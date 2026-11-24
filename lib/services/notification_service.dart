import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as local;

import '../core/alert_notification.dart';
import '../models/circle.dart';
import 'firebase_bootstrap.dart';
import 'sync_service.dart';

/// The loud alerts channel — high importance, sound + vibration +
/// lights. Created at startup (and in the background handler) so it
/// exists before any alert arrives.
local.AndroidNotificationChannel _alertChannel() =>
    const local.AndroidNotificationChannel(
      AlertNotifications.channelId,
      AlertNotifications.channelName,
      description: AlertNotifications.channelDescription,
      importance: local.Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
    );

/// Platform details for one alert notification. SOS gets a
/// full-screen intent (rings over the lock screen like an incoming
/// call); other alerts ring loud on the same channel.
local.NotificationDetails _alertDetails({required bool isSos}) {
  return local.NotificationDetails(
    android: local.AndroidNotificationDetails(
      AlertNotifications.channelId,
      AlertNotifications.channelName,
      channelDescription: AlertNotifications.channelDescription,
      importance: local.Importance.max,
      priority: local.Priority.high,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      fullScreenIntent: isSos,
      category: isSos
          ? local.AndroidNotificationCategory.call
          : local.AndroidNotificationCategory.message,
      visibility: local.NotificationVisibility.public,
      ticker: 'ApnaCircle alert',
    ),
    iOS: local.DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: isSos
          ? local.InterruptionLevel.critical
          : local.InterruptionLevel.timeSensitive,
    ),
  );
}

/// Posts one alert through [plugin]. Shared by the foreground
/// instance methods and the background handler below.
Future<bool> _postAlertNotification(
  local.FlutterLocalNotificationsPlugin plugin, {
  required AlertNotification alert,
}) async {
  try {
    await plugin.show(
      id: AlertNotifications.notificationIdFor(alert.type),
      title: alert.title,
      body: alert.body,
      notificationDetails: _alertDetails(isSos: alert.isSos),
      payload: AlertNotifications.tapPayload,
    );
    return true;
  } catch (e) {
    debugPrint('ApnaCircle: alert notification failed ($e)');
    return false;
  }
}

/// Background message handler — MUST be a top-level function.
/// Runs when a push arrives while the app is closed/killed.
///
/// HONEST LIMIT: this only runs for DATA-ONLY messages. A message
/// that also carries a `notification` payload is displayed by the
/// system itself — this handler never runs for it. The Cloud
/// Function currently sends notification + data, so while the app
/// is closed/killed the system shows it on the loud default
/// channel (see AndroidManifest: default_notification_channel_id)
/// — loud, but WITHOUT the SOS full-screen intent. Full-screen
/// SOS while killed needs the function to send data-only pushes;
/// the function code is intentionally NOT changed here (parent's
/// step). While the app is open, the foreground path below gives
/// SOS its full-screen ring either way.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint(
    'ApnaCircle: background push: ${message.notification?.title}',
  );
  try {
    DartPluginRegistrant.ensureInitialized();
    final plugin = local.FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const local.InitializationSettings(
        android: local.AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = plugin
        .resolvePlatformSpecificImplementation<
            local.AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_alertChannel());
    final type = message.data['type'] as String? ?? 'alert';
    final title = message.notification?.title ??
        AlertNotifications.titleFor(type, 'A family member');
    final body = message.notification?.body ??
        AlertNotifications.bodyFor(type, 'A family member');
    await _postAlertNotification(
      plugin,
      alert: AlertNotification(
        title: title,
        body: body,
        type: type,
        isSos: AlertNotifications.isSos(type),
        dedupeKey: '',
      ),
    );
  } catch (e) {
    debugPrint('ApnaCircle: background alert notification failed ($e)');
  }
}

/// Firebase Cloud Messaging — SOS / battery-low / phone-off push
/// to the family (v0.3, 22 Nov 2026), LOUD since v0.6.10.
///
/// What is wired HERE:
/// * A dedicated "ApnaCircle Alerts" channel (IMPORTANCE_HIGH,
///   sound + vibration + lights), created at startup so it exists
///   before any alert arrives. The manifest also points FCM's
///   default channel at it, so a push that arrives while the app
///   is closed/killed is shown by the system on THIS loud channel.
/// * Foreground pushes ring loud via a local notification (SOS
///   with a full-screen intent) AND are exposed on [messages] —
///   the Home screen still shows its banner/SnackBar on top.
/// * RTDB circle events arriving while the app is open also ring
///   loud ([showAlertFromEvent]) — the user must hear an SOS
///   without staring at the screen. FCM + RTDB delivery of the
///   SAME alert is deduped (60 s window) so the phone rings once.
/// * Tapping an alert notification opens the app on the Alerts
///   tab ([tapRequests] + [takePendingTap]).
/// * FCM token fetch + refresh, stored on the user's profile node
///   (`users/{uid}/profile/fcmToken`) so the server can target it.
/// * Background handler registered (see top of this file).
///
/// What is HONESTLY NOT here (needs a server step, no server
/// change in this version): the Cloud Function
/// `sendCircleEventPush` (functions/index.js) is NOT deployed yet,
/// so no push is sent at all while the app is closed — deploy it
/// and pushes start flowing. Push also needs internet on the
/// RECEIVER's phone: if a member's phone is offline (no data), no
/// push can arrive (SMS fallback covers location only, not
/// alerts). A user can still mute the channel or turn on Do Not
/// Disturb — Android lets them, no app can prevent it.
class NotificationService extends ChangeNotifier {
  NotificationService(this._sync);

  final SyncService _sync;

  final _messagesController = StreamController<RemoteMessage>.broadcast();

  /// Foreground push messages (title/body/data).
  Stream<RemoteMessage> get messages => _messagesController.stream;

  final _tapController = StreamController<String>.broadcast();

  /// Payloads of alert notifications the user tapped. Home
  /// subscribes and opens the Alerts tab on 'alerts'.
  Stream<String> get tapRequests => _tapController.stream;

  /// A tap that arrived before Home was listening (cold start via
  /// FCM onMessageOpenedApp / notification tap). Home drains it
  /// once on start.
  String? _pendingTapPayload;
  String? takePendingTap() {
    final p = _pendingTapPayload;
    _pendingTapPayload = null;
    return p;
  }

  final local.FlutterLocalNotificationsPlugin _local =
      local.FlutterLocalNotificationsPlugin();
  final AlertDedupe _dedupe = AlertDedupe();
  bool _localReady = false;

  String? _token;
  String? get token => _token;

  /// Creates the loud alerts channel + wires notification taps.
  /// Safe to call twice; does NOT need Firebase.
  Future<void> _ensureLocalNotifications() async {
    if (_localReady) return;
    try {
      await _local.initialize(
        settings: const local.InitializationSettings(
          android: local.AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: local.DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload == null) return;
          _pendingTapPayload = payload;
          _tapController.add(payload);
        },
      );
      final android = _local
          .resolvePlatformSpecificImplementation<
              local.AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_alertChannel());
      _localReady = true;
    } catch (e) {
      debugPrint('ApnaCircle: local notifications init failed ($e)');
    }
  }

  Future<void> initialize() async {
    // Channel first: it must exist before any alert can ring.
    await _ensureLocalNotifications();
    if (!FirebaseBootstrap.available) return;
    try {
      final messaging = FirebaseMessaging.instance;
      // Android 13+: the OS asks the user the first time.
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      _token = await messaging.getToken();
      if (_token != null) await _sync.saveProfile(fcmToken: _token);
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        _token = newToken;
        await _sync.saveProfile(fcmToken: newToken);
      });
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(showAlertFromMessage(message));
        _messagesController.add(message);
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _pendingTapPayload = AlertNotifications.tapPayload;
        _tapController.add(AlertNotifications.tapPayload);
        _messagesController.add(message);
      });
    } catch (e) {
      debugPrint('ApnaCircle: FCM init failed ($e)');
    }
  }

  /// Loud local notification for one in-app (RTDB) circle event.
  /// Called by Home on top of the red SnackBar — the user must
  /// hear it without staring at the screen. Deduped against the
  /// FCM path so the same alert rings once.
  Future<bool> showAlertFromEvent(CircleEvent event) async {
    final alert = AlertNotifications.fromEvent(
      type: event.type,
      fromUid: event.fromUid,
      fromName: event.fromName,
      now: DateTime.now(),
    );
    return showAlert(alert);
  }

  /// Loud local notification for one foreground FCM message.
  /// Title/body come from the Cloud Function (the sender's name
  /// is in the body).
  Future<bool> showAlertFromMessage(RemoteMessage message) async {
    final type = message.data['type'] as String? ?? 'alert';
    final fromUid = message.data['fromUid'] as String? ?? '';
    final title = message.notification?.title ??
        AlertNotifications.titleFor(type, 'A family member');
    final body = message.notification?.body ??
        AlertNotifications.bodyFor(type, 'A family member');
    final alert = AlertNotification(
      title: title,
      body: body,
      type: type,
      isSos: AlertNotifications.isSos(type),
      dedupeKey: AlertNotifications.minuteKey(type, fromUid, DateTime.now()),
    );
    return showAlert(alert);
  }

  /// Shows [alert] unless the same alert rang in the last 60 s
  /// (FCM + RTDB deliver the same event twice). Returns false
  /// when suppressed or when local notifications are not ready.
  Future<bool> showAlert(AlertNotification alert) async {
    await _ensureLocalNotifications();
    if (!_localReady) return false;
    if (!_dedupe.shouldShow(alert.dedupeKey)) return false;
    return _postAlertNotification(_local, alert: alert);
  }

  @override
  void dispose() {
    _messagesController.close();
    _tapController.close();
    super.dispose();
  }
}
