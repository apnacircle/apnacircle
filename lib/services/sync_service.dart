import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alerts.dart';
import '../core/app_lock_service.dart';
import '../core/chat_paging.dart';
import '../core/chat_retention.dart';
import '../core/member_phone.dart';
import '../core/protection_level.dart';
import '../models/chat_message.dart';
import '../models/circle.dart';
import '../models/member.dart';
import '../models/trial.dart';
import 'auth_service.dart';
import 'device_owner_service.dart';
import 'firebase_bootstrap.dart';
import 'firebase_config.dart';
import 'pin_service.dart';

/// Resolve a join: the role I join with, and whether joinCircle
/// must (re)write my member node.
///
/// v0.6.15 (RTDB rules v2) — re-join after removal. The role: an
/// existing role entry wins — a removed member re-joins with their
/// OLD role, never with a role the caller passes (a removed child
/// cannot re-join as 'parent' by asking for it).
///
/// The member node: ALWAYS written. First join (no role entry) —
/// the node does not exist yet. Re-join (role entry exists) — the
/// node may be missing (the parent removed me) or present
/// (redundant re-join). joinCircle cannot tell without reading —
/// and under rules v2 the read is DENIED once membership is gone
/// (the members read rule requires your own node to exist) — so it
/// must never read first: it writes directly. The self-write is
/// always allowed under v2 (`members/$memberId` write rule:
/// `auth.uid == $memberId`), and a redundant write is harmless
/// (the next location publish restores location/battery).
({String role, bool writeMemberNode}) resolveJoinRole({
  required String? existingRole,
  required String requestedRole,
}) =>
    (
      role: existingRole ?? requestedRole,
      writeMemberNode: true,
    );

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
    // v0.6.28: never leave the app with circles but NO active
    // circle (a fresh install used to show the list with nothing
    // selected — every admin check then saw activeCircle == null).
    _activeCircleId = resolveActiveCircleId(
      currentActiveId: _activeCircleId,
      circleIds: _myCircles.map((c) => c.id).toList(),
    );
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

  /// Drop one circle from the local list (v0.6.27 — the phone
  /// was removed from it). If it was the active circle, switch
  /// to another circle when one exists, otherwise clear the
  /// active circle entirely (subs are cancelled either way).
  /// Returns the new active circle id, or null when none is
  /// left. The server `users/{uid}/circles` entry is left alone
  /// — the next refresh drops it by itself (its info read is
  /// denied once membership is gone), and re-joining with the
  /// invite code still works.
  Future<String?> removeCircleLocally(String circleId) async {
    _myCircles.removeWhere((c) => c.id == circleId);
    if (_activeCircleId == circleId) {
      _cancelSubs();
      _activeCircleId =
          _myCircles.isEmpty ? null : _myCircles.first.id;
    }
    await _saveLocal();
    notifyListeners();
    return _activeCircleId;
  }

  /// Delete a whole circle (v0.6.28, parent only — the user asked
  /// why circles they never created show up: only the Create
  /// button can make a parent circle, and an empty name becomes
  /// "Family", so accidental creates lingered with no way to
  /// remove them). Removes every member node, the invite code,
  /// my own role entry and — LAST, so read access survives the
  /// operation — the info node (rules v6 let the creator delete
  /// info). Other members' `users/{uid}/circles` entries are left
  /// alone (only they can write them); their next refresh skips
  /// the circle because its info node is gone. If it was the
  /// active circle, the first remaining circle becomes active.
  /// Returns false when the circle is not mine or not a circle
  /// I parent. Server failures still drop it locally, so it never
  /// shows again on this phone.
  Future<bool> deleteCircle(String circleId) async {
    if (!isAvailable) return false;
    final circle =
        _myCircles.where((c) => c.id == circleId).firstOrNull;
    if (circle == null || circle.role != 'parent') return false;
    try {
      final membersSnap = await _root
          .child(FirebaseConfig.circleMembersPath(circleId))
          .get();
      final memberIds = membersSnap.exists && membersSnap.value != null
          ? asMap(membersSnap.value).keys.toList()
          : <String>[uid!];
      for (final m in memberIds) {
        await _root
            .child(FirebaseConfig.circleMemberPath(circleId, m))
            .remove();
      }
      if (circle.inviteCode.isNotEmpty) {
        await _root
            .child(FirebaseConfig.invitePath(circle.inviteCode))
            .remove();
      }
      await _root
          .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
          .remove();
      await _root.child(FirebaseConfig.circleInfoPath(circleId)).remove();
    } catch (_) {
      // Best effort on the server side — still drop it locally.
    }
    _myCircles.removeWhere((c) => c.id == circleId);
    if (_activeCircleId == circleId) {
      _cancelSubs();
      _activeCircleId =
          _myCircles.isEmpty ? null : _myCircles.first.id;
    }
    await _saveLocal();
    notifyListeners();
    return true;
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
          e.key.toString():
              e.value is Map || e.value is List ? _convert(e.value) : e.value,
      };
    }
    return {};
  }

  static dynamic _convert(dynamic value) {
    if (value is Map) return asMap(value);
    if (value is List) {
      return value.map((e) => e is Map || e is List ? _convert(e) : e).toList();
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
      // circle-level read rule requires membership, so write MY
      // OWN member node FIRST (rules v5 accept the create — a
      // full node with name + phone + role, plus the invite
      // code as proof), and only then the info node.
      await _writeMyMemberNode(
        circleId,
        'parent',
        inviteCode: code,
        protection: await DeviceOwnerService().currentLevel(),
      );
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

  /// Join a circle with the parent's 6-digit invite code AND the
  /// member's mobile number (v0.6.14) — both required. Gmail logins
  /// carry no number, so the number must be typed at join time;
  /// without it the SIM-call overlay can never match the member and
  /// no card appears. The number is validated (real phone format,
  /// never an email) and stored as the member node's `phone`.
  /// [role] is 'child', 'elderly' or 'member' — the parent is the
  /// only admin. Returns (circle, null) on success.
  ///
  /// v0.6.15 (RTDB rules v2) — re-join after removal: a member the
  /// parent removed CAN re-join with the code (their
  /// `users/{uid}/circles` role entry is left alone by removal),
  /// but removal deletes only their member node. joinCircle must
  /// write that node again — it must NOT skip the write when the
  /// role entry already exists, and it must NOT read the node
  /// first to check: under v2 the read is DENIED once membership
  /// is gone, so a read-first check would never write.
  ///
  /// v0.6.27 (rules v5): the node write carries the invite code
  /// as proof — rules v5 accept a member-node CREATE with a valid
  /// invite code (or, for older apps, a full node). A removed
  /// member's background task can never write one: its blind
  /// location updates carry no invite code and no name/phone/role.
  /// (see [resolveJoinRole]).
  Future<(CircleInfo?, String?)> joinCircle(
    String code, {
    required String phoneNumber,
    String role = 'child',
    String? displayName,
  }) async {
    if (!isAvailable) return (null, 'Sign in first to join a circle.');
    final joinError = validateJoinInput(code: code, phone: phoneNumber);
    if (joinError != null) return (null, joinError);
    final clean = code.trim();
    final normalizedPhone = validateMemberPhone(phoneNumber).number!;
    try {
      final snap = await _root.child(FirebaseConfig.invitePath(clean)).get();
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
      final join = resolveJoinRole(
        existingRole: existingRole,
        requestedRole: role,
      );
      final myRole = join.role;
      if (existingRole == null) {
        await _root
            .child(FirebaseConfig.userCircleRolePath(uid!, circleId))
            .set(myRole);
      }
      // v0.6.15: ALWAYS write my member node — even on re-join (see
      // resolveJoinRole). Before this the write lived inside the
      // `existingRole == null` branch, so a removed member's re-join
      // "succeeded" but left them invisible: no member node, and
      // under rules v2 ensureMyMemberNode can no longer re-create
      // it (its read-first check is denied once membership is
      // gone). No read here — the self-write is always allowed.
      if (join.writeMemberNode) {
        await _writeMyMemberNode(
          circleId,
          myRole,
          displayName: displayName,
          phone: normalizedPhone,
          inviteCode: clean,
          protection: await DeviceOwnerService().currentLevel(),
        );
      }
      final infoSnap =
          await _root.child(FirebaseConfig.circleInfoPath(circleId)).get();
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
        final infoSnap =
            await _root.child(FirebaseConfig.circleInfoPath(circleId)).get();
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
      // v0.6.28: pick a default active circle when none is set
      // (fresh install) or the old one is gone — before this the
      // refresh only replaced a STALE id, never a null one, so a
      // freshly installed app showed circles with nothing active
      // and every admin check saw activeCircle == null.
      _activeCircleId = resolveActiveCircleId(
        currentActiveId: _activeCircleId,
        circleIds: _myCircles.map((c) => c.id).toList(),
      );
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
    String? phone,
    String? inviteCode,
    ProtectionLevel protection = ProtectionLevel.unknown,
  }) async {
    final member = Member(
      id: uid!,
      name: displayName ?? _auth.displayName ?? _auth.phoneNumber ?? 'Me',
      // v0.6.14: the number typed at join time wins. The old
      // `phoneNumber ?? email` fallback stored an EMAIL for Gmail
      // users, which can never match a SIM call — that is why no
      // overlay card appeared at all. The fallback below survives
      // only for paths that never asked for a number
      // (ensureMyMemberNode); join always passes one.
      phone: phone ?? _auth.phoneNumber ?? _auth.email ?? '',
      role: role,
      lastSeen: DateTime.now(),
      isOnline: true,
      protection: protection,
      // v0.6.27 (rules v5): the invite code is the proof that
      // this node was created by a real join/create, not by a
      // removed member's blind location publish.
      inviteCode: inviteCode,
    );
    await _root
        .child(FirebaseConfig.circleMemberPath(circleId, uid!))
        .set(member.toJson());
    await saveProfile();
  }

  /// One-time membership check (v0.6.27): does MY member node
  /// still exist in [circleId]? `true` = yes, keep sharing.
  /// `false` = definitely gone (node missing, or the read was
  /// permission-denied — the circle-level read rule denies
  /// anyone whose node is gone). `null` = the check itself
  /// failed (no network, unknown error) — the caller must NOT
  /// treat that as a removal. Never throws.
  Future<bool?> myMemberNodeCheck(String circleId) async {
    if (!isAvailable) return null;
    try {
      final snap = await _root
          .child(FirebaseConfig.circleMemberPath(circleId, uid!))
          .get();
      return snap.exists;
    } catch (e) {
      if (e is FirebaseException && e.code == 'permission-denied') {
        return false;
      }
      debugPrint('ApnaCircle: myMemberNodeCheck failed ($e)');
      return null;
    }
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
        protection: await DeviceOwnerService().currentLevel(),
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

  /// Parent sets one member's SIM number after joining (v0.6.14 —
  /// the change-later option for members who joined before numbers
  /// were asked at join time, e.g. mehvish). The member's own phone
  /// never overwrites this: `publishMyLocation` / battery updates
  /// never write the `phone` field, and `ensureMyMemberNode` only
  /// writes when the node is missing. NOTE: this relies on the
  /// circle-level write grant in the current RTDB rules (any member
  /// may write the circle); the pending rules tightening must keep
  /// a parent-write allowance for member phone.
  Future<bool> setMemberPhone(
    String circleId,
    String memberId,
    String phone,
  ) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.circleMemberPath(circleId, memberId))
          .update({'phone': phone});
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: setMemberPhone failed ($e)');
      return false;
    }
  }

  /// RTDB paths deleted when an account is deleted (pure, tested):
  /// the user's own `users/{uid}` node + their own member node in
  /// every circle. Nothing of any other user is ever in this list.
  static List<String> accountCleanupPaths(
    String uid,
    List<String> circleIds,
  ) =>
      [
        'users/$uid',
        for (final id in circleIds) FirebaseConfig.circleMemberPath(id, uid),
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

  /// One-time read of a member's lock settings (the parent's Locks
  /// screen loads the target child's current list before editing).
  /// Null when the node does not exist yet (or cannot be read) —
  /// the caller keeps its local defaults then, instead of wiping
  /// the preset list with an empty one (v0.6.9). Old nodes (apps
  /// only) read back with both switches ON.
  Future<LockSettings?> getLocksOnce(
    String circleId,
    String memberId,
  ) async {
    if (!isAvailable) return null;
    try {
      final snap = await _root
          .child(FirebaseConfig.circleLocksPath(circleId, memberId))
          .get();
      if (!snap.exists || snap.value == null) return null;
      return LockSettings.fromJson(asMap(snap.value));
    } catch (e) {
      debugPrint('ApnaCircle: getLocksOnce failed ($e)');
      return null;
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
        'lastSeen':
            me.lastSeen?.toIso8601String() ?? DateTime.now().toIso8601String(),
        'locationSharingOn': me.locationSharingOn,
      };
      if (me.batteryAt != null) {
        data['batteryAt'] = me.batteryAt!.toIso8601String();
      }
      // Protection level rides along (v0.6.13) — but only when
      // known: writing 'unknown' would clobber a level published
      // earlier by a newer build.
      if (me.protection != ProtectionLevel.unknown) {
        data['protection'] = me.protection.wireValue;
      }
      await _root
          .child(FirebaseConfig.circleMemberPath(circleId, me.id))
          .update(data);
    } catch (e) {
      debugPrint('ApnaCircle: publishMyLocation failed ($e)');
    }
  }

  /// Battery-only publish (v0.6.6): the level changed (or 15
  /// minutes passed) while the location did not, so there is no
  /// new fix to send — push just the battery + its timestamp.
  /// Touches nothing else: location, lastSeen and isOnline keep
  /// their values. The protection level (v0.6.13) rides along when
  /// known, so the parent's label stays fresh even while the
  /// member sits still.
  Future<void> publishBattery({
    required String circleId,
    required String uid,
    required int battery,
    required DateTime at,
    ProtectionLevel protection = ProtectionLevel.unknown,
  }) async {
    if (!isAvailable) return;
    try {
      final data = <String, dynamic>{
        'battery': battery,
        'batteryAt': at.toIso8601String(),
      };
      if (protection != ProtectionLevel.unknown) {
        data['protection'] = protection.wireValue;
      }
      await _root
          .child(FirebaseConfig.circleMemberPath(circleId, uid))
          .update(data);
    } catch (e) {
      debugPrint('ApnaCircle: publishBattery failed ($e)');
    }
  }

  /// Parent changes one member's alerts -> RTDB (child's phone
  /// gets it live). Alerts are a flat {name: bool} map.
  /// Returns true only when the write landed (v0.6.9): callers
  /// retry when it returns false, instead of assuming a
  /// fire-and-forget write arrived.
  Future<bool> publishAlerts(
    String circleId,
    String memberId,
    Map<AlertType, bool> alerts,
  ) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.circleAlertsPath(circleId, memberId))
          .set({for (final e in alerts.entries) e.key.name: e.value});
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: publishAlerts failed ($e)');
      return false;
    }
  }

  /// Parent changes one member's app locks + lock switches -> RTDB
  /// (child's phone enforces them live via AppLockService).
  /// v0.6.9: the whole [LockSettings] object is written — before,
  /// only `{'apps': [...]}` was written and the two switches
  /// (Location Lock, Internet-off alert) were never saved anywhere.
  /// Returns true only when the write landed, so callers can retry
  /// a publish that never arrived.
  Future<bool> publishLocks(
    String circleId,
    String memberId,
    LockSettings settings,
  ) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.circleLocksPath(circleId, memberId))
          .set(settings.toJson());
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: publishLocks failed ($e)');
      return false;
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

  /// Delete one chat message for EVERYONE (v0.6.21): remove its
  /// node. Returns false when offline or when the server refuses
  /// — the RTDB rules (v3) allow ONLY the sender to delete their
  /// own message, so a child can never delete the parent's
  /// messages. The live subscription stops delivering the removed
  /// message, so it vanishes from every phone (see
  /// mergeLiveChatPage for how the local list drops it).
  Future<bool> deleteChatMessage(String circleId, String messageId) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.circleChatPath(circleId))
          .child(messageId)
          .remove();
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: deleteChatMessage failed ($e)');
      return false;
    }
  }

  /// 1-week retention (v0.6.21): delete expired chat messages from
  /// the server. Runs at most once a day per phone (the check is
  /// stored in SharedPreferences), so it costs almost nothing.
  /// Deletes (a) ANY message whose atMs is older than 7 days —
  /// rules v3 allow any circle member to delete those — and
  /// (b) the current user's OWN older messages (sender-only
  /// delete, already allowed by v2/v3). Returns how many were
  /// removed. Old messages (sent before v0.6.21, no atMs) are
  /// pruned by their own sender under (b); they are already
  /// hidden everywhere by the local expiry filter.
  Future<int> pruneOldChatMessages(String circleId) async {
    if (!isAvailable) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastKey = 'chat_prune_last_$circleId';
      final last = prefs.getInt(lastKey) ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - last < const Duration(days: 1).inMilliseconds) {
        return 0;
      }
      final snap =
          await _root.child(FirebaseConfig.circleChatPath(circleId)).get();
      if (!snap.exists) return 0;
      final cutoff = retentionCutoffMs(nowMs);
      final myUid = uid;
      int removed = 0;
      for (final child in snap.children) {
        if (removed >= 200) break;
        final raw = SyncService.asMap(child.value);
        if (raw.isEmpty) continue;
        final atMs = raw['atMs'];
        final senderId = raw['senderId'] as String?;
        final expiredByMs = atMs is int && atMs < cutoff;
        final expiredOwn =
            senderId != null && senderId == myUid && _isExpiredAt(raw['at']);
        if (expiredByMs || expiredOwn) {
          await child.ref.remove();
          removed++;
        }
      }
      await prefs.setInt(lastKey, nowMs);
      if (removed > 0) {
        debugPrint('ApnaCircle: pruned $removed expired chat messages');
      }
      return removed;
    } catch (e) {
      debugPrint('ApnaCircle: pruneOldChatMessages failed ($e)');
      return 0;
    }
  }

  static bool _isExpiredAt(Object? atRaw) {
    if (atRaw is! String) return false;
    try {
      return isChatMessageExpired(at: DateTime.parse(atRaw));
    } catch (_) {
      return false;
    }
  }

  /// Media sharing (v0.6.23): a fresh push key for a media message
  /// — the key is needed BEFORE the upload, because the Storage
  /// path contains it (circles/{circle}/media/{uid}/{key}/...).
  String newChatMessageKey(String circleId) {
    return _root
            .child(FirebaseConfig.circleChatPath(circleId))
            .push()
            .key ??
        DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Media sharing (v0.6.23): write a media message under its
  /// pre-generated key. The file itself is uploaded by
  /// MediaService first; this only writes the chat node (the
  /// create branch of the v3 chat rule allows any member to send).
  Future<bool> sendMediaMessage(String circleId, ChatMessage msg) async {
    if (!isAvailable) return false;
    try {
      await _root
          .child(FirebaseConfig.circleChatPath(circleId))
          .child(msg.id)
          .set(msg.toJson());
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: sendMediaMessage failed ($e)');
      return false;
    }
  }

  /// Media sharing (v0.6.23): record that I downloaded this file
  /// to my own phone. Writes `downloadedBy/{myUid} = nowMs` — the
  /// v4 chat rule allows a member to write ONLY their own entry,
  /// same as the seenBy rule. The UI derives "removed from
  /// server" from downloadedBy (every member has it) + the 24-hour
  /// expiry, so no extra flag is needed.
  Future<bool> markMediaDownloaded(String circleId, String messageId) async {
    if (!isAvailable || uid == null) return false;
    try {
      await _root
          .child(FirebaseConfig.circleChatPath(circleId))
          .child(messageId)
          .child('downloadedBy')
          .child(uid!)
          .set(DateTime.now().millisecondsSinceEpoch);
      return true;
    } catch (e) {
      debugPrint('ApnaCircle: markMediaDownloaded failed ($e)');
      return false;
    }
  }

  /// Media sharing (v0.6.23): read the whole chat node once (for
  /// the media prune). Returns the parsed messages; empty when
  /// offline or when the node does not exist.
  Future<List<ChatMessage>> readChatMessages(String circleId) async {
    if (!isAvailable) return const [];
    try {
      final snap =
          await _root.child(FirebaseConfig.circleChatPath(circleId)).get();
      if (!snap.exists) return const [];
      final out = <ChatMessage>[];
      for (final child in snap.children) {
        final raw = SyncService.asMap(child.value);
        if (raw.isEmpty) continue;
        out.add(ChatMessage.fromJson(raw, id: child.key));
      }
      return out;
    } catch (e) {
      debugPrint('ApnaCircle: readChatMessages failed ($e)');
      return const [];
    }
  }

  /// Read receipts (v0.6.21): mark [messageIds] as read by me.
  /// Writes `seenBy/{myUid} = nowMs` under each message in ONE
  /// multi-path update. Rules v3 allow a member to write ONLY
  /// their own seenBy entry, so nobody can fake someone else's
  /// read. No-op offline.
  Future<void> markMessagesSeen(
    String circleId,
    List<String> messageIds,
  ) async {
    if (!isAvailable || messageIds.isEmpty) return;
    final myUid = uid;
    if (myUid == null) return;
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final updates = <String, Object?>{};
      for (final id in messageIds) {
        updates['${FirebaseConfig.circleChatPath(circleId)}/$id/seenBy/$myUid'] =
            nowMs;
      }
      await _root.update(updates);
    } catch (e) {
      debugPrint('ApnaCircle: markMessagesSeen failed ($e)');
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
      final snap =
          await _root.child(FirebaseConfig.circleInfoPath(circleId)).get();
      if (!snap.exists) return null;
      return asMap(snap.value)['pinHash'] as String?;
    } catch (e) {
      debugPrint('ApnaCircle: fetchPinHash failed ($e)');
      return null;
    }
  }

  /// Cache the circle's parent PIN hash on THIS phone (v0.6.13,
  /// offline rule). Every member's phone must hold the parent PIN
  /// hash locally (SharedPreferences, the same
  /// `flutter.parent_pin_sha256` key LockActivity reads), so the
  /// PIN gates — delete-account, sign-out, admin/owner removal —
  /// keep working with the internet OFF. Only adopts when this
  /// phone has no PIN yet (PinService.adoptHash): a locally-set
  /// PIN is never overwritten by a remote one, and the parent PIN
  /// is set once at first run (there is no change-PIN flow), so a
  /// cached copy cannot go stale. Best effort, never throws.
  /// Call whenever online: after joining a circle and after every
  /// circle-list refresh — never leave a member's phone with no
  /// local copy after its first sync.
  Future<void> cacheParentPinHash(PinService pin) async {
    if (pin.pinHash != null) return;
    final circleId = activeCircleId;
    if (circleId == null) return;
    try {
      final hash = await fetchPinHash(circleId);
      if (hash != null) await pin.adoptHash(hash);
    } catch (_) {
      // Best effort — the next online refresh retries.
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
  ///
  /// [onError] (v0.6.27): stream errors — a removed member's
  /// read is DENIED by the circle-level read rule, so the
  /// subscription dies with permission-denied instead of
  /// delivering an empty list. The caller treats that as
  /// "I was removed" (after verifying — see
  /// FamilyService.handleMembersReadError). Without a handler
  /// the error is unhandled and the app keeps its stale cached
  /// members while the background task keeps publishing.
  void subscribeMembers(
    String circleId,
    void Function(List<Member>) onData, {
    void Function(Object error)? onError,
  }) {
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
    }, onError: onError);
    _subs.add(sub);
  }

  /// Live lock settings for one member (the child's phone
  /// enforces). Delivers the whole [LockSettings] object — apps
  /// plus the two switches (v0.6.9).
  void subscribeLocks(
    String circleId,
    String memberId,
    void Function(LockSettings) onData,
  ) {
    if (!isAvailable) return;
    final sub = _root
        .child(FirebaseConfig.circleLocksPath(circleId, memberId))
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw == null) return;
      onData(LockSettings.fromJson(asMap(raw)));
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
