// v0.6.32 tests — proper US English + proper Urdu script, zero
// Roman Urdu anywhere user-facing.
//
// The user's order (28 Nov 2026): for an international Play Store
// launch the app must show proper US English in the English locale
// and proper Urdu script in the Urdu locale — never Roman Urdu
// ("Aap", "karein", "dobara", ...) in either locale.
import 'package:apnacircle/app.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/l10n/app_en.dart';
import 'package:apnacircle/l10n/app_ur.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/join_request_service.dart';
import 'package:apnacircle/services/media_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/onboarding_service.dart';
import 'package:apnacircle/services/pin_service.dart';
import 'package:apnacircle/services/setup_service.dart';
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
  group('no Roman Urdu in either translation map (v0.6.32)', () {
    // Latin-script Urdu marker words — whole-word match, so
    // 'ApnaCircle' (no word boundary inside) never trips, while
    // a stray 'Aap' or 'dobara' in any value does.
    const markers = [
      'Aap', 'karein', 'dobara', 'ijazat', 'wapas', 'bacha', 'ghalat',
      'chahiye', 'nahi', 'hain', 'phir', 'kuch', 'kaun', 'apna', 'hai',
      'gaya', 'jaye', 'liye', 'bina', 'saath', 'andar', 'bahar', 'upar',
      'pehle', 'baad', 'dafa', 'theek', 'kabhi', 'abhi', 'sakte',
      'zaroori', 'mere', 'mera', 'meri',
    ];
    final pattern = RegExp(
      '\\b(${markers.join('|')})\\b',
      caseSensitive: false,
    );

    test('EN map: no Roman Urdu marker word in any value', () {
      final bad = <String>[];
      enStrings.forEach((key, value) {
        if (pattern.hasMatch(value)) bad.add('$key: $value');
      });
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('UR map: no Roman Urdu marker word in any value', () {
      final bad = <String>[];
      urStrings.forEach((key, value) {
        if (pattern.hasMatch(value)) bad.add('$key: $value');
      });
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('both maps have the same keys', () {
      expect(
        urStrings.keys.toSet(),
        enStrings.keys.toSet(),
        reason: 'every EN key needs a UR twin and vice versa',
      );
    });
  });

  group('role screen renders per locale (v0.6.32)', () {
    Future<void> pumpAppRoot(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lang = LanguageService();
      await lang.load();
      final onboarding = OnboardingService();
      await onboarding.load();
      final pin = PinService();
      await pin.load();
      final setup = SetupService();
      await setup.load();
      final auth = AuthService();
      final sync = SyncService(auth);
      final family = FamilyService()..attachSync(sync);
      final sms = SmsLocationService();
      final joinRequests = JoinRequestService(sync: sync, auth: auth);
      await joinRequests.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: lang),
            ChangeNotifierProvider.value(value: onboarding),
            ChangeNotifierProvider.value(value: joinRequests),
            ChangeNotifierProvider.value(value: pin),
            ChangeNotifierProvider.value(value: setup),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider(
              create: (_) => TrialService(
                deviceIdHashProvider: () async => null,
              ),
            ),
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
          child: const MaterialApp(home: AppRoot()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('EN locale: proper US English, no Roman Urdu',
        (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'en'});
      expect(find.text('Who are you?'), findsOneWidget);
      expect(find.text('Parent / Admin'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Aap kaun hain? / آپ کون ہیں؟'), findsNothing);
      expect(find.text('Child / بچہ'), findsNothing);
    });

    testWidgets('UR locale: proper Urdu script, no English heading',
        (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'ur'});
      expect(find.text('آپ کون ہیں؟'), findsOneWidget);
      expect(find.text('بچہ'), findsOneWidget);
      expect(find.text('Who are you?'), findsNothing);
      expect(find.text('Child'), findsNothing);
    });
  });
}
