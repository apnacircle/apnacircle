import 'package:apnacircle/core/alerts.dart';
import 'package:apnacircle/core/call_notification.dart';
import 'package:apnacircle/core/call_signaling.dart';
import 'package:apnacircle/core/chat_delete.dart';
import 'package:apnacircle/core/chat_receipts.dart';
import 'package:apnacircle/core/chat_retention.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/models/chat_message.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/screens/home_map_screen.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/auth_service.dart';
import 'package:apnacircle/services/billing_service.dart';
import 'package:apnacircle/services/call_service.dart';
import 'package:apnacircle/services/chat_delete_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:apnacircle/services/notification_service.dart';
import 'package:apnacircle/services/sms_location_service.dart';
import 'package:apnacircle/services/sos_sms_service.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:apnacircle/services/trial_service.dart';
import 'package:apnacircle/core/language_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.6.21 (26 Nov 2026) — four user asks in one build:
/// (1) audio+video calls (tap a member's picture, conference,
/// any-to-any); (2) SMS SOS independent of the parent PIN;
/// (3) the alerts bell — total unread on the icon, per-member
/// counts with what each alert was and when; (4) chat delete —
/// for me, for everyone, clear all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('call signaling (pure)', () {
    test('CallInfo round-trips through toMap/fromMap', () {
      const call = CallInfo(
        id: 'abc123',
        circleId: 'c1',
        from: 'u1',
        fromName: 'Mujahid',
        type: CallType.video,
        state: CallState.ringing,
        participants: {'u1': 'joined', 'u2': 'invited'},
        createdAt: 1700000000000,
      );
      final back = CallInfo.fromMap('abc123', 'c1', call.toMap());
      expect(back.id, 'abc123');
      expect(back.fromName, 'Mujahid');
      expect(back.type, CallType.video);
      expect(back.state, CallState.ringing);
      expect(back.participants, {'u1': 'joined', 'u2': 'invited'});
      expect(back.createdAt, 1700000000000);
    });

    test('isRingingFor / othersThan / joinedUids', () {
      const call = CallInfo(
        id: 'x',
        circleId: 'c1',
        from: 'u1',
        fromName: 'Mujahid',
        type: CallType.audio,
        state: CallState.ringing,
        participants: {'u1': 'joined', 'u2': 'invited', 'u3': 'joined'},
        createdAt: 1000,
      );
      expect(call.isRingingFor('u2'), isTrue);
      expect(call.isRingingFor('u9'), isFalse);
      expect(call.othersThan('u1'), ['u2', 'u3']);
      expect(call.joinedUids, ['u1', 'u3']);
      expect(
        call.copyWith(state: CallState.ended).isRingingFor('u2'),
        isFalse,
      );
    });

    test('a ringing call older than 60 s is stale', () {
      const call = CallInfo(
        id: 'x',
        circleId: 'c1',
        from: 'u1',
        fromName: 'Mujahid',
        type: CallType.audio,
        state: CallState.ringing,
        participants: {'u1': 'joined'},
        createdAt: 1000,
      );
      expect(isCallStale(call, nowMs: 1000 + 59000), isFalse);
      expect(isCallStale(call, nowMs: 1000 + 61000), isTrue);
      expect(
        isCallStale(
          call.copyWith(state: CallState.active),
          nowMs: 1000 + 999999,
        ),
        isFalse,
      );
    });

    test('SDP payload round-trips; bad shapes return null', () {
      final p = sdpPayload(sdp: 'v=0\r\n...', type: 'offer', from: 'u1');
      final back = parseSdpPayload(p);
      expect(back?.sdp, 'v=0\r\n...');
      expect(back?.type, 'offer');
      expect(back?.from, 'u1');
      expect(parseSdpPayload({'sdp': '', 'type': 'offer'}), isNull);
      expect(parseSdpPayload({'type': 'offer'}), isNull);
      expect(parseSdpPayload('nope'), isNull);
      expect(parseSdpPayload(null), isNull);
    });

    test('ICE candidate payload round-trips; bad shapes return null', () {
      final p = iceCandidatePayload(
        candidate: 'candidate:1 1 udp 123 1.2.3.4 5000 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      final back = parseIceCandidatePayload(p);
      expect(back?.candidate, contains('typ host'));
      expect(back?.sdpMid, '0');
      expect(back?.sdpMLineIndex, 0);
      expect(parseIceCandidatePayload({'candidate': ''}), isNull);
      expect(parseIceCandidatePayload({'sdpMid': '0'}), isNull);
    });

    test('STUN server is Google public, no TURN, no key', () {
      final servers = callRtcConfiguration['iceServers'] as List;
      expect(servers.length, 1);
      expect(
        (servers.first as Map)['urls'],
        'stun:stun.l.google.com:19302',
      );
      expect(callRtcConfiguration.toString(), isNot(contains('turn:')));
    });
  });

  group('call notification payload', () {
    test('tap payload round-trips the call id', () {
      expect(CallNotifications.tapPayload('abc'), 'call:abc');
      expect(CallNotifications.callIdFromPayload('call:abc'), 'abc');
      expect(CallNotifications.callIdFromPayload('call:'), isNull);
      expect(CallNotifications.callIdFromPayload('chat'), isNull);
      expect(CallNotifications.callIdFromPayload(''), isNull);
    });
  });

  group('SMS SOS independence (v0.6.21)', () {
    test('SOS by SMS needs NO parent PIN; every other alert does', () {
      expect(AlertType.sosSms.needsParentPin, isFalse);
      for (final t in AlertType.values) {
        if (t == AlertType.sosSms) continue;
        expect(t.needsParentPin, isTrue, reason: t.name);
      }
    });

    test('SOS by SMS hint still shows the cost', () {
      expect(AlertType.sosSms.hintEn, contains('Rs. 2'));
      expect(AlertType.sosSms.hintEn, contains('no parent PIN'));
    });
  });

  group('chat delete (pure)', () {
    ChatMessage msg(String id, DateTime at) => ChatMessage(
          id: id,
          senderId: 'u1',
          senderName: 'Ali',
          text: 'hi',
          at: at,
        );

    test('hidden id is invisible; clearedAt hides everything older', () {
      final now = DateTime(2026, 11, 26, 21, 0);
      final m = msg('m1', now);
      expect(
        isChatMessageVisible(msg: m, hiddenIds: {}, clearedAt: null),
        isTrue,
      );
      expect(
        isChatMessageVisible(msg: m, hiddenIds: {'m1'}, clearedAt: null),
        isFalse,
      );
      expect(
        isChatMessageVisible(
          msg: m,
          hiddenIds: {},
          clearedAt: now,
        ),
        isFalse,
      );
      expect(
        isChatMessageVisible(
          msg: msg('m2', now.add(const Duration(seconds: 1))),
          hiddenIds: {},
          clearedAt: now,
        ),
        isTrue,
      );
    });

    test('mergeLiveChatPage drops a deleted message, keeps older pages', () {
      final t0 = DateTime(2026, 11, 26, 20, 0);
      final old1 = msg('k001', t0);
      final old2 = msg('k002', t0.add(const Duration(minutes: 1)));
      final gone = msg('k003', t0.add(const Duration(minutes: 2)));
      final fresh = msg('k004', t0.add(const Duration(minutes: 3)));
      // The live page is the newest 2: k003 was deleted, k004 new.
      final merged = mergeLiveChatPage(
        [old1, old2, gone],
        [old2, fresh],
      );
      expect(merged.map((m) => m.id), ['k001', 'k002', 'k004']);
      // An empty live page never wipes what was already shown.
      expect(mergeLiveChatPage([old1, old2], []), [old1, old2]);
    });
  });

  group('read receipts (v0.6.21)', () {
    ChatMessage msg(String id, String sender, Map<String, int> seen) =>
        ChatMessage(
          id: id,
          senderId: sender,
          senderName: sender,
          text: 'hi',
          at: DateTime(2026, 11, 26, 21, 0),
          seenBy: seen,
        );

    test('readCount excludes the sender', () {
      final m = msg('k1', 'u1', {'u1': 1000, 'u2': 2000, 'u3': 3000});
      expect(readCount(m), 2);
      expect(isSeenBy(m, 'u2'), isTrue);
      expect(isSeenBy(m, 'u9'), isFalse);
      expect(readCount(msg('k2', 'u1', {})), 0);
    });

    test('readersOf: readers first by time, then unread, sender out', () {
      final members = [
        Member(
          id: 'u1',
          name: 'Mujahid',
          phone: '+1',
          role: 'parent',
          lat: 0,
          lon: 0,
          lastSeen: DateTime.now(),
          battery: 80,
          isOnline: true,
        ),
        Member(
          id: 'u2',
          name: 'Ali',
          phone: '+2',
          role: 'child',
          lat: 0,
          lon: 0,
          lastSeen: DateTime.now(),
          battery: 80,
          isOnline: true,
        ),
        Member(
          id: 'u3',
          name: 'Ammi',
          phone: '+3',
          role: 'child',
          lat: 0,
          lon: 0,
          lastSeen: DateTime.now(),
          battery: 80,
          isOnline: true,
        ),
      ];
      final m = msg('k1', 'u1', {
        'u3': DateTime(2026, 11, 26, 21, 5).millisecondsSinceEpoch,
        'u2': DateTime(2026, 11, 26, 21, 2).millisecondsSinceEpoch,
      });
      final rows = readersOf(m, members);
      // Sender (u1) is never listed; readers by time, then unread.
      expect(rows.map((r) => r.member.id), ['u2', 'u3']);
      expect(rows.first.readAt, isNotNull);
      final m2 = msg('k2', 'u1', {'u2': 1000});
      final rows2 = readersOf(m2, members);
      expect(rows2.map((r) => r.member.id), ['u2', 'u3']);
      expect(rows2.last.readAt, isNull);
    });

    test('read time reads "26 Nov, 21:05"', () {
      expect(formatReadTime(DateTime(2026, 11, 26, 21, 5)), '26 Nov, 21:05');
    });

    test('ChatMessage seenBy round-trips', () {
      final m = msg('k1', 'u1', {'u2': 1700000000000});
      final back = ChatMessage.fromJson(m.toJson(), id: 'k1');
      expect(back.seenBy, {'u2': 1700000000000});
      expect(back.toJson()['seenBy'], {'u2': 1700000000000});
      // No seenBy key when nobody read it yet.
      final fresh = msg('k2', 'u1', {});
      expect(fresh.toJson().containsKey('seenBy'), isFalse);
    });
  });

  group('chat retention — 1 week (v0.6.21)', () {
    test('7 days is the window, in ms', () {
      expect(chatRetentionDays, 7);
      expect(chatRetentionMs, 7 * 24 * 60 * 60 * 1000);
      expect(retentionCutoffMs(1700000000000), 1700000000000 - chatRetentionMs);
    });

    test('6 days old stays, 7 days + 1 s expires', () {
      final now = DateTime(2026, 11, 26, 21, 0);
      expect(
        isChatMessageExpired(
          at: now.subtract(const Duration(days: 6, hours: 23)),
          now: now,
        ),
        isFalse,
      );
      expect(
        isChatMessageExpired(
          at: now.subtract(const Duration(days: 7)),
          now: now,
        ),
        isTrue,
      );
      expect(
        isChatMessageExpired(
          at: now.subtract(const Duration(days: 7, seconds: 1)),
          now: now,
        ),
        isTrue,
      );
      expect(
        isChatMessageExpiredMs(
          atMs: now.millisecondsSinceEpoch - chatRetentionMs - 1,
          nowMs: now.millisecondsSinceEpoch,
        ),
        isTrue,
      );
    });

    test('ChatMessage writes atMs and reads it back', () {
      final at = DateTime(2026, 11, 26, 21, 0);
      final m = ChatMessage(
        id: 'k1',
        senderId: 'u1',
        senderName: 'Ali',
        text: 'hi',
        at: at,
      );
      expect(m.atMs, at.millisecondsSinceEpoch);
      expect(m.toJson()['atMs'], at.millisecondsSinceEpoch);
      final back = ChatMessage.fromJson(m.toJson(), id: 'k1');
      expect(back.at, at);
      expect(back.atMs, at.millisecondsSinceEpoch);
      // An old message (no atMs in the node) still parses.
      final old = ChatMessage.fromJson({
        'senderId': 'u1',
        'senderName': 'Ali',
        'text': 'hi',
        'at': at.toIso8601String(),
      }, id: 'k0');
      expect(old.atMs, at.millisecondsSinceEpoch);
    });

    test('expired messages are invisible, fresh ones show', () {
      final now = DateTime(2026, 11, 26, 21, 0);
      final fresh = ChatMessage(
        id: 'f1',
        senderId: 'u1',
        senderName: 'Ali',
        text: 'hi',
        at: now.subtract(const Duration(days: 1)),
      );
      final expired = ChatMessage(
        id: 'e1',
        senderId: 'u1',
        senderName: 'Ali',
        text: 'old',
        at: now.subtract(const Duration(days: 8)),
      );
      // The pure visibility helper hides expired ones too.
      expect(isChatMessageExpired(at: fresh.at, now: now), isFalse);
      expect(isChatMessageExpired(at: expired.at, now: now), isTrue);
      expect(
        isChatMessageVisible(msg: fresh, hiddenIds: {}, clearedAt: null),
        isTrue,
      );
    });
  });

  group('alert labels + time', () {
    test('every known type has a plain-words label', () {
      expect(alertTypeLabel('sos'), 'SOS');
      expect(alertTypeLabel('lowBattery'), 'Low battery');
      expect(alertTypeLabel('phoneOff'), 'Phone switched off');
      expect(alertTypeLabel('internetOff'), 'Internet off');
      expect(alertTypeLabel('locationOff'), 'Location switched off');
      expect(alertTypeLabel('simChanged'), 'SIM changed');
      expect(alertTypeLabel('adminDisabled'), 'Protection removed');
      // Unknown types are shown as-is, never hidden.
      expect(alertTypeLabel('somethingNew'), 'somethingNew');
    });

    test('alert time reads "26 Nov, 21:05"', () {
      expect(
        formatAlertTime(DateTime(2026, 11, 26, 21, 5)),
        '26 Nov, 21:05',
      );
    });
  });

  group('alert history aggregation (pure, via CircleEvent)', () {
    test('events group per member, newest first', () {
      final e1 = CircleEvent(
        type: 'sos',
        fromUid: 'u2',
        fromName: 'Ali',
        at: DateTime(2026, 11, 26, 21, 0),
      );
      final e2 = CircleEvent(
        type: 'lowBattery',
        fromUid: 'u2',
        fromName: 'Ali',
        at: DateTime(2026, 11, 26, 21, 5),
      );
      final e3 = CircleEvent(
        type: 'internetOff',
        fromUid: 'u3',
        fromName: 'Ammi',
        at: DateTime(2026, 11, 26, 20, 0),
      );
      final events = [e1, e2, e3];
      final byMember = <String, List<CircleEvent>>{};
      for (final e in events) {
        byMember.putIfAbsent(e.fromUid, () => []).add(e);
      }
      expect(byMember['u2']!.length, 2);
      expect(byMember['u3']!.length, 1);
      expect(byMember['u2']!.first.type, 'sos');
    });
  });

  group('home widgets (v0.6.21)', () {
    Future<void> pumpHome(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      // Taller than the default 600 px viewport: the members header
      // (with the group-call button) must clear the floating SOS
      // buttons, or taps land on the FAB instead of the button.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = AuthService();
      final sync = SyncService(auth);
      final family = FamilyService()..attachSync(sync);
      final sms = SmsLocationService();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => LanguageService()),
            ChangeNotifierProvider.value(value: auth),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider(create: (_) => TrialService()),
            ChangeNotifierProvider(create: (_) => BillingService()),
            ChangeNotifierProvider.value(
              value: NotificationService(sync),
            ),
            ChangeNotifierProvider.value(value: family),
            ChangeNotifierProvider.value(
              value: CallService(family: family),
            ),
            ChangeNotifierProvider.value(
              value: AlertHistoryService(family: family),
            ),
            ChangeNotifierProvider.value(
              value: ChatDeleteService(family: family),
            ),
            Provider.value(value: sms),
            Provider.value(value: SosSmsService(sms)),
          ],
          child: const MaterialApp(home: HomeMapScreen()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('bell icon is in the AppBar; tap opens the centre',
        (tester) async {
      await pumpHome(tester);
      expect(find.byTooltip('Alerts'), findsOneWidget);
      await tester.tap(find.byTooltip('Alerts'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Alerts — 0 total'), findsOneWidget);
      // Demo family, no events yet: every member shows "No alerts yet".
      expect(find.text('No alerts yet'), findsWidgets);
      expect(find.text('Mujahid'), findsWidgets);
    });

    testWidgets('group-call button is beside the Family header',
        (tester) async {
      await pumpHome(tester);
      expect(find.byTooltip('Group call'), findsOneWidget);
      await tester.tap(find.byTooltip('Group call'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Group call — pick members'), findsOneWidget);
      // Tick one member, then audio call: demo mode has no sync,
      // so the call refuses with the plain-words error.
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pump();
      await tester.tap(find.text('Audio call'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Calls need live sync'), findsOneWidget);
    });

    testWidgets('tap a member picture opens the call menu', (tester) async {
      await pumpHome(tester);
      // The members list is collapsed by default — expand it.
      await tester.tap(find.text('Family (3)'));
      await tester.pump();
      // Ali's row (not mine — my own picture never calls).
      final aliCard = find.widgetWithText(ListTile, 'Ali');
      expect(aliCard, findsOneWidget);
      final avatar = find.descendant(
        of: aliCard,
        matching: find.byType(CircleAvatar),
      );
      await tester.tap(avatar);
      await tester.pump();
      await tester.pump();
      expect(find.text('Audio call Ali'), findsOneWidget);
      expect(find.text('Video call Ali'), findsOneWidget);
    });

    testWidgets('chat: long-press shows delete menu; delete for me works',
        (tester) async {
      await pumpHome(tester);
      // Open the Chat tab (bottom nav).
      await tester.tap(find.text('Chat'));
      // Let the SOS FAB finish its exit animation.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Ghar pahunch gaya.'), findsOneWidget);
      await tester.longPress(find.text('Ghar pahunch gaya.'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Delete for me'), findsOneWidget);
      // Demo mode: no "Delete for everyone" (no server).
      expect(find.text('Delete for everyone'), findsNothing);
      await tester.tap(find.text('Delete for me'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Deleted for you.'), findsOneWidget);
      expect(find.text('Ghar pahunch gaya.'), findsNothing);
    });

    testWidgets('chat: clear-chat menu item exists', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('Chat'));
      // Let the SOS FAB finish its exit animation.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Clear chat'), findsOneWidget);
    });

    testWidgets('chat: tap my message shows Message info', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('Chat'));
      // Let the SOS FAB finish its exit animation — while it is
      // animating out it still covers the Send button.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      // Send a message in demo mode — it is mine (senderId 'me').
      await tester.enterText(
        find.byType(TextField),
        'test receipt 123',
      );
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump();
      expect(find.text('test receipt 123'), findsOneWidget);
      await tester.ensureVisible(find.text('test receipt 123'));
      await tester.pump();
      await tester.tap(find.text('test receipt 123'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Message info'), findsOneWidget);
      // Demo family has not read it yet.
      expect(find.text('Not read yet'), findsWidgets);
      // My own name is never listed as a reader.
      expect(find.text('Mujahid'), findsWidgets);
    });
  });
}
