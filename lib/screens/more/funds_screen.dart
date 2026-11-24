import 'package:flutter/material.dart';
import 'package:hjdev_trading/services/paper_broker.dart';

/// FUNDS — the paper VIRTUAL FUND, reached from More (it left the
/// bottom bar in the Kite redesign). Same derived balance as
/// everywhere else: available = starting fund + booked P&L −
/// margin blocked in open positions. The starting amount is
/// editable from the pencil button, exactly as in Practice.
class FundsScreen extends StatefulWidget {
  const FundsScreen({super.key});

  @override
  State<FundsScreen> createState() => _FundsScreenState();
}

class _FundsScreenState extends State<FundsScreen> {
  PaperFundInfo? _fund;

  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    _loadFund();
    PaperBroker.revisionNotifier.addListener(_loadFund);
  }

  @override
  void dispose() {
    PaperBroker.revisionNotifier.removeListener(_loadFund);
    super.dispose();
  }

  Future<void> _loadFund() async {
    final fund = await PaperBroker.instance.fundInfo();
    if (!mounted) return;
    setState(() => _fund = fund);
  }

  String _fmtMoney(double v) =>
      '${v < 0 ? '-' : ''}₹${v.abs().toStringAsFixed(2)}';

  /// Edit the virtual fund's starting amount — the same dialog
  /// and rules as the pencil button in Practice.
  Future<void> _editFund() async {
    final current = _fund?.startingFund ?? 100000;
    final ctrl =
        TextEditingController(text: current.toStringAsFixed(0));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Edit virtual fund',
            style: TextStyle(color: _text, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: _text),
              decoration: const InputDecoration(
                labelText: 'Starting fund (₹)',
                labelStyle: TextStyle(color: _secondary),
                prefixText: '₹ ',
                prefixStyle: TextStyle(color: _secondary),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Available = fund + booked P&L − margin blocked in open '
              'positions. If the new fund is smaller than the blocked '
              'margin, new buys stop until you sell something.',
              style: TextStyle(color: _hint, fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fund must be more than ₹0'),
          backgroundColor: Colors.red));
      return;
    }
    await PaperBroker.instance.setStartingFund(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text('Virtual fund set to ₹${value.toStringAsFixed(0)}'),
      backgroundColor: Colors.green.shade700,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final fund = _fund;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Funds',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Edit virtual fund',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editFund,
          ),
        ],
      ),
      body: fund == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(4),
                    border:
                        Border.all(color: const Color(0xFFE0E0E0)),
                  ),
                  child: Column(
                    children: [
                      _row('Virtual fund (start)',
                          _fmtMoney(fund.startingFund)),
                      _row(
                        'Booked (realized) P&L',
                        _fmtMoney(fund.realizedPnl),
                        color: fund.realizedPnl >= 0 ? _green : _red,
                      ),
                      _row('Margin blocked',
                          _fmtMoney(fund.marginBlocked)),
                      const Divider(
                          color: Color(0xFFE0E0E0), height: 20),
                      _row('Available fund', _fmtMoney(fund.available),
                          bold: true),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Equity buys block only 1/5th (5x MTF leverage); '
                  'F&O blocks full value. This is paper money only — '
                  'no real funds are involved.',
                  style: TextStyle(color: _hint, fontSize: 11.5),
                ),
              ],
            ),
    );
  }

  Widget _row(String label, String value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style:
                    const TextStyle(color: _secondary, fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color ?? _text,
                    fontSize: 13,
                    fontWeight:
                        bold ? FontWeight.bold : FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
