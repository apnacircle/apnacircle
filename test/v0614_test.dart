import 'package:apnacircle/core/call_member_cache.dart';
import 'package:apnacircle/core/location_service.dart';
import 'package:apnacircle/core/member_phone.dart';
import 'package:apnacircle/core/viewer_position.dart';
import 'package:apnacircle/models/member.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

/// Wrong distance (v0.6.14, 25 Nov 2026): every member distance on
/// the Map tab — and the call-overlay preview — was measured from a
/// HARDCODED Lahore point (31.5204, 74.3587), on EVERY phone. The
/// user in Jahanian (~295 km from Lahore) saw himself and everyone
/// at home as "295.4 km away". The Haversine helper itself was
/// correct; the "from" point was not. The native SIM-call overlay
/// was never affected (its cache carries my real published
/// location); only the two Flutter screens used the constant.
///
/// The fix: the viewer's position is resolved live — fresh GPS fix,
/// else the last known fix, else my own published member entry —
/// and a distance is shown as '—' while it is unknown, never from
/// a made-up point. Lahore stays ONLY as the map's initial camera
/// fallback. These tests pin the pure resolution layer; the screen
/// just wires the foreground loop's fix into it.
void main() {
  // 1 degree of latitude is ~111,320 m.
  // 0.0017966 deg lat ~= 200 m, 0.0323 deg lat ~= 3.6 km.
  Position pos(double lat, double lon, DateTime at) => Position(
        latitude: lat,
        longitude: lon,
        timestamp: at,
        accuracy: 10,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  Member member(String id, String name, {double? lat, double? lon}) =>
      Member(id: id, name: name, phone: '+923000000000', lat: lat, lon: lon);

  // Jahanian (user's home) vs the old hardcoded Lahore point.
  const jahanianLat = 30.0500;
  const jahanianLon = 71.6500;
  const lahoreLat = 31.5204;
  const lahoreLon = 74.3587;

  final now = DateTime(2026, 11, 25, 12, 36);

  group('resolveViewerPosition', () {
    test('live fix wins over lastKnown and myMember', () {
      final v = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
        lastKnown: LastLocation(lahoreLat, lahoreLon, now),
        myMember: member('me', 'Me', lat: lahoreLat, lon: lahoreLon),
      );
      expect(v, isNotNull);
      expect(v!.lat, jahanianLat);
      expect(v.lon, jahanianLon);
    });

    test('no live fix -> lastKnown wins over myMember', () {
      final v = resolveViewerPosition(
        lastKnown: LastLocation(jahanianLat, jahanianLon, now),
        myMember: member('me', 'Me', lat: lahoreLat, lon: lahoreLon),
      );
      expect(v, isNotNull);
      expect(v!.lat, jahanianLat);
      expect(v.lon, jahanianLon);
    });

    test('no fix and no cache -> my own published member entry', () {
      final v = resolveViewerPosition(
        myMember: member('me', 'Me', lat: jahanianLat, lon: jahanianLon),
      );
      expect(v, isNotNull);
      expect(v!.lat, jahanianLat);
      expect(v.lon, jahanianLon);
    });

    test('nothing known -> null, never the Lahore demo point', () {
      final v = resolveViewerPosition();
      expect(v, isNull);
      // The old code returned Lahore here on every phone; the new
      // code returns nothing, and callers show '—' instead.
    });

    test('myMember without a location does not count', () {
      expect(
        resolveViewerPosition(myMember: member('me', 'Me')),
        isNull,
      );
    });
  });

  group('formatMemberDistance', () {
    test('REGRESSION (reported bug): same spot in Jahanian reads 0 m, not 295 km', () {
      final viewer = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
      );
      final me = member('me', 'Me', lat: jahanianLat, lon: jahanianLon);
      // The old code measured from Lahore and printed ~295.4 km
      // for this exact pair.
      expect(
        LocationService.distanceKm(
            lahoreLat, lahoreLon, jahanianLat, jahanianLon),
        greaterThan(200),
      );
      expect(formatMemberDistance(viewer: viewer, member: me), '0 m');
    });

    test('member next to the viewer shows metres, not kilometres', () {
      final viewer = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
      );
      final near = member(
        'ali',
        'Ali',
        lat: jahanianLat + 0.0017966,
        lon: jahanianLon,
      );
      expect(formatMemberDistance(viewer: viewer, member: near), '200 m');
    });

    test('member 3.6 km away shows kilometres with one decimal', () {
      final viewer = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
      );
      final far = member(
        'ali',
        'Ali',
        lat: jahanianLat + 0.0323,
        lon: jahanianLon,
      );
      expect(formatMemberDistance(viewer: viewer, member: far), '3.6 km');
    });

    test('viewer position unknown -> dash, never a made-up number', () {
      final m = member('ali', 'Ali', lat: jahanianLat, lon: jahanianLon);
      expect(formatMemberDistance(viewer: null, member: m), '—');
    });

    test('member without a location -> dash', () {
      final viewer = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
      );
      expect(
        formatMemberDistance(viewer: viewer, member: member('ali', 'Ali')),
        '—',
      );
    });

    test('own row reads ~0 m with a fresh fix (no special case)', () {
      final viewer = resolveViewerPosition(
        liveFix: pos(jahanianLat, jahanianLon, now),
      );
      final me = member('me', 'Me', lat: jahanianLat, lon: jahanianLon);
      expect(formatMemberDistance(viewer: viewer, member: me), '0 m');
    });
  });

  group('resolveCacheMyPosition (call overlay my-position)', () {
    test('REQUIRED: live fix preferred over a stale own-member entry', () {
      final freshFix = LastLocation(jahanianLat, jahanianLon, now);
      final staleMe = member('me', 'Me', lat: lahoreLat, lon: lahoreLon)
          .copyWith(lastSeen: now.subtract(const Duration(minutes: 30)));
      // The published entry still says Lahore (last publish 30 min
      // ago); the phone's last fix says Jahanian, right now.
      final p = CallMemberCache.resolveCacheMyPosition(
        myMember: staleMe,
        lastKnown: freshFix,
      );
      expect(p, isNotNull);
      expect(p!.lat, jahanianLat);
      expect(p.lon, jahanianLon);
    });

    test('no lastKnown -> own published member entry', () {
      final p = CallMemberCache.resolveCacheMyPosition(
        myMember: member('me', 'Me', lat: jahanianLat, lon: jahanianLon)
            .copyWith(lastSeen: now),
      );
      expect(p, isNotNull);
      expect(p!.lat, jahanianLat);
    });

    test('member entry has no location -> lastKnown', () {
      final p = CallMemberCache.resolveCacheMyPosition(
        myMember: member('me', 'Me'),
        lastKnown: LastLocation(jahanianLat, jahanianLon, now),
      );
      expect(p, isNotNull);
      expect(p!.lat, jahanianLat);
    });

    test('neither known -> null (overlay shows no distance)', () {
      expect(
        CallMemberCache.resolveCacheMyPosition(myMember: member('me', 'Me')),
        isNull,
      );
    });

    test('fresh member entry beats a stale lastKnown', () {
      final p = CallMemberCache.resolveCacheMyPosition(
        myMember: member('me', 'Me', lat: jahanianLat, lon: jahanianLon)
            .copyWith(lastSeen: now),
        lastKnown: LastLocation(
          lahoreLat,
          lahoreLon,
          now.subtract(const Duration(minutes: 30)),
        ),
      );
      expect(p, isNotNull);
      expect(p!.lat, jahanianLat);
    });

    test('buildJson writes the resolved my-position into the cache', () {
      final json = CallMemberCache.buildJson(
        [
          member('me', 'Me'),
          member('ali', 'Ali', lat: jahanianLat, lon: jahanianLon)
              .copyWith(lastSeen: now),
        ],
        myId: 'me',
        lastKnown: LastLocation(jahanianLat, jahanianLon, now),
      );
      // My member entry has NO location at all — the cache must
      // still carry my real position from the last fix, or the
      // overlay could never show a distance.
      expect(json['myLat'], jahanianLat);
      expect(json['myLon'], jahanianLon);
    });
  });

  group('validateJoinInput (number asked WITH the code)', () {
    test('join without a number is refused', () {
      expect(
        validateJoinInput(code: '660287', phone: ''),
        contains('mobile number'),
      );
      expect(
        validateJoinInput(code: '660287', phone: '   '),
        isNotNull,
      );
    });

    test('join with an email as number is refused', () {
      expect(
        validateJoinInput(
          code: '660287',
          phone: 'mehvisharshadkips@gmail.com',
        ),
        contains('email'),
      );
    });

    test('join with a too-short number is refused', () {
      expect(
        validateJoinInput(code: '660287', phone: '0300123'),
        isNotNull,
      );
    });

    test('join with a bad code is refused even with a good number', () {
      expect(
        validateJoinInput(code: '123', phone: '03001234567'),
        contains('6 digits'),
      );
    });

    test('join with a valid code + valid number is accepted', () {
      expect(
        validateJoinInput(code: '660287', phone: '03001234567'),
        isNull,
      );
      expect(
        validateJoinInput(code: '660287', phone: '+92 300 1234567'),
        isNull,
      );
    });
  });

  group('member phone (v0.6.14 — overlay matching)', () {
    test('Gmail member (phone = email) NEVER matches a SIM number', () {
      const email = 'mehvisharshadkips@gmail.com';
      expect(memberPhoneCanMatchCalls(email), isFalse);
      expect(
        CallMemberCache.phonesMatch(email, '+923001234567'),
        isFalse,
      );
      expect(
        CallMemberCache.phonesMatch(email, '03001234567'),
        isFalse,
      );
    });

    test('after the parent sets a real number, the same call matches (+92 vs 03…)', () {
      const stored = '+923001234567';
      expect(memberPhoneCanMatchCalls(stored), isTrue);
      expect(CallMemberCache.phonesMatch(stored, '+923001234567'), isTrue);
      expect(CallMemberCache.phonesMatch(stored, '03001234567'), isTrue);
      expect(CallMemberCache.phonesMatch(stored, '3001234567'), isTrue);
    });

    test('validation normalizes and rejects', () {
      expect(
        validateMemberPhone('03001234567').number,
        '+923001234567',
      );
      expect(
        validateMemberPhone('+92 300 1234567').number,
        '+923001234567',
      );
      expect(validateMemberPhone('').number, isNull);
      expect(
        validateMemberPhone('mehvisharshadkips@gmail.com').error,
        contains('email'),
      );
      expect(validateMemberPhone('0300abc').error, isNotNull);
      expect(validateMemberPhone('123').error, isNotNull);
    });

    test('child role cannot set a number; parent can, never their own', () {
      expect(
        canSetMemberPhone(
          isAdmin: false,
          myUid: 'child-uid',
          targetMemberId: 'child-uid',
        ),
        isFalse,
      );
      expect(
        canSetMemberPhone(
          isAdmin: true,
          myUid: 'parent-uid',
          targetMemberId: 'parent-uid',
        ),
        isFalse,
      );
      expect(
        canSetMemberPhone(
          isAdmin: true,
          myUid: 'parent-uid',
          targetMemberId: 'child-uid',
        ),
        isTrue,
      );
      expect(
        canSetMemberPhone(
          isAdmin: true,
          myUid: null,
          targetMemberId: 'child-uid',
        ),
        isFalse,
      );
    });
  });
}
