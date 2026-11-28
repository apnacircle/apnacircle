/// Loud emergency alert notifications — pure mapping logic (v0.6.10).
///
/// Kept free of Flutter plugins so it is unit-testable. The
/// NotificationService uses this to build the actual notification.
///
/// WHY THIS EXISTS (user-reported 24 Nov 2026, live): an SOS/alert
/// only showed as a silent red banner INSIDE the app after someone
/// opened it. For an emergency that is useless — it must ring like
/// a call. So alerts now go out on a dedicated high-importance
/// channel with sound + vibration, and SOS uses a full-screen
/// intent (rings over the lock screen, like an incoming call).
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
/// One alert, ready to show — title/body already include the
/// sender's name, so the receiver knows WHO at a glance.
class AlertNotification {
  const AlertNotification({
    required this.title,
    required this.body,
    required this.type,
    required this.isSos,
    required this.dedupeKey,
  });

  final String title;
  final String body;

  /// Event type: 'sos' | 'lowBattery' | 'phoneOff' | 'internetOff'
  /// | 'locationOff' | 'simChanged' | 'adminDisabled' | ...
  final String type;

  /// SOS rings with a full-screen intent; other alerts ring loud
  /// on the same channel but without taking over the screen.
  final bool isSos;

  /// Key for the 60-second dedupe (see [AlertNotifications]).
  final String dedupeKey;
}

class AlertNotifications {
  /// Dedicated channel for family alerts. The manifest also points
  /// FCM's default channel at this id, so a push that arrives while
  /// the app is closed/killed is still shown by the system on THIS
  /// loud channel instead of the silent default one.
  ///
  /// v0.6.17: id is `..._v2`, NOT the original `apnacircle_alerts`.
  /// Android NEVER updates an existing channel's sound/vibration —
  /// the v0.6.10 channel on the user's phone is stuck on the short
  /// default system "ding", which is exactly the complaint (26 Nov
  /// 2026: "bohat chhota hai, pata hi nahi chalta"). A fresh id is
  /// the only way the new 3-second siren + 3-second vibration
  /// actually apply. The old channel is deleted at startup and is
  /// never used again.
  static const String channelId = 'apnacircle_alerts_v2';

  /// Previous channel id (v0.6.10–v0.6.16) — deleted at startup,
  /// never posted to again.
  static const String legacyChannelId = 'apnacircle_alerts';

  /// Custom alarm sound (v0.6.17): `res/raw/sos_alert.wav`, a
  /// 3-second hi-lo siren generated for this app. Used as the
  /// channel sound AND the per-notification sound, so the alert
  /// rings a full 3 seconds instead of the ~1 s default ding.
  static const String alertSoundName = 'sos_alert';

  /// Vibration pattern in milliseconds (v0.6.17): wait 0, then 4
  /// buzzes of 600 ms with 200 ms gaps — 3000 ms total, matching
  /// the 3-second siren, so the phone buzzes for as long as it
  /// rings. Stored on the channel at creation (Android 8+ reads
  /// the pattern from the channel, not the notification).
  static const List<int> alertVibrationPatternMs = [
    0, 600, 200, 600, 200, 600, 200, 600,
  ];

  /// Total vibration time (pattern sum) — the test asserts this is
  /// at least 2.5 s, so a future edit cannot silently shorten the
  /// alert back to a single buzz.
  static int get alertVibrationTotalMs =>
      alertVibrationPatternMs.fold(0, (a, b) => a + b);

  /// English default (kept for existing call sites). Use
  /// [channelNameFor]/[channelDescriptionFor] for the locale.
  static const String channelName = 'ApnaCircle Alerts';
  static const String channelDescription =
      'Loud emergency alerts from your family — SOS and safety '
      'alerts. Keep sound on.';

  /// Localized channel name / description (v0.6.32). Android shows
  /// these in system Settings, so they follow the phone's chosen
  /// language, not the build default.
  static String channelNameFor({bool isUrdu = false}) =>
      tr(isUrdu, 'core_notifChannelName');
  static String channelDescriptionFor({bool isUrdu = false}) =>
      tr(isUrdu, 'core_notifChannelDesc');

  /// Payload attached to every alert notification. Tapping it opens
  /// the app on the Alerts tab.
  static const String tapPayload = 'alerts';

  static bool isSos(String type) => type == 'sos';

  /// Title for a local notification — always names the sender.
  /// (The Cloud Function's own titles do not include the name; the
  /// body does. Local notifications built here name them in both.)
  /// v0.6.32: localized via [isUrdu] (default English, as before).
  static String titleFor(String type, String fromName,
      {bool isUrdu = false}) {
    final args = {'name': fromName};
    switch (type) {
      case 'sos':
        return trf(isUrdu, 'core_alertTitleSos', args);
      case 'lowBattery':
        return trf(isUrdu, 'core_alertTitleLowBattery', args);
      case 'phoneOff':
        return trf(isUrdu, 'core_alertTitlePhoneOff', args);
      case 'internetOff':
        return trf(isUrdu, 'core_alertTitleInternetOff', args);
      case 'locationOff':
        return trf(isUrdu, 'core_alertTitleLocationOff', args);
      case 'simChanged':
        return trf(isUrdu, 'core_alertTitleSimChanged', args);
      case 'adminDisabled':
        return trf(isUrdu, 'core_alertTitleProtectionOff', args);
      default:
        return trf(isUrdu, 'core_alertTitleGeneric', args);
    }
  }

  /// Body — mirrors the Cloud Function's bodyFor() wording so the
  /// same event reads the same whether it arrives by push or live.
  /// v0.6.32: localized via [isUrdu] (default English, as before).
  static String bodyFor(String type, String fromName,
      {bool isUrdu = false}) {
    final args = {'name': fromName};
    switch (type) {
      case 'sos':
        return trf(isUrdu, 'core_alertBodySos', args);
      case 'lowBattery':
        return trf(isUrdu, 'core_alertBodyLowBattery', args);
      case 'phoneOff':
        return trf(isUrdu, 'core_alertBodyPhoneOff', args);
      case 'internetOff':
        return trf(isUrdu, 'core_alertBodyInternetOff', args);
      case 'locationOff':
        return trf(isUrdu, 'core_alertBodyLocationOff', args);
      case 'simChanged':
        return trf(isUrdu, 'core_alertBodySimChanged', args);
      case 'adminDisabled':
        return trf(isUrdu, 'core_alertBodyProtectionOff', args);
      default:
        return trf(isUrdu, 'core_alertBodyGeneric', args);
    }
  }

  /// Reads the persisted language choice once (SharedPreferences
  /// key `language_code_v1`, written by LanguageService). True
  /// when the user chose Urdu. Defaults to English on any failure
  /// — a notification must never fail because the locale could
  /// not be read. Call sites with a locale already in hand should
  /// pass [isUrdu] to [fromEvent] directly instead.
  static Future<bool> isUrduPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('language_code_v1') == 'ur';
    } catch (_) {
      return false;
    }
  }

  /// Build the notification for one in-app (RTDB) circle event.
  /// [fromName] falls back to 'A family member' when empty.
  /// v0.6.32: pass [isUrdu] when the caller knows the locale, or
  /// use [fromEventLocalized] to read the persisted choice.
  static AlertNotification fromEvent({
    required String type,
    required String fromUid,
    required String fromName,
    required DateTime now,
    bool isUrdu = false,
  }) {
    final name = fromName.isEmpty
        ? tr(isUrdu, 'core_alertFallbackName')
        : fromName;
    return AlertNotification(
      title: titleFor(type, name, isUrdu: isUrdu),
      body: bodyFor(type, name, isUrdu: isUrdu),
      type: type,
      isSos: isSos(type),
      dedupeKey: minuteKey(type, fromUid, now),
    );
  }

  /// Same as [fromEvent] but reads the persisted language once
  /// from SharedPreferences, so the notification renders in the
  /// phone's chosen locale even when the caller has no locale.
  static Future<AlertNotification> fromEventLocalized({
    required String type,
    required String fromUid,
    required String fromName,
    required DateTime now,
  }) async =>
      fromEvent(
        type: type,
        fromUid: fromUid,
        fromName: fromName,
        now: now,
        isUrdu: await isUrduPersisted(),
      );

  /// Dedupe key shared by the FCM path and the RTDB path for the
  /// SAME alert: type + sender + the minute it arrived. The Cloud
  /// Function sends the event over FCM while the RTDB stream
  /// delivers it in-app within seconds — without this shared key
  /// the phone would ring twice for one alert.
  static String minuteKey(String type, String fromUid, DateTime now) =>
      'event:$type:$fromUid:${now.millisecondsSinceEpoch ~/ 60000}';

  /// Stable notification id per alert type, so a repeat of the same
  /// alert updates the one already showing instead of stacking a
  /// dozen identical notifications.
  static int notificationIdFor(String type) {
    switch (type) {
      case 'sos':
        return 1001;
      case 'lowBattery':
        return 1002;
      case 'phoneOff':
        return 1003;
      case 'internetOff':
        return 1004;
      case 'locationOff':
        return 1005;
      case 'simChanged':
        return 1006;
      case 'adminDisabled':
        return 1007;
      default:
        return 1099;
    }
  }
}

/// 60-second dedupe: the same alert key is shown once, then
/// suppressed until the window passes. A NEW alert of the same
/// type from the same sender a minute later still rings.
class AlertDedupe {
  AlertDedupe({
    this.window = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final Map<String, DateTime> _seen = {};

  /// Returns true when this key may be shown now (and records it).
  bool shouldShow(String key) {
    final now = _now();
    final last = _seen[key];
    if (last != null && now.difference(last) < window) return false;
    _seen[key] = now;
    return true;
  }
}
