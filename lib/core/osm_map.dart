import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import 'viewer_position.dart';

/// Map helpers (v0.6.15 OpenStreetMap, v0.6.19 CARTO tiles) — pure,
/// tested.
///
/// v0.6.15 replaced Google Maps with OpenStreetMap: the map tab was
/// blank because Google Maps needs an API key, and the key needs
/// Google Cloud billing (a card on file). v0.6.19 keeps the free,
/// no-key idea but renders the OSM data through CARTO's light
/// basemap instead of OSM's own tiles — same data, cleaner streets
/// and labels, which is what the user asked for (26 Nov 2026: the
/// OSM map "is not a proper map"). Tiles are free, need no key and
/// no card — the app only needs internet to fetch them (same as
/// Google Maps did: offline shows no tiles, the members list still
/// works). Tile use must show the attribution "© OpenStreetMap
/// contributors, © CARTO" (see [osmAttributionText]) — the map
/// screen shows it as a permanent overlay, bottom-left.
///
/// Lahore ([osmMapFallbackLat]/[osmMapFallbackLon]) is the map's
/// INITIAL CAMERA fallback only — used when no viewer position is
/// known yet. It is NEVER a distance: distances use ViewerPosition
/// (see viewer_position.dart), exactly as in v0.6.14.

/// Tile URL template: {s} = CARTO subdomain (a/b/c),
/// {z} = zoom, {x} = column, {y} = row.
const String osmTileUrlTemplate =
    'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';

/// User-Agent package sent with tile requests (tile usage policies
/// ask clients to identify themselves).
const String osmUserAgentPackageName = 'com.apnacircle.app';

/// Required attribution text (the screen prepends '© ').
const String osmAttributionText = 'OpenStreetMap contributors, © CARTO';

/// Lahore — initial camera fallback ONLY (see above).
const double osmMapFallbackLat = 31.5204;
const double osmMapFallbackLon = 74.3587;

/// Default zoom for the initial camera.
const double osmMapInitialZoom = 12.0;

/// Tile URL for one tile: [z] = zoom, [x] = column, [y] = row.
/// Subdomain 'a' — flutter_map picks a/b/c itself from the
/// template at runtime.
String osmTileUrl({required int z, required int x, required int y}) =>
    'https://a.basemaps.cartocdn.com/light_all/$z/$x/$y.png';

/// One map marker's data — a member WITH a location.
class OsmMarkerData {
  final String id;
  final String name;
  final LatLng point;
  final bool isOnline;

  const OsmMarkerData({
    required this.id,
    required this.name,
    required this.point,
    required this.isOnline,
  });
}

/// One marker per member WITH a location. Members with no location
/// never get a marker — same rule as the old Google markers.
List<OsmMarkerData> osmMarkersFor(List<Member> members) => [
      for (final m in members)
        if (m.hasLocation)
          OsmMarkerData(
            id: m.id,
            name: m.name,
            point: LatLng(m.lat!, m.lon!),
            isOnline: m.isOnline,
          ),
    ];

/// The map's initial centre: the viewer's live position when known,
/// else the Lahore fallback — the fallback is ONLY a camera start
/// point, never a distance.
LatLng osmInitialCenter({ViewerPosition? viewer}) => viewer != null
    ? LatLng(viewer.lat, viewer.lon)
    : const LatLng(osmMapFallbackLat, osmMapFallbackLon);
