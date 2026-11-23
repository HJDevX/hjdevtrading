import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// A snapshot of the paper VIRTUAL FUND. The balance is derived,
/// never stored: available = starting fund + realized P&L − margin
/// blocked in open positions.
class PaperFundInfo {
  final double startingFund;
  final double realizedPnl;
  final double marginBlocked;

  const PaperFundInfo({
    required this.startingFund,
    required this.realizedPnl,
    required this.marginBlocked,
  });

  double get available => startingFund + realizedPnl - marginBlocked;
}

/// PAPER (practice) broker. Buys and sells fill instantly at the given
/// live price, positions are averaged, and everything is stored ONLY in
/// the phone's local database. No order is ever sent to Kotak.
///
/// Trades run against a VIRTUAL FUND (₹1,00,000 by default). A BUY
/// blocks margin: EQUITY buys get 5x MTF-style leverage (only 20% of
/// the value is blocked); everything else blocks its full value.
/// A buy that needs more margin than the available fund is refused.
class PaperBroker {
  static final PaperBroker instance = PaperBroker._internal();
  PaperBroker._internal();

  final AppDb _db = AppDb.instance;

  /// Bumped after every paper trade. The Practice tabs watch this to
  /// know their lists are stale (they stay alive in the background, so
  /// initState alone would never refresh them).
  static int revision = 0;

  /// Leverage for a buy: 5x for EQUITY (MTF-style), 1x (full value)
  /// for everything else — futures, options, anything unknown.
  static double leverageFor(String? instrumentType) =>
      instrumentType == 'EQ' ? 5.0 : 1.0;

  /// Margin a buy of [qty] at [price] would block.
  static double marginFor({
    required int qty,
    required double price,
    required String? instrumentType,
  }) =>
      qty * price / leverageFor(instrumentType);

  /// The current virtual-fund snapshot (see PaperFundInfo).
  Future<PaperFundInfo> fundInfo() async {
    final starting = await _db.getPaperStartingFund();
    final realized = await _db.getPaperRealizedTotal();
    final positions = await _db.getPaperPositions();
    var blocked = 0.0;
    for (final p in positions) {
      blocked += marginFor(
          qty: p.qty, price: p.avgPrice, instrumentType: p.instrumentType);
    }
    return PaperFundInfo(
      startingFund: starting,
      realizedPnl: realized,
      marginBlocked: blocked,
    );
  }

  /// Returns null on success, or an error message to show the user.
  Future<String?> buy({
    required WatchItem item,
    required int qty,
    required double price,
  }) =>
      _execute(item: item, side: 'B', qty: qty, price: price);

  /// Returns null on success, or an error message to show the user.
  Future<String?> sell({
    required WatchItem item,
    required int qty,
    required double price,
  }) =>
      _execute(item: item, side: 'S', qty: qty, price: price);

  Future<String?> _execute({
    required WatchItem item,
    required String side,
    required int qty,
    required double price,
  }) async {
    if (qty <= 0) return 'Quantity must be more than 0';
    if (price <= 0) return 'Live price not available yet — try again';

    final existing = await _db.getPaperPosition(
      item.symbol,
      item.exchange,
      item.token,
    );

    double realizedPnl = 0;

    if (side == 'B') {
      // Virtual-fund check: this buy's margin must fit in the
      // available fund (equity blocks only 1/5th — 5x MTF leverage).
      final fund = await fundInfo();
      final needed = marginFor(
          qty: qty, price: price, instrumentType: item.instrumentType);
      if (needed > fund.available + 0.005) {
        return 'Not enough virtual fund — this buy needs '
            '₹${needed.toStringAsFixed(0)} margin, you have '
            '₹${fund.available.toStringAsFixed(0)} available';
      }
      if (existing == null) {
        await _db.upsertPaperPosition(PaperPosition(
          symbol: item.symbol,
          exchange: item.exchange,
          token: item.token,
          displayName: item.displayName,
          instrumentType: item.instrumentType,
          lotSize: item.lotSize,
          qty: qty,
          avgPrice: price,
        ));
      } else {
        final newQty = existing.qty + qty;
        final newAvg =
            (existing.qty * existing.avgPrice + qty * price) / newQty;
        await _db.upsertPaperPosition(
            existing.copyWith(qty: newQty, avgPrice: newAvg));
      }
    } else {
      // SELL
      if (existing == null || existing.qty <= 0) {
        return 'You do not hold ${item.symbol} in Practice';
      }
      if (qty > existing.qty) {
        return 'You hold only ${existing.qty} qty of ${item.symbol}';
      }
      realizedPnl = (price - existing.avgPrice) * qty;
      final newQty = existing.qty - qty;
      if (newQty == 0) {
        await _db.deletePaperPosition(existing.id!);
      } else {
        await _db.upsertPaperPosition(existing.copyWith(qty: newQty));
      }
    }

    await _db.insertPaperOrder(PaperOrder(
      symbol: item.symbol,
      exchange: item.exchange,
      token: item.token,
      displayName: item.displayName,
      instrumentType: item.instrumentType,
      side: side,
      qty: qty,
      price: price,
      realizedPnl: realizedPnl,
      timeMs: DateTime.now().millisecondsSinceEpoch,
    ));
    revision++;
    return null;
  }

  /// Builds a WatchItem-like handle from a position, for selling from
  /// the Portfolio page and for fetching its live quote.
  WatchItem positionAsItem(PaperPosition p) {
    return WatchItem(
      watchlistId: 0,
      symbol: p.symbol,
      exchange: p.exchange,
      token: p.token,
      displayName: p.displayName,
      instrumentType: p.instrumentType,
      lotSize: p.lotSize,
    );
  }
}
