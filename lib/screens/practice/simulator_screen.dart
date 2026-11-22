import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/sim_broker.dart';
import 'package:hjdev_trading/services/simulator_service.dart';

/// SIMULATOR — practice trading on FAKE prices, opened from the
/// Practice page. The market here is the user's own watchlist
/// instruments, each starting at its last real price and then moving
/// on its own once a second, so it works with the real market closed
/// (evenings, weekends). Sim trades live in their own tables and
/// never mix with the real paper record.
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  final SimulatorService _sim = SimulatorService.instance;
  StreamSubscription<void>? _tickSub;

  static const Color _bg = Color(0xFF0D1117);
  static const Color _purple = Color(0xFF7C4DFF);

  @override
  void initState() {
    super.initState();
    // Keep the play/pause icon honest while prices tick.
    _tickSub = _sim.ticks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickSub?.cancel();
    super.dispose();
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Reset simulator?',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          'All simulator orders and holdings will be deleted and every '
          'price goes back to its starting (last real) price. Your real '
          'paper trades are not touched.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    await SimBroker.instance.clearAll();
    _sim.resetPrices();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Simulator reset — fresh start'),
        backgroundColor: Color(0xFF37474F)));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          title: Row(
            children: [
              const Text('Simulator',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Chip(
                label: const Text('SIMULATOR',
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
          actions: [
            IconButton(
              tooltip: _sim.isRunning ? 'Pause prices' : 'Start prices',
              icon: Icon(_sim.isRunning ? Icons.pause : Icons.play_arrow),
              onPressed: () {
                if (_sim.isRunning) {
                  _sim.pause();
                } else {
                  _sim.start();
                }
                setState(() {});
              },
            ),
            IconButton(
              tooltip: 'Reset simulator',
              icon: const Icon(Icons.restart_alt),
              onPressed: _confirmReset,
            ),
          ],
          bottom: const TabBar(
            indicatorColor: _purple,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(text: 'Market'),
              Tab(text: 'Orders'),
              Tab(text: 'Portfolio'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _MarketTab(),
            _SimOrdersTab(),
            _SimPortfolioTab(),
          ],
        ),
      ),
    );
  }
}

String _key(String exchange, String? token) =>
    '${KotakApi.normalizeSegment(exchange)}|${token ?? ''}';

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

const Color _kGreen = Color(0xFF00C853);
const Color _kRed = Color(0xFFE53935);
const Color _kCard = Color(0xFF161B22);

// ---------------- Market tab ----------------

class _MarketTab extends StatefulWidget {
  const _MarketTab();

  @override
  State<_MarketTab> createState() => _MarketTabState();
}

class _MarketTabState extends State<_MarketTab>
    with AutomaticKeepAliveClientMixin {
  final AppDb _db = AppDb.instance;
  final KotakApi _api = KotakApi.instance;
  final SimulatorService _sim = SimulatorService.instance;

  List<WatchItem> _items = [];
  bool _loading = true;
  StreamSubscription<void>? _tickSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tickSub = _sim.ticks.listen((_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tickSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // The sim market = every non-index instrument in any watchlist,
    // each seeded once with its last real price.
    final lists = await _db.getWatchlists();
    final seen = <String>{};
    final items = <WatchItem>[];
    for (final list in lists) {
      if (list.id == null) continue;
      for (final it in await _db.getItems(list.id!)) {
        if (it.isIndex || it.token == null || it.token!.isEmpty) continue;
        if (seen.add(_key(it.exchange, it.token))) items.add(it);
      }
    }
    if (items.isNotEmpty) {
      final batch = await _api.getQuotesBatch(items);
      for (final it in items) {
        final q = (it.token != null ? batch[it.token!] : null) ??
            batch['${it.exchange}|${it.symbol}'] ??
            batch['${it.exchange}|${it.token}'];
        if (q != null && q.ltp > 0) {
          _sim.seed(_key(it.exchange, it.token),
              ltp: q.ltp, prevClose: q.prevClose);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
    _sim.start();
  }

  void _showTradeSheet(WatchItem item) {
    final key = _key(item.exchange, item.token);
    final isDeriv = item.instrumentType == 'FUT' ||
        item.instrumentType == 'CE' ||
        item.instrumentType == 'PE';
    final step = isDeriv ? (item.lotSize ?? 1) : 1;
    var qty = step;

    showModalBottomSheet(
      context: context,
      backgroundColor: _kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final sp = _sim.priceOf(key);
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.symbol,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                          Text(item.displayName,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C4DFF).withAlpha(40),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('SIMULATOR',
                          style: TextStyle(
                              color: Color(0xFF7C4DFF),
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (sp != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('₹${sp.ltp.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold)),
                      Text(
                        '${sp.change >= 0 ? '+' : ''}${sp.change.toStringAsFixed(2)} (${sp.changePct >= 0 ? '+' : ''}${sp.changePct.toStringAsFixed(2)}%)',
                        style: TextStyle(
                            color: sp.change >= 0 ? _kGreen : _kRed,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _ohlcRow('Sim Open', sp.open),
                  _ohlcRow('Sim High', sp.high),
                  _ohlcRow('Sim Low', sp.low),
                  _ohlcRow('Prev Close (real)', sp.prevClose),
                ] else
                  const Text(
                      'No starting price for this one yet — it needs one real price fetch first',
                      style: TextStyle(color: Colors.white54)),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Quantity',
                        style:
                            TextStyle(color: Colors.white70, fontSize: 14)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              color: Colors.white70),
                          onPressed: () {
                            if (qty > step) setSheet(() => qty -= step);
                          },
                        ),
                        Text('$qty',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline,
                              color: Colors.white70),
                          onPressed: () => setSheet(() => qty += step),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () =>
                            _simTrade(item, 'B', qty, sheetCtx),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kGreen,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('BUY (Sim)',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () =>
                            _simTrade(item, 'S', qty, sheetCtx),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kRed,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('SELL (Sim)',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Text(
                      'Simulator trade — fake price, kept separate from Practice',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _ohlcRow(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text('₹${value.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }

  Future<void> _simTrade(WatchItem item, String side, int qty,
      BuildContext sheetCtx) async {
    // Fill at the sim price at the moment of the tap.
    final price = _sim.ltpOf(_key(item.exchange, item.token)) ?? 0;
    final error = side == 'B'
        ? await SimBroker.instance.buy(item: item, qty: qty, price: price)
        : await SimBroker.instance.sell(item: item, qty: qty, price: price);
    if (!mounted) return;
    if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(error ??
          'Sim ${side == 'B' ? 'BUY' : 'SELL'} $qty ${item.symbol} @ ₹${price.toStringAsFixed(2)} — see Portfolio tab'),
      backgroundColor:
          error != null ? Colors.red.shade700 : Colors.green.shade700,
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Your watchlists are empty.\nAdd some stocks from the Watchlist tab first — the simulator trades those same instruments on fake prices.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xFF7C4DFF).withAlpha(25),
          child: Text(
            _sim.isRunning
                ? 'Fake prices moving every second — practice freely, nothing here is real'
                : 'Prices paused — tap ▶ in the top bar to start them moving',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _items.length,
            separatorBuilder: (_, __) => const Divider(
                color: Colors.white10, height: 1, indent: 16),
            itemBuilder: (ctx, i) {
              final item = _items[i];
              final sp = _sim.priceOf(_key(item.exchange, item.token));
              final up = (sp?.change ?? 0) >= 0;
              return ListTile(
                onTap: () => _showTradeSheet(item),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 2),
                title: Text(item.symbol,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(item.displayName,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      sp != null ? sp.ltp.toStringAsFixed(2) : '—',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600),
                    ),
                    Text(
                      sp != null
                          ? '${up ? '+' : ''}${sp.changePct.toStringAsFixed(2)}%'
                          : '',
                      style: TextStyle(
                          color: up ? _kGreen : _kRed, fontSize: 11.5),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------- Sim Orders tab ----------------

class _SimOrdersTab extends StatefulWidget {
  const _SimOrdersTab();

  @override
  State<_SimOrdersTab> createState() => _SimOrdersTabState();
}

class _SimOrdersTabState extends State<_SimOrdersTab>
    with AutomaticKeepAliveClientMixin {
  final AppDb _db = AppDb.instance;
  List<PaperOrder> _orders = [];
  bool _loading = true;
  int _seenRevision = -1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orders = await _db.getSimOrders();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_seenRevision != SimBroker.revision) {
      _seenRevision = SimBroker.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No simulator orders yet.\nOpen the Market tab, tap any stock and BUY (Sim).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }
    final totalRealized =
        _orders.fold<double>(0, (sum, o) => sum + o.realizedPnl);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _orders.length + 1,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1, indent: 16),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return ListTile(
              title: const Text('Total booked (realized) P&L — simulator',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              trailing: Text(
                _fmtMoney(totalRealized),
                style: TextStyle(
                  color: totalRealized >= 0 ? _kGreen : _kRed,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          }
          final o = _orders[i - 1];
          final buy = o.isBuy;
          return ListTile(
            leading: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: buy ? _kGreen.withAlpha(35) : _kRed.withAlpha(35),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(buy ? 'BUY' : 'SELL',
                  style: TextStyle(
                      color: buy ? _kGreen : _kRed,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
            ),
            title: Text(o.symbol,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              '${o.qty} @ ₹${o.price.toStringAsFixed(2)} • ${_fmtTime(o.timeMs)}'
              '${!buy && o.realizedPnl != 0 ? ' • P&L ${_fmtMoney(o.realizedPnl)}' : ''}',
              style: const TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
            trailing: Text(_fmtMoney(o.value),
                style:
                    const TextStyle(color: Colors.white70, fontSize: 13)),
          );
        },
      ),
    );
  }
}

// ---------------- Sim Portfolio tab ----------------

class _SimPortfolioTab extends StatefulWidget {
  const _SimPortfolioTab();

  @override
  State<_SimPortfolioTab> createState() => _SimPortfolioTabState();
}

class _SimPortfolioTabState extends State<_SimPortfolioTab>
    with AutomaticKeepAliveClientMixin {
  final AppDb _db = AppDb.instance;
  final SimulatorService _sim = SimulatorService.instance;

  List<PaperPosition> _positions = [];
  bool _loading = true;
  int _seenRevision = -1;
  StreamSubscription<void>? _tickSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tickSub = _sim.ticks.listen((_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tickSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final positions = await _db.getSimPositions();
    if (!mounted) return;
    setState(() {
      _positions = positions;
      _loading = false;
    });
  }

  Future<void> _exitPosition(PaperPosition p) async {
    final price = _sim.ltpOf(_key(p.exchange, p.token)) ?? 0;
    if (price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sim price not available yet — wait a moment')));
      return;
    }
    final item = SimBroker.instance.positionAsItem(p);
    final error =
        await SimBroker.instance.sell(item: item, qty: p.qty, price: price);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red.shade700));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Sim SELL ${p.qty} ${p.symbol} @ ₹${price.toStringAsFixed(2)}'),
        backgroundColor: Colors.green.shade700,
      ));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_seenRevision != SimBroker.revision) {
      _seenRevision = SimBroker.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_positions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No simulator holdings yet.\nBuy something in the Market tab and it will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }

    double invested = 0, current = 0;
    for (final p in _positions) {
      invested += p.invested;
      final ltp = _sim.ltpOf(_key(p.exchange, p.token));
      current += (ltp ?? p.avgPrice) * p.qty;
    }
    final pnl = current - invested;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _positions.length + 1,
        separatorBuilder: (_, __) =>
            const Divider(color: Colors.white10, height: 1, indent: 16),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _kCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _summaryCol('Invested', _fmtMoney(invested)),
                  _summaryCol('Current', _fmtMoney(current)),
                  _summaryCol(
                    'P&L',
                    _fmtMoney(pnl),
                    color: pnl >= 0 ? _kGreen : _kRed,
                  ),
                ],
              ),
            );
          }
          final p = _positions[i - 1];
          final ltp = _sim.ltpOf(_key(p.exchange, p.token));
          final pPnl = ltp != null ? (ltp - p.avgPrice) * p.qty : null;
          return ListTile(
            title: Text(p.symbol,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${p.qty} qty • Avg ₹${p.avgPrice.toStringAsFixed(2)}'
              '${ltp != null ? ' • Sim LTP ₹${ltp.toStringAsFixed(2)}' : ''}',
              style: const TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pPnl != null ? _fmtMoney(pPnl) : '—',
                  style: TextStyle(
                    color: pPnl == null
                        ? Colors.white38
                        : pPnl >= 0
                            ? _kGreen
                            : _kRed,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _exitPosition(p),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kRed,
                    side: const BorderSide(color: _kRed),
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
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                color: color ?? Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}
