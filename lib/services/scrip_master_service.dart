import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

/// Downloads Kotak's scrip master (the full instrument list) into the
/// local `scrips` table. This is where every searchable stock / future /
/// option / commodity comes from — nothing is hardcoded in the app.
///
/// Official flow (Kotak docs): GET {baseUrl}/script-details/1.0/
/// masterscrip/file-paths with ONLY the access-token header returns the
/// day's file list; the CSV folder name is date-stamped, so file URLs
/// must never be hardcoded. A dated-URL fallback is kept as a last
/// resort because it has proven reliable in practice.
class ScripMasterService {
  static final ScripMasterService instance = ScripMasterService._internal();
  ScripMasterService._internal();

  final AppDb _db = AppDb.instance;
  final http.Client _client = http.Client();

  static const String _keyLastRefreshDate = 'scrip_last_refresh_date';
  static const String _keyLastRefreshTime = 'scrip_last_refresh_time';

  static const List<String> segments = ['nse_cm', 'bse_cm', 'nse_fo', 'mcx_fo'];

  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  void Function(String)? onProgress;
  void Function(String)? onError;
  void Function(Map<String, int>)? onSuccess;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<String?> getLastRefreshTime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLastRefreshTime);
  }

  Future<bool> needsRefreshToday() async {
    final prefs = await SharedPreferences.getInstance();
    final lastDate = prefs.getString(_keyLastRefreshDate);
    if (lastDate != _todayStr()) return true;
    final count = await _db.getScripsCount();
    return count == 0;
  }

  /// Silent morning refresh: runs on the first app open of a new day.
  Future<void> checkAndAutoRefreshMorning() async {
    if (_isRefreshing) return;
    if (await needsRefreshToday()) {
      await refreshScripMaster();
    }
  }

  Future<void> refreshScripMaster() async {
    if (_isRefreshing) return;
    _isRefreshing = true;

    try {
      final allScripsData = <Map<String, dynamic>>[];
      final counts = <String, int>{};

      // 1) Ask Kotak for today's file paths (never guess first).
      List<String> filePaths = [];
      try {
        filePaths = await _fetchDynamicFilePaths();
      } catch (_) {}

      final segmentFiles = <String, String>{};
      if (filePaths.isNotEmpty) {
        for (final path in filePaths) {
          final fileName = path.split('/').last.toLowerCase();
          for (final seg in segments) {
            if (fileName.contains(seg)) {
              if (path.startsWith('http')) {
                segmentFiles[seg] = path;
              } else {
                segmentFiles[seg] =
                    'https://lapi.kotaksecurities.com$path';
              }
            }
          }
        }
      }

      // 2) Download + parse each segment.
      for (final seg in segments) {
        onProgress?.call('Downloading $seg...');
        String? csvContent;

        if (segmentFiles.containsKey(seg)) {
          csvContent = await _downloadCsv(segmentFiles[seg]!);
        }
        if (csvContent == null || csvContent.isEmpty) {
          csvContent = await _downloadWithFallback(seg);
        }
        if (csvContent == null || csvContent.isEmpty) {
          onError?.call('Failed to download instruments for $seg');
          continue;
        }

        onProgress?.call('Parsing $seg...');
        final parsedList = await compute(_parseCsvWorker, {
          'csv': csvContent,
          'segment': seg,
        });

        if (parsedList.isNotEmpty) {
          allScripsData.addAll(parsedList);
          final cats = <String, int>{};
          for (final item in parsedList) {
            final type = item['instrument_type'] as String;
            cats[type] = (cats[type] ?? 0) + 1;
          }
          counts['${seg}_EQ'] = cats['EQ'] ?? 0;
          counts['${seg}_FUT'] = cats['FUT'] ?? 0;
          final optCount = (cats['CE'] ?? 0) + (cats['PE'] ?? 0);
          counts['${seg}_OPT'] = optCount;
          if (seg == 'mcx_fo') {
            counts['mcx_fo_COMMODITY'] = parsedList.length;
          }
        }
      }

      if (allScripsData.isEmpty) {
        onError?.call(
            'Download failed: no instruments received. Old data kept.');
        return;
      }

      onProgress?.call('Saving to database...');
      await _db.replaceAllScrips(allScripsData);

      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final timeStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      await prefs.setString(_keyLastRefreshDate, _todayStr());
      await prefs.setString(_keyLastRefreshTime, timeStr);

      onSuccess?.call(counts);
    } catch (e) {
      onError?.call('Scrip refresh error: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<String?> _downloadCsv(String url) async {
    try {
      final headers = {
        if (KotakApi.instance.accessToken != null)
          'Authorization': KotakApi.instance.accessToken!,
        'neo-fin-key': KotakApi.neoFinKey,
      };
      final res = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 45));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res.body;
      }
    } catch (_) {}
    return null;
  }

  /// Last-resort dated URLs (the folder is date-stamped daily).
  Future<String?> _downloadWithFallback(String seg) async {
    final dates = _getCandidateDates();
    final isEquity = seg == 'nse_cm' || seg == 'bse_cm';

    for (final date in dates) {
      final urlsToTry = <String>[];
      if (isEquity) {
        urlsToTry.add(
            'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$date/transformed-v1/$seg-v1.csv');
        urlsToTry.add(
            'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$date/transformed/$seg.csv');
      } else {
        urlsToTry.add(
            'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$date/transformed/$seg.csv');
        urlsToTry.add(
            'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$date/transformed-v1/$seg-v1.csv');
      }
      for (final url in urlsToTry) {
        final content = await _downloadCsv(url);
        if (content != null && content.isNotEmpty) return content;
      }
    }
    return null;
  }

  /// Dynamic file-paths endpoint. Two official Kotak sources spell the
  /// path differently — "script-details" (getting-started doc) vs
  /// "scriptdetails" (migration guide) — so both are tried, and the
  /// filesPaths list is accepted at the top level or nested under "data".
  Future<List<String>> _fetchDynamicFilePaths() async {
    final baseUrl = KotakApi.instance.quotesBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return [];

    final headers = {
      if (KotakApi.instance.accessToken != null)
        'Authorization': KotakApi.instance.accessToken!,
      'neo-fin-key': KotakApi.neoFinKey,
    };

    for (final path in [
      'script-details/1.0/masterscrip/file-paths',
      'scriptdetails/1.0/masterscrip/file-paths',
    ]) {
      try {
        final res = await _client
            .get(Uri.parse('$baseUrl/$path'), headers: headers)
            .timeout(const Duration(seconds: 15));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map) {
            final direct = decoded['filesPaths'];
            if (direct is List) return List<String>.from(direct);
            final data = decoded['data'];
            if (data is Map && data['filesPaths'] is List) {
              return List<String>.from(data['filesPaths'] as List);
            }
          }
        }
      } catch (_) {}
    }
    return [];
  }

  List<String> _getCandidateDates() {
    final dates = <String>[];
    final now = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final dt = now.subtract(Duration(days: i));
      dates.add(dt.toIso8601String().substring(0, 10));
    }
    return dates;
  }
}

/// Converts a raw scrip-master expiry value into a display string.
/// Kotak CSVs carry expiry either as a readable date or as an epoch
/// number (seconds or milliseconds). Epoch becomes "26 Nov 2026";
/// -1/0/empty (equities) becomes null; readable strings pass through.
String? _formatExpiry(String raw) {
  final v = raw.trim();
  if (v.isEmpty || v == '-1' || v == '0') return null;
  final asInt = int.tryParse(v);
  if (asInt != null && v.length >= 9) {
    final ms = asInt > 100000000000 ? asInt : asInt * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${dt.day.toString().padLeft(2, '0')} ${months[dt.month - 1]} ${dt.year}';
  }
  return v;
}

/// CSV parser running in a background isolate (via [compute]).
List<Map<String, dynamic>> _parseCsvWorker(Map<String, dynamic> params) {
  final csvText = params['csv'] as String;
  final segment = params['segment'] as String;

  final lines = const LineSplitter().convert(csvText);
  if (lines.isEmpty) return [];

  String cleanHeader(String h) =>
      h.replaceAll('"', '').replaceAll("'", '').trim().toLowerCase();

  final headers = lines[0].split(',').map(cleanHeader).toList();

  int getIdx(List<String> variants) {
    for (final v in variants) {
      final idx = headers.indexOf(v.toLowerCase());
      if (idx != -1) return idx;
    }
    return -1;
  }

  final symbolNameIdx =
      getIdx(['pSymbolName', 'symbolName', 'symbol_name', 'tradingSymbol']);
  final symbolIdx = getIdx(['pTrdSymbol', 'trdSymbol', 'trading_symbol']);
  final tokenIdx =
      getIdx(['pSymbol', 'symbol', 'token', 'exchange_token', 'instrumentToken']);
  final descIdx = getIdx(['pDesc', 'desc', 'description', 'name', 'companyName']);
  final instNameIdx =
      getIdx(['pInstName', 'instName', 'instrumentName', 'instrument_name']);
  final optionTypeIdx = getIdx(
      ['pOptionType', 'optionType', 'option_type', 'optType', 'instrumentType']);
  final strikeIdx =
      getIdx(['dStrikePrice', 'strikePrice', 'strike_price', 'strike']);
  final expiryIdx = getIdx(['pExpiryDate', 'lExpiryDate', 'expiry', 'expiryDate']);
  final lotSizeIdx = getIdx(['lLotSize', 'lotSize', 'lot_size', 'lot']);
  final tickSizeIdx = getIdx(['dTickSize', 'tickSize', 'tick_size']);

  String getField(List<String> row, int idx) {
    if (idx < 0 || idx >= row.length) return '';
    return row[idx].replaceAll('"', '').replaceAll("'", '').trim();
  }

  final List<Map<String, dynamic>> results = [];
  final bool isDerivative = segment == 'nse_fo' || segment == 'mcx_fo';

  String exchange = 'NSE';
  if (segment.startsWith('bse')) exchange = 'BSE';
  if (segment.startsWith('mcx')) exchange = 'MCX';

  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    // Simple CSV split (Kotak master rows contain no quoted commas).
    final row = line.split(',');

    final rawSymbolName = getField(row, symbolNameIdx);
    final rawSymbol = getField(row, symbolIdx);
    final token = getField(row, tokenIdx);
    final desc = getField(row, descIdx);
    final instName = getField(row, instNameIdx).toUpperCase();
    final optionTypeField = getField(row, optionTypeIdx).toUpperCase();
    final strikeStr = getField(row, strikeIdx);
    final expiryStr = getField(row, expiryIdx);
    final lotSizeStr = getField(row, lotSizeIdx);
    final tickSizeStr = getField(row, tickSizeIdx);

    final String symbol =
        rawSymbol.isNotEmpty ? rawSymbol : rawSymbolName;
    if (symbol.isEmpty) continue;

    final String displayName =
        desc.isNotEmpty ? desc : (rawSymbolName.isNotEmpty ? rawSymbolName : symbol);

    String instrumentType = 'EQ';
    String? underlying;
    String? expiry;
    double? strike;
    int? lotSize =
        lotSizeStr.isNotEmpty ? int.tryParse(lotSizeStr) : null;
    double? tickSize =
        tickSizeStr.isNotEmpty ? double.tryParse(tickSizeStr) : null;

    if (isDerivative) {
      // FUTURES TRAP (official Kotak scrip docs): futures rows carry
      // pOptionType = "XX" — only CE/PE are literal. Check XX FIRST,
      // otherwise a future whose name lacks "FUT" falls into the options
      // branch (because "XX" is non-empty) and is saved as CE.
      if (optionTypeField == 'XX' ||
          instName.contains('FUT') ||
          symbol.endsWith('FUT')) {
        instrumentType = 'FUT';
      } else if (instName.contains('OPT') ||
          optionTypeField.isNotEmpty ||
          symbol.endsWith('CE') ||
          symbol.endsWith('PE')) {
        if (optionTypeField == 'CE' || symbol.endsWith('CE')) {
          instrumentType = 'CE';
        } else if (optionTypeField == 'PE' || symbol.endsWith('PE')) {
          instrumentType = 'PE';
        } else {
          instrumentType = 'CE';
        }
      } else {
        instrumentType = 'FUT';
      }

      if (expiryStr.isNotEmpty) {
        expiry = _formatExpiry(expiryStr);
      }
      if (strikeStr.isNotEmpty) {
        strike = double.tryParse(strikeStr);
        if (strike != null && strike == 0) strike = null;
      }

      // Underlying = trading symbol minus the date/type suffix.
      var temp = symbol;
      temp = temp.replaceAll(
          RegExp(r'(FUT|CE|PE)$', caseSensitive: false), '');
      temp = temp.replaceAll(
          RegExp(
              r'\d{2}(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\d{2,4}',
              caseSensitive: false),
          '');
      temp = temp.replaceAll(RegExp(r'\d+(\.\d+)?$'), '');
      underlying = temp.trim();
      if (underlying.isEmpty) underlying = symbol;
    }

    results.add({
      'token': token.isNotEmpty ? token : symbol,
      'symbol': symbol,
      'display_name': displayName,
      'segment': segment,
      'exchange': exchange,
      'instrument_type': instrumentType,
      'underlying': underlying,
      'expiry': expiry,
      'strike': strike,
      'lot_size': lotSize,
      'tick_size': tickSize,
    });
  }

  return results;
}
