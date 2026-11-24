import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/signal.dart';
import 'package:hjdev_trading/services/signal_highlighter.dart';
import 'package:hjdev_trading/services/signal_parser.dart';

/// SIGNAL BUILDER — create and edit a signal in the Signal Maths
/// language (design: HJ_Signal_Maths_Language_Design.md):
/// one stock + one action, indicators with weights (ratio rule:
/// equal by default, total always 100%), and maths lines built by
/// tapping — term, sign, term — never by typing formulas.
///
/// Saving stores the signal as DATA in the local DB. This step is
/// create + save only: no engine watches the signals yet, and
/// saving a signal places no trades.
class SignalBuilderScreen extends StatefulWidget {
  final SignalDef? existing;
  const SignalBuilderScreen({super.key, this.existing});

  @override
  State<SignalBuilderScreen> createState() => _SignalBuilderScreenState();
}

class _SignalBuilderScreenState extends State<SignalBuilderScreen> {
  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  final AppDb _db = AppDb.instance;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _qtyCtrl = TextEditingController(text: '1');
  final TextEditingController _tpCtrl = TextEditingController();
  final TextEditingController _slCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  // Picked stock (kept as plain fields — set from a Scrip on pick).
  String? _symbol;
  String? _segment;
  String? _token;
  String? _displayName;
  String? _instrumentType;

  String _side = 'B';
  List<SignalVariable> _variables = [];
  List<SignalIndicator> _indicators = [];
  List<Scrip> _results = [];
  int _searchSeq = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text = e.name;
      _qtyCtrl.text = e.qty.toString();
      _tpCtrl.text = e.tpPct?.toString() ?? '';
      _slCtrl.text = e.slPct?.toString() ?? '';
      _symbol = e.symbol;
      _segment = e.exchange;
      _token = e.token;
      _displayName = e.displayName;
      _instrumentType = e.instrumentType;
      _side = e.side;
      _variables = List.of(e.variables);
      _indicators = List.of(e.indicators);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _tpCtrl.dispose();
    _slCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool green = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: green ? _green : _red,
    ));
  }

  // ---------------- Stock picking ----------------

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    if (q.trim().length < 2) {
      if (mounted) setState(() => _results = []);
      return;
    }
    final results = await _db.searchScrips(q.trim(), limit: 30);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _results = results);
  }

  void _pickStock(Scrip s) {
    setState(() {
      _symbol = s.symbol;
      _segment = s.segment;
      _token = s.token;
      _displayName = s.displayName;
      _instrumentType = s.instrumentType;
      _results = [];
      _searchCtrl.clear();
    });
  }

  // ---------------- Weights (ratio rule, design §7a) ----------------

  double get _totalWeight =>
      _indicators.fold(0.0, (sum, i) => sum + i.weightPct);

  /// Kept indicators (locked, or with a hand-set %) keep their
  /// weight; the free ones split what remains, equally.
  void _rebalanceFree() {
    if (_indicators.isEmpty) return;
    var keptSum = 0.0;
    var freeCount = 0;
    for (final ind in _indicators) {
      if (ind.locked || ind.weightManual) {
        keptSum += ind.weightPct;
      } else {
        freeCount++;
      }
    }
    final freeEach = freeCount == 0 ? 0.0 : (100 - keptSum) / freeCount;
    _indicators = [
      for (final ind in _indicators)
        (ind.locked || ind.weightManual)
            ? ind
            : ind.copyWith(weightPct: freeEach),
    ];
  }

  void _addIndicator() {
    setState(() {
      _indicators = [
        ..._indicators,
        SignalIndicator(
          name: 'Indicator ${_indicators.length + 1}',
          weightPct: 0,
        ),
      ];
      _rebalanceFree();
    });
  }

  void _removeIndicator(int i) {
    setState(() {
      _indicators = List.of(_indicators)..removeAt(i);
      _rebalanceFree();
    });
  }

  void _equalize() {
    setState(() {
      _indicators = [
        for (final ind in _indicators) ind.copyWith(weightManual: false),
      ];
      _rebalanceFree();
    });
  }

  /// Raise/lower one indicator by [delta]; the difference is
  /// given to / taken from the other UNLOCKED indicators equally.
  void _adjustWeight(int i, double delta) {
    final ind = _indicators[i];
    final target = (ind.weightPct + delta).clamp(0.0, 100.0).toDouble();
    final diff = target - ind.weightPct;
    if (diff == 0) return;
    final others = <int>[
      for (var j = 0; j < _indicators.length; j++)
        if (j != i && !_indicators[j].locked) j,
    ];
    if (others.isEmpty) {
      _snack('All other indicators are locked — unlock one first');
      return;
    }
    final per = diff / others.length;
    for (final j in others) {
      final w = _indicators[j].weightPct - per;
      if (w < -0.001 || w > 100.001) {
        _snack('Cannot move — an unlocked indicator would leave 0–100%');
        return;
      }
    }
    setState(() {
      final updated = List.of(_indicators);
      updated[i] = ind.copyWith(weightPct: target, weightManual: true);
      for (final j in others) {
        updated[j] = updated[j]
            .copyWith(weightPct: updated[j].weightPct - per);
      }
      _indicators = updated;
    });
  }

  // ---------------- Indicator / line editing ----------------

  Future<void> _renameIndicator(int i) async {
    final ctrl = TextEditingController(text: _indicators[i].name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Indicator name', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'e.g. Gap Check, Time Check'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() {
      final updated = List.of(_indicators);
      updated[i] = updated[i].copyWith(name: name);
      _indicators = updated;
    });
  }

  Future<SignalLine?> _showLineEditor(SignalLine? existing) {
    return Navigator.push<SignalLine>(
      context,
      MaterialPageRoute(
          builder: (_) => _LineEditorScreen(
              existing: existing, variables: _variables)),
    );
  }

  // ---------------- Variables ----------------

  Future<void> _addVariable() async {
    final v = await Navigator.push<SignalVariable>(
      context,
      MaterialPageRoute(
        builder: (_) => _VariableEditorScreen(
          contextVars: List.of(_variables),
          takenNames: [for (final x in _variables) x.name],
        ),
      ),
    );
    if (v != null && mounted) {
      setState(() => _variables = [..._variables, v]);
    }
  }

  Future<void> _editVariable(int i) async {
    final v = await Navigator.push<SignalVariable>(
      context,
      MaterialPageRoute(
        builder: (_) => _VariableEditorScreen(
          existing: _variables[i],
          contextVars: _variables.sublist(0, i),
          takenNames: [
            for (var j = 0; j < _variables.length; j++)
              if (j != i) _variables[j].name,
          ],
        ),
      ),
    );
    if (v != null && mounted) {
      setState(() {
        final updated = List.of(_variables);
        updated[i] = v;
        _variables = updated;
      });
    }
  }

  /// True when a maths line or another variable uses [name] —
  /// such a variable cannot be deleted until the use is removed.
  bool _variableUsed(String name) {
    bool sideUses(MathsSide? s) =>
        s != null &&
        s.atoms.any((a) =>
            (a.kind == 'VAR' && a.term == name) ||
            a.pctA == name ||
            a.pctB == name);
    bool lineUses(SignalLine l) =>
        l.boolVar == name ||
        sideUses(l.left) ||
        sideUses(l.right) ||
        sideUses(l.right2);
    for (final ind in _indicators) {
      for (final l in ind.lines) {
        if (lineUses(l)) return true;
      }
    }
    for (final v in _variables) {
      if (v.name == name) continue;
      if (sideUses(v.maths)) return true;
      final l = v.line;
      if (l != null && lineUses(l)) return true;
    }
    return false;
  }

  void _removeVariable(int i) {
    final name = _variables[i].name;
    if (_variableUsed(name)) {
      _snack(
          '"$name" is used in a maths line or another variable — remove it there first');
      return;
    }
    setState(() {
      _variables = List.of(_variables)..removeAt(i);
    });
  }

  Future<void> _editLine(int indIdx, SignalLine? existing, int? lineIdx) async {
    final line = await _showLineEditor(existing);
    if (line == null || !mounted) return;
    setState(() {
      final ind = _indicators[indIdx];
      final lines = List.of(ind.lines);
      if (lineIdx == null) {
        lines.add(line);
      } else {
        lines[lineIdx] = line;
      }
      final updated = List.of(_indicators);
      updated[indIdx] = ind.copyWith(lines: lines);
      _indicators = updated;
    });
  }

  void _removeLine(int indIdx, int lineIdx) {
    setState(() {
      final ind = _indicators[indIdx];
      final lines = List.of(ind.lines)..removeAt(lineIdx);
      final updated = List.of(_indicators);
      updated[indIdx] = ind.copyWith(lines: lines);
      _indicators = updated;
    });
  }

  // ---------------- Save ----------------

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Give the signal a name');
      return;
    }
    if (_symbol == null) {
      _snack('Pick a stock for this signal');
      return;
    }
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _snack('Quantity must be at least 1');
      return;
    }
    if (_indicators.isEmpty) {
      _snack('Add at least one indicator');
      return;
    }
    for (final ind in _indicators) {
      if (ind.lines.isEmpty) {
        _snack('"${ind.name}" has no maths lines — add one');
        return;
      }
      for (final line in ind.lines) {
        if (!line.isComplete) {
          _snack('A maths line in "${ind.name}" is incomplete');
          return;
        }
        final err = line.typeError;
        if (err != null) {
          _snack('In "${ind.name}": $err');
          return;
        }
      }
    }
    if ((_totalWeight - 100).abs() > 0.05) {
      _snack(
          'Indicator weights total ${_totalWeight.toStringAsFixed(1)}% — they must total exactly 100%');
      return;
    }
    final tp = double.tryParse(_tpCtrl.text.trim());
    final sl = double.tryParse(_slCtrl.text.trim());
    if (_tpCtrl.text.trim().isNotEmpty && (tp == null || tp <= 0)) {
      _snack('Target % must be a positive number');
      return;
    }
    if (_slCtrl.text.trim().isNotEmpty && (sl == null || sl <= 0)) {
      _snack('Stop-loss % must be a positive number');
      return;
    }
    setState(() => _saving = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Line weights inside an indicator: equal shares (design §7b).
    final indicators = [
      for (final ind in _indicators)
        ind.copyWith(lines: [
          for (final line in ind.lines)
            line.copyWith(
                weightPct: ind.lines.isEmpty
                    ? 0
                    : 100 / ind.lines.length),
        ]),
    ];
    final e = widget.existing;
    final def = SignalDef(
      id: e?.id,
      name: name,
      symbol: _symbol!,
      exchange: _segment ?? 'nse_cm',
      token: _token,
      displayName: _displayName ?? _symbol!,
      instrumentType: _instrumentType,
      side: _side,
      qty: qty,
      tpPct: tp,
      slPct: sl,
      enabled: e?.enabled ?? true,
      variables: _variables,
      indicators: indicators,
      createdMs: e?.createdMs ?? now,
      updatedMs: now,
    );
    try {
      if (e == null) {
        await _db.insertSignal(def);
      } else {
        await _db.updateSignal(def);
      }
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        _snack('Could not save: $err');
      }
      return;
    }
    if (!mounted) return;
    _snack(e == null ? 'Signal created' : 'Signal saved', green: true);
    Navigator.pop(context, true);
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(editing ? 'Edit Signal' : 'Create Signal',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'SAVE',
                style: const TextStyle(
                    color: _blue,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text(
            'A signal = one stock + one action. The app will keep '
            'calculating its maths lines on the live price; at 100% '
            'the signal is TRUE. (Engine comes in the next step — '
            'saving a signal places no trades yet.)',
            style: TextStyle(color: _secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            style: const TextStyle(color: _text, fontSize: 15),
            decoration: const InputDecoration(
              labelText: 'Signal name',
              hintText: 'e.g. JK Paper Gap-Up',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 18),
          const Text('Stock',
              style: TextStyle(
                  color: _text, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (_symbol != null) _pickedStockCard() else _stockSearch(),
          const SizedBox(height: 18),
          const Text('Action',
              style: TextStyle(
                  color: _text, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              _sideChip('BUY', 'B'),
              const SizedBox(width: 8),
              _sideChip('SELL / SHORT', 'S'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: _text),
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _tpCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: _text),
                  decoration: const InputDecoration(
                    labelText: 'Target % (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _slCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: _text),
                  decoration: const InputDecoration(
                    labelText: 'Stop-loss % (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              const Text('Variables',
                  style: TextStyle(
                      color: _text,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _addVariable,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Add variable'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _blue,
                    side: const BorderSide(color: _blue)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Name your own values, Dart-style — give a name, a type '
            'and a value, e.g.  double stockCurrent = PRICE;  '
            'The value is calculated live and the name can be used '
            'inside maths lines. Types: int (whole number), '
            'double (decimal number), String (text), '
            'bool (TRUE/FALSE).',
            style: TextStyle(color: _hint, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (_variables.isEmpty)
            const Text(
              'No variables yet — they are optional. Terms like '
              'PRICE and OPEN always work directly.',
              style: TextStyle(color: _hint, fontSize: 12.5),
            ),
          for (var i = 0; i < _variables.length; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _hairline),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_variables[i].declaration(),
                        style: const TextStyle(
                            color: _text,
                            fontSize: 13,
                            fontFamily: 'monospace')),
                  ),
                  IconButton(
                    tooltip: 'Edit variable',
                    icon: const Icon(Icons.edit_outlined,
                        color: _secondary, size: 18),
                    onPressed: () => _editVariable(i),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: 'Delete variable',
                    icon: const Icon(Icons.delete_outline,
                        color: _red, size: 18),
                    onPressed: () => _removeVariable(i),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text('Indicators',
                  style: TextStyle(
                      color: _text,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('Total: ${_totalWeight.toStringAsFixed(1)}%',
                  style: TextStyle(
                      color: (_totalWeight - 100).abs() <= 0.05
                          ? _green
                          : _red,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Weights are equal by default. Raise or lower one and '
            'the others adjust equally — the total always stays '
            '100%. Lock an indicator to protect its %.' ,
            style: TextStyle(color: _hint, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _addIndicator,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Add indicator'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: _blue,
                    side: const BorderSide(color: _blue)),
              ),
              const SizedBox(width: 8),
              if (_indicators.length > 1)
                OutlinedButton(
                  onPressed: _equalize,
                  child: const Text('Make all equal'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < _indicators.length; i++)
            _indicatorCard(i, _indicators[i]),
          if (_indicators.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No indicators yet. A signal needs at least one '
                'indicator, and each indicator needs at least one '
                'maths line.',
                style: TextStyle(color: _hint, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pickedStockCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _hairline),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: _blue, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_symbol!,
                    style: const TextStyle(
                        color: _text, fontWeight: FontWeight.bold)),
                Text(
                  '${_displayName ?? ''}'
                  '${_instrumentType != null ? ' • $_instrumentType' : ''}',
                  style:
                      const TextStyle(color: _secondary, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _symbol = null;
              _token = null;
            }),
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  Widget _stockSearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchCtrl,
          onChanged: _search,
          style: const TextStyle(color: _text),
          decoration: const InputDecoration(
            hintText: 'Search stocks, futures, options…',
            prefixIcon: Icon(Icons.search, size: 20),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _hairline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: [
                for (final s in _results.take(8))
                  ListTile(
                    dense: true,
                    title: Text(s.symbol,
                        style: const TextStyle(
                            color: _text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${s.displayName} • ${s.instrumentType}'
                      '${s.expiry != null ? ' • ${s.expiry}' : ''}',
                      style: const TextStyle(
                          color: _secondary, fontSize: 11.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(s.exchange,
                        style: const TextStyle(
                            color: _hint, fontSize: 11)),
                    onTap: () => _pickStock(s),
                  ),
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Stocks come from the downloaded scrip master list — '
            'download it from the Watchlist tab if search finds '
            'nothing.',
            style: TextStyle(color: _hint, fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  Widget _sideChip(String label, String value) {
    final selected = _side == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _side = value),
      selectedColor: value == 'B' ? _blue : _red,
      labelStyle: TextStyle(
          color: selected ? Colors.white : _text, fontSize: 13),
      side: BorderSide.none,
      backgroundColor: _panel,
    );
  }

  Widget _indicatorCard(int i, SignalIndicator ind) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _renameIndicator(i),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(ind.name,
                            style: const TextStyle(
                                color: _text,
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.edit, color: _hint, size: 14),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: ind.locked ? 'Unlock weight' : 'Lock weight',
                icon: Icon(
                    ind.locked ? Icons.lock : Icons.lock_open_outlined,
                    color: ind.locked ? _blue : _hint,
                    size: 19),
                onPressed: () => setState(() {
                  final updated = List.of(_indicators);
                  updated[i] = ind.copyWith(locked: !ind.locked);
                  _indicators = updated;
                }),
              ),
              IconButton(
                tooltip: 'Delete indicator',
                icon: const Icon(Icons.delete_outline,
                    color: _red, size: 19),
                onPressed: () => _removeIndicator(i),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Weight',
                  style: TextStyle(color: _secondary, fontSize: 12.5)),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    color: _secondary, size: 20),
                onPressed: () => _adjustWeight(i, -5),
                visualDensity: VisualDensity.compact,
              ),
              Text('${ind.weightPct.toStringAsFixed(1)}%',
                  style: const TextStyle(
                      color: _text,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: _secondary, size: 20),
                onPressed: () => _adjustWeight(i, 5),
                visualDensity: VisualDensity.compact,
              ),
              if (ind.weightManual)
                const Text('manual',
                    style: TextStyle(color: _hint, fontSize: 11)),
            ],
          ),
          const Divider(color: _hairline, height: 14),
          for (var j = 0; j < ind.lines.length; j++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.rich(signalHighlightSpan(
                        ind.lines[j].render(),
                        variables: _variables,
                        base: const TextStyle(
                            color: _text,
                            fontSize: 13,
                            fontFamily: 'monospace'))),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit,
                        color: _hint, size: 17),
                    onPressed: () => _editLine(i, ind.lines[j], j),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: _red, size: 17),
                    onPressed: () => _removeLine(i, j),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: () => _editLine(i, null, null),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add maths line'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _blue,
                side: const BorderSide(color: _hairline),
                visualDensity: VisualDensity.compact),
          ),
        ],
      ),
    );
  }
}

/// The colour of one kind of word in the Stock IDE — like a
/// real programming editor: terms in Kite blue, the user's own
/// VARIABLES in purple (a different colour, so they stand out),
/// numbers orange, clock times green, keywords pink, unknown
/// words red.
Color signalKindColor(String kind) {
  switch (kind) {
    case 'term':
      return const Color(0xFF387ED1);
    case 'variable':
      return const Color(0xFF7C3AED);
    case 'number':
      return const Color(0xFFE65100);
    case 'time':
      return const Color(0xFF2E7D32);
    case 'keyword':
      return const Color(0xFFC2185B);
    case 'unknown':
      return const Color(0xFFE53935);
    default:
      return const Color(0xFF424242);
  }
}

/// [text] as a coloured TextSpan for previews and line rows.
TextSpan signalHighlightSpan(String text,
    {List<SignalVariable> variables = const [], TextStyle? base}) {
  final b = base ?? const TextStyle(color: Color(0xFF424242));
  return TextSpan(
    style: b,
    children: [
      for (final seg in signalSegments(text, variables: variables))
        TextSpan(
          text: seg.text,
          style: TextStyle(
            color: signalKindColor(seg.kind),
            fontWeight: (seg.kind == 'term' ||
                    seg.kind == 'variable' ||
                    seg.kind == 'keyword')
                ? FontWeight.w600
                : null,
          ),
        ),
    ],
  );
}

/// A text controller that paints the Stock IDE's syntax colours
/// while the user types.
class SignalIdeController extends TextEditingController {
  List<SignalVariable> variables = const [];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return signalHighlightSpan(text, variables: variables, base: style);
  }
}

/// STOCK IDE — the one maths-line editor, now a FULL SCREEN page.
/// Type the line as text; matching terms are suggested as you
/// type; the ℹ button opens the all-terms page (tap a term there
/// to add it to the line). SAVE RULE: a line is saved only when
/// its answer is TRUE or FALSE — a complete
/// LEFT compare RIGHT line. Anything else is refused, with the
/// reason shown on the page.
class _LineEditorScreen extends StatefulWidget {
  final SignalLine? existing;
  final List<SignalVariable> variables;
  const _LineEditorScreen({this.existing, this.variables = const []});

  @override
  State<_LineEditorScreen> createState() => _LineEditorScreenState();
}

class _LineEditorScreenState extends State<_LineEditorScreen> {
  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _red = Color(0xFFE53935);

  final SignalIdeController _ideCtrl = SignalIdeController();
  SignalLine? _ideLine;
  String? _ideError;

  @override
  void initState() {
    super.initState();
    _ideCtrl.variables = widget.variables;
    final e = widget.existing;
    if (e != null) {
      _ideCtrl.text = e.formula;
      _ideRefresh();
    }
  }

  @override
  void dispose() {
    _ideCtrl.dispose();
    super.dispose();
  }

  void _ideRefresh() {
    final text = _ideCtrl.text;
    if (text.trim().isEmpty) {
      _ideLine = null;
      _ideError = null;
      return;
    }
    final r = parseSignalLine(text, variables: widget.variables);
    _ideLine = r.line;
    _ideError = r.error;
  }

  /// Term suggestions for the word currently being typed —
  /// language terms plus this signal's own variable names.
  List<String> _ideSuggestions() {
    final text = _ideCtrl.text;
    var cursor = _ideCtrl.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    final before = text.substring(0, cursor);
    final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
    if (m == null) return const [];
    final partial = m.group(0)!.toUpperCase();
    const words = [
      'PCT_CHANGE',
      'CROSSED_ABOVE',
      'CROSSED_BELOW',
      'TOUCHED',
      'BETWEEN',
      'OUTSIDE',
      'AND',
    ];
    final all = <String>[
      for (final v in widget.variables) v.name,
      for (final t in kSignalTerms) t.code,
      ...words,
    ];
    return [
      for (final c in all)
        if (c.toUpperCase().startsWith(partial) &&
            c.toUpperCase() != partial)
          c,
    ].take(8).toList();
  }

  void _insertSuggestion(String code) {
    final text = _ideCtrl.text;
    var cursor = _ideCtrl.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    final before = text.substring(0, cursor);
    final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
    final start = m == null ? cursor : m.start;
    final insert = code == 'PCT_CHANGE' ? 'PCT_CHANGE(' : code;
    final newText = text.replaceRange(start, cursor, insert);
    setState(() {
      _ideCtrl.value = TextEditingValue(
        text: newText,
        selection:
            TextSelection.collapsed(offset: start + insert.length),
      );
      _ideRefresh();
    });
  }

  void _insertSign(String s) {
    final text = _ideCtrl.text;
    var cursor = _ideCtrl.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    final insert = s.length > 1 ? ' $s ' : s;
    final newText = text.replaceRange(cursor, cursor, insert);
    setState(() {
      _ideCtrl.value = TextEditingValue(
        text: newText,
        selection:
            TextSelection.collapsed(offset: cursor + insert.length),
      );
      _ideRefresh();
    });
  }

  void _applyExample(String formula) {
    setState(() {
      _ideCtrl.value = TextEditingValue(
        text: formula,
        selection: TextSelection.collapsed(offset: formula.length),
      );
      _ideRefresh();
    });
  }

  Future<void> _openTerms() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(
          builder: (_) => _TermsInfoScreen(variables: widget.variables)),
    );
    if (code != null && mounted) _insertSuggestion(code);
  }

  /// SAVE RULE: only a line whose answer is TRUE or FALSE — a
  /// complete LEFT compare RIGHT line — can be saved. Anything
  /// else stays on this page with the reason shown.
  void _save() {
    final r = parseSignalLine(_ideCtrl.text, variables: widget.variables);
    if (r.line == null) {
      setState(() => _ideError = r.error);
      return;
    }
    Navigator.pop(context, r.line);
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _ideSuggestions();
    const signs = [
      '>=', '<=', '>', '<', '=', '!=',
      '+', '-', '×', '÷', '(', ')', ',',
    ];
    const examples = <String, String>{
      'Gap up 0.7%': 'PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7',
      'Price above open': 'PRICE >= OPEN',
      'Time 10:15 or later': 'TIME_NOW >= 10:15',
      'Up 1% today': 'CHANGE_PCT >= 1',
    };
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
            widget.existing == null ? 'Add maths line' : 'Edit maths line',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'See all terms',
            icon: const Icon(Icons.info_outline, color: _blue),
            onPressed: _openTerms,
          ),
          TextButton(
            onPressed: _save,
            child: const Text('SAVE',
                style: TextStyle(
                    color: _blue,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          const Text(
            'Type one maths line in the Stock IDE. Its answer must '
            'be TRUE or FALSE: a left side, a compare sign, and a '
            'right side. A line whose answer is not TRUE or FALSE '
            'will not be saved.',
            style: TextStyle(color: _secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ideCtrl,
            autofocus: true,
            maxLines: 4,
            style: const TextStyle(
                color: _text, fontSize: 15, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'e.g. PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_ideRefresh),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _legendDot('term', 'Terms'),
              _legendDot('variable', 'Your variables'),
              _legendDot('number', 'Numbers'),
              _legendDot('time', 'Times'),
              _legendDot('keyword', 'Keywords'),
              _legendDot('unknown', 'Unknown word'),
            ],
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Suggested terms — tap to add:',
                style: TextStyle(
                    color: _secondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in suggestions)
                  ActionChip(
                    label: Text(s, style: const TextStyle(fontSize: 12.5)),
                    onPressed: () => _insertSuggestion(s),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: _blue),
                    labelStyle: const TextStyle(color: _blue),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in signs)
                OutlinedButton(
                  onPressed: () => _insertSign(s),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _text,
                    side: const BorderSide(color: _hairline),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(s, style: const TextStyle(fontSize: 14)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Examples — tap to fill:',
              style: TextStyle(
                  color: _secondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in examples.entries)
                ActionChip(
                  label: Text(entry.key,
                      style: const TextStyle(fontSize: 12.5)),
                  onPressed: () => _applyExample(entry.value),
                  backgroundColor: _panel,
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (_ideLine != null)
            _statusBox(
              _ideLine!.render(),
              'This line is TRUE when '
              '${compareMeaning(_ideLine!.compare)}.',
              ok: true,
            )
          else if (_ideError != null)
            _statusBox(
              _ideCtrl.text.trim().isEmpty ? '…' : _ideCtrl.text.trim(),
              'Not saved — the answer of this line is not TRUE or '
              'FALSE yet.',
              error: _ideError,
            )
          else
            const Text(
              'Start typing — terms are suggested as you type, and '
              'the ℹ button at the top shows every term.',
              style: TextStyle(color: _hint, fontSize: 12.5),
            ),
        ],
      ),
    );
  }

  Widget _legendDot(String kind, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
              color: signalKindColor(kind), shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: _hint, fontSize: 11)),
      ],
    );
  }

  Widget _statusBox(String formula, String meaning,
      {bool ok = false, String? error}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: ok ? _blue : _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(signalHighlightSpan(formula,
              variables: widget.variables,
              base: const TextStyle(
                  color: _text, fontSize: 13.5, fontFamily: 'monospace'))),
          const SizedBox(height: 4),
          Text(meaning,
              style: const TextStyle(color: _secondary, fontSize: 12.5)),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error,
                style: const TextStyle(color: _red, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}

/// ALL TERMS page — opened from the Stock IDE's ℹ button. Every
/// term in the language, grouped by type, with its full name.
/// Tap a term to add it to the line being written.
class _TermsInfoScreen extends StatelessWidget {
  final List<SignalVariable> variables;
  const _TermsInfoScreen({this.variables = const []});

  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);

  static const List<(String, String)> _groups = [
    ('PRICE', 'Price terms — compare with prices or numbers'),
    ('PERCENT', 'Percent terms (ready-made) — compare with numbers'),
    ('TIME', 'Time terms — compare with clock times like 10:15'),
    ('VOLUME', 'Volume terms — compare with volumes or numbers'),
    ('NUMBER', 'Number terms — compare with plain numbers'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('All terms',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const Text(
            'Every term in the Signal Maths language. Tap a term '
            'to add it to your line. A term can only be compared '
            'with the same type — price with price, time with '
            'time — or with a plain number.',
            style: TextStyle(color: _secondary, fontSize: 12.5),
          ),
          if (variables.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Your variables in this signal',
                style: TextStyle(
                    color: _text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _hairline),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                children: [
                  for (final v in variables)
                    ListTile(
                      dense: true,
                      title: Text(v.declaration(),
                          style: const TextStyle(
                              color: _text,
                              fontSize: 12.5,
                              fontFamily: 'monospace')),
                      trailing: const Icon(Icons.add_circle_outline,
                          color: _blue, size: 19),
                      onTap: () => Navigator.pop(context, v.name),
                    ),
                ],
              ),
            ),
          ],
          for (final (type, title) in _groups) ...[
            const SizedBox(height: 18),
            Text(title,
                style: const TextStyle(
                    color: _text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _hairline),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                children: [
                  for (final t in kSignalTerms.where((x) => x.type == type))
                    ListTile(
                      dense: true,
                      title: Text(t.code,
                          style: const TextStyle(
                              color: _text,
                              fontSize: 13.5,
                              fontWeight: FontWeight.bold)),
                      subtitle: Text(t.label,
                          style: const TextStyle(
                              color: _secondary, fontSize: 11.5)),
                      trailing: const Icon(Icons.add_circle_outline,
                          color: _blue, size: 19),
                      onTap: () => Navigator.pop(context, t.code),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Text('One special function',
              style: TextStyle(
                  color: _text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _hairline),
            ),
            child: const Text(
              'PCT_CHANGE(A, B) = (A − B) ÷ B × 100 — the % change '
              'of A from B.\nExample: PCT_CHANGE(OPEN, PREV_CLOSE) '
              '>= 0.7 means the stock opened at least 0.7% above '
              'yesterday\'s close.',
              style: TextStyle(color: _secondary, fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 18),
          const Text('Compare signs — the line\'s answer is TRUE when…',
              style: TextStyle(
                  color: _text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _hairline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: [
                for (final op in kCompareOps)
                  ListTile(
                    dense: true,
                    title: Text(
                        op == compareLabel(op) ? op : '$op  (${compareLabel(op)})',
                        style: const TextStyle(
                            color: _text,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                    subtitle: Text(compareMeaning(op),
                        style: const TextStyle(
                            color: _secondary, fontSize: 11.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// VARIABLE EDITOR — create or edit one of the signal's named
/// variables, Dart-style: a name, a type (int / double / String /
/// bool) and a value. Number variables hold a calculation typed
/// in the Stock IDE (no compare sign); a bool variable holds a
/// whole TRUE/FALSE maths line; a String variable holds text.
/// A variable may use the variables listed ABOVE it in the
/// signal (never itself or later ones), so values can never
/// chase each other in a circle. Name and type are fixed after
/// creation — delete and re-create to change them.
class _VariableEditorScreen extends StatefulWidget {
  final SignalVariable? existing;
  final List<SignalVariable> contextVars;
  final List<String> takenNames;
  const _VariableEditorScreen({
    this.existing,
    required this.contextVars,
    required this.takenNames,
  });

  @override
  State<_VariableEditorScreen> createState() => _VariableEditorScreenState();
}

class _VariableEditorScreenState extends State<_VariableEditorScreen> {
  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _red = Color(0xFFE53935);

  final TextEditingController _nameCtrl = TextEditingController();
  final SignalIdeController _valueCtrl = SignalIdeController();
  String _dartType = 'double';
  String? _error;
  MathsSide? _checkSide;
  SignalLine? _checkLine;

  bool get _editing => widget.existing != null;
  bool get _isBool => _dartType == 'bool';
  bool get _isText => _dartType == 'String';
  bool get _isNumeric => !_isBool && !_isText;

  @override
  void initState() {
    super.initState();
    _valueCtrl.variables = widget.contextVars;
    final e = widget.existing;
    if (e != null) {
      _dartType = e.dartType;
      _nameCtrl.text = e.name;
      if (e.isBool) {
        _valueCtrl.text = e.line?.formula ?? '';
      } else if (e.isText) {
        _valueCtrl.text = e.text ?? '';
      } else {
        _valueCtrl.text = e.maths?.formula ?? '';
      }
      _refresh();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    _error = null;
    _checkSide = null;
    _checkLine = null;
    final value = _valueCtrl.text;
    if (value.trim().isEmpty || _isText) return;
    if (_isBool) {
      final r = parseSignalLine(value, variables: widget.contextVars);
      _checkLine = r.line;
      _error = r.error;
    } else {
      final r = parseSignalMaths(value, variables: widget.contextVars);
      _checkSide = r.side;
      _error = r.error;
      if (r.side != null && r.side!.type == 'TIME') {
        _error = 'A number variable cannot hold a clock time — '
            'use a price, percent, volume or number value';
        _checkSide = null;
      }
    }
  }

  List<String> _suggestions() {
    final text = _valueCtrl.text;
    var cursor = _valueCtrl.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    final before = text.substring(0, cursor);
    final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
    if (m == null) return const [];
    final partial = m.group(0)!.toUpperCase();
    final all = <String>[
      for (final v in widget.contextVars) v.name,
      for (final t in kSignalTerms) t.code,
      'PCT_CHANGE',
      if (_isBool) ...[
        'CROSSED_ABOVE',
        'CROSSED_BELOW',
        'TOUCHED',
        'BETWEEN',
        'OUTSIDE',
        'AND',
      ],
    ];
    return [
      for (final c in all)
        if (c.toUpperCase().startsWith(partial) &&
            c.toUpperCase() != partial)
          c,
    ].take(8).toList();
  }

  void _insert(String insert, {bool replaceWord = false}) {
    final text = _valueCtrl.text;
    var cursor = _valueCtrl.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;
    var start = cursor;
    if (replaceWord) {
      final before = text.substring(0, cursor);
      final m = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
      if (m != null) start = m.start;
    }
    final newText = text.replaceRange(start, cursor, insert);
    setState(() {
      _valueCtrl.value = TextEditingValue(
        text: newText,
        selection:
            TextSelection.collapsed(offset: start + insert.length),
      );
      _refresh();
    });
  }

  void _save() {
    final name = _editing ? widget.existing!.name : _nameCtrl.text.trim();
    if (!_editing) {
      final nameErr = signalVariableNameError(name, widget.takenNames);
      if (nameErr != null) {
        setState(() => _error = nameErr);
        return;
      }
    }
    if (_isText) {
      Navigator.pop(
          context,
          SignalVariable(
              name: name, dartType: _dartType, text: _valueCtrl.text));
      return;
    }
    if (_isBool) {
      final r =
          parseSignalLine(_valueCtrl.text, variables: widget.contextVars);
      if (r.line == null) {
        setState(() => _error = r.error);
        return;
      }
      Navigator.pop(
          context,
          SignalVariable(name: name, dartType: _dartType, line: r.line));
      return;
    }
    final r =
        parseSignalMaths(_valueCtrl.text, variables: widget.contextVars);
    if (r.side == null) {
      setState(() => _error = r.error);
      return;
    }
    if (r.side!.type == 'TIME') {
      setState(() => _error =
          'A number variable cannot hold a clock time — use a price, percent, volume or number value');
      return;
    }
    Navigator.pop(
        context,
        SignalVariable(name: name, dartType: _dartType, maths: r.side));
  }

  String get _typeExplainer {
    switch (_dartType) {
      case 'int':
        return 'Whole number. The value is a calculation; any '
            'fraction is dropped when the signal runs. Good for '
            'counts, minutes and volumes.';
      case 'String':
        return 'Fixed text. Text cannot be used inside maths — '
            'it is for names, notes and messages.';
      case 'bool':
        return 'TRUE or FALSE. The value is a whole maths line '
            'with a compare sign. Inside an indicator, write the '
            'variable name alone as a line to use it.';
      default:
        return 'Decimal number — in Dart this is the type for '
            'prices and percents (other languages call it float). '
            'The value is a calculation, e.g. PRICE or '
            'PCT_CHANGE(OPEN, PREV_CLOSE).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions();
    final signs = _isBool
        ? const ['>=', '<=', '>', '<', '=', '!=', '+', '-', '×', '÷', '(', ')', ',']
        : const ['+', '-', '×', '÷', '(', ')', ','];
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(_editing ? 'Edit variable' : 'Add variable',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('SAVE',
                style: TextStyle(
                    color: _blue,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          if (_editing) ...[
            Text(
              '${widget.existing!.dartType} ${widget.existing!.name}',
              style: const TextStyle(
                  color: _text,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace'),
            ),
            const SizedBox(height: 4),
            const Text(
              'Name and type are fixed after creation — delete '
              'the variable and create it again to change them. '
              'Only its value can be edited here.',
              style: TextStyle(color: _hint, fontSize: 12),
            ),
          ] else ...[
            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: _text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: 'Variable name',
                hintText: 'e.g. stockCurrent',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            const Text('Type',
                style: TextStyle(
                    color: _text,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final t in const ['int', 'double', 'String', 'bool'])
                  ChoiceChip(
                    label: Text(t),
                    selected: _dartType == t,
                    onSelected: (_) => setState(() {
                      _dartType = t;
                      _refresh();
                    }),
                    selectedColor: _blue,
                    labelStyle: TextStyle(
                        color: _dartType == t ? Colors.white : _text,
                        fontSize: 13),
                    side: BorderSide.none,
                    backgroundColor: _panel,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(_typeExplainer,
              style: const TextStyle(color: _secondary, fontSize: 12.5)),
          const SizedBox(height: 16),
          Text(
            _isText
                ? 'Value — text'
                : _isBool
                    ? 'Value — a TRUE/FALSE maths line'
                    : 'Value — a calculation (no compare sign)',
            style: const TextStyle(
                color: _text, fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _valueCtrl,
            maxLines: _isText ? 2 : 3,
            style: TextStyle(
                color: _text,
                fontSize: 14.5,
                fontFamily: _isText ? null : 'monospace'),
            decoration: InputDecoration(
              hintText: _isText
                  ? 'e.g. morning only'
                  : _isBool
                      ? 'e.g. PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7'
                      : 'e.g. PRICE',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_refresh),
          ),
          if (!_isText) ...[
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Suggestions — tap to add:',
                  style: TextStyle(
                      color: _secondary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in suggestions)
                    ActionChip(
                      label:
                          Text(s, style: const TextStyle(fontSize: 12.5)),
                      onPressed: () => _insert(
                          s == 'PCT_CHANGE' ? 'PCT_CHANGE(' : s,
                          replaceWord: true),
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: _blue),
                      labelStyle: const TextStyle(color: _blue),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in signs)
                  OutlinedButton(
                    onPressed: () =>
                        _insert(s.length > 1 ? ' $s ' : s),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      side: const BorderSide(color: _hairline),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(s, style: const TextStyle(fontSize: 14)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_error!,
                  style: const TextStyle(color: _red, fontSize: 12.5)),
            )
          else if (_checkSide != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _blue),
              ),
              child: Text.rich(signalHighlightSpan(
                '$_dartType ${_nameCtrl.text.trim()} = '
                '${_checkSide!.formula};',
                variables: widget.contextVars,
                base: const TextStyle(
                    color: _text, fontSize: 13, fontFamily: 'monospace'),
              )),
            )
          else if (_checkLine != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _blue),
              ),
              child: Text(
                'This value is TRUE when '
                '${compareMeaning(_checkLine!.compare)}.',
                style:
                    const TextStyle(color: _secondary, fontSize: 12.5),
              ),
            ),
          if (widget.contextVars.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'This variable can use: '
              '${widget.contextVars.map((v) => v.name).join(', ')} '
              '(the variables above it) plus all terms.',
              style: const TextStyle(color: _hint, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }
}
