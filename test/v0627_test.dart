import 'package:apnacircle/core/removal_detection.dart';
import 'package:apnacircle/models/circle.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/alert_history_service.dart';
import 'package:apnacircle/services/family_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.6.27 — "removed member comes back" fix.
///
/// The parent removed a member, but the member's phone kept
/// re-creating its node with blind location publishes (rules v2
/// let anyone write their own node), so within 60 seconds the
/// member was back in the circle and their alerts resumed.
/// Rules v5 close the server side; these tests cover the app
/// side: removal detection, the alerts-centre filter, and the
/// invite-code proof on the member node.
///
/// The RTDB rules themselves are JSON, not Dart — they are
/// verified by the console publish + the Simulator checks in
/// FIREBASE_SETUP.md §2, not here.
void main() {
  group('isPermissionDeniedError', () {
    test('permission-denied is a removal signal', () {
      expect(
        isPermissionDeniedError(
          FirebaseException(
            plugin: 'firebase_database',
            code: 'permission-denied',
          ),
        ),
        isTrue,
      );
    });

    test('other Firebase codes are not removal', () {
      expect(
        isPermissionDeniedError(
          FirebaseException(
            plugin: 'firebase_database',
            code: 'network-error',
          ),
        ),
        isFalse,
      );
      expect(
        isPermissionDeniedError(
          FirebaseException(
            plugin: 'firebase_database',
            code: 'disconnected',
          ),
        ),
        isFalse,
      );
    });

    test('a plain exception is not removal', () {
      expect(isPermissionDeniedError(Exception('boom')), isFalse);
      expect(isPermissionDeniedError('permission-denied'), isFalse);
    });
  });

  group('shouldTreatAsRemoved', () {
    test('node definitely gone means removed', () {
      expect(shouldTreatAsRemoved(memberNodeExists: false), isTrue);
    });

    test('node exists means keep sharing', () {
      expect(shouldTreatAsRemoved(memberNodeExists: true), isFalse);
    });

    test('check itself failed means keep sharing (fail open)', () {
      expect(shouldTreatAsRemoved(memberNodeExists: null), isFalse);
    });
  });

  group('filterAlertsToMembers', () {
    CircleEvent event(String uid, String type) => CircleEvent(
          type: type,
          fromUid: uid,
          fromName: uid,
          at: DateTime(2026, 11, 27, 17, 0),
        );

    test('empty member list returns everything (fail open)', () {
      final events = [event('a', 'sos'), event('c', 'sos')];
      expect(filterAlertsToMembers(events, {}), hasLength(2));
    });

    test('drops events from a removed member, keeps current ones', () {
      final events = [
        event('a', 'sos'),
        event('b', 'lowBattery'),
        event('removed-uid', 'sos'),
        event('removed-uid', 'internetOff'),
      ];
      final kept = filterAlertsToMembers(events, {'a', 'b'});
      expect(kept.map((e) => e.fromUid), ['a', 'b']);
      expect(
        kept.any((e) => e.fromUid == 'removed-uid'),
        isFalse,
      );
    });

    test('empty events stay empty', () {
      expect(filterAlertsToMembers([], {'a'}), isEmpty);
    });
  });

  group('Member inviteCode (rules v5 proof)', () {
    test('round-trips through JSON', () {
      const m = Member(
        id: 'u1',
        name: 'Ali',
        phone: '+923001234567',
        inviteCode: '660287',
      );
      final back = Member.fromJson(m.toJson());
      expect(back.inviteCode, '660287');
      expect(back.id, 'u1');
    });

    test('omitted from JSON when null', () {
      const m = Member(id: 'u1', name: 'Ali', phone: '+923001234567');
      expect(m.toJson().containsKey('inviteCode'), isFalse);
      expect(Member.fromJson(m.toJson()).inviteCode, isNull);
    });

    test('old nodes without the field parse fine', () {
      final back = Member.fromJson({
        'id': 'u1',
        'name': 'Ali',
        'phone': '+923001234567',
        'role': 'child',
      });
      expect(back.inviteCode, isNull);
      expect(back.role, 'child');
    });

    test('copyWith keeps the code unless replaced', () {
      const m = Member(
        id: 'u1',
        name: 'Ali',
        phone: '+923001234567',
        inviteCode: '660287',
      );
      expect(m.copyWith().inviteCode, '660287');
      expect(m.copyWith(inviteCode: '123456').inviteCode, '123456');
    });
  });

  group('FamilyService removedNotice', () {
    test('clearRemovedNotice clears it', () {
      final family = FamilyService();
      family.removedNotice = 'You were removed from the circle.';
      expect(family.removedNotice, isNotNull);
      family.clearRemovedNotice();
      expect(family.removedNotice, isNull);
    });
  });
}
