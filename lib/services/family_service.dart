import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/alerts.dart';
import '../core/constants.dart';
import '../models/member.dart';

/// Family circle state: members (MAX 10), alerts, places.
///
/// v0.1 persistence: SharedPreferences (local, on-device).
/// PRODUCTION (TODO, before Play launch): Firebase Realtime Database
/// for live location + remote parent control, Firebase Cloud
/// Messaging for alerts, Firebase Auth for accounts. The API of this
/// class stays the same — only the storage layer changes — so the
/// screens do not need rewriting.
class FamilyService extends ChangeNotifier {
  static const _membersKey = 'family_members_v1';

  final List<Member> _members = [];
  List<Member> get members => List.unmodifiable(_members);
  int get memberCount => _members.length;
  bool get isFull => _members.length >= AppConstants.maxFamilyMembers;

  Member? get me => _members.isEmpty ? null : _members.first;

  /// Add a member. Returns false (and adds nobody) when the circle
  /// is already full at 10 — enforced here AND on the server.
  bool addMember(Member member) {
    if (isFull) return false;
    if (_members.any((m) => m.phone == member.phone)) return false;
    _members.add(member);
    _save();
    notifyListeners();
    return true;
  }

  bool removeMember(String id) {
    final before = _members.length;
    _members.removeWhere((m) => m.id == id);
    if (_members.length == before) return false;
    _save();
    notifyListeners();
    return true;
  }

  /// Update one member's live location (called by LocationService).
  void updateLocation(String id, double lat, double lon, DateTime at) {
    final i = _members.indexWhere((m) => m.id == id);
    if (i < 0) return;
    _members[i] =
        _members[i].copyWith(lat: lat, lon: lon, lastSeen: at, isOnline: true);
    _save();
    notifyListeners();
  }

  /// Parent-only: change one alert for one member. The caller (UI)
  /// must already have verified the parent PIN — see AlertsScreen.
  /// TODO(v0.2): sync this change to the member's phone via Firebase.
  void setAlert(String memberId, AlertType type, bool value) {
    final i = _members.indexWhere((m) => m.id == memberId);
    if (i < 0) return;
    final alerts = Map<AlertType, bool>.of(_members[i].alerts)
      ..[type] = value;
    _members[i] = _members[i].copyWith(alerts: alerts);
    _save();
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
    notifyListeners();
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
    if (raw == null) return;
    _members
      ..clear()
      ..addAll(
        (jsonDecode(raw) as List).map((e) => Member.fromJson(e as Map<String, dynamic>)),
      );
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _membersKey,
      jsonEncode(_members.map((m) => m.toJson()).toList()),
    );
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
}
