import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/language_service.dart';
import 'services/family_service.dart';
import 'services/pin_service.dart';

/// ApnaCircle entry point.
///
/// First run flow: LanguageSelect -> PinSetup (parent) -> Home (map).
/// Returning users go straight to Home if language + PIN are saved.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LanguageService()),
        ChangeNotifierProvider(create: (_) => PinService()),
        ChangeNotifierProvider(create: (_) => FamilyService()),
      ],
      child: const ApnaCircleApp(),
    ),
  );
}

class ApnaCircleApp extends StatelessWidget {
  const ApnaCircleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    return MaterialApp(
      title: 'ApnaCircle',
      debugShowCheckedModeBanner: false,
      locale: lang.locale,
      supportedLocales: const [Locale('en'), Locale('ur')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Urdu = RTL. Flutter flips layout automatically for Locale('ur').
      theme: ApnaCircleTheme.light,
      home: const AppRoot(),
    );
  }
}
