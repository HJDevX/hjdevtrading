import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  group('KotakApi 2-Step Login Tests', () {
    late KotakApi api;

    setUp(() {
      api = KotakApi.instance;
      api.logout();
    });

    test('Initial state: isLoggedIn is false', () {
      expect(api.isLoggedIn, false);
      expect(api.sessionToken, isNull);
      expect(api.baseUrl, isNull);
    });

    test('Successful 2-step login sets tokens and isLoggedIn = true', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/tradeApiLogin')) {
          expect(request.headers['Authorization'], 'test_access_token');
          expect(request.headers['neo-fin-key'], 'neotradeapi');
          expect(request.headers['Content-Type'], 'application/json');

          final body = jsonDecode(request.body);
          expect(body['mobileNumber'], '+919876543210');
          expect(body['ucc'], 'UCC123');
          expect(body['totp'], '123456');

          return http.Response(
            jsonEncode({
              'data': {
                'token': 'view_token_abc',
                'sid': 'view_sid_123',
              }
            }),
            200,
          );
        }

        if (request.url.path.endsWith('/tradeApiValidate')) {
          expect(request.headers['Authorization'], 'test_access_token');
          expect(request.headers['neo-fin-key'], 'neotradeapi');
          expect(request.headers['sid'], 'view_sid_123');
          expect(request.headers['Auth'], 'view_token_abc');

          final body = jsonDecode(request.body);
          expect(body['mpin'], '654321');

          return http.Response(
            jsonEncode({
              'data': {
                'token': 'session_token_xyz',
                'sid': 'session_sid_456',
                'baseUrl': 'https://gw.kotaksecurities.com/trade/1.0',
              }
            }),
            200,
          );
        }

        return http.Response('Not Found', 404);
      });

      api.setMockClient(mockClient);

      await api.tradeApiLogin(
        accessToken: 'test_access_token',
        mobileNumber: '+919876543210',
        ucc: 'UCC123',
        totp: '123456',
      );

      expect(api.viewToken, 'view_token_abc');
      expect(api.viewSid, 'view_sid_123');
      expect(api.isLoggedIn, false); // Step B not done yet

      await api.tradeApiValidate(mpin: '654321');

      expect(api.sessionToken, 'session_token_xyz');
      expect(api.sessionSid, 'session_sid_456');
      expect(api.baseUrl, 'https://gw.kotaksecurities.com/trade/1.0');
      expect(api.isLoggedIn, true);
    });

    test('Throws exception with server message field on Step A error', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'message': 'Invalid TOTP entered. Please try again.',
          }),
          400,
        );
      });

      api.setMockClient(mockClient);

      expect(
        () => api.tradeApiLogin(
          accessToken: 'test_access_token',
          mobileNumber: '+919876543210',
          ucc: 'UCC123',
          totp: '000000',
        ),
        throwsA(
          isA<KotakApiException>().having(
            (e) => e.message,
            'message',
            'Invalid TOTP entered. Please try again.',
          ),
        ),
      );
    });

    test('Throws exception with server message field on Step B error', () async {
      // Setup Step A view credentials
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/tradeApiLogin')) {
          return http.Response(
            jsonEncode({
              'data': {'token': 'view_tok', 'sid': 'view_sid'}
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/tradeApiValidate')) {
          return http.Response(
            jsonEncode({
              'message': 'Invalid MPIN',
            }),
            401,
          );
        }
        return http.Response('Not Found', 404);
      });

      api.setMockClient(mockClient);

      await api.tradeApiLogin(
        accessToken: 'tok',
        mobileNumber: '+911234567890',
        ucc: 'UCC',
        totp: '111111',
      );

      expect(
        () => api.tradeApiValidate(mpin: '000000'),
        throwsA(
          isA<KotakApiException>().having(
            (e) => e.message,
            'message',
            'Invalid MPIN',
          ),
        ),
      );
    });
  });
}
