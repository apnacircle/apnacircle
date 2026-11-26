import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';
import 'sms_location_service.dart';

/// Result of one SOS-by-SMS attempt.
class SosSmsResult {
  /// Members who actually got the SMS.
  final int sent;

  /// Members who had a number and should have got one (excl. sender).
  final int recipients;

  /// Members skipped because no mobile number is saved for them.
  final int withoutNumber;

  /// True when the phone refused the SMS permission.
  final bool permissionDenied;

  /// True when the batch was skipped because a successful batch
  /// went out less than [SosSmsService.resendInterval] ago.
  final bool throttled;

  const SosSmsResult({
    required this.sent,
    required this.recipients,
    required this.withoutNumber,
    this.permissionDenied = false,
    this.throttled = false,
  });

  bool get anySent => sent > 0;
}

/// SOS by SMS (v0.6.18).
///
/// User requirement (26 Nov 2026): an emergency alert must reach
/// the WHOLE family whether the app is open or closed. The RTDB
/// event only reaches open apps, and the FCM push that would reach
/// closed apps needs the Cloud Functions — which need Blaze billing,
/// and Google has now refused THREE billing setups with
/// [OR_BACR2_31] on two different cards (26 Nov 2026). So SOS also
/// goes by SMS: one text to every other member's saved mobile
/// number, sent from the SOS sender's own phone. SMS needs only
/// mobile signal — no internet, no server, no billing.
///
/// Rules:
/// * Recipients are ALL other members of the same circle with a
///   saved mobile number — never anyone outside the circle, never
///   the sender themself.
/// * The SMS costs the SENDER's mobile balance (about Rs. 2 per SMS
///   without a bundle in Pakistan, ~free inside a monthly SMS
///   bundle) — one SMS per member per press, so a press to a
///   5-member family costs ~Rs. 10 without a bundle. Receiving
///   the SMS is free.
/// * A successful batch is throttled for 60 seconds, so an
///   accidental double-tap does not send (and charge) twice. A
///   FAILED batch is never throttled — the user can press again
///   immediately.
/// * SMS permission (SEND_SMS) is requested first, with the OS
///   dialog; the caller must have explained WHY before this runs.
///   Without it, nothing is sent and [SosSmsResult.permissionDenied]
///   is true.
///
/// Honest limits (also in README):
/// * SMS needs mobile signal + balance. No signal = no SMS.
/// * Members with no saved number cannot get the SMS (they joined
///   before v0.6.14, or the parent never set their number).
/// * If the SOS sender's phone is switched OFF, nothing can be
///   sent until it is back on.
class SosSmsService {
  /// SMS body prefix — family phones can recognise the alert.
  static const String smsPrefix = 'APNACIRCLE SOS:';

  /// After a SUCCESSFUL batch, wait this long before another
  /// batch may go out (accidental double-tap protection).
  static const Duration resendInterval = Duration(seconds: 60);

  static const _lastSuccessKey = 'sos_sms_last_success_ms';

  final SmsLocationService _sms;

  SosSmsService(this._sms);

  /// Build the SMS body. With a location it carries a Maps link
  /// so the family can tap straight to the sender; without one it
  /// says so plainly instead of faking a location.
  static String buildSosSms({
    required String fromName,
    double? lat,
    double? lon,
  }) {
    if (lat != null && lon != null) {
      return '$smsPrefix $fromName needs help! Location: '
          'https://maps.google.com/?q=$lat,$lon';
    }
    return '$smsPrefix $fromName needs help! (No location available.)';
  }

  /// Everyone who should get the SMS: all members except the
  /// sender, who have a mobile number saved.
  static List<Member> recipientsFor({
    required List<Member> members,
    required String senderId,
  }) =>
      members
          .where((m) => m.id != senderId && m.phone.trim().isNotEmpty)
          .toList();

  /// Members (except the sender) who would be skipped because no
  /// mobile number is saved for them.
  static int countWithoutNumber({
    required List<Member> members,
    required String senderId,
  }) =>
      members
          .where((m) => m.id != senderId && m.phone.trim().isEmpty)
          .length;

  /// Pure throttle rule (unit-tested): a batch may go out when no
  /// successful batch was ever sent, or when [resendInterval] has
  /// passed since the last successful one.
  static bool shouldSend({
    required DateTime? lastSuccessAt,
    required DateTime now,
  }) {
    if (lastSuccessAt == null) return true;
    return now.difference(lastSuccessAt) >= resendInterval;
  }

  /// Send the SOS SMS to the whole family. Returns how many
  /// members got it. Safe to call on every SOS press — the
  /// throttle, the permission check and the empty-recipients
  /// case are all handled inside.
  Future<SosSmsResult> sendSosSms({
    required String fromName,
    required List<Member> members,
    required String senderId,
    double? lat,
    double? lon,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final recipients = recipientsFor(members: members, senderId: senderId);
    final withoutNumber =
        countWithoutNumber(members: members, senderId: senderId);
    if (recipients.isEmpty) {
      return SosSmsResult(
        sent: 0,
        recipients: 0,
        withoutNumber: withoutNumber,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastSuccessKey);
    final lastSuccess = lastMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastMs);
    if (!shouldSend(lastSuccessAt: lastSuccess, now: at)) {
      return SosSmsResult(
        sent: 0,
        recipients: recipients.length,
        withoutNumber: withoutNumber,
        throttled: true,
      );
    }
    if (!await _sms.ensureSmsPermission()) {
      return SosSmsResult(
        sent: 0,
        recipients: recipients.length,
        withoutNumber: withoutNumber,
        permissionDenied: true,
      );
    }
    final body = buildSosSms(fromName: fromName, lat: lat, lon: lon);
    var sent = 0;
    for (final m in recipients) {
      if (await _sms.sendRawSms(to: m.phone, body: body)) sent++;
    }
    if (sent > 0) {
      await prefs.setInt(_lastSuccessKey, at.millisecondsSinceEpoch);
    }
    return SosSmsResult(
      sent: sent,
      recipients: recipients.length,
      withoutNumber: withoutNumber,
    );
  }
}
