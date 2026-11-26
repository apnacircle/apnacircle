import 'package:apnacircle/core/alerts.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/sos_sms_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// SOS by SMS, as a SEPARATE button (v0.6.18).
///
/// User requirement (26 Nov 2026): an emergency alert must reach
/// the WHOLE family whether the app is open or closed. The RTDB
/// event only reaches open apps, and the FCM push that would reach
/// closed apps needs the Cloud Functions — blocked on Blaze billing
/// (Google refused 3 setups with OR_BACR2_31 on 2 cards). So SOS
/// can also go by SMS to every other member's saved mobile number.
///
/// Design, decided with the user (26 Nov 2026):
/// * "SOS by SMS" is an alert toggle on the Alerts screen — OFF by
///   default, changeable only with the parent PIN. OFF = no SMS
///   ever goes out, no cost ever.
/// * The normal SOS button NEVER sends SMS (free, as before).
/// * A SEPARATE orange "SMS SOS" button sits above the SOS button
///   and shows ONLY when the toggle is ON. Pressing it asks first
///   (confirm dialog with the cost) — for a real emergency only.
Member _member(String id, String phone) => Member(
      id: id,
      name: id,
      phone: phone,
      lat: 0,
      lon: 0,
      battery: 100,
    );

void main() {
  group('SOS by SMS toggle (v0.6.18)', () {
    test('the toggle exists, is labelled, and is OFF by default', () {
      expect(AlertType.sosSms.labelEn, 'SOS by SMS');
      expect(defaultAlertSettings()[AlertType.sosSms], isFalse);
    });

    test('the toggle warns about the cost right where it sits', () {
      expect(AlertType.sosSms.hintEn, contains('Rs. 2'));
      expect(AlertType.sosSms.hintEn, contains('sender pays'));
    });

    test('a member with no saved flag has the toggle OFF', () {
      // Missing key = OFF (fail-closed: nobody pays without
      // choosing to). Members who joined before this version
      // have no sosSms key at all.
      final m = _member('me', '+923001111111');
      expect(m.alerts[AlertType.sosSms] ?? false, isFalse);
    });
  });

  group('SOS SMS body (v0.6.18)', () {
    test('starts with the SOS prefix, names the sender, links the map', () {
      final body = SosSmsService.buildSosSms(
        fromName: 'Mehvish',
        lat: 31.5204,
        lon: 74.3587,
      );
      expect(body, startsWith('APNACIRCLE SOS:'));
      expect(body, contains('Mehvish'));
      expect(body, contains('https://maps.google.com/?q=31.5204,74.3587'));
    });

    test('without a location it says so instead of faking one', () {
      final body = SosSmsService.buildSosSms(fromName: 'Ali');
      expect(body, contains('Ali'));
      expect(body, contains('No location'));
      expect(body, isNot(contains('maps.google.com')));
    });

    test('a typical message fits in one SMS segment', () {
      final body = SosSmsService.buildSosSms(
        fromName: 'Mujahid',
        lat: 31.5204,
        lon: 74.3587,
      );
      expect(body.length, lessThanOrEqualTo(160));
    });
  });

  group('SOS SMS recipients (v0.6.18)', () {
    final members = [
      _member('me', '+923001111111'),
      _member('ali', '+923002222222'),
      _member('ammi', '+923003333333'),
      _member('no-number', ''),
    ];

    test('everyone except the sender, only with a number saved', () {
      final to = SosSmsService.recipientsFor(
        members: members,
        senderId: 'me',
      );
      expect(to.map((m) => m.id), ['ali', 'ammi']);
    });

    test('members without a number are counted, not texted', () {
      expect(
        SosSmsService.countWithoutNumber(
          members: members,
          senderId: 'me',
        ),
        1,
      );
    });

    test('no recipients when only the sender has a number', () {
      expect(
        SosSmsService.recipientsFor(
          members: [_member('me', '+923001111111'), _member('x', '')],
          senderId: 'me',
        ),
        isEmpty,
      );
    });
  });

  group('SOS SMS throttle (v0.6.18)', () {
    test('first batch always allowed', () {
      expect(
        SosSmsService.shouldSend(
          lastSuccessAt: null,
          now: DateTime(2026, 11, 26, 15, 0),
        ),
        isTrue,
      );
    });

    test('a successful batch blocks a repeat within 60 seconds', () {
      expect(
        SosSmsService.shouldSend(
          lastSuccessAt: DateTime(2026, 11, 26, 15, 0, 0),
          now: DateTime(2026, 11, 26, 15, 0, 30),
        ),
        isFalse,
      );
    });

    test('a repeat after 60 seconds is allowed', () {
      expect(
        SosSmsService.shouldSend(
          lastSuccessAt: DateTime(2026, 11, 26, 15, 0, 0),
          now: DateTime(2026, 11, 26, 15, 1, 0),
        ),
        isTrue,
      );
    });
  });
}
