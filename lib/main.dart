import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/call_signaling.dart';
import 'core/language_service.dart';
import 'services/alert_history_service.dart';
import 'services/auth_service.dart';
import 'services/background_location_service.dart';
import 'services/billing_service.dart';
import 'services/call_service.dart';
import 'services/chat_delete_service.dart';
import 'services/device_admin_service.dart';
import 'services/device_owner_service.dart';
import 'services/email_otp_service.dart';
import 'services/family_service.dart';
import 'services/firebase_bootstrap.dart';
import 'services/join_request_service.dart';
import 'services/media_service.dart';
import 'services/notification_service.dart';
import 'services/onboarding_service.dart';
import 'services/pin_service.dart';
import 'services/sim_change_service.dart';
import 'services/sms_location_service.dart';
import 'services/sos_sms_service.dart';
import 'services/setup_service.dart';
import 'services/sync_service.dart';
import 'services/trial_service.dart';
import 'services/voice_message_service.dart';

/// ApnaCircle entry point.
///
/// First run flow: LanguageSelect -> Auth (sign in / demo) ->
/// PinSetup (parent) -> Setup (one-time guided permissions) ->
/// Home (map). Returning users go straight to Home if language +
/// PIN are saved.
///
/// v0.3: Firebase is initialised FIRST, guarded — when no Firebase
/// project exists yet (no google-services.json), initialiseApp()
/// throws, we stay in local demo mode, and NOTHING crashes. The
/// services are created once here and shared via Provider; the
/// FamilyService is attached to the SyncService so its public API
/// stays the same while sync happens underneath.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // v0.6.4: configure the background location service (plugin
  // init only — sharing starts later, from Home, once the member
  // is in a circle with "Allow all the time" permission).
  BackgroundLocationService.init();

  // Guarded: false when no Firebase project exists yet (demo mode).
  await FirebaseBootstrap.initialize();

  final auth = AuthService();
  final sync = SyncService(auth);
  final notifications = NotificationService(sync);
  final sms = SmsLocationService();
  final sosSms = SosSmsService(sms);
  final pin = PinService();
  final family = FamilyService()..attachSync(sync);
  // v0.6.21: calls — the incoming-call ring is wired to the loud
  // notification here (CallService itself never touches the
  // notification plugin).
  final calls = CallService(
    family: family,
    onIncomingCall: (call) => notifications.showIncomingCall(
      callerName: call.fromName,
      isVideo: call.type == CallType.video,
      callId: call.id,
    ),
  );
  // v0.6.21: the alerts centre (bell badge + per-member history).
  final alertHistory = AlertHistoryService(family: family);
  // v0.6.21: local chat deletes (delete for me / clear chat).
  final chatDeletes = ChatDeleteService(family: family);
  // v0.6.23: media sharing — pick / compress / upload / download.
  final media = MediaService(sync);
  // v0.6.29: voice-message recording (hold the mic, release to send).
  final voiceMessages = VoiceMessageService();
  final trial = TrialService()..attachSync(sync);
  final billing = BillingService();
  final simChange = SimChangeService();
  final deviceAdmin = DeviceAdminService();
  final emailOtp = EmailOtpService();
  final setup = SetupService();
  // v0.6.30: join requests — the child asks, the parent allows.
  final joinRequests = JoinRequestService(sync: sync, auth: auth);
  // v0.6.30: language + role are loaded BEFORE the first frame,
  // so AppRoot never flashes the language screen for a returning
  // user (the v0.2 TODO — persist the language — is finally done).
  final lang = LanguageService();
  final onboarding = OnboardingService();

  if (FirebaseBootstrap.available) {
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );
  }

  // Load persisted state BEFORE the first frame, so AppRoot sees
  // the real language/PIN/auth/circle state (v0.2 never called
  // load() — the PIN screen showed on every launch). These are all
  // local SharedPreferences reads — fast, no network.
  await auth.loadDemoSkip();
  await pin.load();
  await sync.load();
  await trial.load();
  await family.load();
  await setup.load();
  await lang.load();
  await onboarding.load();
  await joinRequests.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: lang),
        ChangeNotifierProvider.value(value: onboarding),
        ChangeNotifierProvider.value(value: joinRequests),
        ChangeNotifierProvider.value(value: pin),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: trial),
        ChangeNotifierProvider.value(value: billing),
        ChangeNotifierProvider.value(value: emailOtp),
        ChangeNotifierProvider.value(value: notifications),
        ChangeNotifierProvider.value(value: family),
        ChangeNotifierProvider.value(value: calls),
        ChangeNotifierProvider.value(value: alertHistory),
        ChangeNotifierProvider.value(value: chatDeletes),
        Provider.value(value: media),
        Provider.value(value: voiceMessages),
        Provider.value(value: sms),
        Provider.value(value: sosSms),
        Provider.value(value: simChange),
        Provider.value(value: deviceAdmin),
        ChangeNotifierProvider.value(value: setup),
      ],
      child: const ApnaCircleApp(),
    ),
  );

  // v0.6.7: everything below touches the network (or shows a system
  // permission prompt), and NONE of it gates the first screen — so
  // it runs after the first frame instead of delaying the app
  // opening. Before v0.6.7 these were awaited above runApp, so on
  // a slow network the FCM token fetch alone could hold the app
  // closed for seconds. Order matters: the circle list is
  // refreshed first, because the SIM-change / Device Admin checks
  // iterate it.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_runPostFrameStartup(
      notifications: notifications,
      sync: sync,
      auth: auth,
      simChange: simChange,
      deviceAdmin: deviceAdmin,
      billing: billing,
      pin: pin,
    ));
  });
}

/// Post-first-frame startup (v0.6.7) — see main() above.
Future<void> _runPostFrameStartup({
  required NotificationService notifications,
  required SyncService sync,
  required AuthService auth,
  required SimChangeService simChange,
  required DeviceAdminService deviceAdmin,
  required BillingService billing,
  required PinService pin,
}) async {
  if (FirebaseBootstrap.available) {
    await notifications.initialize();
  }
  await sync.refreshMyCircles();
  // v0.6.13 (offline rule): cache the parent PIN hash locally so
  // every PIN gate works with the internet off. Runs on every
  // start while online; a phone that already has a PIN skips it.
  await sync.cacheParentPinHash(pin);
  await simChange.checkOnStart(sync: sync, auth: auth);
  await deviceAdmin.publishPendingAlertIfAny(sync: sync, auth: auth);
  // v0.6.13: cache this phone's uninstall-protection level so
  // the background task can publish it with the member node (its
  // isolate cannot call the platform channels).
  await DeviceOwnerService().cacheLevel();
  unawaited(billing.initialize());
}

class ApnaCircleApp extends StatelessWidget {
  const ApnaCircleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    return MaterialApp(
      title: 'ApnaCircle',
      debugShowCheckedModeBanner: false,
      locale: lang.locale,
      supportedLocales: const [Locale('en'), Locale('ur')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Urdu = RTL. Flutter flips layout automatically for Locale('ur').
      theme: ApnaCircleTheme.light,
      home: const AppRoot(),
    );
  }
}
