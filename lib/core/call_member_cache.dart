import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';
import 'location_service.dart';

/// Member cache for the native SIM-call distance overlay (v0.6.5).
///
/// The native CallStateReceiver runs WITHOUT the Flutter engine
/// (a call can arrive while the app is dead), so Dart keeps one
/// compact JSON string in SharedPreferences that the native side
/// reads directly:
///   key "apnacircle_call_cache" (stored by the plugin as
///   "flutter.apnacircle_call_cache" in "FlutterSharedPreferences")
///   {"myLat":31.52,"myLon":74.35,"myAt":1732...,
///    "members":[{"phone":"+923001234567","name":"Ali",
///                "lat":31.5,"lon":74.3,"at":1732...}]}
///
/// Written on EVERY member change — FamilyService._save() calls
/// [save], and every mutation (add / remove / location / remote
/// sync / SMS location) flows through _save. My location comes from
/// my own member entry, i.e. the location other members see.
/// Members with no stored phone or with location sharing OFF are
/// left OUT — the overlay must never show a distance for someone
/// who stopped sharing.
class CallMemberCache {
  static const _cacheKey = 'apnacircle_call_cache';

  /// Normalize a phone number for matching. Same rules as native
  /// CallMemberCache.normalize (Kotlin) — keep the two in sync.
  /// Pakistani numbers collapse to +92…; other numbers keep their
  /// "+" country code; anything else keeps its digits.
  static String normalizePhoneNumber(String raw) {
    final trimmed = raw.trim();
    final hasPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (hasPlus) return '+$digits';
    if (digits.length == 12 && digits.startsWith('92')) return '+$digits';
    if (digits.length == 11 && digits.startsWith('0')) {
      return '+92${digits.substring(1)}';
    }
    if (digits.length == 10 && digits.startsWith('3')) return '+92$digits';
    return digits;
  }

  /// True when two spellings of a number are the same number:
  /// normalized equality, or a last-10-digits fallback (covers
  /// +92 vs 03… and any other country-code spelling).
  static bool phonesMatch(String a, String b) {
    final na = normalizePhoneNumber(a);
    final nb = normalizePhoneNumber(b);
    if (na.isNotEmpty && na == nb) return true;
    final da = na.replaceAll(RegExp(r'[^0-9]'), '');
    final db = nb.replaceAll(RegExp(r'[^0-9]'), '');
    if (da.length >= 10 && db.length >= 10) {
      return da.substring(da.length - 10) == db.substring(db.length - 10);
    }
    return false;
  }

  /// Resolve the "my" position written into the native overlay
  /// cache (v0.6.14): the FRESHEST real position of THIS phone
  /// wins. A live/last-known fix beats a stale published member
  /// entry — the entry only moves when a publish lands, so it can
  /// lag the phone by minutes or hours when the phone was offline
  /// or the app was killed, while the last-known fix is refreshed
  /// by every GPS fix the phone takes. When neither is known the
  /// overlay shows no distance ('—' equivalent), never a made-up
  /// point. Returns the position + the time it was true, so the
  /// cache keeps the matching timestamp.
  static ({double lat, double lon, DateTime? at})? resolveCacheMyPosition({
    Member? myMember,
    LastLocation? lastKnown,
  }) {
    final m = myMember;
    final hasMemberLoc = m != null && m.hasLocation;
    if (lastKnown == null) {
      return hasMemberLoc
          ? (lat: m.lat!, lon: m.lon!, at: m.lastSeen)
          : null;
    }
    if (!hasMemberLoc) {
      return (lat: lastKnown.lat, lon: lastKnown.lon, at: lastKnown.at);
    }
    final memberAt = m.lastSeen;
    if (memberAt == null) {
      return (lat: lastKnown.lat, lon: lastKnown.lon, at: lastKnown.at);
    }
    return lastKnown.at.isAfter(memberAt)
        ? (lat: lastKnown.lat, lon: lastKnown.lon, at: lastKnown.at)
        : (lat: m.lat!, lon: m.lon!, at: memberAt);
  }

  /// Build the cache JSON from the current member list. [myId] is
  /// my own uid (null in demo mode — then the first member is used).
  /// [lastKnown] is this phone's last GPS fix: the cache's "my"
  /// position prefers it when it is fresher than my published
  /// member entry (see [resolveCacheMyPosition]).
  static Map<String, dynamic> buildJson(
    List<Member> members, {
    String? myId,
    LastLocation? lastKnown,
  }) {
    Member? me;
    for (final m in members) {
      if (m.id == myId) {
        me = m;
        break;
      }
    }
    me ??= members.isEmpty ? null : members.first;
    final myPos = resolveCacheMyPosition(myMember: me, lastKnown: lastKnown);
    return {
      'myLat': myPos?.lat,
      'myLon': myPos?.lon,
      'myAt': myPos?.at?.millisecondsSinceEpoch,
      'members': [
        for (final m in members)
          if (m.phone.trim().isNotEmpty && m.locationSharingOn)
            {
              'phone': normalizePhoneNumber(m.phone),
              'name': m.name,
              'lat': m.lat,
              'lon': m.lon,
              'at': m.lastSeen?.millisecondsSinceEpoch,
            },
      ],
    };
  }

  static Future<void> save(
    List<Member> members, {
    String? myId,
    LastLocation? lastKnown,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      jsonEncode(buildJson(members, myId: myId, lastKnown: lastKnown)),
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  }
}
