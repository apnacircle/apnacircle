import '../l10n/strings.dart';

/// The 15 alerts in ApnaCircle (agreed 21 Nov 2026; SOS by SMS
/// added 26 Nov 2026).
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
  sosSms,
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
      case AlertType.sosSms:
        return 'SOS by SMS';
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

  /// Localized label (v0.6.32). [labelEn] is kept as the English
  /// source; pass isUrdu: true for the Urdu-script label. The SOS
  /// label reuses the existing `sos` key (EN/UR both 'SOS').
  String label({bool isUrdu = false}) {
    switch (this) {
      case AlertType.sos:
        return tr(isUrdu, 'sos');
      case AlertType.lowBattery:
        return tr(isUrdu, 'core_alertLowBattery');
      case AlertType.phoneOff:
        return tr(isUrdu, 'core_alertPhoneOff');
      case AlertType.internetOff:
        return tr(isUrdu, 'core_alertInternetOff');
      case AlertType.arriveHome:
        return tr(isUrdu, 'core_alertArriveHome');
      case AlertType.leaveHome:
        return tr(isUrdu, 'core_alertLeaveHome');
      case AlertType.fallElderly:
        return tr(isUrdu, 'core_alertFallElderly');
      case AlertType.longStay:
        return tr(isUrdu, 'core_alertLongStay');
      case AlertType.noMovement:
        return tr(isUrdu, 'core_alertNoMovement');
      case AlertType.smsLocationWhenNetOff:
        return tr(isUrdu, 'core_alertSmsLocation');
      case AlertType.sosSms:
        return tr(isUrdu, 'core_alertSosSms');
      case AlertType.shakeSos:
        return tr(isUrdu, 'core_alertShakeSos');
      case AlertType.loudSosOnSilent:
        return tr(isUrdu, 'core_alertLoudSos');
      case AlertType.autoCall1122:
        return tr(isUrdu, 'core_alertAutoCall1122');
      case AlertType.locationViewed:
        return tr(isUrdu, 'core_alertLocationViewed');
    }
  }

  /// Only the parent can turn this one on: it dials 1122.
  bool get needsExplicitOptIn => this == AlertType.autoCall1122;

  /// v0.6.21: does changing this switch need the parent PIN?
  /// Every alert EXCEPT SOS by SMS: yes — a child cannot change
  /// alerts from their own phone. SOS by SMS is the exception the
  /// user ordered (26 Nov 2026): trouble can come to any child at
  /// any time, and they must be able to turn the SMS alert on
  /// THEMSELVES, without waiting for the admin's permission —
  /// otherwise they cannot send an alert at all. The confirm
  /// dialog (with the cost) still guards every send.
  bool get needsParentPin => this != AlertType.sosSms;

  /// Localized small print (v0.6.32). [hintEn] is kept as the
  /// English source; pass isUrdu: true for the Urdu-script hint.
  String? hint({bool isUrdu = false}) {
    switch (this) {
      case AlertType.autoCall1122:
        return tr(isUrdu, 'core_alertHintAutoCall');
      case AlertType.sosSms:
        return tr(isUrdu, 'core_alertHintSosSms');
      default:
        return null;
    }
  }

  /// Small print under the switch, or null for plain alerts.
  /// SOS by SMS costs the sender's mobile balance, so the price
  /// is shown right where the switch is.
  String? get hintEn {
    switch (this) {
      case AlertType.autoCall1122:
        return 'Needs explicit parent opt-in (dials 1122).';
      case AlertType.sosSms:
        return 'Costs about Rs. 2 per member SMS — the sender pays. Anyone in the family can turn this on — no parent PIN needed.';
      default:
        return null;
    }
  }
}

/// Default state: safety alerts ON, the intrusive or costly ones
/// OFF until the parent explicitly turns them on. SOS by SMS is
/// OFF by default because every SOS press then costs the sender
/// about Rs. 2 per member SMS — nobody pays without choosing to.
Map<AlertType, bool> defaultAlertSettings() => {
      for (final a in AlertType.values)
        a: !(a == AlertType.autoCall1122 ||
            a == AlertType.shakeSos ||
            a == AlertType.sosSms),
    };
