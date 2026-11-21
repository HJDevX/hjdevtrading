import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// PAPER (practice) broker. Buys and sells fill instantly at the given
/// live price, positions are averaged, and everything is stored ONLY in
/// the phone's local database. No order is ever sent to Kotak.
class PaperBroker {
  static final PaperBroker instance = PaperBroker._internal();
  PaperBroker._internal();

  final AppDb _db = AppDb.instance;

  /// Bumped after every paper trade. The Practice tabs watch this to
  /// know their lists are stale (they stay alive in the background, so
  /// initState alone would never refresh them).
  static int revision = 0;

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
