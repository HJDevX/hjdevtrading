import 'package:hjdev_trading/models/signal.dart';

/// Syntax colouring for the Stock IDE — like a real programming
/// language editor, every kind of word gets its own colour:
///
///  - term      language terms (PRICE, OPEN, PREV_CLOSE…)
///  - variable  the signal's OWN variables (stockCurrent…) —
///              deliberately a different colour from terms
///  - number    typed numbers (0.7, 40…)
///  - time      clock times (10:15)
///  - keyword   PCT_CHANGE, AND, BETWEEN, CROSSED_ABOVE…
///  - operator  + − × ÷ and the compare signs >=, <, = …
///  - plain     spaces, brackets, commas
///  - unknown   a word the language does not know (a typo —
///              shown in red so it is easy to spot)
///
/// This file is pure Dart (no Flutter): it only splits text into
/// segments. The screens map each kind to a colour.
class SignalSegment {
  final String text;
  final String kind;
  const SignalSegment(this.text, this.kind);
}

const Set<String> _keywords = {
  'PCT_CHANGE',
  'AND',
  'CROSSED_ABOVE',
  'CROSSED_BELOW',
  'TOUCHED',
  'BETWEEN',
  'OUTSIDE',
};

bool _isDigitAt(String s, int i) {
  final u = s.codeUnitAt(i);
  return u >= 48 && u <= 57;
}

bool _isLetterAt(String s, int i) {
  final u = s.codeUnitAt(i);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || s[i] == '_';
}

/// Split [text] into coloured segments. The segments always add
/// up to exactly the input text, and this never throws — half-
/// typed words are coloured by their best guess, unknown words
/// as 'unknown'.
List<SignalSegment> signalSegments(String text,
    {List<SignalVariable> variables = const []}) {
  final varNames = {for (final v in variables) v.name.toUpperCase()};
  final out = <SignalSegment>[];
  var i = 0;
  void add(String t, String kind) {
    if (t.isNotEmpty) out.add(SignalSegment(t, kind));
  }

  while (i < text.length) {
    final c = text[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      var j = i;
      while (j < text.length &&
          (text[j] == ' ' ||
              text[j] == '\t' ||
              text[j] == '\n' ||
              text[j] == '\r')) {
        j++;
      }
      add(text.substring(i, j), 'plain');
      i = j;
      continue;
    }
    if (_isDigitAt(text, i)) {
      var j = i;
      while (j < text.length && _isDigitAt(text, j)) j++;
      // Clock time HH:MM.
      if (j + 1 < text.length && text[j] == ':' && _isDigitAt(text, j + 1)) {
        var k = j + 1;
        while (k < text.length && _isDigitAt(text, k)) k++;
        add(text.substring(i, k), 'time');
        i = k;
        continue;
      }
      var k = j;
      if (k < text.length && text[k] == '.') {
        k++;
        while (k < text.length && _isDigitAt(text, k)) k++;
      }
      add(text.substring(i, k), 'number');
      i = k;
      continue;
    }
    if (_isLetterAt(text, i)) {
      var j = i;
      while (j < text.length &&
          (_isLetterAt(text, j) || _isDigitAt(text, j))) {
        j++;
      }
      final word = text.substring(i, j);
      final upper = word.toUpperCase();
      final String kind;
      if (varNames.contains(upper)) {
        kind = 'variable';
      } else if (signalTermByCode(upper) != null) {
        kind = 'term';
      } else if (_keywords.contains(upper)) {
        kind = 'keyword';
      } else {
        kind = 'unknown';
      }
      add(word, kind);
      i = j;
      continue;
    }
    if (c == '>' || c == '<' || c == '!') {
      if (i + 1 < text.length && text[i + 1] == '=') {
        add(text.substring(i, i + 2), 'operator');
        i += 2;
      } else {
        add(c, 'operator');
        i++;
      }
      continue;
    }
    if (c == '=' || c == '+' || c == '-' || c == '*' || c == '/' ||
        c == '×' || c == '÷') {
      add(c, 'operator');
      i++;
      continue;
    }
    if (c == '(' || c == ')' || c == ',' || c == ';') {
      add(c, 'plain');
      i++;
      continue;
    }
    add(c, 'unknown');
    i++;
  }
  return out;
}
