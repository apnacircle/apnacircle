import 'package:flutter/material.dart';

/// English / Urdu. Chosen on the first screen, changeable in Settings.
/// Urdu uses RTL layout automatically (Locale 'ur', Directionality).
class LanguageService extends ChangeNotifier {
  Locale _locale = const Locale('en');
  bool _hasChosenLanguage = false;

  Locale get locale => _locale;
  bool get hasChosenLanguage => _hasChosenLanguage;
  bool get isUrdu => _locale.languageCode == 'ur';

  void choose(Locale locale) {
    _locale = locale;
    _hasChosenLanguage = true;
    // TODO(v0.2): persist with SharedPreferences + reload saved locale
    // in main() before runApp, so the choice survives a restart.
    notifyListeners();
  }

  void toggle() =>
      choose(isUrdu ? const Locale('en') : const Locale('ur'));
}
