import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/screens/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final todayIst = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  final todayStr =
      '${todayIst.year}-${todayIst.month.toString().padLeft(2, '0')}-${todayIst.day.toString().padLeft(2, '0')}';
  final yesterdayIst = todayIst.subtract(const Duration(days: 1));
  final yesterdayStr =
      '${yesterdayIst.year}-${yesterdayIst.month.toString().padLeft(2, '0')}-${yesterdayIst.day.toString().padLeft(2, '0')}';

  group('KotakApi "Keep me logged in for today" Unit Tests', () {
    late KotakApi api;

    setUp(() {
      api = KotakApi.instance;
      api.logout();
      KotakApi.sessionExpiredNotifier.value = null;
    });

    test('getTodayIstDate returns format yyyy-mm-dd in UTC+5:30', () {
      final date = KotakApi.getTodayIstDate();
      expect(date, matches(r'^\d{4}-\d{2}-\d{2}$'));
      expect(date, todayStr);
    });

    test('Step B (tradeApiValidate) saves session in secure storage with today IST date and NEVER saves totp or mpin', () async {
      final storageMap = <String, String>{};
      FlutterSecureStorage.setMockInitialValues(storageMap);

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/tradeApiLogin')) {
          return http.Response(
            jsonEncode({
              'data': {'token': 'view_tok_123', 'sid': 'view_sid_123'}
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/tradeApiValidate')) {
          return http.Response(
            jsonEncode({
              'data': {
                'token': 'session_token_xyz',
                'sid': 'session_sid_456',
                'baseUrl': 'https://gw.kotaksecurities.com/trade/1.0',
                'greetingName': 'Trader John',
              }
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      api.setMockClient(mockClient);

      await api.tradeApiLogin(
        accessToken: 'access_123',
        mobileNumber: '+919876543210',
        ucc: 'UCC_JOHN',
        totp: '123456',
      );

      await api.tradeApiValidate(mpin: '654321');

      // Check in-memory state
      expect(api.isLoggedIn, true);
      expect(api.sessionToken, 'session_token_xyz');
      expect(api.sessionSid, 'session_sid_456');
      expect(api.baseUrl, 'https://gw.kotaksecurities.com/trade/1.0');
      expect(api.greetingName, 'Trader John');
      expect(api.loginDate, todayStr);

      // Verify flutter_secure_storage values
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'kotak_session_token'), 'session_token_xyz');
      expect(await storage.read(key: 'kotak_session_sid'), 'session_sid_456');
      expect(await storage.read(key: 'kotak_session_base_url'), 'https://gw.kotaksecurities.com/trade/1.0');
      expect(await storage.read(key: 'kotak_greeting_name'), 'Trader John');
      expect(await storage.read(key: 'kotak_login_date'), todayStr);

      // CRITICAL SECURITY REQUIREMENT: Verify TOTP and MPIN are NEVER stored
      expect(await storage.read(key: 'totp'), isNull);
      expect(await storage.read(key: 'kotak_totp'), isNull);
      expect(await storage.read(key: 'mpin'), isNull);
      expect(await storage.read(key: 'kotak_mpin'), isNull);
    });

    test('restoreSessionIfValid restores session when loginDate equals today IST', () async {
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'saved_token_777',
        'kotak_session_sid': 'saved_sid_888',
        'kotak_session_base_url': 'https://saved.kotak.com',
        'kotak_greeting_name': 'Alice',
        'kotak_login_date': todayStr,
      });

      api.logout();
      expect(api.isLoggedIn, false);

      final restored = await api.restoreSessionIfValid();
      expect(restored, true);
      expect(api.isLoggedIn, true);
      expect(api.sessionToken, 'saved_token_777');
      expect(api.sessionSid, 'saved_sid_888');
      expect(api.baseUrl, 'https://saved.kotak.com');
      expect(api.greetingName, 'Alice');
      expect(api.loginDate, todayStr);
    });

    test('restoreSessionIfValid deletes saved session and returns false if loginDate is yesterday', () async {
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'expired_token',
        'kotak_session_sid': 'expired_sid',
        'kotak_session_base_url': 'https://saved.kotak.com',
        'kotak_greeting_name': 'Alice',
        'kotak_login_date': yesterdayStr,
      });

      api.logout();
      final restored = await api.restoreSessionIfValid();
      expect(restored, false);
      expect(api.isLoggedIn, false);
      expect(api.sessionToken, isNull);

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'kotak_session_token'), isNull);
      expect(await storage.read(key: 'kotak_login_date'), isNull);
    });

    test('deleteSavedSession clears storage and in-memory credentials', () async {
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'token_to_delete',
        'kotak_session_sid': 'sid_to_delete',
        'kotak_session_base_url': 'https://base.kotak.com',
        'kotak_greeting_name': 'Bob',
        'kotak_login_date': todayStr,
      });

      api.setSessionForTesting(
        sessionToken: 'token_to_delete',
        sessionSid: 'sid_to_delete',
        baseUrl: 'https://base.kotak.com',
        greetingName: 'Bob',
        loginDate: todayStr,
      );
      expect(api.isLoggedIn, true);

      await api.deleteSavedSession();
      expect(api.isLoggedIn, false);
      expect(api.sessionToken, isNull);

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'kotak_session_token'), isNull);
      expect(await storage.read(key: 'kotak_session_sid'), isNull);
      expect(await storage.read(key: 'kotak_login_date'), isNull);
    });

    test('HTTP 403 deletes saved session and notifies sessionExpiredNotifier', () async {
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'live_token',
        'kotak_session_sid': 'live_sid',
        'kotak_session_base_url': 'https://gw.kotaksecurities.com',
        'kotak_login_date': todayStr,
      });

      api.setSessionForTesting(
        accessToken: 'bearer_token',
        sessionToken: 'live_token',
        sessionSid: 'live_sid',
        baseUrl: 'https://gw.kotaksecurities.com',
        loginDate: todayStr,
      );

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Access forbidden'}),
          403,
        );
      });
      api.setMockClient(mockClient);

      expect(
        () => api.getQuote('RELIANCE', 'NSE', token: '2885'),
        throwsA(isA<KotakApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );

      // Wait a moment for async deleteSavedSession
      await Future.delayed(const Duration(milliseconds: 50));

      expect(api.isLoggedIn, false);
      expect(KotakApi.sessionExpiredNotifier.value, 'Session expired — please login again');

      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'kotak_session_token'), isNull);
    });

    test('Error message containing "session" deletes saved session and triggers notification', () async {
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'live_token_2',
        'kotak_session_sid': 'live_sid_2',
        'kotak_session_base_url': 'https://gw.kotaksecurities.com',
        'kotak_login_date': todayStr,
      });

      api.setSessionForTesting(
        accessToken: 'bearer_token',
        sessionToken: 'live_token_2',
        sessionSid: 'live_sid_2',
        baseUrl: 'https://gw.kotaksecurities.com',
        loginDate: todayStr,
      );

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'message': 'Invalid session or session expired'}),
          401,
        );
      });
      api.setMockClient(mockClient);

      expect(
        () => api.getQuote('TCS', 'NSE', token: '11536'),
        throwsA(isA<KotakApiException>()),
      );

      await Future.delayed(const Duration(milliseconds: 50));

      expect(api.isLoggedIn, false);
      expect(KotakApi.sessionExpiredNotifier.value, 'Session expired — please login again');
    });
  });

  group('HomeScreen & Watchlists UI Session Behavior Tests', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      AppDb.dbName = 'session_persistence_test.db';
      await AppDb.resetDatabase();
      final dbPath = await getDatabasesPath();
      await databaseFactoryFfi.deleteDatabase(p.join(dbPath, AppDb.dbName));
      await AppDb.instance.database;
    });

    testWidgets('Valid session for today lands directly on Watchlist without showing Kotak Login', (tester) async {
      KotakApi.sessionExpiredNotifier.value = null;
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'valid_token',
        'kotak_session_sid': 'valid_sid',
        'kotak_session_base_url': 'https://gw.kotaksecurities.com',
        'kotak_login_date': todayStr,
        'scrip_master_last_updated_date': todayStr,
      });

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Should show indices header (NIFTY / SENSEX) and Watchlists
      expect(find.text('NIFTY'), findsOneWidget);
      expect(find.text('SENSEX'), findsOneWidget);
      // Login screen should NOT be visible
      expect(find.text('Step 1 — Verify TOTP'), findsNothing);
      expect(find.text('Step 1: Neo Trade API Credentials'), findsNothing);
    });

    testWidgets('Tapping Logout button on Kotak Login screen clears session and returns to login credentials', (tester) async {
      KotakApi.sessionExpiredNotifier.value = null;
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'valid_token',
        'kotak_session_sid': 'valid_sid',
        'kotak_session_base_url': 'https://gw.kotaksecurities.com',
        'kotak_login_date': todayStr,
        'scrip_master_last_updated_date': todayStr,
      });

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Switch to Kotak Login tab
      await tester.tap(find.text('Kotak Login'));
      await tester.pump(const Duration(milliseconds: 200));

      // Verify active session banner is shown with Logout button
      expect(find.text('Logged In'), findsOneWidget);
      final logoutBtn = find.widgetWithText(OutlinedButton, 'Logout');
      expect(logoutBtn, findsOneWidget);

      await tester.tap(logoutBtn);
      await tester.pump(const Duration(milliseconds: 300));

      // Session in KotakApi must be cleared
      expect(KotakApi.instance.isLoggedIn, false);

      // Should now show Step 1 login fields
      expect(find.text('Step 1 — Verify TOTP'), findsOneWidget);
      expect(find.text('Step 1: Neo Trade API Credentials'), findsOneWidget);
    });

    testWidgets('Session expiry notification immediately displays SnackBar and switches to login', (tester) async {
      KotakApi.sessionExpiredNotifier.value = null;
      FlutterSecureStorage.setMockInitialValues({
        'kotak_session_token': 'valid_token',
        'kotak_session_sid': 'valid_sid',
        'kotak_session_base_url': 'https://gw.kotaksecurities.com',
        'kotak_login_date': todayStr,
        'scrip_master_last_updated_date': todayStr,
      });

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('NIFTY'), findsOneWidget);

      // Trigger session expired
      KotakApi.sessionExpiredNotifier.value = 'Session expired — please login again';
      await tester.pump(const Duration(milliseconds: 300));

      // Should show SnackBar
      expect(find.text('Session expired — please login again'), findsWidgets);
      // Should switch to login screen
      expect(find.text('Step 1 — Verify TOTP'), findsOneWidget);
    });
  });
}
