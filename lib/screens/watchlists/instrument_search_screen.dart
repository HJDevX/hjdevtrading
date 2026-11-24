import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// Search the downloaded scrip master and add instruments to a
/// watchlist. Every result comes from Kotak's own instrument list —
/// the app ships with zero hardcoded stock names.
class InstrumentSearchScreen extends StatefulWidget {
  final int watchlistId;
  final String watchlistName;

  const InstrumentSearchScreen({
    super.key,
    required this.watchlistId,
    required this.watchlistName,
  });

  @override
  State<InstrumentSearchScreen> createState() =>
      _InstrumentSearchScreenState();
}

class _InstrumentSearchScreenState extends State<InstrumentSearchScreen> {
  final AppDb _db = AppDb.instance;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<Scrip> _results = [];
  final Set<String> _addedKeys = {};
  String _filter = 'All'; // All, Stocks, Futures, Options, Commodity
  bool _isSearching = false;
  bool _hasSearched = false;

  static const Color _card = Color(0xFFF7F7F7);
  static const Color _blue = Color(0xFF387ED1);

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _keyOf(Scrip s) => '${s.segment}|${s.token}|${s.symbol}';

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    setState(() => _isSearching = true);
    final results = await _db.searchScrips(q, limit: 60);
    final added = <String>{};
    for (final s in results) {
      if (await _db.isScripInWatchlist(widget.watchlistId, s)) {
        added.add(_keyOf(s));
      }
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _addedKeys
        ..clear()
        ..addAll(added);
      _isSearching = false;
      _hasSearched = true;
    });
  }

  String _category(Scrip s) {
    if (s.segment == 'mcx_fo') return 'Commodity';
    switch (s.instrumentType) {
      case 'FUT':
        return 'Futures';
      case 'CE':
      case 'PE':
        return 'Options';
      default:
        return 'Stocks';
    }
  }

  List<Scrip> get _filtered {
    if (_filter == 'All') return _results;
    return _results.where((s) => _category(s) == _filter).toList();
  }

  Future<void> _toggleAdd(Scrip scrip) async {
    final key = _keyOf(scrip);
    if (_addedKeys.contains(key)) return;
    await _db.addItem(WatchItem(
      watchlistId: widget.watchlistId,
      symbol: scrip.symbol,
      exchange: scrip.segment,
      token: scrip.token,
      displayName: scrip.displayName,
      instrumentType: scrip.instrumentType,
      expiry: scrip.expiry,
      strike: scrip.strike,
      lotSize: scrip.lotSize,
    ));
    if (!mounted) return;
    setState(() => _addedKeys.add(key));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Add to ${widget.watchlistName}',
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: _onQueryChanged,
              style: const TextStyle(color: Color(0xFF424242)),
              decoration: InputDecoration(
                hintText: 'Search e.g. RELIANCE, NIFTY, GOLD...',
                hintStyle: const TextStyle(color: Color(0xFF9B9B9B)),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF9B9B9B)),
                filled: true,
                fillColor: _card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: ['All', 'Stocks', 'Futures', 'Options', 'Commodity']
                  .map((f) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                          selectedColor: _blue,
                          backgroundColor: _card,
                          labelStyle: TextStyle(
                              color: _filter == f
                                  ? Colors.white
                                  : Color(0xFF666666),
                              fontSize: 13),
                          side: BorderSide.none,
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasSearched) {
      return const Center(
        child: Text('Type at least 2 characters to search',
            style: TextStyle(color: Color(0xFF9B9B9B))),
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No instruments found.\nIf the list is empty, download today\'s stock list from the watchlist screen (cloud icon) first.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF9B9B9B)),
          ),
        ),
      );
    }

    // Group by category when showing All.
    final widgets = <Widget>[];
    if (_filter == 'All') {
      for (final cat in ['Stocks', 'Futures', 'Options', 'Commodity']) {
        final group = list.where((s) => _category(s) == cat).toList();
        if (group.isEmpty) continue;
        widgets.add(_sectionHeader(cat));
        widgets.addAll(group.map(_row));
      }
    } else {
      widgets.addAll(list.map(_row));
    }

    return ListView(children: widgets);
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(title.toUpperCase(),
          style: const TextStyle(
              color: _blue, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  Widget _row(Scrip scrip) {
    final added = _addedKeys.contains(_keyOf(scrip));
    final isDeriv = scrip.instrumentType == 'FUT' ||
        scrip.instrumentType == 'CE' ||
        scrip.instrumentType == 'PE';
    return ListTile(
      title: Text(scrip.symbol,
          style: const TextStyle(color: Color(0xFF424242), fontSize: 14)),
      subtitle: Text(
        isDeriv
            ? '${scrip.displayName} • ${scrip.instrumentType}'
                '${scrip.expiry != null ? ' • Exp ${scrip.expiry}' : ''}'
                '${scrip.strike != null ? ' • Strike ${scrip.strike!.toStringAsFixed(0)}' : ''}'
                '${scrip.lotSize != null ? ' • Lot ${scrip.lotSize}' : ''}'
            : '${scrip.displayName} • ${scrip.exchange}',
        style: const TextStyle(color: Color(0xFF9B9B9B), fontSize: 11.5),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: added
          ? const Chip(
              label: Text('Added', style: TextStyle(fontSize: 11)),
              backgroundColor: Color(0xFFE6F4EA),
              labelStyle: TextStyle(color: Color(0xFF00C853)),
              side: BorderSide.none,
            )
          : IconButton(
              icon: const Icon(Icons.add_circle, color: _blue, size: 28),
              onPressed: () => _toggleAdd(scrip),
            ),
    );
  }
}
