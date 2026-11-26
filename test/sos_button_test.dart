import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/media_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.1 regression test for the SOS button layout bug reported from
/// the user's phone (23 Nov 2026 ~09:24 PKT): on the Map screen the
/// red floating SOS button covered the last member row (Ammi), and
/// its label read "SOS SOS" (the Icons.sos glyph IS the letters SOS,
/// next to a Text('SOS') label).
///
/// The fix: a non-text siren icon (Icons.emergency) + 88 px bottom
/// padding on the members list, so the last row scrolls fully clear
/// of the button on any screen height.
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

    // connectivity_plus event channel: accept the 'listen' call and
    // never emit an event (an unmocked event channel would deliver
    // an error into the offline stream with no error handler).
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
          ChangeNotifierProvider.value(
            value: CallService(family: family),
          ),
          ChangeNotifierProvider.value(
            value: AlertHistoryService(family: family),
          ),
          ChangeNotifierProvider.value(
            value: ChatDeleteService(family: family),
          ),
            Provider.value(value: MediaService(sync)),
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

  testWidgets('SOS label appears exactly once, no SOS text icon',
      (tester) async {
    await pumpHome(tester);

    // One "SOS" text only — the old button showed "SOS SOS".
    expect(find.text('SOS'), findsOneWidget);
    // The icon must not be the letters-SOS glyph anymore.
    expect(find.byIcon(Icons.sos), findsNothing);
    expect(find.byIcon(Icons.emergency), findsOneWidget);
    // Still a big red extended button. (v0.6.15: the map also has
    // a small follow-me FAB, so the finder must name the SOS one —
    // the follow-me button has no text.)
    final fab = tester.widget<FloatingActionButton>(
      find.widgetWithText(FloatingActionButton, 'SOS'),
    );
    expect(fab.backgroundColor, Colors.red);

    // Dispose the screen so its 60 s location timer is cancelled.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('members list clears the SOS button — last row never covered',
      (tester) async {
    await pumpHome(tester);

    // The demo family seeds 3 members; Ammi is the last row — the
    // one the SOS button used to cover.
    final listView = tester.widget<ListView>(
      find.ancestor(
        of: find.text('Ammi'),
        matching: find.byType(ListView),
      ),
    );
    final padding = listView.padding as EdgeInsets;
    // FAB is 56 high + 16 bottom margin; 88 clears it with spare.
    expect(padding.bottom, greaterThanOrEqualTo(88.0));

    // Scroll the list to the very end, then the last row must not
    // touch the SOS button at all.
    final listFinder = find.ancestor(
      of: find.text('Ammi'),
      matching: find.byType(ListView),
    );
    await tester.drag(listFinder, const Offset(0, -1000));
    await tester.pump();
    // v0.6.15: the follow-me FAB is a second FloatingActionButton
    // on the map — name the SOS one here, as above.
    final fabRect =
        tester.getRect(find.widgetWithText(FloatingActionButton, 'SOS'));
    final ammiRect = tester.getRect(find.text('Ammi'));
    expect(fabRect.overlaps(ammiRect), isFalse,
        reason: 'SOS button must never cover the last member row');

    // And the last row is fully on screen and tappable.
    expect(ammiRect.top, greaterThanOrEqualTo(0));
    expect(
      ammiRect.bottom,
      lessThanOrEqualTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio),
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
