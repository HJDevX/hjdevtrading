import 'package:flutter_test/flutter_test.dart';
import 'package:hjdev_trading/main.dart';

void main() {
  testWidgets('App smoke test - verifies tabs and PAPER badge', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Watchlists'), findsWidgets);
    expect(find.text('Kotak Login'), findsOneWidget);
    expect(find.text('PAPER'), findsOneWidget);
  });
}
