import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:hjdev_trading/models/watchlist.dart';

class AppDb {
  static final AppDb instance = AppDb._();
  AppDb._();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'hjdev_trading.db');

    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE watchlists(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL
          );
        ''');

        await db.execute('''
          CREATE TABLE watch_items(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            watchlist_id INTEGER NOT NULL,
            symbol TEXT NOT NULL,
            exchange TEXT NOT NULL DEFAULT 'nse_cm',
            token TEXT,
            display_name TEXT NOT NULL
          );
        ''');

        await _seedDefaultIfEmpty(db);
      },
      onOpen: (db) async {
        await _seedDefaultIfEmpty(db);
      },
    );

    return db;
  }

  /// On first launch, if watchlists is empty, insert "My First List" with JKPAPER.
  Future<void> _seedDefaultIfEmpty(DatabaseExecutor db) async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM watchlists'),
    ) ?? 0;

    if (count == 0) {
      final listId = await db.insert('watchlists', {
        'name': 'My First List',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      await db.insert('watch_items', {
        'watchlist_id': listId,
        'symbol': 'JKPAPER',
        'exchange': 'nse_cm',
        'token': null,
        'display_name': 'JK Paper Ltd',
      });
    }
  }

  /// Get all watchlists ordered by creation date
  Future<List<Watchlist>> getWatchlists() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'watchlists',
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Watchlist.fromMap(m)).toList();
  }

  /// Create a new watchlist by name
  Future<int> createWatchlist(String name) async {
    final db = await database;
    return await db.insert('watchlists', {
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Rename an existing watchlist
  Future<int> renameWatchlist(int id, String newName) async {
    final db = await database;
    return await db.update(
      'watchlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete a watchlist and all of its items
  Future<void> deleteWatchlist(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'watch_items',
        where: 'watchlist_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'watchlists',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Get all items for a given watchlist
  Future<List<WatchItem>> getItems(int watchlistId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'watch_items',
      where: 'watchlist_id = ?',
      whereArgs: [watchlistId],
      orderBy: 'id ASC',
    );
    return maps.map((m) => WatchItem.fromMap(m)).toList();
  }

  /// Add an item to a watchlist (accepts WatchItem or individual fields)
  Future<int> addItem(WatchItem item) async {
    final db = await database;
    return await db.insert('watch_items', item.toMap());
  }

  /// Remove an item by its id
  Future<int> removeItem(int itemId) async {
    final db = await database;
    return await db.delete(
      'watch_items',
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  /// Count the number of items in a watchlist
  Future<int> itemCount(int watchlistId) async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM watch_items WHERE watchlist_id = ?',
        [watchlistId],
      ),
    );
    return count ?? 0;
  }
}
