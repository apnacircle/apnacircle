import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/media_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sos_sms_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.24 — bottom-bar order is Chat first, then Map, then
/// Alerts, Locks, Plan, Settings. The app still OPENS on the
/// Map (the live locations are the home screen).
void main() {
  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthService();
    final sync = SyncService(auth);
    final family = FamilyService()..attachSync(sync);
    final sms = SmsLocationService();
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
          Provider.value(value: sms),
          Provider.value(value: SosSmsService(sms)),
        ],
        child: const MaterialApp(home: HomeMapScreen()),
      ),
    );
    await tester.pump();
  }

  List<String> navLabels(WidgetTester tester) {
    final bar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    return bar.items.map((i) => i.label ?? '').toList();
  }

  testWidgets('bottom bar order is Chat, Map, Alerts, Locks, Plan, Settings',
      (tester) async {
    await pumpHome(tester);
    expect(
      navLabels(tester),
      ['Chat', 'Map', 'Alerts', 'Locks', 'Plan', 'Settings'],
    );
  });

  testWidgets('app still opens on the Map tab', (tester) async {
    await pumpHome(tester);
    // The Map tab shows the SOS button; the Chat tab's header
    // ("Family chat") is not on screen.
    expect(find.text('SOS'), findsOneWidget);
    expect(find.text('Family chat'), findsNothing);
  });

  testWidgets('tapping Chat opens the chat, tapping Map goes back',
      (tester) async {
    await pumpHome(tester);
    await tester.tap(find.text('Chat'));
    // Let the SOS FAB finish its exit animation — while it is
    // animating out it still covers the Chat tab's buttons.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Family chat'), findsOneWidget);
    expect(find.text('SOS'), findsNothing);
    await tester.tap(find.text('Map'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('SOS'), findsOneWidget);
    expect(find.text('Family chat'), findsNothing);
  });
}
