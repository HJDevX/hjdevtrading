import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/instrument_search_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

class WatchlistDetailScreen extends StatefulWidget {
  final Watchlist watchlist;

  const WatchlistDetailScreen({super.key, required this.watchlist});

  @override
  State<WatchlistDetailScreen> createState() => _WatchlistDetailScreenState();
}

class _WatchlistDetailScreenState extends State<WatchlistDetailScreen> {
  final AppDb _db = AppDb.instance;
  final KotakApi _api = KotakApi.instance;

  List<WatchItem> _items = [];
  final Map<int, Quote> _quotes = {};
  bool _isLoading = true;
  bool _isRefreshingQuotes = false;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    setState(() => _isLoading = true);
    final items = await _db.getItems(widget.watchlist.id!);
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  Future<void> _refreshQuotes() async {
    if (_api.accessToken == null || _api.accessToken!.isEmpty) {
      if (!_api.isLoggedIn) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login first'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
    }

    if (_items.isEmpty) return;

    setState(() => _isRefreshingQuotes = true);

    // Resolve missing tokens
    final resolvedItems = <WatchItem>[];
    for (final item in _items) {
      if (item.token == null || item.token!.trim().isEmpty) {
        final lookedUp =
            await _db.findTokenBySymbolAndSegment(item.symbol, item.exchange);
        if (lookedUp != null && lookedUp.trim().isNotEmpty) {
          if (item.id != null) {
            await _db.updateItemToken(item.id!, lookedUp);
          }
          resolvedItems.add(item.copyWith(token: lookedUp));
          continue;
        }
      }
      resolvedItems.add(item);
    }

    if (mounted) {
      setState(() => _items = resolvedItems);
    }

    final validItems = _items
        .where((it) => it.token != null && it.token!.trim().isNotEmpty)
        .toList();

    if (validItems.isNotEmpty) {
      try {
        final batchQuotes = await _api.getQuotesBatch(validItems);
        final updatedQuotes = Map<int, Quote>.from(_quotes);
        for (final item in _items) {
          if (item.id != null && item.token != null && batchQuotes.containsKey(item.token)) {
            updatedQuotes[item.id!] = batchQuotes[item.token]!;
          }
        }
        if (mounted) {
          setState(() {
            _quotes.clear();
            _quotes.addAll(updatedQuotes);
          });
        }
      } catch (e) {
        debugPrint('Failed to batch fetch quotes: $e');
      }
    }

    if (mounted) {
      setState(() => _isRefreshingQuotes = false);
    }
  }

  Future<void> _openSearchScreen() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InstrumentSearchScreen(watchlist: widget.watchlist),
      ),
    );
    _loadItems();
  }

  Future<void> _deleteItem(WatchItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Instrument'),
        content: Text('Remove ${item.symbol} from ${widget.watchlist.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true && item.id != null) {
      await _db.removeItem(item.id!);
      _quotes.remove(item.id);
      _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.watchlist.name,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: _isRefreshingQuotes
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Refresh Quotes',
            onPressed: _isRefreshingQuotes ? null : _refreshQuotes,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text(
                        'No instruments in this watchlist',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _openSearchScreen,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Instrument'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final quote = item.id != null ? _quotes[item.id] : null;

                    return ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      title: _buildRowTitle(item),
                      subtitle: _buildRowSubtitle(item),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.token == null || item.token!.trim().isEmpty)
                            const Text(
                              'Token missing — re-add this stock from search',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFFFFB300),
                                fontStyle: FontStyle.italic,
                              ),
                            )
                          else if (quote != null) ...[
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '₹${quote.ltp.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '${quote.changePct >= 0 ? "+" : ""}${quote.changePct.toStringAsFixed(2)}%',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: quote.changePct >= 0
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            const Text(
                              '—',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            tooltip: 'Remove',
                            onPressed: () => _deleteItem(item),
                          ),
                        ],
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openSearchScreen,
        icon: const Icon(Icons.search),
        label: const Text('Add Instrument'),
      ),
    );
  }

  Widget _buildRowTitle(WatchItem item) {
    final type = item.instrumentType ?? 'EQ';
    final isMcx = item.exchange == 'mcx_fo';
    final isNse = item.exchange == 'nse_cm' || item.exchange == 'nse_fo';

    Color tagColor = Colors.blue;
    String tagLabel = isMcx ? 'MCX' : (isNse ? 'NSE' : 'BSE');
    if (type == 'CE') {
      tagColor = Colors.green;
      tagLabel = 'CE';
    } else if (type == 'PE') {
      tagColor = Colors.red;
      tagLabel = 'PE';
    } else if (type == 'FUT') {
      tagColor = Colors.orange;
      tagLabel = 'FUT';
    }

    return Row(
      children: [
        Flexible(
          child: Text(
            item.symbol,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: tagColor.withAlpha(30),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            tagLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: tagColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRowSubtitle(WatchItem item) {
    final details = <String>[];
    if (item.strike != null && item.strike! > 0) {
      details.add('Strike: ${item.strike!.toStringAsFixed(0)}');
    }
    if (item.expiry != null && item.expiry!.isNotEmpty) {
      details.add('Exp: ${item.expiry!}');
    }
    if (item.lotSize != null && item.lotSize! > 1) {
      details.add('Lot: ${item.lotSize!}');
    }

    if (details.isNotEmpty) {
      return Text(
        details.join(' | '),
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
      );
    }

    return Text(
      item.displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: Colors.grey.shade600,
      ),
    );
  }
}
