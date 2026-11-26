import 'package:apnacircle/core/location_service.dart';
import 'package:apnacircle/core/osm_map.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/setup_service.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/screens/setup_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.19 (26 Nov 2026) — three user asks in one build:
/// (1) CARTO map tiles instead of OSM's own (cleaner streets and
/// labels, still free, no key); (2) a guided one-time setup wizard,
/// because parents cannot be expected to hunt every permission
/// through Settings; (3) a bigger map — the status card shrinks to
/// one line when sharing is fine, the members list is collapsed by
/// default, and tapping the map goes fullscreen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CARTO tiles (v0.6.19)', () {
    test('tile template is CARTO light, no key', () {
      expect(
        osmTileUrlTemplate,
        'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
      );
      expect(osmTileUrlTemplate, isNot(contains('key')));
    });

    test('attribution names CARTO as well as OSM', () {
      expect(osmAttributionText, contains('OpenStreetMap contributors'));
      expect(osmAttributionText, contains('CARTO'));
    });
  });

  group('setup steps', () {
    test('there are 7 steps, each with a title, why and button', () {
      expect(SetupStep.values.length, 7);
      for (final step in SetupStep.values) {
        expect(step.title, isNotEmpty);
        expect(step.why, isNotEmpty);
        expect(step.actionLabel, isNotEmpty);
      }
    });

    test('only location + notifications are required', () {
      final required = SetupStep.values.where((s) => s.isRequired).toSet();
      expect(
        required,
        {SetupStep.locationAlways, SetupStep.notifications},
      );
    });
  });

  group('SetupService persistence', () {
    test('markComplete survives a fresh load', () async {
      SharedPreferences.setMockInitialValues({});
      final first = SetupService();
      await first.load();
      expect(first.isComplete, isFalse);
      await first.markComplete();
      expect(first.isComplete, isTrue);

      final second = SetupService();
      await second.load();
      expect(second.isComplete, isTrue);
    });
  });

  group('compact sharing card', () {
    test('shows only when always + service running', () {
      expect(
        showCompactSharingCard(
          state: LocationSharingState.always,
          serviceRunning: true,
        ),
        isTrue,
      );
      expect(
        showCompactSharingCard(
          state: LocationSharingState.always,
          serviceRunning: false,
        ),
        isFalse,
      );
      expect(
        showCompactSharingCard(
          state: LocationSharingState.whileInUse,
          serviceRunning: true,
        ),
        isFalse,
      );
      expect(
        showCompactSharingCard(
          state: LocationSharingState.off,
          serviceRunning: true,
        ),
        isFalse,
      );
      expect(
        showCompactSharingCard(
          state: null,
          serviceRunning: true,
        ),
        isFalse,
      );
    });
  });

  group('map screen — bigger map', () {
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

    Future<void> pumpHome(WidgetTester tester) async {
      final auth = AuthService();
      final sync = SyncService(auth);
      final family = FamilyService()..attachSync(sync);
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
    }

    testWidgets('members list is collapsed by default, expands on tap',
        (tester) async {
      await pumpHome(tester);

      // The demo family seeds 3 members — the header shows them.
      expect(find.text('Family (3)'), findsOneWidget);
      // Collapsed: the list has zero height.
      final collapsed = tester.getSize(find.byType(ListView)).height;
      expect(collapsed, 0);

      await tester.tap(find.text('Family (3)'));
      await tester.pump();
      final expanded = tester.getSize(find.byType(ListView)).height;
      expect(expanded, 220);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('tapping the map goes fullscreen, close exits it',
        (tester) async {
      await pumpHome(tester);

      expect(find.byIcon(Icons.close), findsNothing);
      // Tap the map's top-left corner: the demo member sits
      // exactly at the map centre, and a tap on a marker does not
      // reach the map's onTap.
      final mapTopLeft = tester.getTopLeft(find.byType(FlutterMap));
      await tester.tapAt(mapTopLeft + const Offset(80, 80));
      // flutter_map waits out its 250 ms double-tap window before
      // firing a single tap — advance the clock past it.
      await tester.pump(const Duration(milliseconds: 300));
      // Fullscreen: the close button appears and the bottom
      // navigation bar (with the Map tab) is gone.
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Map'), findsNothing);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Map'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('setup screen', () {
    testWidgets('shows all 7 steps with Done and Skip', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final setup = SetupService();
      await setup.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: setup,
            child: const SetupScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Setup — ApnaCircle'), findsOneWidget);
      for (final step in SetupStep.values) {
        // The list is lazy — scroll each step into view first.
        await tester.ensureVisible(
          find.textContaining(step.title),
        );
        await tester.pump();
        expect(find.textContaining(step.title), findsOneWidget);
      }
      expect(find.text('Done — go to the map'), findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
    });
  });
}
