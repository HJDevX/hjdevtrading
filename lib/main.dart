import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/home_screen.dart';
import 'package:hjdev_trading/utils/app_sizes.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HJDev Trading',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1216),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF387ED1),
          surface: Color(0xFF16191E),
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1216),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF387ED1),
          surface: Color(0xFF16191E),
        ),
      ),
      builder: (context, child) {
        AppSizes.init(context);
        return child ?? const SizedBox.shrink();
      },
      home: const HomeScreen(),
    );
  }
}
