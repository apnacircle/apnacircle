import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/language_service.dart';
import 'services/auth_service.dart';
import 'services/background_location_service.dart';
import 'services/billing_service.dart';
import 'services/device_admin_service.dart';
import 'services/email_otp_service.dart';
import 'services/family_service.dart';
import 'services/firebase_bootstrap.dart';
import 'services/notification_service.dart';
import 'services/pin_service.dart';
import 'services/sim_change_service.dart';
import 'services/sms_location_service.dart';
import 'services/sync_service.dart';
import 'services/trial_service.dart';

/// ApnaCircle entry point.
///
/// First run flow: LanguageSelect -> Auth (sign in / demo) ->
/// PinSetup (parent) -> Home (map). Returning users go straight
/// to Home if language + PIN are saved.
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
  final pin = PinService();
  final family = FamilyService()..attachSync(sync);
  final trial = TrialService()..attachSync(sync);
  final billing = BillingService();
  final simChange = SimChangeService();
  final deviceAdmin = DeviceAdminService();
  final emailOtp = EmailOtpService();

  if (FirebaseBootstrap.available) {
    FirebaseMessaging.onBackgroundMessage(
      firebaseMessagingBackgroundHandler,
    );
    await notifications.initialize();
  }

  // Load persisted state BEFORE the first frame, so AppRoot sees
  // the real language/PIN/auth/circle state (v0.2 never called
  // load() — the PIN screen showed on every launch).
  await auth.loadDemoSkip();
  await pin.load();
  await sync.load();
  await trial.load();
  await family.load();

  // v0.5 startup checks (do not block the first frame on them):
  // * SIM-change: publish a pending boot event / live mismatch.
  // * Device Admin: publish a pending deactivation alert.
  // * Play Billing: connect in the background; the Plan screen
  //   shows the state when it is ready.
  await simChange.checkOnStart(sync: sync, auth: auth);
  await deviceAdmin.publishPendingAlertIfAny(sync: sync, auth: auth);
  unawaited(billing.initialize());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LanguageService()),
        ChangeNotifierProvider.value(value: pin),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: trial),
        ChangeNotifierProvider.value(value: billing),
        ChangeNotifierProvider.value(value: emailOtp),
        ChangeNotifierProvider.value(value: notifications),
        ChangeNotifierProvider.value(value: family),
        Provider.value(value: sms),
        Provider.value(value: simChange),
        Provider.value(value: deviceAdmin),
      ],
      child: const ApnaCircleApp(),
    ),
  );
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
