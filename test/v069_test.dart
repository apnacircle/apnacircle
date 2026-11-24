import 'dart:convert';

import 'package:apnacircle/core/alerts.dart';
import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/core/chat_paging.dart';
import 'package:apnacircle/core/location_service.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/screens/location_status_card.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/background_location_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Alert toggle that turns itself off (v0.6.9).
///
/// User-reported 24 Nov 2026 ~10:01 PKT: "Alert system be thek nhi
/// Kam kr rha. On krta hon wi khud hi off ho Jata hai" — an alert
/// switched ON reverted to OFF on its own.
///
/// Cause: the members node in RTDB never carries alert changes
/// (publishMyLocation writes lat/lon/battery only; alerts live in
/// the separate `alerts/{memberId}` node), so every members
/// snapshot arrived with the join-time alerts and overwrote the
/// toggle — then _save() persisted the reverted value. The child's
/// phone was offline, so no round-trip ever refreshed it.
///
/// Fix: FamilyService.applyRemoteMembers keeps each existing
/// member's LOCAL alerts when merging a remote snapshot; only the
/// alerts node (subscribeAlerts) may change them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  Member member(String id, String name,
      {Map<AlertType, bool>? alerts, double? lat, double? lon}) {
    return Member(
      id: id,
      name: name,
      phone: '+92300$id',
      role: id == 'parent' ? 'parent' : 'child',
      alerts: alerts,
      lat: lat,
      lon: lon,
    );
  }

  group('alert toggle survives a stale members snapshot (v0.6.9)', () {
    test('ON toggle stays ON after a snapshot with join-time alerts',
        () async {
      final family = FamilyService();
      family.addMember(member('parent', 'Mujahid'));
      family.addMember(
        member('child', 'Bacha', alerts: {AlertType.sos: false}),
      );

      // Parent turns the SOS alert ON for the child.
      family.setAlert('child', AlertType.sos, true);
      expect(
        family.members
            .firstWhere((m) => m.id == 'child')
            .alerts[AlertType.sos],
        isTrue,
      );

      // A members snapshot arrives from RTDB carrying the
      // join-time alerts (SOS still false) plus a fresh location.
      family.applyRemoteMembers([
        member('parent', 'Mujahid'),
        member('child', 'Bacha',
            alerts: {AlertType.sos: false}, lat: 33.6, lon: 73.0),
      ]);

      final child =
          family.members.firstWhere((m) => m.id == 'child');
      // The toggle survives...
      expect(child.alerts[AlertType.sos], isTrue);
      // ...while the rest of the snapshot still applies.
      expect(child.lat, 33.6);
      expect(child.lon, 73.0);
    });

    test('OFF toggle stays OFF after a snapshot with alerts ON',
        () async {
      final family = FamilyService();
      family.addMember(member('parent', 'Mujahid'));
      family.addMember(
        member('child', 'Bacha', alerts: {AlertType.sos: true}),
      );

      family.setAlert('child', AlertType.sos, false);
      family.applyRemoteMembers([
        member('parent', 'Mujahid'),
        member('child', 'Bacha', alerts: {AlertType.sos: true}),
      ]);

      expect(
        family.members
            .firstWhere((m) => m.id == 'child')
            .alerts[AlertType.sos],
        isFalse,
      );
    });

    test('a member new to this phone is added as-is from the snapshot',
        () async {
      final family = FamilyService();
      family.addMember(member('parent', 'Mujahid'));

      family.applyRemoteMembers([
        member('parent', 'Mujahid'),
        member('child', 'Bacha', alerts: {AlertType.sos: true}),
      ]);

      expect(family.members, hasLength(2));
      expect(
        family.members
            .firstWhere((m) => m.id == 'child')
            .alerts[AlertType.sos],
        isTrue,
      );
    });

    test('setAlert for an unknown member is a no-op, not a crash',
        () async {
      final family = FamilyService();
      family.addMember(member('parent', 'Mujahid'));

      family.setAlert('no-such-child', AlertType.sos, true);

      expect(family.members, hasLength(1));
    });
  });

  group('LockSettings JSON (v0.6.9)', () {
    test('round-trip keeps apps + both switches', () {
      const settings = LockSettings(
        apps: [
          LockedApp(
            name: 'YouTube',
            packageName: 'com.google.android.youtube',
          ),
        ],
        locationLocked: false,
        internetAlert: false,
      );
      final back = LockSettings.fromJson(settings.toJson());
      expect(back.apps, hasLength(1));
      expect(back.apps.first.packageName, 'com.google.android.youtube');
      expect(back.locationLocked, isFalse);
      expect(back.internetAlert, isFalse);
    });

    test('old node (apps only) reads back with both switches ON', () {
      final settings = LockSettings.fromJson({
        'apps': [
          {'name': 'YouTube', 'package': 'com.google.android.youtube'},
        ],
      });
      expect(settings.apps, hasLength(1));
      expect(settings.locationLocked, isTrue);
      expect(settings.internetAlert, isTrue);
    });

    test('empty node gives defaults (no apps, both switches ON)', () {
      final settings = LockSettings.fromJson(<String, dynamic>{});
      expect(settings.apps, isEmpty);
      expect(settings.locationLocked, isTrue);
      expect(settings.internetAlert, isTrue);
    });

    test('one bad app entry does not drop the whole list', () {
      final settings = LockSettings.fromJson({
        'apps': [
          {'name': 'YouTube', 'package': 'com.google.android.youtube'},
          {'bogus': true},
          {'name': 'Chrome', 'package': 'com.android.chrome'},
        ],
      });
      expect(
        settings.apps.map((a) => a.packageName),
        ['com.google.android.youtube', 'com.android.chrome'],
      );
    });
  });

  group('InternetOffTracker (v0.6.9)', () {
    test('always online reports nothing', () {
      final tracker = InternetOffTracker();
      final now = DateTime(2026, 11, 24, 10, 0);
      expect(tracker.check(online: true, now: now), isNull);
      expect(
        tracker.check(online: true, now: now.add(const Duration(minutes: 5))),
        isNull,
      );
    });

    test('short blip under 2 minutes is ignored', () {
      final tracker = InternetOffTracker();
      final t0 = DateTime(2026, 11, 24, 10, 0);
      expect(tracker.check(online: false, now: t0), isNull);
      expect(
        tracker.check(online: true, now: t0.add(const Duration(minutes: 1))),
        isNull,
      );
    });

    test('offline 5 minutes then back reports the offline start', () {
      final tracker = InternetOffTracker();
      final t0 = DateTime(2026, 11, 24, 10, 0);
      tracker.check(online: false, now: t0);
      tracker.check(online: false, now: t0.add(const Duration(minutes: 3)));
      expect(
        tracker.check(online: true, now: t0.add(const Duration(minutes: 5))),
        t0,
      );
    });

    test('exactly 2 minutes counts', () {
      final tracker = InternetOffTracker();
      final t0 = DateTime(2026, 11, 24, 10, 0);
      tracker.check(online: false, now: t0);
      expect(
        tracker.check(online: true, now: t0.add(const Duration(minutes: 2))),
        t0,
      );
    });

    test('reports only once per window; a second window reports again',
        () {
      final tracker = InternetOffTracker();
      final t0 = DateTime(2026, 11, 24, 10, 0);
      tracker.check(online: false, now: t0);
      expect(
        tracker.check(online: true, now: t0.add(const Duration(minutes: 5))),
        t0,
      );
      expect(
        tracker.check(online: true, now: t0.add(const Duration(minutes: 6))),
        isNull,
      );
      final t1 = t0.add(const Duration(minutes: 10));
      tracker.check(online: false, now: t1);
      expect(
        tracker.check(online: true, now: t1.add(const Duration(minutes: 3))),
        t1,
      );
    });
  });

  group('alerts end-to-end with a fake SyncService (v0.6.9)', () {
    late _FakeSync sync;
    late FamilyService family;

    Map<AlertType, bool> defaultAlerts() => {
          for (final a in AlertType.values)
            a: a != AlertType.shakeSos && a != AlertType.autoCall1122,
        };

    Member seedMember(String id, String name, String phone, String role) =>
        Member(
          id: id,
          name: name,
          phone: phone,
          role: role,
          alerts: defaultAlerts(),
        );

    List<Member> remoteMembers() => [
          const Member(
            id: 'u1',
            name: 'Me',
            phone: '+923001111111',
            role: 'parent',
          ),
          const Member(
            id: 'u2',
            name: 'Kid',
            phone: '+923002222222',
            role: 'child',
          ),
        ];

    Map<AlertType, bool> serverAlerts({required bool shakeSos}) => {
          for (final a in AlertType.values)
            a: a == AlertType.shakeSos
                ? shakeSos
                : a != AlertType.autoCall1122,
        };

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'family_members_v1': jsonEncode([
          seedMember('u1', 'Me', '+923001111111', 'parent').toJson(),
          seedMember('u2', 'Kid', '+923002222222', 'child').toJson(),
        ]),
      });
      sync = _FakeSync()..publishOk = false;
      family = FamilyService()..attachSync(sync);
      await family.load();
    });

    test('toggle survives refresh + stale server value; retry publishes',
        () async {
      // Parent turns Shake SOS ON; the publish fails (offline).
      family.setAlert('u1', AlertType.shakeSos, true);
      await Future<void>.delayed(Duration.zero);
      expect(
        family.members
            .firstWhere((m) => m.id == 'u1')
            .alerts[AlertType.shakeSos],
        isTrue,
      );
      expect(sync.publishedAlerts, hasLength(1));
      expect(sync.publishedAlerts.single[AlertType.shakeSos], isTrue);

      // A members refresh arrives (RTDB member nodes carry no alerts).
      // It also retries the pending publish — still offline, so it
      // fails again and the toggle must still stay ON.
      sync.membersCallback!(remoteMembers());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        family.members
            .firstWhere((m) => m.id == 'u1')
            .alerts[AlertType.shakeSos],
        isTrue,
        reason: 'members refresh must not wipe the local ON',
      );
      expect(sync.publishedAlerts, hasLength(2));

      // The server still says OFF (stale) — must not clobber it
      // while the local change is still unpublished.
      sync.alertsCallback!(serverAlerts(shakeSos: false));
      await Future<void>.delayed(Duration.zero);
      expect(
        family.members
            .firstWhere((m) => m.id == 'u1')
            .alerts[AlertType.shakeSos],
        isTrue,
      );

      // Back online: the next members event retries the publish.
      sync.publishOk = true;
      sync.membersCallback!(remoteMembers());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sync.publishedAlerts, hasLength(3));
      expect(sync.publishedAlerts.last[AlertType.shakeSos], isTrue);

      // Pending cleared — a server value now applies again.
      sync.alertsCallback!(serverAlerts(shakeSos: false));
      await Future<void>.delayed(Duration.zero);
      expect(
        family.members
            .firstWhere((m) => m.id == 'u1')
            .alerts[AlertType.shakeSos],
        isFalse,
      );
    });

    test('pending publish survives an app restart', () async {
      family.setAlert('u1', AlertType.shakeSos, true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sync.publishedAlerts, hasLength(1));

      // Simulated restart: a fresh FamilyService on the same
      // (mock) SharedPreferences — members + pending both reload.
      final sync2 = _FakeSync()..publishOk = true;
      final family2 = FamilyService()..attachSync(sync2);
      await family2.load();
      expect(
        family2.members
            .firstWhere((m) => m.id == 'u1')
            .alerts[AlertType.shakeSos],
        isTrue,
      );

      // A members event proves we are online again: the pending
      // publish is retried.
      sync2.membersCallback!(remoteMembers());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(sync2.publishedAlerts, hasLength(1));
      expect(sync2.publishedAlerts.single[AlertType.shakeSos], isTrue);
    });
  });

  group('LocationStatusCard — parent lock wording (v0.6.9)', () {
    Future<void> pumpCard(
      WidgetTester tester,
      LocationSharingState? state,
      bool locked,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationStatusCard(
              state: state,
              serviceRunning: false,
              locationLocked: locked,
              onFix: () {},
              onRefresh: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('sharing OFF + locked says the parent locked it',
        (tester) async {
      await pumpCard(tester, LocationSharingState.off, true);
      expect(
        find.text(
          'Location is locked by your parent — turn sharing back on.',
        ),
        findsOneWidget,
      );
      expect(find.text('Turn on always'), findsOneWidget);
    });

    testWidgets('sharing OFF + not locked keeps the plain wording',
        (tester) async {
      await pumpCard(tester, LocationSharingState.off, false);
      expect(
        find.text(
          'Your family cannot see your location at all. Turn location sharing on.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('sharing always + locked keeps the ON wording',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationStatusCard(
              state: LocationSharingState.always,
              serviceRunning: true,
              locationLocked: true,
              onFix: () {},
              onRefresh: () {},
            ),
          ),
        ),
      );
      expect(
        find.text(
          'Your family can see you even when the app is closed.',
        ),
        findsOneWidget,
      );
    });
  });
}

/// Fake SyncService: reports online with a fixed circle/uid, records
/// alert publishes (with a flippable success flag), and lets the
/// test drive the remote callbacks by hand.
class _FakeSync extends SyncService {
  _FakeSync() : super(AuthService());

  @override
  bool get isAvailable => true;

  @override
  String? get uid => 'u1';

  @override
  String? get activeCircleId => 'c1';

  bool publishOk = true;
  final List<Map<AlertType, bool>> publishedAlerts = [];
  void Function(List<Member>)? membersCallback;
  void Function(Map<AlertType, bool>)? alertsCallback;

  @override
  Future<bool> publishAlerts(
    String circleId,
    String memberId,
    Map<AlertType, bool> alerts,
  ) async {
    publishedAlerts.add(Map.of(alerts));
    return publishOk;
  }

  @override
  void subscribeMembers(
    String circleId,
    void Function(List<Member>) onData,
  ) {
    membersCallback = onData;
  }

  @override
  void subscribeAlerts(
    String circleId,
    String memberId,
    void Function(Map<AlertType, bool>) onData,
  ) {
    alertsCallback = onData;
  }

  @override
  void subscribeEvents(
    String circleId,
    void Function(CircleEvent) onData,
  ) {}

  // v0.6.11: FamilyService also subscribes to chat — the fake
  // must stub it, or the real implementation hits Firebase and
  // the test crashes (no Firebase app in tests).
  void Function(List<ChatMessage>)? chatCallback;

  @override
  void subscribeChat(
    String circleId,
    void Function(List<ChatMessage>) onData, {
    int limit = chatPageSize,
  }) {
    chatCallback = onData;
  }
}
