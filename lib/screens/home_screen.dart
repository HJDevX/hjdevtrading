import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/watchlists/watchlists_screen.dart';
import 'package:hjdev_trading/screens/login/kotak_login_screen.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _isCheckingSession = true;

  @override
  void initState() {
    super.initState();
    _checkSavedSession();
    KotakApi.sessionExpiredNotifier.addListener(_onSessionExpired);
  }

  @override
  void dispose() {
    KotakApi.sessionExpiredNotifier.removeListener(_onSessionExpired);
    super.dispose();
  }

  Future<void> _checkSavedSession() async {
    final isValid = await KotakApi.instance.restoreSessionIfValid();
    if (mounted) {
      setState(() {
        _currentIndex = isValid ? 0 : 1;
        _isCheckingSession = false;
      });
    }
  }

  void _onSessionExpired() {
    final msg = KotakApi.sessionExpiredNotifier.value;
    if (msg != null && mounted) {
      setState(() {
        _currentIndex = 1; // Return to login screen
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  List<Widget> get _pages => [
    WatchlistsScreen(
      onLogout: () {
        setState(() {
          _currentIndex = 1;
        });
      },
    ),
    KotakLoginScreen(
      onLoginSuccess: () {
        setState(() {
          _currentIndex = 0; // Switch to Watchlists tab
        });
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (_isCheckingSession) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F1216),
        body: Center(
          child: CircularProgressIndicator(
            color: Color(0xFF387ED1),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F1216),
      appBar: _currentIndex == 1
          ? AppBar(
              backgroundColor: const Color(0xFF0F1216),
              elevation: 0,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Kotak Login', style: TextStyle(color: Colors.white)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade800,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'PAPER',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF14171C),
        selectedItemColor: const Color(0xFF387ED1),
        unselectedItemColor: Colors.grey.shade600,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: 'Watchlist',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            label: 'Kotak Login',
          ),
        ],
      ),
    );
  }
}
