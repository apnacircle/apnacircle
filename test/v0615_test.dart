import 'package:apnacircle/core/osm_map.dart';
import 'package:apnacircle/core/viewer_position.dart';
import 'package:apnacircle/models/member.dart';
import 'package:apnacircle/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// OpenStreetMap replaces Google Maps (v0.6.15, 25 Nov 2026): the
/// map tab was blank because Google Maps needs an API key, and the
/// key needs Google Cloud billing (a card on file). OSM tiles are
/// free, need no key and no card — only internet to fetch them.
/// v0.6.19 tried CARTO's light basemap; v0.6.20 went back to OSM's
/// own tiles — the user found CARTO confusing / worse (26 Nov 2026).
/// These tests pin the pure map layer: tile URLs, member → marker
/// conversion, and the initial camera. Lahore stays ONLY as the
/// camera fallback when no viewer position is known — it is NEVER
/// a distance (that rule is v0.6.14's, tested in v0614_test.dart).
void main() {
  Member member(
    String id,
    String name, {
    double? lat,
    double? lon,
    bool isOnline = true,
  }) =>
      Member(
        id: id,
        name: name,
        phone: '+923000000000',
        lat: lat,
        lon: lon,
        isOnline: isOnline,
      );

  group('OSM tile URL', () {
    test('known z/x/y builds the exact tile URL', () {
      // Zoom 12, tile column 2048, row 1365.
      expect(
        osmTileUrl(z: 12, x: 2048, y: 1365),
        'https://tile.openstreetmap.org/12/2048/1365.png',
      );
    });

    test('template and helper agree for any tile', () {
      const z = 15, x = 12345, y = 9876;
      final fromTemplate = osmTileUrlTemplate
          .replaceAll('{z}', '$z')
          .replaceAll('{x}', '$x')
          .replaceAll('{y}', '$y');
      expect(osmTileUrl(z: z, x: x, y: y), fromTemplate);
    });

    test('tiles come from openstreetmap.org, no key in the URL', () {
      final url = osmTileUrl(z: 10, x: 1, y: 2);
      expect(url, startsWith('https://tile.openstreetmap.org/'));
      expect(url, isNot(contains('key')));
      expect(url, isNot(contains('token')));
    });
  });

  group('member -> marker conversion', () {
    test('keeps every member with a location', () {
      final members = [
        member('u1', 'Ali', lat: 31.5, lon: 74.3),
        member('u2', 'Ammi', lat: 31.6, lon: 74.4, isOnline: false),
        member('u3', 'Me', lat: 31.55, lon: 74.35),
      ];
      final markers = osmMarkersFor(members);
      expect(markers.map((m) => m.id).toList(), ['u1', 'u2', 'u3']);
      expect(markers.first.point, const LatLng(31.5, 74.3));
      expect(markers[1].isOnline, isFalse);
      expect(markers[2].name, 'Me');
    });

    test('drops members with no location (null lat or lon)', () {
      final members = [
        member('u1', 'Ali', lat: 31.5, lon: 74.3),
        member('u2', 'NoLoc'),
        member('u3', 'HalfLoc', lat: 31.5),
        member('u4', 'HalfLoc2', lon: 74.3),
      ];
      final markers = osmMarkersFor(members);
      expect(markers.map((m) => m.id).toList(), ['u1']);
    });

    test('empty member list gives no markers', () {
      expect(osmMarkersFor([]), isEmpty);
    });
  });

  group('initial camera', () {
    test('Lahore fallback ONLY when no viewer position is known', () {
      expect(
        osmInitialCenter(),
        const LatLng(osmMapFallbackLat, osmMapFallbackLon),
      );
      expect(osmMapFallbackLat, 31.5204);
      expect(osmMapFallbackLon, 74.3587);
    });

    test('viewer position wins over the Lahore fallback', () {
      // Jahanian — the v0.6.14 regression spot: the camera must
      // start where the viewer really is, not in Lahore.
      const jahanian = ViewerPosition(29.8067, 71.6481);
      expect(
          osmInitialCenter(viewer: jahanian), const LatLng(29.8067, 71.6481));
      expect(
        osmInitialCenter(viewer: jahanian),
        isNot(const LatLng(osmMapFallbackLat, osmMapFallbackLon)),
      );
    });
  });

  group('attribution + identity constants', () {
    test('required OSM attribution text is present', () {
      expect(osmAttributionText, 'OpenStreetMap contributors');
    });

    test('tile requests identify this app, not a generic client', () {
      expect(osmUserAgentPackageName, 'com.apnacircle.app');
    });
  });

  group('re-join after removal (RTDB rules v2)', () {
    // The rule joinCircle must follow (see resolveJoinRole in
    // sync_service.dart): the member node is written on EVERY
    // join. A live-RTDB test is not possible in this suite — the
    // database handle is not injectable and Firebase Auth cannot
    // sign in here — so the decision itself is pinned here and
    // joinCircle calls it. The real end-to-end proof is a
    // real-phone re-join (see README checklist).
    test('first join writes the member node', () {
      final join = resolveJoinRole(
        existingRole: null,
        requestedRole: 'child',
      );
      expect(join.role, 'child');
      expect(join.writeMemberNode, isTrue);
    });

    test('re-join after removal writes the member node', () {
      // Parent removed me: the member node is gone, but the role
      // entry under users/{uid}/circles survives — so the node
      // MUST be written again, or the re-join "succeeds" and I
      // stay invisible. Under rules v2 ensureMyMemberNode cannot
      // re-create it (its read-first check is denied once
      // membership is gone), so join itself must write it — with
      // no read first.
      final join = resolveJoinRole(
        existingRole: 'child',
        requestedRole: 'child',
      );
      expect(join.role, 'child');
      expect(join.writeMemberNode, isTrue);
    });

    test('a removed child cannot re-join as parent', () {
      // The existing role entry wins over the requested role —
      // asking for 'parent' at re-join does not escalate.
      final join = resolveJoinRole(
        existingRole: 'child',
        requestedRole: 'parent',
      );
      expect(join.role, 'child');
      expect(join.writeMemberNode, isTrue);
    });
  });
}
