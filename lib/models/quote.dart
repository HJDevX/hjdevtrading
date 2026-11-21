/// One instrument's live price snapshot.
///
/// Built either from the Kotak REST quotes response (see
/// [Quote.fromMap]) or directly by the index feed with the plain
/// constructor.
class Quote {
  final String symbol;
  final String exchange; // segment, e.g. nse_cm
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

  /// Parses one entry of the official Kotak REST quotes response:
  /// ltp, per_change, last_volume, exchange_token, and an "ohlc" object
  /// whose "close" is the PREVIOUS close.
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

    final ohlc = map['ohlc'] is Map ? (map['ohlc'] as Map) : null;

    final ltp = parseDouble(map['ltp']);
    final open = parseDouble(ohlc?['open'] ?? map['open']);
    final high = parseDouble(ohlc?['high'] ?? map['high']);
    final low = parseDouble(ohlc?['low'] ?? map['low']);
    final prevClose = parseDouble(ohlc?['close'] ?? map['close']);
    final volume = parseInt(map['last_volume'] ?? map['volume']);

    final double pct;
    if (map['per_change'] != null) {
      pct = parseDouble(map['per_change']);
    } else if (prevClose > 0) {
      pct = ((ltp - prevClose) / prevClose) * 100.0;
    } else {
      pct = 0.0;
    }

    return Quote(
      symbol: symbol,
      exchange: exchange,
      token: (map['exchange_token'] ?? map['token'])?.toString(),
      ltp: ltp,
      open: open,
      high: high,
      low: low,
      prevClose: prevClose,
      volume: volume,
      changePct: pct,
    );
  }
}
