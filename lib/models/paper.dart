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
  });

  double get invested => qty * avgPrice;

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
    );
  }

  PaperPosition copyWith({int? qty, double? avgPrice}) {
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
    );
  }
}
