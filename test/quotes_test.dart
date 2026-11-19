import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/watchlists_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final todayIst = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  final dateStr =
      '${todayIst.year}-${todayIst.month.toString().padLeft(2, '0')}-${todayIst.day.toString().padLeft(2, '0')}';

  FlutterSecureStorage.setMockInitialValues({
    'scrip_master_last_updated_date': dateStr,
  });

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDb.dbName = 'quotes_test.db';
    await AppDb.resetDatabase();
    final dbPath = await getDatabasesPath();
    await databaseFactoryFfi.deleteDatabase(p.join(dbPath, AppDb.dbName));
    await AppDb.instance.database;
  });

  group('Kotak Neo Official Quotes Format Tests', () {
    late KotakApi api;
    late AppDb db;

    setUp(() async {
      api = KotakApi.instance;
      api.logout();
      db = AppDb.instance;

      // Seed JKPAPER scrip for token lookup
      await db.replaceScripsAtomically([
        Scrip(
          token: '11915',
          symbol: 'JKPAPER',
          displayName: 'JK Paper Ltd',
          segment: 'nse_cm',
          exchange: 'NSE',
          instrumentType: 'EQ',
        ),
        Scrip(
          token: '1333',
          symbol: 'HDFCBANK',
          displayName: 'HDFC Bank Ltd',
          segment: 'nse_cm',
          exchange: 'NSE',
          instrumentType: 'EQ',
        ),
      ]);
    });

    test('Requirement 1 & 3: Single quote uses TOKEN number, /all suffix, and Authorization-only header', () async {
      api.setSessionForTesting(
        accessToken: 'test_consumer_access_token',
        // No session token/sid — quotes must succeed with only access token
      );

      final mockClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'test_consumer_access_token');
        expect(request.headers['neo-fin-key'], 'neotradeapi');

        // Path must use instrument token (11915), NOT symbol (JKPAPER), and end with /all
        expect(Uri.decodeComponent(request.url.path), '/trade/1.0/script-details/1.0/quotes/neosymbol/nse_cm|11915/all');
        expect(request.url.path.contains('JKPAPER'), false);

        return http.Response(
          jsonEncode([
            {
              'exchange_token': '11915',
              'ltp': '512.40',
              'ohlc': {
                'open': '505.00',
                'high': '515.20',
                'low': '503.10',
                'close': '500.00', // Previous close
              },
              'per_change': '2.48',
              'last_volume': '452100',
            }
          ]),
          200,
        );
      });

      api.setMockClient(mockClient);

      // Quote requested with token: '11915'
      final quote = await api.getQuote('JKPAPER', 'nse_cm', token: '11915');
      expect(quote.symbol, 'JKPAPER');
      expect(quote.token, '11915');
      expect(quote.ltp, 512.40);
      expect(quote.open, 505.00);
      expect(quote.high, 515.20);
      expect(quote.low, 503.10);
      expect(quote.prevClose, 500.00); // from ohlc.close
      expect(quote.change, closeTo(12.40, 0.01)); // 512.40 - 500.00
      expect(quote.changePct, 2.48); // from per_change directly
      expect(quote.volume, 452100); // from last_volume
    });

    test('Requirement 2: Batch quotes fetches whole watchlist in ONE call joined by commas', () async {
      api.setSessionForTesting(
        accessToken: 'access_key_123',
        baseUrl: 'https://gw.kotaksecurities.com/trade/1.0',
      );

      final items = [
        WatchItem(
          watchlistId: 1,
          symbol: 'HDFCBANK',
          exchange: 'nse_cm',
          token: '1333',
          displayName: 'HDFC Bank Ltd',
        ),
        WatchItem(
          watchlistId: 1,
          symbol: 'JKPAPER',
          exchange: 'nse_cm',
          token: '11915',
          displayName: 'JK Paper Ltd',
        ),
      ];

      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        expect(request.method, 'GET');
        // Joined with commas: nse_cm|1333,nse_cm|11915 and /all suffix
        expect(
          Uri.decodeFull(request.url.toString()),
          'https://gw.kotaksecurities.com/trade/1.0/script-details/1.0/quotes/neosymbol/nse_cm|1333,nse_cm|11915/all',
        );

        return http.Response(
          jsonEncode([
            {
              'exchange_token': '1333',
              'ltp': '1650.00',
              'ohlc': {'open': '1640.0', 'high': '1655.0', 'low': '1635.0', 'close': '1640.0'},
              'per_change': '0.61',
              'last_volume': '1200000',
            },
            {
              'exchange_token': '11915',
              'ltp': '512.40',
              'ohlc': {'open': '505.0', 'high': '515.2', 'low': '503.1', 'close': '500.0'},
              'per_change': '2.48',
              'last_volume': '452100',
            },
          ]),
          200,
        );
      });

      api.setMockClient(mockClient);

      final quotes = await api.getQuotesBatch(items);
      expect(callCount, 1); // Exact ONE network call for entire watchlist
      expect(quotes.length, greaterThanOrEqualTo(2));
      expect(quotes['1333']?.ltp, 1650.00);
      expect(quotes['11915']?.ltp, 512.40);
      expect(quotes['nse_cm|JKPAPER']?.changePct, 2.48);
    });

    test('Requirement 5: Old row with token=null looks up token from scrips table; missing token skips row and shows notice', () async {
      // 1. Symbol with existing scrip: should find token '11915'
      final foundToken = await db.findTokenBySymbolAndSegment('JKPAPER', 'nse_cm');
      expect(foundToken, '11915');

      // 2. Symbol not in scrip master: should return null
      final unknownToken = await db.findTokenBySymbolAndSegment('UNKNOWN_OLD_STOCK', 'nse_cm');
      expect(unknownToken, isNull);
    });
  });

  group('WatchlistsScreen UI with Batch Quotes and JKPAPER', () {
    late KotakApi api;
    late AppDb db;

    setUp(() async {
      api = KotakApi.instance;
      api.logout();
      db = AppDb.instance;

      api.setSessionForTesting(
        accessToken: 'valid_access_token',
        baseUrl: 'https://gw.kotaksecurities.com/trade/1.0',
      );

      // Seed JKPAPER and UNKNOWN stock in watchlist
      var lists = await db.getWatchlists();
      if (lists.isEmpty) {
        await db.createWatchlist('My Stocks');
        lists = await db.getWatchlists();
      }
      final list = lists.first;

      // Clean existing items
      final existing = await db.getItems(list.id!);
      for (final it in existing) {
        if (it.id != null) await db.removeItem(it.id!);
      }

      // Add JKPAPER with token '11915' (as added from search)
      await db.addItem(WatchItem(
        watchlistId: list.id!,
        symbol: 'JKPAPER',
        exchange: 'nse_cm',
        token: '11915',
        displayName: 'JK Paper Ltd',
      ));

      // Add legacy stock with token = null and not in scrips
      await db.addItem(WatchItem(
        watchlistId: list.id!,
        symbol: 'OBSOLETE',
        exchange: 'nse_cm',
        token: null,
        displayName: 'Obsolete Stock',
      ));
    });

    testWidgets('WatchlistsScreen shows JKPAPER live LTP + change% and shows missing token notice without failing', (tester) async {
      var requestedNeosymbols = '';
      final completer = Completer<void>();
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('11915')) {
          requestedNeosymbols = request.url.toString();
          if (!completer.isCompleted) {
            completer.complete();
          }
          return http.Response(
            jsonEncode([
              {
                'exchange_token': '11915',
                'ltp': '512.40',
                'ohlc': {'open': '505.0', 'high': '515.2', 'low': '503.1', 'close': '500.0'},
                'per_change': '2.48',
                'last_volume': '452100',
              }
            ]),
            200,
          );
        }
        if (request.url.path.contains('26000') || request.url.path.contains('1')) {
          return http.Response(
            jsonEncode([
              {
                'exchange_token': '26000',
                'ltp': '25200.00',
                'ohlc': {'close': '25150.00'},
                'per_change': '0.20',
              }
            ]),
            200,
          );
        }
        return http.Response('[]', 200);
      });

      api.setMockClient(mockClient);

      await tester.pumpWidget(const MaterialApp(home: WatchlistsScreen()));
      for (int i = 0; i < 30; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (requestedNeosymbols.isNotEmpty) break;
      }

      // Check request URL sent by batch quote: contains token 11915 and /all, does not contain OBSOLETE
      expect(Uri.decodeComponent(requestedNeosymbols), contains('nse_cm|11915/all'));
      expect(requestedNeosymbols.contains('OBSOLETE'), false);

      // JKPAPER shows live LTP (512.40) and change% (+2.48%) matching Kotak Neo
      expect(find.text('JKPAPER'), findsOneWidget);
      expect(find.text('512.40'), findsOneWidget);
      expect(find.text('+12.40 (+2.48%)'), findsOneWidget);

      // OBSOLETE shows "Token missing — re-add this stock from search"
      expect(find.text('OBSOLETE'), findsOneWidget);
      expect(find.text('Token missing — re-add this stock from search'), findsOneWidget);
    });
  });
}
