/// ApnaCircle — single source of truth for product decisions
/// made by Mujahid (21 Nov 2026). Change these only on his order.
class AppConstants {
  AppConstants._();

  /// Max family members in one circle. Server + UI both enforce it.
  static const int maxFamilyMembers = 10;

  /// Family plan, paid ONLY by the parent, whole family covered.
  static const String planPriceUsdPerYear = '\$5/year';
  static const double planPriceUsd = 5;

  /// Google Play Billing product id for the Family plan (v0.5).
  /// The product must exist in Play Console before a REAL purchase
  /// works — until then the store reports "product not found" and
  /// the Plan screen says so honestly, never faking a charge.
  static const String billingProductId = 'apnacircle_family_yearly';

  /// Demo PIN for the web demo only. The real app forces the parent
  /// to set their own PIN on first run (PinService) — no default PIN.
  static const String demoPin = '1234';

  /// Google Play developer account fee (one-time, non-refundable,
  /// paid by Mujahid himself — never by the app / never by card here).
  static const String playStoreFee = '\$25 one-time';

  /// Closed testing required for a new personal Play account.
  static const int closedTestMinTesters = 12;
  static const int closedTestMinDays = 14;

  /// Location update policy: keep server cost inside the \$5/year
  /// plan (see family-location-app/PLAN.md). Update only when the
  /// member moved >= 50 m, at most every 60 s while moving.
  static const double minMoveMeters = 50;
  static const Duration minUpdateInterval = Duration(seconds: 60);

  /// Pakistan emergency number (1122). Auto-call is OFF by default
  /// and needs explicit parent opt-in per member (SOS settings).
  static const String emergencyNumberPk = '1122';

  /// Method-channel names (must match MainActivity.kt exactly).
  static const String callChannel = 'apnacircle/calls';
  static const String appLockChannel = 'apnacircle/applock';
  static const String smsChannel = 'apnacircle/sms';
  static const String deviceChannel = 'apnacircle/device';
  static const String deviceAdminChannel = 'apnacircle/deviceadmin';
  static const String simChannel = 'apnacircle/sim';
  static const String deviceOwnerChannel = 'apnacircle/deviceowner';
}
