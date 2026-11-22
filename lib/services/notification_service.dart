import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'firebase_bootstrap.dart';
import 'sync_service.dart';

/// Background message handler — MUST be a top-level function.
/// Runs when a push arrives while the app is closed/killed. It
/// cannot touch the UI; it only logs (and, in future, can write a
/// local notification). Registered in main.dart, only when Firebase
/// is configured.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint(
    'ApnaCircle: background push: ${message.notification?.title}',
  );
}

/// Firebase Cloud Messaging — SOS / battery-low / phone-off push
/// to the parent (v0.3, 22 Nov 2026).
///
/// What is wired HERE (in-app, no server):
/// * Notification permission request (Android 13+ asks on first run).
/// * FCM token fetch + refresh, stored on the user's profile node
///   (`users/{uid}/profile/fcmToken`) so a server can target it.
/// * Foreground messages exposed as a [messages] stream — the Home
///   screen shows them as an alert banner/SnackBar.
/// * Background handler registered (see top of this file).
///
/// What is HONESTLY NOT here (needs a server, no server exists yet):
/// sending a push FROM one phone TO another. FCM delivery needs
/// the server key, and the server key must NEVER be in the app.
/// Until a Cloud Function / tiny server exists, SOS delivery
/// between phones uses the RTDB `events` node (see SyncService —
/// the parent's phone listens to it live while the app runs).
/// That is documented in FIREBASE_SETUP.md §4 — not hidden.
class NotificationService extends ChangeNotifier {
  NotificationService(this._sync);

  final SyncService _sync;

  final _messagesController = StreamController<RemoteMessage>.broadcast();

  /// Foreground push messages (title/body/data).
  Stream<RemoteMessage> get messages => _messagesController.stream;

  String? _token;
  String? get token => _token;

  Future<void> initialize() async {
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
        _messagesController.add(message);
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        _messagesController.add(message);
      });
    } catch (e) {
      debugPrint('ApnaCircle: FCM init failed ($e)');
    }
  }

  @override
  void dispose() {
    _messagesController.close();
    super.dispose();
  }
}
