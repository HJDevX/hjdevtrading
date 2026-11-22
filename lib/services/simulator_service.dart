import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// One instrument's SIMULATED price state. The sim starts from the
/// last real price and then random-walks on its own — it is practice
/// data only, never a real quote.
class SimPrice {
  /// The last real price when this instrument entered the simulator.
  final double basePrice;

  /// The real previous close (change % is measured against it, so the
  /// sim screen reads like a normal trading screen).
  final double prevClose;

  double ltp;
  double open;
  double high;
  double low;

  SimPrice({required this.basePrice, required double prevClose})
      : prevClose = prevClose > 0 ? prevClose : basePrice,
        ltp = basePrice,
        open = basePrice,
        high = basePrice,
        low = basePrice;

  double get change => ltp - prevClose;
  double get changePct =>
      prevClose > 0 ? (ltp - prevClose) / prevClose * 100 : 0;
}

/// The simulator engine: fake prices for the user's watchlist
/// instruments, ticking once a second, so the user can practise
/// trading when the real market is closed (evenings, weekends).
///
/// Prices live in memory only. The engine keeps running while the app
/// is open once started (positions need live sim prices for P&L);
/// trades themselves are stored in the sim tables by SimBroker.
class SimulatorService {
  static final SimulatorService instance = SimulatorService._internal();
  SimulatorService._internal();

  final Random _rng = Random();
  Timer? _timer;
  final Map<String, SimPrice> _prices = {}; // key: "segment|token"
  final StreamController<void> _ticksController =
      StreamController<void>.broadcast();

  /// Fires once per sim tick (1 second) — screens just re-read prices.
  Stream<void> get ticks => _ticksController.stream;

  bool get isRunning => _timer != null;
  Map<String, SimPrice> get prices => _prices;

  SimPrice? priceOf(String key) => _prices[key];
  double? ltpOf(String key) => _prices[key]?.ltp;

  /// Add an instrument to the simulator (first seed wins — re-entering
  /// the screen never resets a price that has been walking).
  void seed(String key, {required double ltp, required double prevClose}) {
    if (ltp <= 0) return;
    _prices.putIfAbsent(
        key, () => SimPrice(basePrice: ltp, prevClose: prevClose));
  }

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    debugPrint('Simulator: started (${_prices.length} instruments)');
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    debugPrint('Simulator: paused');
  }

  /// Send every price back to its starting (last real) price.
  void resetPrices() {
    for (final p in _prices.values) {
      p.ltp = p.basePrice;
      p.open = p.basePrice;
      p.high = p.basePrice;
      p.low = p.basePrice;
    }
    _notify();
  }

  void _tick() {
    if (_prices.isEmpty) return;
    for (final p in _prices.values) {
      // Normal step: up to ±0.15%. About 3% of ticks are a jump of up
      // to ±1%, so the sim sometimes moves like real news hit it.
      var step = (_rng.nextDouble() - 0.5) * 0.003;
      if (_rng.nextDouble() < 0.03) {
        step = (_rng.nextDouble() - 0.5) * 0.02;
      }
      var next = p.ltp * (1 + step);
      if (next < 0.05) next = 0.05;
      p.ltp = double.parse(next.toStringAsFixed(2));
      if (p.ltp > p.high) p.high = p.ltp;
      if (p.ltp < p.low) p.low = p.ltp;
    }
    _notify();
  }

  void _notify() {
    if (!_ticksController.isClosed) _ticksController.add(null);
  }
}
