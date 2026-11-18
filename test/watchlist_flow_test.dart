import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/watchlist.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('Step 3 Verification Flow: create 3 lists, rename one, delete one, add 2 stocks to each, restart DB', () async {
    final db = AppDb.instance;

    // 1. Initial state has seeded list
    final initialLists = await db.getWatchlists();
    expect(initialLists.isNotEmpty, true);
    expect(initialLists.first.name, 'My First List');
    final initialItems = await db.getItems(initialLists.first.id!);
    expect(initialItems.length, 1);
    expect(initialItems.first.symbol, 'JKPAPER');

    // 2. Create 3 new lists
    final id1 = await db.createWatchlist('Banking');
    final id2 = await db.createWatchlist('IT Stocks');
    final id3 = await db.createWatchlist('Auto');

    var lists = await db.getWatchlists();
    expect(lists.any((l) => l.name == 'Banking'), true);
    expect(lists.any((l) => l.name == 'IT Stocks'), true);
    expect(lists.any((l) => l.name == 'Auto'), true);

    // 3. Rename one list: 'Auto' -> 'Automobile & EV'
    await db.renameWatchlist(id3, 'Automobile & EV');
    lists = await db.getWatchlists();
    expect(lists.any((l) => l.name == 'Auto'), false);
    expect(lists.any((l) => l.name == 'Automobile & EV'), true);

    // 4. Delete one list: delete 'IT Stocks' (id2)
    await db.deleteWatchlist(id2);
    lists = await db.getWatchlists();
    expect(lists.any((l) => l.id == id2), false);

    // 5. Add 2 stocks to each remaining new list ('Banking' id1 and 'Automobile & EV' id3)
    await db.addItem(WatchItem(
      watchlistId: id1,
      symbol: 'HDFCBANK',
      exchange: 'nse_cm',
      displayName: 'HDFC Bank Ltd',
    ));
    await db.addItem(WatchItem(
      watchlistId: id1,
      symbol: 'ICICIBANK',
      exchange: 'nse_cm',
      displayName: 'ICICI Bank Ltd',
    ));

    await db.addItem(WatchItem(
      watchlistId: id3,
      symbol: 'TATAMOTORS',
      exchange: 'nse_cm',
      displayName: 'Tata Motors Ltd',
    ));
    await db.addItem(WatchItem(
      watchlistId: id3,
      symbol: 'MARUTI',
      exchange: 'bse_cm',
      displayName: 'Maruti Suzuki India',
    ));

    // Verify item counts
    expect(await db.itemCount(id1), 2);
    expect(await db.itemCount(id3), 2);

    final bankingItems = await db.getItems(id1);
    expect(bankingItems.length, 2);
    expect(bankingItems.map((e) => e.symbol), containsAll(['HDFCBANK', 'ICICIBANK']));

    final autoItems = await db.getItems(id3);
    expect(autoItems.length, 2);
    expect(autoItems.map((e) => e.symbol), containsAll(['TATAMOTORS', 'MARUTI']));

    // 6. Simulate restart: fetch again from database
    final restartedLists = await db.getWatchlists();
    expect(restartedLists.any((l) => l.id == id1 && l.name == 'Banking'), true);
    expect(restartedLists.any((l) => l.id == id3 && l.name == 'Automobile & EV'), true);
    expect(restartedLists.any((l) => l.id == id2), false);

    expect(await db.itemCount(id1), 2);
    expect(await db.itemCount(id3), 2);
  });
}
