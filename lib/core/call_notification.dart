/// Incoming-call notification (v0.6.21) — the constants the
/// NotificationService and the Home screen agree on. Mirrors
/// chat_notification.dart / alert_notification.dart.
///
/// Tapping the notification opens the incoming-call screen:
/// payload 'call:{callId}'. The Home screen drains it from the
/// pending slot on cold start, exactly like 'alerts' / 'chat'.
class CallNotifications {
  /// One notification id for incoming calls (a second incoming
  /// call replaces the first — a phone shows one call at a time).
  static const int notificationId = 2001;

  static String tapPayload(String callId) => 'call:$callId';

  /// The call id carried by a 'call:' tap payload, or null.
  static String? callIdFromPayload(String payload) {
    if (!payload.startsWith('call:')) return null;
    final id = payload.substring('call:'.length);
    return id.isEmpty ? null : id;
  }
}
