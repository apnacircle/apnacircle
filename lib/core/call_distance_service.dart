import 'dart:math';
import 'package:flutter/services.dart';

import 'constants.dart';

/// SIM-call caller distance.
///
/// HOW IT WORKS (Android only — iOS cannot see SIM calls, Apple
/// restriction, see README):
/// 1. MainActivity.kt listens for incoming calls (PhoneStateListener /
///    CallScreeningService on Android 10+). When a call arrives it
///    asks this channel for the caller's number.
/// 2. If the number belongs to a family member, we look up that
///    member's last known location and compute the Haversine distance
///    from MY location.
/// 3. The distance is shown on the incoming-call screen (overlay /
///    full-screen intent) AND in the app's Call screen.
/// WhatsApp / app calls are NOT needed — this is a normal SIM call.
/// WhatsApp calls have no SIM number, so they cannot use this path.
class CallDistanceService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.callChannel);

  /// Haversine distance in km between two GPS points.
  static double distanceKm(
      double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return 2 * earthRadiusKm * asin(sqrt(a));
  }

  static double _toRad(double degrees) => degrees * pi / 180;

  static String formatKm(double km) =>
      km < 1 ? '${(km * 1000).round()} m' : '${km.toStringAsFixed(1)} km';

  /// Ask native code for the currently ringing number, if any.
  /// Returns null when there is no incoming call.
  static Future<String?> incomingNumber() async {
    try {
      return await _channel.invokeMethod<String>('incomingNumber');
    } on PlatformException {
      return null;
    }
  }
}
