import 'package:flutter/material.dart';

import 'core/language_service.dart';
import 'screens/home_map_screen.dart';
import 'screens/language_select_screen.dart';
import 'screens/pin_setup_screen.dart';
import 'services/pin_service.dart';
import 'package:provider/provider.dart';

/// Decides the first screen: language -> parent PIN -> map.
class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    final pin = context.watch<PinService>();
    if (!lang.hasChosenLanguage) return const LanguageSelectScreen();
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
