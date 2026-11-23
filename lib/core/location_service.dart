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
  /// member moved >= 50 m (keeps the \$5/year plan affordable).
  /// Returns null when there is no fix — caller must use lastKnown().
  Future<Position?> currentFix() async {
    final p = await ensureWhileInUse();
    if (p != LocationPermission.whileInUse &&
        p != LocationPermission.always) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
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
      if (moved < AppConstants.minMoveMeters && tooSoon) return _lastFix;
    }
    _lastFix = pos;
    _lastSent = DateTime.now();
    await _cache(pos);
    return pos;
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
