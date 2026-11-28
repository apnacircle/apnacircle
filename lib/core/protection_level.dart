import '../l10n/strings.dart';

/// Uninstall-protection level of one phone (v0.6.13, 25 Nov 2026).
///
/// The user order (25 Nov 2026): a child must NOT be able to delete
/// the app on her own will — uninstall needs the parent's
/// permission. The protection level is published with the member
/// node so the parent sees at a glance which child can uninstall
/// and which cannot.
///
/// Levels, strongest first:
/// * [owner] — the app is the device owner (one-time QR setup on a
///   fresh / factory-reset phone). Android itself refuses uninstall:
///   Settings shows no working uninstall for a device-owner app.
///   Only the parent can remove it (PIN-gated clearDeviceOwnerApp
///   inside the app) or a recovery-mode factory reset (no app can
///   stop that — honest limit, stated in README + in-app).
/// * [admin] — Device Admin is active (v0.5). Android refuses
///   uninstall until the admin is deactivated first; deactivation
///   fires an immediate alert to the parent (v0.6.13).
/// * [none] — no protection: the child can uninstall freely.
/// * [unknown] — older app version that does not publish the level,
///   or it could not be read. Shown as nothing (never guessed).
enum ProtectionLevel {
  unknown,
  none,
  admin,
  owner;

  /// Wire value stored on the member node (`protection`).
  String get wireValue => name;

  /// Short label for the parent's member row. Empty for unknown —
  /// the row shows nothing rather than a guess.
  String get label => switch (this) {
        ProtectionLevel.owner => 'Protected',
        ProtectionLevel.admin => 'Admin only',
        ProtectionLevel.none => 'Not protected',
        ProtectionLevel.unknown => '',
      };

  /// Localized label (v0.6.32). [label] is kept as the English
  /// source; pass isUrdu: true for the Urdu-script label. Empty
  /// for unknown, as before.
  String localizedLabel({bool isUrdu = false}) => switch (this) {
        ProtectionLevel.owner => tr(isUrdu, 'core_protectionProtected'),
        ProtectionLevel.admin => tr(isUrdu, 'core_protectionAdminOnly'),
        ProtectionLevel.none => tr(isUrdu, 'core_protectionNotProtected'),
        ProtectionLevel.unknown => '',
      };

  static ProtectionLevel fromWire(String? value) =>
      ProtectionLevel.values.firstWhere(
        (e) => e.name == value,
        orElse: () => ProtectionLevel.unknown,
      );
}

/// Pure mapping from the two device facts to a level — unit-tested.
/// Device owner wins over admin (an owner phone is also an admin,
/// but only "owner" describes what it can do).
ProtectionLevel protectionLevelFrom({
  required bool isDeviceOwner,
  required bool isAdminActive,
}) {
  if (isDeviceOwner) return ProtectionLevel.owner;
  if (isAdminActive) return ProtectionLevel.admin;
  return ProtectionLevel.none;
}

/// "Child gayab" warning (v0.6.13, part D).
///
/// A child member whose last location update is older than
/// [missingWarningAfter] gets a clear in-app warning on the parent's
/// Map screen — the app may have been deleted, or the phone is off
/// or has no data. Local computation from synced member data only:
/// no new server field, no loud notification (no-data is common —
/// a loud alert for every offline stretch would spam the parent
/// with false alarms). The existing "Offline since [time]" text
/// stays exactly as it is.
const Duration missingWarningAfter = Duration(hours: 2);

/// True when this member should carry the missing warning: a CHILD
/// (only children are protected members — a parent going quiet is
/// not an escape) who is not online and whose last seen time is
/// older than [missingWarningAfter]. A missing timestamp never
/// warns (never accuse on no data).
bool shouldShowMissingWarning({
  required String role,
  required bool isOnline,
  required DateTime? lastSeen,
  required DateTime now,
}) {
  if (role != 'child') return false;
  if (isOnline) return false;
  if (lastSeen == null) return false;
  return now.difference(lastSeen) > missingWarningAfter;
}

/// The warning line, with the real staleness in it ("2 ghante se
/// koi update nahi"). Pure — unit-tested. v0.6.32: localized via
/// [isUrdu] (default English, as before); singular/plural via
/// trf with {hours}.
String missingWarningText(DateTime lastSeen, DateTime now,
    {bool isUrdu = false}) {
  final hours = now.difference(lastSeen).inHours;
  if (hours == 1) return tr(isUrdu, 'core_missingWarningOne');
  return trf(isUrdu, 'core_missingWarningMany', {'hours': hours});
}
