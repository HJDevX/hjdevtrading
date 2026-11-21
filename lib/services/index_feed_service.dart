import 'dart:async';
import 'dart:convert';
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

/// Live INDEX prices (NIFTY, SENSEX, BANKNIFTY) from Kotak's market-data
/// WebSocket — the ONLY source for indices (REST quotes rejects them).
///
/// Built strictly from Kotak's official "Market Data WebSocket —
/// Developer Guide":
///  - Connect to `feedUrl` from the login-validate response (https -> wss)
///  - Auth = one JSON text frame; success = message_code 1117, which
///    carries per-exchange price dividers as an OBJECT keyed by segment
///    name, e.g. {"nse_cm": {"divider": 100}}
///  - 1120 = auth failed; 1119 = initial frame (dividers, not success)
///  - Indices subscribe with event "subscribeIndices", inputtoken
///    "nse_cm|26000"; index packets are message_code 7207, 87 bytes,
///    little-endian, prices = raw / divider
///
/// CRASH-SAFETY DESIGN (this service must never take the app down):
///  - every callback is stamped with a generation number; a stale
///    socket's late callbacks are ignored
///  - reconnects are scheduled with a Timer, never called synchronously
///    from inside a stream callback
///  - every message handler is wrapped in try/catch
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

  int _generation = 0;
  bool _manualClose = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;

  bool _triedTokenAuth = false;
  bool _tokenAuthWorked = false;

  final Set<String> _keys = <String>{};

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
    _openChannel(_generation);
  }

  void disconnect() {
    _manualClose = true;
    _generation++;
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
      _sendAuth(channel, useSid: !_triedTokenAuth);
    } catch (e) {
      debugPrint('IndexFeed: connect exception: $e');
      _onSocketDown();
    }
  }

  void _sendAuth(WebSocketChannel channel, {required bool useSid}) {
    final api = KotakApi.instance;
    final authValue = useSid ? api.sessionSid : api.sessionToken;
    if (authValue == null || authValue.isEmpty || api.ucc == null) {
      debugPrint('IndexFeed: missing auth value — cannot authenticate');
      _setState(IndexFeedState.error);
      return;
    }
    final frame = jsonEncode({
      'user': api.ucc,
      'auth': authValue,
      'format': 'native_batch',
      'source': 'NEOTRADEAPI',
      'sdk_version': 1.1,
      'sdk_date': '2026-11-21',
    });
    try {
      channel.sink.add(frame);
      // Never print the credential itself — only which kind was sent.
      debugPrint(
          'IndexFeed: auth frame sent (auth = ${useSid ? 'SID' : 'TOKEN'})');
    } catch (e) {
      debugPrint('IndexFeed: auth send failed: $e');
    }
  }

  void _cleanupChannel() {
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
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
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

  void _sendSubscriptions() {
    final channel = _channel;
    if (channel == null || _keys.isEmpty) return;
    final joined = _keys.join(',');
    for (final event in ['snapshotIndices', 'subscribeIndices']) {
      try {
        channel.sink.add(jsonEncode({'event': event, 'inputtoken': joined}));
      } catch (e) {
        debugPrint('IndexFeed: subscribe send failed: $e');
      }
    }
    debugPrint('IndexFeed: subscribed indices: $joined');
  }

  // ---------------- Message handling ----------------

  void _onMessage(dynamic message) {
    try {
      if (message is String) {
        _handleTextMessage(message);
      } else if (message is List<int>) {
        _parseFrame(Uint8List.fromList(message));
      } else if (message is Uint8List) {
        _parseFrame(message);
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
    debugPrint('IndexFeed: auth/control message_code=$code');

    if (code == 1119) {
      // Initial connect frame — carries dividers, not yet success.
      _storeDividers(decoded);
    } else if (code == 1117) {
      // AUTH SUCCESS
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
          final code = _codeBySegment[name.toString().toLowerCase()];
          if (code != null && info is Map) {
            final d = info['divider'];
            final value =
                d is num ? d.toDouble() : double.tryParse(d?.toString() ?? '');
            if (value != null && value > 0) _dividers[code] = value;
          }
        });
      }
    } catch (e) {
      debugPrint('IndexFeed: divider parse error: $e');
    }
  }

  // ---------------- Binary packets (guide s.6/s.7) ----------------

  /// A frame is a batch of packets; each starts with a uint16 LE total
  /// length that INCLUDES the 2 length bytes and the 9-byte header.
  void _parseFrame(Uint8List bytes) {
    final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    var offset = 0;
    while (offset + 2 <= bytes.length) {
      final totalLength = bd.getUint16(offset, Endian.little);
      if (totalLength < 9) break;
      if (offset + totalLength > bytes.length) break; // truncated tail
      _parsePacket(Uint8List.sublistView(bytes, offset, offset + totalLength));
      offset += totalLength;
    }
  }

  void _parsePacket(Uint8List packet) {
    if (packet.length < 9) return;
    final bd = packet.buffer.asByteData(
        packet.offsetInBytes, packet.length);
    final messageCode = bd.getUint16(2, Endian.little);
    final exchangeId = bd.getInt8(4);

    if (messageCode != 7207) return; // only index packets here
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
    if (!_ticksController.isClosed) _ticksController.add(quote);
  }
}
