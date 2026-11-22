import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Guarded Firebase startup (v0.3, 22 Nov 2026).
///
/// The app MUST still run when no Firebase project exists yet
/// (no google-services.json on the build machine, no console
/// project). On Android, `Firebase.initializeApp()` throws when
/// there is no google-services.json / no default options — that is
/// EXPECTED in demo mode, not a bug. We catch it, stay in local
/// demo mode, and every Firebase service checks [available] before
/// touching the SDK. Nothing in the v0.2 UI depends on Firebase,
/// so the demo family, PIN, locks and map keep working.
///
/// When the console project IS created and google-services.json is
/// placed in android/app/ (see FIREBASE_SETUP.md), this same call
/// succeeds and the app switches to live sync automatically — no
/// code change needed.
class FirebaseBootstrap {
  FirebaseBootstrap._();

  /// True only after a successful `Firebase.initializeApp()`.
  /// False = demo mode (local SharedPreferences only).
  static bool available = false;

  static Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      available = true;
      debugPrint('ApnaCircle: Firebase connected — live sync ON.');
    } catch (e) {
      // No google-services.json / no project yet: demo mode.
      available = false;
      debugPrint('ApnaCircle: Firebase not configured ($e) — demo mode.');
    }
  }
}
