import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hjdev_trading/services/kotak_api.dart';

class KotakLoginScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;

  const KotakLoginScreen({super.key, this.onLoginSuccess});

  @override
  State<KotakLoginScreen> createState() => _KotakLoginScreenState();
}

class _KotakLoginScreenState extends State<KotakLoginScreen> {
  final KotakApi _api = KotakApi.instance;

  // Controllers
  final TextEditingController _accessTokenController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _uccController = TextEditingController();
  final TextEditingController _totpController = TextEditingController();
  final TextEditingController _mpinController = TextEditingController();

  // State
  int _stage = 1; // 1 = Step A (TOTP), 2 = Step B (MPIN)
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscureAccessToken = true;
  bool _obscureMpin = true;

  @override
  void initState() {
    super.initState();
    _loadSavedProfile();
    KotakApi.sessionExpiredNotifier.addListener(_onSessionExpired);
  }

  @override
  void dispose() {
    KotakApi.sessionExpiredNotifier.removeListener(_onSessionExpired);
    _accessTokenController.dispose();
    _mobileController.dispose();
    _uccController.dispose();
    _totpController.dispose();
    _mpinController.dispose();
    super.dispose();
  }

  void _onSessionExpired() {
    final msg = KotakApi.sessionExpiredNotifier.value;
    if (msg != null && mounted) {
      setState(() {
        _stage = 1;
        _errorMessage = msg;
        _totpController.clear();
        _mpinController.clear();
      });
    }
  }

  Future<void> _loadSavedProfile() async {
    final profile = await _api.loadSavedProfile();
    if (mounted) {
      setState(() {
        if (profile['accessToken']?.isNotEmpty ?? false) {
          _accessTokenController.text = profile['accessToken']!;
        }
        if (profile['mobileNumber']?.isNotEmpty ?? false) {
          _mobileController.text = profile['mobileNumber']!;
        } else {
          _mobileController.text = '+91';
        }
        if (profile['ucc']?.isNotEmpty ?? false) {
          _uccController.text = profile['ucc']!;
        }
        // TOTP and MPIN always start blank
        _totpController.clear();
        _mpinController.clear();
      });
    }
  }

  // --- Step 1: Verify TOTP ---
  Future<void> _handleStep1() async {
    final token = _accessTokenController.text.trim();
    final mobile = _mobileController.text.trim();
    final ucc = _uccController.text.trim().toUpperCase();
    final totp = _totpController.text.trim();

    if (token.isEmpty || mobile.isEmpty || ucc.isEmpty || totp.isEmpty) {
      setState(() {
        _errorMessage = 'Please fill in all fields (Token, Mobile, UCC, TOTP).';
      });
      return;
    }

    if (totp.length != 6) {
      setState(() {
        _errorMessage = 'TOTP must be exactly 6 digits.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Save token, mobile, ucc to secure storage
      await _api.saveProfile(
        accessToken: token,
        mobileNumber: mobile,
        ucc: ucc,
      );

      // 2. Call Login Step A
      await _api.tradeApiLogin(
        accessToken: token,
        mobileNumber: mobile,
        ucc: ucc,
        totp: totp,
      );

      if (mounted) {
        setState(() {
          _stage = 2; // Transition to Stage 2
          _isLoading = false;
          _errorMessage = null;
          _mpinController.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  // --- Step 2: Login with MPIN ---
  Future<void> _handleStep2() async {
    final mpin = _mpinController.text.trim();

    if (mpin.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your 6-digit MPIN.';
      });
      return;
    }

    if (mpin.length != 6) {
      setState(() {
        _errorMessage = 'MPIN must be exactly 6 digits.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _api.tradeApiValidate(mpin: mpin);

      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
          _totpController.clear();
          _mpinController.clear();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Logged in successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );

        // Switch to Watchlists tab
        widget.onLoginSuccess?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _handleLogout() async {
    await _api.deleteSavedSession();
    if (mounted) {
      setState(() {
        _stage = 1;
        _totpController.clear();
        _mpinController.clear();
        _errorMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logged out of Kotak Neo.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = _api.isLoggedIn;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Active session banner if already logged in
            if (isLoggedIn) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(25),
                  border: Border.all(color: Colors.green.shade400),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Logged In',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            'Client: ${_api.ucc ?? "Active"}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _handleLogout,
                      child: const Text('Logout'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Stage Header
            Text(
              _stage == 1 ? 'Step 1: Neo Trade API Credentials' : 'Step 2: Enter MPIN',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              _stage == 1
                  ? 'Access Token, Mobile, and UCC will be saved securely. Enter daily TOTP.'
                  : 'Enter your 6-digit MPIN to complete the session login.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 20),

            // --- STAGE 1 FIELDS ---
            if (_stage == 1) ...[
              // Access Token
              TextField(
                controller: _accessTokenController,
                obscureText: _obscureAccessToken,
                decoration: InputDecoration(
                  labelText: 'Access Token *',
                  hintText: 'Enter Kotak Neo Access Token',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureAccessToken
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureAccessToken = !_obscureAccessToken;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Mobile Number
              TextField(
                controller: _mobileController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Mobile Number *',
                  hintText: '+91XXXXXXXXXX',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone_android_outlined),
                ),
              ),
              const SizedBox(height: 14),

              // UCC (Client Code)
              TextField(
                controller: _uccController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'UCC (Client Code) *',
                  hintText: 'e.g. AB1234',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 14),

              // TOTP
              TextField(
                controller: _totpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Daily TOTP (6 Digits) *',
                  hintText: '123456',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_clock_outlined),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 20),

              // Button Step 1
              FilledButton(
                onPressed: _isLoading ? null : _handleStep1,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Step 1 — Verify TOTP',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ],

            // --- STAGE 2 FIELDS ---
            if (_stage == 2) ...[
              // Summary chip of verified credentials
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Verified ${_uccController.text} (${_mobileController.text})',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _stage = 1;
                          _errorMessage = null;
                        });
                      },
                      child: const Text('Edit'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // MPIN
              TextField(
                controller: _mpinController,
                obscureText: _obscureMpin,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'MPIN (6 Digits) *',
                  hintText: '******',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.password_outlined),
                  counterText: '',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureMpin
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureMpin = !_obscureMpin;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Button Step 2
              FilledButton(
                onPressed: _isLoading ? null : _handleStep2,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Step 2 — Login',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ],

            // Red error text under button
            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
