// v0.6.28 tests — parent's own apps lock again + circle delete.
//
// ROOT CAUSE of the re-lock (27 Nov 2026, after installing v0.6.27):
// a fresh install leaves NO circle active (the refresh only
// replaced a STALE active id, never a null one), so Home's admin
// wipe never ran — and every `?? false` admin check treated the
// parent as a child, applying the child's lock list to the
// parent's OWN phone. v0.6.28: (1) the first circle becomes active
// automatically when the list loads; (2) admin checks FAIL CLOSED
// (unknown != not-admin); (3) the admin wipe runs on EVERY Home
// visit, not once; (4) a parent circle can be deleted from
// Account & Circles (rules v6 let the creator delete info).
import 'package:apnacircle/core/app_lock_service.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/screens/circle_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/firebase_bootstrap.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('mayApplyLocally fails closed (v0.6.28)', () {
    test('unknown admin status (null) must NOT apply locally', () {
      expect(AppLockService.mayApplyLocally(isAdmin: null), isFalse);
    });

    test('admin must NOT apply locally', () {
      expect(AppLockService.mayApplyLocally(isAdmin: true), isFalse);
    });

    test('explicit non-admin MAY apply locally', () {
      expect(AppLockService.mayApplyLocally(isAdmin: false), isTrue);
    });
  });

  group('resolveActiveCircleId (v0.6.28)', () {
    test('keeps the current circle when it is still in the list', () {
      expect(
        resolveActiveCircleId(
          currentActiveId: 'c2',
          circleIds: ['c1', 'c2', 'c3'],
        ),
        'c2',
      );
    });

    test('null current id takes the first circle', () {
      expect(
        resolveActiveCircleId(
          currentActiveId: null,
          circleIds: ['c1', 'c2'],
        ),
        'c1',
      );
    });

    test('stale current id takes the first circle', () {
      expect(
        resolveActiveCircleId(
          currentActiveId: 'gone',
          circleIds: ['c1', 'c2'],
        ),
        'c1',
      );
    });

    test('no circles at all stays null', () {
      expect(
        resolveActiveCircleId(currentActiveId: null, circleIds: []),
        isNull,
      );
      expect(
        resolveActiveCircleId(currentActiveId: 'c1', circleIds: []),
        isNull,
      );
    });
  });

  group('CircleScreen delete button (v0.6.28)', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('parent circles show delete, child circles do not; '
        'tap opens the confirm dialog, then the PIN gate',
        (tester) async {
      // AuthService's ctor touches FirebaseAuth ONLY when
      // FirebaseBootstrap.available is true — so build every fake
      // BEFORE flipping the flag, or construction throws
      // [core/no-app] in tests (no Firebase app is initialised).
      final auth = _FakeAuth0628();
      final sync = _FakeSync0628();
      final family = FamilyService();
      FirebaseBootstrap.available = true;
      addTearDown(() => FirebaseBootstrap.available = false);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthService>.value(
              value: auth,
            ),
            ChangeNotifierProvider<SyncService>.value(value: sync),
            ChangeNotifierProvider<FamilyService>.value(value: family),
            ChangeNotifierProvider<PinService>.value(value: PinService()),
          ],
          child: const MaterialApp(home: CircleScreen()),
        ),
      );
      await tester.pump();

      // 3 parent circles (apna ghr + 2 accidental "Family") get a
      // delete button each; the child-role circle gets none.
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(3));
      expect(find.text('apna ghr'), findsOneWidget);
      expect(find.text('Family'), findsNWidgets(2));

      // Tapping a delete button asks for confirmation first.
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(find.text('Delete "apna ghr"?'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      // Confirming opens the parent-PIN gate — the delete itself
      // only runs on a correct PIN (never completed here).
      await tester.tap(find.text('Delete').last);
      await tester.pump();
      expect(find.text('Parent PIN'), findsOneWidget);
      expect(sync.deletedCircleIds, isEmpty);
    });
  });
}

class _FakeAuth0628 extends AuthService {
  @override
  bool get signedIn => true;

  @override
  String? get email => 'tabasam1414@gmail.com';
}

class _FakeSync0628 extends SyncService {
  _FakeSync0628() : super(AuthService());

  final List<String> deletedCircleIds = [];

  @override
  bool get isAvailable => true;

  @override
  String? get uid => 'u1';

  @override
  String? get activeCircleId => 'c1';

  @override
  List<CircleInfo> get myCircles => const [
        CircleInfo(
          id: 'c1',
          name: 'apna ghr',
          role: 'parent',
          inviteCode: '660287',
        ),
        CircleInfo(
          id: 'c2',
          name: 'Family',
          role: 'parent',
          inviteCode: '554682',
        ),
        CircleInfo(
          id: 'c3',
          name: 'Family',
          role: 'parent',
          inviteCode: '902741',
        ),
        CircleInfo(
          id: 'c4',
          name: 'Neighbours',
          role: 'child',
          inviteCode: '111222',
        ),
      ];

  @override
  Future<void> setActiveCircle(String circleId) async {}

  @override
  Future<void> refreshMyCircles() async {}

  @override
  Future<String?> fetchPinHash(String circleId) async => null;

  @override
  Future<bool> deleteCircle(String circleId) async {
    deletedCircleIds.add(circleId);
    return true;
  }
}
