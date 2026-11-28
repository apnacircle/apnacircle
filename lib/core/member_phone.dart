import '../l10n/strings.dart';
import 'call_member_cache.dart';

/// A member's mobile number, set by the parent (v0.6.14, 25 Nov 2026).
///
/// WHY THIS EXISTS: members who signed in with Gmail have NO phone
/// number — `SyncService._writeMyMemberNode` sets
/// `phone: _auth.phoneNumber ?? _auth.email ?? ''`, so a Gmail
/// member's `phone` field is their EMAIL. The SIM-call overlay
/// matches the incoming number against member `phone` fields, so an
/// email can NEVER match a real call: no card appeared at all, not
/// just a wrong distance ("na card na distance"). There was no UI
/// anywhere to set a member's number. The parent now enters each
/// member's real SIM number once (Locks screen, PIN-gated); it is
/// written to the member's RTDB node and flows into the call-member
/// cache on the next save, so the overlay can match.
///
/// RULES: parent-only, and never for their own number — a member
/// must not be able to change (or break) the number the overlay
/// matches on. The number is validated here, in pure code, so it
/// is unit-tested: it must look like a phone number (10–13 digits
/// after normalization), never an email.

/// Validate + normalize a number the parent typed. Returns the
/// normalized number (`+92…`) and no error, or null + a plain-words
/// error for the SnackBar. Validation runs BEFORE the PIN prompt —
/// a bad number needs no code.
({String? number, String? error}) validateMemberPhone(String input,
    {bool isUrdu = false}) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return (number: null, error: tr(isUrdu, 'core_phoneEnterFirst'));
  }
  if (trimmed.contains('@')) {
    return (
      number: null,
      error: tr(isUrdu, 'core_phoneLooksLikeEmail'),
    );
  }
  if (RegExp(r'[A-Za-z]').hasMatch(trimmed)) {
    return (
      number: null,
      error: tr(isUrdu, 'core_phoneDigitsOnly'),
    );
  }
  final normalized = CallMemberCache.normalizePhoneNumber(trimmed);
  final digits = normalized.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 10 || digits.length > 13) {
    return (
      number: null,
      error: tr(isUrdu, 'core_phoneFullNumber'),
    );
  }
  return (number: normalized, error: null);
}

/// True when this stored `phone` value can EVER match a SIM call.
/// A real number can; an email (Gmail login) never can.
bool memberPhoneCanMatchCalls(String phone) {
  if (phone.contains('@')) return false;
  final digits = CallMemberCache.normalizePhoneNumber(phone)
      .replaceAll(RegExp(r'[^0-9]'), '');
  return digits.length >= 10 && digits.length <= 13;
}

/// Validate a join attempt's code + number together (v0.6.14):
/// joining now takes the 6-digit invite code AND the member's
/// mobile number — both required. Returns the plain-words refusal,
/// or null when both are fine. Pure — the service uses it, and it
/// is unit-tested. A Gmail login gives the app no number, so the
/// number must be typed at join time; without it the SIM-call
/// overlay can never match the member and no card appears.
String? validateJoinInput(
    {required String code, required String phone, bool isUrdu = false}) {
  final clean = code.trim();
  if (clean.length != 6 || int.tryParse(clean) == null) {
    return tr(isUrdu, 'core_joinInviteCode6');
  }
  if (phone.trim().isEmpty) {
    return tr(isUrdu, 'core_joinPhoneToo');
  }
  return validateMemberPhone(phone, isUrdu: isUrdu).error;
}

/// Parent-only guard for setting a member's number: only the
/// circle admin may set one, and never their own — a member must
/// not be able to change the number the overlay matches on. The
/// PIN prompt itself lives in the UI; this is the service-level
/// backstop (a child calling the service directly still fails).
bool canSetMemberPhone({
  required bool isAdmin,
  required String? myUid,
  required String targetMemberId,
}) =>
    isAdmin && myUid != null && myUid != targetMemberId;
