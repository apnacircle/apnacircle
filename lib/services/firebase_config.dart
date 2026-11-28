/// Firebase setup — v0.3 (22 Nov 2026): packages added, sync code
/// written. NO Firebase project exists yet (no console project, no
/// google-services.json) — until the project is created the app
/// runs in local demo mode (see FirebaseBootstrap): every Firebase
/// call is guarded, nothing crashes, the v0.2 local behaviour stays.
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
/// Until the console project exists, FamilyService stores
/// everything locally (SharedPreferences) — live sync between two
/// phones does NOT work yet. That is the honest v0.3 limit, written
/// in the README.
class FirebaseConfig {
  FirebaseConfig._();

  /// From the Firebase console (google-services.json, placed in
  /// android/app/ — gitignored, never committed). The Android SDK
  /// reads the json at runtime; these constants hold only the
  /// NON-SECRET identifiers the Dart code needs directly.
  /// NEVER put a real API key here — it lives in google-services.json.
  static const String apiKey = 'YOUR_FIREBASE_API_KEY';
  static const String appId = 'YOUR_FIREBASE_APP_ID';
  static const String messagingSenderId = 'YOUR_FCM_SENDER_ID';

  /// Real project (created 22 Nov 2026 ~22:09 PKT, Spark free,
  /// Analytics OFF, Android app com.apnacircle.app).
  static const String projectId = 'apnacircle-22ef3';

  /// Realtime Database URL (asia-southeast1). Hard-coded because
  /// the google-services.json downloaded before the database was
  /// created contains NO firebase_url — without this, the Dart
  /// SDK cannot find the database. This URL is NOT a secret (it
  /// is just the database's address; the member-only rules in
  /// FIREBASE_SETUP.md §2 are what protect the data).
  static const String databaseUrl =
      'https://apnacircle-22ef3-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// True when a real project is known (values come from
  /// google-services.json at runtime).
  static bool get isConfigured => !projectId.startsWith('YOUR_');

  /// Realtime Database paths (decided now, so the schema is stable
  /// when Firebase is wired — no migration later):
  ///   circles/{circleId}/members/{memberId}   — location, battery, online
  ///   circles/{circleId}/locks/{memberId}     — app locks + time windows
  ///   circles/{circleId}/alerts/{memberId}    — per-alert on/off
  ///   circles/{circleId}/chat                 — family chat messages
  ///   circles/{circleId}/events               — SOS / battery / phone-off
  ///   circles/{circleId}/info                 — name, invite code, PIN hash
  ///   trials/{deviceHash}                    — 7-day free trial, ONCE PER
  ///                                             DEVICE (trialUsed, trialStartedAt,
  ///                                             trialEndsAt, epoch ms; key is the
  ///                                             SHA-256 of the Android ID)
  ///   users/{uid}/profile                     — name, phone, email, FCM token
  ///   users/{uid}/circles/{circleId}          — this user's role in a circle
  ///   invites/{6-digit code}                  — invite code -> circleId
  ///
  /// Pure path builders (no Firebase import) so the schema is
  /// unit-tested in test/firebase_sync_test.dart.
  static const String circlesPath = 'circles';
  static const String usersPath = 'users';
  static const String invitesPath = 'invites';
  static const String trialsPath = 'trials';

  static String circleInfoPath(String circleId) => 'circles/$circleId/info';
  static String circleMembersPath(String circleId) =>
      'circles/$circleId/members';
  static String circleMemberPath(String circleId, String memberId) =>
      'circles/$circleId/members/$memberId';
  static String circleLocksPath(String circleId, String memberId) =>
      'circles/$circleId/locks/$memberId';
  static String circleAlertsPath(String circleId, String memberId) =>
      'circles/$circleId/alerts/$memberId';
  static String circleChatPath(String circleId) => 'circles/$circleId/chat';
  static String circleEventsPath(String circleId) => 'circles/$circleId/events';

  /// v0.6.30: join requests — a child who wants in writes one
  /// node here (pending) and the parent approves / denies it.
  /// See core/join_request.dart + database.rules.json (rules v7).
  static String joinRequestsPath(String circleId) =>
      'circles/$circleId/joinRequests';
  static String joinRequestPath(String circleId, String uid) =>
      'circles/$circleId/joinRequests/$uid';

  /// v0.6.21: call signaling — one node per call under the
  /// circle (see call_signaling.dart for the node shape).
  static String circleCallsPath(String circleId) => 'circles/$circleId/calls';
  static String userProfilePath(String uid) => 'users/$uid/profile';
  static String userCirclesPath(String uid) => 'users/$uid/circles';
  static String userCircleRolePath(String uid, String circleId) =>
      'users/$uid/circles/$circleId';
  static String invitePath(String code) => 'invites/$code';

  /// Free-trial node for one device. The key is the SHA-256 hash of
  /// the Android ID (never the raw id) — see DeviceIdService.
  static String trialPath(String deviceHash) => 'trials/$deviceHash';

  /// A 6-digit invite code (100000–999999). Generated on the parent
  /// phone when a circle is created; the child types it to join.
  /// Pure function — the only randomness in the sync layer.
  static String newInviteCode([int Function(int max)? randomInt]) {
    final r = randomInt ?? _defaultRandom;
    return (100000 + r(900000)).toString();
  }

  static int _defaultRandom(int max) =>
      DateTime.now().microsecondsSinceEpoch % max;
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
