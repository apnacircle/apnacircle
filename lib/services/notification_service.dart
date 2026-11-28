import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as local;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alert_notification.dart';
import '../core/call_notification.dart';
import '../core/chat_notification.dart';
import '../l10n/strings.dart';
import '../models/chat_message.dart';
import '../models/circle.dart';
import 'firebase_bootstrap.dart';
import 'sync_service.dart';

/// Persisted language choice (same key as LanguageService):
/// 'ur' means the user picked Urdu. Used where no locale can be
/// threaded in (the top-level background push handler).
Future<bool> _persistedIsUrdu() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('language_code_v1') == 'ur';
  } catch (_) {
    return false;
  }
}

/// The loud alerts channel — high importance, sound + vibration +
/// lights. Created at startup (and in the background handler) so it
/// exists before any alert arrives.
///
/// v0.6.17: custom 3-second siren (`res/raw/sos_alert.wav`) +
/// 3-second vibration pattern. The user reported (26 Nov 2026)
/// the old alert was "bohat chhota" — the short default system
/// ding, over before anyone noticed it. The siren is a loud hi-lo
/// alarm at full amplitude; the pattern buzzes for the same 3 s.
/// HONEST LIMIT: the sound still plays on the phone's notification
/// volume — if the phone is on silent / Do Not Disturb, Android
/// will not play it. Only an alarm-stream full-screen activity
/// could bypass that, which this version does not add.
local.AndroidNotificationChannel _alertChannel() =>
    local.AndroidNotificationChannel(
      AlertNotifications.channelId,
      AlertNotifications.channelName,
      description: AlertNotifications.channelDescription,
      importance: local.Importance.max,
      playSound: true,
      sound: const local.RawResourceAndroidNotificationSound(
        AlertNotifications.alertSoundName,
      ),
      enableVibration: true,
      vibrationPattern: Int64List.fromList(
        AlertNotifications.alertVibrationPatternMs,
      ),
      enableLights: true,
    );

/// The chat channel — normal importance, sound + vibration, NO
/// full-screen intent and no heads-up intrusion. A chat message
/// must never ring like an SOS call (v0.6.11). Created at startup
/// (and in the background handler) alongside the alerts channel.
local.AndroidNotificationChannel _chatChannel() =>
    const local.AndroidNotificationChannel(
      ChatNotifications.channelId,
      ChatNotifications.channelName,
      description: ChatNotifications.channelDescription,
      importance: local.Importance.defaultImportance,
      playSound: true,
      enableVibration: true,
    );

/// Platform details for one chat notification. Normal priority,
/// message category, lock-screen preview visible (like WhatsApp —
/// a family app, the preview is the point).
local.NotificationDetails _chatDetails() {
  return const local.NotificationDetails(
    android: local.AndroidNotificationDetails(
      ChatNotifications.channelId,
      ChatNotifications.channelName,
      channelDescription: ChatNotifications.channelDescription,
      importance: local.Importance.defaultImportance,
      priority: local.Priority.defaultPriority,
      playSound: true,
      enableVibration: true,
      category: local.AndroidNotificationCategory.message,
      visibility: local.NotificationVisibility.public,
      ticker: 'ApnaCircle chat',
    ),
    iOS: local.DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: local.InterruptionLevel.active,
    ),
  );
}

/// Posts one chat message through [plugin]. Shared by the
/// foreground instance methods and the background handler below.
Future<bool> _postChatNotification(
  local.FlutterLocalNotificationsPlugin plugin, {
  required ChatNotification chat,
}) async {
  try {
    await plugin.show(
      id: ChatNotifications.notificationIdFor(chat.circleId),
      title: chat.title,
      body: chat.body,
      notificationDetails: _chatDetails(),
      payload: ChatNotifications.tapPayload,
    );
    return true;
  } catch (e) {
    debugPrint('ApnaCircle: chat notification failed ($e)');
    return false;
  }
}

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
      // v0.6.17: same 3-second siren + 3-second buzz as the channel
      // (pre-Android-8 devices read the sound from here).
      sound: const local.RawResourceAndroidNotificationSound(
        AlertNotifications.alertSoundName,
      ),
      enableVibration: true,
      vibrationPattern: Int64List.fromList(
        AlertNotifications.alertVibrationPatternMs,
      ),
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
    final android = plugin.resolvePlatformSpecificImplementation<
        local.AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_alertChannel());
    await android?.createNotificationChannel(_chatChannel());
    final type = message.data['type'] as String? ?? 'alert';
    // v0.6.11: family chat pushes are DATA-ONLY (the function
    // sends no `notification` payload, so the system never shows
    // them on the loud alerts channel). Build the visible
    // notification here, on the normal chat channel.
    if (type == 'chat') {
      final chat = ChatNotifications.fromMessage(
        msg: ChatMessage(
          id: message.data['messageId'] as String? ?? '',
          senderId: message.data['fromUid'] as String? ?? '',
          senderName: message.data['senderName'] as String? ??
              message.notification?.title ??
              '',
          text: message.data['preview'] as String? ??
              message.notification?.body ??
              '',
          at: DateTime.now(),
        ),
        circleId: message.data['circleId'] as String? ?? '',
      );
      await _postChatNotification(plugin, chat: chat);
      return;
    }
    final isUrdu = await _persistedIsUrdu();
    final fallbackName = tr(isUrdu, 'svc_familyMember');
    final title = message.notification?.title ??
        AlertNotifications.titleFor(type, fallbackName);
    final body = message.notification?.body ??
        AlertNotifications.bodyFor(type, fallbackName);
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
///   tab ([tapRequests] + [takePendingTap]); tapping a chat
///   notification opens the Chat tab (payload 'chat', v0.6.11).
/// * Chat messages (v0.6.11) go on their OWN normal-importance
///   channel ("ApnaCircle Chat") with sound + vibration — sender
///   name + preview, like WhatsApp — and NEVER ring like an SOS.
///   Own messages never notify, and neither do messages in the
///   chat the user is already looking at ([openChatCircleId],
///   set by ChatScreen). FCM + RTDB delivery of the same message
///   is deduped by message id.
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
  final AlertDedupe _chatDedupe = AlertDedupe();
  bool _localReady = false;

  /// The circle whose chat screen the user is looking at right
  /// now (v0.6.11). ChatScreen sets this when it opens and clears
  /// it when it closes — while it is set, messages in THAT circle
  /// do not ring (same as WhatsApp: no ping for the open chat).
  /// Null when no chat screen is open.
  String? openChatCircleId;

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
      final android = _local.resolvePlatformSpecificImplementation<
          local.AndroidFlutterLocalNotificationsPlugin>();
      // v0.6.17: drop the old channel — its sound/vibration are
      // frozen by Android and can never become the 3-second siren.
      // Deleting is safe: nothing posts to it anymore.
      await android?.deleteNotificationChannel(
        channelId: AlertNotifications.legacyChannelId,
      );
      await android?.createNotificationChannel(_alertChannel());
      await android?.createNotificationChannel(_chatChannel());
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
        // v0.6.11: chat pushes take the chat path (normal sound,
        // sender name + preview) and never reach the alert
        // SnackBar — the chat list itself shows the message.
        if (message.data['type'] == 'chat') {
          unawaited(showChatFromMessage(message));
          return;
        }
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
  Future<bool> showAlertFromMessage(
    RemoteMessage message, {
    bool isUrdu = false,
  }) async {
    final type = message.data['type'] as String? ?? 'alert';
    final fromUid = message.data['fromUid'] as String? ?? '';
    final fallbackName = tr(isUrdu, 'svc_familyMember');
    final title = message.notification?.title ??
        AlertNotifications.titleFor(type, fallbackName);
    final body = message.notification?.body ??
        AlertNotifications.bodyFor(type, fallbackName);
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

  /// Incoming-call ring (v0.6.21): a full-screen-intent
  /// notification on the loud alerts channel — it rings over the
  /// lock screen like a phone call. Tapping it opens the
  /// incoming-call screen (payload 'call:{callId}').
  ///
  /// HONEST NOTE: the ringtone is the same 3-second siren as SOS
  /// (v0.6.17) — there is no separate ringtone file yet. The
  /// full-screen intent is what makes it feel like a call.
  Future<bool> showIncomingCall({
    required String callerName,
    required bool isVideo,
    required String callId,
    bool isUrdu = false,
  }) async {
    await _ensureLocalNotifications();
    if (!_localReady) return false;
    try {
      await _local.show(
        id: CallNotifications.notificationId,
        title: tr(
          isUrdu,
          isVideo ? 'svc_callIncomingVideo' : 'svc_callIncomingAudio',
        ),
        body: trf(isUrdu, 'svc_callIsCalling', {'name': callerName}),
        notificationDetails: _alertDetails(isSos: true),
        payload: CallNotifications.tapPayload(callId),
      );
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: incoming-call notification failed ($e)');
      return false;
    }
  }

  /// WhatsApp-style notification for one family chat message
  /// (v0.6.11): sender's name + preview, on the normal chat
  /// channel — never the loud emergency one. Called by Home for
  /// messages arriving live over RTDB. Suppressed for my own
  /// messages, for empty text, and while the user is looking at
  /// that circle's chat screen ([openChatCircleId]). Deduped
  /// against the FCM path by message id, so one message rings
  /// once. Returns false when suppressed or not ready.
  Future<bool> showChatMessage(
    ChatMessage msg, {
    required String circleId,
  }) async {
    await _ensureLocalNotifications();
    if (!_localReady) return false;
    final chat = ChatNotifications.fromMessage(msg: msg, circleId: circleId);
    if (!ChatNotifications.shouldNotify(
      msg: msg,
      circleId: circleId,
      myUid: _sync.uid,
      openChatCircleId: openChatCircleId,
    )) {
      return false;
    }
    if (!_chatDedupe.shouldShow(chat.dedupeKey)) return false;
    return _postChatNotification(_local, chat: chat);
  }

  /// Chat notification for one foreground FCM message. The Cloud
  /// Function sends the message id, sender and preview as data,
  /// so the RTDB path and this path share the same dedupe key.
  Future<bool> showChatFromMessage(RemoteMessage message) async {
    final data = message.data;
    final msg = ChatMessage(
      id: data['messageId'] as String? ?? '',
      senderId: data['fromUid'] as String? ?? '',
      senderName:
          data['senderName'] as String? ?? message.notification?.title ?? '',
      text: data['preview'] as String? ?? message.notification?.body ?? '',
      at: DateTime.now(),
    );
    return showChatMessage(
      msg,
      circleId: data['circleId'] as String? ?? '',
    );
  }

  @override
  void dispose() {
    _messagesController.close();
    _tapController.close();
    super.dispose();
  }
}
