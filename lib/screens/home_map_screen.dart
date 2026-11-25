import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alert_notification.dart';
import '../core/app_lock_service.dart';
import '../core/chat_notification.dart';
import '../core/location_service.dart';
import '../core/osm_map.dart';
import '../core/protection_level.dart';
import '../core/viewer_position.dart';
import '../models/circle.dart';
import '../models/member.dart';
import '../screens/alerts_screen.dart';
import '../screens/call_overlay_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/locks_screen.dart';
import '../screens/location_status_card.dart';
import '../screens/plan_screen.dart';
import '../screens/settings_screen.dart';
import '../services/background_location_service.dart';
import '../services/family_service.dart';
import '../services/notification_service.dart';
import '../services/sms_location_service.dart';
import '../services/sync_service.dart';

/// Home: live map + member cards with distance (km), battery,
/// online/offline + last location. SOS button is always visible.
///
/// NOTE (v0.6.15): the map is OpenStreetMap (flutter_map) — free,
/// no API key, no card. Google Maps was removed because the map tab
/// was blank without a key, and the key needs Google Cloud billing.
/// Tiles need internet (offline shows no tiles; the members list
/// still works). Attribution "© OpenStreetMap contributors" is
/// shown on the map, bottom-left (OSM licence).
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

  // Map camera fallback — Lahore, in lib/core/osm_map.dart
  // (osmMapFallbackLat/osmMapFallbackLon). It is the initial camera
  // ONLY, before GPS answers. NEVER used for a distance (v0.6.14:
  // distances were measured from this hardcoded Lahore point on
  // every phone, so a user in Jahanian saw everyone as
  // "295.4 km away"). Distances use [_viewerPosition] instead.

  // THIS phone's own position, resolved live (v0.6.14): the
  // foreground loop's fresh fix, else the last known fix, else my
  // own published member entry. Null = unknown — member rows show
  // '—' until it is known, never a made-up number.
  ViewerPosition? _viewerPosition;

  // v0.6.15: OpenStreetMap camera controller — follow-me button,
  // member-card tap-to-centre, and the one-time centre on the
  // first viewer fix. [_mapReady] is set by onMapReady; moves
  // before the map mounts are skipped, never forced.
  final _mapController = MapController();
  bool _mapReady = false;

  static const _smsAskedKey = 'sms_fallback_asked';
  static const _smsEnabledKey = 'sms_fallback_enabled';
  static const _batteryOptAskedKey = 'battery_opt_asked';

  // v0.6.4: background location sharing state on THIS phone
  // (null = still checking) + whether the foreground service is
  // running. Shown in the status card at the top of the Map tab.
  LocationSharingState? _sharingState;
  bool _serviceRunning = false;

  // v0.6.9: the parent's Location Lock for ME (from my locks node
  // — see _ensureLockSubscription). When it is on and sharing is
  // not "always", the status card says the parent locked it, so
  // the child sees they must turn sharing back on. Admins never
  // enforce their own locks, so this stays false on a parent phone.
  bool _myLocationLocked = false;

  // v0.6.4: which circle+user the background service was last
  // (re)started for — re-run only when the circle changes, so a
  // provider rebuild does not re-check permissions every frame.
  String? _bgSharingKey;

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

  // v0.6.3: which circle+user the child-side lock subscription is
  // running for. Home is the landing screen after every login, so
  // this (not the Locks tab) is where lock enforcement starts.
  String? _lockSubscribedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _afterFirstFrame();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The active circle can change after Home is already mounted
    // (fresh sign-in / circle switch) — re-check the subscription.
    _ensureLockSubscription();
    // v0.6.4: same for background location — a circle switch
    // restarts the service so it publishes to the new circle.
    _ensureBackgroundSharingForCurrentCircle();
  }

  /// Child-side lock enforcement (v0.6.3): subscribe to MY locks
  /// and hand them to native code. Before this, the ONLY subscriber
  /// was LocksScreen — so if the child never opened the Locks tab,
  /// applyLocks never ran and the native service had no rules.
  /// Admins never enforce their own locks; the parent's phone only
  /// publishes them. Idempotent: keyed on circle+user, so a
  /// rebuild or a second call does not double-subscribe.
  void _ensureLockSubscription() {
    if (!mounted) return;
    final sync = context.read<SyncService>();
    if (!sync.isAvailable ||
        sync.activeCircleId == null ||
        sync.uid == null) {
      return;
    }
    if (sync.activeCircle?.isAdmin == true) return;
    final key = '${sync.activeCircleId}|${sync.uid}';
    if (_lockSubscribedFor == key) return;
    _lockSubscribedFor = key;
    final circleId = sync.activeCircleId!;
    final uid = sync.uid!;
    // Apply the current list at once — do not wait for the first
    // remote event (e.g. after an app restart).
    sync.getLocksOnce(circleId, uid).then((settings) {
      final apps = settings?.apps ?? const [];
      if (apps.isNotEmpty) AppLockService.applyLocks(apps);
      // v0.6.9: the parent's Location Lock for me — the status card
      // shows it (below), so the child sees the lock is on.
      if (mounted) {
        setState(() => _myLocationLocked = settings?.locationLocked ?? false);
      }
    });
    sync.subscribeLocks(circleId, uid, (incoming) {
      AppLockService.applyLocks(incoming.apps);
      if (mounted) {
        setState(() => _myLocationLocked = incoming.locationLocked);
      }
    });
  }

  /// Background location (v0.6.4): re-check the sharing state +
  /// service state shown in the status card.
  Future<void> _checkSharingState() async {
    final state = await LocationService().sharingState();
    final running = await BackgroundLocationService.isRunning;
    if (mounted) {
      setState(() {
        _sharingState = state;
        _serviceRunning = running;
      });
    }
  }

  /// Background location (v0.6.4): (re)start or stop the
  /// foreground service for the CURRENT circle only. Keyed on
  /// circle+user so a rebuild does not re-check permissions every
  /// time — a circle switch is the only thing that re-runs it.
  void _ensureBackgroundSharingForCurrentCircle() {
    if (!mounted) return;
    final sync = context.read<SyncService>();
    final key = sync.isAvailable && sync.activeCircleId != null
        ? '${sync.activeCircleId}|${sync.uid}'
        : null;
    if (key == null) {
      if (_bgSharingKey != null) {
        _bgSharingKey = null;
        unawaited(BackgroundLocationService.stop());
      }
      return;
    }
    if (key == _bgSharingKey) return;
    _bgSharingKey = key;
    unawaited(_ensureBackgroundSharing());
  }

  /// Start (or stop) the background service for the current login,
  /// then update the card. The service runs only with "Allow all
  /// the time" — with while-in-use/off it is stopped, never left
  /// running uselessly with a permanent notification.
  Future<void> _ensureBackgroundSharing() async {
    if (!mounted) return;
    final sync = context.read<SyncService>();
    final family = context.read<FamilyService>();
    // Android 13+: the service's permanent notification needs the
    // notification permission. Best effort — sharing starts either
    // way (see LocationService.ensureNotificationPermission).
    await LocationService().ensureNotificationPermission();
    final running = await BackgroundLocationService.ensureRunning(
      sync: sync,
      displayName: family.myMember?.name ?? 'Me',
    );
    if (mounted) setState(() => _serviceRunning = running);
    if (running) await _maybeAskBatteryOptimization();
  }

  /// Ask ONCE about the battery-optimization exemption (a phone
  /// that silently kills the background service is worse than one
  /// dialog). Only asked when the service is actually running.
  Future<void> _maybeAskBatteryOptimization() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_batteryOptAskedKey) ?? false) return;
    if (!mounted) return;
    await prefs.setBool(_batteryOptAskedKey, true);
    if (!mounted) return;
    final turnOff = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep location sharing running?'),
        content: const Text(
          'Some phones stop apps running in the background to save '
          'battery. Turn off battery optimization for ApnaCircle so '
          'your family can keep seeing your location when the app '
          'is closed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (turnOff == true && mounted) {
      await LocationService().requestBatteryOptimizationExemption();
    }
  }

  /// The "Turn on always" fix flow from the status card.
  ///
  /// 1. No permission at all -> ask for while-in-use first (the
  ///    system dialog can grant that much).
  /// 2. While-in-use -> show the plain-words reason FIRST (Play
  ///    Store rule), then open the app's Settings page, where the
  ///    user picks "Allow all the time". On Android 11+ no dialog
  ///    can grant it — Settings is the only way.
  /// 3. Already "always" -> just make sure the service is running.
  /// Coming back from Settings is a resume, and
  /// didChangeAppLifecycleState re-checks the state + starts the
  /// service then.
  Future<void> _fixLocationSharing() async {
    final loc = LocationService();
    var state = await loc.sharingState();
    if (state == LocationSharingState.off) {
      final p = await loc.ensureWhileInUse();
      state = locationStateFromPermission(p);
      if (state == LocationSharingState.off) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Location permission is needed to share your location with your family.',
            ),
          ),
        );
        return;
      }
    }
    if (state == LocationSharingState.whileInUse) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Share location even when the app is closed?'),
          content: const Text(
            'Your parent needs to see your location anytime, even '
            'when ApnaCircle is closed — for example if you are on '
            'your way home late. On the next screen, tap Location '
            'and choose "Allow all the time". ApnaCircle only shares '
            'your location with your own family circle, nobody else.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (go == true && mounted) await loc.openAppSettings();
      return;
    }
    await _ensureBackgroundSharing();
    await _checkSharingState();
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
      final notifications = context.read<NotificationService>();
      notifications.messages.listen((msg) {
        if (!mounted) return;
        final title = msg.notification?.title ?? 'ApnaCircle alert';
        final body = msg.notification?.body ?? '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$title${body.isEmpty ? '' : ' — $body'}')),
        );
      });
      // v0.6.10: tapping an alert notification opens the Alerts tab.
      // v0.6.11: tapping a chat notification opens the Chat tab.
      // A tap that arrived before Home was listening (cold start)
      // is drained from the pending slot once, below.
      notifications.tapRequests.listen((payload) {
        if (!mounted) return;
        if (payload == AlertNotifications.tapPayload) {
          setState(() => _tab = 1);
        }
        if (payload == ChatNotifications.tapPayload) {
          setState(() => _tab = 3);
        }
      });
      final pendingTap = notifications.takePendingTap();
      if (pendingTap == AlertNotifications.tapPayload) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _tab = 1);
        });
      }
      if (pendingTap == ChatNotifications.tapPayload) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _tab = 3);
        });
      }
      family.circleEvents.listen((event) {
        if (!mounted) return;
        // v0.6.10: ring LOUD on top of the red banner — an SOS must
        // be heard without staring at the screen. Deduped against
        // the FCM path in NotificationService (same alert rings
        // once). The SnackBar stays as the in-app visual.
        unawaited(notifications.showAlertFromEvent(event));
        // v0.6.9: plain words, not raw type names — a parent
        // reading "internetOff" would not know what it means.
        final label = switch (event.type) {
          'sos' => 'SOS from ${event.fromName}!',
          'internetOff' =>
            'Internet was switched off on ${event.fromName}\'s phone',
          'locationOff' =>
            'Location was switched off on ${event.fromName}\'s phone',
          'lowBattery' => 'Low battery on ${event.fromName}\'s phone',
          'phoneOff' => '${event.fromName}\'s phone was switched off',
          _ => 'Alert from ${event.fromName}: ${event.type}',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(label),
            backgroundColor: Colors.red,
          ),
        );
      });
      // v0.6.11: family chat notifications — a new message from
      // another member rings on the normal chat channel (sender
      // name + preview, like WhatsApp). Own messages are already
      // filtered in FamilyService; the open-chat suppression lives
      // in NotificationService (ChatScreen sets openChatCircleId).
      family.newChatMessages.listen((msg) {
        if (!mounted) return;
        final circleId = family.activeCircleId;
        if (circleId == null) return;
        unawaited(
          notifications.showChatMessage(msg, circleId: circleId),
        );
      });
    }

    // Location loop: every 60 s (matches the 50 m / 60 s throttle).
    _locationTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => _publishCycle());
    _publishCycle();

    // Child-side App Lock enforcement (v0.6.3) — see
    // _ensureLockSubscription: Home is the landing screen, so locks
    // are applied at startup and on every remote change, even if
    // the child never opens the Locks tab.
    _ensureLockSubscription();

    // Background location (v0.6.4): show the sharing state on this
    // phone and keep the foreground service in the right state.
    // Before v0.6.4 the app only fetched location while the Map
    // screen was open, so members went stale the moment the app
    // went to background.
    _checkSharingState();
    _ensureBackgroundSharingForCurrentCircle();
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
    // The battery is read on EVERY cycle, even when there is no
    // new fix: it is published on its own schedule (v0.6.6) and
    // must not be dropped together with a missing/throttled fix.
    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {
      battery = -1;
    }
    if (!mounted) return;
    // v0.6.14: feed the fix into the viewer position, so member
    // distances are measured from THIS phone, not from Lahore.
    // Runs on every cycle, online or offline — the viewer position
    // is local and never needs data.
    await _refreshViewerPosition(fix: fix);
    final offline = await sms.isOffline;
    if (mounted) setState(() => _iAmOffline = offline);
    if (offline) {
      if (fix == null) return;
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
    // Online: no GPS fix right now, but the battery is still
    // readable — share it on its own schedule (v0.6.6) instead of
    // dropping it with the missing fix.
    if (fix == null) {
      await family.publishSelfBattery(battery);
      return;
    }
    // Online: publish to the circle (no-op in demo mode).
    await family.publishSelfLocation(fix.latitude, fix.longitude, battery);
  }

  /// Resolve THIS phone's position for the member distances
  /// (v0.6.14): a fresh fix wins; with no fix, keep the live one
  /// we already have; with none yet, fall back to the last known
  /// fix, then to my own published member entry. Never Lahore.
  Future<void> _refreshViewerPosition({Position? fix}) async {
    if (!mounted) return;
    if (fix != null) {
      final hadViewer = _viewerPosition != null;
      setState(
        () => _viewerPosition = resolveViewerPosition(liveFix: fix),
      );
      // v0.6.15: first fix — centre the map on where I really am.
      // Before this the camera stayed on the Lahore fallback until
      // the user dragged it. Once only: later fixes never yank
      // the camera while the user is looking at a member.
      if (!hadViewer) _centreOnViewer();
      return;
    }
    if (_viewerPosition != null) return;
    final family = context.read<FamilyService>();
    final last = await LocationService().lastKnown();
    if (!mounted) return;
    setState(
      () => _viewerPosition = resolveViewerPosition(
        lastKnown: last,
        myMember: family.myMember,
      ),
    );
    if (_viewerPosition != null) _centreOnViewer();
  }

  /// Move the map camera. Skipped (never forced) before the map is
  /// mounted — the controller has no map to move yet.
  void _moveCamera(LatLng point, double zoom) {
    if (!_mapReady || !mounted) return;
    try {
      _mapController.move(point, zoom);
    } catch (_) {
      // A move on a disposed/unmounted controller is a no-op for
      // the user — the map simply stays where it is.
    }
  }

  /// Follow-me: centre on THIS phone's live position. With no
  /// viewer position yet, take a fresh fix first.
  Future<void> _centreOnViewer() async {
    final viewer = _viewerPosition;
    if (viewer != null) {
      _moveCamera(LatLng(viewer.lat, viewer.lon), 14);
      return;
    }
    final fix = await LocationService().currentFix();
    if (!mounted) return;
    if (fix != null) {
      setState(
        () => _viewerPosition = resolveViewerPosition(liveFix: fix),
      );
      _moveCamera(LatLng(fix.latitude, fix.longitude), 14);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your location is not known yet.'),
        ),
      );
    }
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
      // v0.6.4: the user may have just come back from Settings
      // ("Allow all the time") — re-check the sharing state and
      // start the background service if it is now allowed.
      _checkSharingState();
      _ensureBackgroundSharingForCurrentCircle();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapController.dispose();
    _locationTimer?.cancel();
    _offlineSub?.cancel();
    _smsSub?.cancel();
    super.dispose();
  }

  /// One marker per member WITH a location (v0.6.15, flutter_map).
  /// Same rule as the old Google markers: members with no location
  /// get no marker. Tap a marker to centre the map on that member.
  /// My own member row IS my position — there is no separate blue
  /// dot (Google's myLocationEnabled); the follow-me button centres
  /// on it.
  List<Marker> _markers(List<Member> members) => [
        for (final d in osmMarkersFor(members))
          Marker(
            point: d.point,
            width: 44,
            height: 44,
            child: GestureDetector(
              onTap: () => _moveCamera(d.point, 14),
              child: CircleAvatar(
                backgroundColor:
                    d.isOnline ? Colors.green : Colors.grey,
                child: Text(
                  d.name[0],
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
      ];

  static String _fmtTime(DateTime? t) {
    if (t == null) return '—';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Build ONLY the selected tab (v0.6.7). Before this, `build()`
  /// called `_mapTab(members)` on EVERY build — constructing the
  /// FlutterMap widget, computing all markers and building every
  /// member card — even while the user was on Chat, Locks or
  /// Settings. The map platform view was never mounted for other
  /// tabs, but the widget subtree + marker work was wasted on
  /// every setState. The selected tab renders exactly as before.
  Widget _pageFor(int tab, List<Member> members) {
    switch (tab) {
      case 0:
        return _mapTab(members);
      case 1:
        return const AlertsScreen();
      case 2:
        return const LocksScreen();
      case 3:
        return const ChatScreen();
      case 4:
        return const PlanScreen();
      default:
        return const SettingsScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final family = context.watch<FamilyService>();
    final members = family.members;
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
                    builder: (_) => CallOverlayScreen(
                      caller: ali,
                      viewerPosition: _viewerPosition,
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: _pageFor(_tab, members),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: LocationStatusCard(
              state: _sharingState,
              serviceRunning: _serviceRunning,
              locationLocked: _myLocationLocked,
              onFix: _fixLocationSharing,
              onRefresh: () {
                unawaited(_checkSharingState());
                unawaited(_ensureBackgroundSharing());
              },
            ),
          ),
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
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter:
                        osmInitialCenter(viewer: _viewerPosition),
                    initialZoom: osmMapInitialZoom,
                    onMapReady: () => _mapReady = true,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: osmTileUrlTemplate,
                      userAgentPackageName: osmUserAgentPackageName,
                    ),
                    MarkerLayer(markers: _markers(members)),
                  ],
                ),
                // Required OSM attribution — always visible,
                // bottom-left (OSM licence).
                Positioned(
                  left: 6,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    color: Colors.white70,
                    child: const Text(
                      '© $osmAttributionText',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                ),
                // Follow-me: centre the map on my live position.
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'follow_me',
                    onPressed: () => unawaited(_centreOnViewer()),
                    tooltip: 'Centre on me',
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
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
    // v0.6.14: measured from THIS phone's live position — never
    // from the old hardcoded Lahore point. '—' while the viewer's
    // position is still unknown.
    final distance = formatMemberDistance(
      viewer: _viewerPosition,
      member: m,
    );
    // Honest offline state (v0.3): last location + when it was
    // last seen + how it arrived (live / SMS / nothing since off).
    final String status;
    if (m.locationViaSms) {
      status = 'SMS se aayi · ${_fmtTime(m.lastSeen)} · $distance away';
    } else if (m.isOnline) {
      // Unknown battery (-1) shows no battery part at all — never
      // "-1%" (v0.6.2). A real level keeps showing "Battery 81%".
      // A level older than 30 minutes is marked "(old)" so a stale
      // value is never mistaken for a live one (v0.6.6).
      final batteryPart = m.hasKnownBattery
          ? (m.batteryIsStale ? '${m.batteryLabel} (old)' : m.batteryLabel)
          : '';
      status = batteryPart.isEmpty
          ? 'Online · $distance away'
          : 'Online · $distance away · $batteryPart';
    } else {
      status = 'Offline since ${_fmtTime(m.lastSeen)} · $distance away';
    }
    // v0.6.13 (C): uninstall-protection level, when known — the
    // parent sees at a glance which child can uninstall and which
    // cannot. Unknown shows nothing (never a guess).
    final protectionLabel = m.protection.label;
    final fullStatus = protectionLabel.isEmpty
        ? status
        : '$status · $protectionLabel';
    // v0.6.13 (D): "child gayab" notice — a CHILD with no update
    // for 2+ hours. No loud notification (no-data is common);
    // a clear line on the row, keeping "Offline since [time]".
    final now = DateTime.now();
    final showMissing = shouldShowMissingWarning(
      role: m.role,
      isOnline: m.isOnline,
      lastSeen: m.lastSeen,
      now: now,
    );
    return ListTile(
      // v0.6.15: tap a member's row to centre the map on them.
      onTap: m.hasLocation
          ? () => _moveCamera(LatLng(m.lat!, m.lon!), 14)
          : null,
      leading: CircleAvatar(child: Text(m.name[0])),
      title: Text(m.name),
      subtitle: showMissing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fullStatus),
                Text(
                  missingWarningText(m.lastSeen!, now),
                  style: const TextStyle(color: Colors.orange),
                ),
              ],
            )
          : Text(fullStatus),
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
