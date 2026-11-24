import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/signal.dart';
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
    return showDialog<SignalLine>(
      context: context,
      builder: (_) => _LineEditorDialog(existing: existing),
    );
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
                    child: Text(ind.lines[j].render(),
                        style: const TextStyle(
                            color: _text,
                            fontSize: 13,
                            fontFamily: 'monospace')),
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

/// The maths-line editor — TWO ways to build the same line
/// (design §10):
///  • TAP BUILDER (easy way): tap terms, numbers, times and
///    signs; quick examples fill a whole line in one tap.
///  • STOCK IDE (type way): type the line as text — the editor
///    suggests terms as you type — and the parser reads it back
///    into the exact same stored form.
/// Either way the finished line's answer is TRUE or FALSE, and
/// the two sides' types are checked before saving.
class _LineEditorDialog extends StatefulWidget {
  final SignalLine? existing;
  const _LineEditorDialog({this.existing});

  @override
  State<_LineEditorDialog> createState() => _LineEditorDialogState();
}

class _LineEditorDialogState extends State<_LineEditorDialog> {
  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  // Tap-builder state.
  final List<MathsAtom> _leftAtoms = [];
  final List<String> _leftOps = [];
  final List<MathsAtom> _rightAtoms = [];
  final List<String> _rightOps = [];
  final List<MathsAtom> _right2Atoms = [];
  final List<String> _right2Ops = [];
  String _compare = '>=';
  String? _error;

  // Stock IDE state.
  bool _typeMode = false;
  final TextEditingController _ideCtrl = TextEditingController();
  SignalLine? _ideLine;
  String? _ideError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) _loadLine(e);
  }

  @override
  void dispose() {
    _ideCtrl.dispose();
    super.dispose();
  }

  void _loadLine(SignalLine e) {
    _leftAtoms
      ..clear()
      ..addAll(e.left.atoms);
    _leftOps
      ..clear()
      ..addAll(e.left.ops);
    _rightAtoms
      ..clear()
      ..addAll(e.right.atoms);
    _rightOps
      ..clear()
      ..addAll(e.right.ops);
    _right2Atoms.clear();
    _right2Ops.clear();
    if (e.right2 != null) {
      _right2Atoms.addAll(e.right2!.atoms);
      _right2Ops.addAll(e.right2!.ops);
    }
    _compare = e.compare;
  }

  bool get _needsRight2 => _compare == 'BETWEEN' || _compare == 'OUTSIDE';

  MathsSide _side(List<MathsAtom> atoms, List<String> ops) =>
      MathsSide(atoms: List.of(atoms), ops: List.of(ops));

  SignalLine _currentLine() => SignalLine(
        left: _side(_leftAtoms, _leftOps),
        compare: _compare,
        right: _side(_rightAtoms, _rightOps),
        right2: _needsRight2 ? _side(_right2Atoms, _right2Ops) : null,
      );

  // ---------------- Mode switching ----------------

  void _toTypeMode() {
    final line = _currentLine();
    _ideCtrl.text =
        (line.left.isEmpty && line.right.isEmpty) ? '' : line.formula;
    _ideRefresh();
    setState(() => _typeMode = true);
  }

  void _toTapMode() {
    if (_ideCtrl.text.trim().isNotEmpty) {
      final r = parseSignalLine(_ideCtrl.text);
      if (r.line == null) {
        setState(() => _ideError = r.error);
        return;
      }
      _loadLine(r.line!);
    }
    setState(() {
      _typeMode = false;
      _error = null;
    });
  }

  // ---------------- Stock IDE helpers ----------------

  void _ideRefresh() {
    final text = _ideCtrl.text;
    if (text.trim().isEmpty) {
      _ideLine = null;
      _ideError = null;
      return;
    }
    final r = parseSignalLine(text);
    _ideLine = r.line;
    _ideError = r.error;
  }

  /// Term suggestions for the word currently being typed.
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
      for (final t in kSignalTerms) t.code,
      ...words,
    ];
    return [
      for (final c in all)
        if (c.startsWith(partial) && c != partial) c,
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

  // ---------------- Atom picking (tap builder) ----------------

  Future<SignalTerm?> _pickTerm(String title) {
    return showDialog<SignalTerm>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final t in kSignalTerms)
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
                  trailing: Text(t.type,
                      style: const TextStyle(color: _blue, fontSize: 10.5)),
                  onTap: () => Navigator.pop(ctx, t),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<double?> _pickNumber() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Number', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: const InputDecoration(hintText: 'e.g. 0.7, 40, 1.5'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (text == null) return null;
    return double.tryParse(text);
  }

  Future<void> _addAtom(
      List<MathsAtom> atoms, List<String> ops, MathsAtom? atom) async {
    if (atom == null) return;
    setState(() {
      if (atoms.isNotEmpty) ops.add('+');
      atoms.add(atom);
      _error = null;
    });
  }

  Future<void> _addTerm(List<MathsAtom> atoms, List<String> ops) async {
    final t = await _pickTerm('Pick a term');
    if (t != null) await _addAtom(atoms, ops, MathsAtom.term(t.code));
  }

  Future<void> _addNumber(List<MathsAtom> atoms, List<String> ops) async {
    final v = await _pickNumber();
    if (v != null) await _addAtom(atoms, ops, MathsAtom.number(v));
  }

  Future<void> _addTime(List<MathsAtom> atoms, List<String> ops) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 10, minute: 15),
    );
    if (picked != null) {
      await _addAtom(
          atoms, ops, MathsAtom.time(picked.hour * 60 + picked.minute));
    }
  }

  Future<void> _addPctChange(
      List<MathsAtom> atoms, List<String> ops) async {
    final a = await _pickTerm('PCT_CHANGE — first term (the value)');
    if (a == null) return;
    final b = await _pickTerm('PCT_CHANGE — second term (the base)');
    if (b == null) return;
    await _addAtom(atoms, ops, MathsAtom.pctChange(a.code, b.code));
  }

  void _removeAtom(List<MathsAtom> atoms, List<String> ops, int idx) {
    setState(() {
      atoms.removeAt(idx);
      if (idx > 0) {
        ops.removeAt(idx - 1);
      } else if (ops.isNotEmpty) {
        ops.removeAt(0);
      }
    });
  }

  void _cycleOp(List<String> ops, int idx) {
    const cycle = ['+', '-', '*', '/'];
    setState(() {
      final cur = cycle.indexOf(ops[idx]);
      ops[idx] = cycle[(cur + 1) % cycle.length];
    });
  }

  void _applyExample(SignalLine line) {
    setState(() {
      _loadLine(line);
      _error = null;
    });
  }

  // ---------------- Save ----------------

  void _save() {
    if (_typeMode) {
      final r = parseSignalLine(_ideCtrl.text);
      if (r.line == null) {
        setState(() => _ideError = r.error);
        return;
      }
      Navigator.pop(context, r.line);
      return;
    }
    final line = _currentLine();
    if (!line.isComplete) {
      setState(() => _error = _needsRight2
          ? 'Fill the left side, the right side AND the upper bound'
          : 'Fill both the left and the right side');
      return;
    }
    final err = line.typeError;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, line);
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text(
          widget.existing == null ? 'Add maths line' : 'Edit maths line',
          style: const TextStyle(color: _text, fontSize: 16)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Build one line whose answer is TRUE or FALSE.',
              style: TextStyle(color: _secondary, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: const Text('Tap Builder'),
                    selected: !_typeMode,
                    onSelected: (_) {
                      if (_typeMode) _toTapMode();
                    },
                    selectedColor: _blue,
                    labelStyle: TextStyle(
                        color: !_typeMode ? Colors.white : _text,
                        fontSize: 12.5),
                    side: BorderSide.none,
                    backgroundColor: _panel,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: const Text('Stock IDE — type it'),
                    selected: _typeMode,
                    onSelected: (_) {
                      if (!_typeMode) _toTypeMode();
                    },
                    selectedColor: _blue,
                    labelStyle: TextStyle(
                        color: _typeMode ? Colors.white : _text,
                        fontSize: 12.5),
                    side: BorderSide.none,
                    backgroundColor: _panel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_typeMode) _ideEditor() else _tapEditor(),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
          onPressed: _save,
          child: const Text('Save line',
              style: TextStyle(color: _blue, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  // ---------------- Tap builder UI ----------------

  Widget _tapEditor() {
    final line = _currentLine();
    final typeErr = line.typeError;
    final showExamples = _leftAtoms.isEmpty && _rightAtoms.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showExamples) ...[
          const Text('Quick examples — tap one to start:',
              style: TextStyle(
                  color: _secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _exampleChip('Gap up 0.7%',
                  SignalLine(
                    left: MathsSide(atoms: [
                      MathsAtom.pctChange('OPEN', 'PREV_CLOSE')
                    ]),
                    compare: '>=',
                    right: MathsSide(atoms: [MathsAtom.number(0.7)]),
                  )),
              _exampleChip('Price above open',
                  SignalLine(
                    left: MathsSide(atoms: [MathsAtom.term('PRICE')]),
                    compare: '>=',
                    right: MathsSide(atoms: [MathsAtom.term('OPEN')]),
                  )),
              _exampleChip('Time 10:15 or later',
                  SignalLine(
                    left: MathsSide(atoms: [MathsAtom.term('TIME_NOW')]),
                    compare: '>=',
                    right: MathsSide(atoms: [MathsAtom.time(615)]),
                  )),
              _exampleChip('Up 1% today',
                  SignalLine(
                    left:
                        MathsSide(atoms: [MathsAtom.term('CHANGE_PCT')]),
                    compare: '>=',
                    right: MathsSide(atoms: [MathsAtom.number(1)]),
                  )),
            ],
          ),
          const SizedBox(height: 14),
        ],
        _sideBuilder('LEFT — calculate this', _leftAtoms, _leftOps),
        const SizedBox(height: 12),
        const Text('COMPARE — the test',
            style: TextStyle(
                color: _secondary,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final op in kCompareOps)
              ChoiceChip(
                label: Text(compareLabel(op)),
                selected: _compare == op,
                onSelected: (_) => setState(() {
                  _compare = op;
                  _error = null;
                }),
                selectedColor: _blue,
                labelStyle: TextStyle(
                    color: _compare == op ? Colors.white : _text,
                    fontSize: 12),
                side: BorderSide.none,
                backgroundColor: _panel,
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 12),
        _sideBuilder(
            _needsRight2
                ? 'RIGHT — compare with this (lower bound)'
                : 'RIGHT — compare with this',
            _rightAtoms,
            _rightOps),
        if (_needsRight2) ...[
          const SizedBox(height: 12),
          _sideBuilder('AND — upper bound', _right2Atoms, _right2Ops),
        ],
        const SizedBox(height: 14),
        _previewBox(
          line.render(),
          'This line is TRUE when ${compareMeaning(_compare)}.',
          error: _error ?? typeErr,
        ),
        const SizedBox(height: 6),
        Text(
          'Types — left: ${_side(_leftAtoms, _leftOps).type} • '
          'right: ${_side(_rightAtoms, _rightOps).type}',
          style: const TextStyle(color: _hint, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _exampleChip(String label, SignalLine line) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: () => _applyExample(line),
      backgroundColor: Colors.white,
      side: const BorderSide(color: _blue),
      labelStyle: const TextStyle(color: _blue),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _sideBuilder(
      String label, List<MathsAtom> atoms, List<String> ops) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: _secondary,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _hairline),
          ),
          child: atoms.isEmpty
              ? const Text('Nothing yet — add a term, number or time below',
                  style: TextStyle(color: _hint, fontSize: 12))
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < atoms.length; i++) ...[
                      _atomChip(atoms, ops, i),
                      if (i < ops.length) _opChip(ops, i),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _addButton('+ Term', () => _addTerm(atoms, ops)),
            _addButton('+ Number', () => _addNumber(atoms, ops)),
            _addButton('+ Time', () => _addTime(atoms, ops)),
            _addButton('+ % Change', () => _addPctChange(atoms, ops)),
          ],
        ),
      ],
    );
  }

  Widget _atomChip(List<MathsAtom> atoms, List<String> ops, int i) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _blue),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(atoms[i].render(),
              style: const TextStyle(
                  color: _text, fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _removeAtom(atoms, ops, i),
            child: const Icon(Icons.close, size: 14, color: _red),
          ),
        ],
      ),
    );
  }

  Widget _opChip(List<String> ops, int i) {
    final op = ops[i] == '*' ? '×' : (ops[i] == '/' ? '÷' : ops[i]);
    return InkWell(
      onTap: () => _cycleOp(ops, i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: _blue,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(op,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _addButton(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: _blue,
        side: const BorderSide(color: _hairline),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }

  Widget _previewBox(String formula, String meaning, {String? error}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(formula,
              style: const TextStyle(
                  color: _text, fontSize: 13, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          Text(meaning,
              style: const TextStyle(color: _secondary, fontSize: 12)),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(error,
                style: const TextStyle(color: _red, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  // ---------------- Stock IDE UI ----------------

  Widget _ideEditor() {
    final suggestions = _ideSuggestions();
    const signs = [
      '>=', '<=', '>', '<', '=', '!=',
      '+', '-', '×', '÷', '(', ')', ',',
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ideCtrl,
          maxLines: 3,
          style: const TextStyle(
              color: _text, fontSize: 13.5, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            hintText: 'e.g. PCT_CHANGE(OPEN, PREV_CLOSE) >= 0.7',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(_ideRefresh),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Suggested terms — tap to add:',
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
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _insertSuggestion(s),
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
                onPressed: () => _insertSign(s),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _text,
                  side: const BorderSide(color: _hairline),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(s, style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_ideLine != null)
          _previewBox(
            _ideLine!.render(),
            'This line is TRUE when ${compareMeaning(_ideLine!.compare)}.',
          )
        else if (_ideError != null)
          _previewBox(
            _ideCtrl.text.trim().isEmpty ? '…' : _ideCtrl.text.trim(),
            'Not ready yet.',
            error: _ideError,
          )
        else
          const Text(
            'Start typing — terms are suggested as you type. '
            'One line: LEFT, a compare sign, RIGHT.',
            style: TextStyle(color: _hint, fontSize: 12),
          ),
      ],
    );
  }
}
