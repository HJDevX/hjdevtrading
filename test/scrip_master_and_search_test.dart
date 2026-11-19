import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/services/scrip_master_service.dart';

void main() {
  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDb.dbName = 'scrip_master_test.db';
    await AppDb.resetDatabase();
    final dbPath = await getDatabasesPath();
    await databaseFactoryFfi.deleteDatabase(p.join(dbPath, AppDb.dbName));
  });

  group('Step 8 — Scrip Master Download + Universal Search Requirements', () {
    late AppDb db;
    late Watchlist testList;
    late ScripMasterService service;

    setUp(() async {
      db = AppDb.instance;
      service = ScripMasterService.instance;
      var lists = await db.getWatchlists();
      if (lists.isEmpty) {
        await db.createWatchlist('Comprehensive Test Watchlist');
        lists = await db.getWatchlists();
      }
      testList = lists.first;
    });

    test('Requirement 3 & 4: Download all 4 segments and parse in background isolate', () async {
      // Mock official Kotak Scrip Master CSV responses
      service.setMockClient(MockClient((request) async {
        final path = request.url.path;
        if (path.contains('nse_cm')) {
          return http.Response(
            'pSymbol,pTrdSymbol,pSymbolName,pDesc,pInstName,pOptionType,dStrikePrice,lExpiryDate,lLotSize,dTickSize\n'
            '2885,RELIANCE,RELIANCE,Reliance Industries Ltd,EQ,,0,,1,0.05\n'
            '11915,JKPAPER,JKPAPER,JK Paper Ltd,EQ,,0,,1,0.05\n',
            200,
          );
        } else if (path.contains('bse_cm')) {
          return http.Response(
            'pSymbol,pTrdSymbol,pSymbolName,pDesc,pInstName,pOptionType,dStrikePrice,lExpiryDate,lLotSize,dTickSize\n'
            '500228,JKPAPER,JKPAPER,JK Paper Ltd,EQ,,0,,1,0.05\n',
            200,
          );
        } else if (path.contains('nse_fo')) {
          return http.Response(
            'pSymbol,pTrdSymbol,pSymbolName,pDesc,pInstName,pOptionType,dStrikePrice,lExpiryDate,lLotSize,dTickSize\n'
            '45001,NIFTY24NOVFUT,NIFTY,NIFTY Future 28 Nov,FUT,,0,28 Nov 2026,25,0.05\n'
            '45002,NIFTY24NOV26000CE,NIFTY,NIFTY 26000 CE,OPT,CE,26000.0,28 Nov 2026,25,0.05\n'
            '45003,NIFTY24NOV26000PE,NIFTY,NIFTY 26000 PE,OPT,PE,26000.0,28 Nov 2026,25,0.05\n'
            '53001,BANKNIFTY24NOVFUT,BANKNIFTY,Bank Nifty Future 28 Nov,FUT,,0,28 Nov 2026,15,0.05\n'
            '53002,BANKNIFTY24NOV52000CE,BANKNIFTY,Bank Nifty 52000 CE,OPT,CE,52000.0,28 Nov 2026,15,0.05\n',
            200,
          );
        } else if (path.contains('mcx_fo')) {
          return http.Response(
            'pSymbol,pTrdSymbol,pSymbolName,pDesc,pInstName,pOptionType,dStrikePrice,lExpiryDate,lLotSize,dTickSize\n'
            '71001,GOLD24DECFUT,GOLD,Gold Future 05 Dec,FUT,,0,05 Dec 2026,1,1.0\n'
            '71002,GOLDM24NOVFUT,GOLDM,Gold Mini Future 29 Nov,FUT,,0,29 Nov 2026,1,1.0\n',
            200,
          );
        }
        return http.Response('Not Found', 404);
      }));

      final progressMessages = <String>[];
      final syncResult = await service.syncScripMaster(
        force: true,
        onProgress: (msg) => progressMessages.add(msg),
      );

      expect(syncResult.success, true);
      expect(progressMessages.isNotEmpty, true);
      expect(syncResult.stocksCount, 3);
      expect(syncResult.futuresCount, 2);
      expect(syncResult.optionsCount, 3);
      expect(syncResult.commodityCount, 2);
      expect(syncResult.message.contains('Stocks: 3'), true);
      expect(syncResult.message.contains('Futures: 2'), true);
      expect(syncResult.message.contains('Options: 3'), true);
      expect(syncResult.message.contains('Commodity: 2'), true);
    });

    test('Requirement 8 & 9: Searching "NIFTY" suggests futures and options with strikes + expiries', () async {
      final results = await db.searchScrips('NIFTY');
      expect(results.isNotEmpty, true);

      // Futures suggestion
      final futures = results.where((s) => s.instrumentType == 'FUT').toList();
      expect(futures.isNotEmpty, true);
      final fut = futures.first;
      expect(fut.symbol, 'NIFTY24NOVFUT');
      expect(fut.expiry, '28 Nov 2026');
      expect(fut.lotSize, 25);

      // Options suggestions with strike and expiry
      final ceOption = results.firstWhere((s) => s.instrumentType == 'CE');
      expect(ceOption.strike, 26000.0);
      expect(ceOption.expiry, '28 Nov 2026');
      expect(ceOption.lotSize, 25);

      final peOption = results.firstWhere((s) => s.instrumentType == 'PE');
      expect(peOption.strike, 26000.0);
      expect(peOption.expiry, '28 Nov 2026');
    });

    test('Requirement 8 & 9: Searching "GOLD" suggests MCX rows', () async {
      final results = await db.searchScrips('GOLD');
      expect(results.isNotEmpty, true);
      expect(results.every((s) => s.segment == 'mcx_fo' && s.exchange == 'MCX'), true);

      final gold = results.firstWhere((s) => s.symbol == 'GOLD24DECFUT');
      expect(gold.expiry, '05 Dec 2026');
      expect(gold.lotSize, 1);
    });

    test('Requirement 8 & 9: Searching "JK" suggests JK Paper (NSE & BSE)', () async {
      final results = await db.searchScrips('JK');
      expect(results.isNotEmpty, true);
      expect(results.any((s) => s.symbol == 'JKPAPER' && s.exchange == 'NSE'), true);
      expect(results.any((s) => s.symbol == 'JKPAPER' && s.exchange == 'BSE'), true);
      expect(results.every((s) => s.instrumentType == 'EQ'), true);
    });

    test('Requirement 10: Adding instrument to watchlist saves all columns and prevents duplicates', () async {
      final scrips = await db.searchScrips('NIFTY24NOV26000CE');
      expect(scrips.isNotEmpty, true);
      final scrip = scrips.first;

      // Add to watchlist
      final itemId = await db.addItem(WatchItem(
        watchlistId: testList.id!,
        symbol: scrip.symbol,
        exchange: scrip.segment,
        token: scrip.token,
        displayName: scrip.displayName,
        instrumentType: scrip.instrumentType,
        expiry: scrip.expiry,
        strike: scrip.strike,
        lotSize: scrip.lotSize,
      ));
      expect(itemId > 0, true);

      // Verify all columns were persisted in watch_items
      final items = await db.getItems(testList.id!);
      final added = items.firstWhere((i) => i.symbol == scrip.symbol);
      expect(added.token, scrip.token);
      expect(added.instrumentType, 'CE');
      expect(added.strike, 26000.0);
      expect(added.expiry, '28 Nov 2026');
      expect(added.lotSize, 25);

      // Duplicate prevention
      final isDup = await db.isItemInWatchlist(
        testList.id!,
        scrip.symbol,
        scrip.segment,
        token: scrip.token,
      );
      expect(isDup, true);
    });

    test('Requirement 5: Refresh failure keeps existing database unchanged', () async {
      final initialScripsCount = await db.scripsCount();
      expect(initialScripsCount > 0, true);

      // Failing client
      service.setMockClient(MockClient((request) async {
        return http.Response('Network Timeout', 504);
      }));

      final failResult = await service.syncScripMaster(force: true);
      expect(failResult.success, false);
      expect(failResult.message.contains('failed') || failResult.message.contains('unchanged'), true);

      // Verify scrips table is completely intact
      final afterScripsCount = await db.scripsCount();
      expect(afterScripsCount, initialScripsCount);
    });

    test('Requirement 6: Auto-refresh morning checks sync date', () async {
      // With today already recorded, checkAndAutoRefreshMorning returns null
      final autoResult = await service.checkAndAutoRefreshMorning();
      expect(autoResult, isNull);
    });
  });
}
