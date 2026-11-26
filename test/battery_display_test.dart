import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.2 regression test for the battery bug reported from the
/// user's phone (23 Nov 2026 ~09:40 PKT): member "iza" showed
/// "Battery -1%" on the Map screen. The battery plugin returns -1
/// when it cannot read a level, and the app printed that sentinel
/// literally. The fix: -1 (or null / out of 0–100) is UNKNOWN and
/// shows no battery part at all; a real level still shows
/// "Battery 81%".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // Geolocator: permission denied, so HomeMapScreen's location
    // loop returns early instead of calling the real GPS plugin.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async {
        if (call.method == 'checkPermission') return 0; // denied
        return null;
      },
    );

    // connectivity_plus: pretend we are on Wi-Fi (online), so the
    // screen never shows the offline banner or the SMS dialog.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async {
        if (call.method == 'checkConnectivity') return <String>['wifi'];
        return null;
      },
    );

    // connectivity_plus event channel: accept 'listen' and never
    // emit an event.
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

  Member member(String name, {int battery = -1}) => Member(
        id: name.toLowerCase(),
        name: name,
        phone: '+92300${name.hashCode.abs() % 900000 + 100000}',
        isOnline: true,
        battery: battery,
      );

  group('Member batteryLabel', () {
    test('unknown (-1) has no battery text', () {
      final m = member('Iza', battery: -1);
      expect(m.hasKnownBattery, isFalse);
      expect(m.batteryLabel, isEmpty);
    });

    test('missing battery in JSON defaults to unknown', () {
      final m = Member.fromJson({
        'id': 'iza',
        'name': 'Iza',
        'phone': '+923001111111',
        'isOnline': true,
      });
      expect(m.battery, -1);
      expect(m.hasKnownBattery, isFalse);
      expect(m.batteryLabel, isEmpty);
    });

    test('out-of-range values are unknown too', () {
      expect(member('A', battery: -5).hasKnownBattery, isFalse);
      expect(member('B', battery: 101).hasKnownBattery, isFalse);
      expect(member('C', battery: 150).batteryLabel, isEmpty);
    });

    test('real levels keep showing "Battery N%"', () {
      expect(member('A', battery: 0).batteryLabel, 'Battery 0%');
      expect(member('B', battery: 81).batteryLabel, 'Battery 81%');
      expect(member('C', battery: 100).batteryLabel, 'Battery 100%');
    });
  });

  Future<void> pumpHome(
    WidgetTester tester,
    FamilyService family,
  ) async {
    final auth = AuthService();
    final sync = SyncService(auth);
    family.attachSync(sync);
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
          ChangeNotifierProvider.value(
            value: CallService(family: family),
          ),
          ChangeNotifierProvider.value(
            value: AlertHistoryService(family: family),
          ),
          ChangeNotifierProvider.value(
            value: ChatDeleteService(family: family),
          ),
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

  testWidgets('stale battery (older than 30 min) is marked "(old)"',
      (tester) async {
    final family = FamilyService();
    // Fresh level: shows plain "Battery 81%".
    family.addMember(Member(
      id: 'bilal',
      name: 'Bilal',
      phone: '+923002222222',
      isOnline: true,
      battery: 81,
      batteryAt: DateTime.now().subtract(const Duration(minutes: 5)),
    ));
    // Stale level: the same 82% the user saw frozen for 3.5 hours.
    family.addMember(Member(
      id: 'mujahid',
      name: 'Mujahid',
      phone: '+923001111111',
      isOnline: true,
      battery: 82,
      batteryAt: DateTime.now().subtract(const Duration(minutes: 200)),
    ));
    await pumpHome(tester, family);

    expect(find.textContaining('Battery 81%'), findsOneWidget);
    expect(find.textContaining('Battery 82% (old)'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('unknown battery renders no "-1%" text', (tester) async {
    final family = FamilyService();
    // Pre-seed the members so the demo family is NOT seeded on top.
    family.addMember(member('Iza', battery: -1));
    family.addMember(member('Bilal', battery: 81));
    await pumpHome(tester, family);

    // Nowhere on the screen may the sentinel appear.
    expect(find.textContaining('-1%'), findsNothing);
    expect(find.textContaining('Battery -1'), findsNothing);

    // Iza's row shows online + distance only, no battery part.
    expect(find.text('Online · — away'), findsOneWidget);
    // A real level still shows exactly as before.
    expect(find.textContaining('Battery 81%'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
