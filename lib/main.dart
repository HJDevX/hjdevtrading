import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/home_screen.dart';

void main() {
  runApp(const HJDevTradingApp());
}

class HJDevTradingApp extends StatelessWidget {
  const HJDevTradingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HJDev Trading',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2962FF),
          surface: Color(0xFF161B22),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D1117),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
