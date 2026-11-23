/// Battery publishing schedule (v0.6.6, 23 Nov 2026).
///
/// THE BUG IT FIXES: the battery level used to ride ONLY on a
/// location publish, and location publishes are throttled to
/// "moved >= 50 m" — a member sitting at home never moved, so no
/// publish ever happened and the battery froze at its first value.
/// The user caught it on his own phone (12:47 PKT): the status
/// bar showed 59%, the app still showed the 82% from 09:24.
///
/// THE RULE NOW: battery is published on its OWN schedule,
/// independent of the movement throttle —
/// * at least every 15 minutes, even when the level is unchanged,
/// * and immediately whenever the level changed by >= 2% since
///   the last publish.
/// The 60 s / 50 m throttle still applies to LOCATION only.
/// Pure decision logic — no plugins, no Firebase — unit-tested
/// in test/battery_publish_test.dart.
class BatteryPublishTracker {
  /// Re-publish at least this often even when the level is unchanged.
  static const Duration maxBatteryAge = Duration(minutes: 15);

  /// Re-publish as soon as the level moved by this much.
  static const int minBatteryChange = 2;

  int? _lastPublishedBattery;
  DateTime? _lastPublishedAt;

  /// True when the battery should be pushed to the member's RTDB
  /// node right now. Unknown levels (-1 / out of 0–100) never
  /// publish: there is nothing new to share, and -1 must never
  /// overwrite a real level (v0.6.2).
  bool shouldPublish({required int battery, required DateTime now}) {
    if (battery < 0 || battery > 100) return false;
    if (_lastPublishedBattery == null || _lastPublishedAt == null) {
      return true;
    }
    if ((battery - _lastPublishedBattery!).abs() >= minBatteryChange) {
      return true;
    }
    return now.difference(_lastPublishedAt!) >= maxBatteryAge;
  }

  /// Call after a publish (full or battery-only) so the next
  /// decision is measured from the fresh value. Unknown levels
  /// are ignored — they must not become the "last published"
  /// baseline.
  void markPublished({required int battery, required DateTime now}) {
    if (battery < 0 || battery > 100) return;
    _lastPublishedBattery = battery;
    _lastPublishedAt = now;
  }
}
