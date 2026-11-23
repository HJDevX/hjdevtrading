import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/practice/simulator_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/paper_broker.dart';

/// PRACTICE page — paper trading only, against a VIRTUAL FUND
/// (₹1,00,000 starting; equity buys get 5x MTF leverage — see
/// PaperBroker). The app bar shows the available fund at all times.
///  Tab 1: Orders    — every paper order placed from the watchlist
///  Tab 2: Portfolio — current paper holdings with live P&L and exit
/// The flask icon in the app bar opens the SIMULATOR — replay a real
/// past trading day with historical prices, for practice any time.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  PaperFundInfo? _fund;
  int _seenRevision = -1;

  @override
  void initState() {
    super.initState();
    _loadFund();
  }

  Future<void> _loadFund() async {
    final fund = await PaperBroker.instance.fundInfo();
    if (!mounted) return;
    setState(() => _fund = fund);
  }

  @override
  Widget build(BuildContext context) {
    if (_seenRevision != PaperBroker.revision) {
      _seenRevision = PaperBroker.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadFund());
    }
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
              ),
            ],
          ),
          actions: [
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
    final orders = await _db.getPaperOrders();
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // This tab stays alive in the background — reload whenever a new
    // paper trade has happened since it was last shown.
    if (_seenRevision != PaperBroker.revision) {
      _seenRevision = PaperBroker.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_orders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No paper orders yet.\nOpen any stock in your watchlist and tap BUY (Paper) or SELL (Paper).',
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
              title: const Text('Total booked (realized) P&L',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              trailing: Text(
                _fmtMoney(totalRealized),
                style: TextStyle(
                  color: totalRealized >= 0
                      ? const Color(0xFF00C853)
                      : const Color(0xFFE53935),
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
                color: buy
                    ? const Color(0xFF00C853).withAlpha(35)
                    : const Color(0xFFE53935).withAlpha(35),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(buy ? 'BUY' : 'SELL',
                  style: TextStyle(
                      color: buy
                          ? const Color(0xFF00C853)
                          : const Color(0xFFE53935),
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

  List<PaperPosition> _positions = [];
  final Map<String, Quote> _quotesByToken = {};
  PaperFundInfo? _fund;
  bool _loading = true;
  int _seenRevision = -1;
  Timer? _timer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(
        const Duration(seconds: 3), (_) => _refreshPrices());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final positions = await _db.getPaperPositions();
    final fund = await PaperBroker.instance.fundInfo();
    if (!mounted) return;
    setState(() {
      _positions = positions;
      _fund = fund;
      _loading = false;
    });
    _refreshPrices();
  }

  Future<void> _refreshPrices() async {
    if (!mounted || _positions.isEmpty) return;
    final items = _positions
        .map((p) => PaperBroker.instance.positionAsItem(p))
        .toList();
    // getQuotesBatch keys its result by instrument token (positions
    // have no watchlist-item id), which is exactly what we match on.
    final batch = await _api.getQuotesBatch(items);
    if (!mounted || batch.isEmpty) return;
    setState(() {
      for (final p in _positions) {
        final q = p.token != null ? batch[p.token!] : null;
        if (q != null) _quotesByToken[p.token!] = q;
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
    if (_seenRevision != PaperBroker.revision) {
      _seenRevision = PaperBroker.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_positions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No paper holdings yet.\nBuy something (paper) from your watchlist and it will appear here.',
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
      current += (q?.ltp ?? p.avgPrice) * p.qty;
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
                      _summaryCol('Invested', _fmtMoney(invested)),
                      _summaryCol('Current', _fmtMoney(current)),
                      _summaryCol(
                        'P&L',
                        _fmtMoney(pnl),
                        color: pnl >= 0
                            ? const Color(0xFF00C853)
                            : const Color(0xFFE53935),
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
          final p = _positions[i - 1];
          final q = p.token != null ? _quotesByToken[p.token!] : null;
          final ltp = q?.ltp;
          final pPnl =
              ltp != null ? (ltp - p.avgPrice) * p.qty : null;
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
                Text(
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

  Widget _fundRow(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
          Text(value,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600)),
        ],
      ),
    );
  }
}
