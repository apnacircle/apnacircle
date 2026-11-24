/// WhatsApp-style family chat notifications — pure mapping logic
/// (v0.6.11).
///
/// Kept free of Flutter plugins so it is unit-testable. The
/// NotificationService uses this to build the actual notification.
///
/// WHY THIS EXISTS (user-reported 24 Nov 2026, live): in the family
/// chat, when someone sent a message nobody knew unless they opened
/// the app. Like WhatsApp, a message must appear OUTSIDE the app —
/// sender's name + a short preview + sound — so members know a
/// message arrived.
///
/// DELIBERATELY NOT AN EMERGENCY: chat goes on its OWN channel
/// ("ApnaCircle Chat", normal importance, sound + vibration) — a
/// chat message must never ring like an SOS call. See
/// alert_notification.dart for the loud emergency channel.
library;

import '../models/chat_message.dart';

/// One chat message, ready to show — the sender's name is the
/// title and the message preview is the body, exactly like
/// WhatsApp.
class ChatNotification {
  const ChatNotification({
    required this.title,
    required this.body,
    required this.circleId,
    required this.messageId,
    required this.dedupeKey,
  });

  final String title;
  final String body;
  final String circleId;
  final String messageId;

  /// Key for the dedupe (see [ChatNotifications.dedupeKeyFor]).
  final String dedupeKey;
}

class ChatNotifications {
  /// Dedicated channel for family chat. Normal importance: sound +
  /// vibration, but no heads-up intrusion and NO full-screen
  /// intent — chat is not an emergency. The Cloud Function sends
  /// chat pushes DATA-ONLY on purpose, so the app shows them on
  /// THIS channel; if they carried a `notification` payload the
  /// system would display them on the default (loud alerts)
  /// channel instead and a chat message would ring like an SOS.
  static const String channelId = 'apnacircle_chat';
  static const String channelName = 'ApnaCircle Chat';
  static const String channelDescription =
      'Family chat messages — sender name + preview, with sound. '
      'Quieter than emergency alerts.';

  /// Payload attached to every chat notification. Tapping it opens
  /// the app on the Chat tab.
  static const String tapPayload = 'chat';

  /// A preview is a preview: WhatsApp shows a short snippet, not
  /// a whole essay, and a long message must not flood the shade.
  static const int snippetMaxLength = 120;

  /// Title is the sender's name — the receiver knows WHO at a
  /// glance, before reading a word.
  static String titleFor(String senderName) =>
      senderName.isEmpty ? 'A family member' : senderName;

  /// Short preview of the message text: whitespace collapsed, cut
  /// at [snippetMaxLength] with an ellipsis when longer.
  static String snippetFor(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return '';
    if (t.length <= snippetMaxLength) return t;
    return '${t.substring(0, snippetMaxLength).trimRight()}…';
  }

  /// Build the notification for one chat message.
  static ChatNotification fromMessage({
    required ChatMessage msg,
    required String circleId,
  }) {
    return ChatNotification(
      title: titleFor(msg.senderName),
      body: snippetFor(msg.text),
      circleId: circleId,
      messageId: msg.id,
      dedupeKey: dedupeKeyFor(msg.id),
    );
  }

  /// Dedupe key shared by the FCM path and the RTDB path for the
  /// SAME message: the RTDB push key is the message's id, and the
  /// Cloud Function sends that same id in the push data — so the
  /// message arriving over both paths within seconds rings once,
  /// not twice. (The dedupe itself is [AlertDedupe]: it is
  /// generic over keys, only the name says "alert".)
  static String dedupeKeyFor(String messageId) => 'chat:$messageId';

  /// Stable notification id per circle, so a new message in one
  /// circle updates that circle's notification instead of stacking
  /// a dozen identical ones — and two circles keep separate
  /// notifications.
  static int notificationIdFor(String circleId) =>
      2000 + (circleId.hashCode.abs() % 900);

  /// Should this message ring? Three suppressions, all on purpose:
  /// * my OWN messages — I already know I sent it;
  /// * an empty message — there is nothing to preview;
  /// * the user is ALREADY looking at that circle's chat screen —
  ///   same as WhatsApp, no ping for the open chat.
  static bool shouldNotify({
    required ChatMessage msg,
    required String circleId,
    String? myUid,
    String? openChatCircleId,
  }) {
    if (msg.text.trim().isEmpty) return false;
    if (myUid != null && msg.senderId == myUid) return false;
    if (openChatCircleId != null && openChatCircleId == circleId) {
      return false;
    }
    return true;
  }
}
