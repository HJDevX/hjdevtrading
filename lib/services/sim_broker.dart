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
/// A BUY order can also carry a TARGET — a price, or a % above the
/// fill. The moment the buy fills, a linked TARGET sell order is
/// armed for the same qty; when the replay price reaches the target
/// it sells automatically. Target orders appear in the active list
/// and can be modified or cancelled like any other order.
///
/// Active orders can be modified (qty / trigger price / trigger
/// time) or cancelled before they fire. Fills follow the app's usual
/// paper rules: buys average in, sells need holdings and book
/// realized P&L. Nothing here touches the real paper tables.
class SimOrder {
  final int id;
  String side; // 'B' or 'S'
  int qty;
  String triggerType; // 'MARKET' | 'TIME' | 'PRICE' | 'TARGET'
  double? triggerPrice;
  int? triggerTimeMs;
  String status; // 'ACTIVE' | 'EXECUTED' | 'CANCELLED' | 'FAILED'
  double? fillPrice;
  int? fillTimeMs;
  double realizedPnl;
  String? note;

  /// Target chosen on a BUY order: an exact price, or a % above the
  /// fill price. When the buy fills, a TARGET sell is armed from
  /// these (see [parentId] on the armed order).
  double? targetPrice;
  double? targetPct;

  /// On an armed TARGET order: the id of the BUY order that made it.
  int? parentId;

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
    this.targetPrice,
    this.targetPct,
    this.parentId,
  });

  bool get isBuy => side == 'B';
  bool get isActive => status == 'ACTIVE';

  bool get hasTarget => targetPrice != null || targetPct != null;

  String get triggerText {
    switch (triggerType) {
      case 'TIME':
        return 'at time';
      case 'PRICE':
        return 'at ₹${triggerPrice?.toStringAsFixed(2) ?? '—'}';
      case 'TARGET':
        return 'target ₹${triggerPrice?.toStringAsFixed(2) ?? '—'}';
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

  /// Optional target on a BUY: exact price, or % above the fill.
  double? targetPrice;
  double? targetPct;

  OrderDraft({
    required this.side,
    required this.qty,
    required this.triggerType,
    this.triggerPrice,
    this.triggerTimeMs,
    this.targetPrice,
    this.targetPct,
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
    double? targetPrice,
    double? targetPct,
    int? parentId,
  }) {
    final order = SimOrder(
      id: _nextId++,
      side: side,
      qty: qty,
      triggerType: triggerType,
      triggerPrice: triggerPrice,
      triggerTimeMs: triggerTimeMs,
      targetPrice: targetPrice,
      targetPct: targetPct,
      parentId: parentId,
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
      targetPrice: draft.targetPrice,
      targetPct: draft.targetPct,
    );
  }

  /// Fill an order right now at [price]. Returns an error message
  /// when the fill is impossible (e.g. selling more than held).
  String? fillMarket(SimOrder order, double price, int timeMs) {
    if (!order.isActive) return 'Order is no longer active';
    if (price <= 0) return 'No replay price yet';
    return _applyFill(order, price, timeMs);
  }

  /// Fire any TIME / PRICE / TARGET orders whose trigger the latest
  /// engine step crossed. Called by the replay screen on every step.
  /// Iterates a copy: a filling BUY may arm a new TARGET order.
  void checkTriggers({
    required double prevPrice,
    required double price,
    required int timeMs,
  }) {
    for (final order in List<SimOrder>.of(orders)) {
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
      } else if (order.triggerType == 'TARGET' &&
          order.triggerPrice != null) {
        // A target sells when the price RISES to it.
        if (price >= order.triggerPrice!) {
          _applyFill(order, order.triggerPrice!, timeMs);
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
    if (order.isBuy && order.hasTarget) {
      _armTarget(order, price);
    }
    return null;
  }

  /// Arm the automatic target sell for a filled BUY: same qty, at
  /// the chosen target price (or fill + target %).
  void _armTarget(SimOrder buyOrder, double fillPrice) {
    final tp = buyOrder.targetPrice ??
        (buyOrder.targetPct != null
            ? fillPrice * (1 + buyOrder.targetPct! / 100)
            : null);
    if (tp == null || tp <= 0) return;
    place(
      side: 'S',
      qty: buyOrder.qty,
      triggerType: 'TARGET',
      triggerPrice: double.parse(tp.toStringAsFixed(2)),
      parentId: buyOrder.id,
    );
  }

  void cancel(int orderId) {
    final order = _byId(orderId);
    if (order != null && order.isActive) {
      order.status = 'CANCELLED';
    }
  }

  /// Modify an ACTIVE order's qty and/or trigger — and, for a BUY
  /// that has not filled yet, its target. Returns an error message,
  /// or null on success. Pass [clearTarget] to remove a buy's target.
  String? modify(
    int orderId, {
    int? qty,
    double? triggerPrice,
    int? triggerTimeMs,
    double? targetPrice,
    double? targetPct,
    bool clearTarget = false,
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
    if (clearTarget) {
      order.targetPrice = null;
      order.targetPct = null;
    }
    if (targetPrice != null) {
      if (targetPrice <= 0) return 'Target price must be more than 0';
      order.targetPrice = targetPrice;
      order.targetPct = null;
    }
    if (targetPct != null) {
      if (targetPct <= 0) return 'Target % must be more than 0';
      order.targetPct = targetPct;
      order.targetPrice = null;
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
