class Watchlist {
  final int? id;
  final String name;
  final int createdAt;

  Watchlist({
    this.id,
    required this.name,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'created_at': createdAt,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  factory Watchlist.fromMap(Map<String, dynamic> map) {
    return Watchlist(
      id: map['id'] as int?,
      name: map['name'] as String,
      createdAt: map['created_at'] as int,
    );
  }
}

class WatchItem {
  final int? id;
  final int watchlistId;
  final String symbol;
  final String exchange;
  final String? token;
  final String displayName;
  final String? instrumentType; // EQ / FUT / CE / PE
  final String? expiry;
  final double? strike;
  final int? lotSize;

  WatchItem({
    this.id,
    required this.watchlistId,
    required this.symbol,
    this.exchange = 'nse_cm',
    this.token,
    required this.displayName,
    this.instrumentType,
    this.expiry,
    this.strike,
    this.lotSize,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'watchlist_id': watchlistId,
      'symbol': symbol,
      'exchange': exchange,
      'token': token,
      'display_name': displayName,
      'instrument_type': instrumentType,
      'expiry': expiry,
      'strike': strike,
      'lot_size': lotSize,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }

  factory WatchItem.fromMap(Map<String, dynamic> map) {
    return WatchItem(
      id: map['id'] as int?,
      watchlistId: map['watchlist_id'] as int,
      symbol: map['symbol'] as String,
      exchange: map['exchange'] as String? ?? 'nse_cm',
      token: map['token'] as String?,
      displayName: map['display_name'] as String,
      instrumentType: map['instrument_type'] as String?,
      expiry: map['expiry'] as String?,
      strike: map['strike'] != null ? (map['strike'] as num).toDouble() : null,
      lotSize: map['lot_size'] != null ? (map['lot_size'] as num).toInt() : null,
    );
  }
}
