import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    return Scaffold(
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
              const Text(
                'Aap kaun hain? / آپ کون ہیں؟',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 19),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ye sirf ek dafa poocha jata hai — jis phone par app '
                'hai, us ke hisaab se chuniye.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => context
                    .read<OnboardingService>()
                    .chooseRole('parent'),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Text('Parent / Admin',
                          style: TextStyle(fontSize: 20)),
                      SizedBox(height: 4),
                      Text(
                        'Main family circle banunga — PIN, payment '
                        'aur bachon ki apps mere control mein hon gi.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13),
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
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Column(
                    children: [
                      Text('Child / بچہ',
                          style: TextStyle(fontSize: 20)),
                      SizedBox(height: 4),
                      Text(
                        'Main parent ke circle mein join hounga — '
                        'parent ki ijazat se.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13),
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
