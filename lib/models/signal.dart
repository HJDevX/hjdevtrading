import 'dart:convert';

/// SIGNAL MATHS — the user's own small maths language for signals
/// (design: HJ_Signal_Maths_Language_Design.md).
///
/// A SIGNAL is one stock + one action (BUY/SELL, qty, TP, SL).
/// Inside it: INDICATORS, each holding MATHS LINES. Every line is
///   [ LEFT maths ] [ COMPARE sign ] [ RIGHT maths ]  → TRUE/FALSE
/// Indicator weights follow the ratio rule (equal by default, total
/// always 100%). Signals are stored as DATA (JSON in the local DB),
/// never as code — this file is that stored form plus the term
/// catalogue the tap-builder offers.
///
/// This step is create + save only: no live engine watches these
/// yet, and creating a signal places no trades.

// ---------------- Terms ----------------

/// One pickable term: its short code (what formulas show), its full
/// name (what the picker list shows) and its data type. Types are
/// enforced while building: a line's two sides must be the same
/// type, or one of them a plain NUMBER.
class SignalTerm {
  final String code;
  final String label;
  final String type; // PRICE | PERCENT | TIME | VOLUME | NUMBER
  const SignalTerm(this.code, this.label, this.type);
}

/// The v1 term catalogue: the design's §6a terms plus the
/// price/time/volume families that today's data can already fill.
/// (Candle and indicator families — RSI, EMA… — arrive with the
/// 1-minute candle store.)
const List<SignalTerm> kSignalTerms = [
  // PRICE
  SignalTerm('PRICE', 'Stock Price (live / LTP)', 'PRICE'),
  SignalTerm('OPEN', 'Today Opening Price', 'PRICE'),
  SignalTerm('HIGH', 'Today High Price (so far)', 'PRICE'),
  SignalTerm('LOW', 'Today Low Price (so far)', 'PRICE'),
  SignalTerm('PREV_CLOSE', 'Previous Day Close Price', 'PRICE'),
  SignalTerm('PREV_OPEN', 'Previous Day Opening Price', 'PRICE'),
  SignalTerm('PREV_HIGH', 'Previous Day High Price', 'PRICE'),
  SignalTerm('PREV_LOW', 'Previous Day Low Price', 'PRICE'),
  // PERCENT (ready-made)
  SignalTerm('CHANGE_PCT', 'Change % (Price vs Prev Close)', 'PERCENT'),
  SignalTerm('GAP_PCT', 'Gap % (Open vs Prev Close)', 'PERCENT'),
  SignalTerm('DAY_POSITION_PCT', 'Day Position % (Price in Low–High)', 'PERCENT'),
  SignalTerm('DIST_FROM_HIGH_PCT', 'Distance from High %', 'PERCENT'),
  SignalTerm('DIST_FROM_LOW_PCT', 'Distance from Low %', 'PERCENT'),
  // TIME
  SignalTerm('TIME_NOW', 'Current Time', 'TIME'),
  SignalTerm('HIGH_TIME', 'Today High Price Time', 'TIME'),
  SignalTerm('LOW_TIME', 'Today Low Price Time', 'TIME'),
  // VOLUME
  SignalTerm('VOLUME', 'Volume Today (so far)', 'VOLUME'),
  SignalTerm('OPEN_VOLUME', 'Opening Volume (first 5-min candle)', 'VOLUME'),
  SignalTerm('PREV_VOLUME', 'Previous Day Volume', 'VOLUME'),
  SignalTerm('AVG_VOLUME_10D', 'Average Volume, 10 Days', 'VOLUME'),
  // NUMBER
  SignalTerm('MINUTES_SINCE_OPEN', 'Minutes Since Market Open', 'NUMBER'),
  SignalTerm('MINUTES_TO_CLOSE', 'Minutes To Market Close', 'NUMBER'),
  SignalTerm('DAY_OF_WEEK', 'Day of Week (1=Mon … 5=Fri)', 'NUMBER'),
];

SignalTerm? signalTermByCode(String code) {
  for (final t in kSignalTerms) {
    if (t.code == code) return t;
  }
  return null;
}

/// Compare signs a maths line can end with (design §5b).
const List<String> kCompareOps = [
  '>=',
  '<=',
  '>',
  '<',
  '=',
  '!=',
  'CROSSED_ABOVE',
  'CROSSED_BELOW',
  'TOUCHED',
  'BETWEEN',
  'OUTSIDE',
];

String compareLabel(String op) {
  switch (op) {
    case 'CROSSED_ABOVE':
      return 'crossed above';
    case 'CROSSED_BELOW':
      return 'crossed below';
    case 'TOUCHED':
      return 'touched';
    case 'BETWEEN':
      return 'between';
    case 'OUTSIDE':
      return 'outside';
    default:
      return op;
  }
}

/// The compare sign in plain words — what must happen for the
/// line's answer to be TRUE.
String compareMeaning(String op) {
  switch (op) {
    case '>=':
      return 'the left side is at least the right side';
    case '>':
      return 'the left side is more than the right side';
    case '<=':
      return 'the left side is at most the right side';
    case '<':
      return 'the left side is less than the right side';
    case '=':
      return 'the left side equals the right side';
    case '!=':
      return 'the left side is not equal to the right side';
    case 'CROSSED_ABOVE':
      return 'the left side was below the right side and now goes above it';
    case 'CROSSED_BELOW':
      return 'the left side was above the right side and now goes below it';
    case 'TOUCHED':
      return 'the left side touched the right level at any point today';
    case 'BETWEEN':
      return 'the left side is between the right side and the upper bound';
    case 'OUTSIDE':
      return 'the left side is outside the right side and the upper bound';
    default:
      return '';
  }
}

String fmtClock(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final hh = h % 12 == 0 ? 12 : h % 12;
  final ap = h < 12 ? 'AM' : 'PM';
  return '$hh:${m.toString().padLeft(2, '0')} $ap';
}

String fmtClockShort(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

// ---------------- Maths atoms & sides ----------------

/// One piece of a maths side: a TERM, a typed NUMBER, a clock TIME,
/// or PCT_CHANGE(term, term).
class MathsAtom {
  final String kind; // TERM | NUMBER | TIME | PCT_CHANGE
  final String? term; // for TERM
  final double? number; // for NUMBER
  final int? timeMinutes; // for TIME (minutes of day: 10:15 = 615)
  final String? pctA; // for PCT_CHANGE: (pctA − pctB) / pctB × 100
  final String? pctB;

  const MathsAtom({
    required this.kind,
    this.term,
    this.number,
    this.timeMinutes,
    this.pctA,
    this.pctB,
  });

  factory MathsAtom.term(String code) => MathsAtom(kind: 'TERM', term: code);
  factory MathsAtom.number(double v) => MathsAtom(kind: 'NUMBER', number: v);
  factory MathsAtom.time(int minutes) =>
      MathsAtom(kind: 'TIME', timeMinutes: minutes);
  factory MathsAtom.pctChange(String a, String b) =>
      MathsAtom(kind: 'PCT_CHANGE', pctA: a, pctB: b);

  /// The data type this atom produces.
  String get type {
    switch (kind) {
      case 'TERM':
        return signalTermByCode(term ?? '')?.type ?? 'NUMBER';
      case 'TIME':
        return 'TIME';
      case 'PCT_CHANGE':
        return 'PERCENT';
      default:
        return 'NUMBER';
    }
  }

  String render() {
    switch (kind) {
      case 'TERM':
        return term ?? '?';
      case 'NUMBER':
        final v = number ?? 0;
        return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
      case 'TIME':
        return fmtClockShort(timeMinutes ?? 0);
      case 'PCT_CHANGE':
        return 'PCT_CHANGE(${pctA ?? '?'}, ${pctB ?? '?'})';
      default:
        return '?';
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (term != null) 'term': term,
        if (number != null) 'number': number,
        if (timeMinutes != null) 'time': timeMinutes,
        if (pctA != null) 'pctA': pctA,
        if (pctB != null) 'pctB': pctB,
      };

  factory MathsAtom.fromJson(Map<String, dynamic> j) => MathsAtom(
        kind: j['kind']?.toString() ?? 'NUMBER',
        term: j['term']?.toString(),
        number: (j['number'] as num?)?.toDouble(),
        timeMinutes: (j['time'] as num?)?.toInt(),
        pctA: j['pctA']?.toString(),
        pctB: j['pctB']?.toString(),
      );
}

/// One side of a maths line: atoms joined by maths signs
/// (+ − × ÷), calculated left to right with × ÷ before + −
/// by the future engine. Stored exactly as built.
class MathsSide {
  final List<MathsAtom> atoms;
  final List<String> ops; // between atoms; length = atoms.length − 1

  const MathsSide({this.atoms = const [], this.ops = const []});

  bool get isEmpty => atoms.isEmpty;

  /// The side's data type: the type of its first non-NUMBER atom,
  /// or NUMBER when the side is only typed numbers.
  String get type {
    for (final a in atoms) {
      if (a.type != 'NUMBER') return a.type;
    }
    return 'NUMBER';
  }

  String render() {
    if (atoms.isEmpty) return '…';
    final b = StringBuffer(atoms.first.render());
    for (var i = 0; i < ops.length && i + 1 < atoms.length; i++) {
      final op = ops[i] == '*' ? '×' : (ops[i] == '/' ? '÷' : ops[i]);
      b.write(' $op ${atoms[i + 1].render()}');
    }
    return b.toString();
  }

  /// The same side as typeable text for the Stock IDE editor
  /// (plain * and / signs, term codes, HH:MM times) — the parser
  /// reads this exact form back into the same stored side.
  String get formula {
    if (atoms.isEmpty) return '';
    final b = StringBuffer(atoms.first.render());
    for (var i = 0; i < ops.length && i + 1 < atoms.length; i++) {
      b.write(' ${ops[i]} ${atoms[i + 1].render()}');
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'atoms': atoms.map((a) => a.toJson()).toList(),
        'ops': ops,
      };

  factory MathsSide.fromJson(Map<String, dynamic> j) => MathsSide(
        atoms: ((j['atoms'] as List?) ?? [])
            .map((e) => MathsAtom.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(),
        ops: ((j['ops'] as List?) ?? []).map((e) => e.toString()).toList(),
      );
}

/// Two sides can be compared when their types match, or when one
/// of them is a plain NUMBER (design §4).
bool signalTypesCompatible(String a, String b) =>
    a == b || a == 'NUMBER' || b == 'NUMBER';

// ---------------- Lines, indicators, signal ----------------

/// One maths line: LEFT compare RIGHT (→ TRUE/FALSE). BETWEEN and
/// OUTSIDE use a second right side as the upper bound.
class SignalLine {
  final MathsSide left;
  final String compare;
  final MathsSide right;
  final MathsSide? right2;
  final double weightPct; // share inside its indicator (equal default)

  const SignalLine({
    required this.left,
    required this.compare,
    required this.right,
    this.right2,
    this.weightPct = 0,
  });

  bool get needsRight2 => compare == 'BETWEEN' || compare == 'OUTSIDE';

  bool get isComplete =>
      !left.isEmpty &&
      !right.isEmpty &&
      (!needsRight2 || (right2 != null && !right2!.isEmpty));

  /// Null when the line's types are fine, else the problem in words.
  String? get typeError {
    if (left.isEmpty || right.isEmpty) return null;
    if (!signalTypesCompatible(left.type, right.type)) {
      return 'Left side is ${left.type} but right side is ${right.type} — they must match';
    }
    if (needsRight2 && right2 != null && !right2!.isEmpty) {
      if (!signalTypesCompatible(left.type, right2!.type)) {
        return 'Upper bound is ${right2!.type} but the left side is ${left.type} — they must match';
      }
    }
    return null;
  }

  String render() {
    final base = '${left.render()} ${compareLabel(compare)} ${right.render()}';
    if (needsRight2) return '$base and ${right2?.render() ?? '…'}';
    return base;
  }

  /// The whole line as typeable text for the Stock IDE editor.
  String get formula {
    final base = '${left.formula} $compare ${right.formula}';
    if (needsRight2) return '$base AND ${right2?.formula ?? ''}';
    return base;
  }

  SignalLine copyWith({double? weightPct}) => SignalLine(
        left: left,
        compare: compare,
        right: right,
        right2: right2,
        weightPct: weightPct ?? this.weightPct,
      );

  Map<String, dynamic> toJson() => {
        'left': left.toJson(),
        'compare': compare,
        'right': right.toJson(),
        if (right2 != null) 'right2': right2!.toJson(),
        'weightPct': weightPct,
      };

  factory SignalLine.fromJson(Map<String, dynamic> j) => SignalLine(
        left: MathsSide.fromJson(
            Map<String, dynamic>.from(j['left'] as Map? ?? {})),
        compare: j['compare']?.toString() ?? '>=',
        right: MathsSide.fromJson(
            Map<String, dynamic>.from(j['right'] as Map? ?? {})),
        right2: j['right2'] == null
            ? null
            : MathsSide.fromJson(
                Map<String, dynamic>.from(j['right2'] as Map)),
        weightPct: (j['weightPct'] as num?)?.toDouble() ?? 0,
      );
}

/// A group of maths lines with one job (Gap Check, Time Check…),
/// carrying a weight % of the signal (ratio rule, design §7a).
class SignalIndicator {
  final String name;
  final double weightPct;
  final bool locked;
  final bool weightManual; // user set this % by hand
  final List<SignalLine> lines;

  const SignalIndicator({
    required this.name,
    required this.weightPct,
    this.locked = false,
    this.weightManual = false,
    this.lines = const [],
  });

  SignalIndicator copyWith({
    String? name,
    double? weightPct,
    bool? locked,
    bool? weightManual,
    List<SignalLine>? lines,
  }) =>
      SignalIndicator(
        name: name ?? this.name,
        weightPct: weightPct ?? this.weightPct,
        locked: locked ?? this.locked,
        weightManual: weightManual ?? this.weightManual,
        lines: lines ?? this.lines,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'weightPct': weightPct,
        'locked': locked,
        'weightManual': weightManual,
        'lines': lines.map((l) => l.toJson()).toList(),
      };

  factory SignalIndicator.fromJson(Map<String, dynamic> j) =>
      SignalIndicator(
        name: j['name']?.toString() ?? 'Indicator',
        weightPct: (j['weightPct'] as num?)?.toDouble() ?? 0,
        locked: j['locked'] == true,
        weightManual: j['weightManual'] == true,
        lines: ((j['lines'] as List?) ?? [])
            .map((e) =>
                SignalLine.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// A saved signal: one stock + one action + its indicators.
class SignalDef {
  final int? id;
  final String name;
  final String symbol;
  final String exchange; // segment, e.g. nse_cm
  final String? token;
  final String displayName;
  final String? instrumentType;
  final String side; // 'B' buy | 'S' sell/short
  final int qty;
  final double? tpPct;
  final double? slPct;
  final bool enabled;
  final List<SignalIndicator> indicators;
  final int createdMs;
  final int updatedMs;

  const SignalDef({
    this.id,
    required this.name,
    required this.symbol,
    required this.exchange,
    this.token,
    required this.displayName,
    this.instrumentType,
    required this.side,
    required this.qty,
    this.tpPct,
    this.slPct,
    this.enabled = true,
    required this.indicators,
    required this.createdMs,
    required this.updatedMs,
  });

  bool get isBuy => side == 'B';
  int get lineCount =>
      indicators.fold(0, (sum, i) => sum + i.lines.length);
  double get totalWeight =>
      indicators.fold(0.0, (sum, i) => sum + i.weightPct);

  SignalDef copyWith({bool? enabled, int? id}) => SignalDef(
        id: id ?? this.id,
        name: name,
        symbol: symbol,
        exchange: exchange,
        token: token,
        displayName: displayName,
        instrumentType: instrumentType,
        side: side,
        qty: qty,
        tpPct: tpPct,
        slPct: slPct,
        enabled: enabled ?? this.enabled,
        indicators: indicators,
        createdMs: createdMs,
        updatedMs: updatedMs,
      );

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'symbol': symbol,
      'exchange': exchange,
      'token': token,
      'display_name': displayName,
      'instrument_type': instrumentType,
      'side': side,
      'qty': qty,
      'tp_pct': tpPct,
      'sl_pct': slPct,
      'enabled': enabled ? 1 : 0,
      'body': jsonEncode({
        'indicators': indicators.map((i) => i.toJson()).toList(),
      }),
      'created_ms': createdMs,
      'updated_ms': updatedMs,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory SignalDef.fromMap(Map<String, dynamic> map) {
    var indicators = <SignalIndicator>[];
    try {
      final body = jsonDecode(map['body']?.toString() ?? '{}');
      if (body is Map) {
        indicators = ((body['indicators'] as List?) ?? [])
            .map((e) => SignalIndicator.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {
      indicators = [];
    }
    return SignalDef(
      id: map['id'] as int?,
      name: map['name']?.toString() ?? '',
      symbol: map['symbol']?.toString() ?? '',
      exchange: map['exchange']?.toString() ?? 'nse_cm',
      token: map['token']?.toString(),
      displayName: map['display_name']?.toString() ?? '',
      instrumentType: map['instrument_type']?.toString(),
      side: map['side']?.toString() ?? 'B',
      qty: (map['qty'] as num?)?.toInt() ?? 1,
      tpPct: (map['tp_pct'] as num?)?.toDouble(),
      slPct: (map['sl_pct'] as num?)?.toDouble(),
      enabled: (map['enabled'] as num?)?.toInt() != 0,
      indicators: indicators,
      createdMs: (map['created_ms'] as num?)?.toInt() ?? 0,
      updatedMs: (map['updated_ms'] as num?)?.toInt() ?? 0,
    );
  }
}
