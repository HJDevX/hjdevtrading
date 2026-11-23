import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/instrument_search_screen.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/paper_broker.dart';
import 'package:hjdev_trading/services/pending_order_engine.dart';
import 'package:hjdev_trading/services/scrip_master_service.dart';

/// Main watchlist screen: NIFTY/SENSEX header (live index feed), multiple
/// watchlists, tap a row for details and PAPER buy/sell. Instruments
/// come only from the downloaded scrip master — no stock name is
/// hardcoded anywhere in this app.
///
/// Prices (Step 9): while the feed socket is live, rows update by PUSH
/// (subscribeScripsLite Mini ticks merged over the last REST quote);
/// the 3-second REST batch poll runs only as the fallback when the
/// feed is down, plus one forced fetch whenever the list changes so
/// OHLC/volume are present.
class WatchlistsScreen extends StatefulWidget {
  final bool isLoggedIn;
  final VoidCallback onLogout;

  const WatchlistsScreen({
    super.key,
    required this.isLoggedIn,
    required this.onLogout,
  });

  @override
  State<WatchlistsScreen> createState() => _WatchlistsScreenState();
}

class _WatchlistsScreenState extends State<WatchlistsScreen> {
  final AppDb _db = AppDb.instance;
  final KotakApi _api = KotakApi.instance;
  final IndexFeedService _feed = IndexFeedService.instance;
  final ScripMasterService _scripService = ScripMasterService.instance;

  List<Watchlist> _watchlists = [];
  Watchlist? _activeList;
  List<WatchItem> _items = [];
  final Map<int, Quote> _quotes = {};

  bool _isLoading = true;
  bool _isEditMode = false;
  bool _feedConnected = false;
  String? _scripInfoText;

  // Header indices — null until the first REAL tick arrives.
  double? _niftyLtp, _niftyPct;
  double? _sensexLtp, _sensexPct;

  Timer? _pollTimer;
  StreamSubscription<Quote>? _tickSub;
  StreamSubscription<IndexFeedState>? _stateSub;
  BuildContext? _progressCtx;

  // Incoming feed ticks are batched and applied in ONE rebuild per
  // 100 ms — a reconnect snapshot can deliver every subscribed
  // instrument in a single burst, and one setState per tick would
  // rebuild the list dozens of times back-to-back on the UI thread.
  final List<Quote> _pendingTicks = [];
  Timer? _tickFlushTimer;

  static const Color _bg = Color(0xFF0D1117);
  static const Color _card = Color(0xFF161B22);
  static const Color _blue = Color(0xFF2962FF);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    _setupFeedListeners();
    _loadData();
    _maybeAutoRefreshScrips();
    _pollTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => _refreshQuotes());
  }

  @override
  void didUpdateWidget(covariant WatchlistsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoggedIn && !oldWidget.isLoggedIn) {
      _connectIndexFeed();
      _refreshQuotes();
    }
    if (!widget.isLoggedIn && oldWidget.isLoggedIn) {
      _feed.disconnect();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickFlushTimer?.cancel();
    _tickSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  // ---------------- Data ----------------

  Future<void> _loadData() async {
    var lists = await _db.getWatchlists();
    if (lists.isEmpty) {
      await _db.createWatchlist(Watchlist(
        name: 'Watchlist 1',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      lists = await _db.getWatchlists();
    }
    _activeList ??= lists.first;
    if (!lists.any((l) => l.id == _activeList!.id)) {
      _activeList = lists.first;
    }
    final items = await _db.getItems(_activeList!.id!);
    final scripCount = await _db.getScripsCount();
    final lastTime = await _scripService.getLastRefreshTime();
    if (!mounted) return;
    setState(() {
      _watchlists = lists;
      _items = items;
      _isLoading = false;
      _scripInfoText = scripCount > 0
          ? 'Instruments: $scripCount${lastTime != null ? ' • Updated $lastTime' : ''}'
          : 'No instruments yet — tap the download icon to fetch the stock list';
    });
    _connectIndexFeed();
    _syncFeedSubscriptions();
    _refreshQuotes(force: true);
  }

  Future<void> _refreshQuotes({bool force = false}) async {
    // While the feed is live, rows update by push — skip the REST poll
    // (it remains the fallback when the feed is down, and a forced
    // fetch still runs when the list changes, for OHLC/volume).
    if (_feedConnected && !force) return;
    if (!mounted || _items.isEmpty) return;
    final batch = await _api.getQuotesBatch(_items);
    if (!mounted || batch.isEmpty) return;
    setState(() {
      for (final item in _items) {
        if (item.id == null) continue;
        final quote = (item.token != null ? batch[item.token!] : null) ??
            batch['${item.exchange}|${item.symbol}'] ??
            batch['${item.exchange}|${item.token}'];
        if (quote != null) {
          _quotes[item.id!] = quote;
        }
      }
    });
  }

  // ---------------- Index feed ----------------

  void _setupFeedListeners() {
    // The state stream is broadcast — if the feed connected before
    // this screen listened, seed the flag from the current state.
    _feedConnected = _feed.state == IndexFeedState.connected;
    _tickSub = _feed.ticks.listen((quote) {
      _pendingTicks.add(quote);
      _tickFlushTimer ??=
          Timer(const Duration(milliseconds: 100), _flushTicks);
    });
    _stateSub = _feed.states.listen((s) {
      if (!mounted) return;
      setState(() => _feedConnected = s == IndexFeedState.connected);
    });
  }

  /// Apply all ticks collected in the last 100 ms in a single rebuild.
  void _flushTicks() {
    _tickFlushTimer = null;
    if (!mounted || _pendingTicks.isEmpty) return;
    final ticks = List<Quote>.from(_pendingTicks);
    _pendingTicks.clear();
    setState(() {
      for (final quote in ticks) {
        if (quote.token == '26000' && quote.exchange == 'nse_cm') {
          _niftyLtp = quote.ltp;
          _niftyPct = quote.changePct;
        } else if (quote.token == '1' && quote.exchange == 'bse_cm') {
          _sensexLtp = quote.ltp;
          _sensexPct = quote.changePct;
        }
        // Rows: match on token AND segment (tokens repeat across
        // segments). A Mini tick carries only LTP + change, so merge
        // it over the last REST quote to keep OHLC/volume on screen.
        for (final item in _items) {
          if (item.id == null || item.token == null) continue;
          if (item.token != quote.token) continue;
          if (KotakApi.normalizeSegment(item.exchange) != quote.exchange) {
            continue;
          }
          final old = _quotes[item.id!];
          _quotes[item.id!] = old == null
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
        }
      }
    });
  }

  /// Keep the feed's scrip subscriptions equal to the visible list's
  /// non-index items (indices ride their own subscribeIndices event).
  void _syncFeedSubscriptions() {
    final keys = <String>[];
    for (final item in _items) {
      if (item.isIndex) continue;
      if (item.token == null || item.token!.isEmpty) continue;
      keys.add('${KotakApi.normalizeSegment(item.exchange)}|${item.token}');
    }
    _feed.syncScrips(keys);
  }

  void _connectIndexFeed() {
    if (!widget.isLoggedIn) return;
    _feed.connect();
    final keys = <String>['nse_cm|26000', 'bse_cm|1'];
    for (final item in _items) {
      if (item.isIndex && item.token != null && item.token!.isNotEmpty) {
        keys.add(
            '${KotakApi.normalizeSegment(item.exchange)}|${item.token}');
      }
    }
    _feed.subscribe(keys);
  }

  // ---------------- Scrip master ----------------

  Future<void> _maybeAutoRefreshScrips() async {
    // Silent first-open-of-the-day refresh (no dialogs).
    _scripService.onProgress = null;
    _scripService.onSuccess = (_) => _loadData();
    _scripService.onError = null;
    await _scripService.checkAndAutoRefreshMorning();
  }

  Future<void> _refreshScripsManual() async {
    if (_scripService.isRefreshing) return;
    final progress = ValueNotifier<String>('Starting download...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _progressCtx = ctx;
        return AlertDialog(
          backgroundColor: _card,
          title: const Text('Updating instruments',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (context, value, child) => Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(value,
                      style: const TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ),
        );
      },
    );

    _scripService.onProgress = (msg) => progress.value = msg;
    _scripService.onSuccess = (counts) {
      _closeProgress();
      var total = 0;
      counts.forEach((_, v) => total += v);
      final failed = _scripService.lastFailedSegments;
      if (failed.isEmpty) {
        _snack('Instruments updated ($total rows)', green: true);
      } else {
        _snack(
            'Updated $total rows, but ${failed.join(', ')} failed — tap download again (Wi-Fi helps, the F&O file is ~31 MB)',
            green: false);
      }
      _loadData();
    };
    _scripService.onError = (msg) {
      _closeProgress();
      _snack(msg, green: false);
    };
    await _scripService.refreshScripMaster();
    _closeProgress();
  }

  void _closeProgress() {
    if (_progressCtx != null) {
      Navigator.of(_progressCtx!).pop();
      _progressCtx = null;
    }
  }

  void _snack(String msg, {required bool green}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: green ? Colors.green.shade700 : Colors.red.shade700,
      duration: const Duration(seconds: 3),
    ));
  }

  // ---------------- Watchlist management ----------------

  Future<void> _switchList(Watchlist list) async {
    setState(() {
      _activeList = list;
      _quotes.clear();
      _isLoading = true;
    });
    await _loadData();
  }

  Future<String?> _nameDialog(String title, String initial) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'List name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showManageLists() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('My Watchlists',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            ..._watchlists.map((list) => ListTile(
                  title: Text(list.name,
                      style: const TextStyle(color: Colors.white)),
                  leading: Icon(
                    list.id == _activeList?.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: _blue,
                    size: 20,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit,
                            color: Colors.white54, size: 19),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final name =
                              await _nameDialog('Rename watchlist', list.name);
                          if (name != null && name.isNotEmpty) {
                            await _db.updateWatchlist(Watchlist(
                              id: list.id,
                              name: name,
                              createdAt: list.createdAt,
                            ));
                            _loadData();
                          }
                        },
                      ),
                      if (_watchlists.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete,
                              color: Colors.redAccent, size: 19),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _db.deleteWatchlist(list.id!);
                            if (_activeList?.id == list.id) {
                              _activeList = null;
                            }
                            _loadData();
                          },
                        ),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _switchList(list);
                  },
                )),
            ListTile(
              leading: const Icon(Icons.add_circle, color: _blue),
              title: const Text('New Watchlist',
                  style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _nameDialog('New watchlist', '');
                if (name != null && name.isNotEmpty) {
                  final id = await _db.createWatchlist(Watchlist(
                    name: name,
                    createdAt: DateTime.now().millisecondsSinceEpoch,
                  ));
                  final lists = await _db.getWatchlists();
                  final created =
                      lists.firstWhere((l) => l.id == id, orElse: () => lists.last);
                  await _switchList(created);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------------- Item detail + paper trade ----------------

  void _showItemSheet(WatchItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _ItemSheet(
        item: item,
        // Always the freshest quote the watchlist itself has — the
        // sheet re-reads this on its own timer, so its price moves
        // live exactly like the rows behind it.
        quoteProvider: () => item.id != null ? _quotes[item.id!] : null,
        onTrade: (side, qty, price) => _paperTrade(item, side, qty, price),
        onPlacePending: (order) async {
          await PendingOrderEngine.instance.place(order);
          _snack(
              'Pending ${order.isBuy ? 'BUY' : 'SELL'} ${order.qty} ${order.symbol} placed — watch it in Practice → Orders',
              green: true);
          return null;
        },
        onArmExits: (template, fillPrice) async {
          await PendingOrderEngine.instance
              .armExitsForImmediateBuy(template, fillPrice);
          _snack(
              'Target / stop-loss armed for ${template.symbol} — see Practice → Orders',
              green: true);
        },
      ),
    );
  }

  Widget _ohlcRow(String label, double value, {bool isVolume = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text(
            isVolume
                ? value.toInt().toString()
                : '₹${value.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Runs one paper trade at [price] (one fresh quote fetch first if
  /// the price is missing). Shows the result snack itself and returns
  /// the broker's error, or null on success — the sheet closes on
  /// success and stays open on an error.
  Future<String?> _paperTrade(
      WatchItem item, String side, int qty, double price) async {
    var p = price;
    if (p <= 0) {
      // One fresh fetch before giving up.
      final fresh = await _api.getQuotesBatch([item]);
      final freshQuote = (item.token != null ? fresh[item.token!] : null) ??
          fresh['${item.exchange}|${item.symbol}'] ??
          fresh['${item.exchange}|${item.token}'];
      if (freshQuote != null) {
        p = freshQuote.ltp;
      }
    }
    final error = side == 'B'
        ? await PaperBroker.instance.buy(item: item, qty: qty, price: p)
        : await PaperBroker.instance.sell(item: item, qty: qty, price: p);
    if (!mounted) return error;
    if (error != null) {
      _snack(error, green: false);
    } else {
      _snack(
          'Paper ${side == 'B' ? 'BUY' : 'SELL'} $qty ${item.symbol} @ ₹${p.toStringAsFixed(2)} — see Practice tab',
          green: true);
    }
    return error;
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildTabsRow(),
            _buildSearchBar(),
            if (_scripInfoText != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_scripInfoText!,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ),
              ),
            const Divider(color: Colors.white10, height: 12),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Flexible(
                child: Text('HJDev Trading',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _feedConnected ? _green : Colors.white24,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(_feedConnected ? 'Live' : 'Index feed off',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Download today\'s stock list (scrip master)',
                icon: const Icon(Icons.cloud_download_outlined,
                    color: Colors.white70, size: 22),
                onPressed: _refreshScripsManual,
              ),
              IconButton(
                tooltip: 'Logout',
                icon: const Icon(Icons.logout,
                    color: Colors.white54, size: 21),
                onPressed: () => widget.onLogout(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _indexCard('NIFTY', _niftyLtp, _niftyPct)),
              const SizedBox(width: 10),
              Expanded(
                  child: _indexCard('SENSEX', _sensexLtp, _sensexPct)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _indexCard(String name, double? ltp, double? pct) {
    final up = (pct ?? 0) >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Text(name,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ltp != null ? ltp.toStringAsFixed(2) : '—',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Text(
                    pct != null
                        ? '${up ? '+' : ''}${pct.toStringAsFixed(2)}%'
                        : '',
                    style: TextStyle(
                        color: up ? _green : _red,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _watchlists.map((list) {
                  final active = list.id == _activeList?.id;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(list.name),
                      selected: active,
                      onSelected: (_) => _switchList(list),
                      selectedColor: _blue,
                      backgroundColor: _card,
                      labelStyle: TextStyle(
                          color: active ? Colors.white : Colors.white70,
                          fontSize: 13),
                      side: BorderSide.none,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _showManageLists,
            icon: const Icon(Icons.list, size: 18, color: _blue),
            label: const Text('Lists',
                style: TextStyle(color: _blue, fontSize: 13)),
          ),
          IconButton(
            icon: Icon(_isEditMode ? Icons.check : Icons.edit_outlined,
                color: Colors.white54, size: 19),
            onPressed: () => setState(() => _isEditMode = !_isEditMode),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: InkWell(
        onTap: () async {
          if (_activeList == null) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => InstrumentSearchScreen(
                watchlistId: _activeList!.id!,
                watchlistName: _activeList!.name,
              ),
            ),
          );
          _loadData();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white10),
          ),
          child: const Row(
            children: [
              Icon(Icons.search, color: Colors.white38, size: 19),
              SizedBox(width: 10),
              Expanded(
                child: Text('Search stocks, futures, options...',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'This watchlist is empty.\nTap the search bar to add stocks, futures or options from the downloaded list.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _refreshQuotes(force: true),
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (context, index) =>
            const Divider(color: Colors.white10, height: 1, indent: 16),
        itemBuilder: (ctx, i) {
          final item = _items[i];
          final quote = item.id != null ? _quotes[item.id!] : null;
          return _buildRow(item, quote);
        },
      ),
    );
  }

  Widget _buildRow(WatchItem item, Quote? quote) {
    final up = (quote?.change ?? 0) >= 0;
    return ListTile(
      onTap: () => _showItemSheet(item),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Row(
        children: [
          Flexible(
            child: Text(item.symbol,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          if (item.instrumentType != null && item.instrumentType != 'EQ') ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _blue.withAlpha(50),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(item.instrumentType!,
                  style: const TextStyle(color: _blue, fontSize: 10)),
            ),
          ],
        ],
      ),
      subtitle: Text(
        item.instrumentType == 'FUT' ||
                item.instrumentType == 'CE' ||
                item.instrumentType == 'PE'
            ? '${item.expiry ?? ''}${item.strike != null ? ' • Strike ${item.strike!.toStringAsFixed(0)}' : ''}'
            : item.displayName,
        style: const TextStyle(color: Colors.white38, fontSize: 11.5),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                quote != null ? quote.ltp.toStringAsFixed(2) : '—',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600),
              ),
              Text(
                quote != null
                    ? '${up ? '+' : ''}${quote.changePct.toStringAsFixed(2)}%'
                    : '',
                style: TextStyle(
                    color: up ? _green : _red, fontSize: 11.5),
              ),
            ],
          ),
          if (_isEditMode)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              onPressed: () async {
                if (item.id != null) {
                  await _db.deleteItem(item.id!);
                  _loadData();
                }
              },
            ),
        ],
      ),
    );
  }
}


/// The watchlist item detail sheet (paper BUY/SELL). Its price is
/// LIVE: a short timer keeps re-reading the freshest quote from the
/// watchlist (REST poll or feed tick), so the price in the dialogue
/// moves exactly like the rows behind it. The sheet also shows the
/// VIRTUAL FUND — available money, this order's margin (equity
/// blocks only 1/5th at 5x MTF leverage; F&O blocks full value) —
/// and the quantity can be stepped or typed in manually.
class _ItemSheet extends StatefulWidget {
  final WatchItem item;
  final Quote? Function() quoteProvider;
  final Future<String?> Function(String side, int qty, double price)
      onTrade;
  final Future<String?> Function(PaperPendingOrder order) onPlacePending;
  final Future<void> Function(PaperPendingOrder template, double fillPrice)
      onArmExits;

  const _ItemSheet({
    required this.item,
    required this.quoteProvider,
    required this.onTrade,
    required this.onPlacePending,
    required this.onArmExits,
  });

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);
  static const Color _card = Color(0xFF161B22);

  late final int _step;
  late int _qty;
  Quote? _quote;
  PaperFundInfo? _fund;
  Timer? _timer;
  bool _trading = false;

  // Placement options: execute NOW, when a PRICE is touched, or at
  // an exact TIME — plus an optional TARGET for BUY entries (exit
  // at a target price / % gain / exact time, armed when it fills).
  String _orderType = 'NOW'; // NOW | PRICE | TIME
  double? _limitPrice;
  TimeOfDay? _limitTime;
  String _targetType = 'NONE'; // NONE | PRICE | TIME
  double? _targetPrice;
  double? _targetPct;
  TimeOfDay? _targetTime;
  // Optional stop-loss for BUY entries (any Execute mode): an exit
  // price, or a % loss below the fill price — only ONE of the two:
  // setting one clears the other (same rule for the target).
  double? _slPrice;
  double? _slPct;

  bool get _isDeriv =>
      widget.item.instrumentType == 'FUT' ||
      widget.item.instrumentType == 'CE' ||
      widget.item.instrumentType == 'PE';

  bool get _isEquity => widget.item.instrumentType == 'EQ';

  @override
  void initState() {
    super.initState();
    _step = _isDeriv ? (widget.item.lotSize ?? 1) : 1;
    _qty = _step;
    _quote = widget.quoteProvider();
    _loadFund();
    // Live price: re-read the watchlist's freshest quote ~every
    // second and redraw — the same data the rows are showing.
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      setState(() => _quote = widget.quoteProvider() ?? _quote);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadFund() async {
    final fund = await PaperBroker.instance.fundInfo();
    if (mounted) setState(() => _fund = fund);
  }

  Future<void> _editQty() async {
    final ctrl = TextEditingController(text: _qty.toString());
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Type quantity',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: _isDeriv
                ? 'Quantity (lots of $_step)'
                : 'Quantity',
            labelStyle: const TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    if (value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Quantity must be more than 0'),
          backgroundColor: Colors.red));
      return;
    }
    if (_isDeriv && value % _step != 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Quantity must be in lots of $_step'),
          backgroundColor: Colors.red));
      return;
    }
    setState(() => _qty = value);
  }

  bool _validateExitFields() {
    if (_targetType == 'PRICE') {
      final ok = (_targetPrice != null && _targetPrice! > 0) ||
          (_targetPct != null && _targetPct! > 0);
      if (!ok) {
        _sheetSnack('Set a target price or % — or choose No target');
        return false;
      }
    }
    if (_targetType == 'TIME') {
      if (_targetTime == null) {
        _sheetSnack('Pick the target time — or choose No target');
        return false;
      }
      if (_msFor(_targetTime!) <= DateTime.now().millisecondsSinceEpoch) {
        _sheetSnack('Target time has already passed today');
        return false;
      }
    }
    // Direction rules against the CURRENT price: a target is a
    // profit sale, so it must sit ABOVE the current price; a
    // stop-loss protects below, so it must sit BELOW it.
    final cur = _quote?.ltp ?? 0;
    if (cur > 0 &&
        _targetType == 'PRICE' &&
        _targetPrice != null &&
        _targetPrice! > 0 &&
        _targetPrice! <= cur) {
      _sheetSnack(
          'Target price must be ABOVE the current price ₹${cur.toStringAsFixed(2)}');
      return false;
    }
    if (cur > 0 && _slPrice != null && _slPrice! > 0 && _slPrice! >= cur) {
      _sheetSnack(
          'Stop-loss must be BELOW the current price ₹${cur.toStringAsFixed(2)}');
      return false;
    }
    return true;
  }

  /// After an instant (Execute Now) BUY fills, arm its target /
  /// stop-loss exits with the engine.
  Future<void> _armExitsAfterFill() async {
    final hasTarget = _targetType != 'NONE';
    final hasSl = (_slPrice != null && _slPrice! > 0) ||
        (_slPct != null && _slPct! > 0);
    if (!hasTarget && !hasSl) return;
    final item = widget.item;
    double? tPrice, tPct;
    int? tTime;
    if (hasTarget) {
      if (_targetType == 'PRICE') {
        if (_targetPrice != null && _targetPrice! > 0) {
          tPrice = _targetPrice;
        } else {
          tPct = _targetPct;
        }
      } else {
        tTime = _msFor(_targetTime!);
      }
    }
    final template = PaperPendingOrder(
      symbol: item.symbol,
      exchange: KotakApi.normalizeSegment(item.exchange),
      token: item.token,
      displayName: item.displayName,
      instrumentType: item.instrumentType,
      lotSize: item.lotSize,
      side: 'B',
      qty: _qty,
      triggerType: 'NOW',
      targetPrice: tPrice,
      targetPct: tPct,
      targetTimeMs: tTime,
      slPrice: (_slPrice != null && _slPrice! > 0) ? _slPrice : null,
      slPct: (_slPct != null && _slPct! > 0) ? _slPct : null,
      createdMs: DateTime.now().millisecondsSinceEpoch,
    );
    await widget.onArmExits(template, _quote?.ltp ?? 0);
  }

  Future<void> _trade(String side) async {
    if (_trading) return;
    if (side == 'B' && !_validateExitFields()) return;
    setState(() => _trading = true);
    final error = await widget.onTrade(side, _qty, _quote?.ltp ?? 0);
    if (!mounted) return;
    if (error == null) {
      if (side == 'B') await _armExitsAfterFill();
      if (mounted) Navigator.of(context).pop();
    } else {
      setState(() => _trading = false);
      _loadFund(); // available fund may have changed
    }
  }

  void _sheetSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
  }

  int _msFor(TimeOfDay t) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, t.hour, t.minute)
        .millisecondsSinceEpoch;
  }

  String _fmtTod(TimeOfDay? t) {
    if (t == null) return 'Pick time';
    var h = t.hour % 12;
    if (h == 0) h = 12;
    final ampm = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $ampm';
  }

  Future<void> _editNumber({
    required String title,
    required double? initial,
    required void Function(double?) onSet,
  }) async {
    final ctrl =
        TextEditingController(text: initial?.toString() ?? '');
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, -1.0),
              child: const Text('Clear')),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value == null) return;
    onSet(value < 0 ? null : value);
  }

  Future<void> _placePending(String side) async {
    if (_trading) return;
    final item = widget.item;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    double? trigPrice;
    int? trigTime;
    if (_orderType == 'PRICE') {
      if (_limitPrice == null || _limitPrice! <= 0) {
        _sheetSnack('Set the trigger price first');
        return;
      }
      trigPrice = _limitPrice;
    } else {
      if (_limitTime == null) {
        _sheetSnack('Pick the execution time first');
        return;
      }
      trigTime = _msFor(_limitTime!);
      if (trigTime <= nowMs) {
        _sheetSnack('That time has already passed today');
        return;
      }
    }
    double? tPrice, tPct;
    int? tTime;
    if (side == 'B' && _targetType != 'NONE') {
      if (_targetType == 'PRICE') {
        final hasPrice = _targetPrice != null && _targetPrice! > 0;
        final hasPct = _targetPct != null && _targetPct! > 0;
        if (!hasPrice && !hasPct) {
          _sheetSnack('Set a target price or a target %');
          return;
        }
        if (hasPrice) {
          tPrice = _targetPrice;
        } else {
          tPct = _targetPct;
        }
      } else {
        if (_targetTime == null) {
          _sheetSnack('Pick the target time first');
          return;
        }
        tTime = _msFor(_targetTime!);
        if (tTime <= nowMs) {
          _sheetSnack('Target time has already passed today');
          return;
        }
      }
    }
    if (side == 'B') {
      // Same direction rules as Execute Now, against the CURRENT
      // price: target above it, stop-loss below it.
      final cur = _quote?.ltp ?? 0;
      if (cur > 0 && tPrice != null && tPrice <= cur) {
        _sheetSnack(
            'Target price must be ABOVE the current price ₹${cur.toStringAsFixed(2)}');
        return;
      }
      if (cur > 0 &&
          _slPrice != null &&
          _slPrice! > 0 &&
          _slPrice! >= cur) {
        _sheetSnack(
            'Stop-loss must be BELOW the current price ₹${cur.toStringAsFixed(2)}');
        return;
      }
    }
    setState(() => _trading = true);
    final order = PaperPendingOrder(
      symbol: item.symbol,
      exchange: KotakApi.normalizeSegment(item.exchange),
      token: item.token,
      displayName: item.displayName,
      instrumentType: item.instrumentType,
      lotSize: item.lotSize,
      side: side,
      qty: _qty,
      triggerType: _orderType,
      triggerPrice: trigPrice,
      triggerTimeMs: trigTime,
      targetPrice: tPrice,
      targetPct: tPct,
      targetTimeMs: tTime,
      slPrice: (side == 'B' && _slPrice != null && _slPrice! > 0)
          ? _slPrice
          : null,
      slPct:
          (side == 'B' && _slPct != null && _slPct! > 0) ? _slPct : null,
      createdMs: nowMs,
    );
    final error = await widget.onPlacePending(order);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _trading = false);
    }
  }

  void _submit(String side) {
    if (_orderType == 'NOW') {
      _trade(side);
    } else {
      _placePending(side);
    }
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: const Color(0xFF2962FF),
      backgroundColor: Colors.white10,
      labelStyle:
          TextStyle(color: selected ? Colors.white : Colors.white60),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _tapRow(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(label,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(value,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.edit, color: Colors.white38, size: 14),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color ?? Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final quote = _quote;
    final ltp = quote?.ltp ?? 0;
    final margin = ltp > 0
        ? PaperBroker.marginFor(
            qty: _qty, price: ltp, instrumentType: item.instrumentType)
        : 0.0;
    final available = _fund?.available;
    final notEnough =
        available != null && margin > 0 && margin > available + 0.005;

    // Scrollable: with the fund box, execute options, target and
    // stop-loss sections, the sheet is tall — on a short phone it
    // must scroll instead of overflowing.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: SingleChildScrollView(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.withAlpha(40),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('PAPER',
                    style: TextStyle(
                        color: Colors.orange,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (quote != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text('₹${quote.ltp.toStringAsFixed(2)}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: _green,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text('LIVE',
                          style: TextStyle(
                              color: _green,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${quote.change >= 0 ? '+' : ''}${quote.change.toStringAsFixed(2)} (${quote.changePct >= 0 ? '+' : ''}${quote.changePct.toStringAsFixed(2)}%)',
                      style: TextStyle(
                          color: quote.change >= 0 ? _green : _red,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _row('Open', '₹${quote.open.toStringAsFixed(2)}'),
            _row('High', '₹${quote.high.toStringAsFixed(2)}'),
            _row('Low', '₹${quote.low.toStringAsFixed(2)}'),
            _row('Prev Close', '₹${quote.prevClose.toStringAsFixed(2)}'),
            _row('Volume', quote.volume.toString()),
          ] else
            const Text('Live price not loaded yet',
                style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _row(
                  'Available fund',
                  available == null
                      ? '…'
                      : '₹${available.toStringAsFixed(2)}',
                ),
                _row(
                  'Leverage',
                  _isEquity ? '5x (MTF)' : 'None — full amount',
                ),
                _row(
                  'Margin needed for BUY',
                  ltp > 0 ? '₹${margin.toStringAsFixed(2)}' : '—',
                  color: notEnough ? _red : null,
                ),
                if (notEnough)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Not enough virtual fund for this quantity',
                      style: TextStyle(color: _red, fontSize: 11.5),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Quantity',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline,
                        color: Colors.white70),
                    onPressed: () {
                      if (_qty > _step) setState(() => _qty -= _step);
                    },
                  ),
                  GestureDetector(
                    onTap: _editQty,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('$_qty',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: Colors.white70),
                    onPressed: () => setState(() => _qty += _step),
                  ),
                ],
              ),
            ],
          ),
          const Center(
            child: Text('Tap the quantity number to type it directly',
                style: TextStyle(color: Colors.white24, fontSize: 10.5)),
          ),
          const SizedBox(height: 14),
          const Text('Execute',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip('Now', _orderType == 'NOW',
                  () => setState(() => _orderType = 'NOW')),
              _chip('At price', _orderType == 'PRICE', () {
                setState(() {
                  _orderType = 'PRICE';
                  _limitPrice ??= _quote?.ltp;
                });
              }),
              _chip('At time', _orderType == 'TIME',
                  () => setState(() => _orderType = 'TIME')),
            ],
          ),
          if (_orderType == 'PRICE')
            _tapRow(
              'When price touches',
              _limitPrice != null
                  ? '₹${_limitPrice!.toStringAsFixed(2)}'
                  : 'Set price',
              () => _editNumber(
                title: 'Trigger price (₹)',
                initial: _limitPrice,
                onSet: (v) => setState(() => _limitPrice = v),
              ),
            ),
          if (_orderType == 'TIME')
            _tapRow(
              'Execute today at',
              _fmtTod(_limitTime),
              () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _limitTime ?? TimeOfDay.now(),
                );
                if (picked != null) {
                  setState(() => _limitTime = picked);
                }
              },
            ),
          const SizedBox(height: 12),
          const Text('Target — exit after BUY fills',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip('No target', _targetType == 'NONE',
                  () => setState(() => _targetType = 'NONE')),
              _chip('Target price', _targetType == 'PRICE',
                  () => setState(() => _targetType = 'PRICE')),
              _chip('Target time', _targetType == 'TIME',
                  () => setState(() => _targetType = 'TIME')),
            ],
          ),
          if (_targetType == 'PRICE') ...[
            _tapRow(
              'Target price',
              _targetPrice != null
                  ? '₹${_targetPrice!.toStringAsFixed(2)}'
                  : 'Set price',
              () => _editNumber(
                title: 'Target price (₹)',
                // Starts from the CURRENT price — raise it to your
                // target.
                initial: _targetPrice ?? _quote?.ltp,
                onSet: (v) => setState(() {
                  _targetPrice = v;
                  if (v != null) _targetPct = null; // price OR % — one only
                }),
              ),
            ),
            _tapRow(
              'or Target % gain',
              _targetPct != null
                  ? '+${_targetPct!.toStringAsFixed(1)}%'
                  : 'Set %',
              () => _editNumber(
                title: 'Target % gain',
                initial: _targetPct,
                onSet: (v) => setState(() {
                  _targetPct = v;
                  if (v != null) _targetPrice = null; // price OR % — one only
                }),
              ),
            ),
          ],
          if (_targetType == 'TIME')
            _tapRow(
              'Exit today at',
              _fmtTod(_targetTime),
              () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _targetTime ?? TimeOfDay.now(),
                );
                if (picked != null) {
                  setState(() => _targetTime = picked);
                }
              },
            ),
          const SizedBox(height: 8),
          const Text('Stop-loss (optional, for BUY)',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          _tapRow(
            'Stop-loss price',
            _slPrice != null
                ? '₹${_slPrice!.toStringAsFixed(2)}'
                : 'Not set',
            () => _editNumber(
              title: 'Stop-loss price (₹)',
              // Starts from the CURRENT price — lower it to your
              // stop-loss.
              initial: _slPrice ?? _quote?.ltp,
              onSet: (v) => setState(() {
                _slPrice = v;
                if (v != null) _slPct = null; // price OR % — one only
              }),
            ),
          ),
          _tapRow(
            'or Stop-loss % loss',
            _slPct != null
                ? '−${_slPct!.toStringAsFixed(1)}%'
                : 'Not set',
            () => _editNumber(
              title: 'Stop-loss % loss',
              initial: _slPct,
              onSet: (v) => setState(() {
                _slPct = v;
                if (v != null) _slPrice = null; // price OR % — one only
              }),
            ),
          ),
          const Text(
            'Target and stop-loss apply to BUY orders in every mode '
            '(Now, At price, At time): when the buy fills, the exits '
            'are armed automatically, and whichever fires first '
            'cancels the other. Target must be ABOVE the current '
            'price, stop-loss BELOW it — and for each one, use the '
            'price OR the %, never both.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _trading ? null : () => _submit('B'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                      _orderType == 'NOW' ? 'BUY (Paper)' : 'Place BUY order',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _trading ? null : () => _submit('S'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(
                      _orderType == 'NOW'
                          ? 'SELL (Paper)'
                          : 'Place SELL order',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
            const Center(
              child: Text('Paper trade only — no real order goes to Kotak',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}
