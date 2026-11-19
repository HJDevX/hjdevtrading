class Quote {
  final String symbol;
  final String exchange;
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

    final ltp = parseDouble(
      map['ltp'] ?? map['LTP'] ?? map['lastPrice'] ?? map['lp'],
    );
    final open = parseDouble(
      map['open'] ?? map['Open'] ?? map['op'],
    );
    final high = parseDouble(
      map['high'] ?? map['High'] ?? map['h'],
    );
    final low = parseDouble(
      map['low'] ?? map['Low'] ?? map['l'],
    );
    final prevClose = parseDouble(
      map['prevClose'] ??
          map['previousClose'] ??
          map['pClose'] ??
          map['close'] ??
          map['c'] ??
          map['closingPrice'],
    );
    final volume = parseInt(
      map['volume'] ??
          map['Volume'] ??
          map['vol'] ??
          map['totalTradedVolume'] ??
          map['ttv'],
    );

    double calculatedPct;
    if (prevClose > 0) {
      calculatedPct = ((ltp - prevClose) / prevClose) * 100.0;
    } else if (map.containsKey('changePct') || map.containsKey('pChange')) {
      calculatedPct = parseDouble(map['changePct'] ?? map['pChange']);
    } else {
      calculatedPct = 0.0;
    }

    return Quote(
      symbol: symbol,
      exchange: exchange,
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
