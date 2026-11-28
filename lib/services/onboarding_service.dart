import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-run onboarding state (v0.6.30) — persisted, asked ONCE.
///
/// After the language screen the app asks WHO is using this phone:
/// * 'parent' — the admin: creates the circle, sets the PIN, pays
///   (or starts the free trial), turns everything on. Their own
///   apps are never locked (v0.6.28).
/// * 'child' — joins the parent's circle: Gmail login + the
///   parent's PIN + a join REQUEST the parent must approve. A
///   child NEVER sees the trial / payment screens.
///
/// The role is per PHONE (this install), not per account — the
/// parent's phone is the parent phone, the child's phone is the
/// child phone. A wrong tap is undoable (v0.6.31): every
/// onboarding step has a back arrow — role -> language,
/// plan / join -> role — and Settings offers "Role badlein"
/// while this phone has no circles yet. Once a circle exists
/// the role is proven by membership instead.
class OnboardingService extends ChangeNotifier {
  static const _roleKey = 'onboarding_role_v1';
  static const _planChoiceKey = 'onboarding_plan_choice_v1';
  static const _joinSkippedKey = 'onboarding_join_skipped_v1';

  /// 'parent' | 'child' | null (not chosen yet).
  String? _role;
  String? get role => _role;
  bool get isParent => _role == 'parent';
  bool get isChild => _role == 'child';
  bool get hasChosenRole => _role != null;

  /// Parent only: the trial / subscribe choice was made (trial
  /// started, subscribe viewed, or "baad mein" tapped) — the
  /// choice screen never shows again after that.
  bool _planChoiceDone = false;
  bool get planChoiceDone => _planChoiceDone;

  /// Child only: "Abhi nahi — baad mein join karunga" was tapped
  /// on the join screen (demo mode, or the child will join later
  /// from Account & Circles). The join screen never nags again
  /// after that on this phone.
  bool _joinSkipped = false;
  bool get joinSkipped => _joinSkipped;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _role = prefs.getString(_roleKey);
    _planChoiceDone = prefs.getBool(_planChoiceKey) ?? false;
    _joinSkipped = prefs.getBool(_joinSkippedKey) ?? false;
    notifyListeners();
  }

  Future<void> chooseRole(String role) async {
    assert(role == 'parent' || role == 'child');
    _role = role;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_roleKey, role);
    notifyListeners();
  }

  /// v0.6.31: go back — forget the role (and the plan choice /
  /// join skip that came with it) so the role screen shows
  /// again. AppRoot re-routes by itself on the notify.
  Future<void> clearRole() async {
    _role = null;
    _planChoiceDone = false;
    _joinSkipped = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_roleKey);
    await prefs.remove(_planChoiceKey);
    await prefs.remove(_joinSkippedKey);
    notifyListeners();
  }

  Future<void> markPlanChoiceDone() async {
    _planChoiceDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_planChoiceKey, true);
    notifyListeners();
  }

  Future<void> markJoinSkipped() async {
    _joinSkipped = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_joinSkippedKey, true);
    notifyListeners();
  }
}
