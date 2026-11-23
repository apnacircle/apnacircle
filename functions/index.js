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
