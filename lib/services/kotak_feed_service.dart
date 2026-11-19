import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

/// WebSocket connection state for the Kotak Neo live feed
enum FeedConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  reconnecting,
  error,
}

/// Singleton service that manages the Kotak Neo sfeed WebSocket connection,
/// authentication handshake, instrument subscriptions, and binary frame parsing.
class KotakFeedService {
  static final KotakFeedService instance = KotakFeedService._();
  KotakFeedService._();

  // --- Streams ---
  final StreamController<Quote> _tickController =
      StreamController<Quote>.broadcast();
  final StreamController<FeedConnectionState> _stateController =
      StreamController<FeedConnectionState>.broadcast();

  Stream<Quote> get ticks => _tickController.stream;
  Stream<FeedConnectionState> get connectionStateStream =>
      _stateController.stream;

  // --- State ---
  FeedConnectionState _state = FeedConnectionState.disconnected;
  FeedConnectionState get connectionState => _state;

  // --- Exchange dividers (populated from auth message_code 1117) ---
  final Map<int, double> _exchangeDividers = {};
  Map<int, double> get exchangeDividers => Map.unmodifiable(_exchangeDividers);

  // --- Subscription tracking ---
  /// Keys are "${segment}|${token}" e.g. "nse_cm|11915"
  final Set<String> _subscribedKeys = {};

  // --- WS channel & stream subscription ---
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSubscription;

  // --- Reconnect handling ---
  int _retryCount = 0;
  static const int _maxRetries = 5;
  Timer? _reconnectTimer;

  // --- Timer for periodic index refresh (unused here, owned by screen) ---

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Connect using credentials from [KotakApi.instance].
  /// Safe to call multiple times — idempotent if already connecting/connected.
  Future<void> connect() async {
    if (_state == FeedConnectionState.connecting ||
        _state == FeedConnectionState.authenticating ||
        _state == FeedConnectionState.connected) {
      return;
    }

    final api = KotakApi.instance;
    final feedUrl = api.feedUrl;
    if (feedUrl == null || feedUrl.isEmpty) {
      debugPrint('KotakFeed: feedUrl not available — cannot connect');
      _setState(FeedConnectionState.error);
      return;
    }

    _setState(FeedConnectionState.connecting);

    try {
      final uri = Uri.parse('wss://$feedUrl');
      _channel = WebSocketChannel.connect(uri);
      _setState(FeedConnectionState.authenticating);

      // Cancel any previous subscription
      await _wsSubscription?.cancel();
      _wsSubscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      // Send auth frame immediately
      _sendAuth();
    } catch (e) {
      debugPrint('KotakFeed: connect error: $e');
      _scheduleReconnect();
    }
  }

  /// Disconnect and stop any reconnect attempts.
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _retryCount = 0;
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _channel?.sink.close();
    _channel = null;
    _setState(FeedConnectionState.disconnected);
  }

  /// Add instruments to the subscription set.
  /// Sends subscription frame immediately if already connected.
  void subscribe(List<WatchItem> items) {
    final newScrips = <Map<String, String>>[];
    for (final item in items) {
      final token = item.token?.trim();
      if (token == null || token.isEmpty) continue;
      final segment = KotakApi.normalizeSegment(item.exchange);
      final key = '$segment|$token';
      if (_subscribedKeys.add(key)) {
        newScrips.add({'exchange': segment, 'token': token});
      }
    }
    if (newScrips.isNotEmpty && _state == FeedConnectionState.connected) {
      _sendSubscribe(newScrips);
    }
  }

  /// Remove instruments from the subscription set.
  /// Sends unsubscribe frame immediately if connected.
  void unsubscribe(List<WatchItem> items) {
    final removeScrips = <Map<String, String>>[];
    for (final item in items) {
      final token = item.token?.trim();
      if (token == null || token.isEmpty) continue;
      final segment = KotakApi.normalizeSegment(item.exchange);
      final key = '$segment|$token';
      if (_subscribedKeys.remove(key)) {
        removeScrips.add({'exchange': segment, 'token': token});
      }
    }
    if (removeScrips.isNotEmpty && _state == FeedConnectionState.connected) {
      _sendUnsubscribe(removeScrips);
    }
  }

  // -------------------------------------------------------------------------
  // Internal — WS send helpers
  // -------------------------------------------------------------------------

  void _sendAuth() {
    final api = KotakApi.instance;
    final frame = jsonEncode({
      'user': api.ucc ?? '',
      'auth': api.sessionSid ?? '',
      'format': 'native_batch',
      'source': 'NEOTRADEAPI',
      'sdk_version': 1.1,
      'sdk_date': '2024-01-01T00:00:00.000',
    });
    _safeSend(frame);
  }

  void _sendSubscribe(List<Map<String, String>> scrips) {
    final frame = jsonEncode({
      'method': 'sub',
      'data': {'scrips': scrips},
    });
    _safeSend(frame);
  }

  void _sendUnsubscribe(List<Map<String, String>> scrips) {
    final frame = jsonEncode({
      'method': 'unsub',
      'data': {'scrips': scrips},
    });
    _safeSend(frame);
  }

  void _safeSend(String text) {
    try {
      _channel?.sink.add(text);
    } catch (e) {
      debugPrint('KotakFeed: send error: $e');
    }
  }

  /// After auth success, subscribe all currently tracked keys.
  void _sendPendingSubscriptions() {
    if (_subscribedKeys.isEmpty) return;
    final scrips = _subscribedKeys.map((key) {
      final parts = key.split('|');
      return {'exchange': parts[0], 'token': parts[1]};
    }).toList();
    _sendSubscribe(scrips);
  }

  // -------------------------------------------------------------------------
  // Internal — message routing
  // -------------------------------------------------------------------------

  void _onMessage(dynamic message) {
    if (message is String) {
      _handleTextMessage(message);
    } else if (message is List<int>) {
      _parseFrame(Uint8List.fromList(message));
    } else if (message is Uint8List) {
      _parseFrame(message);
    }
  }

  void _handleTextMessage(String text) {
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final code = data['message_code'] as int?;

      if (code == 1119) return; // initial connect ack — ignore

      if (code == 1117) {
        // Auth success — parse exchange dividers
        final exchanges = data['exchanges'] as List? ?? [];
        for (final ex in exchanges) {
          if (ex is! Map) continue;
          final exCode = ex['exchange_code'] as int?;
          final divider = (ex['divider'] as num?)?.toDouble();
          if (exCode != null && divider != null && divider > 0) {
            _exchangeDividers[exCode] = divider;
          }
        }
        _retryCount = 0; // reset on successful auth
        _setState(FeedConnectionState.connected);
        _sendPendingSubscriptions();
      } else if (code == 1120) {
        debugPrint('KotakFeed: Auth failed (1120) — bad credentials');
        _setState(FeedConnectionState.error);
        disconnect();
      } else if (code == 1109) {
        // subscription ack — ignore
      } else {
        debugPrint('KotakFeed: Unknown text message code $code');
      }
    } catch (e) {
      debugPrint('KotakFeed: text message parse error: $e\nRaw: $text');
    }
  }

  void _onError(Object error) {
    debugPrint('KotakFeed: socket error: $error');
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('KotakFeed: socket closed');
    if (_state != FeedConnectionState.disconnected &&
        _state != FeedConnectionState.error) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _channel?.sink.close();
    _channel = null;

    if (_retryCount >= _maxRetries) {
      debugPrint('KotakFeed: max retries reached — giving up');
      _setState(FeedConnectionState.error);
      return;
    }

    _retryCount++;
    _setState(FeedConnectionState.reconnecting);
    debugPrint('KotakFeed: reconnecting in 3s (attempt $_retryCount/$_maxRetries)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      connect();
    });
  }

  // -------------------------------------------------------------------------
  // Internal — binary frame parsing
  // -------------------------------------------------------------------------

  void _parseFrame(Uint8List bytes) {
    int offset = 0;
    while (offset + 2 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, offset);
      final packetLen = bd.getUint16(0, Endian.little);
      if (packetLen < 9 || offset + packetLen > bytes.length) break;
      _parsePacket(bytes, offset, packetLen);
      offset += packetLen;
    }
  }

  void _parsePacket(Uint8List bytes, int start, int len) {
    if (len < 9) return;
    final bd = ByteData.sublistView(bytes, start, start + len);
    final msgCode = bd.getUint16(2, Endian.little);
    final level = bd.getUint8(5);
    final exchangeCode = bd.getUint16(6, Endian.little);

    if (msgCode == 7208 && level == 4 && len >= 55) {
      final divider = _exchangeDividers[exchangeCode] ?? 100.0;
      final token = bd.getUint32(9, Endian.little);
      if (token == 0) return;
      final ltp = bd.getInt32(13, Endian.little) / divider;
      if (ltp <= 0) return;
      final volume = bd.getInt64(17, Endian.little);
      final open = bd.getInt32(25, Endian.little) / divider;
      final high = bd.getInt32(29, Endian.little) / divider;
      final low = bd.getInt32(33, Endian.little) / divider;
      final close = bd.getInt32(37, Endian.little) / divider;
      final changePct = bd.getInt16(53, Endian.little) / 100.0;

      final quote = Quote(
        symbol: token.toString(),
        exchange: '',
        token: token.toString(),
        ltp: ltp,
        open: open,
        high: high,
        low: low,
        prevClose: close,
        volume: volume.toInt(),
        changePct: changePct,
      );
      _tickController.add(quote);
    }
  }

  // -------------------------------------------------------------------------
  // State helper
  // -------------------------------------------------------------------------

  void _setState(FeedConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    _stateController.add(newState);
  }

  // -------------------------------------------------------------------------
  // Dispose
  // -------------------------------------------------------------------------

  /// Call this when the app is fully torn down (rarely needed for a singleton).
  void dispose() {
    _reconnectTimer?.cancel();
    _wsSubscription?.cancel();
    _channel?.sink.close();
    _tickController.close();
    _stateController.close();
  }
}
