import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../l10n/strings.dart';
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
    final isUrdu = context.read<LanguageService>().isUrdu;
    final ok =
        await context.read<TrialService>().startTrial();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? tr(isUrdu, 'onb_trialStartedMsg')
            : tr(isUrdu, 'trialAlreadyUsed')),
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
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    final canTrial = trial.canStartTrial && !billing.isSubscribed;
    return Scaffold(
      // v0.6.31: back to the role screen — a parent who tapped
      // the wrong role (or a child who meant to be a parent)
      // can undo it here instead of being stuck.
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: t('onb_backChangeRole'),
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
              Text(
                t('plan'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                t('onb_planPriceNote'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: canTrial ? () => _startTrial(context) : null,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(t('onb_startTrialFree'),
                      style: const TextStyle(fontSize: 18)),
                ),
              ),
              if (!canTrial)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    t('onb_trialUsedOnce'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
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
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(t('subscribe'),
                      style: const TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _skip(context),
                child: Text(t('onb_planLater')),
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
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    return Scaffold(
      appBar: AppBar(title: Text(t('onb_subscribeFamilyPlan'))),
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
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(t('onb_continueGmail'),
                      style: const TextStyle(fontSize: 17)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
