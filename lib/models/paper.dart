/// A PAPER (practice) order. Paper orders fill instantly at the latest
/// live price, are stored only on this phone, and are NEVER sent to Kotak.
class PaperOrder {
  final int? id;
  final String symbol;
  final String exchange; // segment
  final String? token;
  final String displayName;
  final String? instrumentType;
  final String side; // 'B' or 'S'
  final int qty;
  final double price;
  final double realizedPnl; // booked P&L for sell orders, else 0
  final int timeMs; // epoch milliseconds

  PaperOrder({
    this.id,
    required this.symbol,
    required this.exchange,
    this.token,
    required this.displayName,
    this.instrumentType,
    required this.side,
    required this.qty,
    required this.price,
    this.realizedPnl = 0,
    required this.timeMs,
  });

  bool get isBuy => side == 'B';
  double get value => qty * price;

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'symbol': symbol,
      'exchange': exchange,
      'token': token,
      'display_name': displayName,
      'instrument_type': instrumentType,
      'side': side,
      'qty': qty,
      'price': price,
      'realized_pnl': realizedPnl,
      'time_ms': timeMs,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory PaperOrder.fromMap(Map<String, dynamic> map) {
    return PaperOrder(
      id: map['id'] as int?,
      symbol: map['symbol'] as String,
      exchange: map['exchange'] as String? ?? 'nse_cm',
      token: map['token']?.toString(),
      displayName: map['display_name'] as String? ?? '',
      instrumentType: map['instrument_type'] as String?,
      side: map['side'] as String? ?? 'B',
      qty: (map['qty'] as num?)?.toInt() ?? 0,
      price: (map['price'] as num?)?.toDouble() ?? 0,
      realizedPnl: (map['realized_pnl'] as num?)?.toDouble() ?? 0,
      timeMs: (map['time_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A PAPER (practice) open position — what the user currently "holds".
class PaperPosition {
  final int? id;
  final String symbol;
  final String exchange; // segment
  final String? token;
  final String displayName;
  final String? instrumentType;
  final int? lotSize;
  final int qty;
  final double avgPrice;

  /// The last live price seen for this position, SAVED in the phone's
  /// local database. The Portfolio shows P&L from the live price when
  /// one is available and from this saved price otherwise (market
  /// closed, no network), so the P&L never disappears.
  final double? lastPrice;

  PaperPosition({
    this.id,
    required this.symbol,
    required this.exchange,
    this.token,
    required this.displayName,
    this.instrumentType,
    this.lotSize,
    required this.qty,
    required this.avgPrice,
    this.lastPrice,
  });

  double get invested => qty * avgPrice;

  /// Open (unrealized) P&L at [price] — live price if given, else the
  /// saved last price, else null (never priced yet).
  double? openPnl([double? price]) {
    final p = price ?? lastPrice;
    if (p == null) return null;
    return (p - avgPrice) * qty;
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'symbol': symbol,
      'exchange': exchange,
      'token': token,
      'display_name': displayName,
      'instrument_type': instrumentType,
      'lot_size': lotSize,
      'qty': qty,
      'avg_price': avgPrice,
      'last_price': lastPrice,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory PaperPosition.fromMap(Map<String, dynamic> map) {
    return PaperPosition(
      id: map['id'] as int?,
      symbol: map['symbol'] as String,
      exchange: map['exchange'] as String? ?? 'nse_cm',
      token: map['token']?.toString(),
      displayName: map['display_name'] as String? ?? '',
      instrumentType: map['instrument_type'] as String?,
      lotSize: map['lot_size'] != null ? (map['lot_size'] as num).toInt() : null,
      qty: (map['qty'] as num?)?.toInt() ?? 0,
      avgPrice: (map['avg_price'] as num?)?.toDouble() ?? 0,
      lastPrice: (map['last_price'] as num?)?.toDouble(),
    );
  }

  PaperPosition copyWith({int? qty, double? avgPrice, double? lastPrice}) {
    return PaperPosition(
      id: id,
      symbol: symbol,
      exchange: exchange,
      token: token,
      displayName: displayName,
      instrumentType: instrumentType,
      lotSize: lotSize,
      qty: qty ?? this.qty,
      avgPrice: avgPrice ?? this.avgPrice,
      lastPrice: lastPrice ?? this.lastPrice,
    );
  }
}


/// A PENDING paper order — placed from the watchlist dialogue with a
/// PRICE or TIME trigger instead of executing immediately. The
/// PendingOrderEngine watches live prices and the clock and fills
/// it through the PaperBroker when the trigger hits. A BUY entry can
/// carry a TARGET (an exit price, an exit % or an exact exit time);
/// when the entry fills, the engine arms the target as its own
/// pending SELL order (isTarget, linked by parentId).
class PaperPendingOrder {
  final int? id;
  final String symbol;
  final String exchange; // segment
  final String? token;
  final String displayName;
  final String? instrumentType;
  final int? lotSize;
  final String side; // 'B' or 'S'
  final int qty;

  /// 'PRICE' (fire when the live price touches [triggerPrice]) or
  /// 'TIME' (fire at [triggerTimeMs], whatever the price).
  final String triggerType;
  final double? triggerPrice;
  final int? triggerTimeMs;

  // Target plan (entry BUY orders only; copied onto the armed exit).
  final double? targetPrice;
  final double? targetPct;
  final int? targetTimeMs;

  /// 'ACTIVE', 'EXECUTED', 'CANCELLED' or 'FAILED'.
  final String status;
  final bool isTarget;
  final int? parentId;
  final int createdMs;
  final int? executedMs;
  final String? note; // failure reason, when FAILED

  PaperPendingOrder({
    this.id,
    required this.symbol,
    required this.exchange,
    this.token,
    required this.displayName,
    this.instrumentType,
    this.lotSize,
    required this.side,
    required this.qty,
    required this.triggerType,
    this.triggerPrice,
    this.triggerTimeMs,
    this.targetPrice,
    this.targetPct,
    this.targetTimeMs,
    this.status = 'ACTIVE',
    this.isTarget = false,
    this.parentId,
    required this.createdMs,
    this.executedMs,
    this.note,
  });

  bool get isBuy => side == 'B';
  bool get hasTarget =>
      targetPrice != null || targetPct != null || targetTimeMs != null;

  String get key => '$exchange|$token';

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'symbol': symbol,
      'exchange': exchange,
      'token': token,
      'display_name': displayName,
      'instrument_type': instrumentType,
      'lot_size': lotSize,
      'side': side,
      'qty': qty,
      'trigger_type': triggerType,
      'trigger_price': triggerPrice,
      'trigger_time_ms': triggerTimeMs,
      'target_price': targetPrice,
      'target_pct': targetPct,
      'target_time_ms': targetTimeMs,
      'status': status,
      'is_target': isTarget ? 1 : 0,
      'parent_id': parentId,
      'created_ms': createdMs,
      'executed_ms': executedMs,
      'note': note,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory PaperPendingOrder.fromMap(Map<String, dynamic> map) {
    return PaperPendingOrder(
      id: map['id'] as int?,
      symbol: map['symbol'] as String,
      exchange: map['exchange'] as String? ?? 'nse_cm',
      token: map['token']?.toString(),
      displayName: map['display_name'] as String? ?? '',
      instrumentType: map['instrument_type'] as String?,
      lotSize:
          map['lot_size'] != null ? (map['lot_size'] as num).toInt() : null,
      side: map['side'] as String? ?? 'B',
      qty: (map['qty'] as num?)?.toInt() ?? 0,
      triggerType: map['trigger_type'] as String? ?? 'PRICE',
      triggerPrice: (map['trigger_price'] as num?)?.toDouble(),
      triggerTimeMs: (map['trigger_time_ms'] as num?)?.toInt(),
      targetPrice: (map['target_price'] as num?)?.toDouble(),
      targetPct: (map['target_pct'] as num?)?.toDouble(),
      targetTimeMs: (map['target_time_ms'] as num?)?.toInt(),
      status: map['status'] as String? ?? 'ACTIVE',
      isTarget: (map['is_target'] as num?)?.toInt() == 1,
      parentId: (map['parent_id'] as num?)?.toInt(),
      createdMs: (map['created_ms'] as num?)?.toInt() ?? 0,
      executedMs: (map['executed_ms'] as num?)?.toInt(),
      note: map['note'] as String?,
    );
  }

  PaperPendingOrder copyWith({
    int? qty,
    String? triggerType,
    double? triggerPrice,
    int? triggerTimeMs,
    double? targetPrice,
    double? targetPct,
    int? targetTimeMs,
    String? status,
    int? executedMs,
    String? note,
    bool clearTriggerPrice = false,
    bool clearTriggerTime = false,
    bool clearTargetPrice = false,
    bool clearTargetPct = false,
    bool clearTargetTime = false,
    bool clearNote = false,
  }) {
    return PaperPendingOrder(
      id: id,
      symbol: symbol,
      exchange: exchange,
      token: token,
      displayName: displayName,
      instrumentType: instrumentType,
      lotSize: lotSize,
      side: side,
      qty: qty ?? this.qty,
      triggerType: triggerType ?? this.triggerType,
      triggerPrice:
          clearTriggerPrice ? null : (triggerPrice ?? this.triggerPrice),
      triggerTimeMs:
          clearTriggerTime ? null : (triggerTimeMs ?? this.triggerTimeMs),
      targetPrice:
          clearTargetPrice ? null : (targetPrice ?? this.targetPrice),
      targetPct: clearTargetPct ? null : (targetPct ?? this.targetPct),
      targetTimeMs:
          clearTargetTime ? null : (targetTimeMs ?? this.targetTimeMs),
      status: status ?? this.status,
      isTarget: isTarget,
      parentId: parentId,
      createdMs: createdMs,
      executedMs: executedMs ?? this.executedMs,
      note: clearNote ? null : (note ?? this.note),
    );
  }
}
