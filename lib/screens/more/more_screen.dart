import 'package:flutter/material.dart';
import 'package:hjdev_trading/screens/login/kotak_login_screen.dart';
import 'package:hjdev_trading/screens/more/funds_screen.dart';
import 'package:hjdev_trading/screens/practice/simulator_screen.dart';
import 'package:hjdev_trading/services/paper_broker.dart';

/// MORE tab — everything that is not a main tab lives here:
/// the virtual Funds (moved out of the bottom bar in the Kite
/// redesign), the replay Simulator, and the Kotak Neo Login.
class MoreScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;
  final VoidCallback? onLogout;

  const MoreScreen({super.key, this.onLoginSuccess, this.onLogout});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  PaperFundInfo? _fund;

  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _blue = Color(0xFF387ED1);

  @override
  void initState() {
    super.initState();
    _loadFund();
    // Keep the Funds row's available figure live, like everywhere
    // else the fund is shown.
    PaperBroker.revisionNotifier.addListener(_loadFund);
  }

  @override
  void dispose() {
    PaperBroker.revisionNotifier.removeListener(_loadFund);
    super.dispose();
  }

  Future<void> _loadFund() async {
    final fund = await PaperBroker.instance.fundInfo();
    if (!mounted) return;
    setState(() => _fund = fund);
  }

  String _fmtMoney(double v) =>
      '${v < 0 ? '-' : ''}₹${v.abs().toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('More',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        children: [
          _row(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Funds',
            subtitle: _fund == null
                ? 'Virtual fund'
                : 'Virtual fund • ${_fmtMoney(_fund!.available)} available',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FundsScreen()),
            ),
          ),
          const Divider(
              color: Color(0xFFE0E0E0), height: 1, indent: 16),
          _row(
            icon: Icons.science_outlined,
            title: 'Replay Simulator',
            subtitle: 'Replay a real past trading day',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SimulatorScreen()),
            ),
          ),
          const Divider(
              color: Color(0xFFE0E0E0), height: 1, indent: 16),
          _row(
            icon: Icons.login,
            title: 'Kotak Neo Login',
            subtitle: 'Session for today • TOTP + MPIN',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => KotakLoginScreen(
                  onLoginSuccess: widget.onLoginSuccess,
                  onLogout: widget.onLogout,
                ),
              ),
            ),
          ),
          const Divider(
              color: Color(0xFFE0E0E0), height: 1, indent: 16),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: _blue, size: 22),
      title: Text(title,
          style: const TextStyle(
              color: _text, fontSize: 14.5, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: _secondary, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right,
          color: Color(0xFF9B9B9B), size: 20),
      onTap: onTap,
    );
  }
}
