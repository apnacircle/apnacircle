// v0.6.30 tests — first-run onboarding (language once, role,
// parent trial/payment, child join REQUEST with parent approval).
//
// The user's report (28 Nov 2026): the language screen came back
// on EVERY app open (the v0.2 persist TODO was never done), and a
// child could join a circle with just the invite code — nobody
// knew, for hours, whether anyone had joined. The new flow:
// language once (persisted) -> parent/child role (once) ->
// parent: trial/subscribe choice -> Gmail login -> PIN -> setup;
// child: Gmail login -> invite code + mobile + PARENT's PIN ->
// join REQUEST -> parent Allows / Denies (live, instant) -> the
// child joins by themself only after Allow. A child never sees
// the trial / payment screens.
import 'package:apnacircle/app.dart';
import 'package:apnacircle/core/join_request.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/firebase_config.dart';
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
  group('language persist (v0.6.30)', () {
    test('choice survives a restart — ask once, never again', () async {
      SharedPreferences.setMockInitialValues({});
      final first = LanguageService();
      await first.choose(const Locale('ur'));
      expect(first.isUrdu, isTrue);
      expect(first.hasChosenLanguage, isTrue);
      final second = LanguageService();
      await second.load();
      expect(second.hasChosenLanguage, isTrue);
      expect(second.isUrdu, isTrue);
    });

    test('nothing saved yet means "not chosen"', () async {
      SharedPreferences.setMockInitialValues({});
      final lang = LanguageService();
      await lang.load();
      expect(lang.hasChosenLanguage, isFalse);
    });
  });

  group('onboarding persist (v0.6.30)', () {
    test('role + plan choice + join skip survive a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final first = OnboardingService();
      await first.chooseRole('child');
      await first.markJoinSkipped();
      final second = OnboardingService();
      await second.load();
      expect(second.isChild, isTrue);
      expect(second.isParent, isFalse);
      expect(second.joinSkipped, isTrue);
      expect(second.planChoiceDone, isFalse);
      await second.chooseRole('parent');
      await second.markPlanChoiceDone();
      final third = OnboardingService();
      await third.load();
      expect(third.isParent, isTrue);
      expect(third.planChoiceDone, isTrue);
    });
  });

  group('join request model (v0.6.30)', () {
    test('round-trips through toMap / fromMap', () {
      const req = JoinRequest(
        circleId: 'c1',
        uid: 'u1',
        name: 'Ali',
        phone: '03001234567',
        inviteCode: '482913',
        pinHashAttempt: 'deadbeef',
        requestedAtMs: 1790000000000,
        status: JoinRequestStatus.approved,
        reason: JoinDenyReason.parentDenied,
        decidedAtMs: 1790000001000,
      );
      final back = JoinRequest.fromMap('c1', 'u1', req.toMap());
      expect(back?.name, 'Ali');
      expect(back?.phone, '03001234567');
      expect(back?.inviteCode, '482913');
      expect(back?.pinHashAttempt, 'deadbeef');
      expect(back?.status, JoinRequestStatus.approved);
      expect(back?.reason, JoinDenyReason.parentDenied);
      expect(back?.decidedAtMs, 1790000001000);
    });

    test('bad data parses to null; unknown status is pending', () {
      expect(JoinRequest.fromMap('c1', 'u1', {'name': 'x'}), isNull);
      expect(joinRequestStatusFromString('approved'),
          JoinRequestStatus.approved);
      expect(joinRequestStatusFromString('denied'),
          JoinRequestStatus.denied);
      expect(joinRequestStatusFromString('nonsense'),
          JoinRequestStatus.pending);
      expect(joinRequestStatusFromString(null), JoinRequestStatus.pending);
    });

    test('PIN match is exact; null hash never matches', () {
      const req = JoinRequest(
        circleId: 'c1',
        uid: 'u1',
        name: 'Ali',
        phone: '0300',
        inviteCode: '482913',
        pinHashAttempt: 'abc123',
        requestedAtMs: 1,
      );
      expect(JoinRequestService.pinMatches(req, 'abc123'), isTrue);
      expect(JoinRequestService.pinMatches(req, 'xyz'), isFalse);
      expect(JoinRequestService.pinMatches(req, null), isFalse);
    });

    test('RTDB paths', () {
      expect(FirebaseConfig.joinRequestsPath('c1'),
          'circles/c1/joinRequests');
      expect(FirebaseConfig.joinRequestPath('c1', 'u1'),
          'circles/c1/joinRequests/u1');
    });
  });

  group('AppRoot onboarding routing (v0.6.30)', () {
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
            // Device id channel is not wired in tests — stub it so
            // the trial starts locally (production reads the real
            // Android ID through DeviceIdService).
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

    testWidgets('no language yet -> language screen', (tester) async {
      await pumpAppRoot(tester);
      // v0.6.32: the language screen is two separate lines now
      // (English line + Urdu-script line), not one mixed string.
      expect(find.text('Choose your language'), findsOneWidget);
      expect(find.text('اپنی زبان منتخب کریں'), findsOneWidget);
    });

    testWidgets('language chosen -> role screen, once', (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'en'});
      expect(find.text('Who are you?'), findsOneWidget);
      expect(find.text('Parent / Admin'), findsOneWidget);
      expect(find.text('Child'), findsOneWidget);
    });

    testWidgets('tap English -> role screen (language never asks again)',
        (tester) async {
      final s = await pumpAppRoot(tester);
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.pump();
      expect(s.lang.hasChosenLanguage, isTrue);
      expect(find.text('Who are you?'), findsOneWidget);
    });

    testWidgets('parent, fresh install -> trial / subscribe choice',
        (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'en'});
      await tester.tap(find.text('Parent / Admin'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Family plan'), findsOneWidget);
      expect(find.text('Start 7-day FREE trial'), findsOneWidget);
      expect(find.text('Subscribe — \$5/year'), findsOneWidget);
      // A child must NEVER see this screen — the role screen only
      // offers the two roles, and the child path below proves it.
    });

    testWidgets('parent trial -> PIN setup (plan choice done, once)',
        (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'en'});
      await tester.tap(find.text('Parent / Admin'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Start 7-day FREE trial'));
      // The trial start chains several async steps (device id ->
      // save -> mark the choice done) — settle them all.
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.text('Set parent PIN'), findsOneWidget);
    });

    testWidgets('child -> join request screen, no trial / payment',
        (tester) async {
      await pumpAppRoot(tester, prefs: {'language_code_v1': 'en'});
      await tester.tap(find.text('Child'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Join family circle'), findsOneWidget);
      expect(find.text("Parent's PIN / code"), findsOneWidget);
      expect(find.text('Send join request'), findsOneWidget);
      expect(find.textContaining('trial'), findsNothing);
      expect(find.textContaining('Subscribe'), findsNothing);
    });

    testWidgets('returning parent (PIN + setup done) -> Home straight away',
        (tester) async {
      await pumpAppRoot(
        tester,
        prefs: {'language_code_v1': 'en'},
        withPin: true,
        setupComplete: true,
      );
      await tester.tap(find.text('Parent / Admin'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(HomeMapScreen), findsOneWidget);
    });
  });
}
