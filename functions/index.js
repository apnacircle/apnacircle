/**
 * ApnaCircle Cloud Functions — REAL phone-to-phone push (v0.5).
 *
 * PROBLEM IT SOLVES: the app's SOS / alerts travel through the
 * Realtime Database `events` node, which the parent's phone only
 * sees while the app is open. A push that wakes a closed app needs
 * a server — this function IS that server.
 *
 * HOW IT WORKS: whenever a new event is written to
 * `circles/{circleId}/events/{eventId}` (SOS, battery-low,
 * phone-off, SIM-changed, admin-disabled), the function looks up
 * every OTHER member of that circle, reads their FCM token from
 * `users/{uid}/profile/fcmToken` (the app stores it there on
 * sign-in — see NotificationService), and sends them a high
 * priority FCM notification.
 *
 * WHAT IT NEVER DOES: it never contains a server key (the Admin
 * SDK uses Application Default Credentials from `firebase deploy`),
 * never reads locations except the one already in the event, and
 * never sends to anyone outside the circle.
 *
 * PLAN NOTE: this uses the v1 (1st-gen) database trigger on
 * purpose — v1 functions deploy on the free Spark plan. The v2
 * (Cloud Run) triggers need a billing account (Blaze). Do NOT
 * "upgrade" this to v2 without asking Mujahid first (card rule).
 *
 * DEPLOY (parent's step — needs `firebase login` once):
 *   cd apnacircle-app
 *   npm --prefix functions install
 *   firebase deploy --only functions
 * See FIREBASE_SETUP.md §4 for the full steps.
 */
const functions = require('firebase-functions');
const admin = require('firebase-admin');
const { getDatabaseWithUrl } = require('firebase-admin/database');
const crypto = require('crypto');
const nodemailer = require('nodemailer');
const otp = require('./email_otp');

admin.initializeApp();

// The database lives in asia-southeast1, NOT the default
// us-central1 instance — without the explicit URL the Admin SDK
// would talk to a database that does not exist. (firebase-admin
// v12: use getDatabaseWithUrl, not admin.database(url).)
const db = getDatabaseWithUrl(
  'https://apnacircle-22ef3-default-rtdb.asia-southeast1.firebasedatabase.app',
);

const TITLES = {
  sos: 'SOS!',
  lowBattery: 'Battery low',
  phoneOff: 'Phone off',
  internetOff: 'Internet off',
  simChanged: 'SIM card changed',
  adminDisabled: 'Protection turned off',
};

function bodyFor(event) {
  const name = event.fromName || 'A family member';
  switch (event.type) {
    case 'sos':
      return `${name} pressed SOS — check on them now.`;
    case 'lowBattery':
      return `${name}'s phone battery is low.`;
    case 'phoneOff':
      return `${name}'s phone went off. Last location saved.`;
    case 'internetOff':
      return `${name}'s phone lost internet. Last location saved.`;
    case 'simChanged':
      return `A different SIM was detected in ${name}'s phone.`;
    case 'adminDisabled':
      return `Uninstall protection was turned off on ${name}'s phone.`;
    default:
      return `${name} sent a family alert.`;
  }
}

exports.sendCircleEventPush = functions.database
  .instance('apnacircle-22ef3-default-rtdb')
  .ref('/circles/{circleId}/events/{eventId}')
  .onCreate(async (snapshot, context) => {
    const event = snapshot.val() || {};
    const { circleId, eventId } = context.params;
    const type = event.type || 'alert';

    // Who is in this circle? Everyone except the sender.
    const membersSnap = await db
      .ref(`circles/${circleId}/members`)
      .once('value');
    const members = membersSnap.val() || {};
    const uids = Object.keys(members).filter(
      (uid) => uid && uid !== event.fromUid,
    );
    if (uids.length === 0) {
      functions.logger.log('No other members to notify', { circleId });
      return null;
    }

    // Each member's FCM token (stored by the app on sign-in).
    const tokens = [];
    for (const uid of uids) {
      const profileSnap = await db
        .ref(`users/${uid}/profile/fcmToken`)
        .once('value');
      const token = profileSnap.val();
      if (typeof token === 'string' && token.length > 0) tokens.push(token);
    }
    if (tokens.length === 0) {
      functions.logger.log('No FCM tokens for circle members', { circleId });
      return null;
    }

    const message = {
      tokens,
      notification: {
        title: TITLES[type] || 'ApnaCircle alert',
        body: bodyFor(event),
      },
      data: {
        type: String(type),
        circleId: String(circleId),
        eventId: String(eventId),
        fromUid: String(event.fromUid || ''),
      },
      android: { priority: 'high' },
    };

    const response = await admin.messaging().sendEachForMulticast(message);
    functions.logger.log('Push sent', {
      circleId,
      type,
      success: response.successCount,
      failure: response.failureCount,
    });
    return null;
  });

// ---------------------------------------------------------------------------
// Family CHAT push (v0.6.11) — WhatsApp-style: "Ali: Ghar pahunch
// gaya."
//
// Trigger: a message written to `circles/{circleId}/chat/{messageId}`.
// Sends the OTHER members a push with the sender's name as the
// title and a short preview as the body. NEVER notifies the sender.
//
// DATA-ONLY ON PURPOSE: the app shows the push itself on the
// "ApnaCircle Chat" channel (normal importance, sound + vibration
// — NOT the loud emergency channel). If this carried a
// `notification` payload, the system would display it on the
// default channel instead, and a chat message would ring like an
// SOS. See lib/services/notification_service.dart
// (firebaseMessagingBackgroundHandler).
// ---------------------------------------------------------------------------

/** Short preview of a chat message (mirrors the app's snippet). */
function chatSnippet(text) {
  const t = String(text || '')
    .trim()
    .replace(/\s+/g, ' ');
  if (t.length <= 120) return t;
  return `${t.slice(0, 120).trimEnd()}…`;
}

exports.sendChatMessagePush = functions.database
  .instance('apnacircle-22ef3-default-rtdb')
  .ref('/circles/{circleId}/chat/{messageId}')
  .onCreate(async (snapshot, context) => {
    const msg = snapshot.val() || {};
    const { circleId, messageId } = context.params;
    const text = String(msg.text || '').trim();
    if (!text) return null; // Empty message — nothing to preview.

    // Who is in this circle? Everyone except the sender.
    const membersSnap = await db
      .ref(`circles/${circleId}/members`)
      .once('value');
    const members = membersSnap.val() || {};
    const uids = Object.keys(members).filter(
      (uid) => uid && uid !== msg.senderId,
    );
    if (uids.length === 0) {
      functions.logger.log('No other members to notify (chat)', {
        circleId,
      });
      return null;
    }

    // Each member's FCM token (stored by the app on sign-in).
    const tokens = [];
    for (const uid of uids) {
      const profileSnap = await db
        .ref(`users/${uid}/profile/fcmToken`)
        .once('value');
      const token = profileSnap.val();
      if (typeof token === 'string' && token.length > 0) tokens.push(token);
    }
    if (tokens.length === 0) {
      functions.logger.log('No FCM tokens for circle members (chat)', {
        circleId,
      });
      return null;
    }

    const senderName = String(msg.senderName || 'A family member');
    const message = {
      tokens,
      // DATA-ONLY — see the note above. The app builds the visible
      // notification on the chat channel itself.
      data: {
        type: 'chat',
        circleId: String(circleId),
        messageId: String(messageId),
        fromUid: String(msg.senderId || ''),
        senderName,
        preview: chatSnippet(text),
      },
      android: { priority: 'high' },
      apns: { payload: { aps: { 'content-available': 1 } } },
    };

    const response = await admin.messaging().sendEachForMulticast(message);
    functions.logger.log('Chat push sent', {
      circleId,
      success: response.successCount,
      failure: response.failureCount,
    });
    return null;
  });

// ---------------------------------------------------------------------------
// 6-digit EMAIL OTP login (v0.6).
//
// Firebase Auth has NO built-in 6-digit email code — only a
// verification link. This is the real code flow, built on purpose:
//   app: requestEmailCode({email}) -> code lands in the Gmail inbox
//   app: verifyEmailCode({email, code}) -> custom token -> sign-in
//
// STORAGE (RTDB, Admin SDK only — no client ever reads these):
//   emailCodes/{sha256(email)}: {codeHash, expiresAt, attempts}
//   emailCodeRequests/{sha256(email)}: {count, windowStart}
// The code itself is NEVER stored and NEVER logged; the email is
// never stored raw (the key is its SHA-256). A code lives 10
// minutes, dies after 5 wrong tries, max 5 codes/hour per email.
//
// SMTP: nodemailer, configured ONLY from environment —
//   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM.
// No credential, password or email address is hardcoded here or
// anywhere in the repo. If SMTP is not configured the function
// returns a clear error and NEVER pretends the code was sent.
//
// SPARK-PLAN HONEST NOTE: the free Spark plan only allows outbound
// traffic to Google services, and SMTP sending from a function is
// routinely reported blocked on Spark — so the first real code
// email may fail with `email-send-failed` until Blaze (billing) is
// attached. That is Mujahid's decision (same as Phone OTP); the
// code + deploy work on Spark, live sending waits on that call.
// See FIREBASE_SETUP.md §4 for the deploy + SMTP setup.
// ---------------------------------------------------------------------------

/** Nodemailer transporter from env, or null when SMTP is unset. */
function smtpTransporter() {
  const host = process.env.SMTP_HOST;
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;
  if (!host || !user || !pass) return null;
  const port = Number(process.env.SMTP_PORT || 587);
  return nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: { user, pass },
  });
}

/**
 * requestEmailCode — send a fresh 6-digit code to a Gmail inbox.
 * Input: {email}. Returns {ok: true, expiresInSeconds: 600}.
 * Errors (message = stable slug, read it in the app):
 *   email-invalid | too-many-requests | email-not-configured |
 *   email-send-failed
 */
exports.requestEmailCode = functions.https.onCall(async (data) => {
  const email = otp.normalizeEmail(data && data.email);
  if (!otp.isValidEmail(email)) {
    throw new functions.https.HttpsError('invalid-argument', 'email-invalid');
  }
  const key = otp.emailKey(email);
  const now = Date.now();

  // Rate limit first — max 5 codes/hour per email.
  const rateRef = db.ref(`emailCodeRequests/${key}`);
  const rateSnap = await rateRef.once('value');
  const rate = rateSnap.val() || {};
  if (!otp.rateLimitAllows(rate.count, rate.windowStart, now)) {
    throw new functions.https.HttpsError(
      'resource-exhausted',
      'too-many-requests',
    );
  }

  // Store ONLY the hash (never the code), then send.
  const code = otp.makeCode();
  const codeRef = db.ref(`emailCodes/${key}`);
  await codeRef.set({
    codeHash: otp.sha256Hex(code),
    expiresAt: now + otp.CODE_TTL_MS,
    attempts: 0,
  });

  const transporter = smtpTransporter();
  if (!transporter) {
    // No SMTP configured — remove the unsent code, say so clearly.
    await codeRef.remove();
    throw new functions.https.HttpsError(
      'failed-precondition',
      'email-not-configured',
    );
  }
  const from = process.env.SMTP_FROM || process.env.SMTP_USER;
  try {
    await transporter.sendMail({
      from,
      to: email,
      subject: 'Your ApnaCircle login code',
      text:
        `Your ApnaCircle login code is ${code}.\n\n` +
        'It works for 10 minutes. Never share it with anyone — ' +
        'ApnaCircle will never ask for your code.\n\n' +
        'If you did not ask for this code, ignore this email.',
    });
  } catch (e) {
    functions.logger.error('Email code send failed', {
      error: String((e && e.message) || e),
    });
    await codeRef.remove();
    throw new functions.https.HttpsError(
      'unavailable',
      'email-send-failed',
    );
  }

  // Count the send against the hourly limit (only after a real send).
  const freshWindow =
    !rate.windowStart || now - rate.windowStart >= otp.RATE_WINDOW_MS;
  await rateRef.set({
    count: freshWindow ? 1 : (rate.count || 0) + 1,
    windowStart: freshWindow ? now : rate.windowStart,
  });
  // Deliberately no code — and no email — in any log line.
  functions.logger.log('Email login code sent');
  return { ok: true, expiresInSeconds: otp.CODE_TTL_MS / 1000 };
});

/**
 * verifyEmailCode — check the code, mint a custom token.
 * Input: {email, code}. Returns {token} on success.
 * Errors (message = stable slug):
 *   email-invalid | code-wrong | code-not-found | code-expired |
 *   too-many-attempts
 * A wrong try increments `attempts` (5 = locked, code deleted).
 * On success the code entry is deleted and the Auth user is
 * found-or-created (emailVerified: true — the inbox proved it).
 */
exports.verifyEmailCode = functions.https.onCall(async (data) => {
  const email = otp.normalizeEmail(data && data.email);
  const code = String((data && data.code) || '').trim();
  if (!otp.isValidEmail(email)) {
    throw new functions.https.HttpsError('invalid-argument', 'email-invalid');
  }
  if (!otp.isValidCode(code)) {
    throw new functions.https.HttpsError('invalid-argument', 'code-wrong');
  }
  const key = otp.emailKey(email);
  const codeRef = db.ref(`emailCodes/${key}`);
  const snap = await codeRef.once('value');
  const entry = snap.val();
  if (!entry || !entry.codeHash) {
    throw new functions.https.HttpsError('not-found', 'code-not-found');
  }
  if (otp.isExpired(entry.expiresAt, Date.now())) {
    await codeRef.remove();
    throw new functions.https.HttpsError(
      'failed-precondition',
      'code-expired',
    );
  }
  if (!otp.canAttempt(entry.attempts)) {
    await codeRef.remove();
    throw new functions.https.HttpsError(
      'resource-exhausted',
      'too-many-attempts',
    );
  }

  // Constant-time compare of the two SHA-256 hex digests.
  const given = Buffer.from(otp.sha256Hex(code), 'utf8');
  const stored = Buffer.from(String(entry.codeHash), 'utf8');
  const match =
    given.length === stored.length && crypto.timingSafeEqual(given, stored);
  if (!match) {
    const attempts = (entry.attempts || 0) + 1;
    await codeRef.update({ attempts });
    throw new functions.https.HttpsError('invalid-argument', 'code-wrong', {
      attemptsLeft: otp.attemptsLeft(attempts),
    });
  }

  // Success: find-or-create the Firebase Auth user, mint a token.
  let uid;
  try {
    const existing = await admin.auth().getUserByEmail(email);
    uid = existing.uid;
  } catch (e) {
    if (e && e.code === 'auth/user-not-found') {
      const created = await admin.auth().createUser({
        email,
        emailVerified: true,
      });
      uid = created.uid;
    } else {
      throw e;
    }
  }
  const token = await admin.auth().createCustomToken(uid);
  await codeRef.remove();
  functions.logger.log('Email code verified, custom token minted');
  return { token };
});
