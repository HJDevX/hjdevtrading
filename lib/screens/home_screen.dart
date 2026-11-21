import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/login/kotak_login_screen.dart';
import 'package:hjdev_trading/screens/practice/practice_screen.dart';
import 'package:hjdev_trading/screens/watchlists/watchlists_screen.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

/// App shell: restores today's session, then shows three tabs —
/// Watchlist, Practice (paper trading) and Login.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _isLoading = true;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final restored = await KotakApi.instance.restoreSessionIfValid();
    if (!mounted) return;
    setState(() {
      _isLoggedIn = restored;
      _isLoading = false;
    });
  }

  void _onLoginSuccess() {
    setState(() {
      _isLoggedIn = true;
      _currentIndex = 0; // jump to watchlist
    });
  }

  Future<void> _onLogout() async {
    IndexFeedService.instance.disconnect();
    await KotakApi.instance.deleteSavedSession();
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _currentIndex = 2; // go to login tab
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF2962FF)),
              SizedBox(height: 16),
              Text(
                'Checking session...',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          WatchlistsScreen(
            isLoggedIn: _isLoggedIn,
            onLogout: _onLogout,
          ),
          const PracticeScreen(),
          KotakLoginScreen(
            onLoginSuccess: _onLoginSuccess,
            onLogout: _onLogout,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        backgroundColor: const Color(0xFF161B22),
        selectedItemColor: const Color(0xFF2962FF),
        unselectedItemColor: Colors.white54,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Watchlist',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.model_training),
            label: 'Practice',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.login),
            label: 'Login',
          ),
        ],
      ),
    );
  }
}
