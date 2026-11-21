/// One row of the Kotak scrip master (the market's full instrument list),
/// as stored in the local `scrips` table after a Refresh download.
class Scrip {
  final int? id;
  final String token;
  final String symbol;
  final String displayName;
  final String segment; // nse_cm, bse_cm, nse_fo, mcx_fo
  final String exchange; // NSE, BSE, MCX
  final String instrumentType; // EQ, FUT, CE, PE, INDEX
  final String? underlying;
  final String? expiry;
  final double? strike;
  final int? lotSize;
  final double? tickSize;

  Scrip({
    this.id,
    required this.token,
    required this.symbol,
    required this.displayName,
    required this.segment,
    required this.exchange,
    required this.instrumentType,
    this.underlying,
    this.expiry,
    this.strike,
    this.lotSize,
    this.tickSize,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'token': token,
      'symbol': symbol,
      'display_name': displayName,
      'segment': segment,
      'exchange': exchange,
      'instrument_type': instrumentType,
      'underlying': underlying,
      'expiry': expiry,
      'strike': strike,
      'lot_size': lotSize,
      'tick_size': tickSize,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory Scrip.fromMap(Map<String, dynamic> map) {
    return Scrip(
      id: map['id'] as int?,
      token: map['token']?.toString() ?? '',
      symbol: map['symbol']?.toString() ?? '',
      displayName: map['display_name']?.toString() ?? '',
      segment: map['segment']?.toString() ?? 'nse_cm',
      exchange: map['exchange']?.toString() ?? 'NSE',
      instrumentType: map['instrument_type']?.toString() ?? 'EQ',
      underlying: map['underlying']?.toString(),
      expiry: map['expiry']?.toString(),
      strike: map['strike'] != null ? (map['strike'] as num).toDouble() : null,
      lotSize: map['lot_size'] != null ? (map['lot_size'] as num).toInt() : null,
      tickSize:
          map['tick_size'] != null ? (map['tick_size'] as num).toDouble() : null,
    );
  }
}
