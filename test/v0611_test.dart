import 'package:apnacircle/core/alert_notification.dart';
import 'package:apnacircle/core/alerts.dart';
import 'package:apnacircle/core/chat_notification.dart';
import 'package:apnacircle/core/chat_paging.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Family chat notifications (v0.6.11).
///
/// User-reported 24 Nov 2026: in the family chat, when someone sent
/// a message nobody knew unless they opened the app. Like WhatsApp,
/// a message must appear OUTSIDE the app — sender's name + a short
/// preview + sound. Fix: a separate normal-importance chat channel
/// (never the loud SOS one), a live RTDB watch + an FCM push for
/// closed/background app, deduped by message id — with no ping for
/// my own messages or for the chat I am already looking at.
ChatMessage _msg({
  String id = 'm1',
  String senderId = 'uid-ali',
  String senderName = 'Ali',
  String text = 'Ghar pahunch gaya.',
}) =>
    ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      text: text,
      at: DateTime(2026, 11, 24, 11, 7),
    );

void main() {
  group('chat channel (v0.6.11)', () {
    test('channel id/name/payload are the chat ones', () {
      expect(ChatNotifications.channelId, 'apnacircle_chat');
      expect(ChatNotifications.channelName, 'ApnaCircle Chat');
      expect(ChatNotifications.tapPayload, 'chat');
    });

    test('chat channel is separate from the SOS alerts channel', () {
      expect(
        ChatNotifications.channelId,
        isNot(AlertNotifications.channelId),
      );
      expect(
        ChatNotifications.tapPayload,
        isNot(AlertNotifications.tapPayload),
      );
    });
  });

  group('title + preview (v0.6.11)', () {
    test('title is the sender name', () {
      final chat = ChatNotifications.fromMessage(
        msg: _msg(),
        circleId: 'apna-ghr',
      );
      expect(chat.title, 'Ali');
      expect(chat.body, 'Ghar pahunch gaya.');
      expect(chat.circleId, 'apna-ghr');
      expect(chat.messageId, 'm1');
    });

    test('empty sender name falls back to a family member', () {
      expect(ChatNotifications.titleFor(''), 'A family member');
    });

    test('short message is shown whole', () {
      expect(
        ChatNotifications.snippetFor('Ghar pahunch gaya.'),
        'Ghar pahunch gaya.',
      );
    });

    test('long message is cut at 120 chars with an ellipsis', () {
      final long = 'a' * 200;
      final snippet = ChatNotifications.snippetFor(long);
      expect(snippet.length, lessThanOrEqualTo(121));
      expect(snippet, endsWith('…'));
      expect(snippet, startsWith('a' * 120));
    });

    test('whitespace is collapsed, empty text has no preview', () {
      expect(
        ChatNotifications.snippetFor('  hello\n\n   world  '),
        'hello world',
      );
      expect(ChatNotifications.snippetFor('   '), isEmpty);
    });
  });

  group('per-circle notification ids (v0.6.11)', () {
    test('stable per circle, in the chat range', () {
      final a = ChatNotifications.notificationIdFor('apna-ghr');
      expect(a, ChatNotifications.notificationIdFor('apna-ghr'));
      expect(a, greaterThanOrEqualTo(2000));
      expect(a, lessThan(2900));
    });
  });

  group('FCM + RTDB dedupe (v0.6.11)', () {
    test('same message id shares one dedupe key on both paths', () {
      expect(
        ChatNotifications.dedupeKeyFor('m1'),
        ChatNotifications.dedupeKeyFor('m1'),
      );
      expect(
        ChatNotifications.dedupeKeyFor('m1'),
        isNot(ChatNotifications.dedupeKeyFor('m2')),
      );
    });

    test('one message rings once inside the window, again after it', () {
      var now = DateTime(2026, 11, 24, 11, 7);
      final dedupe = AlertDedupe(now: () => now);
      final key = ChatNotifications.dedupeKeyFor('m1');
      expect(dedupe.shouldShow(key), isTrue);
      expect(dedupe.shouldShow(key), isFalse);
      now = now.add(const Duration(seconds: 61));
      expect(dedupe.shouldShow(key), isTrue);
    });
  });

  group('suppression rules (v0.6.11)', () {
    test('my own message never notifies', () {
      expect(
        ChatNotifications.shouldNotify(
          msg: _msg(senderId: 'uid-me'),
          circleId: 'apna-ghr',
          myUid: 'uid-me',
        ),
        isFalse,
      );
    });

    test('another member message notifies', () {
      expect(
        ChatNotifications.shouldNotify(
          msg: _msg(),
          circleId: 'apna-ghr',
          myUid: 'uid-me',
        ),
        isTrue,
      );
    });

    test('no notification while looking at that circle chat', () {
      expect(
        ChatNotifications.shouldNotify(
          msg: _msg(),
          circleId: 'apna-ghr',
          myUid: 'uid-me',
          openChatCircleId: 'apna-ghr',
        ),
        isFalse,
      );
    });

    test('looking at another circle chat still notifies', () {
      expect(
        ChatNotifications.shouldNotify(
          msg: _msg(),
          circleId: 'apna-ghr',
          myUid: 'uid-me',
          openChatCircleId: 'other-circle',
        ),
        isTrue,
      );
    });

    test('empty message never notifies', () {
      expect(
        ChatNotifications.shouldNotify(
          msg: _msg(text: '   '),
          circleId: 'apna-ghr',
          myUid: 'uid-me',
        ),
        isFalse,
      );
    });
  });

  group('FamilyService chat watch (v0.6.11)', () {
    late _FakeChatSync sync;
    late FamilyService family;
    late List<ChatMessage> emitted;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      sync = _FakeChatSync();
      family = FamilyService()..attachSync(sync);
      emitted = [];
      family.newChatMessages.listen(emitted.add);
      await family.load();
    });

    test('first page is history: old messages do not ring', () async {
      sync.chatCallback!([_msg(id: 'm1'), _msg(id: 'm2')]);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
    });

    test('a new message from another member is emitted', () async {
      sync.chatCallback!([_msg(id: 'm1')]);
      await Future<void>.delayed(Duration.zero);
      sync.chatCallback!([
        _msg(id: 'm1'),
        _msg(id: 'm2', senderName: 'Mehvish'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.map((m) => m.id), ['m2']);
      expect(emitted.single.senderName, 'Mehvish');
    });

    test('my own new message is not emitted', () async {
      sync.chatCallback!([_msg(id: 'm1')]);
      await Future<void>.delayed(Duration.zero);
      sync.chatCallback!([
        _msg(id: 'm1'),
        _msg(id: 'm9', senderId: 'u1', senderName: 'Me'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
    });
  });
}

/// Minimal fake SyncService: stubs every subscription FamilyService
/// makes, capturing the chat callback so the watch can be driven.
class _FakeChatSync extends SyncService {
  _FakeChatSync() : super(AuthService());

  @override
  bool get isAvailable => true;

  @override
  String? get uid => 'u1';

  @override
  String? get activeCircleId => 'c1';

  void Function(List<ChatMessage>)? chatCallback;

  @override
  void subscribeMembers(
    String circleId,
    void Function(List<Member>) onData,
  ) {}

  @override
  void subscribeAlerts(
    String circleId,
    String memberId,
    void Function(Map<AlertType, bool>) onData,
  ) {}

  @override
  void subscribeEvents(
    String circleId,
    void Function(CircleEvent) onData,
  ) {}

  @override
  void subscribeChat(
    String circleId,
    void Function(List<ChatMessage>) onData, {
    int limit = chatPageSize,
  }) {
    chatCallback = onData;
  }
}
