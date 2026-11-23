/**
 * Unit tests for functions/email_otp.js — pure logic only.
 * Run: `node --test email_otp.test.js` (from functions/).
 * No Firebase, no network, no credentials needed.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const otp = require('./email_otp');

test('code is always exactly 6 digits', () => {
  for (let i = 0; i < 200; i++) {
    const code = otp.makeCode();
    assert.match(code, /^\d{6}$/, code);
    assert.equal(otp.isValidCode(code), true);
  }
});

test('code format: rejects anything that is not 6 digits', () => {
  assert.equal(otp.isValidCode('12345'), false); // too short
  assert.equal(otp.isValidCode('1234567'), false); // too long
  assert.equal(otp.isValidCode('12345a'), false); // letter
  assert.equal(otp.isValidCode(''), false);
  assert.equal(otp.isValidCode(' 12345 '), false);
  assert.equal(otp.isValidCode('123456'), true);
  assert.equal(otp.isValidCode(' 123456 '), true); // trimmed
});

test('hash never equals the raw code and is stable', () => {
  const code = '482913';
  const h1 = otp.sha256Hex(code);
  const h2 = otp.sha256Hex(code);
  assert.equal(h1, h2);
  assert.equal(h1.length, 64); // SHA-256 hex
  assert.equal(h1.includes(code), false);
  assert.notEqual(otp.sha256Hex('482914'), h1);
});

test('email key hides the address and ignores case/space', () => {
  const k1 = otp.emailKey('Mujahid@Gmail.com');
  const k2 = otp.emailKey('  mujahid@gmail.com ');
  assert.equal(k1, k2);
  assert.equal(k1.length, 64);
  assert.equal(k1.includes('mujahid'), false);
  assert.notEqual(otp.emailKey('other@gmail.com'), k1);
});

test('email validation', () => {
  assert.equal(otp.isValidEmail('a@gmail.com'), true);
  assert.equal(otp.isValidEmail('A@Gmail.COM'), true);
  assert.equal(otp.isValidEmail('not-an-email'), false);
  assert.equal(otp.isValidEmail('a@b'), false);
  assert.equal(otp.isValidEmail(''), false);
});

test('expiry math: 10 minutes, then dead', () => {
  const now = 1700000000000;
  const expiresAt = now + otp.CODE_TTL_MS;
  assert.equal(otp.CODE_TTL_MS, 10 * 60 * 1000);
  assert.equal(otp.isExpired(expiresAt, now), false); // still valid
  assert.equal(otp.isExpired(expiresAt, expiresAt - 1), false); // 1 ms left
  assert.equal(otp.isExpired(expiresAt, expiresAt), true); // exactly at expiry: dead
  assert.equal(otp.isExpired(expiresAt, expiresAt + 1), true); // after: dead
});

test('attempt limit: 5 wrong tries, then locked', () => {
  assert.equal(otp.canAttempt(0), true);
  assert.equal(otp.canAttempt(4), true);
  assert.equal(otp.canAttempt(5), false);
  assert.equal(otp.canAttempt(9), false);
  assert.equal(otp.attemptsLeft(0), 5);
  assert.equal(otp.attemptsLeft(3), 2);
  assert.equal(otp.attemptsLeft(5), 0);
  assert.equal(otp.attemptsLeft(9), 0);
});

test('rate limit: 5 codes/hour, then blocked until the window passes', () => {
  const now = 1700000000000;
  const windowStart = now - 10 * 60 * 1000; // 10 min into the hour
  assert.equal(otp.rateLimitAllows(0, windowStart, now), true);
  assert.equal(otp.rateLimitAllows(4, windowStart, now), true);
  assert.equal(otp.rateLimitAllows(5, windowStart, now), false);
  assert.equal(otp.rateLimitAllows(9, windowStart, now), false);
  // No window yet, or an old window: allowed (caller resets to 1).
  assert.equal(otp.rateLimitAllows(undefined, undefined, now), true);
  assert.equal(
    otp.rateLimitAllows(5, now - 61 * 60 * 1000, now),
    true,
  );
});
