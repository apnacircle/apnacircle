import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../l10n/strings.dart';
import '../models/circle.dart';
import 'auth_service.dart';
import 'sync_service.dart';

/// Device Admin — uninstall protection (v0.5, 23 Nov 2026).
///
/// HONEST LIMIT, stated in the UI too: on modern Android NO app
/// can truly BLOCK its own uninstall. What Device Admin does:
/// Android refuses to uninstall the app while it is a device
/// admin, so a child must first deactivate the admin in Settings
/// — and deactivating fires the receiver, which stores a pending
/// alert that Dart publishes to the circle so the parent sees it.
/// The protection is the extra step + the alert, not a lock.
///
/// v0.6.13 closes the hole in that alert: the receiver now writes
/// the pending flag into the FlutterSharedPreferences file, so the
/// background location task (running every 60 s while the app is
/// still installed) publishes the `adminDisabled` event within a
/// minute — the parent no longer depends on the child reopening
/// the app after deactivating. The next-app-start publish below
/// stays as the backup for phones where the background task is not
/// running. Truly non-uninstallable needs Device Owner instead
/// (see DeviceOwnerService).
///
/// Enabling is always the user's own tap on Android's system
/// screen (MainActivity fires ACTION_ADD_DEVICE_ADMIN); the app
/// never enables admin silently.
class DeviceAdminService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.deviceAdminChannel);

  /// True when ApnaCircle is currently a device admin.
  Future<bool> isAdminActive() async {
    try {
      return await _channel.invokeMethod<bool>('isAdminActive') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Android's system "activate device admin" screen.
  /// Returns immediately — the user decides there.
  Future<void> requestAdmin() async {
    try {
      await _channel.invokeMethod<void>('requestAdmin');
    } on PlatformException {
      // Nothing to do — the Settings screen re-checks status.
    }
  }

  /// Remove this app as device admin (parent only, PIN-gated in UI).
  Future<bool> removeAdmin() async {
    try {
      return await _channel.invokeMethod<bool>('removeAdmin') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// SharedPreferences key for the pending admin-deactivation
  /// alert (v0.6.13). The receiver writes the deactivation time
  /// here — into the FlutterSharedPreferences file, so BOTH the
  /// main isolate (next app start) AND the background location
  /// task (every 60 s cycle, while the app is still installed)
  /// can see it. The native "apnacircle_admin" flag is kept only
  /// as a fallback for flags left by pre-v0.6.13 builds.
  static const String pendingDisabledPrefsKey =
      'apnacircle_admin_disabled_at';

  /// Epoch ms when admin was deactivated (pending alert left by
  /// the receiver), or null when there is no pending alert.
  /// Reads the shared-prefs key the receiver writes (v0.6.13),
  /// falling back to the old native flag.
  Future<int?> pendingAdminDisabledAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final at = prefs.getInt(pendingDisabledPrefsKey);
      if (at != null) return at;
    } catch (_) {
      // Fall through to the native flag below.
    }
    try {
      return await _channel.invokeMethod<int>('getPendingAdminDisabled');
    } on PlatformException {
      return null;
    }
  }

  Future<void> clearPendingAdminDisabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pendingDisabledPrefsKey);
    } catch (_) {
      // Best effort only.
    }
    try {
      await _channel.invokeMethod<void>('clearPendingAdminDisabled');
    } on PlatformException {
      // Best effort only.
    }
  }

  /// Publish a pending admin-deactivation alert (left by the
  /// receiver when a child turned Device Admin off) to every
  /// circle, then clear it. Run once at app start. No-op when
  /// there is no pending alert or nobody is signed in.
  ///
  /// OFFLINE RULE (v0.6.13 refinement): the flag is claimed
  /// (removed) ONLY after the write succeeds. With no network the
  /// write cannot land now, so the flag SURVIVES for a later
  /// retry — it is never lost. The write is bounded by a 15 s
  /// timeout (the RTDB SDK queues offline writes, so a timed-out
  /// write may still land later AND a retry may send it again —
  /// the parent's phone dedupes identical adminDisabled events).
  /// Availability is checked BEFORE touching the flag: an
  /// unclaimed flag survives for the background task to pick up.
  Future<void> publishPendingAlertIfAny({
    required SyncService sync,
    required AuthService auth,
  }) async {
    if (!sync.isAvailable || auth.uid == null) return;
    final atMs = await pendingAdminDisabledAt();
    if (atMs == null) return;
    // v0.6.32: the sender-name fallback renders in the phone's
    // chosen locale (persisted language — no Provider here).
    final isUrdu = (await SharedPreferences.getInstance())
            .getString('language_code_v1') ==
        'ur';
    final name = auth.displayName ??
        auth.phoneNumber ??
        auth.email ??
        tr(isUrdu, 'svc_meName');
    var published = false;
    for (final circle in sync.myCircles) {
      try {
        await sync
            .sendEvent(
              circle.id,
              CircleEvent(
                type: 'adminDisabled',
                fromUid: auth.uid!,
                fromName: name,
                at: DateTime.fromMillisecondsSinceEpoch(atMs),
              ),
            )
            .timeout(const Duration(seconds: 15));
        published = true;
      } catch (_) {
        // Offline (timeout) or failed — the flag survives below
        // for the background task / next start to retry.
      }
    }
    if (published) await clearPendingAdminDisabled();
  }
}
