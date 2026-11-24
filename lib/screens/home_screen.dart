import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/more/more_screen.dart';
import 'package:hjdev_trading/screens/practice/practice_screen.dart';
import 'package:hjdev_trading/screens/signals/signals_screen.dart';
import 'package:hjdev_trading/screens/watchlists/watchlists_screen.dart';
import 'package:hjdev_trading/services/index_feed_service.dart';
import 'package:hjdev_trading/services/kotak_api.dart';
import 'package:hjdev_trading/services/pending_order_engine.dart';

/// App shell: restores today's session, then shows five bottom
/// tabs — Watchlist, Orders, Portfolio, Signals and More. Orders
/// and Portfolio are the two pages of the Practice screen (this
/// shell owns its tab controller so the bottom bar can open it on
/// either page); the virtual Funds and the Kotak Login live under
/// More.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  // Bottom-bar selection (0..4) and the page it maps to (0..3):
  // Orders and Portfolio share the Practice page.
  int _navIndex = 0;
  int _pageIndex = 0;
  bool _isLoading = true;
  bool _isLoggedIn = false;

  late final TabController _practiceTabs;

  @override
  void initState() {
    super.initState();
    _practiceTabs = TabController(length: 2, vsync: this);
    // Swiping between Orders / Portfolio inside Practice moves the
    // bottom-bar highlight with it.
    _practiceTabs.addListener(_syncNavWithPracticeTab);
    _checkSession();
    // The pending-order engine watches price/time triggers and
    // armed targets for as long as the app is open.
    PendingOrderEngine.instance.start();
  }

  @override
  void dispose() {
    _practiceTabs.removeListener(_syncNavWithPracticeTab);
    _practiceTabs.dispose();
    super.dispose();
  }

  void _syncNavWithPracticeTab() {
    if (_pageIndex != 1) return;
    final nav = _practiceTabs.index == 0 ? 1 : 2;
    if (nav != _navIndex) setState(() => _navIndex = nav);
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
      _pageIndex = 0; // jump to watchlist
      _navIndex = 0;
    });
  }

  Future<void> _onLogout() async {
    IndexFeedService.instance.disconnect();
    await KotakApi.instance.deleteSavedSession();
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _pageIndex = 3; // go to More, where Login lives now
      _navIndex = 4;
    });
  }

  void _onNavTap(int index) {
    setState(() {
      _navIndex = index;
      switch (index) {
        case 0:
          _pageIndex = 0;
          break;
        case 1:
          _pageIndex = 1;
          _practiceTabs.animateTo(0); // Orders
          break;
        case 2:
          _pageIndex = 1;
          _practiceTabs.animateTo(1); // Portfolio
          break;
        case 3:
          _pageIndex = 2;
          break;
        case 4:
          _pageIndex = 3;
          break;
      }
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
              CircularProgressIndicator(color: Color(0xFF387ED1)),
              SizedBox(height: 16),
              Text(
                'Checking session...',
                style: TextStyle(color: Color(0xFF666666)),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _pageIndex,
        children: [
          WatchlistsScreen(
            isLoggedIn: _isLoggedIn,
            onLogout: _onLogout,
          ),
          PracticeScreen(controller: _practiceTabs),
          const SignalsScreen(),
          MoreScreen(
            onLoginSuccess: _onLoginSuccess,
            onLogout: _onLogout,
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFFE0E0E0), width: 0.5),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _navIndex,
          onTap: _onNavTap,
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFF387ED1),
          unselectedItemColor: const Color(0xFF666666),
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.show_chart),
              label: 'Watchlist',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.receipt_long),
              label: 'Orders',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.pie_chart),
              label: 'Portfolio',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.insights),
              label: 'Signals',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.more_horiz),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
