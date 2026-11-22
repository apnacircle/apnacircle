import 'package:flutter/material.dart';

import 'core/language_service.dart';
import 'screens/auth_screen.dart';
import 'screens/home_map_screen.dart';
import 'screens/language_select_screen.dart';
import 'screens/pin_setup_screen.dart';
import 'services/auth_service.dart';
import 'services/firebase_bootstrap.dart';
import 'services/pin_service.dart';
import 'package:provider/provider.dart';

/// Decides the first screen: language -> auth -> parent PIN -> map.
///
/// * Firebase configured + nobody signed in + demo NOT skipped:
///   AuthScreen (phone OTP / Gmail / demo mode).
/// * Demo mode (no Firebase project yet, or "Continue in demo
///   mode"): skips auth entirely — v0.2 behaviour, local only.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final pin = context.watch<PinService>();
    final auth = context.watch<AuthService>();
    if (!lang.hasChosenLanguage) return const LanguageSelectScreen();
    if (FirebaseBootstrap.available &&
        !auth.signedIn &&
        !auth.demoSkipped) {
      return const AuthScreen();
    }
    if (!pin.hasPin) return const PinSetupScreen();
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
