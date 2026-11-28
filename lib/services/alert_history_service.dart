import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import '../models/circle.dart';
import 'family_service.dart';
import 'firebase_config.dart';
import 'sync_service.dart';

/// The alerts centre (v0.6.21) — every SOS / alert the circle
/// has raised, separated PER MEMBER with a count, instead of one
/// mixed stream where nobody can tell whose alert it was.
///
/// Source of truth: the circle's `events` node in the Realtime
/// Database (the same node FamilyService listens to for live
/// alerts). The centre loads the latest 200 events and keeps
/// listening, so a new SOS appears while the app is open.
///
/// Unread = an event newer than the last time the centre was
/// opened (per circle, stored in SharedPreferences). Opening the
/// centre marks everything read — the bell badge clears, but the
/// per-member counts stay (they are totals, not unread counts).
///
/// Demo mode (no circle): no events — the centre is empty.
class AlertHistoryService extends ChangeNotifier {
  AlertHistoryService({
    required FamilyService family,
  }) : _family = family {
    _family.addListener(_onFamilyChanged);
    _loadSeen();
    _listenToEvents();
  }

  final FamilyService _family;

  DatabaseReference get _root => FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: FirebaseConfig.databaseUrl,
      ).ref();

  /// Latest 200 events, keyed by their RTDB push key (dedupes
  /// the initial load against the live listener).
  final Map<String, CircleEvent> _events = {};

  /// All loaded events, newest first — from CURRENT members
  /// only (v0.6.27). A removed member's old events stay in the
  /// `events` node (it is append-only — nobody can delete them),
  /// but they must not keep showing up in the parent's alerts
  /// centre after the removal. While the member list is still
  /// loading (empty) nothing is filtered — fail open, never hide
  /// a real SOS behind a loading state.
  List<CircleEvent> get events {
    final list = _events.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    return List.unmodifiable(filterAlertsToMembers(
      list,
      _family.members.map((m) => m.id).toSet(),
    ));
  }

  /// Events per member uid, newest first.
  Map<String, List<CircleEvent>> get eventsByMember {
    final map = <String, List<CircleEvent>>{};
    for (final e in events) {
      map.putIfAbsent(e.fromUid, () => []).add(e);
    }
    return map;
  }

  /// Total alerts per member uid (in the loaded window).
  Map<String, int> get countByMember {
    final map = <String, int>{};
    for (final e in events) {
      map[e.fromUid] = (map[e.fromUid] ?? 0) + 1;
    }
    return map;
  }

  DateTime? _lastSeenAt;

  /// Events newer than the last centre visit.
  List<CircleEvent> get unread => _lastSeenAt == null
      ? events
      : events.where((e) => e.at.isAfter(_lastSeenAt!)).toList();

  int get totalUnread => unread.length;

  /// Unread alerts per member uid.
  Map<String, int> get unreadByMember {
    final map = <String, int>{};
    for (final e in unread) {
      map[e.fromUid] = (map[e.fromUid] ?? 0) + 1;
    }
    return map;
  }

  StreamSubscription<DatabaseEvent>? _sub;

  void _onFamilyChanged() {
    _loadSeen();
    _listenToEvents();
  }

  String get _seenKey => 'alerts_seen_${_family.activeCircleId ?? 'none'}';

  Future<void> _loadSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_seenKey);
      _lastSeenAt = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      notifyListeners();
    } catch (_) {
      // A missing/corrupt seen-marker means "everything unread"
      // — safe, never a crash.
    }
  }

  void _listenToEvents() {
    unawaited(_sub?.cancel());
    _sub = null;
    _events.clear();
    final circleId = _family.activeCircleId;
    if (circleId == null || !_family.isSynced) {
      notifyListeners();
      return;
    }
    final ref =
        _root.child(FirebaseConfig.circleEventsPath(circleId)).limitToLast(200);
    _sub = ref.onChildAdded.listen((event) {
      final key = event.snapshot.key;
      final raw = event.snapshot.value;
      if (key == null || raw == null) return;
      try {
        _events[key] = CircleEvent.fromJson(SyncService.asMap(raw));
        notifyListeners();
      } catch (_) {
        // A malformed event must never break the centre.
      }
    });
  }

  /// Mark everything read — called when the centre sheet closes.
  Future<void> markAllRead() async {
    _lastSeenAt = DateTime.now();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _seenKey,
        _lastSeenAt!.millisecondsSinceEpoch,
      );
    } catch (_) {
      // Best effort — the badge clears in memory regardless.
    }
  }

  @override
  void dispose() {
    _family.removeListener(_onFamilyChanged);
    unawaited(_sub?.cancel());
    super.dispose();
  }
}

/// Keep only the alerts that come from CURRENT circle members
/// (v0.6.27 — a removed member's old events must stop showing in
/// the alerts centre). [memberIds] empty means the member list
/// is still loading — return everything (fail open: never hide a
/// real SOS behind a loading state). Pure, unit-tested.
List<CircleEvent> filterAlertsToMembers(
  List<CircleEvent> events,
  Set<String> memberIds,
) {
  if (memberIds.isEmpty) return List.unmodifiable(events);
  return events.where((e) => memberIds.contains(e.fromUid)).toList();
}

/// Plain-words label for one event type (v0.6.21). The stored
/// type is a code ('internetOff'); the centre shows what a
/// parent actually understands. An unknown type is shown as-is —
/// never hidden.
String alertTypeLabel(String type, {bool isUrdu = false}) {
  if (isUrdu) {
    return switch (type) {
      'lowBattery' => tr(true, 'svc_alertLowBattery'),
      'phoneOff' => tr(true, 'svc_alertPhoneOff'),
      'internetOff' => tr(true, 'svc_alertInternetOff'),
      'locationOff' => tr(true, 'svc_alertLocationOff'),
      'simChanged' => tr(true, 'svc_alertSimChanged'),
      'adminDisabled' => tr(true, 'svc_alertProtectionRemoved'),
      _ => type,
    };
  }
  return switch (type) {
    'sos' => 'SOS',
    'lowBattery' => 'Low battery',
    'phoneOff' => 'Phone switched off',
    'internetOff' => 'Internet off',
    'locationOff' => 'Location switched off',
    'simChanged' => 'SIM changed',
    'adminDisabled' => 'Protection removed',
    _ => type,
  };
}

/// Short time for one event: '26 Nov, 21:05' (EN) / '26 نومبر، 21:05' (UR).
String formatAlertTime(DateTime at, {bool isUrdu = false}) {
  const enMonths = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const urMonthKeys = [
    'svc_monthJan',
    'svc_monthFeb',
    'svc_monthMar',
    'svc_monthApr',
    'svc_monthMay',
    'svc_monthJun',
    'svc_monthJul',
    'svc_monthAug',
    'svc_monthSep',
    'svc_monthOct',
    'svc_monthNov',
    'svc_monthDec',
  ];
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  if (isUrdu) {
    return '${at.day} ${tr(true, urMonthKeys[at.month - 1])}، $hh:$mm';
  }
  return '${at.day} ${enMonths[at.month - 1]}, $hh:$mm';
}
