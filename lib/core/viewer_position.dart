import 'package:geolocator/geolocator.dart';

import '../models/member.dart';
import 'call_distance_service.dart';
import 'location_service.dart';

/// The VIEWING phone's own position — measured live, never a
/// hardcoded demo point.
///
/// BUG (v0.6.14, 25 Nov 2026): every member distance on the Map
/// tab was measured from a hardcoded Lahore point
/// (31.5204, 74.3587) — `static const _myLat/_myLon` in
/// HomeMapScreen — on EVERY phone. The user in Jahanian
/// (~295 km from Lahore) saw himself and everyone at home as
/// "295.4 km away", and the call-overlay preview had the same
/// constants. The Haversine helper itself was correct; the
/// "from" point was not. The native SIM-call overlay was never
/// affected: it reads myLat/myLon from the member cache, which
/// Dart writes from my own (real) member entry.
class ViewerPosition {
  final double lat;
  final double lon;
  const ViewerPosition(this.lat, this.lon);
}

/// Resolve the viewer's position, most-live first:
/// 1. a fresh GPS fix ([liveFix])
/// 2. the phone's last known fix ([lastKnown] — same phone, same spot)
/// 3. my own published member entry ([myMember] — the location the
///    family already sees for me)
/// 4. null — unknown. Callers must show '—', never fall back to a
///    demo city for a distance.
ViewerPosition? resolveViewerPosition({
  Position? liveFix,
  LastLocation? lastKnown,
  Member? myMember,
}) {
  if (liveFix != null) {
    return ViewerPosition(liveFix.latitude, liveFix.longitude);
  }
  if (lastKnown != null) {
    return ViewerPosition(lastKnown.lat, lastKnown.lon);
  }
  final m = myMember;
  if (m != null && m.hasLocation) {
    return ViewerPosition(m.lat!, m.lon!);
  }
  return null;
}

/// Distance text for one member row, measured from the VIEWING
/// phone. '—' when the member has no location OR the viewer's
/// position is unknown — a made-up number is worse than none.
/// The viewer's OWN row reads ~0 m when its published location is
/// fresh: it follows naturally from a live viewer position, with
/// no special case (a moving phone honestly shows the small lag
/// between its live fix and its last published fix).
String formatMemberDistance({
  required ViewerPosition? viewer,
  required Member member,
}) {
  if (!member.hasLocation || viewer == null) return '—';
  return CallDistanceService.formatKm(
    LocationService.distanceKm(viewer.lat, viewer.lon, member.lat!, member.lon!),
  );
}
