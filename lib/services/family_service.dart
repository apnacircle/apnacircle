import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alerts.dart';
import '../core/call_member_cache.dart';
import '../core/constants.dart';
import '../models/circle.dart';
import '../models/member.dart';
import 'sync_service.dart';

/// Family circle state: members (MAX 10), alerts, places.
///
/// TWO storage modes (v0.3, 22 Nov 2026):
/// * DEMO mode (no Firebase project / nobody signed in): everything
///   is local SharedPreferences, exactly like v0.2. The demo family
///   is seeded on first run.
/// * SYNCED mode (Firebase configured + signed in + an active
///   circle): the Realtime Database is the source of truth for the
///   member list. Local writes are ALSO pushed to RTDB, so a parent
///   changing a lock/alert on the parent phone updates the child's
///   phone live. The public API of this class is unchanged — the
///   screens do not need rewriting.
///
/// Multi-circle: [activeCircleId] comes from SyncService. A user
/// can be a member of one circle and admin of others; the role is
/// per circle (see CircleInfo / SyncService).
class FamilyService extends ChangeNotifier {
  static const _membersKey = 'family_members_v1';

  final List<Member> _members = [];
  List<Member> get members => List.unmodifiable(_members);
  int get memberCount => _members.length;
  bool get isFull => _members.length >= AppConstants.maxFamilyMembers;

  Member? get me => _members.isEmpty ? null : _members.first;

  /// My own member entry: by Firebase uid when synced, else the
  /// first (local demo) member.
  Member? get myMember {
    final sync = _sync;
    if (sync != null && sync.isAvailable && sync.uid != null) {
      for (final m in _members) {
        if (m.id == sync.uid) return m;
      }
      return null;
    }
    return me;
  }

  /// Parent phone numbers in the active circle (for the offline
  /// SMS fallback — SMS goes ONLY to these numbers).
  List<String> get parentPhones => _members
      .where((m) => m.isParent && m.phone.isNotEmpty)
      .map((m) => m.phone)
      .toList();

  // --- Sync wiring ---

  SyncService? _sync;

  /// True when live sync is active: Firebase configured, signed
  /// in, and an active circle is selected.
  bool get isSynced =>
      _sync != null && _sync!.isAvailable && _sync!.activeCircleId != null;

  String? get activeCircleId => _sync?.activeCircleId;

  final _eventsController = StreamController<CircleEvent>.broadcast();

  /// SOS / battery / phone-off events arriving from the circle
  /// (other members' phones). The Home screen listens and shows
  /// them as an alert.
  Stream<CircleEvent> get circleEvents => _eventsController.stream;

  bool _subscribed = false;

  void attachSync(SyncService sync) {
    _sync = sync;
  }

  /// Add a member. Returns false (and adds nobody) when the circle
  /// is already full at 10 — enforced here AND on the server.
  /// In synced mode the member node is also written to RTDB.
  bool addMember(Member member) {
    if (isFull) return false;
    if (_members.any((m) => m.phone == member.phone)) return false;
    _members.add(member);
    _save();
    _pushMemberNode(member);
    notifyListeners();
    return true;
  }

  bool removeMember(String id) {
    final before = _members.length;
    _members.removeWhere((m) => m.id == id);
    if (_members.length == before) return false;
    _save();
    _removeMemberNode(id);
    notifyListeners();
    return true;
  }

  /// Update one member's live location (called by LocationService).
  /// In synced mode only MY OWN location is published (other
  /// members' locations arrive from RTDB).
  void updateLocation(String id, double lat, double lon, DateTime at) {
    final i = _members.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _members[i] =
        _members[i].copyWith(lat: lat, lon: lon, lastSeen: at, isOnline: true);
    _save();
    if (isSynced && _sync!.uid == id) {
      unawaited(_sync!.publishMyLocation(activeCircleId!, _members[i]));
    }
    notifyListeners();
  }

  /// Publish MY live location (GPS fix + battery) to the active
  /// circle. Creates my member node first if it does not exist
  /// yet (fresh circle). No-op in demo mode.
  Future<void> publishSelfLocation(
    double lat,
    double lon,
    int battery,
  ) async {
    if (!isSynced) return;
    final circleId = activeCircleId!;
    final uid = _sync!.uid!;
    await _sync!.ensureMyMemberNode(circleId);
    var mine = myMember;
    if (mine == null) {
      mine = Member(
        id: uid,
        name: 'Me',
        phone: '',
        role: _sync!.activeCircle?.role ?? 'member',
        lastSeen: DateTime.now(),
        isOnline: true,
      );
      _members.add(mine);
    }
    updateLocation(uid, lat, lon, DateTime.now());
    // Battery rides on the same node — stamped with when it was
    // read, so viewers can tell a live level from a stale one
    // (v0.6.6).
    final now = DateTime.now();
    final i = _members.indexWhere((m) => m.id == uid);
    if (i >= 0) {
      _members[i] =
          _members[i].copyWith(battery: battery, batteryAt: now);
      _save();
      unawaited(_sync!.publishMyLocation(circleId, _members[i]));
      notifyListeners();
    }
  }

  /// Publish ONLY my battery (v0.6.6): the level changed (or 15
  /// minutes passed) while I have not moved, so there is no new
  /// location to send. Unknown levels never publish — there is
  /// nothing new to share, and -1 must never overwrite a real
  /// level (v0.6.2). No-op in demo mode.
  Future<void> publishSelfBattery(int battery) async {
    if (!isSynced) return;
    if (battery < 0 || battery > 100) return;
    final circleId = activeCircleId!;
    final uid = _sync!.uid!;
    final i = _members.indexWhere((m) => m.id == uid);
    if (i < 0) return;
    final now = DateTime.now();
    _members[i] = _members[i].copyWith(battery: battery, batteryAt: now);
    _save();
    unawaited(_sync!.publishBattery(
      circleId: circleId,
      uid: uid,
      battery: battery,
      at: now,
    ));
    notifyListeners();
  }

  /// Parent-only: change one alert for one member. The caller (UI)
  /// must already have verified the parent PIN — see AlertsScreen.
  /// In synced mode the change is pushed to RTDB, so the member's
  /// phone gets it live.
  void setAlert(String memberId, AlertType type, bool value) {
    final i = _members.indexWhere((m) => m.id == memberId);
    if (i < 0) return;
    final alerts = Map<AlertType, bool>.of(_members[i].alerts)
      ..[type] = value;
    _members[i] = _members[i].copyWith(alerts: alerts);
    _save();
    if (isSynced) {
      unawaited(_sync!.publishAlerts(activeCircleId!, memberId, alerts));
    }
    notifyListeners();
  }

  /// Location Lock: a member CANNOT turn sharing off themselves.
  /// Only the parent (PIN verified) can change this, from the
  /// parent phone. Turning it off here only stops the UI toggle —
  /// native enforcement (Device Admin) is documented in README.
  void setLocationSharing(String memberId, bool on) {
    final i = _members.indexWhere((m) => m.id == memberId);
    if (i < 0) return;
    _members[i] = _members[i].copyWith(locationSharingOn: on);
    _save();
    if (isSynced && _sync!.uid == memberId) {
      unawaited(_sync!.publishMyLocation(activeCircleId!, _members[i]));
    }
    notifyListeners();
  }

  /// Apply a location that arrived by SMS while the member's phone
  /// was offline (parent side). The member stays OFFLINE (no data)
  /// and the location is labelled "SMS se aayi" with the SMS time
  /// (see [Member.locationViaSms]). Matched by phone number —
  /// the sender is a member of this circle.
  /// Returns false when the sender is not a member (never apply
  /// an SMS from a stranger).
  bool applySmsLocation(
    String fromPhone,
    double lat,
    double lon,
    DateTime at,
  ) {
    final member = memberByPhone(fromPhone);
    if (member == null) return false;
    final i = _members.indexWhere((m) => m.id == member.id);
    _members[i] = _members[i].copyWith(
      lat: lat,
      lon: lon,
      lastSeen: at,
      isOnline: false,
      locationViaSms: true,
    );
    _save();
    notifyListeners();
    return true;
  }

  Member? memberByPhone(String phone) {
    final norm = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    for (final m in _members) {
      if (m.phone.replaceAll(RegExp(r'[^0-9+]'), '') == norm) return m;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_membersKey);
    if (raw != null) {
      try {
        _members
          ..clear()
          ..addAll(
            (jsonDecode(raw) as List).map(
              (e) => Member.fromJson(e as Map<String, dynamic>),
            ),
          );
      } catch (_) {
        _members.clear();
      }
    }
    notifyListeners();
    _subscribeRemote();
  }

  /// Subscribe to the active circle's RTDB nodes (members + my
  /// alerts + circle events). In demo mode this does nothing.
  void _subscribeRemote() {
    if (!isSynced || _subscribed) return;
    _subscribed = true;
    final circleId = activeCircleId!;
    final sync = _sync!;
    sync.subscribeMembers(circleId, (remote) {
      _members
        ..clear()
        ..addAll(remote);
      _save();
      notifyListeners();
    });
    sync.subscribeAlerts(circleId, sync.uid!, (alerts) {
      final i = _members.indexWhere((m) => m.id == sync.uid);
      if (i < 0) return;
      _members[i] = _members[i].copyWith(alerts: alerts);
      _save();
      notifyListeners();
    });
    sync.subscribeEvents(circleId, (event) {
      // Ignore my own events (I already know I pressed SOS).
      if (event.fromUid != sync.uid) _eventsController.add(event);
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _membersKey,
      jsonEncode(_members.map((m) => m.toJson()).toList()),
    );
    // v0.6.5: keep the native SIM-call overlay cache fresh — the
    // native receiver reads it without the Flutter engine running,
    // so it must be rewritten on EVERY member change, not just on
    // location updates. Every mutation flows through _save().
    await CallMemberCache.save(_members, myId: _sync?.uid);
  }

  Future<void> _pushMemberNode(Member member) async {
    if (!isSynced) return;
    try {
      await _sync!.publishMyLocation(activeCircleId!, member);
    } catch (_) {
      // Local copy is already saved; RTDB retries on next change.
    }
  }

  Future<void> _removeMemberNode(String memberId) async {
    if (!isSynced) return;
    try {
      await _sync!.removeMemberNode(activeCircleId!, memberId);
    } catch (_) {
      // Local removal already happened.
    }
  }

  /// Demo family (Lahore) — used ONLY until real accounts exist.
  /// Remove before production: real members come from Firebase Auth.
  void seedDemoFamily() {
    if (_members.isNotEmpty) return;
    final defaults = defaultAlertSettings();
    _members.addAll([
      Member(
        id: 'me',
        name: 'Mujahid',
        phone: '+923001234567',
        role: 'parent',
        lat: 31.5204,
        lon: 74.3587,
        lastSeen: DateTime.now(),
        battery: 82,
        isOnline: true,
        alerts: Map.of(defaults),
      ),
      Member(
        id: 'ali',
        name: 'Ali',
        phone: '+923005550103',
        role: 'child',
        lat: 31.5497,
        lon: 74.3436,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
        battery: 64,
        isOnline: true,
        alerts: Map.of(defaults),
      ),
      Member(
        id: 'ammi',
        name: 'Ammi',
        phone: '+923004440202',
        role: 'elderly',
        lat: 31.4687,
        lon: 74.3110,
        lastSeen: DateTime.now().subtract(const Duration(minutes: 22)),
        battery: 41,
        isOnline: false,
        alerts: Map.of(defaults),
      ),
    ]);
    notifyListeners();
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}
