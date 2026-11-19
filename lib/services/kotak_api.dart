import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:hjdev_trading/models/quote.dart';

/// Exception thrown when a Kotak Neo API request fails
class KotakApiException implements Exception {
  final String message;
  final int? statusCode;

  KotakApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Service handling the official 2-step Kotak Neo Trade API authentication
class KotakApi {
  static final KotakApi instance = KotakApi._();
  KotakApi._();

  // Custom client support for dependency injection & testing
  http.Client? _httpClient;
  void setMockClient(http.Client? client) => _httpClient = client;
  http.Client get _client => _httpClient ?? http.Client();

  // Storage keys for profile
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _keyAccessToken = 'kotak_access_token';
  static const String _keyMobileNumber = 'kotak_mobile_number';
  static const String _keyUcc = 'kotak_ucc';

  // Storage keys for active session ("Keep me logged in" for today)
  static const String _keySessionToken = 'kotak_session_token';
  static const String _keySessionSid = 'kotak_session_sid';
  static const String _keySessionBaseUrl = 'kotak_session_base_url';
  static const String _keyGreetingName = 'kotak_greeting_name';
  static const String _keyLoginDate = 'kotak_login_date';

  // Session expired notifier
  static final ValueNotifier<String?> sessionExpiredNotifier =
      ValueNotifier<String?>(null);

  // Static API constants
  static const String loginBaseUrl = 'https://mis.kotaksecurities.com/login/1.0';
  static const String neoFinKey = 'neotradeapi';

  // In-memory session credentials
  String? _accessToken;
  String? _mobileNumber;
  String? _ucc;

  // Step A outputs (in-memory only)
  String? _viewToken;
  String? _viewSid;

  // Step B outputs
  String? _sessionToken;
  String? _sessionSid;
  String? _baseUrl;
  String? _greetingName;
  String? _loginDate;

  // Getters
  String? get accessToken => _accessToken;
  String? get mobileNumber => _mobileNumber;
  String? get ucc => _ucc;
  String? get viewToken => _viewToken;
  String? get viewSid => _viewSid;
  String? get sessionToken => _sessionToken;
  String? get sessionSid => _sessionSid;
  String? get baseUrl => _baseUrl;
  String? get greetingName => _greetingName;
  String? get loginDate => _loginDate;

  /// Returns today's date in IST (Indian Standard Time, UTC+5:30) as yyyy-mm-dd
  static String getTodayIstDate() {
    final nowUtc = DateTime.now().toUtc();
    final ist = nowUtc.add(const Duration(hours: 5, minutes: 30));
    final y = ist.year.toString().padLeft(4, '0');
    final m = ist.month.toString().padLeft(2, '0');
    final d = ist.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// True when session token and baseUrl both exist
  bool get isLoggedIn =>
      (_sessionToken != null && _sessionToken!.isNotEmpty) &&
      (_baseUrl != null && _baseUrl!.isNotEmpty);

  // --- Step A: tradeApiLogin ---
  /// POST `https://mis.kotaksecurities.com/login/1.0/tradeApiLogin`
  /// Headers: `Authorization: <accessToken>`, `neo-fin-key: neotradeapi`, `Content-Type: application/json`
  /// Body: `{"mobileNumber": "<+91...>", "ucc": "<client code>", "totp": "<6 digit>"}`
  /// Keeps `data.token` (view token) and `data.sid` in memory.
  Future<Map<String, dynamic>> tradeApiLogin({
    required String accessToken,
    required String mobileNumber,
    required String ucc,
    required String totp,
  }) async {
    _accessToken = accessToken.trim();
    _mobileNumber = mobileNumber.trim();
    _ucc = ucc.trim();

    final url = Uri.parse('$loginBaseUrl/tradeApiLogin');
    final headers = {
      'Authorization': _accessToken!,
      'neo-fin-key': neoFinKey,
      'Content-Type': 'application/json',
    };

    final body = jsonEncode({
      'mobileNumber': _mobileNumber!,
      'ucc': _ucc!,
      'totp': totp.trim(),
    });

    final response = await _client.post(url, headers: headers, body: body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      final data = (decoded is Map && decoded.containsKey('data'))
          ? decoded['data'] as Map<String, dynamic>? ?? {}
          : (decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});

      _viewToken = data['token']?.toString();
      _viewSid = data['sid']?.toString();

      return data;
    } else {
      final errorMessage = _extractErrorMessage(response);
      throw KotakApiException(errorMessage, statusCode: response.statusCode);
    }
  }

  // --- Step B: tradeApiValidate ---
  /// POST `https://mis.kotaksecurities.com/login/1.0/tradeApiValidate`
  /// Headers: `Authorization: <accessToken>`, `neo-fin-key: neotradeapi`, `Content-Type: application/json`, `sid: <view sid>`, `Auth: <view token>`
  /// Body: `{"mpin": "<6 digit>"}`
  /// Keeps `data.token` (session token), `data.sid`, and `data.baseUrl` in memory.
  Future<Map<String, dynamic>> tradeApiValidate({
    required String mpin,
    String? accessToken,
    String? viewSid,
    String? viewToken,
  }) async {
    final tokenAuth = accessToken ?? _accessToken;
    final sidVal = viewSid ?? _viewSid;
    final authVal = viewToken ?? _viewToken;

    if (tokenAuth == null || tokenAuth.isEmpty) {
      throw KotakApiException('Missing Access Token. Please perform Step A first.');
    }
    if (sidVal == null || sidVal.isEmpty || authVal == null || authVal.isEmpty) {
      throw KotakApiException('Missing View Token / SID. Please perform Step A first.');
    }

    final url = Uri.parse('$loginBaseUrl/tradeApiValidate');
    final headers = {
      'Authorization': tokenAuth,
      'neo-fin-key': neoFinKey,
      'Content-Type': 'application/json',
      'sid': sidVal,
      'Auth': authVal,
    };

    final body = jsonEncode({
      'mpin': mpin.trim(),
    });

    final response = await _client.post(url, headers: headers, body: body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      final data = (decoded is Map && decoded.containsKey('data'))
          ? decoded['data'] as Map<String, dynamic>? ?? {}
          : (decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});

      _sessionToken = data['token']?.toString();
      _sessionSid = data['sid']?.toString();
      _baseUrl = data['baseUrl']?.toString();
      _greetingName = data['greetingName']?.toString() ??
          data['name']?.toString() ??
          data['clientName']?.toString() ??
          '';

      // Save active session for today
      if (_sessionToken != null && _baseUrl != null) {
        await saveSession(
          sessionToken: _sessionToken!,
          sessionSid: _sessionSid ?? '',
          baseUrl: _baseUrl!,
          greetingName: _greetingName ?? '',
          loginDate: getTodayIstDate(),
        );
      }

      return data;
    } else {
      final errorMessage = _extractErrorMessage(response);
      throw KotakApiException(errorMessage, statusCode: response.statusCode);
    }
  }

  // --- 2-Step Login Helper ---
  /// Executes Step A followed by Step B
  Future<void> login({
    required String accessToken,
    required String mobileNumber,
    required String ucc,
    required String totp,
    required String mpin,
  }) async {
    await tradeApiLogin(
      accessToken: accessToken,
      mobileNumber: mobileNumber,
      ucc: ucc,
      totp: totp,
    );
    await tradeApiValidate(mpin: mpin);
  }

  // --- Live Quotes ---
  /// GET `{baseUrl}/script-details/1.0/quotes/neosymbol/{exchange}|{symbol}`
  /// Headers: `Authorization: <accessToken>`, `neo-fin-key: neotradeapi`, `Auth: <session token>`, `sid: <session sid>`
  /// Parses ltp, open, high, low, previous close, volume.
  Future<Quote> getQuote(String symbol, String exchange, {String? token}) async {
    if (!isLoggedIn) {
      throw KotakApiException('Not logged in. Please log in first.');
    }

    var base = _baseUrl!;
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }

    final rawSegment = '$exchange|$symbol';
    final encodedSegment = Uri.encodeComponent(rawSegment);
    final url =
        Uri.parse('$base/script-details/1.0/quotes/neosymbol/$encodedSegment');

    final headers = {
      'Authorization': _accessToken ?? '',
      'neo-fin-key': neoFinKey,
      'Auth': _sessionToken ?? '',
      'sid': _sessionSid ?? '',
    };

    final response = await _client.get(url, headers: headers);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final err = _extractErrorMessage(response);
      debugPrint(
          'KotakApi getQuote error (${response.statusCode}) for $rawSegment: ${response.body}');

      // If HTTP 403 or message contains "session", treat saved session as dead
      if (response.statusCode == 403 || err.toLowerCase().contains('session')) {
        await deleteSavedSession();
        sessionExpiredNotifier.value = 'Session expired — please login again';
      }

      throw KotakApiException(err, statusCode: response.statusCode);
    }

    try {
      final decoded = jsonDecode(response.body);
      Map<String, dynamic>? quoteMap;

      // The response may be a top-level list or an object with a data field — handle both
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first;
        if (first is Map<String, dynamic>) {
          quoteMap = first;
        } else if (first is Map) {
          quoteMap = Map<String, dynamic>.from(first);
        }
      } else if (decoded is Map) {
        final dataField = decoded['data'] ??
            decoded['result'] ??
            decoded['quotes'] ??
            decoded['quote'];

        if (dataField is List && dataField.isNotEmpty) {
          final first = dataField.first;
          if (first is Map) {
            quoteMap = Map<String, dynamic>.from(first);
          }
        } else if (dataField is Map) {
          quoteMap = Map<String, dynamic>.from(dataField);
        } else {
          quoteMap = Map<String, dynamic>.from(decoded);
        }
      }

      if (quoteMap != null && quoteMap.isNotEmpty) {
        return Quote.fromMap(quoteMap, symbol: symbol, exchange: exchange);
      } else {
        debugPrint(
            'KotakApi getQuote returned empty data for $rawSegment. Raw response: ${response.body}');
        throw KotakApiException('Quote returned empty for $symbol ($exchange)');
      }
    } catch (e) {
      // If parsing fails, print raw response in debug log so we can fix the parser from real response
      debugPrint(
          'KotakApi getQuote parsing failed for $rawSegment: $e. Raw response: ${response.body}');
      rethrow;
    }
  }

  /// Saves session in flutter_secure_storage for today (IST)
  Future<void> saveSession({
    required String sessionToken,
    required String sessionSid,
    required String baseUrl,
    required String greetingName,
    required String loginDate,
  }) async {
    _sessionToken = sessionToken;
    _sessionSid = sessionSid;
    _baseUrl = baseUrl;
    _greetingName = greetingName;
    _loginDate = loginDate;

    await _storage.write(key: _keySessionToken, value: sessionToken);
    await _storage.write(key: _keySessionSid, value: sessionSid);
    await _storage.write(key: _keySessionBaseUrl, value: baseUrl);
    await _storage.write(key: _keyGreetingName, value: greetingName);
    await _storage.write(key: _keyLoginDate, value: loginDate);
  }

  /// Deletes saved session from secure storage and clears in-memory session
  Future<void> deleteSavedSession() async {
    await _storage.delete(key: _keySessionToken);
    await _storage.delete(key: _keySessionSid);
    await _storage.delete(key: _keySessionBaseUrl);
    await _storage.delete(key: _keyGreetingName);
    await _storage.delete(key: _keyLoginDate);
    logout();
  }

  /// On app start: read saved session. If loginDate equals today's date in IST,
  /// restore session into KotakApi (isLoggedIn = true) and return true.
  /// If loginDate is older or missing, delete saved session and return false.
  Future<bool> restoreSessionIfValid() async {
    await loadSavedProfile();

    final savedDate = await _storage.read(key: _keyLoginDate);
    final todayIst = getTodayIstDate();

    if (savedDate != null && savedDate == todayIst) {
      final token = await _storage.read(key: _keySessionToken);
      final sid = await _storage.read(key: _keySessionSid);
      final base = await _storage.read(key: _keySessionBaseUrl);
      final greeting = await _storage.read(key: _keyGreetingName);

      if (token != null && token.isNotEmpty && base != null && base.isNotEmpty) {
        _sessionToken = token;
        _sessionSid = sid;
        _baseUrl = base;
        _greetingName = greeting;
        _loginDate = savedDate;
        return true;
      }
    }

    // Older date or invalid: clean up
    await deleteSavedSession();
    return false;
  }

  /// Helper for unit testing session state injection
  void setSessionForTesting({
    String? accessToken,
    String? sessionToken,
    String? sessionSid,
    String? baseUrl,
    String? greetingName,
    String? loginDate,
  }) {
    _accessToken = accessToken;
    _sessionToken = sessionToken;
    _sessionSid = sessionSid;
    _baseUrl = baseUrl;
    _greetingName = greetingName;
    _loginDate = loginDate ?? getTodayIstDate();
  }

  /// Clears in-memory session tokens
  void logout() {
    _viewToken = null;
    _viewSid = null;
    _sessionToken = null;
    _sessionSid = null;
    _baseUrl = null;
    _greetingName = null;
    _loginDate = null;
  }

  // --- Profile Storage (flutter_secure_storage) ---
  /// Save user profile (accessToken, mobileNumber, ucc only).
  /// NEVER saves totp or mpin.
  Future<void> saveProfile({
    required String accessToken,
    required String mobileNumber,
    required String ucc,
  }) async {
    _accessToken = accessToken.trim();
    _mobileNumber = mobileNumber.trim();
    _ucc = ucc.trim();

    await _storage.write(key: _keyAccessToken, value: _accessToken);
    await _storage.write(key: _keyMobileNumber, value: _mobileNumber);
    await _storage.write(key: _keyUcc, value: _ucc);
  }

  /// Load saved profile from secure storage
  Future<Map<String, String>> loadSavedProfile() async {
    final token = await _storage.read(key: _keyAccessToken) ?? '';
    final mobile = await _storage.read(key: _keyMobileNumber) ?? '';
    final uccVal = await _storage.read(key: _keyUcc) ?? '';

    if (token.isNotEmpty) _accessToken = token;
    if (mobile.isNotEmpty) _mobileNumber = mobile;
    if (uccVal.isNotEmpty) _ucc = uccVal;

    return {
      'accessToken': token,
      'mobileNumber': mobile,
      'ucc': uccVal,
    };
  }

  /// Clear saved profile from secure storage
  Future<void> clearSavedProfile() async {
    await _storage.delete(key: _keyAccessToken);
    await _storage.delete(key: _keyMobileNumber);
    await _storage.delete(key: _keyUcc);
    _accessToken = null;
    _mobileNumber = null;
    _ucc = null;
  }

  // --- Error Parser ---
  /// Extracts the server's "message" field on failure
  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        if (decoded.containsKey('message') && decoded['message'] != null) {
          return decoded['message'].toString();
        }
        if (decoded.containsKey('error')) {
          final err = decoded['error'];
          if (err is Map && err.containsKey('message') && err['message'] != null) {
            return err['message'].toString();
          }
          if (err is List && err.isNotEmpty) {
            final first = err.first;
            if (first is Map && first.containsKey('message') && first['message'] != null) {
              return first['message'].toString();
            }
          }
          return err.toString();
        }
        if (decoded.containsKey('Fault')) {
          final fault = decoded['Fault'];
          if (fault is Map && fault.containsKey('faultstring')) {
            return fault['faultstring'].toString();
          }
        }
      }
    } catch (_) {}

    return response.reasonPhrase ??
        'Server returned error status: ${response.statusCode}';
  }
}
