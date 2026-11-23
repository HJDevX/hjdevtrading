import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/practice/simulator_screen.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/paper_broker.dart';
import 'package:hjdev_trading/services/pending_order_engine.dart';

/// PRACTICE page — paper trading only, against a VIRTUAL FUND
/// (₹1,00,000 starting, EDITABLE from the pencil button; equity buys
/// get 5x MTF leverage — see PaperBroker). The app bar shows the
/// available fund at all times. Both tabs listen to the broker, so
/// a trade appears in Orders and Portfolio INSTANTLY. Each
/// position's last live price is saved in local storage, so its
/// P&L still shows correctly with the market closed.
///  Tab 1: Orders    — ONLY the pending orders (price/time
///                     triggers, armed targets and stop-losses),
///                     each editable and cancellable
///  Tab 2: Portfolio — current holdings with real-time P&L, the
///                     fund breakdown, and below them the full
///                     EXECUTED trade history (BUY and SELL, shown
///                     faded) with booked P&L
/// The flask icon in the app bar opens the SIMULATOR — replay a real
/// past trading day with historical prices, for practice any time.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  PaperFundInfo? _fund;

  @override
  void initState() {
    super.initState();
    _loadFund();
    // Instant refresh: any paper trade or fund edit reloads the
    // app-bar fund line the moment it happens.
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

  /// Edit the virtual fund's starting amount.
  Future<void> _editFund() async {
    final current = _fund?.startingFund ?? 100000;
    final ctrl =
        TextEditingController(text: current.toStringAsFixed(0));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Edit virtual fund',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Starting fund (₹)',
                labelStyle: TextStyle(color: Colors.white54),
                prefixText: '₹ ',
                prefixStyle: TextStyle(color: Colors.white70),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Available = fund + booked P&L − margin blocked in open '
              'positions. If the new fund is smaller than the blocked '
              'margin, new buys stop until you sell something.',
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Practice',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(width: 10),
                  Chip(
                    label: Text('PAPER',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.orange,
                            fontWeight: FontWeight.bold)),
                    backgroundColor: Color(0xFF3A2A12),
                    side: BorderSide.none,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              Text(
                _fund == null
                    ? 'Virtual fund: …'
                    : 'Virtual fund: ${_fmtMoney(_fund!.available)} available'
                        ' • ${_fmtMoney(_fund!.marginBlocked)} blocked',
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.normal),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Edit virtual fund',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _editFund,
            ),
            IconButton(
              tooltip: 'Simulator — replay a real past day',
              icon: const Icon(Icons.science_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const SimulatorScreen()),
                );
              },
            ),
          ],
          bottom: const TabBar(
            indicatorColor: Color(0xFF2962FF),
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(text: 'Orders'),
              Tab(text: 'Portfolio'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _OrdersTab(),
            _PortfolioTab(),
          ],
        ),
      ),
    );
  }
}

String _fmtTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  var hour = dt.hour;
  final ampm = hour >= 12 ? 'PM' : 'AM';
  hour = hour % 12;
  if (hour == 0) hour = 12;
  return '${dt.day} ${months[dt.month - 1]}, '
      '${hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} $ampm';
}

String _fmtMoney(double v) =>
    '${v < 0 ? '-' : ''}₹${v.abs().toStringAsFixed(2)}';

// ---------------- Orders tab ----------------

class _OrdersTab extends StatefulWidget {
  const _OrdersTab();

  @override
  State<_OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<_OrdersTab>
    with AutomaticKeepAliveClientMixin {
  List<PaperPendingOrder> _pending = [];
  List<PaperPendingOrder> _failed = [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // Instant: pending changes (place / modify / cancel / fill)
    // reload this list the moment they happen.
    PendingOrderEngine.pendingRevision.addListener(_load);
    PaperBroker.revisionNotifier.addListener(_load);
  }

  @override
  void dispose() {
    PendingOrderEngine.pendingRevision.removeListener(_load);
    PaperBroker.revisionNotifier.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final active = await PendingOrderEngine.instance.activeOrders();
    final finished = await PendingOrderEngine.instance.recentFinished();
    if (!mounted) return;
    setState(() {
      _pending = active;
      _failed = finished.where((o) => o.status == 'FAILED').toList();
      _loading = false;
    });
  }

  String _triggerText(PaperPendingOrder o) {
    if (o.triggerType == 'TIME' && o.triggerTimeMs != null) {
      return '${o.isBuy ? 'Buy' : 'Sell'} at ${_fmtTime(o.triggerTimeMs!)}';
    }
    return '${o.isBuy ? 'Buy' : 'Sell'} when price touches '
        '₹${(o.triggerPrice ?? 0).toStringAsFixed(2)}';
  }

  String _targetText(PaperPendingOrder o) {
    if (o.isTarget) return 'Target exit';
    if (o.isStopLoss) return 'Stop-loss exit';
    final parts = <String>[];
    if (o.targetTimeMs != null) {
      parts.add('Target: sell at ${_fmtTime(o.targetTimeMs!)}');
    } else if (o.targetPrice != null) {
      parts.add('Target: sell at ₹${o.targetPrice!.toStringAsFixed(2)}');
    } else if (o.targetPct != null) {
      parts.add('Target: sell at +${o.targetPct!.toStringAsFixed(1)}%');
    }
    if (o.slPrice != null) {
      parts.add('SL: ₹${o.slPrice!.toStringAsFixed(2)}');
    } else if (o.slPct != null) {
      parts.add('SL: −${o.slPct!.toStringAsFixed(1)}%');
    }
    return parts.join(' • ');
  }

  Future<void> _cancelPending(PaperPendingOrder o) async {
    await PendingOrderEngine.instance.cancel(o);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Pending order cancelled: ${o.symbol}'),
        backgroundColor: Colors.grey.shade800));
  }

  Future<int?> _pickTimeMs(int? currentMs) async {
    final now = DateTime.now();
    final initial = currentMs != null
        ? TimeOfDay.fromDateTime(
            DateTime.fromMillisecondsSinceEpoch(currentMs))
        : TimeOfDay.now();
    final picked =
        await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return currentMs;
    return DateTime(now.year, now.month, now.day, picked.hour,
            picked.minute)
        .millisecondsSinceEpoch;
  }

  Future<void> _modifyPending(PaperPendingOrder o) async {
    final qtyCtrl = TextEditingController(text: '${o.qty}');
    final priceCtrl = TextEditingController(
        text: o.triggerPrice?.toStringAsFixed(2) ?? '');
    final tPriceCtrl = TextEditingController(
        text: o.targetPrice?.toStringAsFixed(2) ?? '');
    final tPctCtrl =
        TextEditingController(text: o.targetPct?.toString() ?? '');
    final slPriceCtrl = TextEditingController(
        text: o.slPrice?.toStringAsFixed(2) ?? '');
    final slPctCtrl =
        TextEditingController(text: o.slPct?.toString() ?? '');
    var triggerTime = o.triggerTimeMs;
    var targetTime = o.targetTimeMs;
    var clearTarget = false;
    var clearSl = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: Text('Modify ${o.symbol}',
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dlgField(qtyCtrl, 'Quantity', TextInputType.number),
                if (o.triggerType == 'PRICE')
                  _dlgField(priceCtrl, 'Trigger price (₹)',
                      const TextInputType.numberWithOptions(decimal: true)),
                if (o.triggerType == 'TIME')
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Trigger time',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 13)),
                    subtitle: Text(
                        triggerTime != null
                            ? _fmtTime(triggerTime!)
                            : 'Not set',
                        style: const TextStyle(color: Colors.white)),
                    trailing: const Icon(Icons.access_time,
                        color: Colors.white54),
                    onTap: () async {
                      final v = await _pickTimeMs(triggerTime);
                      setDlg(() => triggerTime = v);
                    },
                  ),
                if (!o.isExit) ...[
                  const Divider(color: Colors.white10),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Target (exit after fill)',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  _dlgField(tPriceCtrl, 'Target price (₹)',
                      const TextInputType.numberWithOptions(decimal: true)),
                  _dlgField(tPctCtrl, 'or Target % gain',
                      const TextInputType.numberWithOptions(decimal: true)),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('or Target time',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 13)),
                    subtitle: Text(
                        targetTime != null
                            ? _fmtTime(targetTime!)
                            : 'Not set',
                        style: const TextStyle(color: Colors.white)),
                    trailing: const Icon(Icons.access_time,
                        color: Colors.white54),
                    onTap: () async {
                      final v = await _pickTimeMs(targetTime);
                      setDlg(() => targetTime = v);
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setDlg(() {
                        clearTarget = true;
                        tPriceCtrl.clear();
                        tPctCtrl.clear();
                        targetTime = null;
                      }),
                      child: const Text('Remove target',
                          style: TextStyle(
                              color: Color(0xFFE53935), fontSize: 12)),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Stop-loss',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  _dlgField(slPriceCtrl, 'Stop-loss price (₹)',
                      const TextInputType.numberWithOptions(decimal: true)),
                  _dlgField(slPctCtrl, 'or Stop-loss % loss',
                      const TextInputType.numberWithOptions(decimal: true)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setDlg(() {
                        clearSl = true;
                        slPriceCtrl.clear();
                        slPctCtrl.clear();
                      }),
                      child: const Text('Remove stop-loss',
                          style: TextStyle(
                              color: Color(0xFFE53935), fontSize: 12)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final qty = int.tryParse(qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      _pendingSnack('Quantity must be more than 0');
      return;
    }
    if (o.lotSize != null && o.lotSize! > 1 && qty % o.lotSize! != 0) {
      _pendingSnack('Quantity must be in lots of ${o.lotSize}');
      return;
    }
    var updated = o.copyWith(qty: qty);
    if (o.triggerType == 'PRICE') {
      final p = double.tryParse(priceCtrl.text.trim());
      if (p == null || p <= 0) {
        _pendingSnack('Trigger price must be more than 0');
        return;
      }
      updated = updated.copyWith(triggerPrice: p);
    } else {
      if (triggerTime == null) {
        _pendingSnack('Pick a trigger time');
        return;
      }
      updated = updated.copyWith(triggerTimeMs: triggerTime);
    }
    if (!o.isExit) {
      if (clearTarget) {
        updated = updated.copyWith(
            clearTargetPrice: true,
            clearTargetPct: true,
            clearTargetTime: true);
      } else {
        final tp = double.tryParse(tPriceCtrl.text.trim());
        final tpc = double.tryParse(tPctCtrl.text.trim());
        updated = updated.copyWith(
          targetPrice: tp,
          clearTargetPrice: tp == null,
          targetPct: tpc,
          clearTargetPct: tpc == null,
          targetTimeMs: targetTime,
          clearTargetTime: targetTime == null,
        );
      }
      if (clearSl) {
        updated = updated.copyWith(clearSlPrice: true, clearSlPct: true);
      } else {
        final sp = double.tryParse(slPriceCtrl.text.trim());
        final spc = double.tryParse(slPctCtrl.text.trim());
        updated = updated.copyWith(
          slPrice: sp,
          clearSlPrice: sp == null,
          slPct: spc,
          clearSlPct: spc == null,
        );
      }
    }
    await PendingOrderEngine.instance.modify(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Pending order updated: ${o.symbol}'),
        backgroundColor: Colors.green.shade700));
  }

  void _pendingSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
  }

  Widget _dlgField(
      TextEditingController ctrl, String label, TextInputType type) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: ctrl,
        keyboardType: type,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ),
    );
  }

  Widget _pendingTile(PaperPendingOrder o, {required bool failed}) {
    final buy = o.isBuy;
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: failed
              ? const Color(0xFFE53935).withAlpha(35)
              : buy
                  ? const Color(0xFF00C853).withAlpha(35)
                  : const Color(0xFFE53935).withAlpha(35),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
            failed
                ? 'FAILED'
                : o.isStopLoss
                    ? 'STOP-LOSS'
                    : o.isTarget
                        ? 'TARGET'
                        : buy
                            ? 'BUY'
                            : 'SELL',
            style: TextStyle(
                color: failed || !buy
                    ? const Color(0xFFE53935)
                    : const Color(0xFF00C853),
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      ),
      title: Text(o.symbol,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(
        failed
            ? (o.note ?? 'Could not execute')
            : '${o.qty} qty • ${_triggerText(o)}'
                '${_targetText(o).isNotEmpty ? '\n${_targetText(o)}' : ''}',
        style: TextStyle(
            color: failed ? const Color(0xFFE53935) : Colors.white38,
            fontSize: 11.5),
      ),
      trailing: failed
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Modify',
                  icon: const Icon(Icons.edit_outlined,
                      color: Colors.white70, size: 20),
                  onPressed: () => _modifyPending(o),
                ),
                IconButton(
                  tooltip: 'Cancel order',
                  icon: const Icon(Icons.close,
                      color: Color(0xFFE53935), size: 20),
                  onPressed: () => _cancelPending(o),
                ),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_pending.isEmpty && _failed.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No pending orders.\nPlace one from any watchlist stock: Execute → At price or At time — or set a target / stop-loss on a buy.\nExecuted trades live in the Portfolio tab.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }
    final itemCount = 1 + _pending.length + _failed.length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: itemCount,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1, indent: 16),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('PENDING ORDERS — tap ✎ to edit, ✕ to cancel',
                  style: TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6)),
            );
          }
          final idx = i - 1;
          if (idx < _pending.length) {
            return _pendingTile(_pending[idx], failed: false);
          }
          return _pendingTile(_failed[idx - _pending.length],
              failed: true);
        },
      ),
    );
  }
}

// ---------------- Portfolio tab ----------------

class _PortfolioTab extends StatefulWidget {
  const _PortfolioTab();

  @override
  State<_PortfolioTab> createState() => _PortfolioTabState();
}

class _PortfolioTabState extends State<_PortfolioTab>
    with AutomaticKeepAliveClientMixin {
  final AppDb _db = AppDb.instance;
  final KotakApi _api = KotakApi.instance;
  final IndexFeedService _feed = IndexFeedService.instance;

  List<PaperPosition> _positions = [];
  final Map<String, Quote> _quotesByToken = {};
  List<PaperOrder> _history = [];
  PaperFundInfo? _fund;
  bool _loading = true;
  Timer? _timer;
  StreamSubscription<Quote>? _tickSub;
  final List<Quote> _pendingTicks = [];
  Timer? _tickFlushTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // Instant: a new paper trade reloads holdings the moment it
    // happens, even while this tab sits in the background.
    PaperBroker.revisionNotifier.addListener(_load);
    // REAL-TIME P&L: the same live feed ticks that move the
    // watchlist rows update this tab's prices (batched at 100 ms,
    // exactly like the watchlist). The pending-order engine keeps
    // every position subscribed on the feed. The 3 s REST poll
    // below is only a fallback while the feed is down.
    _tickSub = _feed.ticks.listen((quote) {
      _pendingTicks.add(quote);
      _tickFlushTimer ??=
          Timer(const Duration(milliseconds: 100), _flushTicks);
    });
    _timer = Timer.periodic(
        const Duration(seconds: 3), (_) => _refreshPrices());
  }

  @override
  void dispose() {
    PaperBroker.revisionNotifier.removeListener(_load);
    _tickSub?.cancel();
    _tickFlushTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  /// Apply collected feed ticks to the matching positions.
  void _flushTicks() {
    _tickFlushTimer = null;
    if (!mounted || _pendingTicks.isEmpty) return;
    final ticks = List<Quote>.from(_pendingTicks);
    _pendingTicks.clear();
    setState(() {
      for (final quote in ticks) {
        if (quote.token == null) continue;
        for (var i = 0; i < _positions.length; i++) {
          final p = _positions[i];
          if (p.token != quote.token) continue;
          if (KotakApi.normalizeSegment(p.exchange) != quote.exchange) {
            continue;
          }
          final old = _quotesByToken[p.token!];
          _quotesByToken[p.token!] = old == null
              ? quote
              : Quote(
                  symbol: old.symbol,
                  exchange: old.exchange,
                  token: old.token,
                  ltp: quote.ltp,
                  open: old.open,
                  high: old.high,
                  low: old.low,
                  prevClose:
                      old.prevClose > 0 ? old.prevClose : quote.prevClose,
                  volume: old.volume,
                  changePct: quote.changePct,
                );
          if (quote.ltp > 0 && quote.ltp != p.lastPrice) {
            _positions[i] = p.copyWith(lastPrice: quote.ltp);
            PaperBroker.instance.savePositionLastPrice(p, quote.ltp);
          }
        }
      }
    });
  }

  Future<void> _load() async {
    final positions = await _db.getPaperPositions();
    final fund = await PaperBroker.instance.fundInfo();
    final history = await _db.getPaperOrders();
    if (!mounted) return;
    setState(() {
      _positions = positions;
      _fund = fund;
      _history = history;
      _loading = false;
    });
    _refreshPrices();
  }

  Future<void> _refreshPrices() async {
    if (!mounted || _positions.isEmpty) return;
    // While the live feed is connected, ticks drive the prices —
    // don't compete with REST polls.
    if (_feed.state == IndexFeedState.connected) return;
    final items = _positions
        .map((p) => PaperBroker.instance.positionAsItem(p))
        .toList();
    // getQuotesBatch keys its result by instrument token (positions
    // have no watchlist-item id), which is exactly what we match on.
    final batch = await _api.getQuotesBatch(items);
    if (!mounted || batch.isEmpty) return;
    setState(() {
      for (var i = 0; i < _positions.length; i++) {
        final p = _positions[i];
        final q = p.token != null ? batch[p.token!] : null;
        if (q == null) continue;
        _quotesByToken[p.token!] = q;
        // SAVE the fresh price to local storage: the position's P&L
        // is then stored on the phone and still shows correctly
        // when the market is closed or there is no network.
        if (q.ltp > 0 && q.ltp != p.lastPrice) {
          _positions[i] = p.copyWith(lastPrice: q.ltp);
          PaperBroker.instance.savePositionLastPrice(p, q.ltp);
        }
      }
    });
  }

  Future<void> _exitPosition(PaperPosition p) async {
    final q = p.token != null ? _quotesByToken[p.token!] : null;
    final price = q?.ltp ?? 0;
    if (price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Live price not available yet — wait a moment')));
      return;
    }
    final item = PaperBroker.instance.positionAsItem(p);
    final error = await PaperBroker.instance
        .sell(item: item, qty: p.qty, price: price);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red.shade700));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Paper SELL ${p.qty} ${p.symbol} @ ₹${price.toStringAsFixed(2)}'),
        backgroundColor: Colors.green.shade700,
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_positions.isEmpty && _history.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No paper holdings yet.\nBuy something (paper) from your watchlist and it will appear here, with its P&L and trade history.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }

    double invested = 0, current = 0;
    for (final p in _positions) {
      invested += p.invested;
      final q = p.token != null ? _quotesByToken[p.token!] : null;
      // Current value at the live price, or at the SAVED last price
      // when no live price is available right now.
      current += (q?.ltp ?? p.lastPrice ?? p.avgPrice) * p.qty;
    }
    final pnl = current - invested;

    final itemCount = 1 +
        _positions.length +
        (_history.isEmpty ? 0 : 1 + _history.length);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: itemCount,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1, indent: 16),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: _summaryCol('Invested', _fmtMoney(invested))),
                      Expanded(child: _summaryCol('Current', _fmtMoney(current))),
                      Expanded(
                        child: _summaryCol(
                          'P&L',
                          _fmtMoney(pnl),
                          color: pnl >= 0
                              ? const Color(0xFF00C853)
                              : const Color(0xFFE53935),
                        ),
                      ),
                    ],
                  ),
                  if (_fund != null) ...[
                    const Divider(color: Colors.white10, height: 20),
                    _fundRow('Virtual fund (start)',
                        _fmtMoney(_fund!.startingFund)),
                    _fundRow('Margin blocked',
                        _fmtMoney(_fund!.marginBlocked)),
                    _fundRow('Available fund',
                        _fmtMoney(_fund!.available),
                        bold: true),
                    _fundRow(
                      'Booked (realized) P&L',
                      _fmtMoney(_fund!.realizedPnl),
                      color: _fund!.realizedPnl >= 0
                          ? const Color(0xFF00C853)
                          : const Color(0xFFE53935),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Equity buys block only 1/5th (5x MTF leverage); F&O blocks full value.',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }
          if (i > _positions.length) {
            // Executed-trade history section (shown faded).
            final hIdx = i - _positions.length - 1;
            if (hIdx == 0) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text('EXECUTED TRADES',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.6)),
              );
            }
            return _historyTile(_history[hIdx - 1]);
          }
          final p = _positions[i - 1];
          final q = p.token != null ? _quotesByToken[p.token!] : null;
          // Live price if we have one, else the price saved in local
          // storage — either way the current P&L shows.
          final ltp = q?.ltp ?? p.lastPrice;
          final pPnl = p.openPnl(ltp);
          return ListTile(
            title: Text(p.symbol,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${p.qty} qty • Avg ₹${p.avgPrice.toStringAsFixed(2)}'
              '${ltp != null ? ' • LTP ₹${ltp.toStringAsFixed(2)}' : ''}',
              style: const TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      pPnl != null ? _fmtMoney(pPnl) : '—',
                      style: TextStyle(
                        color: pPnl == null
                            ? Colors.white38
                            : pPnl >= 0
                                ? const Color(0xFF00C853)
                                : const Color(0xFFE53935),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _exitPosition(p),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE53935),
                    side: const BorderSide(color: Color(0xFFE53935)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('EXIT', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summaryCol(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 3),
        // Money amounts vary in length — shrink to fit the column
        // instead of overflowing on narrow phones.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: TextStyle(
                  color: color ?? Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _fundRow(String label, String value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12.5),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color ?? Colors.white,
                    fontSize: 12.5,
                    fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// One executed trade in the history section — deliberately
  /// FADED: these are done deals, shown for the record and their
  /// P&L, under the live holdings.
  Widget _historyTile(PaperOrder o) {
    final buy = o.isBuy;
    final chipColor =
        buy ? const Color(0xFF00C853) : const Color(0xFFE53935);
    return Opacity(
      opacity: 0.55,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: chipColor.withAlpha(35),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(buy ? 'BUY' : 'SELL',
              style: TextStyle(
                  color: chipColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        title: Text(o.symbol,
            style: const TextStyle(color: Colors.white, fontSize: 13.5)),
        subtitle: Text(
          '${o.qty} @ ₹${o.price.toStringAsFixed(2)} • ${_fmtTime(o.timeMs)}'
          '${!buy && o.realizedPnl != 0 ? ' • P&L ${_fmtMoney(o.realizedPnl)}' : ''}',
          style: const TextStyle(color: Colors.white38, fontSize: 11.5),
        ),
        trailing: Text(_fmtMoney(o.value),
            style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
      ),
    );
  }
}
