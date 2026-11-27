import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/core/time_lock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// App Lock enforcement (v0.6.3): the native service was never
/// declared before v0.6.3, so locks never worked on a real phone.
/// These tests pin the Dart side of the contract — time windows
/// evaluated at enforcement time (incl. overnight windows and day
/// boundaries), and the exact payload Dart hands to native code
/// (full schedule + service status channel calls).
void main() {
  group('LockedApp.isLockedAt — overnight window 22:00–06:00 Mon–Fri',
      () {
    // 23 Nov 2026 is a Monday; 24 Nov Tuesday; 28 Nov Saturday;
    // 29 Nov Sunday.
    const overnight = TimeWindow(
      startMinutes: 22 * 60,
      endMinutes: 6 * 60,
      days: {1, 2, 3, 4, 5},
    );
    const app = LockedApp(
      name: 'PUBG',
      packageName: 'com.tencent.ig',
      mode: LockMode.time,
      window: overnight,
    );

    test('Monday 23:30 is locked (inside the window)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 23, 23, 30)), isTrue);
    });

    test('Tuesday 05:30 is locked (overnight spill from Monday)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 24, 5, 30)), isTrue);
    });

    test('Tuesday 06:00 is open (window end is exclusive)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 24, 6, 0)), isFalse);
    });

    test('Monday 21:59 is open (before the window starts)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 23, 21, 59)), isFalse);
    });

    test('Sunday 05:30 is open (Saturday is not a scheduled day)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 29, 5, 30)), isFalse);
    });

    test('Saturday 23:30 is open (Saturday is not scheduled)', () {
      expect(app.isLockedAt(DateTime(2026, 11, 28, 23, 30)), isFalse);
    });

    test('unlocked flag beats the window', () {
      final off = app.copyWith(locked: false);
      expect(off.isLockedAt(DateTime(2026, 11, 23, 23, 30)), isFalse);
    });
  });

  group('lockedPackagesNow — mixed modes at one moment', () {
    test('only actually-locked apps are handed to native code', () {
      final monday10 = DateTime(2026, 11, 23, 10, 0);
      final apps = [
        const LockedApp(
          name: 'YouTube',
          packageName: 'com.google.android.youtube',
        ),
        const LockedApp(
          name: 'PUBG',
          packageName: 'com.tencent.ig',
          mode: LockMode.time,
          window: TimeWindow.workday8to2,
        ),
        const LockedApp(
          name: 'Chrome',
          packageName: 'com.android.chrome',
          locked: false,
        ),
      ];
      // Monday 10:00: YouTube (always) + PUBG (08:00–14:00) locked.
      final locked = AppLockService.lockedPackagesNow(apps, monday10);
      expect(
        locked,
        containsAll(['com.google.android.youtube', 'com.tencent.ig']),
      );
      expect(locked, isNot(contains('com.android.chrome')));
      // Saturday 10:00: PUBG window is Mon–Fri only.
      final lockedSat = AppLockService.lockedPackagesNow(
        apps,
        DateTime(2026, 11, 28, 10, 0),
      );
      expect(lockedSat, ['com.google.android.youtube']);
    });
  });

  group('custom apps', () {
    test('customApp stores the name as a custom: package', () {
      final app = AppLockService.customApp('Snapchat');
      expect(app.packageName, 'custom:snapchat');
      expect(app.isCustom, isTrue);
      expect(app.locked, isTrue);
    });

    test('JSON round-trip keeps a time window', () {
      const app = LockedApp(
        name: 'PUBG',
        packageName: 'com.tencent.ig',
        mode: LockMode.time,
        window: TimeWindow.workday8to2,
      );
      final back = LockedApp.fromJson(app.toJson());
      expect(back.mode, LockMode.time);
      expect(back.window?.startMinutes, 8 * 60);
      expect(back.window?.endMinutes, 14 * 60);
      expect(back.window?.days, {1, 2, 3, 4, 5});
    });
  });

  group('apnacircle/applock channel', () {
    const channel = MethodChannel('apnacircle/applock');
    final calls = <MethodCall>[];

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> mockNative({bool? applyResult, bool? enabled}) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'applyLocks':
            return applyResult;
          case 'isLockServiceEnabled':
            return enabled;
          default:
            return null;
        }
      });
    }

    test('applyLocks sends the full schedule to native code', () async {
      await mockNative(applyResult: true);
      const apps = [
        LockedApp(name: 'YouTube', packageName: 'com.google.android.youtube'),
        LockedApp(
          name: 'PUBG',
          packageName: 'com.tencent.ig',
          mode: LockMode.time,
          window: TimeWindow.workday8to2,
        ),
      ];
      final ok = await AppLockService.applyLocks(apps);
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'applyLocks');
      final args = calls.single.arguments as Map;
      expect(
        (args['packages'] as List),
        contains('com.google.android.youtube'),
      );
      final schedule = args['schedule'] as List;
      expect(schedule, hasLength(2));
      expect((schedule[0] as Map)['package'], 'com.google.android.youtube');
      expect((schedule[1] as Map)['mode'], 'time');
      expect(
        ((schedule[1] as Map)['window'] as Map)['start'],
        8 * 60,
      );
    });

    test('applyLocks returns false when native code throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'NO_ENGINE');
      });
      final ok = await AppLockService.applyLocks(
        const [LockedApp(name: 'X', packageName: 'com.x')],
      );
      expect(ok, isFalse);
    });

    test('isServiceEnabled reports the native value', () async {
      await mockNative(enabled: true);
      expect(await AppLockService.isServiceEnabled(), isTrue);
      await mockNative(enabled: null);
      expect(await AppLockService.isServiceEnabled(), isFalse);
    });

    test('applyLocks([]) sends an empty schedule (the admin clear)',
        () async {
      await mockNative(applyResult: true);
      final ok = await AppLockService.applyLocks([]);
      expect(ok, isTrue);
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map;
      expect((args['packages'] as List), isEmpty);
      expect((args['schedule'] as List), isEmpty);
    });

    test('openAccessibilitySettings calls the channel', () async {
      await mockNative();
      await AppLockService.openAccessibilitySettings();
      expect(
        calls.map((c) => c.method),
        contains('openAccessibilitySettings'),
      );
    });
  });

  group('v0.6.26 — mayApplyLocally (admin apps must never lock)', () {
    test('admin phone must NOT apply a lock list locally', () {
      expect(AppLockService.mayApplyLocally(isAdmin: true), isFalse);
    });

    test('member/child phone DOES apply its own lock list locally',
        () {
      expect(AppLockService.mayApplyLocally(isAdmin: false), isTrue);
    });
  });
}
