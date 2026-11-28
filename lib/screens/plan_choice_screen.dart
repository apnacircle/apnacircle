import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/billing_service.dart';
import '../services/onboarding_service.dart';
import '../services/trial_service.dart';
import 'plan_screen.dart';

/// Parent-only first-run screen (v0.6.30): trial ya payment?
/// Shown ONCE, right after the parent picks their role — before
/// the Gmail login. A child NEVER sees this screen.
///
/// * "7-day FREE trial" — starts the once-per-phone trial and
///   continues to the login.
/// * "Subscribe — \$5/year" — opens the full Plan screen (real
///   Play Billing; until the product exists in Play Console the
///   store says "product not found" and nothing is charged).
///   A "Continue" button there moves on to the login.
/// * "Baad mein" — skips the choice; the Plan tab stays available
///   in the app. The app has no paid-plan gate today, so nothing
///   is locked by skipping.
class PlanChoiceScreen extends StatelessWidget {
  const PlanChoiceScreen({super.key});

  Future<void> _startTrial(BuildContext context) async {
    final ok =
        await context.read<TrialService>().startTrial();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '7-day free trial shuru ho gaya.'
            : 'Is phone par trial pehle hi use ho chuka hai.'),
      ),
    );
    await context.read<OnboardingService>().markPlanChoiceDone();
  }

  Future<void> _skip(BuildContext context) async {
    await context.read<OnboardingService>().markPlanChoiceDone();
  }

  @override
  Widget build(BuildContext context) {
    final trial = context.watch<TrialService>();
    final billing = context.watch<BillingService>();
    final canTrial = trial.canStartTrial && !billing.isSubscribed;
    return Scaffold(
      // v0.6.31: back to the role screen — a parent who tapped
      // the wrong role (or a child who meant to be a parent)
      // can undo it here instead of being stuck.
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Wapas — role badlein',
          onPressed: () =>
              context.read<OnboardingService>().clearRole(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Family plan',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '\$5 / saal — poori family (max 10 members). '
                'Payment sirf parent karta hai.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: canTrial ? () => _startTrial(context) : null,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('7-day FREE trial shuru karein',
                      style: TextStyle(fontSize: 18)),
                ),
              ),
              if (!canTrial)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Is phone par trial pehle hi use ho chuka hai — '
                    'trial sirf ek dafa milta hai.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const _PlanSubscribePage(),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('Subscribe — \$5/year',
                      style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _skip(context),
                child: const Text('Baad mein — abhi aage badhein'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full Plan screen (trial card + payment methods + real
/// Play Billing subscribe button) with a Continue button that
/// moves the parent on to the Gmail login. Nothing is charged
/// until the store confirms a purchase.
class _PlanSubscribePage extends StatelessWidget {
  const _PlanSubscribePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscribe — Family plan')),
      body: Column(
        children: [
          const Expanded(child: PlanScreen()),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  await context
                      .read<OnboardingService>()
                      .markPlanChoiceDone();
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Continue — Gmail se login karein',
                      style: TextStyle(fontSize: 17)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
