import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';

class AppDb {
  static final AppDb instance = AppDb._();
  AppDb._();

  static Database? _database;
  static String dbName = 'hjdev_trading.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  /// Closes database and resets instance (useful in tests)
  static Future<void> resetDatabase() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, dbName);

    final db = await openDatabase(
      path,
      version: 2,
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
            display_name TEXT NOT NULL,
            instrument_type TEXT,
            expiry TEXT,
            strike REAL,
            lot_size INTEGER
          );
        ''');

        await db.execute('''
          CREATE TABLE scrips(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT NOT NULL,
            symbol TEXT NOT NULL,
            display_name TEXT NOT NULL,
            segment TEXT NOT NULL,
            exchange TEXT NOT NULL,
            instrument_type TEXT NOT NULL,
            underlying TEXT,
            expiry TEXT,
            strike REAL,
            lot_size INTEGER,
            tick_size REAL
          );
        ''');

        await db.execute('CREATE INDEX idx_scrips_symbol ON scrips(symbol);');
        await db.execute('CREATE INDEX idx_scrips_display_name ON scrips(display_name);');
        await db.execute('CREATE INDEX idx_scrips_underlying ON scrips(underlying);');

        await _seedDefaultIfEmpty(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Non-destructive ALTER TABLE upgrade
          await db.execute('ALTER TABLE watch_items ADD COLUMN instrument_type TEXT;');
          await db.execute('ALTER TABLE watch_items ADD COLUMN expiry TEXT;');
          await db.execute('ALTER TABLE watch_items ADD COLUMN strike REAL;');
          await db.execute('ALTER TABLE watch_items ADD COLUMN lot_size INTEGER;');

          await db.execute('''
            CREATE TABLE IF NOT EXISTS scrips(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              token TEXT NOT NULL,
              symbol TEXT NOT NULL,
              display_name TEXT NOT NULL,
              segment TEXT NOT NULL,
              exchange TEXT NOT NULL,
              instrument_type TEXT NOT NULL,
              underlying TEXT,
              expiry TEXT,
              strike REAL,
              lot_size INTEGER,
              tick_size REAL
            );
          ''');

          await db.execute('CREATE INDEX IF NOT EXISTS idx_scrips_symbol ON scrips(symbol);');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_scrips_display_name ON scrips(display_name);');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_scrips_underlying ON scrips(underlying);');
        }
      },
      onOpen: (db) async {
        await _seedDefaultIfEmpty(db);
      },
    );

    return db;
  }

  /// On first launch, if watchlists is empty, insert empty default watchlist
  Future<void> _seedDefaultIfEmpty(DatabaseExecutor db) async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM watchlists'),
    ) ?? 0;

    if (count == 0) {
      await db.insert('watchlists', {
        'name': 'Watchlist 1',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  // --- Watchlist Functions ---

  Future<List<Watchlist>> getWatchlists() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'watchlists',
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Watchlist.fromMap(m)).toList();
  }

  Future<int> createWatchlist(String name) async {
    final db = await database;
    return await db.insert('watchlists', {
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> renameWatchlist(int id, String newName) async {
    final db = await database;
    return await db.update(
      'watchlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

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

  Future<int> addItem(WatchItem item) async {
    final db = await database;
    return await db.insert('watch_items', item.toMap());
  }

  Future<int> removeItem(int itemId) async {
    final db = await database;
    return await db.delete(
      'watch_items',
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

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

  /// Looks up token from scrips table by symbol and segment (for legacy rows)
  Future<String?> findTokenBySymbolAndSegment(String symbol, String segment) async {
    final db = await database;
    String cleanSegment = segment.toLowerCase().trim();
    if (cleanSegment == 'nse') cleanSegment = 'nse_cm';
    if (cleanSegment == 'bse') cleanSegment = 'bse_cm';
    if (cleanSegment == 'nfo') cleanSegment = 'nse_fo';
    if (cleanSegment == 'mcx') cleanSegment = 'mcx_fo';

    final results = await db.query(
      'scrips',
      columns: ['token'],
      where: 'symbol = ? AND (segment = ? OR exchange = ?)',
      whereArgs: [symbol.toUpperCase(), cleanSegment, cleanSegment],
      limit: 1,
    );
    if (results.isNotEmpty) {
      return results.first['token'] as String?;
    }

    // Fallback: search just by symbol if segment didn't match
    final fallback = await db.query(
      'scrips',
      columns: ['token'],
      where: 'symbol = ?',
      whereArgs: [symbol.toUpperCase()],
      limit: 1,
    );
    if (fallback.isNotEmpty) {
      return fallback.first['token'] as String?;
    }
    return null;
  }

  /// Updates token on a watchlist item
  Future<void> updateItemToken(int itemId, String token) async {
    final db = await database;
    await db.update(
      'watch_items',
      {'token': token},
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  // --- Scrips Search & Master Storage ---

  /// Search scrips with text query and optional category filter
  Future<List<Scrip>> searchScrips(
    String query, {
    String? categoryFilter, // All, Stocks, Futures, Options, Commodity
    int limit = 30,
  }) async {
    final db = await database;
    final cleanQuery = query.trim().toUpperCase();
    if (cleanQuery.length < 2) return [];

    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    // Text search: matches symbol, display_name or underlying
    whereClauses.add('(symbol LIKE ? OR display_name LIKE ? OR underlying LIKE ?)');
    whereArgs.add('%$cleanQuery%');
    whereArgs.add('%$cleanQuery%');
    whereArgs.add('%$cleanQuery%');

    // Category Filter
    if (categoryFilter != null && categoryFilter != 'All') {
      switch (categoryFilter) {
        case 'Stocks':
          whereClauses.add("instrument_type = 'EQ'");
          break;
        case 'Futures':
          whereClauses.add("instrument_type = 'FUT' AND segment != 'mcx_fo'");
          break;
        case 'Options':
          whereClauses.add("(instrument_type = 'CE' OR instrument_type = 'PE')");
          break;
        case 'Commodity':
          whereClauses.add("segment = 'mcx_fo'");
          break;
      }
    }

    final whereString = whereClauses.join(' AND ');
    final safeQuery = cleanQuery.replaceAll("'", "''");

    // Order results: exact match first, then starts with, then by symbol length
    final results = await db.query(
      'scrips',
      where: whereString,
      whereArgs: whereArgs,
      orderBy: '''
        CASE 
          WHEN UPPER(symbol) = '$safeQuery' THEN 1
          WHEN UPPER(symbol) LIKE '$safeQuery%' THEN 2
          WHEN UPPER(display_name) LIKE '$safeQuery%' THEN 3
          WHEN UPPER(underlying) LIKE '$safeQuery%' THEN 4
          ELSE 5 
        END,
        instrument_type ASC,
        LENGTH(symbol) ASC
      ''',
      limit: limit,
    );

    return results.map((m) => Scrip.fromMap(m)).toList();
  }

  /// Replaces the old scrips table with newly downloaded scrips atomically in a transaction.
  /// Existing watchlists and watch_items are NEVER touched.
  Future<void> replaceScripsAtomically(List<Scrip> scrips) async {
    if (scrips.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('scrips');
      final batch = txn.batch();
      for (final s in scrips) {
        batch.insert('scrips', s.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  /// Insert batch of scrips in a transaction
  Future<void> insertScripsBatch(List<Scrip> scrips) async {
    if (scrips.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final s in scrips) {
        batch.insert(
          'scrips',
          s.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Checks if an instrument already exists in the given watchlist
  Future<bool> isItemInWatchlist(
    int watchlistId,
    String symbol,
    String exchange, {
    String? token,
  }) async {
    final db = await database;
    List<Map<String, dynamic>> results;
    if (token != null && token.isNotEmpty) {
      results = await db.query(
        'watch_items',
        where: 'watchlist_id = ? AND (token = ? OR (symbol = ? AND exchange = ?))',
        whereArgs: [watchlistId, token, symbol, exchange],
        limit: 1,
      );
    } else {
      results = await db.query(
        'watch_items',
        where: 'watchlist_id = ? AND symbol = ? AND exchange = ?',
        whereArgs: [watchlistId, symbol, exchange],
        limit: 1,
      );
    }
    return results.isNotEmpty;
  }

  /// Total count of scrips in database
  Future<int> scripsCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM scrips'),
        ) ??
        0;
  }
}
