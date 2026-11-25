import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/protection_level.dart';
import 'device_admin_service.dart';

/// Device Owner — the only way on Android to make the app truly
/// non-uninstallable from Settings (v0.6.13, 25 Nov 2026).
///
/// The user order: a child must NOT be able to delete the app on
/// her own will — uninstall needs the parent's permission. Device
/// Admin (v0.5) only forces a deactivation step + alert; a device
/// owner app has NO working uninstall in Settings at all.
///
/// HOW IT WORKS (one-time setup, parent-driven):
/// 1. The parent opens Settings → "Uninstall protection (Device
///    Owner)" on their own phone (PIN-gated) and fills the APK
///    download URL (+ optional Wi-Fi) — the screen shows a QR code.
/// 2. The child's phone is factory-reset (or brand new) → setup
///    wizard → tap 6 times on the welcome screen → scan the QR.
///    Android downloads the APK from the URL, verifies the
///    signature checksum in the QR, installs it and makes it the
///    device owner.
/// 3. From then on the child cannot uninstall from Settings. The
///    parent removes it only from inside the app (PIN-gated
///    clearDeviceOwnerApp) or by a recovery-mode factory reset.
///
/// HONEST LIMITS (also in README + on the setup screen — do not
/// hide them):
/// * Needs a factory reset once (or a fresh phone). It CANNOT be
///   done on an already-set-up phone without a reset: Android
///   refuses device-owner provisioning once accounts exist
///   (`adb set-device-owner` fails the same way).
/// * A recovery-mode factory reset still wipes the phone — no app
///   can stop that. Google FRP still applies.
/// * The checksum in the QR is the SHA-256 of the signing
///   certificate of the APK at the download URL. CI builds are
///   debug-signed with a FRESH key per run, so the QR must be
///   generated from the SAME build as the APK at the URL (the
///   setup screen computes the checksum from the app installed on
///   the parent's phone — use that phone's build at the URL).
/// * Play Store will need a justification for device-owner use at
///   submission (family-safety / parental control).
class DeviceOwnerService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.deviceOwnerChannel);

  /// The admin receiver component, flattened as the provisioning
  /// wizard expects it: "<package>/<fully-qualified receiver>".
  static const String adminComponentName =
      'com.apnacircle.app/com.apnacircle.app.ApnaCircleDeviceAdminReceiver';

  /// SharedPreferences key for the cached protection level (read by
  /// the background task, which cannot call the platform channels).
  static const String cachedLevelKey = 'protection_level_v1';

  /// Build the managed-provisioning QR payload. Pure — unit-tested.
  /// [downloadLocation] is the public URL of the exact APK build
  /// whose signing checksum is [checksum] (base64 SHA-256 of the
  /// signing certificate — from [signingChecksum], never typed by
  /// hand). Wi-Fi is optional: without it the child phone must
  /// join Wi-Fi by hand during setup.
  static String buildQrPayload({
    required String downloadLocation,
    required String checksum,
    String? wifiSsid,
    String? wifiPassword,
    String? wifiSecurityType,
  }) {
    final payload = <String, Object>{
      'android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_NAME':
          'com.apnacircle.app',
      'android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME':
          adminComponentName,
      'android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION':
          downloadLocation,
      'android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM':
          checksum,
      // The child's phone is wiped for setup anyway; skipping the
      // encryption step keeps the one-time setup short.
      'android.app.extra.PROVISIONING_SKIP_ENCRYPTION': true,
    };
    if (wifiSsid != null && wifiSsid.isNotEmpty) {
      payload['android.app.extra.PROVISIONING_WIFI_SSID'] = wifiSsid;
      if (wifiPassword != null && wifiPassword.isNotEmpty) {
        payload['android.app.extra.PROVISIONING_WIFI_PASSWORD'] =
            wifiPassword;
      }
      payload['android.app.extra.PROVISIONING_WIFI_SECURITY_TYPE'] =
          wifiSecurityType ?? 'WPA';
    }
    return jsonEncode(payload);
  }

  /// Parent-side removal gate (pure — unit-tested). The gate is
  /// the PARENT PIN, not the role: anyone who knows the parent's
  /// code may remove the protection — the parent holding the
  /// child's phone, or the parent on their own phone — and nobody
  /// without the code may, whatever their role. That is both
  /// directions of the user's order (25 Nov 2026): the child
  /// cannot remove it (no code), the parent always can (his code
  /// always works — he is never locked out of his own phone).
  /// [pinVerified] must come from [verifyPinAgainstHash] against
  /// the parent PIN hash, never from a role check alone.
  static bool canClearDeviceOwner({
    required bool pinVerified,
    required bool isDeviceOwner,
  }) =>
      pinVerified && isDeviceOwner;

  /// Remove ALL uninstall protection from THIS phone, for the
  /// parent who entered their code: clear the device owner when
  /// it is the owner, and deactivate the device admin when it is
  /// active. After this returns true the app CAN be uninstalled
  /// from Settings — that is the parent-controlled removal path.
  /// Returns false when any removal step failed (protection may
  /// still be partly on — the UI re-reads the real statuses).
  /// The PIN check itself lives in the UI ([askParentPin] with the
  /// parent hash); this method never asks for a code.
  Future<bool> removeAllProtection() async {
    var ok = true;
    try {
      if (await isDeviceOwner()) {
        ok = await clearDeviceOwner() && ok;
      }
    } catch (_) {
      ok = false;
    }
    try {
      if (await DeviceAdminService().isAdminActive()) {
        ok = await DeviceAdminService().removeAdmin() && ok;
      }
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  /// True when THIS phone's app is the device owner.
  Future<bool> isDeviceOwner() async {
    try {
      return await _channel.invokeMethod<bool>('isDeviceOwner') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Base64 SHA-256 of THIS installed app's signing certificate —
  /// the value the QR checksum must carry. Null when it cannot be
  /// read (the setup screen then refuses to show a QR rather than
  /// showing a wrong one).
  Future<String?> signingChecksum() async {
    try {
      return await _channel.invokeMethod<String>('getSigningChecksum');
    } on PlatformException {
      return null;
    }
  }

  /// Remove device-owner status from THIS phone (parent only,
  /// PIN-gated in the UI). The app stays installed, but the child
  /// can uninstall it again afterwards — that is the point of the
  /// parent-controlled removal path. False when it was not the
  /// owner or the call failed.
  Future<bool> clearDeviceOwner() async {
    try {
      return await _channel.invokeMethod<bool>('clearDeviceOwner') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// The protection level of THIS phone right now: owner, admin,
  /// or none. Unknown only when the platform calls fail.
  Future<ProtectionLevel> currentLevel() async {
    try {
      if (await isDeviceOwner()) return ProtectionLevel.owner;
      if (await DeviceAdminService().isAdminActive()) {
        return ProtectionLevel.admin;
      }
      return ProtectionLevel.none;
    } catch (_) {
      return ProtectionLevel.unknown;
    }
  }

  /// The last level the main isolate computed (written by
  /// [cacheLevel]). The background task reads this — it cannot
  /// call the platform channels from its isolate.
  static Future<ProtectionLevel> cachedLevel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ProtectionLevel.fromWire(prefs.getString(cachedLevelKey));
    } catch (_) {
      return ProtectionLevel.unknown;
    }
  }

  /// Compute the level now and cache it for the background task.
  /// Call on app start, on resume, and after any admin/owner
  /// change. Best effort — never throws.
  Future<void> cacheLevel() async {
    try {
      final level = await currentLevel();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cachedLevelKey, level.wireValue);
    } catch (_) {
      // Protection label only — must never break startup.
    }
  }
}
