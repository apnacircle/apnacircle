import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

/// Stable per-device identifier for the 7-day free trial
/// (user order, 23 Nov 2026 ~23:58 PKT: "AK mobile pay ak bar
/// trail mily bus" — one phone gets the trial only ONCE).
///
/// The trial is keyed by device, NOT by account or circle: a
/// reinstall, or a different account signing in on the SAME phone,
/// must NOT grant a new trial. A different phone gets its own one
/// trial (parent phone and child phone are separate devices).
///
/// How it works: Android ID (Settings.Secure.ANDROID_ID) comes
/// over the small `apnacircle/device` platform channel (see
/// MainActivity.kt) — no new package needed. The raw id NEVER
/// leaves the phone: only its SHA-256 hash is stored, in the
/// Realtime Database under `trials/{hash}` and in the local cache.
/// No permission is needed to read the Android ID.
///
/// HONEST LIMIT: a factory reset changes the Android ID, so a
/// reset phone could get a new trial. That is accepted (see README)
/// — it is a normal trade-off, not a hidden hole.
class DeviceIdService {
  static const _channel = MethodChannel(AppConstants.deviceChannel);

  /// SHA-256 of the Android ID (64 hex chars). Null when the id
  /// cannot be read (non-Android platform, channel not wired, or
  /// the platform call throws) — callers fall back to a local-only
  /// trial then, and say so.
  Future<String?> getDeviceIdHash() async {
    try {
      final id = await _channel.invokeMethod<String>('getAndroidId');
      if (id == null || id.isEmpty) return null;
      return hashDeviceId(id);
    } catch (_) {
      return null;
    }
  }

  /// Pure helper (unit-tested): hash the raw device id. Never
  /// store or transmit the raw id itself.
  static String hashDeviceId(String deviceId) =>
      sha256.convert(utf8.encode(deviceId)).toString();
}
