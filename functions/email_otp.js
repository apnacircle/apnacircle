/**
 * ApnaCircle — 6-digit EMAIL OTP, pure helpers (v0.6).
 *
 * WHY THIS FILE EXISTS: Firebase Auth has NO built-in 6-digit
 * email code (only a verification LINK). The code flow is built
 * here with a Cloud Function + an email sender (see index.js):
 *   requestEmailCode -> 6-digit code sent to the Gmail inbox
 *   verifyEmailCode  -> code checked -> custom token -> sign-in
 *
 * SECURITY RULES (do not weaken):
 * * The code itself is NEVER stored — only its SHA-256 hash.
 * * The code itself is NEVER logged anywhere.
 * * The email address is never stored raw either — the RTDB key
 *   is SHA-256 of the lower-cased email.
 * * A code lives 10 minutes and dies after 5 wrong tries.
 * * Max 5 codes per hour per email (abuse / spam protection).
 *
 * These helpers are pure (no Firebase, no network) so they can be
 * unit-tested with plain `node --test` — see email_otp.test.js.
 * The same constants are mirrored in Dart (EmailOtpLogic) — keep
 * the two in sync.
 */
const crypto = require('crypto');

/** A code is valid for 10 minutes. */
const CODE_TTL_MS = 10 * 60 * 1000;
/** Max wrong tries per code — then the code is deleted. */
const MAX_ATTEMPTS = 5;
/** Max codes sent per email per hour. */
const MAX_CODES_PER_HOUR = 5;
/** Rate-limit window: 1 hour. */
const RATE_WINDOW_MS = 60 * 60 * 1000;

/** SHA-256 hex of a string (never store or log the raw code). */
function sha256Hex(value) {
  return crypto
    .createHash('sha256')
    .update(String(value), 'utf8')
    .digest('hex');
}

/** Lower-case + trim — the same email in any case is one account. */
function normalizeEmail(email) {
  return String(email || '')
    .trim()
    .toLowerCase();
}

/** Plain sanity check — the real check is "can we send to it". */
function isValidEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(normalizeEmail(email));
}

/** Exactly 6 digits, nothing else. */
function isValidCode(code) {
  return /^\d{6}$/.test(String(code || '').trim());
}

/** RTDB key for an email — a hash, never the raw address. */
function emailKey(email) {
  return sha256Hex(normalizeEmail(email));
}

/** Random 6-digit code as a string ("100000"–"999999"). */
function makeCode() {
  return String(crypto.randomInt(100000, 1000000));
}

/** True when the code's expiry time has passed. */
function isExpired(expiresAt, nowMs) {
  return Number(nowMs) >= Number(expiresAt);
}

/** Tries left before the code locks (0 = locked). */
function attemptsLeft(attempts) {
  return Math.max(0, MAX_ATTEMPTS - Number(attempts || 0));
}

/** True while another wrong try is still allowed. */
function canAttempt(attempts) {
  return Number(attempts || 0) < MAX_ATTEMPTS;
}

/**
 * Rate limit: may another code be sent now?
 * `count`/`windowStart` are the stored values from
 * `emailCodeRequests/{emailKey}` (or undefined on first send).
 * A window older than an hour resets — the caller stores count 1.
 */
function rateLimitAllows(count, windowStart, nowMs) {
  if (!windowStart || Number(nowMs) - Number(windowStart) >= RATE_WINDOW_MS) {
    return true;
  }
  return Number(count || 0) < MAX_CODES_PER_HOUR;
}

module.exports = {
  CODE_TTL_MS,
  MAX_ATTEMPTS,
  MAX_CODES_PER_HOUR,
  RATE_WINDOW_MS,
  sha256Hex,
  normalizeEmail,
  isValidEmail,
  isValidCode,
  emailKey,
  makeCode,
  isExpired,
  attemptsLeft,
  canAttempt,
  rateLimitAllows,
};
