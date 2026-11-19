class Quote {
  final String symbol;
  final String exchange;
  final String? token;
  final double ltp;
  final double open;
  final double high;
  final double low;
  final double prevClose;
  final int volume;
  final double changePct;

  double get change => ltp - prevClose;

  Quote({
    required this.symbol,
    required this.exchange,
    this.token,
    required this.ltp,
    required this.open,
    required this.high,
    required this.low,
    required this.prevClose,
    required this.volume,
    double? changePct,
  }) : changePct = changePct ??
            (prevClose > 0 ? ((ltp - prevClose) / prevClose * 100) : 0.0);

  factory Quote.fromMap(
    Map<String, dynamic> map, {
    required String symbol,
    required String exchange,
  }) {
    double parseDouble(dynamic val, [double def = 0.0]) {
      if (val == null) return def;
      if (val is num) return val.toDouble();
      return double.tryParse(val.toString().replaceAll(',', '')) ?? def;
    }

    int parseInt(dynamic val, [int def = 0]) {
      if (val == null) return def;
      if (val is int) return val;
      if (val is num) return val.toInt();
      return int.tryParse(val.toString().replaceAll(',', '')) ?? def;
    }

    // Official Kotak Neo format has "ohlc" object:
    // ohlc.open, ohlc.high, ohlc.low, ohlc.close (where close = PREVIOUS close)
    final ohlc = map['ohlc'] is Map ? (map['ohlc'] as Map) : null;

    final ltp = parseDouble(
      map['ltp'] ?? map['LTP'] ?? map['lastPrice'] ?? map['lp'],
    );
    final open = parseDouble(
      ohlc?['open'] ?? map['open'] ?? map['Open'] ?? map['op'],
    );
    final high = parseDouble(
      ohlc?['high'] ?? map['high'] ?? map['High'] ?? map['h'],
    );
    final low = parseDouble(
      ohlc?['low'] ?? map['low'] ?? map['Low'] ?? map['l'],
    );
    final prevClose = parseDouble(
      ohlc?['close'] ??
          map['prevClose'] ??
          map['previousClose'] ??
          map['pClose'] ??
          map['close'] ??
          map['c'] ??
          map['closingPrice'],
    );
    final volume = parseInt(
      map['last_volume'] ??
          map['volume'] ??
          map['Volume'] ??
          map['vol'] ??
          map['totalTradedVolume'] ??
          map['ttv'],
    );

    // Official Kotak Neo format uses "per_change" for change% directly
    double calculatedPct;
    if (map.containsKey('per_change') && map['per_change'] != null) {
      calculatedPct = parseDouble(map['per_change']);
    } else if (map.containsKey('changePct') || map.containsKey('pChange')) {
      calculatedPct = parseDouble(map['changePct'] ?? map['pChange']);
    } else if (prevClose > 0) {
      calculatedPct = ((ltp - prevClose) / prevClose) * 100.0;
    } else {
      calculatedPct = 0.0;
    }

    final token = (map['exchange_token'] ?? map['token'])?.toString();

    return Quote(
      symbol: symbol,
      exchange: exchange,
      token: token,
      ltp: ltp,
      open: open,
      high: high,
      low: low,
      prevClose: prevClose,
      volume: volume,
      changePct: calculatedPct,
    );
  }
}
