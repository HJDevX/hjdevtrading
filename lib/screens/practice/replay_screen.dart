import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/services/sim_broker.dart';
import 'package:hjdev_trading/services/simulator_service.dart';

/// THE REPLAY — one past trading session replays candle by candle
/// on a candlestick chart, at the chosen speed. The user watches the
/// price move, places market / time / price triggered orders, can
/// modify or cancel the active ones, and tracks the session
/// portfolio and P&L. Session-only: leaving this screen ends it.
class ReplayScreen extends StatefulWidget {
  final String title;
  final List<Candle> candles;
  final IntervalSpec spec;
  final double initialSpeed;
  final List<OrderDraft> drafts;

  const ReplayScreen({
    super.key,
    required this.title,
    required this.candles,
    required this.spec,
    required this.initialSpeed,
    required this.drafts,
  });

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

const Color _kBg = Color(0xFF0D1117);
const Color _kCard = Color(0xFF161B22);
const Color _kBlue = Color(0xFF2962FF);
const Color _kPurple = Color(0xFF7C4DFF);
const Color _kGreen = Color(0xFF00C853);
const Color _kRed = Color(0xFFE53935);

String _fmtMoney(double v) =>
    '${v < 0 ? '-' : ''}₹${v.abs().toStringAsFixed(2)}';

String _fmtClock(DateTime dt) {
  var hour = dt.hour;
  final ampm = hour >= 12 ? 'PM' : 'AM';
  hour = hour % 12;
  if (hour == 0) hour = 12;
  return '${hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} $ampm';
}

String _fmtDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
}

class _ReplayScreenState extends State<ReplayScreen> {
  late final ReplayEngine _engine;
  final SimBroker _broker = SimBroker();
  StreamSubscription<void>? _tickSub;

  @override
  void initState() {
    super.initState();
    _engine = ReplayEngine(
      candles: widget.candles,
      spec: widget.spec,
      speed: widget.initialSpeed,
    );
    _engine.onStep = (prev, price, timeMs) => _broker.checkTriggers(
        prevPrice: prev, price: price, timeMs: timeMs);
    _placeDrafts();
    _engine.settleAtStart();
    _tickSub = _engine.ticks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickSub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  void _placeDrafts() {
    for (final d in widget.drafts) {
      final order = _broker.placeDraft(d);
      if (d.triggerType == 'MARKET') {
        _broker.fillMarket(
            order, widget.candles.first.open, widget.candles.first.timeMs);
      }
    }
  }

  void _restartSession() {
    _engine.pause();
    _broker.reset();
    _placeDrafts();
    _engine.restart();
    _engine.settleAtStart();
    setState(() {});
  }

  void _snack(String msg, {bool green = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: green ? Colors.green.shade700 : Colors.red.shade700,
    ));
  }

  // ---------------- order forms ----------------

  Future<void> _newOrder() async {
    if (_engine.isFinished) {
      _snack('Simulation has ended — restart to trade again');
      return;
    }
    final draft = await _orderForm(context, title: 'New order');
    if (draft == null || !mounted) return;
    final order = _broker.placeDraft(draft);
    if (draft.triggerType == 'MARKET') {
      final err =
          _broker.fillMarket(order, _engine.currentPrice, _engine.simTimeMs);
      if (err != null) {
        _snack(err);
      } else {
        _snack(
            '${order.isBuy ? 'BUY' : 'SELL'} ${order.qty} @ ₹${order.fillPrice!.toStringAsFixed(2)}',
            green: true);
      }
    }
    setState(() {});
  }

  /// Shared form for new orders and modifications. Returns a draft,
  /// or null when cancelled. TIME orders are placed on the current
  /// sim date (for modify: on the order's own trigger date).
  Future<OrderDraft?> _orderForm(
    BuildContext context, {
    required String title,
    SimOrder? existing,
  }) async {
    var side = existing?.side ?? 'B';
    var type = existing?.triggerType ?? 'MARKET';
    final qtyCtrl =
        TextEditingController(text: (existing?.qty ?? 1).toString());
    final priceCtrl = TextEditingController(
        text: existing?.triggerPrice?.toStringAsFixed(2) ?? '');
    TimeOfDay? time;
    if (existing?.triggerTimeMs != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(existing!.triggerTimeMs!);
      time = TimeOfDay(hour: dt.hour, minute: dt.minute);
    }
    final result = await showDialog<OrderDraft>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _kCard,
          title: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('BUY'),
                      selected: side == 'B',
                      onSelected: existing == null
                          ? (_) => setDlg(() => side = 'B')
                          : null,
                      selectedColor: _kGreen,
                      side: BorderSide.none,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('SELL'),
                      selected: side == 'S',
                      onSelected: existing == null
                          ? (_) => setDlg(() => side = 'S')
                          : null,
                      selectedColor: _kRed,
                      side: BorderSide.none,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    labelText: 'Quantity',
                    labelStyle: TextStyle(color: Colors.white54)),
              ),
              const SizedBox(height: 10),
              DropdownButton<String>(
                value: type,
                dropdownColor: _kCard,
                isExpanded: true,
                style: const TextStyle(color: Colors.white),
                items: [
                  const DropdownMenuItem(
                      value: 'MARKET', child: Text('At market (now)')),
                  if (widget.spec.id != '1d')
                    const DropdownMenuItem(
                        value: 'TIME', child: Text('At a time')),
                  const DropdownMenuItem(
                      value: 'PRICE', child: Text('At a price')),
                ],
                onChanged: existing == null
                    ? (v) => setDlg(() => type = v ?? 'MARKET')
                    : null,
              ),
              if (type == 'TIME')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    time == null
                        ? 'Pick a time'
                        : 'At ${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing:
                      const Icon(Icons.schedule, color: Colors.white54),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: ctx,
                      initialTime: time ?? const TimeOfDay(hour: 10, minute: 0),
                    );
                    if (t != null) setDlg(() => time = t);
                  },
                ),
              if (type == 'PRICE')
                TextField(
                  controller: priceCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                      labelText: 'Trigger price ₹',
                      labelStyle: TextStyle(color: Colors.white54)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
                if (qty <= 0) return;
                int? timeMs;
                if (type == 'TIME') {
                  if (time == null) return;
                  // Date part: the existing order's date when
                  // modifying, else the current sim date.
                  final base = existing?.triggerTimeMs != null
                      ? DateTime.fromMillisecondsSinceEpoch(
                          existing!.triggerTimeMs!)
                      : _engine.simTime;
                  timeMs = DateTime(base.year, base.month, base.day,
                          time!.hour, time!.minute)
                      .millisecondsSinceEpoch;
                }
                double? price;
                if (type == 'PRICE') {
                  price = double.tryParse(priceCtrl.text.trim());
                  if (price == null || price <= 0) return;
                }
                Navigator.pop(
                  ctx,
                  OrderDraft(
                    side: side,
                    qty: qty,
                    triggerType: type,
                    triggerPrice: price,
                    triggerTimeMs: timeMs,
                  ),
                );
              },
              child: Text(existing == null ? 'Place' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null &&
        result.triggerType == 'TIME' &&
        existing == null &&
        result.triggerTimeMs! <= _engine.simTimeMs) {
      _snack('That time has already passed in the simulation');
      return null;
    }
    return result;
  }

  Future<void> _modifyOrder(SimOrder order) async {
    final draft = await _orderForm(context,
        title: 'Modify order #${order.id}', existing: order);
    if (draft == null || !mounted) return;
    final err = _broker.modify(
      order.id,
      qty: draft.qty,
      triggerPrice: draft.triggerPrice,
      triggerTimeMs: draft.triggerTimeMs,
    );
    if (err != null) {
      _snack(err);
    } else {
      _snack('Order #${order.id} updated', green: true);
    }
    setState(() {});
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final price = _engine.currentPrice;
    final dayOpen = widget.candles.first.open;
    final change = price - dayOpen;
    final changePct = dayOpen > 0 ? change / dayOpen * 100 : 0.0;
    final up = change >= 0;
    final simTime = _engine.simTime;
    final isDaily = widget.spec.id == '1d';

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: _kBg,
        appBar: AppBar(
          title: Row(
            children: [
              Flexible(
                child: Text(widget.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 10),
              Chip(
                label: const Text('SIMULATOR',
                    style: TextStyle(
                        fontSize: 11,
                        color: _kPurple,
                        fontWeight: FontWeight.bold)),
                backgroundColor: _kPurple.withAlpha(40),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            _header(price, change, changePct, up, simTime, isDaily),
            _chart(),
            _controls(isDaily),
            const TabBar(
              indicatorColor: _kPurple,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              tabs: [
                Tab(text: 'Orders'),
                Tab(text: 'Portfolio'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _ordersTab(),
                  _portfolioTab(price),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(double price, double change, double changePct, bool up,
      DateTime simTime, bool isDaily) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isDaily
                    ? _fmtDate(simTime)
                    : '${_fmtDate(simTime)} • ${_fmtClock(simTime)}',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                isDaily
                    ? 'Day ${_engine.candleIndex + 1} of ${widget.candles.length} • ${widget.spec.label} candles'
                    : 'Candle ${_engine.candleIndex + 1} of ${widget.candles.length} • ${widget.spec.label}',
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
              if (_engine.isFinished)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text('SIMULATION ENDED',
                      style: TextStyle(
                          color: _kPurple,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('₹${price.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.bold)),
              Text(
                '${up ? '+' : ''}${change.toStringAsFixed(2)} (${up ? '+' : ''}${changePct.toStringAsFixed(2)}%) vs open',
                style: TextStyle(
                    color: up ? _kGreen : _kRed,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chart() {
    final idx = _engine.candleIndex;
    // Completed candles only — the current one is drawn as the
    // partial (when finished, the last candle is the partial).
    final done = _engine.isFinished
        ? widget.candles.sublist(0, widget.candles.length - 1)
        : widget.candles.sublist(0, idx);
    final partial = _engine.partialCandle;
    final triggerPrices = _broker.activeOrders
        .where((o) => o.triggerType == 'PRICE' && o.triggerPrice != null)
        .map((o) => o.triggerPrice!)
        .toList();
    return Container(
      height: 240,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          done: done,
          partial: partial,
          triggerPrices: triggerPrices,
        ),
      ),
    );
  }

  Widget _controls(bool isDaily) {
    final start = DateTime.fromMillisecondsSinceEpoch(
        widget.candles.first.timeMs);
    final end = DateTime.fromMillisecondsSinceEpoch(
        widget.candles.last.timeMs + widget.spec.seconds * 1000);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                iconSize: 34,
                icon: Icon(
                  _engine.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  color: _engine.isFinished ? Colors.white24 : _kPurple,
                ),
                onPressed: _engine.isFinished
                    ? null
                    : () {
                        if (_engine.isPlaying) {
                          _engine.pause();
                        } else {
                          _engine.play();
                        }
                        setState(() {});
                      },
              ),
              IconButton(
                tooltip: 'Restart simulation',
                icon: const Icon(Icons.restart_alt, color: Colors.white70),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: _kCard,
                      title: const Text('Restart simulation?',
                          style:
                              TextStyle(color: Colors.white, fontSize: 16)),
                      content: const Text(
                        'The clock goes back to the start, all session trades and orders are cleared, and your start orders are placed again.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Restart')),
                      ],
                    ),
                  );
                  if (ok == true) _restartSession();
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Slider(
                  value: _engine.speed.clamp(1, 600),
                  min: 1,
                  max: 600,
                  divisions: 599,
                  activeColor: _kBlue,
                  label: '${_engine.speed.toInt()}x',
                  onChanged: (v) =>
                      _engine.setSpeed(v.roundToDouble()),
                ),
              ),
              Text('${_engine.speed.toInt()}x',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          Row(
            children: [
              Text(isDaily ? _fmtDate(start) : _fmtClock(start),
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: LinearProgressIndicator(
                    value: _engine.progress,
                    backgroundColor: Colors.white10,
                    color: _kPurple,
                    minHeight: 4,
                  ),
                ),
              ),
              Text(isDaily ? _fmtDate(end) : _fmtClock(end),
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- Orders tab ----------------

  Widget _ordersTab() {
    final active = _broker.activeOrders;
    final done = _broker.doneOrders;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              const Text('Orders',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _newOrder,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('New order'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kBlue,
                  side: const BorderSide(color: _kBlue),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: active.isEmpty && done.isEmpty
              ? const Center(
                  child: Text(
                    'No orders yet.\nPlace one — market, at a time, or at a price.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 13.5),
                  ),
                )
              : ListView(
                  children: [
                    if (active.isNotEmpty) ...[
                      _orderSectionHeader('ACTIVE (${active.length})'),
                      ...active.map(_activeOrderRow),
                    ],
                    if (done.isNotEmpty) ...[
                      _orderSectionHeader('DONE (${done.length})'),
                      ...done.map(_doneOrderRow),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _orderSectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white38,
              fontSize: 11.5,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _sideChip(SimOrder o) {
    final buy = o.isBuy;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: buy ? _kGreen.withAlpha(35) : _kRed.withAlpha(35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(buy ? 'BUY' : 'SELL',
          style: TextStyle(
              color: buy ? _kGreen : _kRed,
              fontSize: 11,
              fontWeight: FontWeight.bold)),
    );
  }

  String _orderTriggerDetail(SimOrder o) {
    switch (o.triggerType) {
      case 'TIME':
        final dt = o.triggerTimeMs != null
            ? DateTime.fromMillisecondsSinceEpoch(o.triggerTimeMs!)
            : null;
        return dt != null
            ? 'at ${_fmtClock(dt)} (any price)'
            : 'at a time';
      case 'PRICE':
        return 'when price reaches ₹${o.triggerPrice?.toStringAsFixed(2) ?? '—'}';
      default:
        return 'market';
    }
  }

  Widget _activeOrderRow(SimOrder o) {
    return ListTile(
      leading: _sideChip(o),
      title: Text('${o.qty} qty • ${_orderTriggerDetail(o)}',
          style: const TextStyle(color: Colors.white, fontSize: 13.5)),
      subtitle: Text('Order #${o.id} • waiting',
          style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Modify',
            icon: const Icon(Icons.edit, color: Colors.white54, size: 19),
            onPressed: () => _modifyOrder(o),
          ),
          IconButton(
            tooltip: 'Cancel order',
            icon: const Icon(Icons.close, color: _kRed, size: 19),
            onPressed: () {
              _broker.cancel(o.id);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _doneOrderRow(SimOrder o) {
    final statusColor = o.status == 'EXECUTED'
        ? _kGreen
        : o.status == 'FAILED'
            ? _kRed
            : Colors.white38;
    var detail = o.status;
    if (o.status == 'EXECUTED' && o.fillPrice != null) {
      final dt = o.fillTimeMs != null
          ? DateTime.fromMillisecondsSinceEpoch(o.fillTimeMs!)
          : null;
      detail =
          'filled @ ₹${o.fillPrice!.toStringAsFixed(2)}${dt != null ? ' • ${_fmtClock(dt)}' : ''}';
      if (!o.isBuy && o.realizedPnl != 0) {
        detail += ' • P&L ${_fmtMoney(o.realizedPnl)}';
      }
    } else if (o.note != null) {
      detail += ' • ${o.note}';
    }
    return ListTile(
      leading: _sideChip(o),
      title: Text('${o.qty} qty • ${o.triggerText}',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
      subtitle: Text('Order #${o.id} • $detail',
          style: TextStyle(color: statusColor, fontSize: 11.5)),
    );
  }

  // ---------------- Portfolio tab ----------------

  Widget _portfolioTab(double price) {
    final unreal = _broker.unrealizedPnl(price);
    final total = _broker.realizedPnl + unreal;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              if (_broker.positionQty > 0) ...[
                _pfRow('Holding', '${_broker.positionQty} qty'),
                _pfRow('Average price',
                    '₹${_broker.positionAvg.toStringAsFixed(2)}'),
                _pfRow('Current price', '₹${price.toStringAsFixed(2)}'),
                _pfRow('Invested', _fmtMoney(_broker.invested)),
                _pfRow('Unrealized P&L', _fmtMoney(unreal),
                    color: unreal >= 0 ? _kGreen : _kRed),
              ] else
                const Text('No open position right now',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              const Divider(color: Colors.white10, height: 20),
              _pfRow('Realized P&L (booked)', _fmtMoney(_broker.realizedPnl),
                  color: _broker.realizedPnl >= 0 ? _kGreen : _kRed),
              _pfRow('Total P&L', _fmtMoney(total),
                  color: total >= 0 ? _kGreen : _kRed, bold: true),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_broker.positionQty > 0)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _engine.isFinished
                  ? null
                  : () {
                      final err = _broker.exitAll(price, _engine.simTimeMs);
                      if (err != null) {
                        _snack(err);
                      } else {
                        _snack('Position exited at ₹${price.toStringAsFixed(2)}',
                            green: true);
                      }
                      setState(() {});
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: _kRed,
                side: const BorderSide(color: _kRed),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              child: const Text('EXIT ALL at current price',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        const SizedBox(height: 10),
        const Text(
          'This portfolio exists only inside this simulation. Leaving the screen ends the session.',
          style: TextStyle(color: Colors.white38, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _pfRow(String label, String value, {Color? color, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
        ],
      ),
    );
  }
}

// ---------------- Chart ----------------

class _ChartPainter extends CustomPainter {
  final List<Candle> done;
  final Candle partial;
  final List<double> triggerPrices;

  _ChartPainter({
    required this.done,
    required this.partial,
    required this.triggerPrices,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...done, partial];
    if (all.isEmpty) return;
    var minP = double.infinity;
    var maxP = -double.infinity;
    for (final c in all) {
      minP = min(minP, c.low);
      maxP = max(maxP, c.high);
    }
    for (final t in triggerPrices) {
      minP = min(minP, t);
      maxP = max(maxP, t);
    }
    if (maxP - minP < 0.01) {
      maxP += 0.5;
      minP -= 0.5;
    }
    final pad = (maxP - minP) * 0.08;
    maxP += pad;
    minP -= pad;

    const labelW = 52.0;
    final chartW = size.width - labelW;
    double y(double price) =>
        size.height - (price - minP) / (maxP - minP) * size.height;

    // Grid + price labels
    final gridPaint = Paint()
      ..color = Colors.white.withAlpha(18)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(color: Colors.white.withAlpha(120), fontSize: 9);
    for (var i = 0; i <= 4; i++) {
      final p = minP + (maxP - minP) * i / 4;
      final yy = y(p);
      canvas.drawLine(Offset(0, yy), Offset(chartW, yy), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: p.toStringAsFixed(1), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(chartW + 4, yy - 5));
    }

    // Candles
    final slot = chartW / max(all.length, 8);
    final bodyW = max(1.0, slot * 0.68);
    for (var i = 0; i < all.length; i++) {
      final c = all[i];
      final cx = slot * i + slot / 2;
      final upC = c.close >= c.open;
      final paint = Paint()..color = upC ? _kGreen : _kRed;
      canvas.drawLine(
          Offset(cx, y(c.high)), Offset(cx, y(c.low)), paint..strokeWidth = 1);
      final top = y(max(c.open, c.close));
      final bottom = y(min(c.open, c.close));
      canvas.drawRect(
        Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2,
            max(bottom, top + 1)),
        paint,
      );
    }

    // Active price-trigger lines (dashed purple)
    final linePaint = Paint()
      ..color = _kPurple
      ..strokeWidth = 1;
    for (final t in triggerPrices) {
      final yy = y(t);
      var x = 0.0;
      while (x < chartW) {
        canvas.drawLine(Offset(x, yy), Offset(min(x + 6, chartW), yy), linePaint);
        x += 10;
      }
      final tp = TextPainter(
        text: TextSpan(
            text: '₹${t.toStringAsFixed(1)}',
            style: const TextStyle(color: _kPurple, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, yy - 12));
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
