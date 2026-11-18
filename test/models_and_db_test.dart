import 'package:flutter_test/flutter_test.dart';
import 'package:hjdev_trading/models/watchlist.dart';

void main() {
  group('Watchlist & WatchItem Model Tests', () {
    test('Watchlist toMap and fromMap work correctly', () {
      final list = Watchlist(
        id: 1,
        name: 'My First List',
        createdAt: 1700000000,
      );

      final map = list.toMap();
      expect(map['id'], 1);
      expect(map['name'], 'My First List');
      expect(map['created_at'], 1700000000);

      final fromMap = Watchlist.fromMap(map);
      expect(fromMap.id, 1);
      expect(fromMap.name, 'My First List');
      expect(fromMap.createdAt, 1700000000);
    });

    test('WatchItem toMap and fromMap work correctly with defaults', () {
      final item = WatchItem(
        id: 10,
        watchlistId: 1,
        symbol: 'JKPAPER',
        displayName: 'JK Paper Ltd',
      );

      final map = item.toMap();
      expect(map['id'], 10);
      expect(map['watchlist_id'], 1);
      expect(map['symbol'], 'JKPAPER');
      expect(map['exchange'], 'nse_cm');
      expect(map['token'], isNull);
      expect(map['display_name'], 'JK Paper Ltd');

      final fromMap = WatchItem.fromMap(map);
      expect(fromMap.id, 10);
      expect(fromMap.watchlistId, 1);
      expect(fromMap.symbol, 'JKPAPER');
      expect(fromMap.exchange, 'nse_cm');
      expect(fromMap.token, isNull);
      expect(fromMap.displayName, 'JK Paper Ltd');
    });
  });
}
