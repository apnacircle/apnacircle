import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../core/location_service.dart';
import '../models/circle.dart';
import 'firebase_config.dart';
import 'sync_service.dart';

/// Background location sharing (v0.6.4, 23 Nov 2026).
///
/// THE GAP IT CLOSES: before v0.6.4 the app only ever asked for
/// while-in-use location, and `currentFix()` was only called from
/// the Map screen — so a member's location stopped updating the
/// moment the app went to background. That is why the parent's
/// screenshots showed iza as "— away" and Ammi "Offline since
/// 08:38": their phones were fine, the app simply never sent
/// anything while closed.
///
/// HOW IT WORKS NOW:
/// * The user grants "Allow all the time" (Settings — Android 11+
///   cannot grant it from a dialog; see LocationService).
/// * A foreground service (flutter_foreground_task) then runs a
///   Dart task in the background: every 60 s it takes a GPS fix
///   (same 50 m / 60 s throttle as LocationService) and publishes
///   it to the member's own RTDB node, exactly like the foreground
///   loop in HomeMapScreen. The service shows a permanent
///   notification: "ApnaCircle is sharing your location with your
///   family".
/// * It starts automatically once the member is in a circle AND
///   background permission is granted, and stops when they leave
///   all circles (see [BackgroundLocationService.ensureRunning]).
///
/// HONEST LIMITS (do not hide these — they are in README too):
/// * A foreground service can still be stopped: the user swiping
///   the app away on some phones, or an aggressive battery saver
///   (Xiaomi / Oppo / Vivo), or Android itself under memory
///   pressure. The battery-optimization exemption
///   (LocationService.requestBatteryOptimizationExemption) lowers
///   the risk, it does not remove it. When the service dies, the
///   member simply goes stale on the parent's phone — the app
///   never fakes a live location.
/// * The service needs the phone's location services ON. NO normal
///   app can block the system GPS switch (Settings / quick panel)
///   — Android does not allow it, and this app does not pretend
///   otherwise. What it DOES do: the background task notices the
///   switch-off at once and publishes a `locationOff` event to the
///   circle (with the last known location), so the parent is told
///   immediately — same pattern as the internet-off alert.
/// * The CHILD cannot turn sharing off from inside the app: the
///   Location Lock switch is parent-PIN-gated, and this service
///   deliberately does NOT stop on the in-app sharing flag — it
///   stops only when the user leaves all circles or the system
///   permission is revoked. (Parent order, 23 Nov 2026 ~10:34 PKT:
///   "Location app bhi na kar sake child".)
/// * The SMS offline fallback still needs the app open (it lives
///   in the foreground loop) — the background task only publishes
///   to RTDB while the phone has data.
class BackgroundLocationService {
  BackgroundLocationService._();

  /// Foreground-service notification channel (Android 8+).
  static const String channelId = 'apnacircle_location';
  static const String channelName = 'Location sharing';

  /// The permanent notification while the service runs.
  static const String notificationTitle = 'ApnaCircle';
  static const String notificationText =
      'ApnaCircle is sharing your location with your family';

  /// Task data keys (flutter_foreground_task saveData/getData —
  /// SharedPreferences-backed, so they survive a reboot and the
  /// task can restart on boot with the same circle).
  static const String dataCircleId = 'bg_circle_id';
  static const String dataUid = 'bg_uid';
  static const String dataName = 'bg_name';

  static bool _initialized = false;

  /// Call once from main() before runApp. Only configures the
  /// plugin — it does NOT start sharing.
  static void init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: channelId,
        channelName: channelName,
        channelDescription:
            'Shows while ApnaCircle shares your location with your family in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Pure start/stop decision — unit-tested. Background sharing
  /// runs only for a member of a circle with "always" permission.
  /// A while-in-use permission can never feed the background task,
  /// so the service is not started for it (starting it would only
  /// show a permanent notification and share nothing).
  static bool shouldRunBackgroundSharing({
    required bool inCircle,
    required LocationSharingState state,
  }) =>
      inCircle && state == LocationSharingState.always;

  static Future<bool> get isRunning =>
      FlutterForegroundTask.isRunningService;

  /// Start the foreground service for one circle member. Saves the
  /// circle/uid/name first, so the background task (a separate
  /// isolate) knows where to publish. Returns false when the
  /// service could not be started.
  static Future<bool> start({
    required String circleId,
    required String uid,
    required String displayName,
  }) async {
    init();
    try {
      await FlutterForegroundTask.saveData(
          key: dataCircleId, value: circleId);
      await FlutterForegroundTask.saveData(key: dataUid, value: uid);
      await FlutterForegroundTask.saveData(
          key: dataName, value: displayName);
      final result = await FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.location],
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        callback: backgroundLocationTaskCallback,
      );
      return result is ServiceRequestSuccess;
    } catch (e) {
      debugPrint('ApnaCircle: background location start failed ($e)');
      return false;
    }
  }

  /// Stop the service and CLEAR the saved task data, so a reboot
  /// or auto-restart can never resume sharing for a circle the
  /// user already left.
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('ApnaCircle: background location stop failed ($e)');
    }
    try {
      await FlutterForegroundTask.saveData(key: dataCircleId, value: '');
      await FlutterForegroundTask.saveData(key: dataUid, value: '');
      await FlutterForegroundTask.saveData(key: dataName, value: '');
    } catch (_) {
      // Best effort — stale data only matters if the service is
      // restarted, and start() always overwrites it first.
    }
  }

  /// Keep the service in the right state for the current login:
  /// start it when the user is in a circle with "always"
  /// permission, stop it otherwise (no circle, or permission
  /// dropped to while-in-use/off). A circle switch restarts the
  /// service so the task publishes to the new circle. Idempotent —
  /// safe to call on every resume and circle change.
  static Future<bool> ensureRunning({
    required SyncService sync,
    required String displayName,
  }) async {
    final circleId = sync.isAvailable ? sync.activeCircleId : null;
    final uid = sync.uid;
    final inCircle = circleId != null && uid != null;
    final running = await isRunning;
    if (!inCircle) {
      if (running) await stop();
      return false;
    }
    final state = await LocationService().sharingState();
    if (!shouldRunBackgroundSharing(inCircle: inCircle, state: state)) {
      if (running) await stop();
      return false;
    }
    if (running) {
      final savedCircle =
          await FlutterForegroundTask.getData<String>(key: dataCircleId);
      if (savedCircle == circleId) return true;
      await stop();
    }
    return await start(
      circleId: circleId,
      uid: uid,
      displayName: displayName,
    );
  }
}

/// The entry point the foreground service calls in its own isolate.
/// Must be top-level (never a closure or a method) — see
/// flutter_foreground_task README.
@pragma('vm:entry-point')
void backgroundLocationTaskCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundLocationTaskHandler());
}

/// The background task itself: runs in a separate Dart isolate
/// while the foreground service is alive. Every 60 s (the repeat
/// interval) it takes a GPS fix and publishes it to the member's
/// RTDB node. Firebase is initialized HERE, in this isolate —
/// Firebase plugins do not share state across isolates.
///
/// If the phone's location services are switched off, no fix is
/// possible: the task publishes ONE `locationOff` event to the
/// circle (with the last known location) and stays quiet until
/// location is back on — it never spams one alert per cycle.
class BackgroundLocationTaskHandler extends TaskHandler {
  final LocationService _loc = LocationService();
  final LocationOffDetector _offDetector = LocationOffDetector();

  DatabaseReference? _db;
  String? _circleId;
  String? _uid;
  String? _name;
  DateTime? _lastPublishedFixAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _circleId = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataCircleId);
    _uid = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataUid);
    _name = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataName);
    if (_circleId == null ||
        _circleId!.isEmpty ||
        _uid == null ||
        _uid!.isEmpty) {
      // No circle saved (user left all circles) — nothing to share.
      return;
    }
    try {
      await Firebase.initializeApp();
      _db = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseUrl,
      ).ref();
    } catch (e) {
      // Demo mode (no Firebase project) or init failure — the task
      // stays alive but publishes nothing, never crashes.
      debugPrint('ApnaCircle: background task Firebase init failed ($e)');
      _db = null;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_publishCycle());
  }

  Future<void> _publishCycle() async {
    if (_db == null || _circleId == null || _uid == null) return;
    bool servicesOn;
    try {
      servicesOn = await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return;
    }
    if (!servicesOn) {
      // System GPS switched off — tell the parent ONCE, with the
      // last known location, then stay quiet until it is back on.
      if (_offDetector.check(false)) {
        await _publishLocationOffAlert();
      }
      return;
    }
    _offDetector.check(true);
    // Never ask for a permission from the background isolate: if
    // the permission was revoked, the task simply publishes
    // nothing (the main isolate restarts/stops the service).
    final p = await _loc.checkPermission();
    if (p != LocationPermission.whileInUse &&
        p != LocationPermission.always) {
      return;
    }
    final fix = await _loc.currentFix();
    if (fix == null) return;
    // LocationService throttles (50 m / 60 s) by returning the
    // previous fix — do not publish the same fix twice.
    if (_lastPublishedFixAt != null &&
        fix.timestamp == _lastPublishedFixAt) {
      return;
    }
    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {
      battery = -1; // Unknown battery shows no battery text (v0.6.2).
    }
    try {
      await _db!
          .child(FirebaseConfig.circleMemberPath(_circleId!, _uid!))
          .update({
        'lat': fix.latitude,
        'lon': fix.longitude,
        'battery': battery,
        'isOnline': true,
        'lastSeen': DateTime.now().toIso8601String(),
        'locationSharingOn': true,
      });
      _lastPublishedFixAt = fix.timestamp;
      try {
        final now = DateTime.now();
        final hh = now.hour.toString().padLeft(2, '0');
        final mm = now.minute.toString().padLeft(2, '0');
        await FlutterForegroundTask.updateService(
          notificationText:
              '${BackgroundLocationService.notificationText} · Last shared $hh:$mm',
        );
      } catch (_) {
        // Notification text is cosmetic — sharing already happened.
      }
    } catch (e) {
      debugPrint('ApnaCircle: background location publish failed ($e)');
    }
  }

  /// Parent alert: this phone's location services were switched
  /// off. Sent ONCE per switch-off (see LocationOffDetector),
  /// with the last known location attached so the parent still
  /// sees where the child was.
  Future<void> _publishLocationOffAlert() async {
    final last = await _loc.lastKnown();
    final event = CircleEvent(
      type: 'locationOff',
      fromUid: _uid!,
      fromName: _name ?? 'Me',
      at: DateTime.now(),
      lat: last?.lat,
      lon: last?.lon,
    );
    try {
      await _db!
          .child(FirebaseConfig.circleEventsPath(_circleId!))
          .push()
          .set(event.toJson());
    } catch (e) {
      debugPrint('ApnaCircle: locationOff alert failed ($e)');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Detects the phone's location services going OFF and reports it
/// exactly once per switch-off (no alert spam every cycle).
/// Pure logic, unit-tested.
class LocationOffDetector {
  bool _wasEnabled = true;

  /// Returns true only on the enabled → disabled transition.
  /// A re-enable resets the detector, so a second switch-off
  /// alerts again. While location stays off, returns false.
  bool check(bool enabledNow) {
    if (enabledNow) {
      _wasEnabled = true;
      return false;
    }
    if (_wasEnabled) {
      _wasEnabled = false;
      return true;
    }
    return false;
  }
}
