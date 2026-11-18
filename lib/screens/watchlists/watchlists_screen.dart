import 'package:flutter/material.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/watchlist_detail_screen.dart';

class WatchlistsScreen extends StatefulWidget {
  const WatchlistsScreen({super.key});

  @override
  State<WatchlistsScreen> createState() => _WatchlistsScreenState();
}

class _WatchlistsScreenState extends State<WatchlistsScreen> {
  final AppDb _db = AppDb.instance;
  List<Watchlist> _watchlists = [];
  Map<int, int> _counts = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadWatchlists();
  }

  Future<void> _loadWatchlists() async {
    setState(() => _isLoading = true);
    final lists = await _db.getWatchlists();
    final counts = <int, int>{};
    for (final l in lists) {
      if (l.id != null) {
        counts[l.id!] = await _db.itemCount(l.id!);
      }
    }
    setState(() {
      _watchlists = lists;
      _counts = counts;
      _isLoading = false;
    });
  }

  Future<void> _showCreateListDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Watchlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Watchlist Name',
            hintText: 'e.g. Banking, Tech, Top 10',
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
              if (ctx.mounted) {
                Navigator.pop(ctx);
              }
              if (mounted) {
                _loadWatchlists();
              }
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
        title: const Text('Rename Watchlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
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
              if (ctx.mounted) {
                Navigator.pop(ctx);
              }
              if (mounted) {
                _loadWatchlists();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Watchlist list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Watchlist'),
        content: Text(
          'Are you sure you want to delete "${list.name}"?\nThis will also delete all stocks inside it.',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _watchlists.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.format_list_bulleted,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text(
                        'No watchlists yet',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _showCreateListDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('New List'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _watchlists.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = _watchlists[index];
                    final count = _counts[item.id] ?? 0;
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(
                          Icons.show_chart,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        item.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      subtitle: Text(
                        '$count ${count == 1 ? "stock" : "stocks"}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (value) {
                              if (value == 'rename') {
                                _showRenameDialog(item);
                              } else if (value == 'delete') {
                                _confirmDelete(item);
                              }
                            },
                            itemBuilder: (ctx) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Row(
                                  children: [
                                    Icon(Icons.edit_outlined, size: 20),
                                    SizedBox(width: 8),
                                    Text('Rename'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete_outline,
                                        size: 20, color: Colors.red),
                                    SizedBox(width: 8),
                                    Text('Delete',
                                        style: TextStyle(color: Colors.red)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                WatchlistDetailScreen(watchlist: item),
                          ),
                        );
                        _loadWatchlists();
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateListDialog,
        icon: const Icon(Icons.add),
        label: const Text('New List'),
      ),
    );
  }
}
