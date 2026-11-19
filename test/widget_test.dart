import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/main.dart';
import 'package:hjdev_trading/db/app_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDb.dbName = 'widget_test.db';
    await AppDb.resetDatabase();
    final dbPath = await getDatabasesPath();
    await databaseFactoryFfi.deleteDatabase(p.join(dbPath, AppDb.dbName));
    await AppDb.instance.database;

    final todayIst = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final dateStr =
        '${todayIst.year}-${todayIst.month.toString().padLeft(2, '0')}-${todayIst.day.toString().padLeft(2, '0')}';

    FlutterSecureStorage.setMockInitialValues({
      'scrip_master_last_updated_date': dateStr,
    });
  });

  testWidgets('App smoke test - verifies tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Watchlist'), findsWidgets);
    expect(find.text('Kotak Login'), findsWidgets);
  });
}
