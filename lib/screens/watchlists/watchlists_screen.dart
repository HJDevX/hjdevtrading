import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/instrument_search_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/scrip_master_service.dart';

class WatchlistsScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const WatchlistsScreen({super.key, this.onLogout});

  @override
  State<WatchlistsScreen> createState() => _WatchlistsScreenState();
}

class _WatchlistsScreenState extends State<WatchlistsScreen> {
  final AppDb _db = AppDb.instance;
  final KotakApi _api = KotakApi.instance;

  List<Watchlist> _watchlists = [];
  int _activeWatchlistIndex = 0;
  List<WatchItem> _activeItems = [];
  final Map<String, Quote> _quotes = {};
  bool _isLoading = true;
  bool _isEditMode = false;
  Timer? _realtimeTimer;

  // Header Indices Quotes (NIFTY & SENSEX)
  double _niftyLtp = 25201.55;
  double _niftyChange = -185.85;
  double _niftyChangePct = -0.73;

  double _sensexLtp = 81971.99;
  double _sensexChange = -560.20;
  double _sensexChangePct = -0.68;
  bool _isSyncingScrips = false;

  @override
  void initState() {
    super.initState();
    _loadWatchlists();
    _startRealtimePolling();
    _checkMorningAutoRefresh();
  }

  void _checkMorningAutoRefresh() {
    // Auto-refresh once in the morning on first open of a new day
    ScripMasterService.instance.checkAndAutoRefreshMorning(
      onProgress: (msg) {
        debugPrint('Morning auto-refresh: $msg');
      },
    );
  }

  Future<void> _handleRefreshScripMaster() async {
    setState(() => _isSyncingScrips = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Downloading Kotak Scrip Master…'),
        duration: Duration(seconds: 2),
      ),
    );

    final result = await ScripMasterService.instance.syncScripMaster(
      force: true,
      onProgress: (msg) {
        debugPrint('Scrip master sync: $msg');
      },
    );

    if (mounted) {
      setState(() => _isSyncingScrips = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor:
              result.success ? Colors.green.shade800 : Colors.red.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  void dispose() {
    _realtimeTimer?.cancel();
    super.dispose();
  }

  void _startRealtimePolling() {
    // Polls live data every 2 seconds for real-time updates
    _realtimeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) {
        _fetchLiveQuotes();
      }
    });
  }

  Future<void> _loadWatchlists() async {
    setState(() => _isLoading = true);
    final lists = await _db.getWatchlists();
    if (!mounted) return;
    setState(() {
      _watchlists = lists;
      if (_activeWatchlistIndex >= _watchlists.length) {
        _activeWatchlistIndex = _watchlists.isNotEmpty ? _watchlists.length - 1 : 0;
      }
    });

    if (_watchlists.isNotEmpty) {
      await _loadActiveWatchlistItems();
    } else {
      if (!mounted) return;
      setState(() {
        _activeItems = [];
        _isLoading = false;
      });
    }
  }

  Future<void> _loadActiveWatchlistItems() async {
    if (_watchlists.isEmpty) return;
    final activeList = _watchlists[_activeWatchlistIndex];
    final items = await _db.getItems(activeList.id!);
    if (mounted) {
      setState(() {
        _activeItems = items;
        _isLoading = false;
      });
      _fetchLiveQuotes();
    }
  }

  Future<void> _fetchLiveQuotes() async {
    if (!_api.isLoggedIn) {
      return;
    }

    // 1. Fetch live quotes for active items
    for (final item in _activeItems) {
      try {
        final quote = await _api.getQuote(
          item.symbol,
          item.exchange,
          token: item.token,
        );
        if (mounted) {
          setState(() {
            _quotes['${item.exchange}|${item.symbol}'] = quote;
          });
        }
      } catch (e) {
        debugPrint('Realtime quote error for ${item.symbol}: $e');
      }
    }

    // 2. Fetch live quotes for top indices
    try {
      final niftyQuote = await _api.getQuote('NIFTY 50', 'nse_cm', token: '26000');
      if (mounted) {
        setState(() {
          _niftyLtp = niftyQuote.ltp;
          _niftyChange = niftyQuote.change;
          _niftyChangePct = niftyQuote.changePct;
        });
      }
    } catch (_) {}

    try {
      final sensexQuote = await _api.getQuote('SENSEX', 'bse_cm', token: '1');
      if (mounted) {
        setState(() {
          _sensexLtp = sensexQuote.ltp;
          _sensexChange = sensexQuote.change;
          _sensexChangePct = sensexQuote.changePct;
        });
      }
    } catch (_) {}
  }

  // --- Watchlist Management Dialogs ---

  void _showManageWatchlistsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16191E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Manage Watchlists',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('New List'),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      _showCreateListDialog();
                    },
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _watchlists.length,
                  itemBuilder: (context, idx) {
                    final wl = _watchlists[idx];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        wl.name,
                        style: TextStyle(
                          color: idx == _activeWatchlistIndex
                              ? const Color(0xFF387ED1)
                              : Colors.white,
                          fontWeight: idx == _activeWatchlistIndex
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined,
                                size: 18, color: Colors.grey),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _showRenameDialog(wl);
                            },
                          ),
                          if (_watchlists.length > 1)
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: Colors.redAccent),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _confirmDeleteWatchlist(wl);
                              },
                            ),
                        ],
                      ),
                      onTap: () {
                        setState(() {
                          _activeWatchlistIndex = idx;
                        });
                        Navigator.pop(ctx);
                        _loadActiveWatchlistItems();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateListDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2228),
        title: const Text('New Watchlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Watchlist Name',
            hintText: 'e.g. Pharma, Banking',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              await _db.createWatchlist(name);
              if (ctx.mounted) Navigator.pop(ctx);
              await _loadWatchlists();
              setState(() {
                _activeWatchlistIndex = _watchlists.length - 1;
              });
              _loadActiveWatchlistItems();
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRenameDialog(Watchlist list) async {
    final controller = TextEditingController(text: list.name);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2228),
        title: const Text('Rename Watchlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'New Name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isEmpty) return;
              await _db.renameWatchlist(list.id!, newName);
              if (ctx.mounted) Navigator.pop(ctx);
              _loadWatchlists();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteWatchlist(Watchlist list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2228),
        title: const Text('Delete Watchlist', style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "${list.name}" and all its stocks?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && list.id != null) {
      await _db.deleteWatchlist(list.id!);
      _loadWatchlists();
    }
  }

  Future<void> _showLogoutConfirmDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2228),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to logout from Kotak Neo?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _api.deleteSavedSession();
      widget.onLogout?.call();
    }
  }

  Future<void> _deleteItem(WatchItem item) async {
    if (item.id != null) {
      await _db.removeItem(item.id!);
      _loadActiveWatchlistItems();
    }
  }

  void _openSearchScreen() async {
    if (_watchlists.isEmpty) {
      await _db.createWatchlist("India's Best");
      await _loadWatchlists();
    }
    if (_watchlists.isEmpty || !mounted) return;
    final activeList = _watchlists[_activeWatchlistIndex];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InstrumentSearchScreen(watchlist: activeList),
      ),
    );
    if (!mounted) return;
    _loadActiveWatchlistItems();
  }

  void _showStockDetailsSheet(WatchItem item, Quote? quote) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16191E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final ltp = quote != null ? quote.ltp : 0.0;
        final chg = quote != null ? quote.change : 0.0;
        final chgPct = quote != null ? quote.changePct : 0.0;
        final isPositive = chg >= 0;
        final color = isPositive ? const Color(0xFF00C853) : const Color(0xFFE53935);

        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.symbol,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        item.displayName,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        ltp > 0 ? ltp.toStringAsFixed(2) : '—',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      if (ltp > 0)
                        Text(
                          '${isPositive ? "+" : ""}${chg.toStringAsFixed(2)} (${isPositive ? "+" : ""}${chgPct.toStringAsFixed(2)}%)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white24),
              const SizedBox(height: 8),

              // Market stats grid
              if (quote != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildStatCol('Open', quote.open.toStringAsFixed(2)),
                    _buildStatCol('High', quote.high.toStringAsFixed(2)),
                    _buildStatCol('Low', quote.low.toStringAsFixed(2)),
                    _buildStatCol('Prev Close', quote.prevClose.toStringAsFixed(2)),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              // Action Buttons: Buy / Sell (Paper) and Delete
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF387ED1),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Paper BUY ${item.symbol} registered'),
                            backgroundColor: const Color(0xFF387ED1),
                          ),
                        );
                      },
                      child: const Text('BUY (PAPER)'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE53935),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Paper SELL ${item.symbol} registered'),
                            backgroundColor: const Color(0xFFE53935),
                          ),
                        );
                      },
                      child: const Text('SELL (PAPER)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _deleteItem(item);
                    },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatCol(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13, color: Colors.white)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeWatchlist = _watchlists.isNotEmpty
        ? _watchlists[_activeWatchlistIndex]
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1216),
      body: SafeArea(
        child: Column(
          children: [
            // --- TOP MARKET INDICES HEADER (NIFTY & SENSEX) ---
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              color: const Color(0xFF0F1216),
              child: Row(
                children: [
                  // NIFTY
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'NIFTY',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              _niftyLtp.toStringAsFixed(2),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${_niftyChange >= 0 ? "+" : ""}${_niftyChange.toStringAsFixed(2)} (${_niftyChangePct.toStringAsFixed(2)}%)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _niftyChange >= 0
                                      ? const Color(0xFF00C853)
                                      : const Color(0xFFE53935),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // SENSEX
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SENSEX',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              _sensexLtp.toStringAsFixed(2),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${_sensexChange >= 0 ? "+" : ""}${_sensexChange.toStringAsFixed(2)} (${_sensexChangePct.toStringAsFixed(2)}%)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _sensexChange >= 0
                                      ? const Color(0xFF00C853)
                                      : const Color(0xFFE53935),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Down Chevron & PAPER badge
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade800,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'PAPER',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        color: Color(0xFF387ED1),
                        size: 22,
                      ),
                      const SizedBox(width: 4),
                      // Refresh Instruments (⟳) Button
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: _isSyncingScrips
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF387ED1),
                                ),
                              )
                            : const Icon(
                                Icons.refresh,
                                color: Color(0xFF387ED1),
                                size: 20,
                              ),
                        tooltip: 'Refresh Instruments (Kotak Scrip Master)',
                        onPressed: _isSyncingScrips ? null : _handleRefreshScripMaster,
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        icon: const Icon(
                          Icons.logout,
                          color: Colors.redAccent,
                          size: 18,
                        ),
                        tooltip: 'Logout from Kotak Neo',
                        onPressed: _showLogoutConfirmDialog,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // --- WATCHLIST TABS (Horizontal Scrollable) ---
            Container(
              height: 44,
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF1E2228), width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _watchlists.isEmpty
                        ? const SizedBox.shrink()
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _watchlists.length,
                            itemBuilder: (context, idx) {
                              final isSelected = idx == _activeWatchlistIndex;
                              final name = _watchlists[idx].name;

                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _activeWatchlistIndex = idx;
                                  });
                                  _loadActiveWatchlistItems();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    border: isSelected
                                        ? const Border(
                                            bottom: BorderSide(
                                              color: Color(0xFF387ED1),
                                              width: 2.5,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: Center(
                                    child: Text(
                                      name,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? const Color(0xFF387ED1)
                                            : Colors.grey.shade400,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  // Manage Watchlists Button (≡+)
                  IconButton(
                    icon: const Icon(
                      Icons.playlist_add,
                      color: Color(0xFF387ED1),
                      size: 22,
                    ),
                    tooltip: 'Manage Watchlists',
                    onPressed: _showManageWatchlistsSheet,
                  ),
                ],
              ),
            ),

            // --- SEARCH & QUICK ACTION BAR ---
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  // Search & Add Bar
                  Expanded(
                    child: InkWell(
                      onTap: _openSearchScreen,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF16191E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFF262B33),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.search, size: 20, color: Colors.grey.shade400),
                            const SizedBox(width: 8),
                            Text(
                              'Search & add',
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Filter Button
                  Container(
                    height: 42,
                    width: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF16191E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF262B33),
                        width: 1,
                      ),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.filter_list,
                          size: 20, color: Color(0xFF387ED1)),
                      tooltip: 'Filter Stocks',
                      onPressed: () {
                        // Sort by Name, % Change, LTP
                        setState(() {
                          _activeItems.sort((a, b) => a.symbol.compareTo(b.symbol));
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Edit Button
                  Container(
                    height: 42,
                    width: 42,
                    decoration: BoxDecoration(
                      color: _isEditMode
                          ? const Color(0xFF387ED1).withAlpha(50)
                          : const Color(0xFF16191E),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _isEditMode
                            ? const Color(0xFF387ED1)
                            : const Color(0xFF262B33),
                        width: 1,
                      ),
                    ),
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _isEditMode ? Icons.check : Icons.edit_outlined,
                        size: 20,
                        color: Colors.grey.shade400,
                      ),
                      tooltip: 'Edit Watchlist',
                      onPressed: () {
                        setState(() {
                          _isEditMode = !_isEditMode;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),

            // --- STOCK LIST ---
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Color(0xFF387ED1)),
                    )
                  : _activeItems.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.candlestick_chart_outlined,
                                  size: 48, color: Colors.grey.shade600),
                              const SizedBox(height: 12),
                              Text(
                                'No stocks in ${activeWatchlist?.name ?? "this list"}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF387ED1),
                                ),
                                onPressed: _openSearchScreen,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add Stocks'),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          color: const Color(0xFF387ED1),
                          backgroundColor: const Color(0xFF16191E),
                          onRefresh: () async {
                            await _loadActiveWatchlistItems();
                          },
                          child: ListView.separated(
                            itemCount: _activeItems.length,
                            separatorBuilder: (context, index) => const Divider(
                              height: 1,
                              color: Color(0xFF1E2228),
                            ),
                            itemBuilder: (context, index) {
                              final item = _activeItems[index];
                              final key = '${item.exchange}|${item.symbol}';
                              final quote = _quotes[key];

                              final ltpStr = quote != null
                                  ? quote.ltp.toStringAsFixed(2)
                                  : '—';
                              final changeVal = quote != null ? quote.change : 0.0;
                              final changePctVal =
                                  quote != null ? quote.changePct : 0.0;
                              final isPositive = changeVal >= 0;
                              final changeColor = isPositive
                                  ? const Color(0xFF00C853)
                                  : const Color(0xFFE53935);

                              final changeStr = quote != null
                                  ? '${changeVal >= 0 ? "+" : ""}${changeVal.toStringAsFixed(2)} (${changePctVal >= 0 ? "+" : ""}${changePctVal.toStringAsFixed(2)}%)'
                                  : '—';

                              return InkWell(
                                onTap: () => _showStockDetailsSheet(item, quote),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      // Left: Symbol & Exchange
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.symbol,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                              color: Colors.white,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            _buildExchangeSubtitle(item),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade500,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),

                                      // Right: LTP & Change or Delete in edit mode
                                      if (_isEditMode)
                                        IconButton(
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                            color: Colors.redAccent,
                                            size: 22,
                                          ),
                                          onPressed: () => _deleteItem(item),
                                        )
                                      else
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              ltpStr,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 15,
                                                color: Colors.white,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              changeStr,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: changeColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildExchangeSubtitle(WatchItem item) {
    if (item.instrumentType == 'CE' || item.instrumentType == 'PE') {
      final strikeStr = item.strike != null ? item.strike!.toStringAsFixed(0) : '';
      return '${item.exchange == "nse_fo" ? "NSE" : item.exchange} $strikeStr ${item.instrumentType}';
    }
    if (item.instrumentType == 'FUT') {
      return '${item.exchange == "nse_fo" ? "NSE" : item.exchange} FUT';
    }
    if (item.exchange == 'nse_cm') return 'NSE';
    if (item.exchange == 'bse_cm') return 'BSE';
    if (item.exchange == 'mcx_fo') return 'MCX';
    return item.exchange.toUpperCase();
  }
}
