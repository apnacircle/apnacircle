import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants.dart';

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

  /// Ask for permission (while-in-use first; background only after
  /// the user understands why — Play Store requires a video + prompt
  /// for background location, see README).
  Future<bool> ensurePermission() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p == LocationPermission.whileInUse ||
        p == LocationPermission.always;
  }

  /// Current fix, throttled: at most every 60 s and only after the
  /// member moved >= 50 m (keeps the \$5/year plan affordable).
  /// Returns null when there is no fix — caller must use lastKnown().
  Future<Position?> currentFix() async {
    if (!await ensurePermission()) return null;
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
