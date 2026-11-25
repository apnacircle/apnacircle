import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

/// What level of location sharing this phone has right now.
///
/// * [off] — permission denied / denied forever, or the phone's
///   location services are switched off entirely.
/// * [whileInUse] — "Allow only while using the app": the parent
///   sees the child ONLY while ApnaCircle is open on the child's
///   phone. Background tracking cannot run.
/// * [always] — "Allow all the time": the background service can
///   keep sharing even when the app is closed (v0.6.4).
enum LocationSharingState { off, whileInUse, always }

/// Pure mapping from the system permission to the sharing state —
/// unit-tested (test/background_location_test.dart). The "location
/// services switched off" case is handled by [LocationService.sharingState],
/// not here, because it needs a platform call.
LocationSharingState locationStateFromPermission(LocationPermission p) {
  switch (p) {
    case LocationPermission.always:
      return LocationSharingState.always;
    case LocationPermission.whileInUse:
      return LocationSharingState.whileInUse;
    case LocationPermission.denied:
    case LocationPermission.deniedForever:
    case LocationPermission.unableToDetermine:
      return LocationSharingState.off;
  }
}

/// What the background cycle should do to obtain a position
/// (v0.6.12, battery drain fix). Pure decision — unit-tested
/// (test/v0612_test.dart). The rule: never power the GPS when a
/// cheaper source already proves where the phone is.
enum FixAcquisition {
  /// A fresh OS-cached fix near our last fix proves the phone has
  /// not moved — use the last fix, power nothing.
  useCached,

  /// The cache is missing, stale, or far from our last fix — verify
  /// with one LOW-POWER fix (cell/WiFi, no GPS radio) before ever
  /// asking for GPS.
  mediumCheck,

  /// No baseline yet, the accurate baseline is too old, or the
  /// low-power check suggests movement — take a fresh
  /// high-accuracy GPS fix.
  highFix,
}

/// Pure decision for the background cycle (v0.6.12): how to get a
/// position this cycle, cheapest first. Nothing here touches the
/// radio — the caller acts on the returned value.
///
/// * No last fix yet ([lastFix] null) → [FixAcquisition.highFix]:
///   only a real GPS fix can establish the baseline.
/// * Accurate baseline older than [LocationService.highFixMaxAge]
///   → [FixAcquisition.highFix]: even a phone sitting at home gets
///   a fresh GPS fix at least every 30 min, so the baseline never
///   goes stale for hours.
/// * OS-cached fix fresh (≤ [LocationService.lastKnownFreshWindow])
///   AND within 50 m of our last fix → [FixAcquisition.useCached]:
///   the phone provably has not moved; power nothing.
/// * Anything else (no cache, stale cache, cache far from our last
///   fix) → [FixAcquisition.mediumCheck]: verify cheaply first.
///   A real move is NEVER swallowed by the cache — a fresh cached
///   fix far away escalates to a check, and the check escalates to
///   GPS when it suggests movement.
FixAcquisition decideFixAcquisition({
  required Position? lastKnown,
  required Position? lastFix,
  required DateTime? lastHighFixAt,
  required DateTime now,
}) {
  if (lastFix == null) return FixAcquisition.highFix;
  if (lastHighFixAt == null ||
      now.difference(lastHighFixAt) > LocationService.highFixMaxAge) {
    return FixAcquisition.highFix;
  }
  if (lastKnown != null) {
    final age = now.difference(lastKnown.timestamp);
    if (age <= LocationService.lastKnownFreshWindow) {
      final moved = Geolocator.distanceBetween(
        lastFix.latitude,
        lastFix.longitude,
        lastKnown.latitude,
        lastKnown.longitude,
      );
      if (moved <= AppConstants.minMoveMeters) {
        return FixAcquisition.useCached;
      }
    }
  }
  return FixAcquisition.mediumCheck;
}

/// Does a low-power (medium-accuracy) fix suggest the phone really
/// moved away from [lastFix]? Same 50 m threshold as the publish
/// rule — a move the parent would want to see must never be
/// dismissed as network-location noise, and a false alarm only
/// costs one GPS fix (the throttle still suppresses the publish
/// when the GPS fix shows no real move).
bool mediumSuggestsMovement({
  required Position medium,
  required Position lastFix,
}) {
  final moved = Geolocator.distanceBetween(
    lastFix.latitude,
    lastFix.longitude,
    medium.latitude,
    medium.longitude,
  );
  return moved > AppConstants.minMoveMeters;
}

/// Location, with last-known fallback.
///
/// RULE: if the net is off, the app MUST still show the member's
/// LAST location + time (Mujahid, 21 Nov 2026). So every fix is
/// cached locally (SharedPreferences) and the UI always reads
/// `lastKnown` when no live fix is available.
class LastLocation {
  final double lat;
  final double lon;
  final DateTime at;
  const LastLocation(this.lat, this.lon, this.at);
}

class LocationService {
  static const _latKey = 'last_lat';
  static const _lonKey = 'last_lon';
  static const _atKey = 'last_at_ms';

  Position? _lastFix;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the last high-accuracy GPS fix was taken (v0.6.12).
  /// Only set when a fresh GPS fix is actually accepted — never on
  /// a throttled return of the previous fix.
  DateTime? _lastHighFixAt;

  /// An OS-cached fix this fresh counts as proof the phone has not
  /// moved (v0.6.12). A few minutes, not longer: the cache is only
  /// trusted while it is clearly current.
  static const Duration lastKnownFreshWindow = Duration(minutes: 2);

  /// Even a phone that never moves gets a fresh high-accuracy GPS
  /// fix at least this often (v0.6.12), so the accurate baseline
  /// never goes stale for hours. Stationary cost: one GPS fix per
  /// 30 min instead of one per minute.
  static const Duration highFixMaxAge = Duration(minutes: 30);

  /// A low-power (medium-accuracy) fix may take up to this long;
  /// on timeout the cycle falls back to a high-accuracy fix rather
  /// than guessing (v0.6.12).
  static const Duration mediumFixTimeout = Duration(seconds: 10);

  /// Raw system permission (no request). The UI maps it with
  /// [locationStateFromPermission].
  Future<LocationPermission> checkPermission() =>
      Geolocator.checkPermission();

  /// The sharing state on THIS phone right now. Returns [off] when
  /// the permission is denied/denied-forever OR when the phone's
  /// location services are switched off entirely — in both cases
  /// the parent sees nothing live, and the status card must say so.
  Future<LocationSharingState> sharingState() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationSharingState.off;
    }
    return locationStateFromPermission(await checkPermission());
  }

  /// Ask for while-in-use permission only (the first step). Returns
  /// the permission that resulted. Background ("always") is NEVER
  /// requested here: on Android 11+ it can only be granted from
  /// Settings, not from a dialog — see [openAppSettings].
  Future<LocationPermission> ensureWhileInUse() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p;
  }

  /// Open THIS app's page in Android Settings, where the user picks
  /// "Allow all the time" (Location permission → "Allow all the
  /// time"). This is the ONLY way to get background location on
  /// Android 11+: a request dialog cannot grant it, and the app
  /// must show a plain-words reason BEFORE sending the user there
  /// (Play Store rule — the rationale dialog lives in
  /// HomeMapScreen._fixLocationSharing).
  Future<bool> openAppSettings() async {
    try {
      return await ph.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  /// Ask Android to exempt ApnaCircle from battery optimization, so
  /// the phone does not kill the background location service to
  /// save battery. Returns true when exempt. Some phones (notably
  /// Xiaomi / Oppo / Vivo with aggressive killers) still stop
  /// background work even when exempt — that limit is documented
  /// in README, never hidden.
  Future<bool> requestBatteryOptimizationExemption() async {
    try {
      final status =
          await ph.Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Android 13+: the foreground service shows a permanent
  /// notification ("sharing your location with your family"), which
  /// needs the notification permission. Best effort — the service
  /// is started either way; a denied notification permission only
  /// hides the notification, it does not stop the sharing.
  Future<bool> ensureNotificationPermission() async {
    try {
      final status = await ph.Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Current fix, throttled: at most every 60 s and only after the
  /// member moved >= 50 m (keeps the $5/year plan affordable).
  /// Returns null when there is no fix — caller must use lastKnown().
  /// UNCHANGED in v0.6.12: the foreground Map loop still takes a
  /// fresh high-accuracy fix — the user is looking at the map, so
  /// accuracy on demand is correct there and cheap. Only the
  /// 24/7 background cycle uses [efficientFix].
  Future<Position?> currentFix() async {
    final p = await ensureWhileInUse();
    if (p != LocationPermission.whileInUse &&
        p != LocationPermission.always) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    return _acquireHighFix();
  }

  /// Battery-aware fix for the BACKGROUND cycle (v0.6.12).
  ///
  /// THE DRAIN IT FIXES: the background task runs every 60 s,
  /// 24/7, and the old path took a FRESH high-accuracy GPS fix
  /// every single cycle (~1,440 GPS fixes/day) — the 50 m / 60 s
  /// throttle ran AFTER the fix, so it saved server writes but
  /// never saved battery. A phone sitting at home all day still
  /// fired the GPS radio every minute.
  ///
  /// THE NEW ORDER, cheapest first (see [decideFixAcquisition]):
  /// fresh OS-cached fix near our last fix → use it, power nothing;
  /// otherwise one LOW-POWER fix (cell/WiFi, no GPS radio) to check
  /// for movement; GPS only when that check suggests movement, when
  /// there is no baseline yet, or when the accurate baseline is
  /// older than [highFixMaxAge] (30 min). The 60 s cycle and the
  /// 50 m / 60 s publish throttle are UNCHANGED: a real move is
  /// still caught within ~60 s, and what the parent sees — and
  /// when — is exactly what it was before. Only HOW the fix is
  /// obtained changed.
  Future<Position?> efficientFix() async {
    final p = await ensureWhileInUse();
    if (p != LocationPermission.whileInUse &&
        p != LocationPermission.always) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final now = DateTime.now();
    final lastKnown = await _osLastKnown();
    switch (decideFixAcquisition(
      lastKnown: lastKnown,
      lastFix: _lastFix,
      lastHighFixAt: _lastHighFixAt,
      now: now,
    )) {
      case FixAcquisition.useCached:
        // Proven stationary by a fresh OS-cached fix: no radio.
        return _lastFix;
      case FixAcquisition.mediumCheck:
        final medium = await _mediumFix();
        if (medium == null) {
          // Could not verify cheaply (e.g. no network for a
          // cell/WiFi fix) — verify properly rather than guessing.
          return _acquireHighFix();
        }
        if (_lastFix != null &&
            !mediumSuggestsMovement(medium: medium, lastFix: _lastFix!)) {
          return _lastFix;
        }
        return _acquireHighFix();
      case FixAcquisition.highFix:
        return _acquireHighFix();
    }
  }

  /// The old currentFix() body, unchanged except for stamping
  /// [_lastHighFixAt]: one fresh high-accuracy GPS fix, with the
  /// same 50 m / 60 s throttle as before.
  Future<Position> _acquireHighFix() async {
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
    if (_lastFix != null) {
      final moved = Geolocator.distanceBetween(
        _lastFix!.latitude, _lastFix!.longitude, pos.latitude, pos.longitude,
      );
      final tooSoon =
          DateTime.now().difference(_lastSent) < AppConstants.minUpdateInterval;
      if (moved < AppConstants.minMoveMeters && tooSoon) return _lastFix!;
    }
    _lastFix = pos;
    _lastSent = DateTime.now();
    _lastHighFixAt = DateTime.now();
    await _cache(pos);
    return pos;
  }

  /// The OS's last known position, if any. FREE: it reads a cached
  /// value and never powers the GPS. Null when the OS has nothing
  /// (or the call fails) — the caller then verifies cheaply.
  Future<Position?> _osLastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// A LOW-POWER fix (cell/WiFi, no GPS radio) used only to check
  /// whether the phone moved. Null on timeout or error — the caller
  /// then falls back to a high-accuracy fix.
  Future<Position?> _mediumFix() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: mediumFixTimeout,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _cache(Position pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_latKey, pos.latitude);
    await prefs.setDouble(_lonKey, pos.longitude);
    await prefs.setInt(_atKey, pos.timestamp.millisecondsSinceEpoch);
  }

  /// Last known location, even with net/GPS off. Null = never had one.
  Future<LastLocation?> lastKnown() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_latKey);
    final lon = prefs.getDouble(_lonKey);
    final at = prefs.getInt(_atKey);
    if (lat == null || lon == null || at == null) return null;
    return LastLocation(
      lat,
      lon,
      DateTime.fromMillisecondsSinceEpoch(at),
    );
  }

  /// Distance helper used by the map + member cards.
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * r * asin(sqrt(a));
  }
}
