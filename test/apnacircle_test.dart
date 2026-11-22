import 'package:apnacircle/core/alerts.dart';
import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/core/call_distance_service.dart';
import 'package:apnacircle/core/constants.dart';
import 'package:apnacircle/core/time_lock.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('14 alerts exist', () {
    expect(AlertType.values.length, 14);
    expect(defaultAlertSettings().length, 14);
  });

  test('family circle max is 10', () {
    expect(AppConstants.maxFamilyMembers, 10);
  });

  test('plan is \$5/year, parent pays only', () {
    expect(AppConstants.planPriceUsd, 5);
    expect(AppConstants.planPriceUsdPerYear, '\$5/year');
  });

  test('Haversine: Lahore Gulberg to Model Town is ~5-6 km', () {
    // Gulberg (31.5204, 74.3587) -> Model Town (31.4687, 74.3110)
    final km = CallDistanceService.distanceKm(31.5204, 74.3587, 31.4687, 74.3110);
    expect(km, greaterThan(4));
    expect(km, lessThan(8));
  });

  test('Haversine: same point is 0 km', () {
    expect(CallDistanceService.distanceKm(31.5, 74.3, 31.5, 74.3), 0);
  });

  test('distance formatting: under 1 km shows metres', () {
    expect(CallDistanceService.formatKm(0.4), '400 m');
    expect(CallDistanceService.formatKm(5.7), '5.7 km');
  });

  test('PIN hash is stable and not the PIN itself', () {
    final h1 = PinService.hashPin('1234');
    final h2 = PinService.hashPin('1234');
    expect(h1, h2);
    expect(h1, isNot('1234'));
    expect(PinService.hashPin('4321'), isNot(h1));
  });

  test('member JSON round-trip keeps location + alerts', () {
    const m = Member(
      id: 'ali',
      name: 'Ali',
      phone: '+923005550103',
      lat: 31.5497,
      lon: 74.3436,
      battery: 64,
      isOnline: true,
    );
    final back = Member.fromJson(m.toJson());
    expect(back.name, 'Ali');
    expect(back.lat, 31.5497);
    expect(back.battery, 64);
    expect(back.isOnline, true);
  });

  test('1122 auto-call needs explicit opt-in', () {
    expect(AlertType.autoCall1122.needsExplicitOptIn, true);
    expect(AlertType.sos.needsExplicitOptIn, false);
  });

  // --- Time Lock (22 Nov 2026) ---
  test('time window: Mon-Fri 08:00-14:00 is active at Monday 10:00', () {
    // 2026-11-23 is a Monday.
    final monday10 = DateTime(2026, 11, 23, 10, 0);
    expect(monday10.weekday, DateTime.monday);
    expect(TimeWindow.workday8to2.isActiveAt(monday10), true);
  });

  test('time window: not active before start or on weekend', () {
    expect(
      TimeWindow.workday8to2.isActiveAt(DateTime(2026, 11, 23, 7, 59)),
      false,
    );
    expect(
      TimeWindow.workday8to2.isActiveAt(DateTime(2026, 11, 23, 14, 0)),
      false,
    );
    // Saturday 10:00 — not a scheduled day.
    expect(
      TimeWindow.workday8to2.isActiveAt(DateTime(2026, 11, 28, 10, 0)),
      false,
    );
  });

  test('time window: overnight 22:00-06:00 spans midnight', () {
    const night = TimeWindow(
      startMinutes: 22 * 60,
      endMinutes: 6 * 60,
      days: {1, 2, 3, 4, 5, 6, 7},
    );
    expect(night.isActiveAt(DateTime(2026, 11, 23, 23, 30)), true);
    expect(night.isActiveAt(DateTime(2026, 11, 24, 2, 0)), true);
    expect(night.isActiveAt(DateTime(2026, 11, 24, 12, 0)), false);
  });

  test('time window: set once, next start is the next scheduled day', () {
    // Friday 15:00 — window ended, next start is Monday 08:00.
    final next =
        TimeWindow.workday8to2.nextStartAfter(DateTime(2026, 11, 27, 15, 0));
    expect(next, DateTime(2026, 11, 30, 8, 0));
  });

  test('time window: days summary', () {
    expect(TimeWindow.workday8to2.daysSummary(), 'Mon–Fri');
    expect(
      const TimeWindow(startMinutes: 480, endMinutes: 840).daysSummary(),
      'Every day',
    );
  });

  test('time window: JSON round-trip keeps days + times', () {
    final back = TimeWindow.fromJson(TimeWindow.workday8to2.toJson());
    expect(back.startMinutes, 480);
    expect(back.endMinutes, 840);
    expect(back.days, {1, 2, 3, 4, 5});
  });

  test('PUBG preset is time-locked Mon-Fri 08:00-14:00', () {
    final pubg = AppLockService.presets
        .firstWhere((a) => a.name == 'PUBG');
    expect(pubg.mode, LockMode.time);
    expect(pubg.window, TimeWindow.workday8to2);
    expect(pubg.isLockedAt(DateTime(2026, 11, 23, 10, 0)), true);
    expect(pubg.isLockedAt(DateTime(2026, 11, 28, 10, 0)), false);
  });

  test('always-lock app is locked at any time; lockedPackagesNow filters', () {
    const apps = AppLockService.presets;
    final monday10 = DateTime(2026, 11, 23, 10, 0);
    final locked = AppLockService.lockedPackagesNow(apps, monday10);
    expect(locked, contains('com.google.android.youtube'));
    expect(locked, contains('com.tencent.ig')); // PUBG in window
    final saturday10 = DateTime(2026, 11, 28, 10, 0);
    final lockedSat = AppLockService.lockedPackagesNow(apps, saturday10);
    expect(lockedSat, contains('com.google.android.youtube'));
    expect(lockedSat, isNot(contains('com.tencent.ig'))); // PUBG out of window
  });

  test('LockedApp JSON round-trip keeps mode + window', () {
    final pubg =
        AppLockService.presets.firstWhere((a) => a.name == 'PUBG');
    final back = LockedApp.fromJson(pubg.toJson());
    expect(back.mode, LockMode.time);
    expect(back.window?.startMinutes, 480);
    expect(back.window?.days, {1, 2, 3, 4, 5});
  });
}
