import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/call_distance_service.dart';
import '../core/location_service.dart';
import '../models/circle.dart';
import '../models/member.dart';
import '../screens/alerts_screen.dart';
import '../screens/call_overlay_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/locks_screen.dart';
import '../screens/plan_screen.dart';
import '../screens/settings_screen.dart';
import '../services/family_service.dart';
import '../services/notification_service.dart';
import '../services/sms_location_service.dart';
import '../services/sync_service.dart';

/// Home: live map + member cards with distance (km), battery,
/// online/offline + last location. SOS button is always visible.
///
/// NOTE: Google Maps needs an API key in android/app/src/main/
/// AndroidManifest.xml (meta-data com.google.android.geo.API_KEY)
/// and the key restricted to this app. No key is committed here.
///
/// v0.3: this screen also runs the location loop — every 60 s it
/// takes a GPS fix and:
/// * ONLINE + synced: publishes it to the active circle (RTDB),
///   so the other phone sees it live.
/// * OFFLINE (no data): sends it to the parent's number by SMS,
///   at most every 15 min and only when moved >= 50 m
///   (see SmsLocationService). SMS fallback needs the user's OK
///   first — the app explains why, then asks for the SMS
///   permission. Nothing is sent without that OK.
class HomeMapScreen extends StatefulWidget {
  const HomeMapScreen({super.key});
  @override
  State<HomeMapScreen> createState() => _HomeMapScreenState();
}

class _HomeMapScreenState extends State<HomeMapScreen>
    with WidgetsBindingObserver {
  int _tab = 0;

  // My location (Lahore demo default until GPS gives a real fix).
  static const _myLat = 31.5204;
  static const _myLon = 74.3587;

  static const _smsAskedKey = 'sms_fallback_asked';
  static const _smsEnabledKey = 'sms_fallback_enabled';

  Timer? _locationTimer;
  StreamSubscription<bool>? _offlineSub;
  StreamSubscription<SmsLocation>? _smsSub;
  bool _iAmOffline = false;
  bool _smsFallbackOn = false;

  // Bottom padding of the members list, so the floating SOS button
  // can NEVER cover the last member row (v0.6.1: it used to cover
  // Ammi's row). FAB height 56 + 16 bottom margin + 16 spare = 88.
  // With this padding the last row scrolls fully clear of the
  // button on any screen height.
  static const double membersListBottomPadding = 88;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _afterFirstFrame();
    });
  }

  Future<void> _afterFirstFrame() async {
    if (!mounted) return;
    final family = context.read<FamilyService>();
    // Demo family only when NOT synced — in synced mode the
    // members come from the circle (RTDB).
    if (!family.isSynced) family.seedDemoFamily();

    final sms = context.read<SmsLocationService>();
    final prefs = await SharedPreferences.getInstance();
    _smsFallbackOn = prefs.getBool(_smsEnabledKey) ?? false;

    // Incoming SMS locations (parent side): live + pending.
    sms.startListening();
    _smsSub = sms.incoming.listen(_applySmsLocation);
    for (final loc in await sms.fetchPendingSms()) {
      _applySmsLocation(loc);
    }
    _offlineSub = sms.onOfflineChanged.listen((offline) async {
      if (!mounted) return;
      setState(() => _iAmOffline = offline);
      if (offline) await _maybeAskSmsPermission();
    });
    _iAmOffline = await sms.isOffline;
    if (_iAmOffline) await _maybeAskSmsPermission();
    if (mounted) setState(() {});

    // FCM foreground pushes + RTDB circle events (SOS from family).
    if (mounted) {
      context.read<NotificationService>().messages.listen((msg) {
        if (!mounted) return;
        final title = msg.notification?.title ?? 'ApnaCircle alert';
        final body = msg.notification?.body ?? '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title${body.isEmpty ? '' : ' — $body'}')),
        );
      });
      family.circleEvents.listen((event) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              event.type == 'sos'
                  ? 'SOS from ${event.fromName}!'
                  : 'Alert from ${event.fromName}: ${event.type}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      });
    }

    // Location loop: every 60 s (matches the 50 m / 60 s throttle).
    _locationTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => _publishCycle());
    _publishCycle();
  }

  void _applySmsLocation(SmsLocation loc) {
    if (!mounted) return;
    final family = context.read<FamilyService>();
    final applied = family.applySmsLocation(loc.from, loc.lat, loc.lon, loc.at);
    if (applied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Location by SMS from ${loc.from} — ${_fmtTime(loc.at)}',
          ),
        ),
      );
    }
  }

  /// Plain-language explanation BEFORE the SMS permission is
  /// asked (first time the phone goes offline). Nothing is sent
  /// unless the user taps "Turn on".
  Future<void> _maybeAskSmsPermission() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_smsAskedKey) ?? false) return;
    if (!mounted) return;
    await prefs.setBool(_smsAskedKey, true);
    if (!mounted) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No internet — use SMS for location?'),
        content: const Text(
          'Your phone has no data right now, so your live location '
          'cannot reach your family. ApnaCircle can send your GPS '
          'location to your PARENT\'s number by SMS instead — at most '
          'once every 15 minutes, only when you moved. SMS needs '
          'mobile signal and uses your SMS balance. No SMS is ever '
          'sent to anyone except your parent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (enable != true || !mounted) return;
    final granted =
        await context.read<SmsLocationService>().ensureSmsPermission();
    final prefs2 = await SharedPreferences.getInstance();
    await prefs2.setBool(_smsEnabledKey, granted);
    if (mounted) setState(() => _smsFallbackOn = granted);
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'SMS permission was not given — offline location by SMS stays off.',
          ),
        ),
      );
    }
  }

  Future<void> _publishCycle() async {
    if (!mounted) return;
    final family = context.read<FamilyService>();
    final sms = context.read<SmsLocationService>();
    final loc = LocationService();
    final fix = await loc.currentFix();
    if (fix == null) return;
    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {
      battery = -1;
    }
    if (!mounted) return;
    final offline = await sms.isOffline;
    if (mounted) setState(() => _iAmOffline = offline);
    if (offline) {
      // No data: SMS fallback (only when the user turned it on).
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_smsEnabledKey) ?? false)) return;
      await sms.sendOfflineLocationIfNeeded(
        parentPhones: family.parentPhones,
        lat: fix.latitude,
        lon: fix.longitude,
        at: fix.timestamp,
      );
      return;
    }
    // Online: publish to the circle (no-op in demo mode).
    await family.publishSelfLocation(fix.latitude, fix.longitude, battery);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Pick up SMS locations that arrived while the app was closed.
      final sms = context.read<SmsLocationService>();
      sms.fetchPendingSms().then((pending) {
        for (final loc in pending) {
          _applySmsLocation(loc);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationTimer?.cancel();
    _offlineSub?.cancel();
    _smsSub?.cancel();
    super.dispose();
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
                    : 'Last seen: ${_fmtTime(m.lastSeen)}',
              ),
            ),
      };

  static String _fmtTime(DateTime? t) {
    if (t == null) return '—';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

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
              // v0.6.1: was Icons.sos — that icon IS the letters "SOS",
              // so next to the "SOS" label the button read "SOS SOS".
              // Icons.emergency is a siren glyph, so the label "SOS"
              // now appears exactly once.
              icon: const Icon(Icons.emergency),
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
          if (_iAmOffline)
            Container(
              width: double.infinity,
              color: Colors.orange.shade100,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: Text(
                _smsFallbackOn
                    ? 'You are offline (no data). Location is sent to your parent by SMS, every 15 min.'
                    : 'You are offline (no data). Turn on SMS location in Settings to keep sharing.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
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
              // Bottom padding clears the floating SOS button —
              // see membersListBottomPadding above.
              padding: const EdgeInsets.only(
                bottom: membersListBottomPadding,
              ),
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
    // Honest offline state (v0.3): last location + when it was
    // last seen + how it arrived (live / SMS / nothing since off).
    final String status;
    if (m.locationViaSms) {
      status = 'SMS se aayi · ${_fmtTime(m.lastSeen)} · $distance away';
    } else if (m.isOnline) {
      status = 'Online · $distance away · Battery ${m.battery}%';
    } else {
      status = 'Offline since ${_fmtTime(m.lastSeen)} · $distance away';
    }
    return ListTile(
      leading: CircleAvatar(child: Text(m.name[0])),
      title: Text(m.name),
      subtitle: Text(status),
      trailing: m.locationSharingOn
          ? const Icon(Icons.location_on, color: Colors.green)
          : const Icon(Icons.location_off, color: Colors.red),
    );
  }

  Future<void> _sendSos(BuildContext context) async {
    final family = context.read<FamilyService>();
    final sync = context.read<SyncService>();
    final mine = family.myMember;
    // v0.3: the SOS event goes to the whole circle (RTDB) so the
    // parent's phone gets it live; FCM push for the same event
    // needs a server (see NotificationService — not faked here).
    if (sync.isAvailable && sync.activeCircleId != null && mine != null) {
      await sync.sendEvent(
        sync.activeCircleId!,
        CircleEvent(
          type: 'sos',
          fromUid: mine.id,
          fromName: mine.name,
          at: DateTime.now(),
          lat: mine.lat,
          lon: mine.lon,
        ),
      );
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('SOS sent to your family!')),
    );
  }
}
