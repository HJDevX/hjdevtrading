import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// SIMULATOR broker — same rules as the paper broker (instant fills,
/// averaged positions, realized P&L), but fills happen at SIMULATED
/// prices and everything lands in the sim tables, fully separate
/// from the real paper record.
class SimBroker {
  static final SimBroker instance = SimBroker._internal();
  SimBroker._internal();

  final AppDb _db = AppDb.instance;

  /// Bumped after every sim trade (and on Reset). The Simulator tabs
  /// watch this to know their lists are stale.
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
    if (price <= 0) return 'Sim price not available yet — try again';

    final existing = await _db.getSimPosition(
      item.symbol,
      item.exchange,
      item.token,
    );

    double realizedPnl = 0;

    if (side == 'B') {
      if (existing == null) {
        await _db.upsertSimPosition(PaperPosition(
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
        await _db.upsertSimPosition(
            existing.copyWith(qty: newQty, avgPrice: newAvg));
      }
    } else {
      // SELL
      if (existing == null || existing.qty <= 0) {
        return 'You do not hold ${item.symbol} in the Simulator';
      }
      if (qty > existing.qty) {
        return 'You hold only ${existing.qty} qty of ${item.symbol}';
      }
      realizedPnl = (price - existing.avgPrice) * qty;
      final newQty = existing.qty - qty;
      if (newQty == 0) {
        await _db.deleteSimPosition(existing.id!);
      } else {
        await _db.upsertSimPosition(existing.copyWith(qty: newQty));
      }
    }

    await _db.insertSimOrder(PaperOrder(
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

  /// Wipe all sim trades and restart the sim record from zero.
  Future<void> clearAll() async {
    await _db.clearSimData();
    revision++;
  }

  /// Builds a WatchItem-like handle from a sim position (for EXIT).
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
