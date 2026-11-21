import 'package:flutter/material.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

/// Kotak Neo login — the official 2-step flow:
///  Step A: Access Token + Mobile + UCC + TOTP  -> view token + sid
///  Step B: MPIN                                  -> session for the day
///
/// The profile (token / mobile / UCC) is saved once in secure storage.
/// TOTP and MPIN are NEVER saved. A successful session is kept for the
/// rest of the day (IST) and restored automatically on app start.
class KotakLoginScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;
  final VoidCallback? onLogout;

  const KotakLoginScreen({super.key, this.onLoginSuccess, this.onLogout});

  @override
  State<KotakLoginScreen> createState() => _KotakLoginScreenState();
}

class _KotakLoginScreenState extends State<KotakLoginScreen> {
  final _api = KotakApi.instance;

  final _tokenCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _uccCtrl = TextEditingController();
  final _totpCtrl = TextEditingController();
  final _mpinCtrl = TextEditingController();

  bool _loadingProfile = true;
  bool _isVerifyingTotp = false;
  bool _isLoggingIn = false;
  bool _showMpinField = false;
  bool _isLoggedIn = false;
  String? _viewToken;
  String? _viewSid;
  String? _greetingName;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _mobileCtrl.dispose();
    _uccCtrl.dispose();
    _totpCtrl.dispose();
    _mpinCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    await _api.loadSavedProfile();
    if (!mounted) return;
    setState(() {
      _tokenCtrl.text = _api.accessToken ?? '';
      _mobileCtrl.text = _api.mobileNumber ?? '';
      _uccCtrl.text = _api.ucc ?? '';
      _isLoggedIn = _api.isLoggedIn;
      _greetingName = _api.greetingName;
      _loadingProfile = false;
    });
  }

  Future<void> _handleVerifyTotp() async {
    final token = _tokenCtrl.text.trim();
    final mobile = _mobileCtrl.text.trim();
    final ucc = _uccCtrl.text.trim();
    final totp = _totpCtrl.text.trim();

    if (token.isEmpty || mobile.isEmpty || ucc.isEmpty) {
      setState(() => _error = 'Please fill Access Token, Mobile and UCC');
      return;
    }
    if (totp.length != 6) {
      setState(() => _error = 'TOTP must be 6 digits (from your Kotak Neo app)');
      return;
    }

    setState(() {
      _isVerifyingTotp = true;
      _error = null;
    });

    try {
      await _api.saveProfile(
          accessToken: token, mobileNumber: mobile, ucc: ucc);
      final res = await _api.tradeApiLogin(totp: totp);
      final data = res['data'] as Map<String, dynamic>?;
      final viewToken = data?['token']?.toString();
      final viewSid = data?['sid']?.toString();

      if (viewToken == null || viewSid == null) {
        throw Exception('Token or SID missing in Kotak response');
      }
      if (!mounted) return;
      setState(() {
        _viewToken = viewToken;
        _viewSid = viewSid;
        _showMpinField = true;
        _isVerifyingTotp = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('TOTP verified — now enter your MPIN')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isVerifyingTotp = false;
      });
    }
  }

  Future<void> _handleLogin() async {
    final mpin = _mpinCtrl.text.trim();
    if (mpin.length < 4) {
      setState(() => _error = 'Please enter your MPIN');
      return;
    }
    if (_viewToken == null || _viewSid == null) {
      setState(() => _error = 'Please verify TOTP first');
      return;
    }

    setState(() {
      _isLoggingIn = true;
      _error = null;
    });

    try {
      await _api.tradeApiValidate(
        viewToken: _viewToken!,
        viewSid: _viewSid!,
        mpin: mpin,
      );
      if (!_api.isLoggedIn) {
        throw Exception('Session not created — please try again');
      }
      if (!mounted) return;
      setState(() {
        _isLoggedIn = true;
        _greetingName = _api.greetingName;
        _isLoggingIn = false;
        _showMpinField = false;
        _mpinCtrl.clear();
        _totpCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_greetingName != null
              ? 'Welcome, $_greetingName'
              : 'Logged in successfully'),
          backgroundColor: Colors.green.shade700,
        ),
      );
      widget.onLoginSuccess?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isLoggingIn = false;
      });
    }
  }

  Future<void> _handleLogout() async {
    widget.onLogout?.call();
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _greetingName = null;
      _showMpinField = false;
      _viewToken = null;
      _viewSid = null;
    });
  }

  InputDecoration _dec(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: const Color(0xFF161B22),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingProfile) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kotak Neo Login',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isLoggedIn) _buildLoggedInCard(),
            if (!_isLoggedIn) ...[
              const Text(
                'Step A — Profile + TOTP',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Profile is saved once on this phone. TOTP and MPIN are never saved.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tokenCtrl,
                decoration: _dec('Kotak Access Token', Icons.key),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _mobileCtrl,
                decoration: _dec('Mobile Number (+91...)', Icons.phone),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _uccCtrl,
                decoration: _dec('UCC (Client Code)', Icons.badge),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _totpCtrl,
                decoration: _dec('TOTP (6 digits)', Icons.pin),
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isVerifyingTotp ? null : _handleVerifyTotp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2962FF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _isVerifyingTotp
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Verify TOTP',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold)),
              ),
              if (_showMpinField) ...[
                const SizedBox(height: 24),
                const Text(
                  'Step B — MPIN',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _mpinCtrl,
                  decoration: _dec('MPIN', Icons.lock),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _isLoggingIn ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _isLoggingIn
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('Login',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withAlpha(90)),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoggedInCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withAlpha(90)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 44),
          const SizedBox(height: 10),
          Text(
            _greetingName != null ? 'Welcome, $_greetingName' : 'Logged in',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Session stays active for today. Tomorrow, login again with a fresh TOTP + MPIN.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _handleLogout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Logout'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}
