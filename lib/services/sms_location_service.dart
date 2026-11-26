import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/location_service.dart';

/// One location received by SMS (parent side).
class SmsLocation {
  final String from; // sender phone number (parent sees who sent it)
  final double lat;
  final double lon;
  final DateTime at; // GPS fix time on the child's phone
  const SmsLocation({
    required this.from,
    required this.lat,
    required this.lon,
    required this.at,
  });
}

/// OFFLINE location fallback (v0.3 addition, 22 Nov 2026).
///
/// Problem: the child goes out, home Wi-Fi is gone, mobile data is
/// off — Firebase cannot deliver the live location. GPS still works
/// with no internet, and SMS needs only mobile signal (no data).
/// So, while the phone is offline, the app sends its GPS fix to the
/// PARENT's number by SMS, and the parent's phone reads the SMS and
/// shows that location on the map, labelled "SMS se aayi".
///
/// Rules (Mujahid, 22 Nov 2026):
/// * SMS goes ONLY to parent number(s) in the SAME circle — never
///   to anyone else.
/// * Modest interval: at most every 15 minutes while offline, and
///   only when the child moved >= 50 m since the last SMS — so it
///   does not eat the SMS balance.
/// * Permissions SEND_SMS / RECEIVE_SMS are requested with a plain
///   explanation in the app before the first send (see
///   [ensureSmsPermission] + the dialog in HomeMapScreen).
/// * SMS body format (short, parseable, no personal data beyond
///   the location itself):
///   `APNACIRCLE LOC:<lat>,<lon>,<epochMillis>`
///
/// Honest limits (also in README):
/// * No live tracking without ANY channel — SMS is a 15-minute
///   snapshot, not live.
/// * SMS needs mobile signal + balance. No signal = no SMS.
/// * If the phone is switched OFF, nothing can be sent until it is
///   back on — the parent only ever sees the last location from
///   before it went off, with its time.
class SmsLocationService {
  static const MethodChannel _channel =
      MethodChannel(AppConstants.smsChannel);

  /// SMS body prefix — the parent's phone only acts on messages
  /// starting with this (other SMS are never touched).
  static const String smsPrefix = 'APNACIRCLE LOC:';

  /// At most one SMS location per 15 minutes while offline.
  static const Duration offlineSmsInterval = Duration(minutes: 15);

  final _incomingController = StreamController<SmsLocation>.broadcast();
  bool _listening = false;

  /// Locations arriving by SMS (live, while the app runs).
  Stream<SmsLocation> get incoming => _incomingController.stream;

  /// Encode a fix into the SMS body.
  static String encodeSms(double lat, double lon, DateTime at) =>
      '$smsPrefix$lat,$lon,${at.millisecondsSinceEpoch}';

  /// Parse an SMS body. Returns null when it is not our format
  /// (wrong prefix, bad numbers, impossible coordinates).
  static SmsLocation? parseSms(String body, {String from = ''}) {
    if (!body.startsWith(smsPrefix)) return null;
    final parts = body.substring(smsPrefix.length).split(',');
    if (parts.length != 3) return null;
    final lat = double.tryParse(parts[0].trim());
    final lon = double.tryParse(parts[1].trim());
    final atMs = int.tryParse(parts[2].trim());
    if (lat == null || lon == null || atMs == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return SmsLocation(
      from: from,
      lat: lat,
      lon: lon,
      at: DateTime.fromMillisecondsSinceEpoch(atMs),
    );
  }

  /// Pure throttle rule (unit-tested): send when never sent, or
  /// when [offlineSmsInterval] has passed since [lastSentAt].
  static bool shouldSendSms({
    required DateTime? lastSentAt,
    required DateTime now,
  }) {
    if (lastSentAt == null) return true;
    return now.difference(lastSentAt) >= offlineSmsInterval;
  }

  /// True when the phone has NO data connection at all (no Wi-Fi,
  /// no mobile data). GPS + SMS still work in this state.
  Future<bool> get isOffline async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  /// Stream of offline/online changes (true = offline).
  Stream<bool> get onOfflineChanged =>
      Connectivity().onConnectivityChanged.map((results) =>
          results.isEmpty ||
          results.every((r) => r == ConnectivityResult.none));

  /// Ask for SEND_SMS + RECEIVE_SMS with the OS dialog. The caller
  /// (UI) must explain WHY first — see HomeMapScreen. Returns true
  /// only when the permission is granted.
  Future<bool> ensureSmsPermission() async {
    var status = await Permission.sms.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied) return false;
    status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Send any SMS body to [to] via the native SmsManager.
  /// [sendLocationSms] is the location-only wrapper around this.
  /// Returns false when the native send failed (no permission, no
  /// signal, no SIM). Never call with a number outside the sender's
  /// own circle — enforced by the caller.
  Future<bool> sendRawSms({
    required String to,
    required String body,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('sendSms', {
        'to': to,
        'body': body,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('ApnaCircle: sendSms failed ($e)');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Send one location SMS to [parentPhone]. Returns false when
  /// the native send failed (no permission, no signal, no SIM).
  /// Never call with any number except a parent's number from the
  /// same circle — enforced by the caller.
  Future<bool> sendLocationSms({
    required String parentPhone,
    required double lat,
    required double lon,
    required DateTime at,
  }) =>
      sendRawSms(to: parentPhone, body: encodeSms(lat, lon, at));

  /// Start listening for live incoming SMS locations (native
  /// receiver -> Dart). Safe to call repeatedly; only binds once.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSmsLocation') {
        final args = call.arguments as Map?;
        final body = args?['body'] as String?;
        final from = args?['from'] as String? ?? '';
        if (body == null) return;
        final loc = parseSms(body, from: from);
        if (loc != null) _incomingController.add(loc);
      }
    });
  }

  /// SMS locations the native receiver saved while the app was
  /// closed (read on start / on resume). Clears them after reading.
  Future<List<SmsLocation>> fetchPendingSms() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('getPendingSmsLocations');
      if (raw == null || raw.isEmpty) return const [];
      await _channel.invokeMethod<void>('clearPendingSmsLocations');
      final out = <SmsLocation>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final body = item['body'] as String?;
        final from = item['from'] as String? ?? '';
        if (body == null) continue;
        final loc = parseSms(body, from: from);
        if (loc != null) out.add(loc);
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('ApnaCircle: fetchPendingSms failed ($e)');
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  // --- Offline send orchestration (child side) ---

  static const _lastSmsLatKey = 'sms_last_lat';
  static const _lastSmsLonKey = 'sms_last_lon';
  static const _lastSmsAtKey = 'sms_last_at_ms';

  /// Send the current GPS fix to every parent in the circle — but
  /// ONLY when all of these hold: (a) the phone is offline (no
  /// data), (b) 15 minutes passed since the last SMS, (c) the child
  /// moved >= 50 m since the last SMS (or never sent one).
  /// Returns how many parents got the SMS. Call this from a timer
  /// (e.g. every 5 min check, actual send at most every 15 min).
  Future<int> sendOfflineLocationIfNeeded({
    required List<String> parentPhones,
    required double lat,
    required double lon,
    required DateTime at,
  }) async {
    if (parentPhones.isEmpty) return 0;
    if (!await isOffline) return 0; // online: Firebase does the job
    final prefs = await SharedPreferences.getInstance();
    final lastAtMs = prefs.getInt(_lastSmsAtKey);
    final lastAt = lastAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastAtMs);
    if (!shouldSendSms(lastSentAt: lastAt, now: at)) return 0;
    final lastLat = prefs.getDouble(_lastSmsLatKey);
    final lastLon = prefs.getDouble(_lastSmsLonKey);
    if (lastLat != null && lastLon != null) {
      final moved = LocationService.distanceKm(lastLat, lastLon, lat, lon);
      if (moved * 1000 < AppConstants.minMoveMeters) return 0;
    }
    var sent = 0;
    for (final phone in parentPhones) {
      final ok = await sendLocationSms(
        parentPhone: phone,
        lat: lat,
        lon: lon,
        at: at,
      );
      if (ok) sent++;
    }
    if (sent > 0) {
      await prefs.setDouble(_lastSmsLatKey, lat);
      await prefs.setDouble(_lastSmsLonKey, lon);
      await prefs.setInt(_lastSmsAtKey, at.millisecondsSinceEpoch);
    }
    return sent;
  }

  /// For tests / debug: the SMS body this phone would send.
  static String previewSms(double lat, double lon, DateTime at) =>
      encodeSms(lat, lon, at);

  void dispose() {
    _incomingController.close();
  }
}
