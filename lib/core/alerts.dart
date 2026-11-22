/// The 14 alerts in ApnaCircle (agreed 21 Nov 2026).
/// Every alert has its OWN on/off switch, and changing any of them
/// requires the parent PIN (see PinService + AlertsScreen).
/// Remote control: the parent changes these on THEIR phone; the
/// values sync to the member's phone via the backend (Firebase
/// Realtime Database in production; local persistence in v0.1).
enum AlertType {
  sos,
  lowBattery,
  phoneOff,
  internetOff,
  arriveHome,
  leaveHome,
  fallElderly,
  longStay,
  noMovement,
  smsLocationWhenNetOff,
  shakeSos,
  loudSosOnSilent,
  autoCall1122,
  locationViewed,
}

extension AlertTypeInfo on AlertType {
  String get key => name;

  /// English label (Urdu lives in lib/l10n/app_ur.dart).
  String get labelEn {
    switch (this) {
      case AlertType.sos:
        return 'SOS';
      case AlertType.lowBattery:
        return 'Low battery';
      case AlertType.phoneOff:
        return 'Phone switched off';
      case AlertType.internetOff:
        return 'Internet switched off';
      case AlertType.arriveHome:
        return 'Arrived home / school';
      case AlertType.leaveHome:
        return 'Left home';
      case AlertType.fallElderly:
        return 'Fall alert (elderly)';
      case AlertType.longStay:
        return 'Stayed in one place too long';
      case AlertType.noMovement:
        return 'No movement';
      case AlertType.smsLocationWhenNetOff:
        return 'SMS location when net is off';
      case AlertType.shakeSos:
        return 'Shake phone for SOS';
      case AlertType.loudSosOnSilent:
        return 'SOS rings loud even on silent';
      case AlertType.autoCall1122:
        return 'Auto-call 1122 on SOS';
      case AlertType.locationViewed:
        return 'Someone viewed my location';
    }
  }

  /// Only the parent can turn this one on: it dials 1122.
  bool get needsExplicitOptIn => this == AlertType.autoCall1122;
}

/// Default state: safety alerts ON, the two intrusive ones OFF
/// until the parent explicitly turns them on.
Map<AlertType, bool> defaultAlertSettings() => {
      for (final a in AlertType.values)
        a: !(a == AlertType.autoCall1122 || a == AlertType.shakeSos),
    };
