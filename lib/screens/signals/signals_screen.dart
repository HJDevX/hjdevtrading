import 'package:flutter/material.dart';

/// SIGNALS tab — the user's four backtested JK Paper signs,
/// pre-loaded as Sign 01–04 exactly as tested (3 years of hourly
/// data, ₹1,50,000 per trade, paper only). This screen is a
/// reference card: it places NO trades. The signal engine and the
/// in-app Signal Builder arrive in a later step; until then the
/// daily 10:15 check stays manual, exactly as it is today.
class SignalsScreen extends StatelessWidget {
  const SignalsScreen({super.key});

  static const Color _text = Color(0xFF424242);
  static const Color _secondary = Color(0xFF666666);
  static const Color _hint = Color(0xFF9B9B9B);
  static const Color _blue = Color(0xFF387ED1);
  static const Color _panel = Color(0xFFF7F7F7);
  static const Color _hairline = Color(0xFFE0E0E0);
  static const Color _green = Color(0xFF00C853);
  static const Color _red = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Signals',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const Text(
            'Your 4 proven signs — backtested on 3 years of JK Paper '
            'data, ₹1,50,000 per trade, paper only. Entry 10:15 AM, '
            'hard exit 3:00 PM. A sample this size is proven '
            'profitable, not a guarantee.',
            style: TextStyle(color: _secondary, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          _signCard(
            tag: 'SIGN 01',
            name: 'Strong Gap-Up (base)',
            side: 'BUY',
            rule: 'Open ≥ +0.7% vs previous close AND still above '
                'the open at 10:15 → BUY at 10:15.',
            proof: '59 trades in 3 years • 66% targets • net +₹11,292',
          ),
          _signCard(
            tag: 'SIGN 02',
            name: 'Gap-Up After a Red Day',
            side: 'BUY',
            rule: 'Same as Sign 01, plus the previous day was red.',
            proof: '31 trades in 3 years • 71% targets • net +₹9,829',
          ),
          _signCard(
            tag: 'SIGN 03',
            name: 'Extreme Weak Morning',
            side: 'SHORT',
            rule: 'First-hour fall ≤ −1.5 sigma of its own 20-day '
                'distribution (practical line: −2.2% by 10:15) → SHORT.',
            proof: '59 trades in 3 years • 66% targets • net +₹14,555',
          ),
          _signCard(
            tag: 'SIGN 04',
            name: 'NR7 Squeeze → Gap-Up',
            side: 'BUY',
            rule: 'Yesterday was NR7 (narrowest range in 7 days) '
                '+ gap ≥ +0.3% + still green at 10:15 → BUY.',
            proof: '19 trades in 3 years • 74% targets • net +₹5,750',
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _hairline),
            ),
            child: const Text(
              'FFU Fade is a supporting filter only — not a '
              'standalone sign. Default frame on every sign: '
              'TP +0.65%, SL −0.80%, exit 3:00 PM.',
              style: TextStyle(color: _secondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'The signal engine and Signal Builder come in a later '
            'step. Nothing on this screen places trades.',
            style: TextStyle(color: _hint, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _signCard({
    required String tag,
    required String name,
    required String side,
    required String rule,
    required String proof,
  }) {
    final buy = side == 'BUY';
    final sideColor = buy ? _blue : _red;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(tag,
                  style: const TextStyle(
                      color: _blue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: sideColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(side,
                    style: TextStyle(
                        color: sideColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(name,
              style: const TextStyle(
                  color: _text,
                  fontSize: 15,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(rule,
              style: const TextStyle(color: _secondary, fontSize: 12.5)),
          const SizedBox(height: 8),
          Text(proof,
              style: const TextStyle(
                  color: _green,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
