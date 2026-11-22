import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/instrument_search_screen.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/paper_broker.dart';
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
      if (!mounted) return;
      setState(() {
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
      });
    });
    _stateSub = _feed.states.listen((s) {
      if (!mounted) return;
      setState(() => _feedConnected = s == IndexFeedState.connected);
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
    final quote = item.id != null ? _quotes[item.id!] : null;
    final isDeriv = item.instrumentType == 'FUT' ||
        item.instrumentType == 'CE' ||
        item.instrumentType == 'PE';
    final step = isDeriv ? (item.lotSize ?? 1) : 1;
    var qty = step;

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
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
                    Text('₹${quote.ltp.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    Text(
                      '${quote.change >= 0 ? '+' : ''}${quote.change.toStringAsFixed(2)} (${quote.changePct >= 0 ? '+' : ''}${quote.changePct.toStringAsFixed(2)}%)',
                      style: TextStyle(
                          color: quote.change >= 0 ? _green : _red,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _ohlcRow('Open', quote.open),
                _ohlcRow('High', quote.high),
                _ohlcRow('Low', quote.low),
                _ohlcRow('Prev Close', quote.prevClose),
                _ohlcRow('Volume', quote.volume.toDouble(), isVolume: true),
              ] else
                const Text('Live price not loaded yet',
                    style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 18),
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
                          _paperTrade(item, 'B', qty, quote, ctx),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _green,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('BUY (Paper)',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () =>
                          _paperTrade(item, 'S', qty, quote, ctx),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _red,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('SELL (Paper)',
                          style: TextStyle(
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

  Future<void> _paperTrade(WatchItem item, String side, int qty,
      Quote? quote, BuildContext sheetCtx) async {
    var price = quote?.ltp ?? 0;
    if (price <= 0) {
      // One fresh fetch before giving up.
      final fresh = await _api.getQuotesBatch([item]);
      final freshQuote = (item.token != null ? fresh[item.token!] : null) ??
          fresh['${item.exchange}|${item.symbol}'] ??
          fresh['${item.exchange}|${item.token}'];
      if (freshQuote != null) {
        price = freshQuote.ltp;
      }
    }
    final error = side == 'B'
        ? await PaperBroker.instance.buy(item: item, qty: qty, price: price)
        : await PaperBroker.instance.sell(item: item, qty: qty, price: price);
    if (!mounted) return;
    if (sheetCtx.mounted) {
      Navigator.of(sheetCtx).pop();
    }
    if (error != null) {
      _snack(error, green: false);
    } else {
      _snack(
          'Paper ${side == 'B' ? 'BUY' : 'SELL'} $qty ${item.symbol} @ ₹${price.toStringAsFixed(2)} — see Practice tab',
          green: true);
    }
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
              const Text('HJDev Trading',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.bold)),
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
              Text(_feedConnected ? 'Live' : 'Index feed off',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
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
          const Spacer(),
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
              Text('Search stocks, futures, options...',
                  style: TextStyle(color: Colors.white38, fontSize: 13)),
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
