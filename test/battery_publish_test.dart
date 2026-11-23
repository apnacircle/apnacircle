import 'package:apnacircle/core/battery_schedule.dart';
import 'package:apnacircle/models/member.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.6.6 regression tests for the stale-battery bug the user
/// caught on his own phone (23 Nov 2026 ~12:47 PKT): the status
/// bar showed 59%, the app still showed the 82% from 09:24.
/// The battery used to ride ONLY on a location publish, and
/// location publishes are throttled to "moved >= 50 m" — sitting
/// at home, no publish ever happened and the battery froze.
/// The fix: battery is published on its OWN schedule — every 15
/// minutes, and on any >= 2% change — even when the location has
/// not moved.
void main() {
  group('BatteryPublishTracker', () {
    DateTime t(int minutes) =>
        DateTime(2026, 11, 23, 12, 0).add(Duration(minutes: minutes));

    test('first known level always publishes', () {
      final tracker = BatteryPublishTracker();
      expect(tracker.shouldPublish(battery: 82, now: t(0)), isTrue);
    });

    test('same level does NOT publish within 15 minutes', () {
      final tracker = BatteryPublishTracker();
      tracker.markPublished(battery: 82, now: t(0));
      expect(tracker.shouldPublish(battery: 82, now: t(5)), isFalse);
      expect(tracker.shouldPublish(battery: 82, now: t(14)), isFalse);
    });

    test('same level publishes again after 15 minutes (time-based)', () {
      // The core of the bug: no location move for hours, yet the
      // battery must still go out on its own timer.
      final tracker = BatteryPublishTracker();
      tracker.markPublished(battery: 82, now: t(0));
      expect(tracker.shouldPublish(battery: 82, now: t(15)), isTrue);
      expect(tracker.shouldPublish(battery: 82, now: t(180)), isTrue);
    });

    test('a 1% change does NOT trigger a publish', () {
      final tracker = BatteryPublishTracker();
      tracker.markPublished(battery: 82, now: t(0));
      expect(tracker.shouldPublish(battery: 81, now: t(1)), isFalse);
      expect(tracker.shouldPublish(battery: 83, now: t(1)), isFalse);
    });

    test('a 2% change triggers a publish right away', () {
      final tracker = BatteryPublishTracker();
      tracker.markPublished(battery: 82, now: t(0));
      expect(tracker.shouldPublish(battery: 80, now: t(1)), isTrue);
      expect(tracker.shouldPublish(battery: 84, now: t(1)), isTrue);
      // And a bigger drop (the user's 82 -> 59) certainly does.
      expect(tracker.shouldPublish(battery: 59, now: t(1)), isTrue);
    });

    test('unknown levels never publish', () {
      final tracker = BatteryPublishTracker();
      expect(tracker.shouldPublish(battery: -1, now: t(0)), isFalse);
      expect(tracker.shouldPublish(battery: 101, now: t(0)), isFalse);
      expect(tracker.shouldPublish(battery: -5, now: t(0)), isFalse);
    });

    test('an unknown level never becomes the published baseline', () {
      final tracker = BatteryPublishTracker();
      tracker.markPublished(battery: 82, now: t(0));
      tracker.markPublished(battery: -1, now: t(1));
      // Still measured from the real 82% at t(0).
      expect(tracker.shouldPublish(battery: 82, now: t(5)), isFalse);
      expect(tracker.shouldPublish(battery: 80, now: t(5)), isTrue);
    });
  });

  group('Member batteryAt', () {
    Member member({int battery = 82, DateTime? batteryAt}) => Member(
          id: 'mujahid',
          name: 'Mujahid',
          phone: '+923001111111',
          isOnline: true,
          battery: battery,
          batteryAt: batteryAt,
        );

    test('batteryAt survives a JSON round-trip', () {
      final at = DateTime(2026, 11, 23, 12, 30);
      final restored = Member.fromJson(member(batteryAt: at).toJson());
      expect(restored.battery, 82);
      expect(restored.batteryAt, at);
    });

    test('missing batteryAt in JSON stays null (older app versions)', () {
      final restored = Member.fromJson({
        'id': 'mujahid',
        'name': 'Mujahid',
        'phone': '+923001111111',
        'isOnline': true,
        'battery': 82,
      });
      expect(restored.batteryAt, isNull);
      expect(restored.batteryIsStale, isFalse);
    });

    test('battery is stale after 30 minutes', () {
      final old = member(
        batteryAt: DateTime.now().subtract(const Duration(minutes: 31)),
      );
      expect(old.batteryIsStale, isTrue);
    });

    test('battery is fresh within 30 minutes', () {
      final fresh = member(
        batteryAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(fresh.batteryIsStale, isFalse);
    });
  });
}
