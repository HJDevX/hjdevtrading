import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/paper_broker.dart';

/// PENDING ORDER ENGINE for paper trading.
///
/// Watches ACTIVE rows in paper_pending_orders and fills them
/// through the PaperBroker:
///  - PRICE orders fill when the live price TOUCHES the trigger
///    (crosses it between two ticks), filled AT the trigger price.
///  - TIME orders fill at the exact clock time, at the then-live
///    price (a time that passed while the app was closed fires on
///    the next app start).
///  - When a BUY entry fills and it carries a TARGET, the target is
///    armed as its own pending SELL (price, % or exact time).
///  - A fill the broker refuses (no holdings to sell, not enough
///    virtual fund) marks the order FAILED with the reason kept.
///
/// Prices come from the live feed (the engine keeps its instruments
/// + all open positions subscribed via the feed's extra set, which
/// is also what makes the Portfolio P&L update in real time), with
/// a REST poll every 3 s as fallback while the feed is down.
/// Runs only while the app is open — started from the home screen.
class PendingOrderEngine {
  static final PendingOrderEngine instance = PendingOrderEngine._internal();
  PendingOrderEngine._internal();

  final AppDb _db = AppDb.instance;
  final IndexFeedService _feed = IndexFeedService.instance;
  final KotakApi _api = KotakApi.instance;

  /// Bumped whenever the pending list changes (place / modify /
  /// cancel / fill / fail). The Orders tab listens to this.
  static final ValueNotifier<int> pendingRevision =
      ValueNotifier<int>(0);

  bool _started = false;
  Timer? _clockTimer;
  StreamSubscription<Quote>? _tickSub;
  DateTime _lastRestPoll = DateTime.fromMillisecondsSinceEpoch(0);

  /// Last two prices per instrument key, for touch/cross detection.
  final Map<String, double> _lastPrice = {};
  final Map<String, double> _prevPrice = {};

  List<PaperPendingOrder> _active = [];

  void _bump() => pendingRevision.value = pendingRevision.value + 1;

  // ---------------- Lifecycle ----------------

  void start() {
    if (_started) return;
    _started = true;
    _tickSub = _feed.ticks.listen(_onTick);
    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _onSecond());
    PaperBroker.revisionNotifier.addListener(_onBrokerChanged);
    _reload();
    debugPrint('PendingEngine: started');
  }

  void _onBrokerChanged() {
    // Positions changed (a trade happened) — the feed's extra set
    // tracks positions too, and a manual full exit cancels targets.
    _refreshWatchSet();
    _cancelOrphanTargets();
  }

  Future<void> _reload() async {
    _active = await _db.getPaperPendingOrders(status: 'ACTIVE');
    _refreshWatchSet();
  }

  /// Feed-tick key for an order (segment names normalised, matching
  /// the exchange names the feed puts on its tick quotes).
  String _keyFor(PaperPendingOrder o) =>
      '${KotakApi.normalizeSegment(o.exchange)}|${o.token}';

  /// Keep the feed subscribed (extra set) to every instrument with
  /// an ACTIVE pending order plus every open paper position — the
  /// same ticks drive the Portfolio's real-time P&L.
  Future<void> _refreshWatchSet() async {
    final keys = <String>{};
    for (final o in _active) {
      if (o.token != null && o.token!.isNotEmpty) keys.add(_keyFor(o));
    }
    final positions = await _db.getPaperPositions();
    for (final p in positions) {
      if (p.token != null && p.token!.isNotEmpty) {
        keys.add('${KotakApi.normalizeSegment(p.exchange)}|${p.token}');
      }
    }
    _feed.syncExtraScrips(keys.toList());
  }

  // ---------------- Public operations ----------------

  Future<List<PaperPendingOrder>> activeOrders() =>
      _db.getPaperPendingOrders(status: 'ACTIVE');

  /// Recent finished orders (executed / cancelled / failed).
  Future<List<PaperPendingOrder>> recentFinished({int limit = 20}) async {
    final all = await _db.getPaperPendingOrders();
    return all.where((o) => o.status != 'ACTIVE').take(limit).toList();
  }

  Future<void> place(PaperPendingOrder order) async {
    await _db.insertPaperPendingOrder(order);
    await _reload();
    _bump();
  }

  Future<void> cancel(PaperPendingOrder order) async {
    if (order.status != 'ACTIVE') return;
    await _db.updatePaperPendingOrder(order.copyWith(status: 'CANCELLED'));
    await _reload();
    _bump();
  }

  Future<void> modify(PaperPendingOrder updated) async {
    await _db.updatePaperPendingOrder(updated);
    await _reload();
    _bump();
  }

  // ---------------- Watching ----------------

  void _onTick(Quote quote) {
    if (quote.token == null) return;
    final key = '${quote.exchange}|${quote.token}';
    _notePrice(key, quote.ltp);
    _evaluatePriceOrders(key);
  }

  void _notePrice(String key, double price) {
    if (price <= 0) return;
    _prevPrice[key] = _lastPrice[key] ?? price;
    _lastPrice[key] = price;
  }

  void _onSecond() {
    final now = DateTime.now().millisecondsSinceEpoch;
    // TIME triggers: exact clock time (or overdue after app start).
    for (final o in List<PaperPendingOrder>.from(_active)) {
      if (o.triggerType == 'TIME' &&
          o.triggerTimeMs != null &&
          now >= o.triggerTimeMs!) {
        _fireTimeOrder(o);
      }
    }
    // REST fallback for PRICE triggers while the feed is down.
    if (_feed.state != IndexFeedState.connected &&
        DateTime.now().difference(_lastRestPoll).inSeconds >= 3) {
      _lastRestPoll = DateTime.now();
      _pollPrices();
    }
  }

  Future<void> _pollPrices() async {
    final priceOrders =
        _active.where((o) => o.triggerType == 'PRICE').toList();
    if (priceOrders.isEmpty) return;
    final items = <WatchItem>[];
    final seen = <String>{};
    for (final o in priceOrders) {
      if (seen.add(o.key)) items.add(_itemFor(o));
    }
    if (items.isEmpty) return;
    final batch = await _api.getQuotesBatch(items);
    for (final o in priceOrders) {
      final q = (o.token != null ? batch[o.token!] : null) ??
          batch['${o.exchange}|${o.symbol}'] ??
          batch[_keyFor(o)];
      if (q == null) continue;
      _notePrice(_keyFor(o), q.ltp);
      _evaluatePriceOrders(_keyFor(o));
    }
  }

  void _evaluatePriceOrders(String key) {
    final price = _lastPrice[key];
    final prev = _prevPrice[key];
    if (price == null || prev == null) return;
    for (final o in List<PaperPendingOrder>.from(_active)) {
      if (_keyFor(o) != key || o.triggerType != 'PRICE') continue;
      final trigger = o.triggerPrice;
      if (trigger == null) continue;
      // Touch = the price reached the trigger, or crossed it
      // between the previous tick and this one.
      final touched = price == trigger ||
          (prev - trigger) * (price - trigger) < 0;
      if (touched) _firePriceOrder(o, trigger);
    }
  }

  // ---------------- Firing ----------------

  WatchItem _itemFor(PaperPendingOrder o) {
    return WatchItem(
      watchlistId: 0,
      symbol: o.symbol,
      exchange: o.exchange,
      token: o.token,
      displayName: o.displayName,
      instrumentType: o.instrumentType,
      lotSize: o.lotSize,
    );
  }

  Future<void> _firePriceOrder(PaperPendingOrder o, double fillPrice) =>
      _fire(o, fillPrice);

  Future<void> _fireTimeOrder(PaperPendingOrder o) async {
    // Fill at the live price at this moment: last tick if we have
    // one, else one fresh REST fetch.
    var price = _lastPrice[_keyFor(o)] ?? 0;
    if (price <= 0) {
      final batch = await _api.getQuotesBatch([_itemFor(o)]);
      final q = (o.token != null ? batch[o.token!] : null) ??
          batch['${o.exchange}|${o.symbol}'] ??
          batch[_keyFor(o)];
      if (q != null) price = q.ltp;
    }
    await _fire(o, price);
  }

  Future<void> _fire(PaperPendingOrder o, double fillPrice) async {
    // Claim the order first so a second tick can't fire it twice.
    _active.removeWhere((x) => x.id == o.id);
    final claimed = o.copyWith(
      status: 'EXECUTED',
      executedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.updatePaperPendingOrder(claimed);

    final item = _itemFor(o);
    final error = o.isBuy
        ? await PaperBroker.instance
            .buy(item: item, qty: o.qty, price: fillPrice)
        : await PaperBroker.instance
            .sell(item: item, qty: o.qty, price: fillPrice);

    if (error != null) {
      await _db.updatePaperPendingOrder(claimed.copyWith(
        status: 'FAILED',
        note: error,
      ));
      debugPrint('PendingEngine: order ${o.id} FAILED: $error');
    } else {
      debugPrint('PendingEngine: order ${o.id} filled '
          '${o.side} ${o.qty} ${o.symbol} @ $fillPrice');
      // A filled BUY entry arms its TARGET as a pending SELL.
      if (o.isBuy && !o.isTarget && o.hasTarget) {
        await _armTarget(o, fillPrice);
      }
    }
    await _reload();
    _bump();
  }

  Future<void> _armTarget(PaperPendingOrder entry, double fillPrice) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    PaperPendingOrder target;
    if (entry.targetTimeMs != null) {
      target = PaperPendingOrder(
        symbol: entry.symbol,
        exchange: entry.exchange,
        token: entry.token,
        displayName: entry.displayName,
        instrumentType: entry.instrumentType,
        lotSize: entry.lotSize,
        side: 'S',
        qty: entry.qty,
        triggerType: 'TIME',
        triggerTimeMs: entry.targetTimeMs,
        status: 'ACTIVE',
        isTarget: true,
        parentId: entry.id,
        createdMs: now,
      );
    } else {
      final price = entry.targetPrice ??
          (entry.targetPct != null
              ? fillPrice * (1 + entry.targetPct! / 100)
              : null);
      if (price == null) return;
      target = PaperPendingOrder(
        symbol: entry.symbol,
        exchange: entry.exchange,
        token: entry.token,
        displayName: entry.displayName,
        instrumentType: entry.instrumentType,
        lotSize: entry.lotSize,
        side: 'S',
        qty: entry.qty,
        triggerType: 'PRICE',
        triggerPrice: price,
        status: 'ACTIVE',
        isTarget: true,
        parentId: entry.id,
        createdMs: now,
      );
    }
    await _db.insertPaperPendingOrder(target);
    debugPrint('PendingEngine: target armed for ${entry.symbol} '
        '(${target.triggerType} ${target.triggerPrice ?? target.triggerTimeMs})');
  }

  /// If a position was fully sold by hand, its armed target exits
  /// are orphans — cancel them instead of letting them fail later.
  Future<void> _cancelOrphanTargets() async {
    final positions = await _db.getPaperPositions();
    final heldKeys = positions
        .where((p) => p.qty > 0)
        .map((p) => '${KotakApi.normalizeSegment(p.exchange)}|${p.token}')
        .toSet();
    var changed = false;
    for (final o in List<PaperPendingOrder>.from(_active)) {
      if (o.isTarget && !heldKeys.contains(_keyFor(o))) {
        await _db.updatePaperPendingOrder(o.copyWith(
          status: 'CANCELLED',
          note: 'Position already sold',
        ));
        changed = true;
      }
    }
    if (changed) {
      await _reload();
      _bump();
    }
  }
}
