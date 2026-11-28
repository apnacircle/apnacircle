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

import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
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
  /// English default (kept for existing call sites). Use
  /// [channelNameFor]/[channelDescriptionFor] for the locale.
  static const String channelName = 'ApnaCircle Chat';
  static const String channelDescription =
      'Family chat messages — sender name + preview, with sound. '
      'Quieter than emergency alerts.';

  /// Localized channel name / description (v0.6.32).
  static String channelNameFor({bool isUrdu = false}) =>
      tr(isUrdu, 'core_chatChannelName');
  static String channelDescriptionFor({bool isUrdu = false}) =>
      tr(isUrdu, 'core_chatChannelDesc');

  /// Reads the persisted language choice once (SharedPreferences
  /// key `language_code_v1`, written by LanguageService). True
  /// when the user chose Urdu. Defaults to English on any failure.
  static Future<bool> isUrduPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('language_code_v1') == 'ur';
    } catch (_) {
      return false;
    }
  }

  /// Payload attached to every chat notification. Tapping it opens
  /// the app on the Chat tab.
  static const String tapPayload = 'chat';

  /// A preview is a preview: WhatsApp shows a short snippet, not
  /// a whole essay, and a long message must not flood the shade.
  static const int snippetMaxLength = 120;

  /// Title is the sender's name — the receiver knows WHO at a
  /// glance, before reading a word. v0.6.32: the empty-name
  /// fallback is localized via [isUrdu] (default English).
  static String titleFor(String senderName, {bool isUrdu = false}) =>
      senderName.isEmpty
          ? tr(isUrdu, 'core_alertFallbackName')
          : senderName;

  /// Short preview of the message text: whitespace collapsed, cut
  /// at [snippetMaxLength] with an ellipsis when longer.
  static String snippetFor(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return '';
    if (t.length <= snippetMaxLength) return t;
    return '${t.substring(0, snippetMaxLength).trimRight()}…';
  }

  /// Build the notification for one chat message.
  /// v0.6.32: pass [isUrdu] when the caller knows the locale, or
  /// use [fromMessageLocalized] to read the persisted choice.
  static ChatNotification fromMessage({
    required ChatMessage msg,
    required String circleId,
    bool isUrdu = false,
  }) {
    return ChatNotification(
      title: titleFor(msg.senderName, isUrdu: isUrdu),
      body: snippetFor(msg.text),
      circleId: circleId,
      messageId: msg.id,
      dedupeKey: dedupeKeyFor(msg.id),
    );
  }

  /// Same as [fromMessage] but reads the persisted language once
  /// from SharedPreferences, so the fallback sender name renders
  /// in the phone's chosen locale.
  static Future<ChatNotification> fromMessageLocalized({
    required ChatMessage msg,
    required String circleId,
  }) async =>
      fromMessage(
        msg: msg,
        circleId: circleId,
        isUrdu: await isUrduPersisted(),
      );

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
