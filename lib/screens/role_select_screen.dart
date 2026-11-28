import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/language_service.dart';
import '../l10n/strings.dart';
import '../services/onboarding_service.dart';

/// Second first-run screen (v0.6.30): who is using THIS phone?
/// Asked ONCE, right after the language — never again on open.
///
/// * Parent / admin — creates the family circle, sets the PIN,
///   pays (or takes the free trial). Their own apps never lock.
/// * Child — joins the parent's circle with the parent's PIN.
///   A child never sees the trial / payment screens.
class RoleSelectScreen extends StatelessWidget {
  const RoleSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    String t(String key) => tr(lang.isUrdu, key);
    return Scaffold(
      // v0.6.31: back to the language screen — a wrong tap is
      // undoable at every step (the user's report, 28 Nov 2026:
      // Child dab gaya tha aur wapas jaane ka option hi nahi tha).
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: t('onb_backChangeLanguage'),
          onPressed: () =>
              context.read<LanguageService>().clearChoice(),
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
                'ApnaCircle',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                t('onb_roleHeading'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 19),
              ),
              const SizedBox(height: 8),
              Text(
                t('onb_roleExplain'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => context
                    .read<OnboardingService>()
                    .chooseRole('parent'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Text(t('onb_roleParent'),
                          style: const TextStyle(fontSize: 20)),
                      const SizedBox(height: 4),
                      Text(
                        t('onb_roleParentSub'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: () => context
                    .read<OnboardingService>()
                    .chooseRole('child'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Text(t('onb_roleChild'),
                          style: const TextStyle(fontSize: 20)),
                      const SizedBox(height: 4),
                      Text(
                        t('onb_roleChildSub'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
