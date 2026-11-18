import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:hjdev_trading/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App smoke test - verifies tabs and PAPER badge', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Watchlists'), findsWidgets);
    expect(find.text('Kotak Login'), findsOneWidget);
    expect(find.text('PAPER'), findsOneWidget);
  });
}
