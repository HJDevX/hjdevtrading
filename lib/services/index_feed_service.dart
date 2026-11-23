import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

enum IndexFeedState {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  error,
}

/// Live prices from Kotak's market-data WebSocket (SFeed):
///  - INDICES (NIFTY, SENSEX, BANKNIFTY) — the ONLY source for them
///    (REST quotes rejects indices)
///  - SCRIPS (Step 9) — watchlist stocks/F&O via subscribeScripsLite:
///    push updates the moment a trade happens, replacing the old
///    3-second REST polling while the socket is live
///
/// Built strictly from Kotak's official "Market Data WebSocket —
/// Developer Guide":
///  - Connect to `feedUrl` from the login-validate response (https -> wss)
///  - Auth = one JSON text frame; success = message_code 1117 — or
///    1119, which is what the production server actually sends (both
///    carry the per-exchange price dividers as an OBJECT keyed by
///    segment name, e.g. {"nse_cm": {"divider": 100}})
///  - 1120 = auth failed (also the reply when the auth frame is
///    missing fields the server requires — see _sendAuth)
///  - Indices subscribe with event "subscribeIndices", inputtoken
///    "nse_cm|26000"; index packets are message_code 7207, 87 bytes,
///    little-endian, prices = raw / divider
///  - Scrips subscribe with "subscribeScripsLite"; their packets share
///    message_code 7208 with the full Market Picture — route by the
///    LEVEL byte (level 1 = Mini Touch Line, 54 bytes, guide s.7.4)
///
/// CRASH-SAFETY DESIGN (this service must never take the app down):
///  - every callback is stamped with a generation number; a stale
///    socket's late callbacks are ignored
///  - reconnects are scheduled with a Timer, never called synchronously
///    from inside a stream callback
///  - every message handler is wrapped in try/catch
///  - packet decoding is sliced (max 200 packets per event-loop
///    turn) and reconnects back off (3s, 6s, 9s...) — added after
///    the third freeze, which again followed a network drop +
///    reconnect + auth frame; the heartbeat prints frame/packet/
///    tick counters so any future freeze log is decisive
///  - auth is tried with SID first; on 1120 it retries ONCE with the
///    session token; a second 1120 stops the service (state = error)
class IndexFeedService {
  static final IndexFeedService instance = IndexFeedService._internal();
  IndexFeedService._internal();

  final _ticksController = StreamController<Quote>.broadcast();
  Stream<Quote> get ticks => _ticksController.stream;

  final _stateController = StreamController<IndexFeedState>.broadcast();
  Stream<IndexFeedState> get states => _stateController.stream;

  IndexFeedState _state = IndexFeedState.disconnected;
  IndexFeedState get state => _state;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  bool _loggedFirstFrame = false;
  bool _loggedFirstBinary = false;

  // Freeze-detective counters, printed by the heartbeat: exactly how
  // far the feed got before any freeze (frames in, packets decoded,
  // ticks out, last control code seen).
  int _framesReceived = 0;
  int _packetsDecoded = 0;
  int _ticksEmitted = 0;
  int? _lastControlCode;

  int _generation = 0;
  bool _manualClose = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;

  bool _triedTokenAuth = false;
  bool _tokenAuthWorked = false;

  final Set<String> _keys = <String>{};

  /// Scrip keys ("segment|token") subscribed via subscribeScripsLite.
  /// Two owners share one socket: the watchlist screen (syncScrips)
  /// and everyone else — pending-order engine + portfolio holdings
  /// (syncExtraScrips). The socket subscribes the UNION of both.
  final Set<String> _scripKeys = <String>{};
  final Set<String> _extraScripKeys = <String>{};

  Set<String> get _allScripKeys => {..._scripKeys, ..._extraScripKeys};

  bool _loggedFirstMini = false;

  /// Price dividers by numeric exchange code (guide section 9).
  final Map<int, double> _dividers = <int, double>{};

  static const Map<int, String> _segmentByCode = {
    1: 'nse_cm',
    2: 'nse_fo',
    3: 'cde_fo',
    4: 'nse_com',
    5: 'bse_cm',
    6: 'bse_fo',
    7: 'bse_cd',
    8: 'bse_co',
    9: 'mcx_fo',
    10: 'ncd_co',
  };

  static const Map<String, int> _codeBySegment = {
    'nse_cm': 1,
    'nse_fo': 2,
    'cde_fo': 3,
    'nse_com': 4,
    'bse_cm': 5,
    'bse_fo': 6,
    'bse_cd': 7,
    'bse_co': 8,
    'mcx_fo': 9,
    'ncd_co': 10,
  };

  void _setState(IndexFeedState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
    debugPrint('IndexFeed: state -> $s');
  }

  String _wsUrl(String feedUrl) {
    var url = feedUrl.trim();
    if (url.startsWith('https://')) {
      url = 'wss://${url.substring('https://'.length)}';
    } else if (url.startsWith('http://')) {
      url = 'ws://${url.substring('http://'.length)}';
    }
    return url;
  }

  // ---------------- Public API ----------------

  void connect() {
    if (_state == IndexFeedState.connecting ||
        _state == IndexFeedState.authenticating ||
        _state == IndexFeedState.connected) {
      return;
    }
    _reconnectTimer?.cancel();
    _manualClose = false;
    // On a fresh connect, start from the auth value that worked last time.
    _triedTokenAuth = _tokenAuthWorked;
    _generation++;
    _setState(IndexFeedState.connecting);
    _startHeartbeat();
    _openChannel(_generation);
  }

  /// Freeze detective: while the app runs, this prints every 10s. If
  /// the app ever freezes again, the log tells us where: heartbeats
  /// still printing = the Dart side is alive and the stall is on the
  /// platform side; heartbeats stopped = the Dart side itself stuck,
  /// and the last breadcrumb before them names the step it died in.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      debugPrint('IndexFeed: heartbeat (state=$_state, '
          'frames=$_framesReceived, packets=$_packetsDecoded, '
          'ticks=$_ticksEmitted, lastCode=$_lastControlCode)');
    });
  }

  void disconnect() {
    _manualClose = true;
    _generation++;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _cleanupChannel();
    _retryCount = 0;
    _triedTokenAuth = false;
    _tokenAuthWorked = false;
    _setState(IndexFeedState.disconnected);
  }

  /// Keys look like "nse_cm|26000". Safe to call any time; keys are
  /// remembered and (re)sent after every successful auth.
  void subscribe(List<String> keys) {
    var added = false;
    for (final k in keys) {
      final key = k.trim();
      if (key.isEmpty) continue;
      if (_keys.add(key)) added = true;
    }
    if (added && _state == IndexFeedState.connected) {
      _sendSubscriptions();
    }
  }

  /// Make the scrip (Mini Touch Line) subscriptions exactly match
  /// [keys] — the watchlist calls this whenever its items change.
  /// Additions are snapshot+subscribed, removals unsubscribed; when
  /// the socket is down the set is simply remembered and sent after
  /// the next successful auth (the server forgets everything on
  /// disconnect, guide s.8).
  void syncScrips(List<String> keys) {
    final before = _allScripKeys;
    _scripKeys
      ..clear()
      ..addAll(keys
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty));
    _applyScripDiff(before, _allScripKeys);
  }

  /// The extra set: instruments the pending-order engine and the
  /// paper portfolio need live ticks for, on top of the watchlist.
  void syncExtraScrips(List<String> keys) {
    final before = _allScripKeys;
    _extraScripKeys
      ..clear()
      ..addAll(keys
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty));
    _applyScripDiff(before, _allScripKeys);
  }

  void _applyScripDiff(Set<String> before, Set<String> after) {
    final added = after.difference(before);
    final removed = before.difference(after);
    if (_state != IndexFeedState.connected) return;
    if (removed.isNotEmpty) {
      _sendFrame('unsubscribeScripsLite', removed.join(','));
    }
    if (added.isNotEmpty) {
      _sendFrame('snapshotScripsLite', added.join(','));
      _sendFrame('subscribeScripsLite', added.join(','));
      debugPrint('IndexFeed: subscribed scrips (lite): ${added.join(',')}');
    }
  }

  // ---------------- Connection internals ----------------

  void _openChannel(int gen) {
    final api = KotakApi.instance;
    final feedUrl = api.feedUrl;
    final ucc = api.ucc;
    if (feedUrl == null || feedUrl.isEmpty || ucc == null || ucc.isEmpty) {
      debugPrint('IndexFeed: no feedUrl/UCC — login first');
      _setState(IndexFeedState.error);
      return;
    }

    try {
      debugPrint('IndexFeed: opening socket...');
      _loggedFirstFrame = false;
      _loggedFirstBinary = false;
      final channel = WebSocketChannel.connect(Uri.parse(_wsUrl(feedUrl)));
      _channel = channel;
      _subscription = channel.stream.listen(
        (message) {
          if (gen != _generation) return; // stale socket — ignore
          _onMessage(message);
        },
        onError: (Object e) {
          if (gen != _generation) return;
          debugPrint('IndexFeed: socket error: $e');
          _onSocketDown();
        },
        onDone: () {
          if (gen != _generation) return;
          debugPrint('IndexFeed: socket closed by server');
          _onSocketDown();
        },
        cancelOnError: false,
      );
      _setState(IndexFeedState.authenticating);
      _sendAuth(channel, useSid: !_triedTokenAuth, gen: gen);
    } catch (e) {
      debugPrint('IndexFeed: connect exception: $e');
      _onSocketDown();
    }
  }

  void _sendAuth(WebSocketChannel channel,
      {required bool useSid, required int gen}) {
    final api = KotakApi.instance;
    final authValue = useSid ? api.sessionSid : api.sessionToken;
    if (authValue == null || authValue.isEmpty || api.ucc == null) {
      debugPrint('IndexFeed: missing auth value — cannot authenticate');
      _setState(IndexFeedState.error);
      return;
    }
    // This frame mirrors what Kotak's own client sends, verified
    // against a production integration (OpenAlgo): the server REJECTS
    // the frame (1120) when fields are missing. platform, version,
    // conn_req_time and sessionValidation must all be present, and
    // sdk_version is the integer 2 — the short frame from the PDF
    // guide (sdk_version 1.1, date-only sdk_date, nothing else) is
    // what got us 1120.
    final now = DateTime.now();
    final frame = jsonEncode({
      'user': api.ucc,
      'auth': authValue,
      'format': 'native_batch',
      'source': 'NEOTRADEAPI',
      'platform': 'Web',
      'version': '1.2.3',
      'sdk_version': 2,
      'sdk_date': now.toUtc().toIso8601String(),
      'conn_req_time': now.millisecondsSinceEpoch,
      'sessionValidation': false,
    });
    try {
      channel.sink.add(frame);
      // Never print the credential itself — only which kind was sent.
      debugPrint(
          'IndexFeed: auth frame sent (auth = ${useSid ? 'SID' : 'TOKEN'})');
      _startAuthWatchdog(gen);
    } catch (e) {
      debugPrint('IndexFeed: auth send failed: $e');
    }
  }

  /// A rejected auth can look exactly like a quiet market: the socket
  /// stays open and nothing arrives. If no auth reply lands within
  /// 15 seconds, close and let the reconnect logic retry.
  Timer? _authTimer;
  void _startAuthWatchdog(int gen) {
    _authTimer?.cancel();
    _authTimer = Timer(const Duration(seconds: 15), () {
      if (gen != _generation) return;
      if (_state == IndexFeedState.authenticating) {
        debugPrint('IndexFeed: no auth reply in 15s — closing to retry');
        _onSocketDown();
      }
    });
  }

  void _cleanupChannel() {
    _authTimer?.cancel();
    try {
      _subscription?.cancel();
    } catch (_) {}
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _onSocketDown() {
    if (_manualClose || _state == IndexFeedState.error) return;
    // Invalidate the dead socket's callbacks BEFORE touching it, so a
    // late onDone/onError from it can never disturb the next connection.
    _generation++;
    _cleanupChannel();

    if (_retryCount >= _maxRetries) {
      debugPrint('IndexFeed: giving up after $_maxRetries retries');
      _setState(IndexFeedState.error);
      return;
    }
    _retryCount++;
    _setState(IndexFeedState.reconnecting);
    _reconnectTimer?.cancel();
    // Backoff: 3s, 6s, 9s... — on a dead network, hammering the
    // reconnect is what all three freezes followed.
    _reconnectTimer = Timer(Duration(seconds: 3 * _retryCount), () {
      if (_manualClose) return;
      // Force a fresh connect attempt.
      _state = IndexFeedState.disconnected;
      connect();
    });
  }

  /// 1120 with SID: close quietly and retry ONCE with the session token.
  void _retryWithTokenAuth() {
    _triedTokenAuth = true;
    final gen = ++_generation;
    _cleanupChannel();
    _setState(IndexFeedState.authenticating);
    Timer(const Duration(milliseconds: 400), () {
      if (_manualClose || gen != _generation) return;
      _openChannel(gen);
    });
  }

  void _sendFrame(String event, String inputtoken) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode({'event': event, 'inputtoken': inputtoken}));
    } catch (e) {
      debugPrint('IndexFeed: send $event failed: $e');
    }
  }

  void _sendSubscriptions() {
    if (_channel == null) return;
    if (_keys.isNotEmpty) {
      final joined = _keys.join(',');
      _sendFrame('snapshotIndices', joined);
      _sendFrame('subscribeIndices', joined);
      debugPrint('IndexFeed: subscribed indices: $joined');
    }
    final allScrips = _allScripKeys;
    if (allScrips.isNotEmpty) {
      final joined = allScrips.join(',');
      _sendFrame('snapshotScripsLite', joined);
      _sendFrame('subscribeScripsLite', joined);
      debugPrint('IndexFeed: subscribed scrips (lite): $joined');
    }
  }

  // ---------------- Message handling ----------------

  void _onMessage(dynamic message) {
    try {
      _framesReceived++;
      if (!_loggedFirstFrame) {
        _loggedFirstFrame = true;
        debugPrint(
            'IndexFeed: first frame on this socket (${message is String ? 'text' : 'binary'})');
      }
      if (message is String) {
        _handleTextMessage(message);
      } else if (message is List<int>) {
        _parseFrame(Uint8List.fromList(message), _generation);
      } else if (message is Uint8List) {
        _parseFrame(message, _generation);
      }
    } catch (e) {
      // A bad packet must never crash the app.
      debugPrint('IndexFeed: message handling error: $e');
    }
  }

  void _handleTextMessage(String message) {
    dynamic decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      return; // not JSON — ignore
    }
    if (decoded is! Map) return;

    final codeRaw = decoded['message_code'];
    final code = codeRaw is num
        ? codeRaw.toInt()
        : int.tryParse(codeRaw?.toString() ?? '');
    _lastControlCode = code;
    debugPrint('IndexFeed: auth/control message_code=$code');

    if (decoded['format'] == 'native_fallback') {
      // The server refused native_batch and downgraded the connection;
      // our binary decoder cannot read the fallback format. Stop
      // rather than decode garbage.
      debugPrint(
          'IndexFeed: server downgraded to native_fallback — stopping');
      _manualClose = true;
      _generation++;
      _cleanupChannel();
      _setState(IndexFeedState.error);
      return;
    }

    if (code == 1117 || code == 1119) {
      // AUTH SUCCESS. 1117 is the code in Kotak's PDF guide, but 1119
      // is what the production server actually sends (verified against
      // a live integration, OpenAlgo: MSG_AUTH_RESPONSE_CODES =
      // (1117, 1119)). Treating 1119 as "not yet success" was a bug —
      // the feed authenticated but never subscribed, so no index
      // prices ever arrived.
      _authTimer?.cancel();
      _storeDividers(decoded);
      _tokenAuthWorked = _triedTokenAuth;
      _retryCount = 0;
      _setState(IndexFeedState.connected);
      debugPrint(
          'IndexFeed: AUTH SUCCESS (auth = ${_triedTokenAuth ? 'TOKEN' : 'SID'})');
      _sendSubscriptions();
    } else if (code == 1120) {
      // AUTH FAILED
      if (!_triedTokenAuth) {
        debugPrint('IndexFeed: auth failed with SID (1120) — retrying once with TOKEN');
        _retryWithTokenAuth();
      } else {
        debugPrint('IndexFeed: auth failed with TOKEN too (1120) — stopping');
        _manualClose = true;
        _generation++;
        _cleanupChannel();
        _setState(IndexFeedState.error);
      }
    }
    // 1109 = subscription ack — nothing to do.
  }

  /// The 1117/1119 reply carries dividers as an OBJECT keyed by segment
  /// NAME: {"exchanges": {"nse_cm": {"divider": 100}, ...}} (guide s.3).
  void _storeDividers(Map<dynamic, dynamic> decoded) {
    try {
      final exchanges = decoded['exchanges'];
      if (exchanges is Map) {
        exchanges.forEach((name, info) {
          if (info is! Map) return;
          // Prefer the numeric exchange id the reply itself states
          // ("value") over our static name->id map, so a server-side
          // renumbering cannot silently misscale a whole segment.
          final stated = info['value'];
          final code = (stated is num ? stated.toInt() : null) ??
              _codeBySegment[name.toString().toLowerCase()];
          if (code == null) return;
          final d = info['divider'];
          final value =
              d is num ? d.toDouble() : double.tryParse(d?.toString() ?? '');
          if (value != null && value > 0) _dividers[code] = value;
        });
      }
    } catch (e) {
      debugPrint('IndexFeed: divider parse error: $e');
    }
  }

  // ---------------- Binary packets (guide s.6/s.7) ----------------

  /// A frame is a batch of packets; each starts with a uint16 LE total
  /// length that INCLUDES the 2 length bytes and the 9-byte header.
  ///
  /// HARDENING (after the third freeze): never decode more than 200
  /// packets in one event-loop turn. If a frame carries more (a huge
  /// snapshot burst), the rest is decoded on the next turn — a burst
  /// can then never monopolise the main thread long enough to ANR.
  /// The generation stamp drops leftovers from a dead socket.
  void _parseFrame(Uint8List bytes, int gen) {
    _parseFrameSlice(bytes, 0, gen);
  }

  void _parseFrameSlice(Uint8List bytes, int startOffset, int gen) {
    if (gen != _generation) return; // leftover from a dead socket
    final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    var offset = startOffset;
    var processed = 0;
    while (offset + 2 <= bytes.length) {
      final totalLength = bd.getUint16(offset, Endian.little);
      if (totalLength < 9) break;
      if (offset + totalLength > bytes.length) break; // truncated tail
      _parsePacket(Uint8List.sublistView(bytes, offset, offset + totalLength));
      _packetsDecoded++;
      offset += totalLength;
      processed++;
      if (processed >= 200 && offset + 2 <= bytes.length) {
        Timer(Duration.zero, () => _parseFrameSlice(bytes, offset, gen));
        return;
      }
    }
    if (!_loggedFirstBinary) {
      _loggedFirstBinary = true;
      debugPrint(
          'IndexFeed: first binary frame decoded ok (packets so far: $_packetsDecoded)');
    }
  }

  void _parsePacket(Uint8List packet) {
    if (packet.length < 9) return;
    final bd = packet.buffer.asByteData(
        packet.offsetInBytes, packet.length);
    final messageCode = bd.getUint16(2, Endian.little);
    final exchangeId = bd.getInt8(4);
    final level = bd.getUint8(5);

    // Routing order per guide s.6.2: index (7207) first, then market
    // status / CAS (105/104, ignored), then by the LEVEL byte — the
    // Mini Touch Line and the full Market Picture BOTH arrive as
    // message_code 7208, only the level tells them apart.
    if (messageCode == 7207) {
      _decodeIndexPacket(bd, packet, exchangeId);
    } else if (messageCode == 105 || messageCode == 104) {
      // Market status / CAS reference — not prices, ignore.
      return;
    } else if (level == 1) {
      _decodeMiniPacket(bd, exchangeId);
    }
    // Level 2/4/8 = full Market Picture — we never subscribe to it.
  }

  void _decodeIndexPacket(ByteData bd, Uint8List packet, int exchangeId) {
    if (packet.length < 53) return; // need values through net_chg_percent

    final divider = _dividers[exchangeId] ?? 100.0;
    final token = bd.getUint32(9, Endian.little);
    final open = bd.getInt32(13, Endian.little) / divider;
    final prevClose = bd.getInt32(17, Endian.little) / divider;
    final high = bd.getInt32(21, Endian.little) / divider;
    final low = bd.getInt32(25, Endian.little) / divider;
    final value = bd.getInt32(29, Endian.little) / divider;
    final pctRaw = bd.getInt32(49, Endian.little);

    var name = '';
    if (packet.length >= 87) {
      final nameBytes = packet.sublist(66, 87);
      final end = nameBytes.indexOf(0);
      name = utf8
          .decode(end == -1 ? nameBytes : nameBytes.sublist(0, end),
              allowMalformed: true)
          .trim();
    }
    if (name.isEmpty) {
      name = token == 26000
          ? 'NIFTY'
          : token == 26009
              ? 'BANKNIFTY'
              : token == 1
                  ? 'SENSEX'
                  : 'IDX$token';
    }

    final quote = Quote(
      symbol: name,
      exchange: _segmentByCode[exchangeId] ?? 'nse_cm',
      token: token.toString(),
      ltp: value,
      open: open,
      high: high,
      low: low,
      prevClose: prevClose,
      volume: 0,
      changePct: pctRaw / 100.0,
    );
    _ticksEmitted++;
    if (!_ticksController.isClosed) _ticksController.add(quote);
  }

  /// Mini Touch Line — message_code 7208, level 1, 54 bytes (guide
  /// s.7.4): token u32 @9, last_traded_price u32 @21 / divider,
  /// net_chg_percent i32 @37 / 100, net_chg i32 @41 / divider.
  ///
  /// The packet's own close_price (@33) is documented as "used as-is,
  /// NOT divided" — but the guide's worked example only reconciles
  /// (ltp - net_chg = prev close) if the previous close is derived
  /// from the two unambiguous fields, so that is what we do. The Mini
  /// packet carries no OHLC/day-volume; the watchlist merges each
  /// tick over the last REST quote so those stay on screen.
  void _decodeMiniPacket(ByteData bd, int exchangeId) {
    if (bd.lengthInBytes < 54) return;
    final divider = _dividers[exchangeId] ?? 100.0;
    final token = bd.getUint32(9, Endian.little);
    final ltp = bd.getUint32(21, Endian.little) / divider;
    final pct = bd.getInt32(37, Endian.little) / 100.0;
    final netChg = bd.getInt32(41, Endian.little) / divider;
    final prevClose = ltp - netChg;
    if (ltp <= 0) return;
    if (!_loggedFirstMini) {
      _loggedFirstMini = true;
      debugPrint(
          'IndexFeed: MINI token=$token ltp=$ltp chg%=$pct (first scrip packet)');
    }
    final quote = Quote(
      symbol: token.toString(),
      exchange: _segmentByCode[exchangeId] ?? 'nse_cm',
      token: token.toString(),
      ltp: ltp,
      open: prevClose,
      high: prevClose,
      low: prevClose,
      prevClose: prevClose,
      volume: 0,
      changePct: pct,
    );
    _ticksEmitted++;
    if (!_ticksController.isClosed) _ticksController.add(quote);
  }
}
