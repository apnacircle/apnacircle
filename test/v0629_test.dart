// v0.6.29 tests — call sheet, WhatsApp-style chat input, voice
// messages.
//
// The user's report (27 Nov 2026): the top call button "did
// nothing" — the v0.6.21 dialog kept its Audio/Video buttons
// greyed out until a member was ticked, so tapping them did
// nothing. The new flow is a member list: tap a name, call them;
// the Group call row is the conference picker. The chat input
// is WhatsApp-style now: attach sits INSIDE the round text box,
// mic while the box is empty (hold to record, release to send),
// send circle once text is typed.
import 'package:apnacircle/core/voice_message.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/services/media_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sos_sms_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:apnacircle/services/voice_message_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('voice message helpers (v0.6.29)', () {
    test('file name is voice_<epoch-ms>.m4a', () {
      expect(voiceMessageFileName(1790000000000), 'voice_1790000000000.m4a');
    });

    test('under 1 second is too short; 1 second and over is fine', () {
      expect(isVoiceMessageTooShort(durationMs: 0), isTrue);
      expect(isVoiceMessageTooShort(durationMs: 999), isTrue);
      expect(isVoiceMessageTooShort(durationMs: 1000), isFalse);
      expect(isVoiceMessageTooShort(durationMs: 5000), isFalse);
    });
  });

  group('chat input (v0.6.29)', () {
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
            Provider.value(value: VoiceMessageService()),
          ],
          child: const MaterialApp(home: HomeMapScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    Future<void> openChat(WidgetTester tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('Chat'));
      // Let the SOS FAB finish its exit animation — while it is
      // animating out it still covers the input row.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('attach sits INSIDE the text box, not outside it',
        (tester) async {
      await openChat(tester);
      expect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.byIcon(Icons.attach_file),
        ),
        findsOneWidget,
      );
    });

    testWidgets('mic shows while the box is empty; send shows '
        'after typing', (tester) async {
      await openChat(tester);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);
    });

    testWidgets('holding the mic in demo mode refuses plainly',
        (tester) async {
      await openChat(tester);
      await tester.longPress(find.byIcon(Icons.mic_none));
      await tester.pump();
      expect(
        find.text('Voice bhejne ke liye internet aur circle chahiye.'),
        findsOneWidget,
      );
    });
  });
}
