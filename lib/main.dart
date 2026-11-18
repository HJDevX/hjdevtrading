import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/home_screen.dart';
import 'package:hjdev_trading/utils/app_sizes.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HJDev Trading',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
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
