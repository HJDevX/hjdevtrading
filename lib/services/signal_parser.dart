import 'package:hjdev_trading/models/signal.dart';

/// STOCK IDE parser — reads a maths line typed as text into the
/// exact same stored form the tap-builder produces (design §10):
///
///   PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7
///   PRICE >= OPEN
///   TIME_NOW >= 10:15
///   VOLUME > AVG_VOLUME_10D * 1.5
///   PRICE BETWEEN 350 AND 400
///
/// A side is atoms (term / number / clock time / PCT_CHANGE)
/// joined by + − × ÷. Brackets are only supported inside
/// PCT_CHANGE(...). Every failure comes back as a friendly,
/// specific message — the parser never guesses.
class SignalParseResult {
  final SignalLine? line;
  final String? error;
  const SignalParseResult.ok(this.line) : error = null;
  const SignalParseResult.fail(this.error) : line = null;
}

const Set<String> _compareWords = {
  'CROSSED_ABOVE',
  'CROSSED_BELOW',
  'TOUCHED',
  'BETWEEN',
  'OUTSIDE',
};

class _Tok {
  final String kind; // num | time | ident | op | cmp | lparen | rparen | comma
  final String text;
  final double? numValue;
  final int? timeMinutes;
  const _Tok(this.kind, this.text, {this.numValue, this.timeMinutes});
}

class _LexError implements Exception {
  final String message;
  _LexError(this.message);
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 48 && u <= 57;
}

bool _isLetter(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || c == '_';
}

List<_Tok> _lex(String input) {
  final toks = <_Tok>[];
  var i = 0;
  while (i < input.length) {
    final c = input[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    if (_isDigit(c)) {
      // Number, or a clock time HH:MM.
      var j = i;
      while (j < input.length && _isDigit(input[j])) j++;
      if (j + 1 < input.length && input[j] == ':' && _isDigit(input[j + 1])) {
        var k = j + 1;
        while (k < input.length && _isDigit(input[k])) k++;
        final h = int.parse(input.substring(i, j));
        final m = int.parse(input.substring(j + 1, k));
        if (h > 23 || m > 59) {
          throw _LexError(
              '"${input.substring(i, k)}" is not a valid clock time');
        }
        toks.add(_Tok('time', input.substring(i, k), timeMinutes: h * 60 + m));
        i = k;
        continue;
      }
      var k = j;
      if (k < input.length && input[k] == '.') {
        k++;
        while (k < input.length && _isDigit(input[k])) k++;
      }
      final text = input.substring(i, k);
      final v = double.tryParse(text);
      if (v == null) throw _LexError('"$text" is not a valid number');
      toks.add(_Tok('num', text, numValue: v));
      i = k;
      continue;
    }
    if (_isLetter(c)) {
      var j = i;
      while (j < input.length && (_isLetter(input[j]) || _isDigit(input[j]))) {
        j++;
      }
      toks.add(_Tok('ident', input.substring(i, j).toUpperCase()));
      i = j;
      continue;
    }
    switch (c) {
      case '>':
      case '<':
        if (i + 1 < input.length && input[i + 1] == '=') {
          toks.add(_Tok('cmp', '$c='));
          i += 2;
        } else {
          toks.add(_Tok('cmp', c));
          i++;
        }
        break;
      case '=':
        toks.add(const _Tok('cmp', '='));
        i++;
        break;
      case '!':
        if (i + 1 < input.length && input[i + 1] == '=') {
          toks.add(const _Tok('cmp', '!='));
          i += 2;
        } else {
          throw _LexError('"!" alone means nothing — did you mean "!=" ?');
        }
        break;
      case '+':
      case '-':
        toks.add(_Tok('op', c));
        i++;
        break;
      case '*':
      case '×':
        toks.add(const _Tok('op', '*'));
        i++;
        break;
      case '/':
      case '÷':
        toks.add(const _Tok('op', '/'));
        i++;
        break;
      case '(':
        toks.add(const _Tok('lparen', '('));
        i++;
        break;
      case ')':
        toks.add(const _Tok('rparen', ')'));
        i++;
        break;
      case ',':
        toks.add(const _Tok('comma', ','));
        i++;
        break;
      default:
        throw _LexError('I don\'t understand the character "$c"');
    }
  }
  return toks;
}

class _Parser {
  final List<_Tok> toks;
  var pos = 0;
  _Parser(this.toks);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;

  bool get _atCompare {
    final t = _peek;
    if (t == null) return false;
    if (t.kind == 'cmp') return true;
    return t.kind == 'ident' && _compareWords.contains(t.text);
  }

  MathsAtom _parseAtom() {
    final t = _peek;
    if (t == null) {
      throw _LexError('The line ends suddenly — something is missing');
    }
    // A leading minus before a number makes a negative number.
    if (t.kind == 'op' && t.text == '-') {
      final next = pos + 1 < toks.length ? toks[pos + 1] : null;
      if (next != null && next.kind == 'num') {
        pos += 2;
        return MathsAtom.number(-next.numValue!);
      }
      throw _LexError('A minus sign here needs a number after it');
    }
    switch (t.kind) {
      case 'num':
        pos++;
        return MathsAtom.number(t.numValue!);
      case 'time':
        pos++;
        return MathsAtom.time(t.timeMinutes!);
      case 'ident':
        if (_compareWords.contains(t.text) || t.text == 'AND') {
          throw _LexError(
              '"${t.text}" is a compare word — it belongs after the left side');
        }
        if (t.text == 'PCT_CHANGE') {
          pos++;
          if (_peek?.kind != 'lparen') {
            throw _LexError(
                'PCT_CHANGE needs brackets: PCT_CHANGE(OPEN, PREV_CLOSE)');
          }
          pos++;
          final a = _peek;
          if (a == null || a.kind != 'ident' ||
              signalTermByCode(a.text) == null) {
            throw _LexError(
                'Inside PCT_CHANGE, first pick a term like OPEN');
          }
          pos++;
          if (_peek?.kind != 'comma') {
            throw _LexError(
                'PCT_CHANGE needs a comma: PCT_CHANGE(OPEN, PREV_CLOSE)');
          }
          pos++;
          final b = _peek;
          if (b == null || b.kind != 'ident' ||
              signalTermByCode(b.text) == null) {
            throw _LexError(
                'Inside PCT_CHANGE, after the comma pick the base term like PREV_CLOSE');
          }
          pos++;
          if (_peek?.kind != 'rparen') {
            throw _LexError('PCT_CHANGE is missing its closing bracket ")"');
          }
          pos++;
          return MathsAtom.pctChange(a.text, b.text);
        }
        final term = signalTermByCode(t.text);
        if (term == null) {
          throw _LexError(
              'Unknown term "${t.text}" — tap one of the suggested terms');
        }
        pos++;
        return MathsAtom.term(t.text);
      case 'lparen':
        throw _LexError(
            'Brackets are only used inside PCT_CHANGE(...) for now');
      default:
        throw _LexError('Expected a term, number or time, found "${t.text}"');
    }
  }

  MathsSide _parseSide() {
    final atoms = <MathsAtom>[_parseAtom()];
    final ops = <String>[];
    while (_peek != null && _peek!.kind == 'op') {
      final op = _peek!.text;
      pos++;
      ops.add(op);
      atoms.add(_parseAtom());
    }
    return MathsSide(atoms: atoms, ops: ops);
  }

  SignalLine parse() {
    final left = _parseSide();
    if (!_atCompare) {
      final t = _peek;
      if (t == null) {
        throw _LexError(
            'This line\'s answer is not TRUE or FALSE yet — it needs a compare sign (>=, >, = …) and a right side');
      }
      throw _LexError(
          'After the left side I expected a compare sign (>=, >, = …), but found "${t.text}"');
    }
    final cmpTok = toks[pos++];
    final compare = cmpTok.text;
    final right = _parseSide();
    MathsSide? right2;
    if (compare == 'BETWEEN' || compare == 'OUTSIDE') {
      final t = _peek;
      if (t == null || t.kind != 'ident' || t.text != 'AND') {
        throw _LexError(
            '$compare needs AND and an upper bound: PRICE $compare 350 AND 400');
      }
      pos++;
      right2 = _parseSide();
    }
    if (pos < toks.length) {
      throw _LexError(
          'Extra words at the end ("${toks[pos].text}") — one line is LEFT compare RIGHT');
    }
    return SignalLine(
      left: left,
      compare: compare,
      right: right,
      right2: right2,
    );
  }
}

/// Parse one typed maths line. On success the line is complete
/// and type-checked; on failure [SignalParseResult.error] says
/// exactly what to fix, in plain words.
SignalParseResult parseSignalLine(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    return const SignalParseResult.fail(
        'Type a maths line, e.g. PRICE >= OPEN');
  }
  try {
    final toks = _lex(text);
    final line = _Parser(toks).parse();
    if (!line.isComplete) {
      return const SignalParseResult.fail('The line is not complete yet');
    }
    final typeErr = line.typeError;
    if (typeErr != null) return SignalParseResult.fail(typeErr);
    return SignalParseResult.ok(line);
  } on _LexError catch (e) {
    return SignalParseResult.fail(e.message);
  } catch (_) {
    return const SignalParseResult.fail(
        'Something in this line could not be read — check it and try again');
  }
}
