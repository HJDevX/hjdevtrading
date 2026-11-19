import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:hjdev_trading/db/app_db.dart';
import 'package:hjdev_trading/models/scrip.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

class ScripSyncResult {
  final bool success;
  final String message;
  final int stocksCount;
  final int futuresCount;
  final int optionsCount;
  final int commodityCount;
  final String? error;

  ScripSyncResult({
    required this.success,
    required this.message,
    this.stocksCount = 0,
    this.futuresCount = 0,
    this.optionsCount = 0,
    this.commodityCount = 0,
    this.error,
  });
}

class ScripMasterService {
  static final ScripMasterService instance = ScripMasterService._();
  ScripMasterService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _keyLastUpdated = 'scrip_master_last_updated_time';
  static const String _keyLastDate = 'scrip_master_last_updated_date';

  http.Client? _mockClient;
  void setMockClient(http.Client? client) => _mockClient = client;
  http.Client get _client => _mockClient ?? http.Client();

  /// Formatted date/time when scrips were last updated
  Future<String> getLastUpdatedDisplay() async {
    final timestamp = await _storage.read(key: _keyLastUpdated);
    if (timestamp == null || timestamp.isEmpty) {
      return 'Tap ⟳ to download Scrip Master';
    }
    return timestamp;
  }

  /// Automatically called on app launch: if today's date != last sync date, auto-refreshes
  Future<ScripSyncResult?> checkAndAutoRefreshMorning({
    void Function(String message)? onProgress,
  }) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final lastDate = await _storage.read(key: _keyLastDate);

    if (lastDate != today) {
      debugPrint('ScripMaster: New day detected ($today != $lastDate). Starting auto-refresh…');
      return await syncScripMaster(force: true, onProgress: onProgress);
    }
    return null;
  }

  /// Manually downloads the latest Kotak Neo Scrip Master for NSE, BSE, NFO and MCX.
  /// If refresh fails, leaves the existing database completely unchanged and shows error.
  Future<ScripSyncResult> syncScripMaster({
    bool force = false,
    void Function(String message)? onProgress,
  }) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final lastDate = await _storage.read(key: _keyLastDate);

    if (!force && lastDate == today) {
      final existingSummary = await getLastUpdatedDisplay();
      return ScripSyncResult(
        success: true,
        message: existingSummary,
      );
    }

    try {
      onProgress?.call('Connecting to Kotak Scrip Master…');

      // 1. Check if dynamic file-paths endpoint is available
      final dynamicUrls = await _fetchDynamicFilePaths();

      // 2. Candidate dates if dynamic URLs are not returned or need fallback
      final candidateDates = _getCandidateDates();

      // Segment configurations
      final segmentsToFetch = [
        {
          'segment': 'nse_cm',
          'exchange': 'NSE',
          'label': 'NSE stocks',
          'isDerivative': false,
          'preferredKey': 'nse_cm-v1.csv',
          'fallbackKey': 'nse_cm.csv',
          'directPath': (String d) =>
              'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$d/transformed-v1/nse_cm-v1.csv',
        },
        {
          'segment': 'bse_cm',
          'exchange': 'BSE',
          'label': 'BSE stocks',
          'isDerivative': false,
          'preferredKey': 'bse_cm-v1.csv',
          'fallbackKey': 'bse_cm.csv',
          'directPath': (String d) =>
              'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$d/transformed-v1/bse_cm-v1.csv',
        },
        {
          'segment': 'nse_fo',
          'exchange': 'NSE',
          'label': 'NSE Futures & Options',
          'isDerivative': true,
          'preferredKey': 'nse_fo.csv',
          'fallbackKey': 'nse_fo.csv',
          'directPath': (String d) =>
              'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$d/transformed/nse_fo.csv',
        },
        {
          'segment': 'mcx_fo',
          'exchange': 'MCX',
          'label': 'MCX Commodities',
          'isDerivative': true,
          'preferredKey': 'mcx_fo.csv',
          'fallbackKey': 'mcx_fo.csv',
          'directPath': (String d) =>
              'https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod/$d/transformed/mcx_fo.csv',
        },
      ];

      final allParsedScrips = <Scrip>[];
      bool anySegmentSucceeded = false;

      final headers = {
        if (KotakApi.instance.accessToken != null &&
            KotakApi.instance.accessToken!.isNotEmpty)
          'Authorization': KotakApi.instance.accessToken!,
        'neo-fin-key': KotakApi.neoFinKey,
      };

      for (final config in segmentsToFetch) {
        final label = config['label'] as String;
        final segment = config['segment'] as String;
        final exchange = config['exchange'] as String;
        final isDerivative = config['isDerivative'] as bool;

        onProgress?.call('Downloading $label…');

        String? csvBody;

        // Try dynamic URL first if found
        final prefKey = config['preferredKey'] as String;
        final fallKey = config['fallbackKey'] as String;
        String? resolvedUrl = dynamicUrls.firstWhere(
          (u) => u.contains(prefKey) || u.contains(fallKey),
          orElse: () => '',
        );

        if (resolvedUrl.isNotEmpty) {
          try {
            final res = await _client.get(Uri.parse(resolvedUrl), headers: headers);
            if (res.statusCode >= 200 && res.statusCode < 300 && res.body.length > 50) {
              csvBody = res.body;
            }
          } catch (_) {}
        }

        // If not found or failed, try candidate dates
        if (csvBody == null) {
          final directPathBuilder =
              config['directPath'] as String Function(String);
          for (final dateStr in candidateDates) {
            try {
              final url = Uri.parse(directPathBuilder(dateStr));
              final res = await _client.get(url, headers: headers);
              if (res.statusCode >= 200 && res.statusCode < 300 && res.body.length > 50) {
                csvBody = res.body;
                break;
              }
            } catch (_) {}
          }
        }

        if (csvBody != null && csvBody.isNotEmpty) {
          onProgress?.call('Parsing $label in background isolate…');
          final parsed = await compute(
            _parseCsvWorker,
            {
              'csvContent': csvBody,
              'segment': segment,
              'exchange': exchange,
              'isDerivative': isDerivative,
            },
          );

          if (parsed.isNotEmpty) {
            anySegmentSucceeded = true;
            allParsedScrips.addAll(parsed.map((m) => Scrip.fromMap(m)));
          }
        } else {
          debugPrint('ScripMaster: Could not fetch CSV for $segment');
        }
      }

      // If downloads or parsing completely failed: keep existing database unchanged
      if (!anySegmentSucceeded || allParsedScrips.isEmpty) {
        return ScripSyncResult(
          success: false,
          message: 'Refresh failed: Unable to download Scrip Master. Existing data kept unchanged.',
          error: 'Network or server error downloading segment files.',
        );
      }

      // Requirement 4: Replace old data with new data in a single SQLite transaction
      onProgress?.call('Saving ${allParsedScrips.length} instruments to local database…');
      await AppDb.instance.replaceScripsAtomically(allParsedScrips);

      // Calculate categorized counts
      int stocksCount = 0;
      int futuresCount = 0;
      int optionsCount = 0;
      int commodityCount = 0;

      for (final s in allParsedScrips) {
        if (s.segment == 'mcx_fo') {
          commodityCount++;
        } else if (s.instrumentType == 'EQ') {
          stocksCount++;
        } else if (s.instrumentType == 'FUT') {
          futuresCount++;
        } else if (s.instrumentType == 'CE' || s.instrumentType == 'PE') {
          optionsCount++;
        }
      }

      final now = DateTime.now();
      final timeStr =
          '${now.day.toString().padLeft(2, "0")} ${_monthName(now.month)} ${now.year}, ${_formatTime(now)}';
      final summary =
          'Instruments updated: $timeStr — Stocks: $stocksCount, Futures: $futuresCount, Options: $optionsCount, Commodity: $commodityCount';

      await _storage.write(key: _keyLastUpdated, value: summary);
      await _storage.write(key: _keyLastDate, value: today);

      return ScripSyncResult(
        success: true,
        message: summary,
        stocksCount: stocksCount,
        futuresCount: futuresCount,
        optionsCount: optionsCount,
        commodityCount: commodityCount,
      );
    } catch (e) {
      debugPrint('ScripMaster sync error: $e');
      return ScripSyncResult(
        success: false,
        message: 'Refresh error: $e. Existing database kept unchanged.',
        error: e.toString(),
      );
    }
  }

  /// Attempts to call the dynamic file-paths endpoint if available
  Future<List<String>> _fetchDynamicFilePaths() async {
    final baseUrl = KotakApi.instance.baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return [];

    try {
      final uri = Uri.parse('$baseUrl/script-details/1.0/masterscrip/file-paths');
      final headers = {
        if (KotakApi.instance.accessToken != null)
          'Authorization': KotakApi.instance.accessToken!,
        'neo-fin-key': KotakApi.neoFinKey,
      };

      final res = await _client.get(uri, headers: headers);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map && decoded['filesPaths'] is List) {
          return List<String>.from(decoded['filesPaths'] as List);
        }
      }
    } catch (_) {}
    return [];
  }

  /// Returns recent candidate date strings (YYYY-MM-DD) for trading day fallback
  List<String> _getCandidateDates() {
    final dates = <String>[];
    final now = DateTime.now();
    for (int i = 0; i < 5; i++) {
      final dt = now.subtract(Duration(days: i));
      dates.add(dt.toIso8601String().substring(0, 10));
    }
    return dates;
  }

  static String _formatTime(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  static String _monthName(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return (month >= 1 && month <= 12) ? months[month - 1] : '';
  }
}

/// Standalone top-level worker for [compute] isolate execution
List<Map<String, dynamic>> _parseCsvWorker(Map<String, dynamic> params) {
  final csvContent = params['csvContent'] as String;
  final segment = params['segment'] as String;
  final exchange = params['exchange'] as String;
  final isDerivative = params['isDerivative'] as bool;

  final lines = const LineSplitter().convert(csvContent);
  if (lines.length <= 1) return [];

  // Parse header
  final headerRow = _parseCsvLine(lines.first);
  final headerMap = <String, int>{};
  for (int i = 0; i < headerRow.length; i++) {
    headerMap[headerRow[i].trim()] = i;
  }

  String getField(List<String> row, List<String> candidates) {
    for (final col in candidates) {
      final idx = headerMap[col];
      if (idx != null && idx < row.length) {
        final val = row[idx].trim();
        if (val.isNotEmpty) return val;
      }
    }
    return '';
  }

  final results = <Map<String, dynamic>>[];

  for (int i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    final row = _parseCsvLine(line);
    if (row.isEmpty) continue;

    final token = getField(row, ['pSymbol', 'lToken', 'token']);
    if (token.isEmpty) continue;

    final rawSymbol = getField(row, ['pTrdSymbol', 'pSymbolName', 'symbol']);
    final rawName = getField(row, ['pDesc', 'pCompany', 'company_name', 'name']);
    final underlying = getField(row, ['pSymbolName', 'underlying']);
    final instName = getField(row, ['pInstName', 'instrument_type']);
    final optionTypeField = getField(row, ['pOptionType', 'opt_type']);
    final strikeStr = getField(row, ['dStrikePrice', 'strike']);
    final expiryStr = getField(row, ['lExpiryDate', 'expiry']);
    final lotSizeStr = getField(row, ['lLotSize', 'lot_size']);
    final tickSizeStr = getField(row, ['dTickSize', 'tick_size']);

    String instrumentType = 'EQ';
    double? strike;
    String? expiry;

    if (isDerivative) {
      if (instName.contains('FUT') || rawSymbol.endsWith('FUT')) {
        instrumentType = 'FUT';
      } else if (instName.contains('OPT') ||
          optionTypeField.isNotEmpty ||
          rawSymbol.endsWith('CE') ||
          rawSymbol.endsWith('PE')) {
        if (optionTypeField == 'PE' || rawSymbol.endsWith('PE')) {
          instrumentType = 'PE';
        } else {
          instrumentType = 'CE';
        }

        if (strikeStr.isNotEmpty) {
          final sVal = double.tryParse(strikeStr.replaceAll(',', ''));
          if (sVal != null && sVal > 0) strike = sVal;
        }
      }

      if (expiryStr.isNotEmpty) {
        expiry = expiryStr;
      }
    }

    final lotSize = int.tryParse(lotSizeStr.replaceAll(',', '')) ?? (isDerivative ? 25 : 1);
    final tickSize = double.tryParse(tickSizeStr.replaceAll(',', '')) ?? 0.05;

    results.add({
      'token': token,
      'symbol': rawSymbol.isNotEmpty ? rawSymbol : token,
      'display_name': rawName.isNotEmpty ? rawName : rawSymbol,
      'segment': segment,
      'exchange': exchange,
      'instrument_type': instrumentType,
      'underlying': underlying.isNotEmpty ? underlying : null,
      'expiry': expiry,
      'strike': strike,
      'lot_size': lotSize,
      'tick_size': tickSize,
    });
  }

  return results;
}

/// Simple CSV line splitter handling comma separation and quotes
List<String> _parseCsvLine(String line) {
  final values = <String>[];
  final sb = StringBuffer();
  bool inQuotes = false;

  for (int i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      inQuotes = !inQuotes;
    } else if (char == ',' && !inQuotes) {
      values.add(sb.toString().trim());
      sb.clear();
    } else {
      sb.write(char);
    }
  }
  values.add(sb.toString().trim());
  return values;
}
