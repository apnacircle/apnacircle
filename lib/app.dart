import 'package:flutter/material.dart';

import 'core/language_service.dart';
import 'screens/auth_screen.dart';
import 'screens/home_map_screen.dart';
import 'screens/join_request_screen.dart';
import 'screens/language_select_screen.dart';
import 'screens/pin_setup_screen.dart';
import 'screens/plan_choice_screen.dart';
import 'screens/role_select_screen.dart';
import 'screens/setup_screen.dart';
import 'services/auth_service.dart';
import 'services/firebase_bootstrap.dart';
import 'services/onboarding_service.dart';
import 'services/pin_service.dart';
import 'services/setup_service.dart';
import 'services/sync_service.dart';
import 'package:provider/provider.dart';

/// Decides the first screen (v0.6.30 onboarding):
/// language (once, persisted) -> role (once: parent / child) ->
/// parent: plan choice (trial / subscribe, once) -> Gmail login ->
/// parent PIN -> one-time setup -> map.
/// child: Gmail login -> join REQUEST (parent must approve; no
/// trial / payment screens ever) -> one-time setup -> map.
///
/// Returning users go straight to Home: language + role are
/// persisted, and the plan / join screens only show when there is
/// genuinely nothing yet (no PIN and no circles for a new parent;
/// no circles for a new child).
///
/// * Firebase configured + nobody signed in + demo NOT skipped:
///   AuthScreen (Gmail / email code first — phone OTP is
///   billing-blocked, so the Gmail code is the default tab).
/// * Demo mode (no Firebase project yet, or "Continue in demo
///   mode"): skips auth entirely — v0.2 behaviour, local only.
/// * v0.6.19: after the PIN, the one-time guided Setup screen
///   (permissions) shows until it is finished or skipped; it never
///   nags again after that.
/// * v0.6.30: only the PARENT sets a PIN — a child never sees the
///   PIN setup screen; their phone adopts the parent's PIN from
///   the circle (cacheParentPinHash) after the parent approves
///   the join.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final onboarding = context.watch<OnboardingService>();
    final pin = context.watch<PinService>();
    final auth = context.watch<AuthService>();
    final setup = context.watch<SetupService>();
    final sync = context.watch<SyncService>();
    if (!lang.hasChosenLanguage) return const LanguageSelectScreen();
    if (!onboarding.hasChosenRole) return const RoleSelectScreen();
    // Brand-new parent only: no PIN and no circles yet. A parent
    // who already has a PIN or a circle never sees this again.
    if (onboarding.isParent &&
        !onboarding.planChoiceDone &&
        !pin.hasPin &&
        sync.myCircles.isEmpty) {
      return const PlanChoiceScreen();
    }
    if (FirebaseBootstrap.available && !auth.signedIn && !auth.demoSkipped) {
      return const AuthScreen(initialMode: 2, showRoleBack: true);
    }
    if (onboarding.isChild &&
        sync.myCircles.isEmpty &&
        !onboarding.joinSkipped) {
      return const JoinRequestScreen();
    }
    if (onboarding.isParent && !pin.hasPin) return const PinSetupScreen();
    if (!setup.isComplete) return const SetupScreen();
    return const HomeMapScreen();
  }
}

class ApnaCircleTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A45)),
        // Big, readable text: many users are parents / elderly.
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 17),
          bodyMedium: TextStyle(fontSize: 15),
        ),
      );
}
