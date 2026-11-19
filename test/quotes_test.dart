import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/watchlist.dart';
import 'package:hjdev_trading/screens/watchlists/watchlist_detail_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDb.dbName = 'quotes_test.db';
    await AppDb.resetDatabase();
    final dbPath = await getDatabasesPath();
    await databaseFactoryFfi.deleteDatabase(p.join(dbPath, AppDb.dbName));
  });

  group('KotakApi getQuote Tests', () {
    late KotakApi api;

    setUp(() {
      api = KotakApi.instance;
      api.logout();
      api.setSessionForTesting(
        accessToken: 'mock_access',
        sessionToken: 'mock_session',
        sessionSid: 'mock_sid',
        baseUrl: 'https://gw.kotaksecurities.com/trade/1.0',
      );
    });

    test('getQuote parses top-level list response and calculates changePct', () async {
      final mockClient = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'mock_access');
        expect(request.headers['neo-fin-key'], 'neotradeapi');
        expect(request.headers['Auth'], 'mock_session');
        expect(request.headers['sid'], 'mock_sid');

        // Verify URL encoding of exchange|symbol
        expect(request.url.path, contains('neosymbol/nse_cm%7CJKPAPER'));

        return http.Response(
          jsonEncode([
            {
              'ltp': '450.00',
              'open': '440.00',
              'high': '455.00',
              'low': '438.00',
              'prevClose': '400.00',
              'volume': '1500000',
            }
          ]),
          200,
        );
      });

      api.setMockClient(mockClient);

      final quote = await api.getQuote('JKPAPER', 'nse_cm');
      expect(quote.symbol, 'JKPAPER');
      expect(quote.exchange, 'nse_cm');
      expect(quote.ltp, 450.0);
      expect(quote.open, 440.0);
      expect(quote.high, 455.0);
      expect(quote.low, 438.0);
      expect(quote.prevClose, 400.0);
      expect(quote.volume, 1500000);
      // changePct = (450 - 400) / 400 * 100 = 12.5%
      expect(quote.changePct, 12.5);
    });

    test('getQuote parses object with data field and handles negative changePct', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': [
              {
                'ltp': 90.0,
                'open': 100.0,
                'high': 102.0,
                'low': 89.0,
                'prevClose': 100.0,
                'volume': 50000,
              }
            ]
          }),
          200,
        );
      });

      api.setMockClient(mockClient);

      final quote = await api.getQuote('TCS', 'nse_cm');
      expect(quote.ltp, 90.0);
      expect(quote.prevClose, 100.0);
      // changePct = (90 - 100) / 100 * 100 = -10.0%
      expect(quote.changePct, -10.0);
    });
  });

  group('WatchlistDetailScreen Refresh Quotes UI', () {
    late KotakApi api;
    late AppDb db;
    late Watchlist testList;

    setUp(() async {
      api = KotakApi.instance;
      api.logout();

      db = AppDb.instance;
      var lists = await db.getWatchlists();
      if (lists.isEmpty) {
        await db.createWatchlist('Test Quotes List');
        lists = await db.getWatchlists();
      }
      testList = lists.first;

      var items = await db.getItems(testList.id!);
      if (items.isEmpty) {
        await db.addItem(WatchItem(
          watchlistId: testList.id!,
          symbol: 'JKPAPER',
          exchange: 'nse_cm',
          displayName: 'JK Paper Ltd',
        ));
      }
    });

    testWidgets('Shows "Login first" snackbar when refresh tapped while logged out', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WatchlistDetailScreen(watchlist: testList),
        ),
      );
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      // Initially shows '—'
      expect(find.text('—'), findsWidgets);

      // Tap refresh
      await tester.tap(find.byTooltip('Refresh Quotes'));
      await tester.pump();

      // Expect snackbar "Login first"
      expect(find.text('Login first'), findsOneWidget);
    });

    testWidgets('Fetches quotes and displays LTP + change% when logged in', (tester) async {
      api.setSessionForTesting(
        accessToken: 'tok',
        sessionToken: 'sess',
        sessionSid: 'sid',
        baseUrl: 'https://gw.kotaksecurities.com/trade/1.0',
      );

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'ltp': 525.50,
              'prevClose': 500.00,
              'open': 510.0,
              'high': 530.0,
              'low': 505.0,
              'volume': 20000,
            }
          ]),
          200,
        );
      });

      api.setMockClient(mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: WatchlistDetailScreen(watchlist: testList),
        ),
      );
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      // Tap refresh
      await tester.tap(find.byTooltip('Refresh Quotes'));
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
      await tester.pump();

      // "—" replaced with live price
      expect(find.text('₹525.50'), findsWidgets);
      expect(find.text('+5.10%'), findsWidgets);
    });
  });
}
