import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/location_service.dart';
import '../models/circle.dart';
import 'auth_service.dart';
import 'sync_service.dart';

/// SIM-change detection — pure, unit-tested logic (v0.5).
///
/// The fingerprint is a SHA-256 hash of the SIM operator fields
/// (see SimFingerprint.kt). The raw values are NEVER stored or
/// sent anywhere — only the hash. A change is only reported when a
/// previous hash exists: the first run stores the baseline
/// silently, so a fresh install never raises a false alert.
class SimChangeDetector {
  /// SHA-256 hex of the joined fingerprint fields.
  static String hashFingerprint(List<String> fields) =>
      sha256.convert(utf8.encode(fields.join('|'))).toString();

  /// True only when BOTH hashes exist and differ. A missing old
  /// hash means "first run — store the baseline, do not alert".
  static bool isChanged(String? oldHash, String? newHash) =>
      oldHash != null && newHash != null && oldHash != newHash;
}

/// SIM-change alert + boot auto-start follow-up (v0.5, 23 Nov 2026).
///
/// Two catch points, both feeding the same RTDB event:
/// * BOOT: BootReceiver compares the SIM hash after every reboot
///   and leaves a pending event when it changed (the app itself
///   was not running). [checkOnStart] publishes that pending event.
/// * RUNNING: [checkOnStart] also compares the live fingerprint
///   with the Dart-side stored hash and publishes on a mismatch.
///
/// The event is written to every circle this phone belongs to, with
/// the LAST known location (the new SIM may have no data yet — the
/// new location follows when the phone gets internet and a fix).
/// The new SIM's NUMBER is usually not obtainable — the alert says
/// "SIM changed", it never promises the new number.
///
/// HONEST LIMITS (also in SimFingerprint.kt / README):
/// * A same-carrier SIM swap is NOT detectable — Android 10+ hides
///   ICCID/IMSI from normal apps, so the fingerprint is the SIM
///   operator, not the SIM itself.
/// * The alert needs net to reach the parent: with no data the
///   pending event waits and is published when the app next runs
///   with internet.
/// * A factory reset deletes the app — no alert is possible after
///   a reset.
class SimChangeService {
  SimChangeService({LocationService? location})
      : _location = location ?? LocationService();

  static const MethodChannel _channel =
      MethodChannel(AppConstants.simChannel);

  /// Dart-side stored SIM hash (separate from the native
  /// BootReceiver's own stored hash — both track independently).
  static const _storedHashKey = 'sim_hash_v1';

  final LocationService _location;

  /// Current SIM fingerprint hash from native code, or null when
  /// it cannot be read (no READ_PHONE_STATE, no SIM, non-Android).
  Future<String?> currentHash() async {
    try {
      return await _channel.invokeMethod<String>('getSimFingerprint');
    } on PlatformException {
      return null;
    }
  }

  /// Pending SIM-change event left by BootReceiver (decoded JSON),
  /// or null.
  Future<Map<String, dynamic>?> pendingSimChange() async {
    try {
      final raw =
          await _channel.invokeMethod<String>('getPendingSimChange');
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPendingSimChange() async {
    try {
      await _channel.invokeMethod<void>('clearPendingSimChange');
    } on PlatformException {
      // Best effort only.
    }
  }

  /// Run once at app start (after sync.load()). Publishes a
  /// 'simChanged' event to every circle when the SIM changed —
  /// either from the pending boot event or from a live mismatch.
  /// No-op when not signed in (demo mode): the baseline is still
  /// stored, so the next signed-in start compares correctly.
  Future<void> checkOnStart({
    required SyncService sync,
    required AuthService auth,
  }) async {
    // 1. Pending boot event first — it carries the change time.
    final pending = await pendingSimChange();
    if (pending != null) {
      await clearPendingSimChange();
      await _publishSimChanged(
        sync: sync,
        auth: auth,
        at: pending['at'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (pending['at'] as num).toInt(),
              )
            : DateTime.now(),
      );
    }

    // 2. Live comparison against the Dart-side baseline.
    final current = await currentHash();
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_storedHashKey);
    if (current == null) return;
    if (!SimChangeDetector.isChanged(stored, current)) {
      // First run (baseline) or no change — store and stop.
      if (stored != current) {
        await prefs.setString(_storedHashKey, current);
      }
      return;
    }
    await prefs.setString(_storedHashKey, current);
    await _publishSimChanged(sync: sync, auth: auth, at: DateTime.now());
  }

  Future<void> _publishSimChanged({
    required SyncService sync,
    required AuthService auth,
    required DateTime at,
  }) async {
    if (!sync.isAvailable || auth.uid == null) return;
    final last = await _location.lastKnown();
    final name = auth.displayName ?? auth.phoneNumber ?? auth.email ?? 'Me';
    for (final circle in sync.myCircles) {
      await sync.sendEvent(
        circle.id,
        CircleEvent(
          type: 'simChanged',
          fromUid: auth.uid!,
          fromName: name,
          at: at,
          lat: last?.lat,
          lon: last?.lon,
        ),
      );
    }
  }
}
