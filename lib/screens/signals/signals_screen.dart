import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/signal.dart';
import 'package:hjdev_trading/screens/signals/signal_builder_screen.dart';

/// SIGNALS tab — the user's own signals, created in the Signal
/// Builder and saved on the phone (Signal Maths language).
/// EMPTY by default: nothing is pre-loaded; the user creates his
/// own. This step is create + save only — no engine watches the
/// signals yet, so nothing here places trades.
class SignalsScreen extends StatefulWidget {
  const SignalsScreen({super.key});

  @override
  State<SignalsScreen> createState() => _SignalsScreenState();
}

class _SignalsScreenState extends State<SignalsScreen> {
  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  final AppDb _db = AppDb.instance;
  List<SignalDef> _signals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final signals = await _db.getSignals();
    if (!mounted) return;
    setState(() {
      _signals = signals;
      _loading = false;
    });
  }

  Future<void> _create() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const SignalBuilderScreen()),
    );
    if (saved == true) _load();
  }

  Future<void> _editSignal(SignalDef s) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => SignalBuilderScreen(existing: s)),
    );
    if (saved == true) _load();
  }

  Future<void> _deleteSignal(SignalDef s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete signal?', style: TextStyle(fontSize: 16)),
        content: Text('"${s.name}" will be removed from this phone.',
            style: const TextStyle(color: _secondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: _red))),
        ],
      ),
    );
    if (ok != true || s.id == null) return;
    await _db.deleteSignal(s.id!);
    _load();
  }

  Future<void> _toggleEnabled(SignalDef s, bool value) async {
    final updated = s.copyWith(enabled: value);
    await _db.updateSignal(updated);
    if (!mounted) return;
    setState(() {
      _signals = [
        for (final x in _signals) x.id == s.id ? updated : x,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Signals',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Create a new signal',
            icon: const Icon(Icons.add, color: _blue),
            onPressed: _create,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        backgroundColor: _blue,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Create signal',
            style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _signals.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                    children: [
                      const Text(
                        'Your signals, in your own Signal Maths. The '
                        'live engine that watches them arrives in the '
                        'next step — creating a signal places no '
                        'trades yet.',
                        style:
                            TextStyle(color: _secondary, fontSize: 12.5),
                      ),
                      const SizedBox(height: 14),
                      for (final s in _signals) _signalCard(s),
                    ],
                  ),
                ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.functions, color: _hint, size: 44),
            const SizedBox(height: 14),
            const Text(
              'No signals yet',
              style: TextStyle(
                  color: _text, fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create your first signal in your own maths language: '
              'pick a stock, add indicators, and build maths lines '
              'by tapping terms and signs. When a signal\'s score '
              'reaches 100%, it is TRUE.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _secondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create your first signal'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signalCard(SignalDef s) {
    final firstLine = s.indicators.isNotEmpty &&
            s.indicators.first.lines.isNotEmpty
        ? s.indicators.first.lines.first.render()
        : 'No maths lines yet';
    final extraLines = s.lineCount - 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _hairline),
      ),
      child: InkWell(
        onTap: () => _editSignal(s),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(s.name,
                        style: const TextStyle(
                            color: _text,
                            fontSize: 15,
                            fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (s.isBuy ? _blue : _red).withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(s.isBuy ? 'BUY' : 'SELL',
                        style: TextStyle(
                            color: s.isBuy ? _blue : _red,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${s.symbol} • ${s.displayName}',
                style: const TextStyle(color: _secondary, fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                extraLines > 0
                    ? '$firstLine  (+$extraLines more)'
                    : firstLine,
                style: const TextStyle(
                    color: _text, fontSize: 12.5, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 6),
              Text(
                '${s.variables.isNotEmpty ? '${s.variables.length} variable${s.variables.length == 1 ? '' : 's'} • ' : ''}'
                '${s.indicators.length} indicator${s.indicators.length == 1 ? '' : 's'}'
                ' • ${s.lineCount} maths line${s.lineCount == 1 ? '' : 's'}'
                ' • Qty ${s.qty}'
                '${s.tpPct != null ? ' • TP +${s.tpPct}%' : ''}'
                '${s.slPct != null ? ' • SL −${s.slPct}%' : ''}',
                style: const TextStyle(color: _hint, fontSize: 11.5),
              ),
              const Divider(color: _hairline, height: 18),
              Row(
                children: [
                  Text(s.enabled ? 'On' : 'Off',
                      style: TextStyle(
                          color: s.enabled ? _green : _hint,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                  Switch(
                    value: s.enabled,
                    onChanged: (v) => _toggleEnabled(s, v),
                    activeColor: _blue,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Edit signal',
                    icon: const Icon(Icons.edit_outlined,
                        color: _secondary, size: 19),
                    onPressed: () => _editSignal(s),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: 'Delete signal',
                    icon: const Icon(Icons.delete_outline,
                        color: _red, size: 19),
                    onPressed: () => _deleteSignal(s),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
