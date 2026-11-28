import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/join_request.dart';
import '../l10n/strings.dart';
import '../models/circle.dart';
import 'auth_service.dart';
import 'firebase_config.dart';
import 'pin_service.dart';
import 'sync_service.dart';

/// Join requests (v0.6.30): a child asks, the parent allows.
///
/// * CHILD: [submitRequest] writes one `pending` node under the
///   circle (invite code + name + phone + the HASH of the parent
///   PIN typed). [watchMyRequest] listens to that node — approved
///   means the child's phone may now run the normal join itself;
///   denied means "try again" (wrong parent code, or the parent
///   said no). A returning member skips the request and re-joins
///   directly (their role entry still exists).
/// * PARENT: [watchCircleRequests] live-listens to the active
///   circle's requests; [approve]/[deny] decide. [verifyPendingRequests]
///   auto-denies a request whose PIN hash does not match the
///   circle's real PIN, so the child gets a fast, clear answer
///   ("code ghalat tha") without the parent having to look.
/// * [refreshAllPending] counts pending requests across every
///   circle this phone parents, so a request in a non-active
///   circle is still visible on Home.
///
/// All methods are safe no-ops / clear errors when Firebase is
/// not configured or nobody is signed in — demo mode never
/// touches this class's Firebase code.
class JoinRequestService extends ChangeNotifier {
  JoinRequestService({
    required SyncService sync,
    required AuthService auth,
  })  : _sync = sync,
        _auth = auth;

  final SyncService _sync;
  final AuthService _auth;

  bool get isAvailable => _sync.isAvailable;

  DatabaseReference get _root => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseUrl,
      ).ref();

  // --- child side ---

  JoinRequest? _myRequest;
  JoinRequest? get myRequest => _myRequest;

  /// Circle of my still-open request, persisted so the waiting
  /// screen resumes after the app restarts.
  String? _pendingCircleId;
  String? get pendingCircleId => _pendingCircleId;

  StreamSubscription<DatabaseEvent>? _mySub;

  static const _pendingCircleKey = 'join_pending_circle_v1';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _pendingCircleId = prefs.getString(_pendingCircleKey);
  }

  Future<void> _savePendingCircle(String? circleId) async {
    _pendingCircleId = circleId;
    final prefs = await SharedPreferences.getInstance();
    if (circleId == null) {
      await prefs.remove(_pendingCircleKey);
    } else {
      await prefs.setString(_pendingCircleKey, circleId);
    }
  }

  /// Submit a join request (child). Returns (request, error).
  /// When the request is null AND the error is null, the child
  /// already had a role in this circle and joined directly.
  Future<(JoinRequest?, String?)> submitRequest({
    required String inviteCode,
    required String phone,
    required String parentPin,
    required String displayName,
    bool isUrdu = false,
  }) async {
    if (!isAvailable || _auth.uid == null) {
      return (null, tr(isUrdu, 'svc_joinNeedSignIn'));
    }
    final code = inviteCode.trim();
    final name = displayName.trim();
    if (code.isEmpty) return (null, tr(isUrdu, 'svc_joinEnterInviteCode'));
    if (name.isEmpty) return (null, tr(isUrdu, 'svc_joinEnterName'));
    if (phone.trim().isEmpty) {
      return (null, tr(isUrdu, 'svc_joinEnterPhone'));
    }
    if (parentPin.length < 4) {
      return (null, tr(isUrdu, 'svc_joinPinMinDigits'));
    }
    try {
      // Resolve the code -> circle (invites read is open to any
      // signed-in user — the code IS the credential).
      final inviteSnap =
          await _root.child(FirebaseConfig.invitePath(code)).get();
      if (!inviteSnap.exists || inviteSnap.value == null) {
        return (null, tr(isUrdu, 'svc_joinNoCircleForCode'));
      }
      final circleId = inviteSnap.value as String;
      // Returning member? Their role entry still exists — re-join
      // directly, no request, no parent approval needed again.
      final roleSnap = await _root
          .child(FirebaseConfig.userCircleRolePath(_auth.uid!, circleId))
          .get();
      if (roleSnap.exists && roleSnap.value != null) {
        final (circle, err) = await _sync.joinCircle(
          code,
          phoneNumber: phone,
          role: 'child',
          displayName: name,
          isUrdu: isUrdu,
        );
        if (circle == null) {
          return (null, err ?? tr(isUrdu, 'svc_joinFailed'));
        }
        await _savePendingCircle(null);
        return (null, null);
      }
      final req = JoinRequest(
        circleId: circleId,
        uid: _auth.uid!,
        name: name,
        phone: phone.trim(),
        inviteCode: code,
        pinHashAttempt: PinService.hashPin(parentPin),
        requestedAtMs: DateTime.now().millisecondsSinceEpoch,
        status: JoinRequestStatus.pending,
      );
      await _root
          .child(FirebaseConfig.joinRequestPath(circleId, _auth.uid!))
          .set(req.toMap());
      await _savePendingCircle(circleId);
      _myRequest = req;
      notifyListeners();
      watchMyRequest(circleId);
      return (req, null);
    } catch (e) {
      return (null, trf(isUrdu, 'svc_joinRequestFailed', {'e': e.toString()}));
    }
  }

  /// Listen to MY request node (child waiting screen). The
  /// listener stays live until [stopWatchingMyRequest].
  void watchMyRequest(String circleId) {
    if (!isAvailable || _auth.uid == null) return;
    _mySub?.cancel();
    _mySub = _root
        .child(FirebaseConfig.joinRequestPath(circleId, _auth.uid!))
        .onValue
        .listen((event) {
      _myRequest = JoinRequest.fromMap(
        circleId,
        _auth.uid!,
        event.snapshot.value,
      );
      notifyListeners();
    });
  }

  /// One-time read of MY request (resume after a restart).
  Future<JoinRequest?> fetchMyRequest(String circleId) async {
    if (!isAvailable || _auth.uid == null) return null;
    try {
      final snap = await _root
          .child(FirebaseConfig.joinRequestPath(circleId, _auth.uid!))
          .get();
      final req = JoinRequest.fromMap(circleId, _auth.uid!, snap.value);
      _myRequest = req;
      notifyListeners();
      return req;
    } catch (_) {
      return null;
    }
  }

  void stopWatchingMyRequest() {
    _mySub?.cancel();
    _mySub = null;
  }

  /// Clear the stored pending circle (joined, denied-and-retried,
  /// or the child gave up). Does NOT delete the server node.
  Future<void> clearPendingCircle() => _savePendingCircle(null);

  /// v0.6.31: the child backs out of the join (wrong role tapped
  /// by mistake). Delete MY pending request node on the server
  /// (best effort — the rules let the owner delete their own
  /// pending request from v7+delete; until those rules are live
  /// the remove is refused and the node simply lingers as
  /// pending, which the parent can Deny), then clear the local
  /// pending state either way so the child is never stuck.
  Future<void> cancelMyRequest() async {
    final circleId = _pendingCircleId;
    _myRequest = null;
    stopWatchingMyRequest();
    if (circleId != null && isAvailable && _auth.uid != null) {
      try {
        await _root
            .child(FirebaseConfig.joinRequestPath(circleId, _auth.uid!))
            .remove();
      } catch (_) {
        // Server node lingers as pending — the parent can Deny
        // it; the child is unblocked regardless.
      }
    }
    await clearPendingCircle();
    notifyListeners();
  }

  // --- parent side ---

  final Map<String, JoinRequest> _circleRequests = {};

  /// Pending requests in the watched (active) circle, newest first.
  List<JoinRequest> get pendingRequests {
    final list = _circleRequests.values
        .where((r) => r.status == JoinRequestStatus.pending)
        .toList();
    list.sort((a, b) => b.requestedAtMs.compareTo(a.requestedAtMs));
    return List.unmodifiable(list);
  }

  /// Pending counts per circle, from [refreshAllPending] — so a
  /// request in a non-active circle is still visible on Home.
  final Map<String, int> _pendingByCircle = {};
  Map<String, int> get pendingByCircle => Map.unmodifiable(_pendingByCircle);

  StreamSubscription<DatabaseEvent>? _circleSub;
  String? _watchingCircleId;

  /// Live-listen to one circle's requests (parent, active circle).
  /// Idempotent per circle — a second call for the same circle is
  /// a no-op, a switch re-subscribes.
  void watchCircleRequests(String circleId) {
    if (_watchingCircleId == circleId) return;
    _circleSub?.cancel();
    _watchingCircleId = circleId;
    _circleRequests.clear();
    if (!isAvailable) return;
    _circleSub = _root
        .child(FirebaseConfig.joinRequestsPath(circleId))
        .onValue
        .listen((event) {
      _circleRequests.clear();
      final raw = event.snapshot.value;
      if (raw is Map) {
        for (final entry in raw.entries) {
          final req = JoinRequest.fromMap(
            circleId,
            entry.key.toString(),
            entry.value,
          );
          if (req != null) _circleRequests[req.uid] = req;
        }
      }
      _pendingByCircle[circleId] = pendingRequests.length;
      notifyListeners();
    });
  }

  /// One-time pending counts across every circle this phone
  /// parents (Home init — the live listener only covers the
  /// active circle).
  Future<void> refreshAllPending(List<CircleInfo> adminCircles) async {
    if (!isAvailable) return;
    for (final c in adminCircles) {
      try {
        final snap = await _root
            .child(FirebaseConfig.joinRequestsPath(c.id))
            .get();
        var count = 0;
        final raw = snap.value;
        if (raw is Map) {
          for (final entry in raw.entries) {
            final req = JoinRequest.fromMap(
              c.id,
              entry.key.toString(),
              entry.value,
            );
            if (req != null && req.status == JoinRequestStatus.pending) {
              count++;
            }
          }
        }
        _pendingByCircle[c.id] = count;
      } catch (_) {
        // One circle's read failing must not hide the others.
      }
    }
    notifyListeners();
  }

  /// Does this request's typed PIN match the circle's real parent
  /// PIN? Null hash = cannot verify (parent on a new phone whose
  /// PIN was never recovered) — the parent then decides by hand.
  static bool pinMatches(JoinRequest req, String? pinHash) =>
      pinHash != null && req.pinHashAttempt == pinHash;

  /// Auto-deny every pending request whose PIN hash does not match
  /// the circle's real PIN. Runs when the parent's app starts
  /// watching a circle — the child gets a fast "code ghalat tha"
  /// without the parent having to look.
  Future<void> verifyPendingRequests(
    String circleId,
    String? pinHash,
  ) async {
    if (pinHash == null || !isAvailable) return;
    for (final req in pendingRequests) {
      if (req.circleId != circleId) continue;
      if (!pinMatches(req, pinHash)) {
        await deny(circleId, req.uid, reason: JoinDenyReason.wrongCode);
      }
    }
  }

  Future<bool> approve(String circleId, String uid) async {
    if (!isAvailable) return false;
    try {
      await _root.child(FirebaseConfig.joinRequestPath(circleId, uid)).update({
        'status': JoinRequestStatus.approved.name,
        'decidedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deny(
    String circleId,
    String uid, {
    String reason = JoinDenyReason.parentDenied,
  }) async {
    if (!isAvailable) return false;
    try {
      await _root.child(FirebaseConfig.joinRequestPath(circleId, uid)).update({
        'status': JoinRequestStatus.denied.name,
        'reason': reason,
        'decidedAtMs': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _mySub?.cancel();
    _circleSub?.cancel();
    super.dispose();
  }
}
