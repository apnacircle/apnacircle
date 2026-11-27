/// Removal detection (v0.6.27) — the "removed member comes back"
/// bug.
///
/// Root cause, found 27 Nov 2026: the parent removes a member
/// (their member node is deleted), but the removed phone's
/// background location service keeps publishing with a blind
/// `update()` — no read first — and the old rules let anyone
/// write their own member node, so within 60 seconds the node
/// was re-created, membership was restored, and the alerts
/// resumed. Rules v5 close the server side; this file is the
/// app side: notice that you were removed, verify it is real
/// (not a transient auth glitch), and stop everything.
///
/// The decision is deliberately fail-open: only a PROVEN
/// removal (permission-denied, or the node definitely gone)
/// stops sharing. A check that itself failed (no network,
/// unknown error) changes nothing — the next cycle tries again.
library;

import 'package:firebase_core/firebase_core.dart';

/// True when [error] is an RTDB "permission denied" — the
/// signature of a removed member: the circle-level read rule
/// denies anyone whose member node is gone.
bool isPermissionDeniedError(Object error) =>
    error is FirebaseException && error.code == 'permission-denied';

/// Should this phone treat itself as removed from the circle,
/// given a membership check that returned [memberNodeExists]?
/// `true` = the node exists, keep sharing. `false` = the node
/// is definitely gone (or the read was permission-denied), stop.
/// `null` = the check itself failed — keep sharing, try again
/// next cycle. Never stop on an unknown.
bool shouldTreatAsRemoved({required bool? memberNodeExists}) =>
    memberNodeExists == false;
