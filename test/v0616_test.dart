import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/core/remove_member.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remove a member (v0.6.16, 25 Nov 2026): the user asked — "Agr
/// kisi child ko remove krna ho tu wo option be hona chaye". The
/// service plumbing already existed (FamilyService.removeMember +
/// SyncService.removeMemberNode) but NO UI called it. Now the
/// parent's member list has a "⋮" menu per row (never on their own
/// row, never for a child): confirm dialog → parent PIN → removal.
/// These tests pin the guard, the service and the widget flow.
void main() {
  group('canRemoveMember (pure guard)', () {
    test('parent can remove another member', () {
      expect(
        canRemoveMember(
          isAdmin: true,
          myUid: 'parent-uid',
          targetMemberId: 'child-uid',
        ),
        isTrue,
      );
    });

    test('a child can never remove anyone', () {
      expect(
        canRemoveMember(
          isAdmin: false,
          myUid: 'child-uid',
          targetMemberId: 'other-uid',
        ),
        isFalse,
      );
    });

    test('the parent can never remove themselves', () {
      expect(
        canRemoveMember(
          isAdmin: true,
          myUid: 'parent-uid',
          targetMemberId: 'parent-uid',
        ),
        isFalse,
      );
    });

    test('unknown identity (no uid) can remove nobody', () {
      expect(
        canRemoveMember(
          isAdmin: true,
          myUid: null,
          targetMemberId: 'child-uid',
        ),
        isFalse,
      );
    });
  });

  group('FamilyService.removeMember', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('parent removes another member (demo family)', () async {
      final family = FamilyService()..seedDemoFamily();
      final (ok, error) = await family.removeMember('ali');
      expect(ok, isTrue);
      expect(error, isNull);
      expect(
        family.members.map((m) => m.id).toList(),
        isNot(contains('ali')),
      );
      expect(family.memberCount, 2);
    });

    test('the parent can never remove themselves', () async {
      final family = FamilyService()..seedDemoFamily();
      final (ok, error) = await family.removeMember('me');
      expect(ok, isFalse);
      expect(error, contains('yourself'));
      expect(family.memberCount, 3);
    });

    test('removing someone already gone is a no-op with a plain message',
        () async {
      final family = FamilyService()..seedDemoFamily();
      final (firstOk, _) = await family.removeMember('ali');
      expect(firstOk, isTrue);
      final (ok, error) = await family.removeMember('ali');
      expect(ok, isFalse);
      expect(error, contains('already gone'));
      expect(family.memberCount, 2);
    });

    test('a child cannot remove anyone (synced child role)', () async {
      SharedPreferences.setMockInitialValues({
        'active_circle_id': 'c1',
        'my_circles_v1':
            '[{"id":"c1","name":"apna ghr","role":"child","inviteCode":"660287"}]',
      });
      final sync = SyncService(AuthService());
      await sync.load();
      final family = FamilyService()
        ..attachSync(sync)
        ..seedDemoFamily();
      final (ok, error) = await family.removeMember('ali');
      expect(ok, isFalse);
      expect(error, contains('Only the parent'));
      expect(family.memberCount, 3);
    });
  });

  group('remove member in the member list (widget)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async {
          if (call.method == 'checkPermission') return 0; // denied
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async {
          if (call.method == 'checkConnectivity') return <String>['wifi'];
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
        'dev.fluttercommunity.plus/connectivity_status',
        (message) async {
          const codec = StandardMethodCodec();
          final call = codec.decodeMethodCall(message);
          if (call.method == 'listen' || call.method == 'cancel') {
            return codec.encodeSuccessEnvelope(null);
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
        'dev.fluttercommunity.plus/connectivity_status',
        null,
      );
    });

    /// Pumps the Map tab with the demo family seeded (Mujahid the
    /// parent, Ali + Ammi). The cached circle role decides parent
    /// vs child — 'parent' by default. The parent PIN is 1234.
    Future<void> pumpHome(
      WidgetTester tester, {
      String role = 'parent',
    }) async {
      SharedPreferences.setMockInitialValues({
        'active_circle_id': 'c1',
        'my_circles_v1':
            '[{"id":"c1","name":"apna ghr","role":"$role","inviteCode":"660287"}]',
      });
      final auth = AuthService();
      final sync = SyncService(auth);
      await sync.load();
      final family = FamilyService()..attachSync(sync);
      final pin = PinService();
      await pin.setPin('1234');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LanguageService()),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider(create: (_) => TrialService()),
            ChangeNotifierProvider(create: (_) => BillingService()),
            ChangeNotifierProvider.value(
              value: NotificationService(sync),
            ),
            ChangeNotifierProvider.value(value: family),
            ChangeNotifierProvider.value(value: pin),
            Provider.value(value: SmsLocationService()),
          ],
          child: const MaterialApp(home: HomeMapScreen()),
        ),
      );
      // No pumpAndSettle: the screen runs a 60 s periodic location
      // timer, which would make pumpAndSettle time out.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // v0.6.19: the members list is collapsed by default — expand
      // it so the member rows are laid out and tappable.
      await tester.tap(find.textContaining('Family ('));
      await tester.pump();
    }

    /// Pump several small frames: a single big pump does NOT
    /// advance route animations (popup menu / dialogs) — the first
    /// frame anchors the ticker, so the animation needs real
    /// frames. pumpAndSettle is out (the screen's 60 s location
    /// timer never settles).
    Future<void> pumpFrames(
      WidgetTester tester, {
      int count = 5,
      Duration step = const Duration(milliseconds: 100),
    }) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(step);
      }
    }

    /// Opens the "⋮" menu on the first removable row (Ali's) and
    /// picks "Remove from circle", then confirms the dialog.
    Future<void> startRemoval(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await pumpFrames(tester);
      await tester.tap(find.text('Remove from circle'));
      await pumpFrames(tester);
      expect(find.text('Remove Ali?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await pumpFrames(tester);
      expect(find.text('Parent PIN'), findsOneWidget);
    }

    testWidgets('parent sees the ⋮ menu on other members, never on '
        'their own row', (tester) async {
      await pumpHome(tester);
      expect(find.text('Mujahid'), findsOneWidget);
      expect(find.text('Ali'), findsOneWidget);
      expect(find.text('Ammi'), findsOneWidget);
      // 3 members, but only Ali + Ammi have the menu — the
      // parent's own row never does.
      expect(find.byIcon(Icons.more_vert), findsNWidgets(2));
    });

    testWidgets('full flow: confirm + correct PIN removes the member',
        (tester) async {
      await pumpHome(tester);
      await startRemoval(tester);
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('Unlock'));
      await pumpFrames(tester);
      expect(find.text('Ali removed from the circle.'), findsOneWidget);
      expect(find.text('Ali'), findsNothing);
      // The other members stay put.
      expect(find.text('Mujahid'), findsOneWidget);
      expect(find.text('Ammi'), findsOneWidget);
    });

    testWidgets('wrong PIN blocks the removal', (tester) async {
      await pumpHome(tester);
      await startRemoval(tester);
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text('Unlock'));
      await pumpFrames(tester);
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      expect(find.text('Ali'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);
      expect(find.text('Ali'), findsOneWidget);
    });

    testWidgets('a child phone never sees the ⋮ menu', (tester) async {
      await pumpHome(tester, role: 'child');
      expect(find.text('Ali'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });
}
