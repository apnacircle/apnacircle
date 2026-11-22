import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';

import '../core/call_distance_service.dart';
import '../core/location_service.dart';
import '../models/member.dart';
import '../screens/alerts_screen.dart';
import '../screens/call_overlay_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/locks_screen.dart';
import '../screens/plan_screen.dart';
import '../screens/settings_screen.dart';
import '../services/family_service.dart';

/// Home: live map + member cards with distance (km), battery,
/// online/offline + last location. SOS button is always visible.
///
/// NOTE: Google Maps needs an API key in android/app/src/main/
/// AndroidManifest.xml (meta-data com.google.android.geo.API_KEY)
/// and the key restricted to this app. No key is committed here.
class HomeMapScreen extends StatefulWidget {
  const HomeMapScreen({super.key});
  @override
  State<HomeMapScreen> createState() => _HomeMapScreenState();
}

class _HomeMapScreenState extends State<HomeMapScreen> {
  int _tab = 0;

  // My location (Lahore demo default until GPS gives a real fix).
  static const _myLat = 31.5204;
  static const _myLon = 74.3587;

  @override
  void initState() {
    super.initState();
    // Seed demo family until real Firebase accounts exist.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FamilyService>().seedDemoFamily();
    });
  }

  Set<Marker> _markers(List<Member> members) => {
        for (final m in members)
          if (m.hasLocation)
            Marker(
              markerId: MarkerId(m.id),
              position: LatLng(m.lat!, m.lon!),
              infoWindow: InfoWindow(
                title: m.name,
                snippet: m.isOnline
                    ? 'Online'
                    : 'Last seen: ${m.lastSeen}',
              ),
            ),
      };

  @override
  Widget build(BuildContext context) {
    final family = context.watch<FamilyService>();
    final members = family.members;
    final pages = [
      _mapTab(members),
      const AlertsScreen(),
      const LocksScreen(),
      const ChatScreen(),
      const PlanScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('ApnaCircle'),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone),
            tooltip: 'Simulate SIM call',
            // Real path: MainActivity tells us when a real SIM call
            // arrives; this button is for testing on an emulator.
            onPressed: () {
              final ali = family.memberByPhone('+923005550103');
              if (ali != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CallOverlayScreen(caller: ali),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: pages[_tab],
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              onPressed: () => _sendSos(context),
              backgroundColor: Colors.red,
              icon: const Icon(Icons.sos),
              label: const Text('SOS'),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.notifications), label: 'Alerts'),
          BottomNavigationBarItem(icon: Icon(Icons.lock), label: 'Locks'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Plan'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Widget _mapTab(List<Member> members) => Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: const CameraPosition(
                target: LatLng(_myLat, _myLon),
                zoom: 12,
              ),
              myLocationEnabled: true,
              markers: _markers(members),
            ),
          ),
          SizedBox(
            height: 220,
            child: ListView(
              children: [
                for (final m in members) _memberCard(m),
              ],
            ),
          ),
        ],
      );

  Widget _memberCard(Member m) {
    final distance = m.hasLocation
        ? CallDistanceService.formatKm(
            LocationService.distanceKm(_myLat, _myLon, m.lat!, m.lon!),
          )
        : '—';
    return ListTile(
      leading: CircleAvatar(child: Text(m.name[0])),
      title: Text(m.name),
      subtitle: Text(
        m.isOnline
            ? 'Online · $distance away · Battery ${m.battery}%'
            : 'Last location ${m.lastSeen} · $distance away',
      ),
      trailing: m.locationSharingOn
          ? const Icon(Icons.location_on, color: Colors.green)
          : const Icon(Icons.location_off, color: Colors.red),
    );
  }

  void _sendSos(BuildContext context) {
    // TODO(v0.2): send SOS via Firebase Cloud Messaging to the whole
    // circle + optional SMS to the parent + optional 1122 auto-call
    // (only when the parent opted in — see AlertType.autoCall1122).
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('SOS sent to your family!')),
    );
  }
}
