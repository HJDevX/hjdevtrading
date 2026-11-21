import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hjdev_trading/models/quote.dart';
import 'package:hjdev_trading/models/watchlist.dart';

/// Kotak Neo Trade API client (login, session, quotes).
///
/// Login is the official 2-step flow from Kotak's docs:
///  Step A: POST /login/1.0/tradeApiLogin  (access token + mobile + UCC + TOTP)
///          -> view token + sid
///  Step B: POST /login/1.0/tradeApiValidate (view token + sid + MPIN)
///          -> session token + sid + baseUrl + feedUrl
///
/// Quotes need ONLY the access token (no session). Indices are NOT served
/// by REST quotes at all — they come from the WebSocket index feed.
///
/// Safety rule: this class NEVER calls any order API.
class KotakApi {
  static final KotakApi instance = KotakApi._internal();
  KotakApi._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final http.Client _client = http.Client();

  static const String loginBaseUrl = 'https://mis.kotaksecurities.com';
  static const String neoFinKey = 'neotradeapi';

  // Secure-storage keys
  static const String _keyAccessToken = 'kotak_access_token';
  static const String _keyMobile = 'kotak_mobile';
  static const String _keyUcc = 'kotak_ucc';
  static const String _keySessionToken = 'kotak_session_token';
  static const String _keySessionSid = 'kotak_session_sid';
  static const String _keyBaseUrl = 'kotak_base_url';
  static const String _keyFeedUrl = 'kotak_feed_url';
  static const String _keyGreetingName = 'kotak_greeting_name';
  static const String _keyLoginDate = 'kotak_login_date';
  // The gateway host (baseUrl) is NOT a secret. It is kept even after
  // logout so quotes and the scrip-master download still know where to
  // go before the next login.
  static const String _keyGatewayBaseUrl = 'kotak_gateway_base_url';

  String? accessToken;
  String? mobileNumber;
  String? ucc;

  String? _sessionToken;
  String? _sessionSid;
  String? _baseUrl;
  String? _feedUrl;
  String? greetingName;

  String? _gatewayBaseUrl;

  String? get sessionToken => _sessionToken;
  String? get sessionSid => _sessionSid;
  String? get baseUrl => _baseUrl;
  String? get feedUrl => _feedUrl;

  /// Host for quotes / scrip master: today's session host if logged in,
  /// otherwise the last known gateway host.
  String? get quotesBaseUrl => _baseUrl ?? _gatewayBaseUrl;

  bool get isLoggedIn =>
      _sessionToken != null &&
      _sessionToken!.isNotEmpty &&
      _sessionSid != null &&
      _sessionSid!.isNotEmpty;

  // ---------------- Profile (saved once) ----------------

  Future<void> saveProfile({
    required String accessToken,
    required String mobileNumber,
    required String ucc,
  }) async {
    this.accessToken = accessToken.trim();
    this.mobileNumber = mobileNumber.trim();
    this.ucc = ucc.trim();
    await _storage.write(key: _keyAccessToken, value: this.accessToken);
    await _storage.write(key: _keyMobile, value: this.mobileNumber);
    await _storage.write(key: _keyUcc, value: this.ucc);
  }

  Future<void> loadSavedProfile() async {
    accessToken = await _storage.read(key: _keyAccessToken);
    mobileNumber = await _storage.read(key: _keyMobile);
    ucc = await _storage.read(key: _keyUcc);
    _gatewayBaseUrl = await _storage.read(key: _keyGatewayBaseUrl);
  }

  // ---------------- Session ----------------

  String _todayIST() {
    final nowUtc = DateTime.now().toUtc();
    final ist = nowUtc.add(const Duration(hours: 5, minutes: 30));
    return '${ist.year.toString().padLeft(4, '0')}-'
        '${ist.month.toString().padLeft(2, '0')}-'
        '${ist.day.toString().padLeft(2, '0')}';
  }

  Future<void> _saveSession({
    required String token,
    required String sid,
    required String baseUrl,
    String? feedUrl,
    String? greeting,
  }) async {
    _sessionToken = token;
    _sessionSid = sid;
    _baseUrl = baseUrl;
    _feedUrl = feedUrl;
    greetingName = greeting;
    _gatewayBaseUrl = baseUrl;

    await _storage.write(key: _keySessionToken, value: token);
    await _storage.write(key: _keySessionSid, value: sid);
    await _storage.write(key: _keyBaseUrl, value: baseUrl);
    if (feedUrl != null && feedUrl.isNotEmpty) {
      await _storage.write(key: _keyFeedUrl, value: feedUrl);
    }
    if (greeting != null) {
      await _storage.write(key: _keyGreetingName, value: greeting);
    }
    await _storage.write(key: _keyLoginDate, value: _todayIST());
    await _storage.write(key: _keyGatewayBaseUrl, value: baseUrl);
  }

  /// Restores today's session (if any) so the user stays logged in for
  /// the day. Returns true when a valid same-day session was restored.
  Future<bool> restoreSessionIfValid() async {
    await loadSavedProfile();
    final loginDate = await _storage.read(key: _keyLoginDate);
    if (loginDate != _todayIST()) {
      await deleteSavedSession();
      return false;
    }
    _sessionToken = await _storage.read(key: _keySessionToken);
    _sessionSid = await _storage.read(key: _keySessionSid);
    _baseUrl = await _storage.read(key: _keyBaseUrl);
    _feedUrl = await _storage.read(key: _keyFeedUrl);
    greetingName = await _storage.read(key: _keyGreetingName);

    if (_sessionToken == null ||
        _sessionToken!.isEmpty ||
        _sessionSid == null ||
        _sessionSid!.isEmpty ||
        _baseUrl == null ||
        _baseUrl!.isEmpty) {
      await deleteSavedSession();
      return false;
    }
    return true;
  }

  Future<void> deleteSavedSession() async {
    _sessionToken = null;
    _sessionSid = null;
    _baseUrl = null;
    _feedUrl = null;
    greetingName = null;
    await _storage.delete(key: _keySessionToken);
    await _storage.delete(key: _keySessionSid);
    await _storage.delete(key: _keyBaseUrl);
    await _storage.delete(key: _keyFeedUrl);
    await _storage.delete(key: _keyGreetingName);
    await _storage.delete(key: _keyLoginDate);
    // NOTE: profile and gateway host are intentionally kept.
  }

  // ---------------- Login step A: TOTP ----------------

  Future<Map<String, dynamic>> tradeApiLogin({
    required String totp,
  }) async {
    if (accessToken == null || accessToken!.isEmpty) {
      throw Exception('Please enter your Kotak Access Token first');
    }
    if (mobileNumber == null || mobileNumber!.isEmpty) {
      throw Exception('Please enter your mobile number first');
    }
    if (ucc == null || ucc!.isEmpty) {
      throw Exception('Please enter your UCC first');
    }

    final url = Uri.parse('$loginBaseUrl/login/1.0/tradeApiLogin');
    final headers = {
      'Authorization': accessToken!,
      'neo-fin-key': neoFinKey,
      'Content-Type': 'application/json',
    };
    final body = jsonEncode({
      'mobileNumber': mobileNumber!.trim(),
      'ucc': ucc!.trim(),
      'totp': totp.trim(),
    });

    final response = await _client
        .post(url, headers: headers, body: body)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw Exception('Unexpected response from Kotak (not a JSON object)');
    }

    String errMsg = 'Login failed (Status ${response.statusCode})';
    try {
      final errDecoded = jsonDecode(response.body);
      if (errDecoded is Map) {
        errMsg = errDecoded['message'] ??
            errDecoded['error']?['message'] ??
            errDecoded.toString();
      }
    } catch (_) {
      errMsg = '${errMsg.split('\n').first}: ${response.body}';
    }
    throw Exception(errMsg);
  }

  // ---------------- Login step B: MPIN ----------------

  Future<Map<String, dynamic>> tradeApiValidate({
    required String viewToken,
    required String viewSid,
    required String mpin,
  }) async {
    final url = Uri.parse('$loginBaseUrl/login/1.0/tradeApiValidate');
    final headers = {
      'Authorization': accessToken!,
      'neo-fin-key': neoFinKey,
      'Content-Type': 'application/json',
      'sid': viewSid,
      'Auth': viewToken,
    };
    final body = jsonEncode({'mpin': mpin.trim()});

    final response = await _client
        .post(url, headers: headers, body: body)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final data = decoded['data'] as Map<String, dynamic>?;
        if (data != null) {
          final sessionToken =
              data['token']?.toString() ?? data['sessionToken']?.toString();
          final sessionSid = data['sid']?.toString();
          final baseUrl = data['baseUrl']?.toString();
          final feedUrl = data['feedUrl']?.toString();
          final greeting =
              data['greetingName']?.toString() ?? data['name']?.toString();

          if (sessionToken != null &&
              sessionSid != null &&
              baseUrl != null) {
            await _saveSession(
              token: sessionToken,
              sid: sessionSid,
              baseUrl: baseUrl,
              feedUrl: feedUrl,
              greeting: greeting,
            );
          }
        }
        return decoded;
      }
      throw Exception('Unexpected response from Kotak (not a JSON object)');
    }

    String errMsg = 'Validate failed (Status ${response.statusCode})';
    try {
      final errDecoded = jsonDecode(response.body);
      if (errDecoded is Map) {
        errMsg = errDecoded['message'] ??
            errDecoded['error']?['message'] ??
            errDecoded.toString();
      }
    } catch (_) {
      errMsg = '${errMsg.split('\n').first}: ${response.body}';
    }
    throw Exception(errMsg);
  }

  // ---------------- Quotes (REST, access-token only) ----------------

  static String normalizeSegment(String rawSegment) {
    var seg = rawSegment.trim().toLowerCase();
    if (seg == 'nse' || seg == 'nse_eq') return 'nse_cm';
    if (seg == 'bse' || seg == 'bse_eq') return 'bse_cm';
    if (seg == 'mcx') return 'mcx_fo';
    if (seg.contains('nse_cm')) return 'nse_cm';
    if (seg.contains('bse_cm')) return 'bse_cm';
    if (seg.contains('nse_fo')) return 'nse_fo';
    if (seg.contains('bse_fo')) return 'bse_fo';
    if (seg.contains('mcx_fo')) return 'mcx_fo';
    if (seg.contains('cde_fo')) return 'cde_fo';
    if (seg == 'nse_cm' ||
        seg == 'bse_cm' ||
        seg == 'nse_fo' ||
        seg == 'bse_fo' ||
        seg == 'mcx_fo' ||
        seg == 'cde_fo') {
      return seg;
    }
    return seg;
  }

  /// Batch quotes for many instruments in ONE call.
  ///
  /// Official format (Kotak quotes docs):
  ///   GET {baseUrl}/script-details/1.0/quotes/neosymbol/
  ///       {segment}|{TOKEN}[,{segment}|{TOKEN}...]/all
  /// The value after | is the instrument TOKEN, never the symbol name.
  /// | and , are NOT url-encoded. Max 50 instruments per call.
  ///
  /// INDEX items are skipped: the REST API rejects them with 400 —
  /// indices come only from the WebSocket index feed.
  ///
  /// Quotes authenticate with the access token alone, so an error here
  /// must NEVER delete the saved login session.
  Future<Map<String, Quote>> getQuotesBatch(List<WatchItem> items) async {
    final result = <String, Quote>{};
    if (items.isEmpty) return result;

    final host = quotesBaseUrl;
    if (host == null || host.isEmpty) {
      debugPrint('KotakApi quotes: no baseUrl known yet (login once first)');
      return result;
    }
    if (accessToken == null || accessToken!.isEmpty) {
      debugPrint('KotakApi quotes: access token missing — save profile first');
      return result;
    }

    final itemByToken = <String, WatchItem>{};
    final segments = <String>[];

    for (final item in items) {
      if (item.isIndex) continue;
      var tokenStr = item.token?.trim();
      if (tokenStr == null || tokenStr.isEmpty) continue;
      // Some old rows stored a decimal token like "1333.0" — normalise.
      if (tokenStr.contains('.')) {
        final parsed = double.tryParse(tokenStr);
        if (parsed != null) tokenStr = parsed.toInt().toString();
      }
      final segment = normalizeSegment(item.exchange);
      if (segment.isEmpty) continue;
      itemByToken[tokenStr] = item;
      segments.add('$segment|$tokenStr');
    }

    if (segments.isEmpty) return result;

    const batchSize = 50;
    for (int i = 0; i < segments.length; i += batchSize) {
      final chunk = segments.sublist(
          i, i + batchSize > segments.length ? segments.length : i + batchSize);
      final joined = chunk.join(',');
      final urlString = '$host/script-details/1.0/quotes/neosymbol/$joined/all';
      final uri = Uri.parse(urlString);

      final headers = {
        'Authorization': accessToken!,
        'neo-fin-key': neoFinKey,
        if (isLoggedIn) 'Auth': _sessionToken!,
        if (isLoggedIn) 'sid': _sessionSid!,
      };

      try {
        final response = await _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 10));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decoded = jsonDecode(response.body);
          if (decoded is List) {
            for (final itemMap in decoded) {
              if (itemMap is Map<String, dynamic>) {
                final tokenStr =
                    (itemMap['exchange_token'] ?? itemMap['token'])?.toString();
                if (tokenStr != null && itemByToken.containsKey(tokenStr)) {
                  final wItem = itemByToken[tokenStr]!;
                  final quote = Quote.fromMap(
                    itemMap,
                    symbol: wItem.symbol,
                    exchange: normalizeSegment(wItem.exchange),
                  );
                  // Keyed by token always, and by watchlist-item id when
                  // the item has one (paper positions have no id).
                  result[tokenStr] = quote;
                  if (wItem.id != null) {
                    result[wItem.id!.toString()] = quote;
                  }
                }
              }
            }
          }
        } else {
          // Log only errors, and only the body — never on success, the
          // watchlist polls every few seconds.
          debugPrint(
              'KotakApi quotes batch (${response.statusCode}) for $urlString: ${response.body}');
        }
      } catch (e) {
        debugPrint('KotakApi quotes batch exception: $e');
      }
    }
    return result;
  }
}
