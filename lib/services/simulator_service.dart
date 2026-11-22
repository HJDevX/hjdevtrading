import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// REPLAY SIMULATOR services — real historical market data, replayed
/// candle by candle at a chosen speed. NO fake prices: candles come
/// from Yahoo Finance's free chart API (Kotak's API has no historical
/// endpoint — verified against Kotak's official SDK repos).
///
/// Availability below was verified live on 2026-11-22:
///   1-minute candles: last 7 days only
///   5 / 15-minute:    last ~60 days
///   1-hour:           last ~2 years
///   1-day:            many years
/// Futures & options contracts are NOT on Yahoo — only equity stocks
/// and the big indices (NIFTY, BANKNIFTY, SENSEX) can be replayed.

class Candle {
  final int timeMs; // candle open time, epoch milliseconds
  final double open;
  final double high;
  final double low;
  final double close;
  final int volume;

  const Candle({
    required this.timeMs,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });
}

/// One selectable replay interval and how far back its data exists.
class IntervalSpec {
  final String id; // '1m' | '5m' | '15m' | '1h' | '1d'
  final String yahooInterval;
  final int seconds; // candle duration used for replay pacing
  final int maxDaysBack;
  final String label;
  final String rangeText;

  const IntervalSpec({
    required this.id,
    required this.yahooInterval,
    required this.seconds,
    required this.maxDaysBack,
    required this.label,
    required this.rangeText,
  });

  static const List<IntervalSpec> all = [
    IntervalSpec(
      id: '1m',
      yahooInterval: '1m',
      seconds: 60,
      maxDaysBack: 7,
      label: '1 min',
      rangeText: 'last 7 days',
    ),
    IntervalSpec(
      id: '5m',
      yahooInterval: '5m',
      seconds: 300,
      maxDaysBack: 60,
      label: '5 min',
      rangeText: 'last 60 days',
    ),
    IntervalSpec(
      id: '15m',
      yahooInterval: '15m',
      seconds: 900,
      maxDaysBack: 60,
      label: '15 min',
      rangeText: 'last 60 days',
    ),
    IntervalSpec(
      id: '1h',
      yahooInterval: '60m',
      seconds: 3600,
      maxDaysBack: 730,
      label: '1 hour',
      rangeText: 'last ~2 years',
    ),
    IntervalSpec(
      id: '1d',
      yahooInterval: '1d',
      seconds: 23400, // one trading day, for pacing
      maxDaysBack: 3650,
      label: '1 day',
      rangeText: 'many years',
    ),
  ];

  static IntervalSpec byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => all[1]);
}

class HistoryException implements Exception {
  final String message;
  HistoryException(this.message);
  @override
  String toString() => message;
}

/// Fetches real historical candles from Yahoo Finance.
class HistoryService {
  static final HistoryService instance = HistoryService._internal();
  HistoryService._internal();

  final http.Client _client = http.Client();

  /// Maps an app instrument to its Yahoo symbol, or null when Yahoo
  /// has no history for it (futures/options, unknown segments).
  static String? yahooSymbolFor({
    required String segment,
    required String symbol,
    String? token,
    String? instrumentType,
  }) {
    if (token == '26000') return '^NSEI'; // NIFTY
    if (token == '26009') return '^NSEBANK'; // BANKNIFTY
    if (segment == 'bse_cm' && token == '1') return '^BSESN'; // SENSEX
    if (instrumentType != null && instrumentType != 'EQ') return null;
    // Trading symbols look like "RELIANCE-EQ" — Yahoo wants "RELIANCE".
    final base = symbol.split('-').first.trim();
    if (base.isEmpty) return null;
    if (segment == 'nse_cm') return '$base.NS';
    if (segment == 'bse_cm') return '$base.BO';
    return null;
  }

  /// Candles for ONE chosen day (intraday intervals), or up to 30
  /// daily candles starting at the chosen date (1-day interval).
  /// Throws HistoryException with a user-readable reason on failure.
  Future<List<Candle>> fetchCandles({
    required String yahooSymbol,
    required IntervalSpec spec,
    required DateTime date, // local (IST) calendar date
  }) async {
    final start = DateTime(date.year, date.month, date.day);
    final DateTime end;
    final int limit;
    if (spec.id == '1d') {
      end = start.add(const Duration(days: 75));
      limit = 30;
    } else {
      end = start.add(const Duration(days: 1));
      limit = 100000;
    }
    final url = Uri.parse(
      'https://query1.finance.yahoo.com/v8/finance/chart/'
      '${Uri.encodeComponent(yahooSymbol)}'
      '?interval=${spec.yahooInterval}'
      '&period1=${start.millisecondsSinceEpoch ~/ 1000}'
      '&period2=${end.millisecondsSinceEpoch ~/ 1000}',
    );
    http.Response res;
    try {
      res = await _client
          .get(url, headers: const {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw HistoryException('Could not reach the history server: $e');
    }
    if (res.statusCode != 200) {
      throw HistoryException(
          'History server answered ${res.statusCode} — try again in a moment');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw HistoryException('History server sent an unreadable reply');
    }
    final chart = decoded is Map ? decoded['chart'] : null;
    if (chart is! Map) throw HistoryException('Unexpected history reply');
    final error = chart['error'];
    if (error is Map && error['description'] != null) {
      throw HistoryException(error['description'].toString());
    }
    final results = chart['result'];
    if (results is! List || results.isEmpty) {
      throw HistoryException('No data returned for this selection');
    }
    final result = results.first as Map;
    final timestamps = result['timestamp'] as List?;
    final indicators = result['indicators'] as Map?;
    final quotes = indicators?['quote'] is List
        ? (indicators!['quote'] as List).first as Map
        : null;
    if (timestamps == null || quotes == null) {
      throw HistoryException('No candles for this selection');
    }
    final opens = quotes['open'] as List? ?? const [];
    final highs = quotes['high'] as List? ?? const [];
    final lows = quotes['low'] as List? ?? const [];
    final closes = quotes['close'] as List? ?? const [];
    final volumes = quotes['volume'] as List? ?? const [];

    double at(List list, int i) =>
        i < list.length && list[i] is num ? (list[i] as num).toDouble() : 0;

    final candles = <Candle>[];
    for (var i = 0; i < timestamps.length; i++) {
      final close = at(closes, i);
      if (close <= 0) continue; // gap row (holiday / no trades)
      final ts = (timestamps[i] as num).toInt() * 1000;
      if (spec.id != '1d') {
        // Keep only candles of the chosen IST calendar day.
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        if (d.year != date.year || d.month != date.month || d.day != date.day) {
          continue;
        }
      }
      candles.add(Candle(
        timeMs: ts,
        open: at(opens, i),
        high: at(highs, i),
        low: at(lows, i),
        close: close,
        volume: i < volumes.length && volumes[i] is num
            ? (volumes[i] as num).toInt()
            : 0,
      ));
      if (candles.length >= limit) break;
    }
    if (candles.isEmpty) {
      throw HistoryException(spec.id == '1d'
          ? 'No trading days found from this date'
          : 'No data for this date — it may be a weekend/holiday, or outside the ${spec.rangeText} window for ${spec.label} candles');
    }
    candles.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    debugPrint(
        'History: ${candles.length} ${spec.id} candles for $yahooSymbol');
    return candles;
  }
}

/// The replay clock. Advances through the fetched candles at the
/// chosen speed; inside a candle the price walks open -> low/high ->
/// high/low -> close (the standard approximation), so price-trigger
/// orders can fire mid-candle, not only at candle closes.
class ReplayEngine {
  final List<Candle> candles;
  final IntervalSpec spec;
  double speed;

  ReplayEngine({required this.candles, required this.spec, this.speed = 10});

  final StreamController<void> _ticksController =
      StreamController<void>.broadcast();

  /// Fires on every engine step and control change — screens re-read.
  Stream<void> get ticks => _ticksController.stream;

  /// Called after each advance: (prevPrice, price, simTimeMs) — the
  /// broker uses it to fire time/price triggered orders.
  void Function(double prevPrice, double price, int simTimeMs)? onStep;

  Timer? _timer;
  double _elapsedSec = 0;
  bool _finished = false;

  bool get isPlaying => _timer != null;
  bool get isFinished => _finished;
  double get totalSec => candles.length * spec.seconds.toDouble();
  double get progress => totalSec <= 0 ? 0 : _elapsedSec / totalSec;

  int get candleIndex {
    if (candles.isEmpty) return 0;
    final idx = (_elapsedSec / spec.seconds).floor();
    return min(idx, candles.length - 1);
  }

  double get _progressInCandle {
    if (candles.isEmpty) return 0;
    final within = _elapsedSec - candleIndex * spec.seconds;
    return (within / spec.seconds).clamp(0.0, 1.0);
  }

  int get simTimeMs {
    if (candles.isEmpty) return 0;
    return candles.first.timeMs + (_elapsedSec * 1000).round();
  }

  DateTime get simTime => DateTime.fromMillisecondsSinceEpoch(simTimeMs);

  /// Price checkpoints inside one candle: open, first extreme, second
  /// extreme, close. A green candle dips to its low before rising to
  /// its high (and a red one the reverse) — the usual assumption.
  List<double> _path(Candle c) {
    if (c.close >= c.open) return [c.open, c.low, c.high, c.close];
    return [c.open, c.high, c.low, c.close];
  }

  double priceAt(Candle c, double progress) {
    final path = _path(c);
    final scaled = progress.clamp(0.0, 1.0) * 3;
    final seg = min(scaled.floor(), 2);
    final frac = scaled - seg;
    return path[seg] + (path[seg + 1] - path[seg]) * frac;
  }

  double get currentPrice {
    if (candles.isEmpty) return 0;
    if (_finished) return candles.last.close;
    return priceAt(candles[candleIndex], _progressInCandle);
  }

  /// The candle as it looks SO FAR (for the chart): close = current
  /// price, high/low extended only as far as the walk has reached.
  Candle get partialCandle {
    final c = candles[candleIndex];
    if (_finished) return candles.last;
    final path = _path(c);
    final p = _progressInCandle;
    var hi = c.open;
    var lo = c.open;
    final scaled = p * 3;
    for (var s = 0; s < 3; s++) {
      final segEnd = (s + 1).toDouble();
      if (scaled >= segEnd) {
        hi = max(hi, path[s + 1]);
        lo = min(lo, path[s + 1]);
      } else {
        final cur = priceAt(c, p);
        hi = max(hi, cur);
        lo = min(lo, cur);
        break;
      }
    }
    return Candle(
      timeMs: c.timeMs,
      open: c.open,
      high: hi,
      low: lo,
      close: currentPrice,
      volume: c.volume,
    );
  }

  void play() {
    if (_timer != null || _finished || candles.isEmpty) return;
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _advance(0.2 * speed);
    });
    _notify();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _notify();
  }

  void restart() {
    pause();
    _elapsedSec = 0;
    _finished = false;
    _notify();
  }

  void setSpeed(double x) {
    speed = x;
    _notify();
  }

  void _advance(double simSeconds) {
    if (_finished) return;
    final prevPrice = currentPrice;
    _elapsedSec += simSeconds;
    if (_elapsedSec >= totalSec) {
      _elapsedSec = totalSec;
      _finished = true;
      _timer?.cancel();
      _timer = null;
    }
    final price = currentPrice;
    onStep?.call(prevPrice, price, simTimeMs);
    _notify();
  }

  /// Jump straight to a sim time (used when a session is created, to
  /// settle any orders whose trigger time is the very start).
  void settleAtStart() {
    if (candles.isEmpty) return;
    onStep?.call(candles.first.open, candles.first.open, candles.first.timeMs);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _notify() {
    if (!_ticksController.isClosed) _ticksController.add(null);
  }
}
