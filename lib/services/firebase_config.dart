/// Firebase setup — PLACEHOLDERS ONLY (v0.2, 22 Nov 2026).
///
/// NO Firebase project has been created, NO account has been used,
/// and NO firebase_* package is in pubspec.yaml yet. This file is
/// the single place where the real values will go, so the rest of
/// the code only has to call [FirebaseConfig.isConfigured].
///
/// Why Firebase is needed (see FIREBASE_SETUP.md for the checklist):
/// * Realtime Database — live location + parent's remote control
///   (alerts, locks) syncing to the child's phone.
/// * Cloud Messaging (FCM) — SOS / battery-low / phone-off alerts
///   pushed to the parent even when the app is closed.
/// * Auth — family accounts (parent + members), so a circle is not
///   tied to one phone. Anonymous sign-in is NOT enough for a
///   family product: a lost phone must not lose the circle.
///
/// Until Firebase is wired, FamilyService stores everything locally
/// (SharedPreferences) — live sync between two phones does NOT work
/// yet. That is the honest v0.1 limit, written in the README.
class FirebaseConfig {
  FirebaseConfig._();

  /// Fill these from the Firebase console (google-services.json).
  /// NEVER commit a real google-services.json with a production
  /// key — it is already in .gitignore. Use the placeholder below
  /// until the project exists.
  static const String apiKey = 'YOUR_FIREBASE_API_KEY';
  static const String projectId = 'YOUR_FIREBASE_PROJECT_ID';
  static const String appId = 'YOUR_FIREBASE_APP_ID';
  static const String messagingSenderId = 'YOUR_FCM_SENDER_ID';
  static const String databaseUrl =
      'https://YOUR_FIREBASE_PROJECT_ID-default-rtdb.firebaseio.com';

  /// True only when a real project has been configured.
  static bool get isConfigured =>
      !apiKey.startsWith('YOUR_') && !projectId.startsWith('YOUR_');

  /// Realtime Database paths (decided now, so the schema is stable
  /// when Firebase is wired — no migration later):
  ///   circles/{circleId}/members/{memberId}   — location, battery, online
  ///   circles/{circleId}/locks/{memberId}     — app locks + time windows
  ///   circles/{circleId}/alerts/{memberId}    — per-alert on/off
  ///   circles/{circleId}/chat                 — family chat messages
  static const String circlesPath = 'circles';
}

/// One checklist item for the Firebase setup (FIREBASE_SETUP.md).
/// `done` is tracked in the README, not in code.
class FirebaseChecklistItem {
  final String step;
  final String detail;
  const FirebaseChecklistItem(this.step, this.detail);
}

/// Setup steps in order — do them on the Firebase console, then
/// add the firebase_* packages + google-services.json and flip
/// [FirebaseConfig] above. Estimated: 1–2 hours on a normal machine.
const firebaseChecklist = [
  FirebaseChecklistItem(
    '1. Project banayein',
    'Firebase console (console.firebase.google.com) par naya project — '
    'naam: apnacircle. Google Analytics optional hai, off rakh sakte hain.',
  ),
  FirebaseChecklistItem(
    '2. Android app register karein',
    'Package: com.apnacircle.app. google-services.json download karke '
    'android/app/ mein rakhein (ye file .gitignore mein hai — commit NAHI hogi).',
  ),
  FirebaseChecklistItem(
    '3. Realtime Database',
    'Database banayein (locked mode se shuru karein), region: asia-southeast1 '
    '(Pakistan ke qareeb). Rules: sirf apne circle ke members parh/sakte hain — '
    'rules file FIREBASE_SETUP.md mein hai.',
  ),
  FirebaseChecklistItem(
    '4. Authentication',
    'Phone number sign-in ON karein (family ke liye phone number sab se '
    'asaan hai). Email/password backup ke tor par.',
  ),
  FirebaseChecklistItem(
    '5. Cloud Messaging (FCM)',
    'FCM API enable karein. Server key kabhi app mein NAHI dalni — '
    'sirf Cloud Functions / server se use hogi.',
  ),
  FirebaseChecklistItem(
    '6. Packages add karein',
    'pubspec.yaml mein: firebase_core, firebase_auth, '
    'firebase_database, firebase_messaging. Phir `flutter pub get` '
    'aur `Firebase.initializeApp()` main.dart mein.',
  ),
  FirebaseChecklistItem(
    '7. Test karein',
    'Do phones par live location sync, parent se remote lock, aur '
    'SOS push notification — teeno kaam karte hon to hi v0.2 complete hai.',
  ),
];
