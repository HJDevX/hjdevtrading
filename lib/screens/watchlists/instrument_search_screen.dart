import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/services/scrip_master_service.dart';

class InstrumentSearchScreen extends StatefulWidget {
  final Watchlist watchlist;

  const InstrumentSearchScreen({super.key, required this.watchlist});

  @override
  State<InstrumentSearchScreen> createState() => _InstrumentSearchScreenState();
}

class _InstrumentSearchScreenState extends State<InstrumentSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final AppDb _db = AppDb.instance;
  final ScripMasterService _masterService = ScripMasterService.instance;

  String _selectedCategory = 'All'; // All | Stocks | Futures | Options | Commodity
  final List<String> _categories = const [
    'All',
    'Stocks',
    'Futures',
    'Options',
    'Commodity',
  ];

  List<Scrip> _searchResults = [];
  Set<String> _addedKeys = {};
  bool _isSearching = false;
  bool _isSyncing = false;
  String _syncProgressMessage = '';
  String _lastUpdatedText = '';

  @override
  void initState() {
    super.initState();
    _loadExistingWatchlistItems();
    _loadLastUpdated();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingWatchlistItems() async {
    final items = await _db.getItems(widget.watchlist.id!);
    if (mounted) {
      setState(() {
        _addedKeys = items
            .map((e) => _itemKey(e.exchange, e.symbol, e.token))
            .toSet();
      });
    }
  }

  String _itemKey(String segment, String symbol, String? token) =>
      '$segment|$symbol|${token ?? ""}';

  Future<void> _loadLastUpdated() async {
    final text = await _masterService.getLastUpdatedDisplay();
    if (mounted) {
      setState(() {
        _lastUpdatedText = text;
      });
    }
  }

  // --- Requirement 4: REFRESH Button (⟳) with Live Progress ---
  Future<void> _handleRefreshInstruments() async {
    setState(() {
      _isSyncing = true;
      _syncProgressMessage = 'Starting Kotak Scrip Master download…';
    });

    final result = await _masterService.syncScripMaster(
      force: true,
      onProgress: (msg) {
        if (mounted) {
          setState(() {
            _syncProgressMessage = msg;
          });
        }
      },
    );

    await _loadLastUpdated();

    if (mounted) {
      setState(() {
        _isSyncing = false;
        _syncProgressMessage = '';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: result.success
              ? Colors.green.shade800
              : Colors.red.shade800,
          duration: const Duration(seconds: 4),
        ),
      );

      // Re-run search if user has text
      if (_searchController.text.trim().length >= 2) {
        _performSearch(_searchController.text.trim());
      }
    }
  }

  // --- Requirement 8: Search min 2 characters, max 30 results ---
  Future<void> _performSearch(String query) async {
    final clean = query.trim();
    if (clean.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    final results = await _db.searchScrips(
      clean,
      categoryFilter: _selectedCategory,
      limit: 30,
    );

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  // --- Requirement 10: Add to Watchlist & Prevent Duplicates ---
  Future<void> _addScrip(Scrip scrip) async {
    final key = _itemKey(scrip.segment, scrip.symbol, scrip.token);

    final isDuplicate = _addedKeys.contains(key) ||
        await _db.isItemInWatchlist(
          widget.watchlist.id!,
          scrip.symbol,
          scrip.segment,
          token: scrip.token,
        );

    if (!mounted) return;

    if (isDuplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${scrip.symbol} is already in ${widget.watchlist.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    final item = WatchItem(
      watchlistId: widget.watchlist.id!,
      symbol: scrip.symbol,
      exchange: scrip.segment,
      token: scrip.token,
      displayName: scrip.displayName,
      instrumentType: scrip.instrumentType,
      expiry: scrip.expiry,
      strike: scrip.strike,
      lotSize: scrip.lotSize,
    );

    await _db.addItem(item);

    if (mounted) {
      setState(() {
        _addedKeys.add(key);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${scrip.symbol} to ${widget.watchlist.name}'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  // --- Requirement 8: Grouping in exact order: STOCKS, FUTURES, OPTIONS, COMMODITY ---
  Map<String, List<Scrip>> _groupResults() {
    final stocks = <Scrip>[];
    final futures = <Scrip>[];
    final options = <Scrip>[];
    final commodity = <Scrip>[];

    for (final s in _searchResults) {
      if (s.segment == 'mcx_fo') {
        commodity.add(s);
      } else if (s.instrumentType == 'EQ') {
        stocks.add(s);
      } else if (s.instrumentType == 'FUT') {
        futures.add(s);
      } else if (s.instrumentType == 'CE' || s.instrumentType == 'PE') {
        options.add(s);
      } else {
        stocks.add(s);
      }
    }

    final groups = <String, List<Scrip>>{};
    if (stocks.isNotEmpty) groups['STOCKS'] = stocks;
    if (futures.isNotEmpty) groups['FUTURES'] = futures;
    if (options.isNotEmpty) groups['OPTIONS'] = options;
    if (commodity.isNotEmpty) groups['COMMODITY'] = commodity;

    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupResults();
    final queryText = _searchController.text.trim();
    final hasMinChars = queryText.length >= 2;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1216),
        title: Text(
          'Add to ${widget.watchlist.name}',
          style: const TextStyle(color: Colors.white, fontSize: 17),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // Refresh Button (⟳) in AppBar
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF387ED1),
                    ),
                  )
                : const Icon(Icons.refresh, color: Color(0xFF387ED1)),
            tooltip: 'Refresh Instruments (Kotak Scrip Master)',
            onPressed: _isSyncing ? null : _handleRefreshInstruments,
          ),
        ],
      ),
      body: Column(
        children: [
          // Live Sync Progress Banner
          if (_isSyncing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF1E2838),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF387ED1),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _syncProgressMessage,
                      style: const TextStyle(
                        color: Color(0xFF387ED1),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Top Search Box (Autocomplete as you type)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF16191E),
                hintText: 'Search stocks, futures, options, MCX (e.g. NIFTY, GOLD, JK)',
                hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          _performSearch('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF262B33)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF262B33)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onChanged: _performSearch,
            ),
          ),

          // Filter Chips: All | Stocks | Futures | Options | Commodity
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: _categories.map((cat) {
                final isSelected = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text(cat),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey.shade400,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12,
                    ),
                    selected: isSelected,
                    selectedColor: const Color(0xFF387ED1),
                    backgroundColor: const Color(0xFF16191E),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF387ED1)
                          : const Color(0xFF262B33),
                    ),
                    onSelected: (selected) {
                      setState(() {
                        _selectedCategory = cat;
                      });
                      if (_searchController.text.trim().length >= 2) {
                        _performSearch(_searchController.text.trim());
                      }
                    },
                  ),
                );
              }).toList(),
            ),
          ),

          // Header: Updated Time & Refresh Button
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF16191E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF262B33)),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _lastUpdatedText,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFF387ED1).withAlpha(30),
                  ),
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF387ED1),
                          ),
                        )
                      : const Icon(Icons.refresh, size: 16, color: Color(0xFF387ED1)),
                  label: const Text(
                    'Refresh',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF387ED1),
                    ),
                  ),
                  onPressed: _isSyncing ? null : _handleRefreshInstruments,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E2228)),

          // Results List (Downloaded Kotak scrips ONLY)
          Expanded(
            child: _isSearching
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF387ED1)),
                  )
                : !hasMinChars
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search, size: 48, color: Colors.grey.shade700),
                            const SizedBox(height: 12),
                            Text(
                              'Type at least 2 characters to search instruments\n(e.g. NIFTY, GOLD, JK)',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      )
                    : grouped.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.info_outline, size: 40, color: Colors.grey.shade700),
                                const SizedBox(height: 8),
                                Text(
                                  'No instruments matching "${_searchController.text}"',
                                  style: TextStyle(color: Colors.grey.shade500),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Suggestions come from downloaded Kotak Scrip Master only.',
                                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: grouped.keys.length,
                            itemBuilder: (context, groupIdx) {
                              final groupKey = grouped.keys.elementAt(groupIdx);
                              final scripsInGroup = grouped[groupKey]!;

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Category Heading (STOCKS, FUTURES, OPTIONS, COMMODITY)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 6,
                                    ),
                                    color: const Color(0xFF14171C),
                                    child: Text(
                                      groupKey,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.8,
                                        color: Color(0xFF387ED1),
                                      ),
                                    ),
                                  ),

                                  // Instrument Rows
                                  ...scripsInGroup.map((scrip) {
                                    final key = _itemKey(
                                        scrip.segment, scrip.symbol, scrip.token);
                                    final isAdded = _addedKeys.contains(key);

                                    return ListTile(
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 2,
                                      ),
                                      title: _buildRowTitle(scrip),
                                      subtitle: _buildRowSubtitle(scrip),
                                      trailing: isAdded
                                          ? Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withAlpha(20),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.check,
                                                      color: Colors.green, size: 16),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    'Added',
                                                    style: TextStyle(
                                                      color: Colors.green,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                          : IconButton(
                                              icon: const Icon(
                                                  Icons.add_circle_outline,
                                                  color: Color(0xFF387ED1)),
                                              tooltip: 'Add to Watchlist',
                                              onPressed: () => _addScrip(scrip),
                                            ),
                                      onTap: () {
                                        if (!isAdded) {
                                          _addScrip(scrip);
                                        }
                                      },
                                    );
                                  }),
                                ],
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  // --- Requirement 9: Row formats ---
  // Stock: SYMBOL — Company Name — NSE/BSE tag
  // Future: SYMBOL — Expiry date — Lot size
  // Option: SYMBOL — Strike — CE/PE — Expiry date — Lot size
  // Commodity: SYMBOL — Expiry date — Lot size — MCX tag

  Widget _buildRowTitle(Scrip scrip) {
    if (scrip.segment == 'mcx_fo') {
      return Row(
        children: [
          Text(
            scrip.symbol,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
          ),
          const SizedBox(width: 8),
          _buildBadge('MCX', Colors.deepOrange),
        ],
      );
    }

    if (scrip.instrumentType == 'EQ') {
      return Row(
        children: [
          Text(
            scrip.symbol,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
          ),
          const SizedBox(width: 8),
          _buildBadge(
            scrip.exchange.toUpperCase(),
            scrip.exchange == 'NSE' ? const Color(0xFF387ED1) : Colors.indigoAccent,
          ),
        ],
      );
    }

    if (scrip.instrumentType == 'FUT') {
      return Row(
        children: [
          Text(
            scrip.symbol,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
          ),
          const SizedBox(width: 8),
          _buildBadge('FUT', Colors.purpleAccent),
        ],
      );
    }

    // Option (CE / PE)
    return Row(
      children: [
        Text(
          scrip.symbol,
          style: const TextStyle(
              fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
        ),
        const SizedBox(width: 8),
        _buildBadge(
          scrip.instrumentType,
          scrip.instrumentType == 'CE' ? Colors.green : Colors.redAccent,
        ),
      ],
    );
  }

  Widget _buildBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget? _buildRowSubtitle(Scrip scrip) {
    // Stock: SYMBOL — Company Name — NSE/BSE tag
    if (scrip.instrumentType == 'EQ') {
      return Text(
        scrip.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
      );
    }

    // Future: SYMBOL — Expiry date — Lot size
    if (scrip.instrumentType == 'FUT') {
      final parts = <String>[];
      if (scrip.expiry != null && scrip.expiry!.isNotEmpty) {
        parts.add(scrip.expiry!);
      }
      if (scrip.lotSize != null && scrip.lotSize! > 0) {
        parts.add('Lot ${scrip.lotSize}');
      }
      return Text(
        parts.isNotEmpty ? parts.join(' — ') : scrip.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
      );
    }

    // Option: SYMBOL — Strike — CE/PE — Expiry date — Lot size
    if (scrip.instrumentType == 'CE' || scrip.instrumentType == 'PE') {
      final parts = <String>[];
      if (scrip.strike != null && scrip.strike! > 0) {
        final strikeStr = scrip.strike! % 1 == 0
            ? scrip.strike!.toInt().toString()
            : scrip.strike!.toStringAsFixed(2);
        parts.add(strikeStr);
      }
      parts.add(scrip.instrumentType);
      if (scrip.expiry != null && scrip.expiry!.isNotEmpty) {
        parts.add(scrip.expiry!);
      }
      if (scrip.lotSize != null && scrip.lotSize! > 0) {
        parts.add('Lot ${scrip.lotSize}');
      }
      return Text(
        parts.join(' — '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
      );
    }

    // Commodity: SYMBOL — Expiry date — Lot size — MCX tag
    final commParts = <String>[];
    if (scrip.expiry != null && scrip.expiry!.isNotEmpty) {
      commParts.add(scrip.expiry!);
    }
    if (scrip.lotSize != null && scrip.lotSize! > 0) {
      commParts.add('Lot ${scrip.lotSize}');
    }
    commParts.add('MCX');
    return Text(
      commParts.join(' — '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
    );
  }
}
