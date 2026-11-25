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
import 'services/device_owner_service.dart';
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
