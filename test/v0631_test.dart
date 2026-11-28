// v0.6.31 tests — going back (undo a wrong role tap).
//
// The user's report (28 Nov 2026): he chose English, then his
// hand slipped and tapped Child instead of Parent — and there was
// NO way back. He went on without an account (demo mode) and
// kept going forward with no back option anywhere. The fix:
// every onboarding step has a back arrow — role -> language,
// plan / join / login -> role — and Settings offers "Role
// badlein" while this phone has no circles yet. Backing out of
// a join also cancels the child's pending request on the server
// (best effort; the rules let the owner delete their own
// pending request from v7+delete).
import 'package:apnacircle/app.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/screens/auth_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/email_otp_service.dart';
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
  group('going back — services (v0.6.31)', () {
    test('language: clearChoice forgets the choice', () async {
      SharedPreferences.setMockInitialValues({});
      final lang = LanguageService();
      await lang.choose(const Locale('ur'));
      expect(lang.hasChosenLanguage, isTrue);
      await lang.clearChoice();
      expect(lang.hasChosenLanguage, isFalse);
      expect(lang.isUrdu, isFalse);
      final reloaded = LanguageService();
      await reloaded.load();
      expect(reloaded.hasChosenLanguage, isFalse);
    });

    test('onboarding: clearRole forgets role + plan + join skip',
        () async {
      SharedPreferences.setMockInitialValues({});
      final first = OnboardingService();
      await first.chooseRole('child');
      await first.markJoinSkipped();
      await first.chooseRole('parent');
      await first.markPlanChoiceDone();
      expect(first.isParent, isTrue);
      expect(first.planChoiceDone, isTrue);
      expect(first.joinSkipped, isTrue);
      await first.clearRole();
      expect(first.hasChosenRole, isFalse);
      expect(first.planChoiceDone, isFalse);
      expect(first.joinSkipped, isFalse);
      final second = OnboardingService();
      await second.load();
      expect(second.hasChosenRole, isFalse);
      expect(second.planChoiceDone, isFalse);
      expect(second.joinSkipped, isFalse);
    });

    test('join request: cancel clears a persisted pending circle',
        () async {
      SharedPreferences.setMockInitialValues(
        {'join_pending_circle_v1': 'c1'},
      );
      final auth = AuthService();
      final sync = SyncService(auth);
      final service = JoinRequestService(sync: sync, auth: auth);
      await service.load();
      expect(service.pendingCircleId, 'c1');
      // No Firebase in tests (isAvailable false) — the server
      // delete is skipped, the local pending state still clears.
      await service.cancelMyRequest();
      expect(service.pendingCircleId, isNull);
      final reloaded = JoinRequestService(sync: sync, auth: auth);
      await reloaded.load();
      expect(reloaded.pendingCircleId, isNull);
    });
  });

  group('going back — AppRoot routing (v0.6.31)', () {
    Future<({LanguageService lang, OnboardingService onboarding,
        PinService pin, SetupService setup})> pumpAppRoot(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
      bool withPin = false,
      bool setupComplete = false,
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
      if (withPin) await pin.setPin('1234');
      final setup = SetupService();
      await setup.load();
      if (setupComplete) await setup.markComplete();
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
      return (
        lang: lang,
        onboarding: onboarding,
        pin: pin,
        setup: setup,
      );
    }

    testWidgets('role screen back arrow -> language screen',
        (tester) async {
      final s = await pumpAppRoot(
        tester,
        prefs: {'language_code_v1': 'en'},
      );
      expect(find.text('Who are you?'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump();
      expect(s.lang.hasChosenLanguage, isFalse);
      // v0.6.32: the language screen is two separate lines now
      // (English line + Urdu-script line), not one mixed string.
      expect(find.text('Choose your language'), findsOneWidget);
      expect(find.text('اپنی زبان منتخب کریں'), findsOneWidget);
    });

    testWidgets('parent plan screen back arrow -> role screen',
        (tester) async {
      final s = await pumpAppRoot(
        tester,
        prefs: {'language_code_v1': 'en'},
      );
      await tester.tap(find.text('Parent / Admin'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Family plan'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump();
      expect(s.onboarding.hasChosenRole, isFalse);
      expect(find.text('Who are you?'), findsOneWidget);
    });

    testWidgets('child join screen back arrow -> role screen',
        (tester) async {
      final s = await pumpAppRoot(
        tester,
        prefs: {'language_code_v1': 'en'},
      );
      await tester.tap(find.text('Child'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Join family circle'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump();
      expect(s.onboarding.hasChosenRole, isFalse);
      expect(find.text('Who are you?'), findsOneWidget);
    });

    testWidgets('login screen back arrow (first-run) -> role screen',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final onboarding = OnboardingService();
      await onboarding.chooseRole('parent');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: LanguageService()),
            ChangeNotifierProvider.value(value: onboarding),
            ChangeNotifierProvider.value(value: AuthService()),
            ChangeNotifierProvider.value(value: EmailOtpService()),
          ],
          child: const MaterialApp(
            home: AuthScreen(showRoleBack: true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Sign in — ApnaCircle'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump();
      expect(onboarding.hasChosenRole, isFalse);
    });

    testWidgets('login screen pushed from Settings has no role back',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final onboarding = OnboardingService();
      await onboarding.chooseRole('parent');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: LanguageService()),
            ChangeNotifierProvider.value(value: onboarding),
            ChangeNotifierProvider.value(value: AuthService()),
            ChangeNotifierProvider.value(value: EmailOtpService()),
          ],
          child: const MaterialApp(
            home: AuthScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // No back arrow at all (root route, no role back offered).
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(onboarding.hasChosenRole, isTrue);
    });
  });
}
