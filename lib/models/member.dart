import '../core/alerts.dart';

/// One family member. Location is shared ONLY with consent:
/// the member joined the circle and left sharing on.
class Member {
  final String id;
  final String name;
  final String phone; // E.164-ish, e.g. +92300XXXXXXX — used to match SIM calls
  final String role; // 'parent' | 'child' | 'elderly' | 'member'
  final double? lat;
  final double? lon;
  final DateTime? lastSeen;
  final int battery; // 0-100, -1 = unknown
  final bool isOnline;
  final bool locationSharingOn;
  final Map<AlertType, bool> alerts;

  /// True when this member's shown location arrived by SMS while
  /// their phone was offline (v0.3). The map labels it "SMS se
  /// aayi" with the SMS time — it is a 15-minute snapshot, not live.
  final bool locationViaSms;

  const Member({
    required this.id,
    required this.name,
    required this.phone,
    this.role = 'member',
    this.lat,
    this.lon,
    this.lastSeen,
    this.battery = -1,
    this.isOnline = false,
    this.locationSharingOn = true,
    this.locationViaSms = false,
    Map<AlertType, bool>? alerts,
  }) : alerts = alerts ?? const {};

  bool get hasLocation => lat != null && lon != null;
  bool get isParent => role == 'parent';
  bool get isElderly => role == 'elderly';

  Member copyWith({
    double? lat,
    double? lon,
    DateTime? lastSeen,
    int? battery,
    bool? isOnline,
    bool? locationSharingOn,
    bool? locationViaSms,
    Map<AlertType, bool>? alerts,
  }) =>
      Member(
        id: id,
        name: name,
        phone: phone,
        role: role,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        lastSeen: lastSeen ?? this.lastSeen,
        battery: battery ?? this.battery,
        isOnline: isOnline ?? this.isOnline,
        locationSharingOn: locationSharingOn ?? this.locationSharingOn,
        locationViaSms: locationViaSms ?? this.locationViaSms,
        alerts: alerts ?? this.alerts,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'role': role,
        'lat': lat,
        'lon': lon,
        'lastSeen': lastSeen?.toIso8601String(),
        'battery': battery,
        'isOnline': isOnline,
        'locationSharingOn': locationSharingOn,
        'locationViaSms': locationViaSms,
        'alerts': {for (final e in alerts.entries) e.key.name: e.value},
      };

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String,
        role: j['role'] as String? ?? 'member',
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        lastSeen: j['lastSeen'] == null
            ? null
            : DateTime.parse(j['lastSeen'] as String),
        battery: j['battery'] as int? ?? -1,
        isOnline: j['isOnline'] as bool? ?? false,
        locationSharingOn: j['locationSharingOn'] as bool? ?? true,
        locationViaSms: j['locationViaSms'] as bool? ?? false,
        alerts: {
          for (final e in (j['alerts'] as Map? ?? {}).entries)
            AlertType.values.firstWhere(
              (a) => a.name == e.key,
              orElse: () => AlertType.sos,
            ): e.value as bool,
        },
      );
}
