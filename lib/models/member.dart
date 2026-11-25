import '../core/alerts.dart';
import '../core/protection_level.dart';

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

  /// When this battery level was published (v0.6.6). Null =
  /// written by an older app version that did not stamp it.
  final DateTime? batteryAt;
  final bool isOnline;
  final bool locationSharingOn;

  /// Uninstall-protection level of this member's phone (v0.6.13):
  /// owner = cannot be uninstalled from Settings, admin = uninstall
  /// needs deactivation first (+ parent alert), none = can be
  /// uninstalled freely. Unknown = older app version that does not
  /// publish it yet — the UI shows nothing rather than guessing.
  final ProtectionLevel protection;
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
    this.batteryAt,
    this.isOnline = false,
    this.locationSharingOn = true,
    this.locationViaSms = false,
    this.protection = ProtectionLevel.unknown,
    Map<AlertType, bool>? alerts,
  }) : alerts = alerts ?? const {};

  bool get hasLocation => lat != null && lon != null;
  bool get isParent => role == 'parent';
  bool get isElderly => role == 'elderly';

  /// True only for a real level (0–100). The battery plugin returns
  /// -1 when it cannot read a level — that sentinel must never be
  /// shown to the user as "-1%" (v0.6.2).
  bool get hasKnownBattery => battery >= 0 && battery <= 100;

  /// Display text for the battery, or empty when unknown.
  String get batteryLabel => hasKnownBattery ? 'Battery $battery%' : '';

  /// True when the shown battery level is older than 30 minutes
  /// (v0.6.6) — the row marks it "(old)" so a stale value is never
  /// mistaken for a live one. A missing timestamp (older app
  /// versions) is never called stale.
  bool get batteryIsStale =>
      batteryAt != null &&
      DateTime.now().difference(batteryAt!) >
          const Duration(minutes: 30);

  Member copyWith({
    String? phone,
    double? lat,
    double? lon,
    DateTime? lastSeen,
    int? battery,
    DateTime? batteryAt,
    bool? isOnline,
    bool? locationSharingOn,
    bool? locationViaSms,
    ProtectionLevel? protection,
    Map<AlertType, bool>? alerts,
  }) =>
      Member(
        id: id,
        name: name,
        phone: phone ?? this.phone,
        role: role,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        lastSeen: lastSeen ?? this.lastSeen,
        battery: battery ?? this.battery,
        batteryAt: batteryAt ?? this.batteryAt,
        isOnline: isOnline ?? this.isOnline,
        locationSharingOn: locationSharingOn ?? this.locationSharingOn,
        locationViaSms: locationViaSms ?? this.locationViaSms,
        protection: protection ?? this.protection,
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
        'batteryAt': batteryAt?.toIso8601String(),
        'isOnline': isOnline,
        'locationSharingOn': locationSharingOn,
        'locationViaSms': locationViaSms,
        'protection': protection.wireValue,
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
        batteryAt: j['batteryAt'] == null
            ? null
            : DateTime.parse(j['batteryAt'] as String),
        isOnline: j['isOnline'] as bool? ?? false,
        locationSharingOn: j['locationSharingOn'] as bool? ?? true,
        locationViaSms: j['locationViaSms'] as bool? ?? false,
        protection:
            ProtectionLevel.fromWire(j['protection'] as String?),
        alerts: {
          for (final e in (j['alerts'] as Map? ?? {}).entries)
            AlertType.values.firstWhere(
              (a) => a.name == e.key,
              orElse: () => AlertType.sos,
            ): e.value as bool,
        },
      );
}
