import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_lock_service.dart';
import '../core/call_distance_service.dart';
import '../core/location_service.dart';
import '../l10n/strings.dart';
import '../services/device_admin_service.dart';
import '../services/sms_location_service.dart';

/// One-time guided setup (v0.6.19).
///
/// User problem (26 Nov 2026): installing the app on a child's
/// phone means allowing permissions "from everywhere" — location,
/// notifications, SMS, overlay, Accessibility, Device Admin — and
/// a parent who is not technical cannot be expected to know where
/// each one lives in Settings. The user asked for an automatic
/// system; the honest limit is that Android FORBIDS any app from
/// granting its own permissions — every one of these needs the
/// phone's owner to tap once in a system dialog or settings page,
/// and no app can bypass that. So instead of automatic, setup is
/// GUIDED: one screen, one step per permission, each with a single
/// big button that opens exactly the right settings page. The
/// parent taps through, the app ticks each step off as it is done,
/// and nothing needs to be understood.
///
/// The wizard shows once, right after the PIN is set, and can be
/// skipped ("Skip for now" — it never nags again, and it stays
/// available from Settings → "Setup — permissions"). It also shows
/// the steps that are already done, so a parent can see at a
/// glance what is still missing on this phone.
///
/// Steps (in the order a parent meets them on a child's phone):
/// * Location "Allow all the time" — REQUIRED: without it the
///   family cannot see the child when the app is closed. Android
///   11+ can only grant this from the app's Settings page, never
///   from a dialog (the rationale + settings flow is shared with
///   HomeMapScreen._fixLocationSharing).
/// * Notifications — REQUIRED on Android 13+: without it the
///   phone shows no SOS/alert notifications at all.
/// * SMS — for offline location + SMS SOS; the phone sends SMS
///   from its own balance.
/// * Display over other apps — for the SIM-call distance overlay.
/// * Accessibility — for App Lock. Sideloaded APKs additionally
///   need "Allow restricted settings" first (that detour vanishes
///   once the app is on the Play Store).
/// * Device Admin — for uninstall protection (one system tap).
/// * Battery optimization exemption — so the phone does not kill
///   the background location service.
enum SetupStep {
  locationAlways,
  notifications,
  sms,
  overlay,
  accessibility,
  deviceAdmin,
  battery,
}

extension SetupStepInfo on SetupStep {
  String get title {
    switch (this) {
      case SetupStep.locationAlways:
        return 'Location — Allow all the time';
      case SetupStep.notifications:
        return 'Notifications';
      case SetupStep.sms:
        return 'SMS permission';
      case SetupStep.overlay:
        return 'Display over other apps';
      case SetupStep.accessibility:
        return 'Accessibility — App Lock';
      case SetupStep.deviceAdmin:
        return 'Device Admin — uninstall protection';
      case SetupStep.battery:
        return 'Ignore battery optimization';
    }
  }

  /// Plain words: why this phone needs it.
  String get why {
    switch (this) {
      case SetupStep.locationAlways:
        return 'So your family can see this phone even when the app is closed.';
      case SetupStep.notifications:
        return 'So SOS and safety alerts can ring on this phone.';
      case SetupStep.sms:
        return 'So location still reaches your family by SMS when there is no internet, and SMS SOS can be sent.';
      case SetupStep.overlay:
        return 'So the caller\'s distance shows on top during a SIM call.';
      case SetupStep.accessibility:
        return 'So App Lock can lock apps on this phone. (Needs "Allow restricted settings" first on a sideloaded app.)';
      case SetupStep.deviceAdmin:
        return 'So the app cannot be uninstalled without the parent PIN.';
      case SetupStep.battery:
        return 'So the phone does not stop location sharing in the background to save battery.';
    }
  }

  /// The two without which the app cannot do its job at all.
  bool get isRequired {
    switch (this) {
      case SetupStep.locationAlways:
      case SetupStep.notifications:
        return true;
      default:
        return false;
    }
  }

  /// Localized [title] / [why] / [actionLabel]. The plain getters
  /// stay (English, for existing call sites); screens that know
  /// the locale call these instead.
  String titleIn(bool isUrdu) {
    if (!isUrdu) return title;
    return switch (this) {
      SetupStep.locationAlways => tr(true, 'svc_setupLocationTitle'),
      SetupStep.notifications => tr(true, 'svc_setupNotificationsTitle'),
      SetupStep.sms => tr(true, 'svc_setupSmsTitle'),
      SetupStep.overlay => tr(true, 'svc_setupOverlayTitle'),
      SetupStep.accessibility => tr(true, 'svc_setupAccessibilityTitle'),
      SetupStep.deviceAdmin => tr(true, 'svc_setupDeviceAdminTitle'),
      SetupStep.battery => tr(true, 'svc_setupBatteryTitle'),
    };
  }

  String whyIn(bool isUrdu) {
    if (!isUrdu) return why;
    return switch (this) {
      SetupStep.locationAlways => tr(true, 'svc_setupWhyLocation'),
      SetupStep.notifications => tr(true, 'svc_setupWhyNotifications'),
      SetupStep.sms => tr(true, 'svc_setupWhySms'),
      SetupStep.overlay => tr(true, 'svc_setupWhyOverlay'),
      SetupStep.accessibility => tr(true, 'svc_setupWhyAccessibility'),
      SetupStep.deviceAdmin => tr(true, 'svc_setupWhyDeviceAdmin'),
      SetupStep.battery => tr(true, 'svc_setupWhyBattery'),
    };
  }

  String actionLabelIn(bool isUrdu) {
    if (!isUrdu) return actionLabel;
    return switch (this) {
      SetupStep.locationAlways => tr(true, 'svc_setupAllowLocation'),
      SetupStep.notifications => tr(true, 'svc_setupAllowNotifications'),
      SetupStep.sms => tr(true, 'svc_setupAllowSms'),
      SetupStep.overlay => tr(true, 'svc_setupOpenSettings'),
      SetupStep.accessibility => tr(true, 'svc_setupOpenSettings'),
      SetupStep.deviceAdmin => tr(true, 'svc_setupActivate'),
      SetupStep.battery => tr(true, 'svc_setupAllow'),
    };
  }

  /// Label on the step's action button.
  String get actionLabel {
    switch (this) {
      case SetupStep.locationAlways:
        return 'Allow location';
      case SetupStep.notifications:
        return 'Allow notifications';
      case SetupStep.sms:
        return 'Allow SMS';
      case SetupStep.overlay:
        return 'Open settings';
      case SetupStep.accessibility:
        return 'Open settings';
      case SetupStep.deviceAdmin:
        return 'Activate';
      case SetupStep.battery:
        return 'Allow';
    }
  }
}

/// Opens the app's own Settings page (App info) — the manual route
/// to the battery exemption.
///
/// v0.6.22: on Oppo/ColorOS (and on any phone after one denial)
/// the exemption dialog never appears again — tapping "Allow" in
/// the wizard then does nothing, no matter how often it is tapped.
/// The only route left is the manual one the user was told in
/// chat: Settings → Apps → ApnaCircle → Battery → "Unrestricted".
/// This opens exactly that App info page, so the user never has
/// to hunt for it. Returns false when the page could not be
/// opened (never a crash).
Future<bool> openBatterySettings() async {
  try {
    return await ph.openAppSettings();
  } catch (_) {
    return false;
  }
}

/// Live status of one setup step on THIS phone.
Future<bool> isSetupStepDone(SetupStep step) async {
  try {
    switch (step) {
      case SetupStep.locationAlways:
        return await LocationService().sharingState() ==
            LocationSharingState.always;
      case SetupStep.notifications:
        return await ph.Permission.notification.status.isGranted;
      case SetupStep.sms:
        return await ph.Permission.sms.status.isGranted;
      case SetupStep.overlay:
        return await CallDistanceService.canDrawOverlays();
      case SetupStep.accessibility:
        return await AppLockService.isServiceEnabled();
      case SetupStep.deviceAdmin:
        return await DeviceAdminService().isAdminActive();
      case SetupStep.battery:
        return await ph.Permission.ignoreBatteryOptimizations.status.isGranted;
    }
  } catch (_) {
    return false;
  }
}

/// Runs the step's action (request dialog or settings page).
/// Returns nothing — the caller re-checks the status afterwards
/// (the user may have said no, and the tick only appears when the
/// permission is really granted). For location "Allow all the time"
/// the plain-words reason is shown FIRST (Play Store rule — the
/// same rationale as HomeMapScreen._fixLocationSharing), because
/// Android 11+ can only grant it from the app's Settings page.
Future<void> runSetupStepAction(
  BuildContext context,
  SetupStep step, {
  bool isUrdu = false,
}) async {
  try {
    switch (step) {
      case SetupStep.locationAlways:
        final loc = LocationService();
        final state = await loc.sharingState();
        if (state == LocationSharingState.off) {
          await loc.ensureWhileInUse();
        } else if (state == LocationSharingState.whileInUse) {
          if (!context.mounted) return;
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(tr(isUrdu, 'svc_setupShareLocationTitle')),
              content: Text(tr(isUrdu, 'svc_setupShareLocationBody')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr(isUrdu, 'svc_setupNotNow')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr(isUrdu, 'svc_setupOpenSettings')),
                ),
              ],
            ),
          );
          if (go == true && context.mounted) await loc.openAppSettings();
        }
      case SetupStep.notifications:
        await LocationService().ensureNotificationPermission();
      case SetupStep.sms:
        await SmsLocationService().ensureSmsPermission();
      case SetupStep.overlay:
        await CallDistanceService.openOverlaySettings();
      case SetupStep.accessibility:
        await AppLockService.openAccessibilitySettings();
      case SetupStep.deviceAdmin:
        await DeviceAdminService().requestAdmin();
      case SetupStep.battery:
        await LocationService().requestBatteryOptimizationExemption();
    }
  } catch (_) {
    // A failed request is just a step left undone — never a crash.
  }
}

/// Remembers whether the one-time setup was finished or skipped.
/// The wizard never shows again on its own after that; it stays
/// reachable from Settings → "Setup — permissions".
class SetupService extends ChangeNotifier {
  static const _completeKey = 'setup_complete_v1';

  bool _isComplete = false;
  bool get isComplete => _isComplete;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _isComplete = prefs.getBool(_completeKey) ?? false;
  }

  Future<void> markComplete() async {
    _isComplete = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_completeKey, true);
  }
}
