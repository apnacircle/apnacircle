import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alerts.dart';
import '../core/app_lock_service.dart';
import '../core/chat_paging.dart';
import '../models/chat_message.dart';
import '../models/circle.dart';
import '../models/member.dart';
import '../models/trial.dart';
import 'auth_service.dart';
import 'firebase_bootstrap.dart';
import 'firebase_config.dart';

/// Firebase Realtime Database sync (v0.3, 22 Nov 2026).
///
/// This is the layer that makes a parent on ONE phone control a
/// child on ANOTHER phone:
///
/// * Parent creates a circle -> gets a 6-digit invite code.
/// * Child joins with the code -> both phones see the same circle.
/// * Parent changes a lock / alert -> written to RTDB -> the
///   child's phone gets it live via `onValue` and enforces it.
/// * Each phone publishes its own live location (throttled 50 m /
///   60 s — see LocationService) to its own member node; the other
///   phone reads it.
/// * Chat + SOS events go through the same circle node.
///
/// Multi-circle: a user can be a member of one circle and admin of
/// others. The role is stored PER CIRCLE
/// (`users/{uid}/circles/{circleId}` + `members/{uid}/role`).
///
/// All methods are safe no-ops when Firebase is not configured or
/// nobody is signed in ([isAvailable] false) — callers check that
/// first, so demo mode never touches this class's Firebase code.
/// The database URL comes from google-services.json (created in
/// the Firebase console, region asia-southeast1); no key or URL is
/// hard-coded here.
class SyncService extends ChangeNotifier {
  SyncService(this._auth);

  final AuthService _auth;

  static const _activeCircleKey = 'active_circle_id';
  static const _myCirclesKey = 'my_circles_v1';

  bool get isAvailable =>
      FirebaseBootstrap.available && _auth.signedIn && _auth.uid != null;

  String? get uid => _auth.uid;

  // --- Active circle (persisted locally) ---

  String? _activeCircleId;
  String? get activeCircleId => _activeCircleId;

  final List<CircleInfo> _myCircles = [];
  List<CircleInfo> get myCircles => List.unmodifiable(_myCircles);

  CircleInfo? get activeCircle {
    for (final c in _myCircles) {
      if (c.id == _activeCircleId) return c;
    }
    return null;
  }

  final List<StreamSubscription<DatabaseEvent>> _subs = [];

  /// Database handle. Uses the explicit asia-southeast1 URL from
  /// FirebaseConfig because the google-services.json downloaded
  /// before the database was created has NO firebase_url inside —
  /// the default instance would not know where the database lives.
  DatabaseReference get _root => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseUrl,
      ).ref();

  /// Load the locally cached active circle + circle list (so the UI
  /// shows them instantly). The server refresh is NOT done here any
  /// more (v0.6.7): it is a network read, and it used to delay the
  /// first frame. main() runs [refreshMyCircles] after the first
  /// frame instead — the cached list is shown until then, which is
  /// what the first screen (Map) shows anyway.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _activeCircleId = prefs.getString(_activeCircleKey);
    final raw = prefs.getString(_myCirclesKey);
    if (raw != null) {
      try {
        _myCircles
          ..clear()
          ..addAll((jsonDecode(raw) as List).map(
            (e) => CircleInfo.fromJson(e as Map<String, dynamic>),
          ));
      } catch (_) {
        _myCircles.clear();
      }
    }
    notifyListeners();
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    if (_activeCircleId == null) {
      await prefs.remove(_activeCircleKey);
    } else {
      await prefs.setString(_activeCircleKey, _activeCircleId!);
    }
    await prefs.setString(
      _myCirclesKey,
      jsonEncode(_myCircles.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> setActiveCircle(String circleId) async {
    _cancelSubs();
    _activeCircleId = circleId;
    await _saveLocal();
    notifyListeners();
  }

  void _cancelSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  // --- RTDB value helpers ---

  /// RTDB returns Map<Object?, Object?> — convert recursively so
  /// the models' `as Map<String, dynamic>` casts do not throw.
  static Map<String, dynamic> asMap(dynamic value) {
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key.toString(): e.value is Map || e.value is List
              ? _convert(e.value)
              : e.value,
      };
    }
    return {};
  }

  static dynamic _convert(dynamic value) {
    if (value is Map) return asMap(value);
    if (value is List) {
      return value
          .map((e) => e is Map || e is List ? _convert(e) : e)
          .toList();
    }
    return value;
  }

  // --- Circles: create / join / list ---

  /// Create a circle as its parent (admin). Returns (circle, null)
  /// on success, (null, error message) on failure.
  Future<(CircleInfo?, String?)> createCircle(
    String name, {
    String? pinHash,
  }) async {
    if (!isAvailable) return (null, 'Sign in first to create a circle.');
    final trimmed = name.trim().isEmpty ? 'Family' : name.trim();
    try {
      final circleId = _root.child(FirebaseConfig.circlesPath).push().key!;
      final code = FirebaseConfig.newInviteCode();
      final info = {
        'name': trimmed,
        'inviteCode': code,
        'createdBy': uid,
        'createdAt': DateTime.now().toIso8601String(),
        if (pinHash != null) 'pinHash': pinHash,
      };
      // ORDER MATTERS (RTDB rules, see FIREBASE_SETUP.md §2): the
      // circle-level write rule requires membership, so write MY
      // OWN member node FIRST (the rules allow anyone to write
      // their own members/{uid} node), and only then the info node.
      await _writeMyMemberNode(circleId, 'parent');
      await _root.child(FirebaseConfig.circleInfoPath(circleId)).set(info);
      await _root.child(FirebaseConfig.invitePath(code)).set(circleId);
      await _root
          .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
          .set('parent');
      final circle = CircleInfo(
        id: circleId,
        name: trimmed,
        role: 'parent',
        inviteCode: code,
        createdAt: DateTime.now(),
      );
      _myCircles.removeWhere((c) => c.id == circleId);
      _myCircles.add(circle);
      await setActiveCircle(circleId);
      await _saveLocal();
      notifyListeners();
      return (circle, null);
    } catch (e) {
      return (null, 'Could not create the circle: $e');
    }
  }

  /// Join a circle with the parent's 6-digit invite code.
  /// [role] is 'child', 'elderly' or 'member' — the parent is the
  /// only admin. Returns (circle, null) on success.
  Future<(CircleInfo?, String?)> joinCircle(
    String code, {
    String role = 'child',
    String? displayName,
  }) async {
    if (!isAvailable) return (null, 'Sign in first to join a circle.');
    final clean = code.trim();
    if (clean.length != 6 || int.tryParse(clean) == null) {
      return (null, 'The invite code is 6 digits.');
    }
    try {
      final snap =
          await _root.child(FirebaseConfig.invitePath(clean)).get();
      if (!snap.exists || snap.value == null) {
        return (null, 'No circle found for that code — check the digits.');
      }
      final circleId = snap.value as String;
      // ORDER MATTERS (RTDB rules, see FIREBASE_SETUP.md §2): the
      // circle-level read rule requires membership, so join FIRST
      // (write my own members/{uid} node — the rules allow that),
      // and only then read the circle's info node.
      final roleSnap = await _root
          .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
          .get();
      final existingRole = roleSnap.value as String?;
      final myRole = existingRole ?? role;
      if (existingRole == null) {
        await _root
            .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
            .set(myRole);
        await _writeMyMemberNode(circleId, myRole,
            displayName: displayName);
      }
      final infoSnap = await _root
          .child(FirebaseConfig.circleInfoPath(circleId))
          .get();
      if (!infoSnap.exists) return (null, 'That circle no longer exists.');
      final info = asMap(infoSnap.value);
      final circle = CircleInfo(
        id: circleId,
        name: info['name'] as String? ?? 'Family',
        role: myRole,
        inviteCode: clean,
        createdAt: info['createdAt'] == null
            ? null
            : DateTime.parse(info['createdAt'] as String),
      );
      _myCircles.removeWhere((c) => c.id == circleId);
      _myCircles.add(circle);
      await setActiveCircle(circleId);
      await _saveLocal();
      notifyListeners();
      return (circle, null);
    } catch (e) {
      return (null, 'Could not join the circle: $e');
    }
  }

  /// Refresh "my circles" from `users/{uid}/circles` + each
  /// circle's info node. Keeps the locally cached list on failure.
  Future<void> refreshMyCircles() async {
    if (!isAvailable) return;
    try {
      final snap =
          await _root.child(FirebaseConfig.userCirclesPath(uid!)).get();
      if (!snap.exists || snap.value == null) return;
      final roles = asMap(snap.value);
      final fresh = <CircleInfo>[];
      for (final entry in roles.entries) {
        final circleId = entry.key;
        final role = entry.value as String? ?? 'member';
        final infoSnap = await _root
            .child(FirebaseConfig.circleInfoPath(circleId))
            .get();
        if (!infoSnap.exists) continue;
        final info = asMap(infoSnap.value);
        fresh.add(CircleInfo(
          id: circleId,
          name: info['name'] as String? ?? 'Family',
          role: role,
          inviteCode: info['inviteCode'] as String? ?? '',
          createdAt: info['createdAt'] == null
              ? null
              : DateTime.parse(info['createdAt'] as String),
        ));
      }
      _myCircles
        ..clear()
        ..addAll(fresh);
      if (_activeCircleId != null &&
          !_myCircles.any((c) => c.id == _activeCircleId)) {
        _activeCircleId = _myCircles.isEmpty ? null : _myCircles.first.id;
      }
      await _saveLocal();
      notifyListeners();
    } catch (e) {
      debugPrint('ApnaCircle: refreshMyCircles failed ($e)');
    }
  }

  /// My profile node (name, phone, email, FCM token). Written when
  /// joining/creating a circle and when the FCM token refreshes.
  Future<void> saveProfile({String? fcmToken}) async {
    if (!isAvailable) return;
    try {
      await _root.child(FirebaseConfig.userProfilePath(uid!)).update({
        'name': _auth.displayName ?? '',
        'phone': _auth.phoneNumber ?? '',
        'email': _auth.email ?? '',
        'updatedAt': DateTime.now().toIso8601String(),
        if (fcmToken != null) 'fcmToken': fcmToken,
      });
    } catch (e) {
      debugPrint('ApnaCircle: saveProfile failed ($e)');
    }
  }

  Future<void> _writeMyMemberNode(
    String circleId,
    String role, {
    String? displayName,
  }) async {
    final member = Member(
      id: uid!,
      name: displayName ?? _auth.displayName ?? _auth.phoneNumber ?? 'Me',
      phone: _auth.phoneNumber ?? _auth.email ?? '',
      role: role,
      lastSeen: DateTime.now(),
      isOnline: true,
    );
    await _root
        .child(FirebaseConfig.circleMemberPath(circleId, uid!))
        .set(member.toJson());
    await saveProfile();
  }

  /// Make sure my member node exists in a circle (fresh circle /
  /// first location publish). Writes it only when it is missing —
  /// never overwrites an existing node.
  Future<void> ensureMyMemberNode(String circleId) async {
    if (!isAvailable) return;
    try {
      final snap = await _root
          .child(FirebaseConfig.circleMemberPath(circleId, uid!))
          .get();
      if (snap.exists) return;
      final roleSnap = await _root
          .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
          .get();
      await _writeMyMemberNode(
        circleId,
        roleSnap.value as String? ?? 'member',
      );
    } catch (e) {
      debugPrint('ApnaCircle: ensureMyMemberNode failed ($e)');
    }
  }

  /// Remove one member's node from a circle (parent removing a
  /// member). The member's own `users/{uid}/circles` entry is left
  /// alone — they can re-join with the invite code.
  Future<void> removeMemberNode(String circleId, String memberId) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleMemberPath(circleId, memberId))
          .remove();
    } catch (e) {
      debugPrint('ApnaCircle: removeMemberNode failed ($e)');
    }
  }

  /// RTDB paths deleted when an account is deleted (pure, tested):
  /// the user's own `users/{uid}` node + their own member node in
  /// every circle. Nothing of any other user is ever in this list.
  static List<String> accountCleanupPaths(
    String uid,
    List<String> circleIds,
  ) => [
        'users/$uid',
        for (final id in circleIds)
          FirebaseConfig.circleMemberPath(id, uid),
      ];

  /// Delete MY data from the Realtime Database (v0.5, account
  /// delete — Play Store requirement). Removes the user's own
  /// `users/{uid}` node (profile + circle roles) and their own
  /// member node from every circle they belong to. Best effort:
  /// a failed remove is logged, not fatal — the Auth account
  /// delete that follows is what actually closes the account.
  /// What is NOT deleted here, honestly: chat messages and events
  /// the user already sent (they belong to the circle's shared
  /// history), and circles the user created as parent (other
  /// members still use them — the parent should hand the circle
  /// over or delete it first). The privacy policy says the same.
  Future<void> deleteMyAccountData() async {
    if (!isAvailable) return;
    final myUid = uid!;
    final paths = accountCleanupPaths(
      myUid,
      _myCircles.map((c) => c.id).toList(),
    );
    for (final path in paths) {
      try {
        await _root.child(path).remove();
      } catch (e) {
        debugPrint('ApnaCircle: deleteMyAccountData $path failed ($e)');
      }
    }
    _myCircles.clear();
    _activeCircleId = null;
    await _saveLocal();
    notifyListeners();
  }

  /// One-time read of a member's app locks (the parent's Locks
  /// screen loads the target child's current list before editing).
  Future<List<LockedApp>> getLocksOnce(
    String circleId,
    String memberId,
  ) async {
    if (!isAvailable) return const [];
    try {
      final snap = await _root
          .child(FirebaseConfig.circleLocksPath(circleId, memberId))
          .get();
      if (!snap.exists || snap.value == null) return const [];
      final appsRaw = asMap(snap.value)['apps'];
      if (appsRaw is! List) return const [];
      return appsRaw
          .map((a) {
            try {
              return LockedApp.fromJson(asMap(a));
            } catch (_) {
              return null;
            }
          })
          .whereType<LockedApp>()
          .toList();
    } catch (e) {
      debugPrint('ApnaCircle: getLocksOnce failed ($e)');
      return const [];
    }
  }

  // --- Live data: publish (my phone -> RTDB) ---

  /// Publish my member node (location, battery, online) for a circle.
  Future<void> publishMyLocation(
    String circleId,
    Member me,
  ) async {
    if (!isAvailable) return;
    try {
      // batteryAt is only written when known: an update() with a
      // null value would DELETE the key on the server.
      final data = <String, dynamic>{
        'lat': me.lat,
        'lon': me.lon,
        'battery': me.battery,
        'isOnline': me.isOnline,
        'lastSeen': me.lastSeen?.toIso8601String() ??
            DateTime.now().toIso8601String(),
        'locationSharingOn': me.locationSharingOn,
      };
      if (me.batteryAt != null) {
        data['batteryAt'] = me.batteryAt!.toIso8601String();
      }
      await _root.child(FirebaseConfig.circleMemberPath(circleId, me.id)).update(data);
    } catch (e) {
      debugPrint('ApnaCircle: publishMyLocation failed ($e)');
    }
  }

  /// Battery-only publish (v0.6.6): the level changed (or 15
  /// minutes passed) while the location did not, so there is no
  /// new fix to send — push just the battery + its timestamp.
  /// Touches nothing else: location, lastSeen and isOnline keep
  /// their values.
  Future<void> publishBattery({
    required String circleId,
    required String uid,
    required int battery,
    required DateTime at,
  }) async {
    if (!isAvailable) return;
    try {
      await _root.child(FirebaseConfig.circleMemberPath(circleId, uid)).update({
        'battery': battery,
        'batteryAt': at.toIso8601String(),
      });
    } catch (e) {
      debugPrint('ApnaCircle: publishBattery failed ($e)');
    }
  }

  /// Parent changes one member's alerts -> RTDB (child's phone
  /// gets it live). Alerts are a flat {name: bool} map.
  Future<void> publishAlerts(
    String circleId,
    String memberId,
    Map<AlertType, bool> alerts,
  ) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleAlertsPath(circleId, memberId))
          .set({for (final e in alerts.entries) e.key.name: e.value});
    } catch (e) {
      debugPrint('ApnaCircle: publishAlerts failed ($e)');
    }
  }

  /// Parent changes one member's app locks -> RTDB (child's phone
  /// enforces them live via AppLockService).
  Future<void> publishLocks(
    String circleId,
    String memberId,
    List<LockedApp> apps,
  ) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleLocksPath(circleId, memberId))
          .set({'apps': apps.map((a) => a.toJson()).toList()});
    } catch (e) {
      debugPrint('ApnaCircle: publishLocks failed ($e)');
    }
  }

  /// Family chat: append one message to the circle.
  Future<void> sendChatMessage(String circleId, ChatMessage msg) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleChatPath(circleId))
          .push()
          .set(msg.toJson());
    } catch (e) {
      debugPrint('ApnaCircle: sendChatMessage failed ($e)');
    }
  }

  /// SOS / battery-low / phone-off event for the whole circle.
  Future<void> sendEvent(String circleId, CircleEvent event) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleEventsPath(circleId))
          .push()
          .set(event.toJson());
    } catch (e) {
      debugPrint('ApnaCircle: sendEvent failed ($e)');
    }
  }

  // --- Parent PIN recovery (account-based) ---

  /// Store the parent PIN hash on the circle, so a parent who signs
  /// in on a NEW phone recovers the same PIN (approved feature:
  /// parent-phone-loss recovery). Only circle members can read it
  /// (see RTDB rules in FIREBASE_SETUP.md). The hash is SHA-256 —
  /// never the PIN itself.
  Future<void> publishPinHash(String circleId, String pinHash) async {
    if (!isAvailable) return;
    try {
      await _root
          .child(FirebaseConfig.circleInfoPath(circleId))
          .update({'pinHash': pinHash});
    } catch (e) {
      debugPrint('ApnaCircle: publishPinHash failed ($e)');
    }
  }

  /// Fetch the circle's stored PIN hash (null = none stored yet).
  Future<String?> fetchPinHash(String circleId) async {
    if (!isAvailable) return null;
    try {
      final snap = await _root
          .child(FirebaseConfig.circleInfoPath(circleId))
          .get();
      if (!snap.exists) return null;
      return asMap(snap.value)['pinHash'] as String?;
    } catch (e) {
      debugPrint('ApnaCircle: fetchPinHash failed ($e)');
      return null;
    }
  }

  // --- 7-day free trial (22 Nov 2026; once PER DEVICE, 23 Nov 2026) ---

  /// Read one device's trial state from `trials/{deviceHash}`.
  /// Null = no trial stored yet (never started on this phone).
  /// The device hash is the SHA-256 of the Android ID — the raw id
  /// is never stored or sent (see DeviceIdService).
  Future<TrialState?> fetchTrial(String deviceHash) async {
    if (!isAvailable) return null;
    try {
      final snap =
          await _root.child(FirebaseConfig.trialPath(deviceHash)).get();
      if (!snap.exists) return null;
      return TrialState.fromJson(asMap(snap.value));
    } catch (e) {
      debugPrint('ApnaCircle: fetchTrial failed ($e)');
      return null;
    }
  }

  /// Write one device's trial state to `trials/{deviceHash}` (set,
  /// so the whole node is written at once). Returns false when the
  /// write failed — the caller must not treat the trial as started
  /// then. Needs the `trials` rules in FIREBASE_SETUP.md §2 —
  /// without them this fails with "permission denied".
  Future<bool> publishTrial(String deviceHash, TrialState trial) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.trialPath(deviceHash))
          .set(trial.toJson());
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: publishTrial failed ($e)');
      return false;
    }
  }

  // --- Live data: subscribe (RTDB -> this phone) ---

  /// Live member list of a circle (location, battery, online).
  void subscribeMembers(
    String circleId,
    void Function(List<Member>) onData,
  ) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleMembersPath(circleId))
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) {
        onData(const []);
        return;
      }
      final map = asMap(raw);
      final members = <Member>[];
      for (final e in map.entries) {
        try {
          final m = asMap(e.value);
          m.putIfAbsent('id', () => e.key);
          members.add(Member.fromJson(m));
        } catch (err) {
          debugPrint('ApnaCircle: bad member node ${e.key} ($err)');
        }
      }
      onData(members);
    });
    _subs.add(sub);
  }

  /// Live app locks for one member (the child's phone enforces).
  void subscribeLocks(
    String circleId,
    String memberId,
    void Function(List<LockedApp>) onData,
  ) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleLocksPath(circleId, memberId))
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;
      final map = asMap(raw);
      final appsRaw = map['apps'];
      if (appsRaw is! List) return;
      final apps = <LockedApp>[];
      for (final a in appsRaw) {
        try {
          apps.add(LockedApp.fromJson(asMap(a)));
        } catch (err) {
          debugPrint('ApnaCircle: bad lock entry ($err)');
        }
      }
      onData(apps);
    });
    _subs.add(sub);
  }

  /// Live per-alert on/off for one member.
  void subscribeAlerts(
    String circleId,
    String memberId,
    void Function(Map<AlertType, bool>) onData,
  ) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleAlertsPath(circleId, memberId))
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;
      final map = asMap(raw);
      final out = <AlertType, bool>{};
      for (final e in map.entries) {
        for (final a in AlertType.values) {
          if (a.name == e.key && e.value is bool) out[a] = e.value as bool;
        }
      }
      if (out.isNotEmpty) onData(out);
    });
    _subs.add(sub);
  }

  /// Live family chat of a circle (newest [limit] messages, oldest
  /// first). v0.6.7: the subscription used to download the WHOLE
  /// history — and re-download all of it on every new message.
  /// Now it is capped at [chatPageSize]; older pages come from
  /// [loadOlderChatMessages]. The newest messages arrive exactly
  /// as before.
  void subscribeChat(
    String circleId,
    void Function(List<ChatMessage>) onData, {
    int limit = chatPageSize,
  }) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleChatPath(circleId))
        .limitToLast(limit)
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) {
        onData(const []);
        return;
      }
      final map = asMap(raw);
      final msgs = <ChatMessage>[];
      for (final e in map.entries) {
        try {
          msgs.add(ChatMessage.fromJson(asMap(e.value), id: e.key));
        } catch (err) {
          debugPrint('ApnaCircle: bad chat message ($err)');
        }
      }
      msgs.sort((a, b) => a.at.compareTo(b.at));
      onData(msgs);
    });
    _subs.add(sub);
  }

  /// One older page of chat history: the [limit] messages sent
  /// just before the message with RTDB push key [beforeId].
  /// Returns oldest first. Used by the "Load older messages"
  /// button — the live subscription only keeps the newest page.
  Future<List<ChatMessage>> loadOlderChatMessages(
    String circleId, {
    required String beforeId,
    int limit = chatPageSize,
  }) async {
    if (!isAvailable) return const [];
    try {
      final snap = await _root
          .child(FirebaseConfig.circleChatPath(circleId))
          .orderByKey()
          .endBefore(beforeId)
          .limitToLast(limit)
          .get();
      if (!snap.exists || snap.value == null) return const [];
      final map = asMap(snap.value);
      final msgs = <ChatMessage>[];
      for (final e in map.entries) {
        try {
          msgs.add(ChatMessage.fromJson(asMap(e.value), id: e.key));
        } catch (err) {
          debugPrint('ApnaCircle: bad chat message ($err)');
        }
      }
      msgs.sort((a, b) => a.at.compareTo(b.at));
      return msgs;
    } catch (e) {
      debugPrint('ApnaCircle: loadOlderChatMessages failed ($e)');
      return const [];
    }
  }

  /// New SOS / alert events only (childAdded — old events are not
  /// replayed when the parent opens the app).
  void subscribeEvents(
    String circleId,
    void Function(CircleEvent) onEvent,
  ) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleEventsPath(circleId))
        .onChildAdded
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;
      try {
        onEvent(CircleEvent.fromJson(asMap(raw)));
      } catch (err) {
        debugPrint('ApnaCircle: bad circle event ($err)');
      }
    });
    _subs.add(sub);
  }

  @override
  void dispose() {
    _cancelSubs();
    super.dispose();
  }
}
