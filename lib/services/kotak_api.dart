import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

  // Storage
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _keyAccessToken = 'kotak_access_token';
  static const String _keyMobileNumber = 'kotak_mobile_number';
  static const String _keyUcc = 'kotak_ucc';

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

  // Step B outputs (in-memory only)
  String? _sessionToken;
  String? _sessionSid;
  String? _baseUrl;

  // Getters
  String? get accessToken => _accessToken;
  String? get mobileNumber => _mobileNumber;
  String? get ucc => _ucc;
  String? get viewToken => _viewToken;
  String? get viewSid => _viewSid;
  String? get sessionToken => _sessionToken;
  String? get sessionSid => _sessionSid;
  String? get baseUrl => _baseUrl;

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

  /// Clears in-memory session tokens
  void logout() {
    _viewToken = null;
    _viewSid = null;
    _sessionToken = null;
    _sessionSid = null;
    _baseUrl = null;
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
