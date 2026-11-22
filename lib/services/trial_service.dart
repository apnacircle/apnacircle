import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trial.dart';
import 'device_id_service.dart';
import 'sync_service.dart';

/// 7-day free trial of the Family plan (22 Nov 2026).
///
/// ONCE PER DEVICE (user correction, 23 Nov 2026 ~23:58 PKT:
/// "AK mobile pay ak bar trail mily bus"). The trial is keyed by
/// the SHA-256 hash of the Android ID — NOT by account or circle:
/// * a reinstall on the same phone does NOT grant a new trial;
/// * a different account signing in on the same phone does NOT
///   grant a new trial;
/// * a different phone gets its own one trial (parent phone and
///   child phone are separate devices).
///
/// Storage:
/// * SYNCED mode (Firebase configured + signed in): the trial lives
///   in the Realtime Database under `trials/{deviceHash}`. The flag
///   is read fresh from RTDB before starting, so no phone can
///   restart it. Needs the `trials` rules in FIREBASE_SETUP.md §2.
/// * LOCAL cache (always): SharedPreferences, keyed by the same
///   device hash, so the Plan screen shows instantly and demo-mode
///   users (no Firebase / not signed in) can try the trial too.
///
/// The trial is started ONLY by the parent, from the Plan screen.
/// After expiry nothing is deleted and nothing is silently kept:
/// the Plan screen says the trial ended and a subscription is
/// needed. No feature is locked by this class — the app has no
/// paid-plan gate today, and inventing one was NOT ordered.
///
/// HONEST LIMITS: a factory reset changes the Android ID, so a
/// reset phone could get a new trial (accepted). When the device id
/// cannot be read at all (non-Android, channel missing), the trial
/// is local-only and a reinstall could restart it — that fallback
/// is documented, not hidden.
class TrialService extends ChangeNotifier {
  TrialService({Future<String?> Function()? deviceIdHashProvider})
      : _deviceIdHashProvider =
            deviceIdHashProvider ?? DeviceIdService().getDeviceIdHash;

  static const _prefsKeyBase = 'trial_state_v1';

  final Future<String?> Function() _deviceIdHashProvider;

  TrialState _state = const TrialState();
  TrialState get state => _state;

  TrialStatus get status => _state.statusAt(DateTime.now());
  int get daysRemaining => _state.daysRemainingAt(DateTime.now());
  bool get isActive => status == TrialStatus.active;
  bool get isExpired => status == TrialStatus.expired;
  bool get canStartTrial => status == TrialStatus.notStarted;

  /// SHA-256 of this phone's Android ID (null = could not be read).
  String? _deviceHash;
  String? get deviceHash => _deviceHash;

  SyncService? _sync;

  void attachSync(SyncService sync) {
    _sync = sync;
  }

  bool get _isSynced => _sync != null && _sync!.isAvailable;

  /// The trial can be proven per-device only when the device hash
  /// is known — without it, only the local cache is used.
  bool get _isSyncedWithDevice => _isSynced && _deviceHash != null;

  String _prefsKey() => _deviceHash == null
      ? _prefsKeyBase
      : '${_prefsKeyBase}_$_deviceHash';

  /// Load the locally cached trial for THIS device, then refresh
  /// from RTDB when synced (the server copy wins — it is the
  /// shared truth that survives a reinstall).
  Future<void> load() async {
    _deviceHash ??= await _deviceIdHashProvider();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey());
    if (raw != null) {
      try {
        final cached = TrialState.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        // Only trust a cached copy that belongs to this device
        // (a factory reset changes the id — the old copy is not
        // this phone's trial any more).
        if (cached.deviceHash == null ||
            cached.deviceHash == _deviceHash) {
          _state = cached;
        }
      } catch (_) {
        _state = const TrialState();
      }
    }
    notifyListeners();
    if (_isSyncedWithDevice) {
      final remote = await _sync!.fetchTrial(_deviceHash!);
      if (remote != null) {
        _state = remote;
        await _saveLocal();
        notifyListeners();
      }
    }
  }

  /// Start the 7-day trial on THIS phone. Returns false — and
  /// starts nothing — when the trial was already used on this
  /// device (in RTDB, or in the local cache). A reinstall or a
  /// new account on the same phone cannot restart it.
  Future<bool> startTrial() async {
    _deviceHash ??= await _deviceIdHashProvider();
    if (_state.trialUsed) return false;
    if (_isSyncedWithDevice) {
      // Fresh read first: the trial may already exist on the server
      // (started before a reinstall, or on this phone under another
      // account).
      final remote = await _sync!.fetchTrial(_deviceHash!);
      if (remote != null && remote.trialUsed) {
        _state = remote;
        await _saveLocal();
        notifyListeners();
        return false;
      }
      final started =
          TrialState.start(DateTime.now(), deviceHash: _deviceHash);
      final ok = await _sync!.publishTrial(_deviceHash!, started);
      if (!ok) return false;
      _state = started;
    } else {
      _state = TrialState.start(DateTime.now(), deviceHash: _deviceHash);
    }
    await _saveLocal();
    notifyListeners();
    return true;
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey(), jsonEncode(_state.toJson()));
  }
}
