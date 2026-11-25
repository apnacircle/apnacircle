import '../services/pin_service.dart';
import '../services/sync_service.dart';

/// Parent-PIN gate on the in-app escape hatches (v0.6.13, part E).
///
/// The user's order (25 Nov 2026): "bacha app del kry tu code
/// mangay" — when the child tries to delete the app, it must ask
/// for a code (the parent PIN). The system uninstall screen itself
/// is owned by Android — no app can put a PIN prompt on it, and
/// that honest boundary stays in README + in-app text (Device
/// Admin / Device Owner are the enforcement there). But everything
/// the child can do INSIDE the app to escape must demand the
/// parent's code:
///
/// * "Delete my account" — child role: parent PIN first.
/// * "Sign out" — child role: same gate (signing out is how a child
///   drops out of the circle silently).
/// * Disabling Device Admin from inside the app — child role: same
///   gate.
///
/// Parent role: NEVER gated. Demo mode (no circle): no parent PIN
/// exists, so nothing is gated. The lock-screen / app-lock PIN
/// behaviour is untouched.
///
/// The gate is pure where it can be (role check + hash verify) so
/// it is unit-tested; the hash resolution (local PIN first, then
/// the circle's stored hash from the server) is the only
/// network-touching part.

/// True when this role must pass the parent PIN before using an
/// escape hatch: a CHILD in a circle. Every other role — parent,
/// elderly, member — and demo mode (no role) are unaffected.
bool childEscapeNeedsParentPin(String? role) => role == 'child';

/// Verify an entered PIN against a stored hash. Same scheme as
/// LockActivity and PinService: SHA-256 of "apnacircle:<pin>".
/// Wrong PIN = false, with no hint about the right one.
bool verifyPinAgainstHash(String pin, String expectedHash) =>
    PinService.hashPin(pin) == expectedHash;

/// Resolve the parent PIN hash to verify against: the PIN stored on
/// THIS phone first (the parent's phone has it), otherwise the
/// circle's stored hash from the server (the parent publishes it at
/// PIN setup, so a child's phone can verify without the parent
/// being present). Null when no hash can be found — the caller must
/// then FAIL CLOSED (block the escape), never let it through.
Future<String?> resolveParentPinHash({
  required SyncService sync,
  required PinService pin,
}) async {
  if (pin.pinHash != null) return pin.pinHash;
  final circleId = sync.activeCircleId;
  if (circleId == null) return null;
  return await sync.fetchPinHash(circleId);
}
