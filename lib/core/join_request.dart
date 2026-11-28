/// A child's request to join a circle (v0.6.30).
///
/// The child enters the invite code + their mobile + the PARENT's
/// PIN. Nothing is joined yet: a `pending` request node is written
/// under the circle, the parent sees it instantly (live sync) and
/// taps Allow or Deny. Only after Allow does the child's phone run
/// the normal join (member node + role entry) itself.
///
/// Security, by construction:
/// * The child NEVER reads the circle before approval — the request
///   node is the only thing they can write/read, and it carries
///   only the HASH of the PIN they typed (pinHashAttempt), never
///   the PIN itself. The parent's phone compares that hash with
///   the real one and auto-denies a wrong code.
/// * The child can never approve their own request: the rules only
///   let the parent (info/createdBy) set status approved/denied;
///   a self-write must keep status 'pending' (see
///   database.rules.json, rules v7).
/// * A returning member (role entry already exists) skips the
///   request entirely and re-joins directly.
enum JoinRequestStatus { pending, approved, denied }

JoinRequestStatus joinRequestStatusFromString(String? raw) => switch (raw) {
      'approved' => JoinRequestStatus.approved,
      'denied' => JoinRequestStatus.denied,
      _ => JoinRequestStatus.pending,
    };

/// Denial reasons the child sees in plain words.
class JoinDenyReason {
  /// The parent tapped Deny.
  static const parentDenied = 'parent_denied';

  /// The parent's phone auto-denied: the PIN the child typed did
  /// not match the circle's real parent PIN.
  static const wrongCode = 'wrong_code';
}

class JoinRequest {
  final String circleId;
  final String uid;
  final String name;
  final String phone;
  final String inviteCode;

  /// SHA-256 of the parent PIN the child typed
  /// ("apnacircle:<pin>") — never the PIN itself.
  final String pinHashAttempt;
  final int requestedAtMs;
  final JoinRequestStatus status;
  final String? reason;
  final int? decidedAtMs;

  const JoinRequest({
    required this.circleId,
    required this.uid,
    required this.name,
    required this.phone,
    required this.inviteCode,
    required this.pinHashAttempt,
    required this.requestedAtMs,
    this.status = JoinRequestStatus.pending,
    this.reason,
    this.decidedAtMs,
  });

  Map<String, dynamic> toMap() => {
        'inviteCode': inviteCode,
        'name': name,
        'phone': phone,
        'pinHashAttempt': pinHashAttempt,
        'requestedAtMs': requestedAtMs,
        'status': status.name,
        if (reason != null) 'reason': reason,
        if (decidedAtMs != null) 'decidedAtMs': decidedAtMs,
      };

  static JoinRequest? fromMap(
    String circleId,
    String uid,
    Object? raw,
  ) {
    if (raw is! Map) return null;
    final inviteCode = raw['inviteCode'];
    final name = raw['name'];
    final phone = raw['phone'];
    final pinHashAttempt = raw['pinHashAttempt'];
    final requestedAtMs = raw['requestedAtMs'];
    if (inviteCode is! String ||
        name is! String ||
        phone is! String ||
        pinHashAttempt is! String ||
        requestedAtMs is! int) {
      return null;
    }
    final reason = raw['reason'];
    final decidedAtMs = raw['decidedAtMs'];
    return JoinRequest(
      circleId: circleId,
      uid: uid,
      name: name,
      phone: phone,
      inviteCode: inviteCode,
      pinHashAttempt: pinHashAttempt,
      requestedAtMs: requestedAtMs,
      status: joinRequestStatusFromString(raw['status'] as String?),
      reason: reason is String ? reason : null,
      decidedAtMs: decidedAtMs is int ? decidedAtMs : null,
    );
  }
}
