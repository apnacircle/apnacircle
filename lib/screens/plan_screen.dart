import 'package:flutter/material.dart';

/// Family plan screen — DISPLAY ONLY in v0.1.
///
/// \$5/year, paid ONLY by the parent, whole family covered, max 10
/// members. Payment methods are SHOWN (Pakistan + international)
/// but NO real payment is charged here. Real charging uses Google
/// Play Billing (in-app subscription) — Play policy requires
/// digital subscriptions to go through Play Billing; JazzCash /
/// Easypaisa cannot be used inside the Play app for the digital
/// plan (see README). That integration is a v0.2 step, after the
/// Play Console account exists.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  static const _pakistanMethods = [
    'JazzCash',
    'Easypaisa',
    'Bank transfer / debit card',
  ];
  static const _internationalMethods = [
    'Visa / Mastercard',
    'Google Play billing',
    'PayPal (where available)',
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Family plan',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('\$5 / year',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('Only the parent pays — whole family covered.'),
                Text('Maximum 10 family members.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Ways to pay',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Pakistan', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final m in _pakistanMethods) ListTile(title: Text(m)),
        const Text('International',
            style: TextStyle(fontWeight: FontWeight.bold)),
        for (final m in _internationalMethods) ListTile(title: Text(m)),
        const SizedBox(height: 8),
        const Text(
          'Demo only — no real payment is taken here. '
          'Play Store fee is \$25 one-time, paid by the parent.',
        ),
      ],
    );
  }
}
