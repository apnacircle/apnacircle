/// A family circle (v0.3, 22 Nov 2026).
///
/// One person can be a MEMBER in one circle and ADMIN (parent) of
/// other circles — the role is PER CIRCLE, not per account. A circle
/// is created by a parent, who shares a 6-digit invite code; the
/// child joins with that code. Each circle has its own members,
/// PIN hash (so a parent who loses their phone recovers the PIN by
/// signing in on a new phone), locks and alerts.
///
/// Storage: Firebase Realtime Database (see SyncService). All of
/// this is plain data — no Firebase import here, so it stays
/// unit-testable without a Firebase project.
class CircleInfo {
  final String id;
  final String name;
  final String role; // 'parent' | 'child' | 'elderly' | 'member'
  final String inviteCode; // 6 digits, e.g. '482913'
  final DateTime? createdAt;

  const CircleInfo({
    required this.id,
    required this.name,
    this.role = 'parent',
    this.inviteCode = '',
    this.createdAt,
  });

  bool get isAdmin => role == 'parent';

  CircleInfo copyWith({String? name, String? role, String? inviteCode}) =>
      CircleInfo(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        inviteCode: inviteCode ?? this.inviteCode,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'inviteCode': inviteCode,
        'createdAt': createdAt?.toIso8601String(),
      };

  factory CircleInfo.fromJson(Map<String, dynamic> j) => CircleInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Family',
        role: j['role'] as String? ?? 'member',
        inviteCode: j['inviteCode'] as String? ?? '',
        createdAt: j['createdAt'] == null
            ? null
            : DateTime.parse(j['createdAt'] as String),
      );
}

/// A circle event pushed to the parent (SOS, battery-low, phone-off).
/// Written to `circles/{id}/events/` in RTDB; the parent's phone
/// listens to that node. FCM push for the same events needs a server
/// / Cloud Function (see NotificationService) — RTDB events are the
/// in-app delivery channel that works with no server at all.
class CircleEvent {
  final String type; // 'sos' | 'lowBattery' | 'phoneOff' | 'internetOff' | 'locationOff'
  final String fromUid;
  final String fromName;
  final DateTime at;
  final double? lat;
  final double? lon;

  const CircleEvent({
    required this.type,
    required this.fromUid,
    required this.fromName,
    required this.at,
    this.lat,
    this.lon,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'fromUid': fromUid,
        'fromName': fromName,
        'at': at.toIso8601String(),
        'lat': lat,
        'lon': lon,
      };

  factory CircleEvent.fromJson(Map<String, dynamic> j) => CircleEvent(
        type: j['type'] as String,
        fromUid: j['fromUid'] as String? ?? '',
        fromName: j['fromName'] as String? ?? '',
        at: j['at'] == null
            ? DateTime.now()
            : DateTime.parse(j['at'] as String),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
      );
}
