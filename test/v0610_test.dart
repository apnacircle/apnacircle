import 'package:apnacircle/core/alert_notification.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loud emergency alert notifications (v0.6.10).
///
/// User-reported 24 Nov 2026: an SOS/alert only showed as a silent
/// red banner INSIDE the app after someone opened it — no sound, no
/// notification outside the app. For an emergency that is useless:
/// alerts must ring like a call. Fix: a dedicated high-importance
/// channel with sound + vibration, SOS with a full-screen intent,
/// and the in-app RTDB event rings loud too — with a 60 s dedupe so
/// the same alert arriving over FCM + RTDB rings once, not twice.
void main() {
  group('alert channel (v0.6.10)', () {
    test('channel id/name are the ones the manifest points FCM at', () {
      expect(AlertNotifications.channelId, 'apnacircle_alerts');
      expect(AlertNotifications.channelName, 'ApnaCircle Alerts');
      expect(AlertNotifications.tapPayload, 'alerts');
    });
  });

  group('SOS vs other alerts (v0.6.10)', () {
    test('only sos is a full-screen alert', () {
      expect(AlertNotifications.isSos('sos'), isTrue);
      for (final t in [
        'lowBattery',
        'phoneOff',
        'internetOff',
        'locationOff',
        'simChanged',
        'adminDisabled',
        'alert',
      ]) {
        expect(AlertNotifications.isSos(t), isFalse, reason: t);
      }
    });

    test('SOS title and body name the sender', () {
      final alert = AlertNotifications.fromEvent(
        type: 'sos',
        fromUid: 'uid-1',
        fromName: 'Mehvish',
        now: DateTime(2026, 11, 24, 10, 0),
      );
      expect(alert.isSos, isTrue);
      expect(alert.title, contains('Mehvish'));
      expect(alert.body, contains('Mehvish'));
      expect(alert.body, contains('SOS'));
    });

    test('non-SOS alerts name the sender too', () {
      expect(
        AlertNotifications.titleFor('lowBattery', 'Ali'),
        contains('Ali'),
      );
      expect(
        AlertNotifications.bodyFor('phoneOff', 'Ali'),
        contains('Ali'),
      );
      expect(
        AlertNotifications.titleFor('unknownType', 'Ali'),
        contains('Ali'),
      );
    });

    test('empty sender name falls back to "A family member"', () {
      final alert = AlertNotifications.fromEvent(
        type: 'sos',
        fromUid: 'uid-1',
        fromName: '',
        now: DateTime(2026, 11, 24, 10, 0),
      );
      expect(alert.title, contains('A family member'));
    });

    test('notification ids are stable per type (repeats update, not stack)',
        () {
      expect(
        AlertNotifications.notificationIdFor('sos'),
        AlertNotifications.notificationIdFor('sos'),
      );
      expect(
        AlertNotifications.notificationIdFor('sos'),
        isNot(AlertNotifications.notificationIdFor('lowBattery')),
      );
    });
  });

  group('60-second dedupe (v0.6.10)', () {
    test('same alert rings once inside the window, again after it', () {
      var now = DateTime(2026, 11, 24, 10, 0, 0);
      final dedupe = AlertDedupe(now: () => now);
      expect(dedupe.shouldShow('event:sos:uid-1'), isTrue);
      expect(dedupe.shouldShow('event:sos:uid-1'), isFalse);
      now = now.add(const Duration(seconds: 59));
      expect(dedupe.shouldShow('event:sos:uid-1'), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(dedupe.shouldShow('event:sos:uid-1'), isTrue);
    });

    test('different alerts are independent', () {
      final dedupe = AlertDedupe();
      expect(dedupe.shouldShow('event:sos:uid-1'), isTrue);
      expect(dedupe.shouldShow('event:lowBattery:uid-1'), isTrue);
      expect(dedupe.shouldShow('event:sos:uid-2'), isTrue);
    });

    test('FCM and RTDB paths share one key for the same alert', () {
      // The Cloud Function sends the event over FCM while the RTDB
      // stream delivers it in-app within seconds. Both paths build
      // minuteKey(type, fromUid, now) — same minute, same key, one ring.
      final at = DateTime(2026, 11, 24, 10, 0, 30);
      final fcmKey =
          AlertNotifications.minuteKey('sos', 'uid-1', at);
      final rtdbKey =
          AlertNotifications.minuteKey('sos', 'uid-1', at);
      expect(fcmKey, rtdbKey);

      var now = at;
      final dedupe = AlertDedupe(now: () => now);
      expect(dedupe.shouldShow(fcmKey), isTrue);
      // RTDB delivery 5 seconds later: suppressed.
      now = at.add(const Duration(seconds: 5));
      expect(dedupe.shouldShow(rtdbKey), isFalse);
    });

    test('minuteKey changes in a new minute (a repeat SOS still rings)',
        () {
      final k1 = AlertNotifications.minuteKey(
          'sos', 'uid-1', DateTime(2026, 11, 24, 10, 0, 30));
      final k2 = AlertNotifications.minuteKey(
          'sos', 'uid-1', DateTime(2026, 11, 24, 10, 1, 5));
      expect(k1, isNot(k2));
    });
  });
}
