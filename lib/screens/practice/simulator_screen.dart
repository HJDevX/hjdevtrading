import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/practice/replay_screen.dart';
import 'package:hjdev_trading/services/sim_broker.dart';
import 'package:hjdev_trading/services/simulator_service.dart';

/// SIMULATOR SETUP — pick a real stock, a past date, a candle
/// interval and a playback speed; optionally pre-place orders; then
/// START moves to the replay screen, which replays that day's REAL
/// market candles (fetched free from Yahoo Finance history — Kotak
/// has no historical-data API).
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _PickedStock {
  final String symbol;
  final String displayName;
  final String segment;
  final String? token;
  final String? instrumentType;

  const _PickedStock({
    required this.symbol,
    required this.displayName,
    required this.segment,
    this.token,
    this.instrumentType,
  });

  String? get yahooSymbol => HistoryService.yahooSymbolFor(
        segment: segment,
        symbol: symbol,
        token: token,
        instrumentType: instrumentType,
      );
}

class _DraftRow {
  String side = 'B';
  int qty = 1;
  String triggerType = 'MARKET'; // MARKET | TIME | PRICE
  double? triggerPrice;
  TimeOfDay? triggerTime;

  /// Optional target on a BUY: exact price, or % above the fill.
  double? targetPrice;
  double? targetPct;

  String describe(DateTime date) {
    final sideText = side == 'B' ? 'BUY' : 'SELL';
    String base;
    switch (triggerType) {
      case 'TIME':
        final t = triggerTime;
        final when = t == null
            ? ''
            : ' at ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        base = '$sideText $qty$when (time — any price)';
        break;
      case 'PRICE':
        base = '$sideText $qty at ₹${triggerPrice?.toStringAsFixed(2) ?? '—'} (when price reaches it)';
        break;
      default:
        base = '$sideText $qty at market (start price)';
    }
    if (side == 'B' && targetPrice != null) {
      base += ' → target ₹${targetPrice!.toStringAsFixed(2)}';
    } else if (side == 'B' && targetPct != null) {
      base += ' → target +${targetPct!.toStringAsFixed(1)}%';
    }
    return base;
  }
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  final AppDb _db = AppDb.instance;

  static const Color _bg = Color(0xFFFFFFFF);
  static const Color _card = Color(0xFFF7F7F7);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _purple = Color(0xFF387ED1);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  final TextEditingController _searchCtrl = TextEditingController();
  List<Scrip> _searchResults = [];
  List<WatchItem> _watchItems = [];
  _PickedStock? _picked;

  DateTime _date = _lastWeekday();
  IntervalSpec _spec = IntervalSpec.byId('5m');
  double _speed = 10;
  static const List<double> _speedChips = [1, 2, 5, 10, 30, 60];

  final List<_DraftRow> _drafts = [];
  bool _starting = false;

  static DateTime _lastWeekday() {
    var d = DateTime.now().subtract(const Duration(days: 1));
    while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      d = d.subtract(const Duration(days: 1));
    }
    return DateTime(d.year, d.month, d.day);
  }

  @override
  void initState() {
    super.initState();
    _loadWatchItems();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWatchItems() async {
    final lists = await _db.getWatchlists();
    final seen = <String>{};
    final items = <WatchItem>[];
    for (final list in lists) {
      if (list.id == null) continue;
      for (final it in await _db.getItems(list.id!)) {
        final key = '${it.exchange}|${it.token ?? it.symbol}';
        if (seen.add(key)) items.add(it);
      }
    }
    if (!mounted) return;
    setState(() => _watchItems = items);
  }

  Future<void> _runSearch(String q) async {
    if (q.trim().length < 2) {
      setState(() => _searchResults = []);
      return;
    }
    final results = await _db.searchScrips(q.trim());
    if (!mounted) return;
    setState(() => _searchResults = results
        .where((s) => s.instrumentType == 'EQ')
        .take(15)
        .toList());
  }

  void _snack(String msg, {bool green = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: green ? Colors.green.shade700 : Colors.red.shade700,
    ));
  }

  // ---------------- start ----------------

  Future<void> _start() async {
    final picked = _picked;
    if (picked == null) {
      _snack('Pick a stock first');
      return;
    }
    final yahoo = picked.yahooSymbol;
    if (yahoo == null) {
      _snack(
          'No history for futures/options — pick a stock or NIFTY/SENSEX');
      return;
    }
    setState(() => _starting = true);
    try {
      final candles = await HistoryService.instance.fetchCandles(
        yahooSymbol: yahoo,
        spec: _spec,
        date: _date,
      );
      if (!mounted) return;
      final drafts = _drafts.map((d) {
        int? timeMs;
        if (d.triggerType == 'TIME' && d.triggerTime != null) {
          timeMs = DateTime(_date.year, _date.month, _date.day,
                  d.triggerTime!.hour, d.triggerTime!.minute)
              .millisecondsSinceEpoch;
        }
        return OrderDraft(
          side: d.side,
          qty: d.qty,
          triggerType: d.triggerType,
          triggerPrice: d.triggerPrice,
          triggerTimeMs: timeMs,
          targetPrice: d.targetPrice,
          targetPct: d.targetPct,
        );
      }).toList();
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReplayScreen(
          title: picked.symbol,
          candles: candles,
          spec: _spec,
          initialSpeed: _speed,
          drafts: drafts,
        ),
      ));
    } on HistoryException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('Could not load history: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Simulator',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),
            Chip(
              label: const Text('REPLAY',
                  style: TextStyle(
                      fontSize: 11,
                      color: _purple,
                      fontWeight: FontWeight.bold)),
              backgroundColor: _purple.withAlpha(40),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _availabilityCard(),
          const SizedBox(height: 16),
          _sectionTitle('1. Pick a stock'),
          _stockPicker(),
          const SizedBox(height: 16),
          _sectionTitle('2. Pick a date and candle size'),
          _dateAndInterval(),
          const SizedBox(height: 16),
          _sectionTitle('3. Playback speed'),
          _speedPicker(),
          const SizedBox(height: 16),
          _sectionTitle('4. Orders to place at start (optional)'),
          _draftsSection(),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_starting ? 'Loading history...' : 'START SIMULATION'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _purple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Real past market data — no fake prices. Futures/options have no free history; stocks and NIFTY/SENSEX/BANKNIFTY work.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              color: Color(0xFF424242),
              fontSize: 14.5,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _availabilityCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How much old data do we have?',
              style: TextStyle(
                  color: Color(0xFF424242),
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            'History comes free from Yahoo Finance (Kotak has no history API). This is how far back each candle size goes:',
            style: TextStyle(color: Color(0xFF666666), fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...IntervalSpec.all.map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text('${s.label} candles',
                          style: const TextStyle(
                              color: Color(0xFF666666), fontSize: 12.5)),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(s.rangeText,
                          style: const TextStyle(
                              color: _purple,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _stockPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_picked != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _blue.withAlpha(35),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _blue.withAlpha(90)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: _blue, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_picked!.symbol,
                          style: const TextStyle(
                              color: Color(0xFF424242),
                              fontWeight: FontWeight.bold)),
                      Text(_picked!.displayName,
                          style: const TextStyle(
                              color: Color(0xFF666666), fontSize: 11.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (_picked!.yahooSymbol == null)
                  const Text('no history',
                      style: TextStyle(color: _red, fontSize: 11.5))
                else
                  Text(_picked!.yahooSymbol!,
                      style: const TextStyle(
                          color: Color(0xFF9B9B9B), fontSize: 11.5)),
              ],
            ),
          ),
        TextField(
          controller: _searchCtrl,
          style: const TextStyle(color: Color(0xFF424242)),
          decoration: InputDecoration(
            hintText: 'Search any stock (from the downloaded list)',
            hintStyle: const TextStyle(color: Color(0xFF9B9B9B)),
            prefixIcon: const Icon(Icons.search, color: Color(0xFF9B9B9B)),
            filled: true,
            fillColor: _card,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: _runSearch,
        ),
        if (_searchResults.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: _searchResults
                  .map((s) => ListTile(
                        dense: true,
                        title: Text(s.symbol,
                            style: const TextStyle(
                                color: Color(0xFF424242), fontSize: 13.5)),
                        subtitle: Text(s.displayName,
                            style: const TextStyle(
                                color: Color(0xFF9B9B9B), fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        onTap: () {
                          setState(() {
                            _picked = _PickedStock(
                              symbol: s.symbol,
                              displayName: s.displayName,
                              segment: s.segment,
                              token: s.token,
                              instrumentType: s.instrumentType,
                            );
                            _searchResults = [];
                            _searchCtrl.clear();
                          });
                        },
                      ))
                  .toList(),
            ),
          ),
        if (_watchItems.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Or pick from your watchlists:',
              style: TextStyle(color: Color(0xFF666666), fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _watchItems.map((it) {
              final hasHistory = HistoryService.yahooSymbolFor(
                    segment: it.exchange,
                    symbol: it.symbol,
                    token: it.token,
                    instrumentType: it.instrumentType,
                  ) !=
                  null;
              final selected = _picked?.symbol == it.symbol &&
                  _picked?.segment == it.exchange;
              return ChoiceChip(
                label: Text(it.symbol),
                selected: selected,
                onSelected: hasHistory
                    ? (_) => setState(() => _picked = _PickedStock(
                          symbol: it.symbol,
                          displayName: it.displayName,
                          segment: it.exchange,
                          token: it.token,
                          instrumentType: it.instrumentType,
                        ))
                    : null,
                selectedColor: _blue,
                backgroundColor: _card,
                labelStyle: TextStyle(
                    color: selected
                        ? Colors.white
                        : hasHistory
                            ? Color(0xFF424242)
                            : Color(0xFF9B9B9B),
                    fontSize: 12.5),
                side: BorderSide.none,
              );
            }).toList(),
          ),
          const Text('Greyed-out = futures/options (no free history)',
              style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 11)),
        ],
      ],
    );
  }

  Widget _dateAndInterval() {
    final firstDate =
        DateTime.now().subtract(Duration(days: _spec.maxDaysBack));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: _date.isBefore(firstDate) ? firstDate : _date,
              firstDate: firstDate,
              lastDate: DateTime.now(),
            );
            if (picked != null) setState(() => _date = picked);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                const Icon(Icons.calendar_month,
                    color: Color(0xFF666666), size: 19),
                const SizedBox(width: 10),
                Text(
                  '${_date.day}/${_date.month}/${_date.year}',
                  style:
                      const TextStyle(color: Color(0xFF424242), fontSize: 14.5),
                ),
                const Spacer(),
                const Text('tap to change',
                    style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: IntervalSpec.all.map((s) {
            final selected = _spec.id == s.id;
            return ChoiceChip(
              label: Text('${s.label} (${s.rangeText})'),
              selected: selected,
              onSelected: (_) => setState(() {
                _spec = s;
                final earliest =
                    DateTime.now().subtract(Duration(days: s.maxDaysBack));
                if (_date.isBefore(earliest)) _date = _lastWeekday();
              }),
              selectedColor: _blue,
              backgroundColor: _card,
              labelStyle: TextStyle(
                  color: selected ? Colors.white : Color(0xFF666666),
                  fontSize: 12.5),
              side: BorderSide.none,
            );
          }).toList(),
        ),
        if (_spec.id == '1d')
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Daily candles: the replay runs 30 trading days starting from the chosen date.',
              style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5),
            ),
          ),
      ],
    );
  }

  Widget _speedPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            ..._speedChips.map((x) => ChoiceChip(
                  label: Text('${x.toInt()}x'),
                  selected: _speed == x,
                  onSelected: (_) => setState(() => _speed = x),
                  selectedColor: _blue,
                  backgroundColor: _card,
                  labelStyle: TextStyle(
                      fontSize: 12.5,
                      color: _speed == x
                          ? Colors.white
                          : Color(0xFF424242)),
                  side: BorderSide.none,
                )),
            ChoiceChip(
              label: Text('Custom: ${_speed.toInt()}x'),
              selected: !_speedChips.contains(_speed),
              onSelected: (_) {},
              selectedColor: _blue,
              backgroundColor: _card,
              labelStyle: TextStyle(
                      fontSize: 12.5,
                      color: !_speedChips.contains(_speed)
                          ? Colors.white
                          : Color(0xFF424242)),
              side: BorderSide.none,
            ),
          ],
        ),
        Slider(
          value: _speed.clamp(1, 600),
          min: 1,
          max: 600,
          divisions: 599,
          activeColor: _blue,
          label: '${_speed.toInt()}x',
          onChanged: (v) => setState(() => _speed = v.roundToDouble()),
        ),
        Text(
          _spec.id == '1d'
              ? 'At ${_speed.toInt()}x, one day-candle takes about ${(23400 / _speed).round()} seconds'
              : 'At ${_speed.toInt()}x, a full trading day takes about ${(375 * 60 / _speed / 60).toStringAsFixed(1)} minutes',
          style: const TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5),
        ),
      ],
    );
  }

  // ---------------- pre-order drafts ----------------

  Widget _draftsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._drafts.asMap().entries.map((e) => Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(
                    e.value.side == 'B'
                        ? Icons.arrow_circle_up
                        : Icons.arrow_circle_down,
                    color: e.value.side == 'B' ? _green : _red,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(e.value.describe(_date),
                        style: const TextStyle(
                            color: Color(0xFF424242), fontSize: 13)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFF9B9B9B), size: 19),
                    onPressed: () =>
                        setState(() => _drafts.removeAt(e.key)),
                  ),
                ],
              ),
            )),
        OutlinedButton.icon(
          onPressed: _addDraft,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add an order'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _blue,
            side: const BorderSide(color: _blue),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Three kinds: at market (fills at the start price), at a time (fills when the clock reaches it, at any price), at a price (fills when the price reaches your price). A BUY can also carry a target — a price or a % gain — and the simulator sells automatically when the price hits it.',
          style: TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5),
        ),
      ],
    );
  }

  Future<void> _addDraft() async {
    final draft = _DraftRow();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController();
    final targetCtrl = TextEditingController();
    var targetMode = 'NONE'; // NONE | PRICE | PCT (BUY orders only)
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('Order at start',
              style: TextStyle(color: Color(0xFF424242), fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('BUY'),
                      selected: draft.side == 'B',
                      onSelected: (_) => setDlg(() => draft.side = 'B'),
                      selectedColor: _green,
                      labelStyle: TextStyle(
                          color: draft.side == 'B'
                              ? Colors.white
                              : Color(0xFF424242)),
                      side: BorderSide.none,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('SELL'),
                      selected: draft.side == 'S',
                      onSelected: (_) => setDlg(() => draft.side = 'S'),
                      selectedColor: _red,
                      labelStyle: TextStyle(
                          color: draft.side == 'S'
                              ? Colors.white
                              : Color(0xFF424242)),
                      side: BorderSide.none,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: qtyCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Color(0xFF424242)),
                      decoration: const InputDecoration(
                          labelText: 'Quantity (size)',
                          labelStyle: TextStyle(color: Color(0xFF666666))),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Color(0xFF666666)),
                    onPressed: () {
                      final q = int.tryParse(qtyCtrl.text.trim()) ?? 1;
                      if (q > 1) {
                        qtyCtrl.text = (q - 1).toString();
                        setDlg(() {});
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: Color(0xFF666666)),
                    onPressed: () {
                      final q = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                      qtyCtrl.text = (q + 1).toString();
                      setDlg(() {});
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [1, 10, 25, 50, 100].map((n) {
                  return ActionChip(
                    label: Text('$n', style: const TextStyle(fontSize: 11.5)),
                    backgroundColor: Color(0xFFF7F7F7),
                    side: BorderSide.none,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      qtyCtrl.text = n.toString();
                      setDlg(() {});
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
              DropdownButton<String>(
                value: draft.triggerType,
                dropdownColor: Colors.white,
                isExpanded: true,
                style: const TextStyle(color: Color(0xFF424242)),
                items: [
                  const DropdownMenuItem(
                      value: 'MARKET', child: Text('At market (start)')),
                  if (_spec.id != '1d')
                    const DropdownMenuItem(
                        value: 'TIME', child: Text('At a time')),
                  const DropdownMenuItem(
                      value: 'PRICE', child: Text('At a price')),
                ],
                onChanged: (v) =>
                    setDlg(() => draft.triggerType = v ?? 'MARKET'),
              ),
              if (draft.triggerType == 'TIME')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    draft.triggerTime == null
                        ? 'Pick a time'
                        : 'At ${draft.triggerTime!.hour.toString().padLeft(2, '0')}:${draft.triggerTime!.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Color(0xFF424242)),
                  ),
                  trailing: const Icon(Icons.schedule, color: Color(0xFF666666)),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: ctx,
                      initialTime:
                          draft.triggerTime ?? const TimeOfDay(hour: 10, minute: 0),
                    );
                    if (t != null) setDlg(() => draft.triggerTime = t);
                  },
                ),
              if (draft.triggerType == 'PRICE')
                TextField(
                  controller: priceCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: Color(0xFF424242)),
                  decoration: const InputDecoration(
                      labelText: 'Trigger price ₹',
                      labelStyle: TextStyle(color: Color(0xFF666666))),
                ),
              if (draft.side == 'B') ...[
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Target — auto-sell when the price hits it',
                      style: TextStyle(color: Color(0xFF666666), fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ChoiceChip(
                      label: const Text('No target',
                          style: TextStyle(fontSize: 11.5)),
                      selected: targetMode == 'NONE',
                      onSelected: (_) => setDlg(() => targetMode = 'NONE'),
                      selectedColor: _blue,
                      labelStyle: TextStyle(
                          fontSize: 11.5,
                          color: targetMode == 'NONE'
                              ? Colors.white
                              : Color(0xFF424242)),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('Price ₹',
                          style: TextStyle(fontSize: 11.5)),
                      selected: targetMode == 'PRICE',
                      onSelected: (_) => setDlg(() => targetMode = 'PRICE'),
                      selectedColor: _blue,
                      labelStyle: TextStyle(
                          fontSize: 11.5,
                          color: targetMode == 'PRICE'
                              ? Colors.white
                              : Color(0xFF424242)),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('% gain',
                          style: TextStyle(fontSize: 11.5)),
                      selected: targetMode == 'PCT',
                      onSelected: (_) => setDlg(() => targetMode = 'PCT'),
                      selectedColor: _blue,
                      labelStyle: TextStyle(
                          fontSize: 11.5,
                          color: targetMode == 'PCT'
                              ? Colors.white
                              : Color(0xFF424242)),
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                if (targetMode != 'NONE')
                  TextField(
                    controller: targetCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Color(0xFF424242)),
                    decoration: InputDecoration(
                        labelText: targetMode == 'PRICE'
                            ? 'Target price ₹'
                            : 'Target % above buy price',
                        labelStyle:
                            const TextStyle(color: Color(0xFF666666))),
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    draft.qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
    if (draft.qty <= 0) {
      _snack('Quantity must be more than 0');
      return;
    }
    if (draft.triggerType == 'TIME' && draft.triggerTime == null) {
      _snack('Pick a time for the time order');
      return;
    }
    if (draft.triggerType == 'PRICE') {
      draft.triggerPrice = double.tryParse(priceCtrl.text.trim());
      if (draft.triggerPrice == null || draft.triggerPrice! <= 0) {
        _snack('Enter a valid trigger price');
        return;
      }
    }
    if (draft.side == 'B' && targetMode != 'NONE') {
      final tv = double.tryParse(targetCtrl.text.trim());
      if (tv == null || tv <= 0) {
        _snack('Enter a valid target');
        return;
      }
      if (targetMode == 'PRICE') {
        draft.targetPrice = tv;
      } else {
        draft.targetPct = tv;
      }
    }
    setState(() => _drafts.add(draft));
  }
}
