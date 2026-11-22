/// SIMULATOR (replay) session broker — in-memory only.
///
/// One replay session trades ONE instrument. Orders come in three
/// trigger kinds:
///  - MARKET: fill immediately at the current replay price
///  - TIME:   fill when the replay clock reaches the chosen time,
///            at whatever price is live then ("time only — price
///            does not matter")
///  - PRICE:  fill when the replay price touches the chosen price,
///            filled AT that price (like a limit order)
///
/// Active orders can be modified (qty / trigger price / trigger
/// time) or cancelled before they fire. Fills follow the app's usual
/// paper rules: buys average in, sells need holdings and book
/// realized P&L. Nothing here touches the real paper tables.
class SimOrder {
  final int id;
  String side; // 'B' or 'S'
  int qty;
  String triggerType; // 'MARKET' | 'TIME' | 'PRICE'
  double? triggerPrice;
  int? triggerTimeMs;
  String status; // 'ACTIVE' | 'EXECUTED' | 'CANCELLED' | 'FAILED'
  double? fillPrice;
  int? fillTimeMs;
  double realizedPnl;
  String? note;

  SimOrder({
    required this.id,
    required this.side,
    required this.qty,
    required this.triggerType,
    this.triggerPrice,
    this.triggerTimeMs,
    this.status = 'ACTIVE',
    this.fillPrice,
    this.fillTimeMs,
    this.realizedPnl = 0,
    this.note,
  });

  bool get isBuy => side == 'B';
  bool get isActive => status == 'ACTIVE';

  String get triggerText {
    switch (triggerType) {
      case 'TIME':
        return 'at time';
      case 'PRICE':
        return 'at ₹${triggerPrice?.toStringAsFixed(2) ?? '—'}';
      default:
        return 'market';
    }
  }
}

/// A not-yet-placed order, from the setup screen's pre-order list or
/// the replay screen's order form.
class OrderDraft {
  String side; // 'B' or 'S'
  int qty;
  String triggerType; // 'MARKET' | 'TIME' | 'PRICE'
  double? triggerPrice;
  int? triggerTimeMs;

  OrderDraft({
    required this.side,
    required this.qty,
    required this.triggerType,
    this.triggerPrice,
    this.triggerTimeMs,
  });
}

class SimBroker {
  final List<SimOrder> orders = [];
  int positionQty = 0;
  double positionAvg = 0;
  double realizedPnl = 0;
  int _nextId = 1;

  void reset() {
    orders.clear();
    positionQty = 0;
    positionAvg = 0;
    realizedPnl = 0;
    _nextId = 1;
  }

  List<SimOrder> get activeOrders =>
      orders.where((o) => o.isActive).toList();

  List<SimOrder> get doneOrders =>
      orders.where((o) => !o.isActive).toList().reversed.toList();

  double get invested => positionQty * positionAvg;

  double unrealizedPnl(double ltp) =>
      positionQty == 0 ? 0 : (ltp - positionAvg) * positionQty;

  /// Place an order. MARKET orders are returned unfilled — the caller
  /// fills them with [fillMarket] at the live replay price so the
  /// fill price/time always come from the engine.
  SimOrder place({
    required String side,
    required int qty,
    required String triggerType,
    double? triggerPrice,
    int? triggerTimeMs,
  }) {
    final order = SimOrder(
      id: _nextId++,
      side: side,
      qty: qty,
      triggerType: triggerType,
      triggerPrice: triggerPrice,
      triggerTimeMs: triggerTimeMs,
    );
    orders.add(order);
    return order;
  }

  SimOrder placeDraft(OrderDraft draft) {
    return place(
      side: draft.side,
      qty: draft.qty,
      triggerType: draft.triggerType,
      triggerPrice: draft.triggerPrice,
      triggerTimeMs: draft.triggerTimeMs,
    );
  }

  /// Fill an order right now at [price]. Returns an error message
  /// when the fill is impossible (e.g. selling more than held).
  String? fillMarket(SimOrder order, double price, int timeMs) {
    if (!order.isActive) return 'Order is no longer active';
    if (price <= 0) return 'No replay price yet';
    return _applyFill(order, price, timeMs);
  }

  /// Fire any TIME / PRICE orders whose trigger the latest engine
  /// step crossed. Called by the replay screen on every step.
  void checkTriggers({
    required double prevPrice,
    required double price,
    required int timeMs,
  }) {
    for (final order in orders) {
      if (!order.isActive) continue;
      if (order.triggerType == 'TIME' && order.triggerTimeMs != null) {
        if (timeMs >= order.triggerTimeMs!) {
          _applyFill(order, price, timeMs);
        }
      } else if (order.triggerType == 'PRICE' &&
          order.triggerPrice != null) {
        final tp = order.triggerPrice!;
        final crossed = (prevPrice < tp && price >= tp) ||
            (prevPrice > tp && price <= tp) ||
            price == tp;
        if (crossed) {
          _applyFill(order, tp, timeMs);
        }
      }
    }
  }

  String? _applyFill(SimOrder order, double price, int timeMs) {
    if (order.isBuy) {
      final newQty = positionQty + order.qty;
      positionAvg =
          (positionQty * positionAvg + order.qty * price) / newQty;
      positionQty = newQty;
    } else {
      if (positionQty <= 0) {
        order.status = 'FAILED';
        order.note = 'No holdings to sell';
        return order.note;
      }
      if (order.qty > positionQty) {
        order.status = 'FAILED';
        order.note = 'Held only $positionQty qty';
        return order.note;
      }
      final pnl = (price - positionAvg) * order.qty;
      realizedPnl += pnl;
      order.realizedPnl = pnl;
      positionQty -= order.qty;
      if (positionQty == 0) positionAvg = 0;
    }
    order.status = 'EXECUTED';
    order.fillPrice = price;
    order.fillTimeMs = timeMs;
    return null;
  }

  void cancel(int orderId) {
    final order = _byId(orderId);
    if (order != null && order.isActive) {
      order.status = 'CANCELLED';
    }
  }

  /// Modify an ACTIVE order's qty and/or trigger. Returns an error
  /// message, or null on success.
  String? modify(
    int orderId, {
    int? qty,
    double? triggerPrice,
    int? triggerTimeMs,
  }) {
    final order = _byId(orderId);
    if (order == null) return 'Order not found';
    if (!order.isActive) return 'Only active orders can be changed';
    if (qty != null) {
      if (qty <= 0) return 'Quantity must be more than 0';
      order.qty = qty;
    }
    if (triggerPrice != null) {
      if (triggerPrice <= 0) return 'Price must be more than 0';
      order.triggerPrice = triggerPrice;
    }
    if (triggerTimeMs != null) {
      order.triggerTimeMs = triggerTimeMs;
    }
    return null;
  }

  /// Sell the whole position at the current replay price.
  String? exitAll(double price, int timeMs) {
    if (positionQty <= 0) return 'No position to exit';
    final order = place(side: 'S', qty: positionQty, triggerType: 'MARKET');
    return fillMarket(order, price, timeMs);
  }

  SimOrder? _byId(int id) {
    for (final o in orders) {
      if (o.id == id) return o;
    }
    return null;
  }
}
