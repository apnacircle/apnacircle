import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../models/trial.dart';
import '../services/billing_service.dart';
import '../services/trial_service.dart';

/// Family plan screen.
///
/// \$5/year, paid ONLY by the parent, whole family covered, max 10
/// members. Payment methods are SHOWN (Pakistan + international)
/// but NO real payment is charged here except through Google Play
/// Billing (v0.5): the Subscribe button starts the real store
/// flow. Until the product exists in Play Console the store says
/// "product not found" and the screen says so honestly — a charge
/// is never faked and a purchase is never claimed without the
/// store confirming it.
///
/// 7-day free trial (22 Nov 2026): the parent taps "Start 7-day
/// free trial" once. The trial is ONCE PER PHONE (23 Nov 2026),
/// keyed by the hashed Android ID in the Realtime Database
/// (TrialService) in synced mode, or in local SharedPreferences
/// in demo mode. Reinstalling, or a new account on the same phone,
/// cannot restart it. After expiry the screen says so plainly and
/// asks to subscribe — the circle and its data are NOT deleted, and
/// no feature is silently locked by this screen (the app has no
/// paid-plan gate today).
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
    final lang = context.watch<LanguageService>();
    final trial = context.watch<TrialService>();
    final billing = context.watch<BillingService>();
    String t(String key) => tr(lang.isUrdu, key);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('plan'),
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(t('planPrice'),
                    style: const TextStyle(
                        fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(t('planPaidByParent')),
                Text(t('maxMembers')),
                if (billing.isSubscribed) ...[
                  const SizedBox(height: 8),
                  Text(
                    t('subscribed'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _trialCard(context, trial, billing, t),
        const SizedBox(height: 16),
        Text(t('paymentMethods'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(t('pakistan'), style: const TextStyle(fontWeight: FontWeight.bold)),
        for (final m in _pakistanMethods) ListTile(title: Text(m)),
        Text(t('international'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        for (final m in _internationalMethods) ListTile(title: Text(m)),
        const SizedBox(height: 8),
        Text(t('noRealPayment')),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => billing.restorePurchases(),
          child: Text(t('restorePurchases')),
        ),
      ],
    );
  }

  Widget _trialCard(
    BuildContext context,
    TrialService trial,
    BillingService billing,
    String Function(String) t,
  ) {
    final status = trial.status;
    final endsAt = trial.state.endsAt;
    final endDate = endsAt == null
        ? '—'
        : DateFormat.yMMMd().format(endsAt);

    return Card(
      color: status == TrialStatus.expired
          ? Colors.orange.shade50
          : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('trialTitle'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (status == TrialStatus.notStarted) ...[
              Text(t('trialNotStarted')),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _startTrial(context, trial, t),
                child: Text(t('startTrial')),
              ),
              const SizedBox(height: 8),
              _subscribeButton(context, billing, t, filled: false),
            ] else if (status == TrialStatus.active) ...[
              Text(t('trialActive'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '${trial.daysRemaining} ${t('daysLeft')}',
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold),
              ),
              Text('${t('trialEndsOn')} $endDate'),
              const SizedBox(height: 12),
              _subscribeButton(context, billing, t, filled: false),
            ] else ...[
              Text(t('trialExpired'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(t('trialExpiredNote')),
              const SizedBox(height: 12),
              _subscribeButton(context, billing, t, filled: true),
            ],
          ],
        ),
      ),
    );
  }

  /// The Subscribe button, wired to real Play Billing (v0.5).
  /// Every store state is shown honestly: a missing product or
  /// an unavailable store is a message, never a fake charge.
  Widget _subscribeButton(
    BuildContext context,
    BillingService billing,
    String Function(String) t, {
    required bool filled,
  }) {
    if (billing.isSubscribed) {
      return FilledButton(
        onPressed: null,
        child: Text(t('subscribed')),
      );
    }
    final label = billing.status == BillingStatus.purchasePending
        ? t('billingPending')
        : t('buyNow');
    final onPressed = billing.status == BillingStatus.loading ||
            billing.status == BillingStatus.purchasePending
        ? null
        : () => _onSubscribe(context, billing, t);
    final button = filled
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label));
    return button;
  }

  Future<void> _onSubscribe(
    BuildContext context,
    BillingService billing,
    String Function(String) t,
  ) async {
    switch (billing.status) {
      case BillingStatus.unavailable:
        _showMessage(context, t('billingNotAvailable'));
        return;
      case BillingStatus.productMissing:
        _showMessage(context, t('billingProductMissing'));
        return;
      case BillingStatus.error:
        _showMessage(context, billing.error ?? t('billingError'));
        return;
      case BillingStatus.loading:
      case BillingStatus.purchasePending:
      case BillingStatus.purchased:
        return;
      case BillingStatus.ready:
        break;
    }
    final started = await billing.buySubscription();
    if (!context.mounted) return;
    if (!started) {
      _showMessage(context, t('billingError'));
    }
    // On success the purchase stream fires and the screen rebuilds
    // to "Subscribed" — nothing is claimed before the store says so.
  }

  void _showMessage(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _startTrial(
    BuildContext context,
    TrialService trial,
    String Function(String) t,
  ) async {
    final ok = await trial.startTrial();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? t('trialStarted') : t('trialAlreadyUsed')),
      ),
    );
  }
}
