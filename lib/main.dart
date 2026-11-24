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
      // Zerodha Kite theme: pure white surfaces, #f7f7f7 panels,
      // #424242 text, #666666 secondary text, Kite blue #387ed1,
      // hairline dividers, 4px corners, no shadows. Green/red are
      // used only for P&L and price movement. (The Open Sans font
      // files are not bundled yet, so the family name is set and
      // the system font is used until they are added.)
      theme: ThemeData(
        brightness: Brightness.light,
        fontFamily: 'Open Sans',
        fontFamilyFallback: const ['Roboto', 'sans-serif'],
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF387ED1),
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: Color(0xFF424242),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF424242),
          elevation: 0,
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE0E0E0),
          thickness: 0.5,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ),
        tabBarTheme: const TabBarThemeData(
          indicatorColor: Color(0xFF387ED1),
          labelColor: Color(0xFF424242),
          unselectedLabelColor: Color(0xFF666666),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(color: Color(0xFF666666)),
          hintStyle: TextStyle(color: Color(0xFF9B9B9B)),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Color(0xFF387ED1),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
