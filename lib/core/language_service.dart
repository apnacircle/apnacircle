import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// English / Urdu. Chosen on the first screen, changeable in Settings.
/// Urdu uses RTL layout automatically (Locale 'ur', Directionality).
///
/// v0.6.30: the choice is PERSISTED (SharedPreferences) and loaded
/// in main() before runApp — before this the TODO from v0.2 was
/// never done, so the choice lived only in memory and the language
/// screen came back on EVERY app open. Ask once; change in Settings.
class LanguageService extends ChangeNotifier {
  static const _localeKey = 'language_code_v1';

  Locale _locale = const Locale('en');
  bool _hasChosenLanguage = false;

  Locale get locale => _locale;
  bool get hasChosenLanguage => _hasChosenLanguage;
  bool get isUrdu => _locale.languageCode == 'ur';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_localeKey);
    if (code != null && (code == 'en' || code == 'ur')) {
      _locale = Locale(code);
      _hasChosenLanguage = true;
    }
    notifyListeners();
  }

  Future<void> choose(Locale locale) async {
    _locale = locale;
    _hasChosenLanguage = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, locale.languageCode);
    notifyListeners();
  }

  /// v0.6.31: go back — forget the choice so the language screen
  /// shows again (the role screen's back arrow). The locale
  /// resets to English until the user picks again.
  Future<void> clearChoice() async {
    _locale = const Locale('en');
    _hasChosenLanguage = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localeKey);
    notifyListeners();
  }

  void toggle() =>
      choose(isUrdu ? const Locale('en') : const Locale('ur'));
}
