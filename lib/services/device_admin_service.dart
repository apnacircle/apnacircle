import 'package:flutter/services.dart';

import '../core/constants.dart';
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

  /// Epoch ms when admin was deactivated (pending alert left by the
  /// receiver), or null when there is no pending alert.
  Future<int?> pendingAdminDisabledAt() async {
    try {
      return await _channel.invokeMethod<int>('getPendingAdminDisabled');
    } on PlatformException {
      return null;
    }
  }

  Future<void> clearPendingAdminDisabled() async {
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
  Future<void> publishPendingAlertIfAny({
    required SyncService sync,
    required AuthService auth,
  }) async {
    final atMs = await pendingAdminDisabledAt();
    if (atMs == null) return;
    await clearPendingAdminDisabled();
    if (!sync.isAvailable || auth.uid == null) return;
    final name = auth.displayName ?? auth.phoneNumber ?? auth.email ?? 'Me';
    for (final circle in sync.myCircles) {
      await sync.sendEvent(
        circle.id,
        CircleEvent(
          type: 'adminDisabled',
          fromUid: auth.uid!,
          fromName: name,
          at: DateTime.fromMillisecondsSinceEpoch(atMs),
        ),
      );
    }
  }
}
