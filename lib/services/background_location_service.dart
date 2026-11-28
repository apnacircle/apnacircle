import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/battery_schedule.dart';
import '../core/location_service.dart';
import '../core/protection_level.dart';
import '../core/removal_detection.dart';
import '../l10n/strings.dart';
import '../models/circle.dart';
import 'device_admin_service.dart';
import 'device_owner_service.dart';
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
///   Dart task in the background: every 60 s it gets a fix with
///   [LocationService.efficientFix] (v0.6.12: last-known first, a
///   low-power cell/WiFi check while stationary, GPS only on
///   movement or a 30-min re-baseline — the old path took a fresh
///   high-accuracy GPS fix EVERY cycle, ~1,440/day, which drained
///   the battery even for a phone sitting at home) and publishes
///   it to the member's own RTDB node, with the same 50 m / 60 s
///   throttle as LocationService. The service shows a permanent
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

  /// Localized [notificationText]. The const above stays (English)
  /// for existing call sites; the service start/update paths use
  /// this with the persisted locale.
  static String notificationTextFor(bool isUrdu) =>
      tr(isUrdu, 'svc_bgSharingText');

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
        notificationText: notificationTextFor(await _persistedIsUrdu()),
        callback: backgroundLocationTaskCallback,
      );
      return result is ServiceRequestSuccess;
    } catch (e) {
      debugPrint('ApnaCircle: background location start failed ($e)');
      return false;
    }
  }

  /// Persisted language choice (same key as LanguageService).
  static Future<bool> _persistedIsUrdu() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('language_code_v1') == 'ur';
    } catch (_) {
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
  // Internet-off alert (v0.6.9): the phone going offline can only
  // be reported when it is back online — while offline there is no
  // channel to the parent except SMS. The tracker records the
  // offline window; on reconnect the parent gets ONE event,
  // labelled with when the internet went off.
  final InternetOffTracker _internetOffTracker = InternetOffTracker();

  /// Last known Internet-off alert flag for this member (v0.6.9).
  /// Read from the locks node when an offline window closes;
  /// default ON, matching the Locks screen default. A failed read
  /// keeps the cached value — the alert must not depend on a
  /// single read, and this must never break the location cycle.
  bool _cachedInternetAlert = true;
  // Battery has its OWN schedule (v0.6.6): it is published every
  // 15 minutes and on a >= 2% change, even when the location has
  // not moved and the movement throttle says "do not send the fix
  // again". Before this, the battery rode only on a location
  // publish, so a member sitting at home kept the first-published
  // value for hours (user's phone: 82% at 09:24, still 82% at
  // 12:47 while the real level was 59%).
  final BatteryPublishTracker _batteryTracker = BatteryPublishTracker();

  DatabaseReference? _db;
  String? _circleId;
  String? _uid;
  String? _name;
  DateTime? _lastPublishedFixAt;

  /// Persisted locale, read once in [onStart] (this isolate has
  /// no access to the main isolate's LanguageService).
  bool _isUrdu = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _circleId = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataCircleId);
    _uid = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataUid);
    _name = await FlutterForegroundTask.getData<String>(
        key: BackgroundLocationService.dataName);
    _isUrdu = await BackgroundLocationService._persistedIsUrdu();
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

  /// One-time membership check (v0.6.27): does MY member node
  /// still exist? `true` = yes. `false` = definitely gone (node
  /// missing, or the read was permission-denied — the read rule
  /// denies anyone whose node is gone). `null` = the check
  /// itself failed (offline, unknown error) — never treat that
  /// as a removal. Never throws.
  Future<bool?> _checkMembership() async {
    try {
      final snap = await _db!
          .child(FirebaseConfig.circleMemberPath(_circleId!, _uid!))
          .get();
      return snap.exists;
    } catch (e) {
      if (isPermissionDeniedError(e)) return false;
      return null;
    }
  }

  /// Stop the foreground service because I was removed from the
  /// circle (v0.6.27), and clear its saved data so a reboot or
  /// auto-restart can never resume sharing for this circle.
  /// Best effort — a failure to stop here is retried next cycle
  /// (the check runs every cycle until the service is gone).
  Future<void> _stopForRemoval() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // Retried next cycle.
    }
    try {
      await FlutterForegroundTask.saveData(
          key: BackgroundLocationService.dataCircleId, value: '');
      await FlutterForegroundTask.saveData(
          key: BackgroundLocationService.dataUid, value: '');
      await FlutterForegroundTask.saveData(
          key: BackgroundLocationService.dataName, value: '');
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _publishCycle() async {
    if (_db == null || _circleId == null || _uid == null) return;
    // v0.6.27 — REMOVED FROM THE CIRCLE: the parent deleted my
    // member node, so stop sharing at once. One membership read
    // per cycle (cheap): node gone or read denied means removed
    // — stop the service and clear its saved data so a reboot
    // can never resume sharing for this circle. A check that
    // itself failed (no network) changes nothing; the next cycle
    // tries again. Without this, the publishes below would keep
    // re-creating the node (rules v5 deny the write, but the
    // service would still run and drain the battery for nothing).
    final memberExists = await _checkMembership();
    if (shouldTreatAsRemoved(memberNodeExists: memberExists)) {
      await _stopForRemoval();
      return;
    }
    final now = DateTime.now();
    // v0.6.13 (B): a child deactivating Device Admin must alert
    // the parent WITHIN A MINUTE — while the app is still
    // installed — not only on the next app start (which never
    // comes if the child uninstalls right after deactivating).
    // The receiver writes the deactivation time into the
    // FlutterSharedPreferences file; this task checks it every
    // cycle, claims it, and publishes the event. The next-start
    // path watches the same flag as backup.
    await _publishPendingAdminDisabledAlert();
    // Internet-off alert (v0.6.9): check connectivity FIRST, so
    // the offline window is tracked even when GPS is off or the
    // permission was revoked (the returns below must not skip it).
    final online = await _isOnline();
    final offlineSince =
        _internetOffTracker.check(online: online, now: now);
    if (offlineSince != null) {
      await _maybePublishInternetOffAlert(offlineSince);
    }
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
    // v0.6.12: battery-aware fix — last-known first, a low-power
    // check while stationary, GPS only on movement (or a 30-min
    // re-baseline). Same 60 s rhythm, same publish rules.
    final fix = await _loc.efficientFix();
    // The battery is read on EVERY cycle, even when there is no
    // new fix: it is published on its own schedule (v0.6.6) and
    // must not be dropped together with a throttled location.
    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {
      battery = -1; // Unknown battery shows no battery text (v0.6.2).
    }
    if (fix == null) {
      // No GPS fix right now, but the battery is still readable —
      // share it on its own schedule instead of dropping it.
      await _publishBatteryIfDue(battery, now);
      return;
    }
    // LocationService throttles (50 m / 60 s) by returning the
    // previous fix — do not publish the same fix twice. But the
    // battery still goes out on its own schedule (v0.6.6).
    if (_lastPublishedFixAt != null && fix.timestamp == _lastPublishedFixAt) {
      await _publishBatteryIfDue(battery, now);
      return;
    }
    try {
      // A failed battery read (-1) must never overwrite a real
      // level on the server: the battery fields are only written
      // when the level is known (v0.6.2).
      final update = <String, dynamic>{
        'lat': fix.latitude,
        'lon': fix.longitude,
        'isOnline': true,
        'lastSeen': now.toIso8601String(),
        'locationSharingOn': true,
      };
      if (battery >= 0 && battery <= 100) {
        update['battery'] = battery;
        update['batteryAt'] = now.toIso8601String();
      }
      // v0.6.13 (C): the protection level rides along, from the
      // cache the main isolate maintains (this isolate cannot call
      // the platform channels). Only when known — 'unknown' must
      // never clobber a level published earlier.
      final protection = await DeviceOwnerService.cachedLevel();
      if (protection != ProtectionLevel.unknown) {
        update['protection'] = protection.wireValue;
      }
      await _db!
          .child(FirebaseConfig.circleMemberPath(_circleId!, _uid!))
          .update(update);
      _lastPublishedFixAt = fix.timestamp;
      _batteryTracker.markPublished(battery: battery, now: now);
      try {
        final hh = now.hour.toString().padLeft(2, '0');
        final mm = now.minute.toString().padLeft(2, '0');
        await FlutterForegroundTask.updateService(
          notificationText:
              '${BackgroundLocationService.notificationTextFor(_isUrdu)} · ${trf(_isUrdu, 'svc_bgLastShared', {'time': '$hh:$mm'})}',
        );
      } catch (_) {
        // Notification text is cosmetic — sharing already happened.
      }
    } catch (e) {
      debugPrint('ApnaCircle: background location publish failed ($e)');
    }
  }

  /// Battery-only publish (v0.6.6) — see [BatteryPublishTracker].
  /// Writes only `battery` + `batteryAt`, never location or
  /// lastSeen: a member who has not moved keeps the last fix, but
  /// the family still sees a fresh battery level. The protection
  /// level (v0.6.13) rides along when known, so the parent's label
  /// stays fresh even while the member sits still.
  Future<void> _publishBatteryIfDue(int battery, DateTime now) async {
    if (!_batteryTracker.shouldPublish(battery: battery, now: now)) {
      return;
    }
    try {
      final data = <String, dynamic>{
        'battery': battery,
        'batteryAt': now.toIso8601String(),
      };
      final protection = await DeviceOwnerService.cachedLevel();
      if (protection != ProtectionLevel.unknown) {
        data['protection'] = protection.wireValue;
      }
      await _db!
          .child(FirebaseConfig.circleMemberPath(_circleId!, _uid!))
          .update(data);
      _batteryTracker.markPublished(battery: battery, now: now);
    } catch (e) {
      debugPrint('ApnaCircle: background battery publish failed ($e)');
    }
  }

  /// Immediate admin-deactivation alert (v0.6.13, part B). The
  /// receiver writes the deactivation time into the
  /// FlutterSharedPreferences file when the child turns Device
  /// Admin off. This task checks it EVERY cycle and publishes the
  /// `adminDisabled` event to the circle within a minute — while
  /// the app is still installed.
  ///
  /// OFFLINE RULE (v0.6.13 refinement): the flag is claimed
  /// (removed) ONLY after the write succeeds. With no network the
  /// write cannot land now, so the flag SURVIVES for the next
  /// cycle (or the next app start) to retry — it is never lost.
  /// The write is bounded by a 15 s timeout: the RTDB SDK queues
  /// offline writes, so a timed-out write may still land later
  /// AND a retry may send it again — the parent's phone dedupes
  /// identical adminDisabled events (same phone + same time).
  /// Honest limit, kept: with net off the alert CANNOT be sent
  /// immediately — no channel exists — and if the app is then
  /// uninstalled before any reconnect, nothing reports again;
  /// the parent-side 2-hour silence notice is the backstop for
  /// that case. Never throws, never breaks the location cycle.
  Future<void> _publishPendingAdminDisabledAlert() async {
    int? atMs;
    try {
      final prefs = await SharedPreferences.getInstance();
      atMs = prefs.getInt(DeviceAdminService.pendingDisabledPrefsKey);
      if (atMs == null) return;
    } catch (_) {
      return;
    }
    var published = false;
    try {
      final event = CircleEvent(
        type: 'adminDisabled',
        fromUid: _uid!,
        fromName: _name ?? 'Me',
        at: DateTime.fromMillisecondsSinceEpoch(atMs),
      );
      await _db!
          .child(FirebaseConfig.circleEventsPath(_circleId!))
          .push()
          .set(event.toJson())
          .timeout(const Duration(seconds: 15));
      published = true;
    } catch (e) {
      debugPrint(
        'ApnaCircle: background adminDisabled publish failed ($e)',
      );
    }
    if (!published) return; // Flag survives — retry next cycle.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(DeviceAdminService.pendingDisabledPrefsKey);
    } catch (_) {
      // The next-start path claims the same flag; the parent's
      // phone dedupes identical events.
    }
  }

  /// True when the phone has any data connection. A failed check
  /// reports online — an unknown state must never fake an offline
  /// window, and this must never break the location cycle.
  Future<bool> _isOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.isNotEmpty &&
          results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  /// Parent alert: this phone's internet was switched off at
  /// [since] and is back now (v0.6.9). Sent only when the parent
  /// left the Internet-off alert ON for this member — the flag is
  /// read from the locks node at this moment (we are back online,
  /// so the read should succeed) and cached for the next time.
  /// Honest limit: the alert CANNOT arrive while the phone is
  /// offline — no channel exists then except SMS — so it arrives
  /// on reconnect, labelled with when the internet went off.
  Future<void> _maybePublishInternetOffAlert(DateTime since) async {
    bool alertOn = _cachedInternetAlert;
    try {
      final snap = await _db!
          .child(FirebaseConfig.circleLocksPath(_circleId!, _uid!))
          .get()
          .timeout(const Duration(seconds: 5));
      final raw = snap.value;
      if (raw is Map) {
        final v = raw['internetAlert'];
        if (v is bool) {
          alertOn = v;
          _cachedInternetAlert = v;
        }
      }
    } catch (_) {
      // Keep the cached value — see the field comment.
    }
    if (!alertOn) return;
    final last = await _loc.lastKnown();
    final event = CircleEvent(
      type: 'internetOff',
      fromUid: _uid!,
      fromName: _name ?? 'Me',
      at: since,
      lat: last?.lat,
      lon: last?.lon,
    );
    try {
      await _db!
          .child(FirebaseConfig.circleEventsPath(_circleId!))
          .push()
          .set(event.toJson());
    } catch (e) {
      debugPrint('ApnaCircle: internetOff alert failed ($e)');
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

/// Detects the phone going offline and coming back, reporting the
/// offline window exactly once (v0.6.9). Pure logic, unit-tested.
///
/// Short blips (under [minOffline]) are ignored — a Wi-Fi/mobile
/// handover must not spam the parent with an alert. The window is
/// reported when the phone comes back online, never while it is
/// offline (there is no channel to the parent then except SMS).
class InternetOffTracker {
  static const Duration minOffline = Duration(minutes: 2);

  DateTime? _offlineSince;

  /// Returns the start of the offline window when the phone just
  /// came back online after being offline for at least [minOffline];
  /// null otherwise (still online, just went offline, still
  /// offline, or the window was too short to report).
  DateTime? check({required bool online, required DateTime now}) {
    if (!online) {
      _offlineSince ??= now;
      return null;
    }
    final since = _offlineSince;
    _offlineSince = null;
    if (since == null) return null;
    if (now.difference(since) < minOffline) return null;
    return since;
  }
}
