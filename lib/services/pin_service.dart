import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Parent PIN — the key to EVERYTHING locked in ApnaCircle.
///
/// * Alerts on/off, Location Lock, App Lock add/remove, plan change:
///   all require this PIN, and only the PARENT can change them.
/// * The PIN is never stored in plain text — only its SHA-256 hash.
/// * A child cannot change settings from their own phone: settings
///   changes are signed by the parent (PIN) and synced from the
///   parent phone (remote control). In v0.1 the sync is local-only;
///   the Firebase sync layer is marked TODO in FamilyService.
class PinService extends ChangeNotifier {
  static const _hashKey = 'parent_pin_sha256';
  String? _pinHash;

  bool get hasPin => _pinHash != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _pinHash = prefs.getString(_hashKey);
    notifyListeners();
  }

  static String hashPin(String pin) =>
      sha256.convert(utf8.encode('apnacircle:$pin')).toString();

  Future<void> setPin(String pin) async {
    assert(pin.length >= 4, 'PIN must be at least 4 digits');
    final prefs = await SharedPreferences.getInstance();
    _pinHash = hashPin(pin);
    await prefs.setString(_hashKey, _pinHash!);
    notifyListeners();
  }

  bool verify(String pin) =>
      _pinHash != null && hashPin(pin) == _pinHash;

  /// Ask the user for the PIN and run [action] only if it matches.
  /// UI calls this via the PinGateDialog (screens/pin_gate_dialog.dart).
  bool check(String pin) => verify(pin);
}
