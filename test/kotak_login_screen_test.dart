import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hjdev_trading/screens/login/kotak_login_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

void main() {
  group('KotakLoginScreen UI & Flow Tests', () {
    late KotakApi api;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      api = KotakApi.instance;
      api.logout();
    });

    testWidgets('Renders Stage 1 fields and Verify TOTP button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: KotakLoginScreen(),
        ),
      );
      await tester.pump();

      expect(find.text('Access Token *'), findsOneWidget);
      expect(find.text('Mobile Number *'), findsOneWidget);
      expect(find.text('UCC (Client Code) *'), findsOneWidget);
      expect(find.text('Daily TOTP (6 Digits) *'), findsOneWidget);
      expect(find.text('Step 1 — Verify TOTP'), findsOneWidget);
      expect(find.text('Step 2 — Login'), findsNothing);
    });

    testWidgets('Validation error appears in red when fields are empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: KotakLoginScreen(),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Step 1 — Verify TOTP'));
      await tester.pump();

      expect(find.text('Please fill in all fields (Token, Mobile, UCC, TOTP).'), findsOneWidget);
    });

    testWidgets('Complete 2-stage login flow switches tab', (tester) async {
      var switched = false;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/tradeApiLogin')) {
          return http.Response(
            jsonEncode({
              'data': {'token': 'view_token_test', 'sid': 'view_sid_test'}
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/tradeApiValidate')) {
          return http.Response(
            jsonEncode({
              'data': {
                'token': 'session_token_test',
                'sid': 'session_sid_test',
                'baseUrl': 'https://gw.kotaksecurities.com/trade/1.0',
              }
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      api.setMockClient(mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: KotakLoginScreen(
            onLoginSuccess: () {
              switched = true;
            },
          ),
        ),
      );
      await tester.pump();

      // Enter Step 1 fields
      await tester.enterText(find.byType(TextField).at(0), 'mock_token');
      await tester.enterText(find.byType(TextField).at(1), '+919999999999');
      await tester.enterText(find.byType(TextField).at(2), 'UCC123');
      await tester.enterText(find.byType(TextField).at(3), '123456');

      await tester.tap(find.text('Step 1 — Verify TOTP'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Stage 2 should now be visible
      expect(find.text('Step 2: Enter MPIN'), findsOneWidget);
      expect(find.text('MPIN (6 Digits) *'), findsOneWidget);
      expect(find.text('Step 2 — Login'), findsOneWidget);

      // Enter MPIN and submit Step 2
      await tester.enterText(find.byType(TextField).first, '654321');
      await tester.tap(find.text('Step 2 — Login'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.isLoggedIn, true);
      expect(switched, true);
    });

    testWidgets('When user is logged in, do NOT show Step 1 verify fields', (tester) async {
      api.setSessionForTesting(
        accessToken: 'valid_access_token',
        sessionToken: 'valid_session_token',
        sessionSid: 'valid_session_sid',
        baseUrl: 'https://gw.kotaksecurities.com',
        greetingName: 'Trader Rahul',
      );
      expect(api.isLoggedIn, true);

      await tester.pumpWidget(
        const MaterialApp(
          home: KotakLoginScreen(),
        ),
      );
      await tester.pump();

      // Must NOT show Step 1 or Step 2 fields
      expect(find.text('Step 1 — Verify TOTP'), findsNothing);
      expect(find.text('Step 1: Neo Trade API Credentials'), findsNothing);
      expect(find.text('Access Token *'), findsNothing);
      expect(find.text('Daily TOTP (6 Digits) *'), findsNothing);
      expect(find.text('Step 2 — Login'), findsNothing);

      // Must show logged in details and Logout button
      expect(find.text('Trader Rahul'), findsOneWidget);
      expect(find.text('Active Trading Session (Today)'), findsOneWidget);
      final logoutBtn = find.widgetWithText(OutlinedButton, 'Logout');
      expect(logoutBtn, findsOneWidget);

      // Tapping Logout clears session and transitions to Step 1
      await tester.tap(logoutBtn);
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.isLoggedIn, false);
      expect(find.text('Step 1 — Verify TOTP'), findsOneWidget);
      expect(find.text('Step 1: Neo Trade API Credentials'), findsOneWidget);
    });
  });
}
