import 'dart:convert';

import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/models/trial.dart';
import 'package:apnacircle/screens/plan_screen.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/device_id_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // --- TrialState: pure date maths ---

  test('trial starts unstarted, 0 days left', () {
    const s = TrialState();
    final now = DateTime.utc(2026, 11, 23);
    expect(s.statusAt(now), TrialStatus.notStarted);
    expect(s.daysRemainingAt(now), 0);
    expect(s.isUsed, false);
  });

  test('trial lasts exactly 7 days', () {
    final start = DateTime.utc(2026, 11, 23, 10);
    final s = TrialState.start(start);
    expect(s.startedAt, start);
    expect(s.endsAt, start.add(const Duration(days: 7)));
    expect(s.statusAt(start), TrialStatus.active);
    expect(s.daysRemainingAt(start), 7);
  });

  test('days remaining counts down, last partial day is 1', () {
    final start = DateTime.utc(2026, 11, 23, 10);
    final s = TrialState.start(start);
    // 3 days in: 4 full days left.
    expect(s.daysRemainingAt(start.add(const Duration(days: 3))), 4);
    // 3 days + 1 hour in: still 4 (rounded up).
    expect(
      s.daysRemainingAt(start.add(const Duration(days: 3, hours: 1))),
      4,
    );
    // 6 days 23 hours in: 1 day left.
    expect(
      s.daysRemainingAt(start.add(const Duration(days: 6, hours: 23))),
      1,
    );
    // At the end instant and after: expired, 0 days.
    expect(s.statusAt(s.endsAt!), TrialStatus.expired);
    expect(s.daysRemainingAt(s.endsAt!), 0);
    expect(
      s.statusAt(start.add(const Duration(days: 8))),
      TrialStatus.expired,
    );
  });

  test('trial JSON round-trip keeps used flag, dates and device hash', () {
    final start = DateTime.utc(2026, 11, 23, 10);
    final s = TrialState.start(start, deviceHash: 'abc123hash');
    final back = TrialState.fromJson(s.toJson());
    expect(back.trialUsed, true);
    expect(back.startedAt, start);
    expect(back.endsAt, start.add(const Duration(days: 7)));
    expect(back.deviceHash, 'abc123hash');
    expect(back.statusAt(start), TrialStatus.active);
    // Missing fields = never started (old installs / empty node).
    expect(TrialState.fromJson({}).statusAt(start), TrialStatus.notStarted);
  });

  // --- Device id hashing (pure, no platform channel) ---

  test('device hash is stable, hex, and never the raw id', () {
    final h1 = DeviceIdService.hashDeviceId('android-id-12345');
    final h2 = DeviceIdService.hashDeviceId('android-id-12345');
    expect(h1, h2);
    expect(h1.length, 64);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h1), true);
    expect(h1, isNot(contains('android-id-12345')));
    expect(DeviceIdService.hashDeviceId('other-id'), isNot(h1));
  });

  // --- TrialService: once PER DEVICE (demo mode, local only) ---
  //
  // The provider stands in for the platform channel: each hash is
  // one phone. All tests share one SharedPreferences store, like
  // phones share one RTDB — the per-device cache key is what keeps
  // their trials apart.

  group('TrialService — once per device', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test('trial starts once on a phone — second start refused', () async {
      final trial = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await trial.load();
      expect(trial.canStartTrial, true);
      expect(await trial.startTrial(), true);
      expect(trial.isActive, true);
      expect(trial.daysRemaining, 7);
      // Second start: refused, state unchanged.
      expect(await trial.startTrial(), false);
      expect(trial.isActive, true);
      expect(trial.daysRemaining, 7);
    });

    test('trial survives a fresh service = reinstall cannot restart it',
        () async {
      final first = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await first.load();
      expect(await first.startTrial(), true);
      // New instance, same prefs store, SAME device hash (like
      // reinstalling the app on the same phone): still used.
      final second = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await second.load();
      expect(second.canStartTrial, false);
      expect(await second.startTrial(), false);
      expect(second.isActive, true);
    });

    test('a different phone gets its own one trial', () async {
      final phoneA = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await phoneA.load();
      expect(await phoneA.startTrial(), true);
      // Same prefs store, DIFFERENT device hash: fresh trial.
      final phoneB = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-b',
      );
      await phoneB.load();
      expect(phoneB.canStartTrial, true);
      expect(await phoneB.startTrial(), true);
      expect(phoneB.isActive, true);
      // And phone A still has only its own trial.
      final phoneAAgain = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await phoneAAgain.load();
      expect(await phoneAAgain.startTrial(), false);
    });

    test('expired trial loaded from storage reports expired', () async {
      final prefs = await SharedPreferences.getInstance();
      final old = TrialState.start(
        DateTime.now().subtract(const Duration(days: 8)),
        deviceHash: 'hash-phone-a',
      );
      await prefs.setString(
        'trial_state_v1_hash-phone-a',
        jsonEncode(old.toJson()),
      );
      final trial = TrialService(
        deviceIdHashProvider: () async => 'hash-phone-a',
      );
      await trial.load();
      expect(trial.isExpired, true);
      expect(trial.daysRemaining, 0);
      expect(await trial.startTrial(), false);
    });
  });

  // --- Plan screen widget ---

  group('PlanScreen', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    TrialService widgetTrial() => TrialService(
          deviceIdHashProvider: () async => 'hash-widget-phone',
        );

    Future<void> pumpPlan(WidgetTester tester, TrialService trial) async {
      await trial.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LanguageService()),
            ChangeNotifierProvider.value(value: trial),
            // PlanScreen watches BillingService since v0.5 (real
            // Play Billing flow). Not initialized here — the
            // uninitialized service reports loading, which is the
            // state the widget must handle gracefully.
            ChangeNotifierProvider(create: (_) => BillingService()),
          ],
          child: const MaterialApp(
            home: Scaffold(body: PlanScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows start button, then days left after starting',
        (tester) async {
      final trial = widgetTrial();
      await pumpPlan(tester, trial);
      expect(find.text('Start 7-day free trial'), findsOneWidget);
      expect(find.text('Free trial active'), findsNothing);
      await tester.tap(find.text('Start 7-day free trial'));
      await tester.pumpAndSettle();
      expect(find.text('Free trial active'), findsOneWidget);
      expect(find.text('7 days left'), findsOneWidget);
      expect(find.text('Start 7-day free trial'), findsNothing);
    });

    testWidgets('expired trial shows ended message + subscribe button',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final old = TrialState.start(
        DateTime.now().subtract(const Duration(days: 8)),
        deviceHash: 'hash-widget-phone',
      );
      await prefs.setString(
        'trial_state_v1_hash-widget-phone',
        jsonEncode(old.toJson()),
      );
      final trial = widgetTrial();
      await pumpPlan(tester, trial);
      expect(find.text('Your free trial has ended'), findsOneWidget);
      // v0.5: the subscribe button is the real Play Billing flow
      // and is labelled "Buy — $5/year".
      expect(find.text('Buy — \$5/year'), findsOneWidget);
      expect(find.text('Start 7-day free trial'), findsNothing);
    });
  });
}
