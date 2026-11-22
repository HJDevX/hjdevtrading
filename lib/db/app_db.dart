import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:hjdev_trading/models/paper.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// The app's local on-phone database (SQLite).
///
/// Tables:
///  - watchlists / watch_items : the user's watchlists (instruments come
///    ONLY from the downloaded scrip master — nothing is hardcoded)
///  - scrips                    : Kotak's full instrument list (Refresh)
///  - paper_orders              : practice orders placed from watchlist
///  - paper_positions           : practice holdings
///  - sim_orders / sim_positions: SIMULATOR trades (fake prices) — kept
///    fully separate from the real paper record
class AppDb {
  static final AppDb instance = AppDb._init();
  static Database? _database;

  AppDb._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('hjdev_trading.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await _createCoreTables(db);
    await _createScripsTable(db);
    await _createPaperTables(db);
    await _createSimTables(db);
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createScripsTable(db);
      // watch_items gained scrip columns in v2 — add any that are missing.
      for (final ddl in [
        "ALTER TABLE watch_items ADD COLUMN token TEXT",
        "ALTER TABLE watch_items ADD COLUMN instrument_type TEXT",
        "ALTER TABLE watch_items ADD COLUMN expiry TEXT",
        "ALTER TABLE watch_items ADD COLUMN strike REAL",
        "ALTER TABLE watch_items ADD COLUMN lot_size INTEGER",
      ]) {
        try {
          await db.execute(ddl);
        } catch (_) {
          // Column already exists — fine.
        }
      }
    }
    if (oldVersion < 3) {
      await _createPaperTables(db);
    }
    if (oldVersion < 4) {
      await _createSimTables(db);
    }
  }

  Future<void> _createCoreTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS watchlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS watch_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        watchlist_id INTEGER NOT NULL,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL DEFAULT 'nse_cm',
        token TEXT,
        display_name TEXT NOT NULL,
        instrument_type TEXT,
        expiry TEXT,
        strike REAL,
        lot_size INTEGER,
        FOREIGN KEY (watchlist_id) REFERENCES watchlists (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _createScripsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scrips (
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
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_scrips_symbol ON scrips(symbol)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_scrips_name ON scrips(display_name)');
  }

  Future<void> _createPaperTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS paper_orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL DEFAULT 'nse_cm',
        token TEXT,
        display_name TEXT,
        instrument_type TEXT,
        side TEXT NOT NULL,
        qty INTEGER NOT NULL,
        price REAL NOT NULL,
        realized_pnl REAL NOT NULL DEFAULT 0,
        time_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS paper_positions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL DEFAULT 'nse_cm',
        token TEXT,
        display_name TEXT,
        instrument_type TEXT,
        lot_size INTEGER,
        qty INTEGER NOT NULL,
        avg_price REAL NOT NULL
      )
    ''');
  }

  // ---------------- Watchlists ----------------

  Future<int> createWatchlist(Watchlist watchlist) async {
    final db = await instance.database;
    return await db.insert('watchlists', watchlist.toMap());
  }

  Future<List<Watchlist>> getWatchlists() async {
    final db = await instance.database;
    final result = await db.query('watchlists', orderBy: 'created_at ASC');
    return result.map((json) => Watchlist.fromMap(json)).toList();
  }

  Future<int> updateWatchlist(Watchlist watchlist) async {
    final db = await instance.database;
    return await db.update(
      'watchlists',
      watchlist.toMap(),
      where: 'id = ?',
      whereArgs: [watchlist.id],
    );
  }

  Future<int> deleteWatchlist(int id) async {
    final db = await instance.database;
    await db.delete('watch_items', where: 'watchlist_id = ?', whereArgs: [id]);
    return await db.delete('watchlists', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> addItem(WatchItem item) async {
    final db = await instance.database;
    return await db.insert('watch_items', item.toMap());
  }

  Future<List<WatchItem>> getItems(int watchlistId) async {
    final db = await instance.database;
    final result = await db.query(
      'watch_items',
      where: 'watchlist_id = ?',
      whereArgs: [watchlistId],
      orderBy: 'id ASC',
    );
    return result.map((json) => WatchItem.fromMap(json)).toList();
  }

  Future<int> deleteItem(int id) async {
    final db = await instance.database;
    return await db.delete('watch_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<bool> isItemInWatchlist(int watchlistId, String symbol) async {
    final db = await instance.database;
    final result = await db.query(
      'watch_items',
      where: 'watchlist_id = ? AND symbol = ?',
      whereArgs: [watchlistId, symbol],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<bool> isScripInWatchlist(int watchlistId, Scrip scrip) async {
    final db = await instance.database;
    final result = await db.query(
      'watch_items',
      where: 'watchlist_id = ? AND symbol = ? AND exchange = ?',
      whereArgs: [watchlistId, scrip.symbol, scrip.segment],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  /// All watch items of one segment+token across every watchlist — used
  /// to fill in a missing token for items saved by older app versions.
  Future<List<WatchItem>> getItemsBySegmentAndToken(
      String segment, String token) async {
    final db = await instance.database;
    final result = await db.query(
      'watch_items',
      where: 'exchange = ? AND token = ?',
      whereArgs: [segment, token],
    );
    return result.map((json) => WatchItem.fromMap(json)).toList();
  }

  // ---------------- Scrips (instrument master) ----------------

  Future<void> replaceAllScrips(List<Map<String, dynamic>> scripsData) async {
    final db = await instance.database;
    final batch = db.batch();
    batch.delete('scrips');
    for (final map in scripsData) {
      batch.insert('scrips', map);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Scrip>> searchScrips(String query, {int limit = 30}) async {
    final db = await instance.database;
    final q = '%${query.toUpperCase()}%';
    final result = await db.query(
      'scrips',
      where:
          'UPPER(symbol) LIKE ? OR UPPER(display_name) LIKE ? OR UPPER(underlying) LIKE ?',
      whereArgs: [q, q, q],
      orderBy: 'symbol ASC',
      limit: limit,
    );
    return result.map((json) => Scrip.fromMap(json)).toList();
  }

  Future<int> getScripsCount() async {
    final db = await instance.database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as count FROM scrips');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<Map<String, int>> getScripsCountBySegment() async {
    final db = await instance.database;
    final result = await db.rawQuery(
        'SELECT segment, COUNT(*) as count FROM scrips GROUP BY segment');
    final map = <String, int>{};
    for (final row in result) {
      map[row['segment'].toString()] = (row['count'] as num).toInt();
    }
    return map;
  }

  Future<Scrip?> getScripBySymbolAndSegment(
      String symbol, String segment) async {
    final db = await instance.database;
    final result = await db.query(
      'scrips',
      where: 'symbol = ? AND segment = ?',
      whereArgs: [symbol, segment],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Scrip.fromMap(result.first);
  }

  Future<Scrip?> getScripByTokenAndSegment(String token, String segment) async {
    final db = await instance.database;
    final result = await db.query(
      'scrips',
      where: 'token = ? AND segment = ?',
      whereArgs: [token, segment],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Scrip.fromMap(result.first);
  }

  // ---------------- Paper trading ----------------

  Future<int> insertPaperOrder(PaperOrder order) async {
    final db = await instance.database;
    return await db.insert('paper_orders', order.toMap());
  }

  Future<List<PaperOrder>> getPaperOrders() async {
    final db = await instance.database;
    final result =
        await db.query('paper_orders', orderBy: 'time_ms DESC, id DESC');
    return result.map((json) => PaperOrder.fromMap(json)).toList();
  }

  Future<List<PaperPosition>> getPaperPositions() async {
    final db = await instance.database;
    final result = await db.query('paper_positions', orderBy: 'symbol ASC');
    return result.map((json) => PaperPosition.fromMap(json)).toList();
  }

  Future<PaperPosition?> getPaperPosition(
      String symbol, String exchange, String? token) async {
    final db = await instance.database;
    final result = await db.query(
      'paper_positions',
      where: token != null
          ? 'symbol = ? AND exchange = ? AND token = ?'
          : 'symbol = ? AND exchange = ?',
      whereArgs:
          token != null ? [symbol, exchange, token] : [symbol, exchange],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return PaperPosition.fromMap(result.first);
  }

  Future<int> upsertPaperPosition(PaperPosition position) async {
    final db = await instance.database;
    if (position.id == null) {
      return await db.insert('paper_positions', position.toMap());
    }
    return await db.update(
      'paper_positions',
      position.toMap(),
      where: 'id = ?',
      whereArgs: [position.id],
    );
  }

  Future<int> deletePaperPosition(int id) async {
    final db = await instance.database;
    return await db
        .delete('paper_positions', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- Simulator trading ----------------
  // Same shapes as the paper tables (PaperOrder / PaperPosition are
  // reused as the row models), different tables — sim trades can
  // never mix into the real paper record.

  Future<void> _createSimTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sim_orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL DEFAULT 'nse_cm',
        token TEXT,
        display_name TEXT,
        instrument_type TEXT,
        side TEXT NOT NULL,
        qty INTEGER NOT NULL,
        price REAL NOT NULL,
        realized_pnl REAL NOT NULL DEFAULT 0,
        time_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sim_positions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        symbol TEXT NOT NULL,
        exchange TEXT NOT NULL DEFAULT 'nse_cm',
        token TEXT,
        display_name TEXT,
        instrument_type TEXT,
        lot_size INTEGER,
        qty INTEGER NOT NULL,
        avg_price REAL NOT NULL
      )
    ''');
  }

  Future<int> insertSimOrder(PaperOrder order) async {
    final db = await instance.database;
    return await db.insert('sim_orders', order.toMap());
  }

  Future<List<PaperOrder>> getSimOrders() async {
    final db = await instance.database;
    final result =
        await db.query('sim_orders', orderBy: 'time_ms DESC, id DESC');
    return result.map((json) => PaperOrder.fromMap(json)).toList();
  }

  Future<List<PaperPosition>> getSimPositions() async {
    final db = await instance.database;
    final result = await db.query('sim_positions', orderBy: 'symbol ASC');
    return result.map((json) => PaperPosition.fromMap(json)).toList();
  }

  Future<PaperPosition?> getSimPosition(
      String symbol, String exchange, String? token) async {
    final db = await instance.database;
    final result = await db.query(
      'sim_positions',
      where: token != null
          ? 'symbol = ? AND exchange = ? AND token = ?'
          : 'symbol = ? AND exchange = ?',
      whereArgs:
          token != null ? [symbol, exchange, token] : [symbol, exchange],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return PaperPosition.fromMap(result.first);
  }

  Future<int> upsertSimPosition(PaperPosition position) async {
    final db = await instance.database;
    if (position.id == null) {
      return await db.insert('sim_positions', position.toMap());
    }
    return await db.update(
      'sim_positions',
      position.toMap(),
      where: 'id = ?',
      whereArgs: [position.id],
    );
  }

  Future<int> deleteSimPosition(int id) async {
    final db = await instance.database;
    return await db.delete('sim_positions', where: 'id = ?', whereArgs: [id]);
  }

  /// Wipe every simulator order and position (the Simulator's Reset).
  Future<void> clearSimData() async {
    final db = await instance.database;
    await db.delete('sim_orders');
    await db.delete('sim_positions');
  }
}
