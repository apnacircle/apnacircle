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

  /// True when the app holds READ_CALL_LOG. On Android 10+ the
  /// ringing number is only delivered with this permission — with
  /// only READ_PHONE_STATE the listener runs but the number comes
  /// back empty. That is an Android rule, not a bug here.
  static Future<bool> hasCallLogPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasCallLogPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// True when the app holds PROCESS_OUTGOING_CALLS — the dialled
  /// number for the outgoing-call overlay (v0.6.5).
  static Future<bool> hasOutgoingCallPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasOutgoingCallPermission') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// True when the app may draw over other apps — the overlay
  /// permission the call-distance card needs (v0.6.5). Only the
  /// user's own tap on Android's system page can grant it.
  static Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Open Android's "Display over other apps" page for this app.
  /// The CALLER must show a plain explanation first — never open
  /// the system page silently.
  static Future<void> openOverlaySettings() async {
    try {
      await _channel.invokeMethod<void>('openOverlaySettings');
    } on PlatformException {
      // Nothing to open on this platform — ignore.
    }
  }

  /// Ask Android for READ_PHONE_STATE + READ_CALL_LOG (native
  /// permission dialog). The CALLER must show a plain explanation
  /// first — never request silently. Returns which permissions
  /// were granted. After a grant, re-registers the listener so
  /// numbers start flowing.
  static Future<Map<String, bool>> requestCallPermissions() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('requestCallPermissions');
      final out = <String, bool>{};
      raw?.forEach((k, v) {
        if (k is String && v is bool) out[k] = v;
      });
      return out;
    } on PlatformException {
      return {};
    }
  }
}
