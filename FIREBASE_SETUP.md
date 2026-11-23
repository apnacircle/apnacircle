# ApnaCircle — Firebase setup checklist (v0.3)

**Status (22 Nov 2026 ~22:13 PKT): console DONE.** Project
`apnacircle` (ID `apnacircle-22ef3`, Spark free, Analytics OFF),
Android app `com.apnacircle.app`, `google-services.json` in
`android/app/` (gitignored). Realtime Database asia-southeast1,
locked mode, member-only rules published. Auth Phone ON +
Email/Password ON, Anonymous OFF. Cloud Messaging API (V1)
enabled. No card used. Code wiring (this repo, v0.3) is done —
what is left is the TWO-PHONE test (see §6), the rules check in
§2, and the CI note in §5.

## 1. Project (Firebase console — console.firebase.google.com)

1. **Add project** → naam: `apnacircle` → Google Analytics: OFF (chahiye to ON).
2. Android app add karein: package name **`com.apnacircle.app`** (yehi
   `android/app/build.gradle` mein hai — ghalat package se app connect
   nahi hogi).
3. **`google-services.json` download karein → `android/app/` mein rakhein.**
   Ye file `.gitignore` mein hai — git mein commit NAHI hogi, sahi hai.
   Is mein API key hoti hai, is liye is ko kabhi chat / WhatsApp par
   share na karein.

## 2. Realtime Database

1. Build → Realtime Database → Create database → **Locked mode** se shuru
   karein → Location: `asia-southeast1` (Singapore — Pakistan ke qareeb).
2. Data structure (code mein pehle se tay hai, `firebase_config.dart`):

```
circles/{circleId}/
  info/                 {name, inviteCode, createdBy, createdAt, pinHash}
  members/{memberId}/   lat, lon, battery, isOnline, lastSeen, role
  locks/{memberId}/     apps: [{package, locked, mode, window:{start,end,days}}]
  alerts/{memberId}/    {sos: true, lowBattery: true, ...}   // 14 alerts
  chat/                 [{from, text, at}]
  events/               [{type: sos/lowBattery/phoneOff, fromUid, fromName, at}]
trials/{deviceHash}/    {trialUsed, trialStartedAt, trialEndsAt (epoch ms), deviceHash}
                        — 7-day free trial, ONCE PER PHONE (23 Nov 2026).
                        Key = SHA-256 of the Android ID, never the raw id.
                        A different phone gets its own one trial; a
                        reinstall or a new account on the same phone
                        gets none. HONEST LIMIT: a factory reset
                        changes the Android ID, so a reset phone could
                        get a new trial — accepted, not hidden.
users/{uid}/
  profile/              {name, phone, email, fcmToken}
  circles/{circleId}/   role ('parent' | 'child' | 'elderly' | 'member')
invites/{6-digit code}/ circleId
```

3. Rules — **use the FULL text below, not just the circles block.**
   The plain "only members can read/write a circle" rule ALONE
   BREAKS joining: a child who is not a member yet cannot write
   their own member node, so they can never join. The rules below
   add the one exception that makes joining work — anyone signed
   in may write ONLY their own `members/{their-own-uid}` node —
   plus rules for the `users/` and `invites/` nodes the app writes
   to. **Check the published rules in the console and update them
   to this text, otherwise Create/Join circle fails with
   "permission denied".**

```json
{
  "rules": {
    "circles": {
      "$circleId": {
        "members": {
          "$memberId": {
            ".read": "auth != null && (auth.uid == $memberId || root.child('circles/' + $circleId + '/members/' + auth.uid).exists())",
            ".write": "auth != null && auth.uid == $memberId"
          }
        },
        ".read": "auth != null && root.child('circles/' + $circleId + '/members/' + auth.uid).exists()",
        ".write": "auth != null && root.child('circles/' + $circleId + '/members/' + auth.uid).exists()"
      }
    },
    "users": {
      "$uid": {
        ".read": "auth != null && auth.uid == $uid",
        ".write": "auth != null && auth.uid == $uid"
      }
    },
    "trials": {
      // 7-day free trial, ONCE PER PHONE (23 Nov 2026). The key is
      // the SHA-256 hash of the Android ID — unguessable without the
      // phone, so any signed-in user may read their own hash node.
      // Write is CREATE-ONLY (!data.exists()): once a trial exists
      // for a phone it can never be overwritten, extended or reset —
      // not even by the phone's own user.
      "$deviceHash": {
        ".read": "auth != null",
        ".write": "auth != null && !data.exists()"
      }
    },
    "invites": {
      ".read": "auth != null",
      ".write": "auth != null"
    }
  }
}
```

**Rules ko test kiye baghair "public" (`.read: true`) kabhi na karein —
puri family ki live location khul jayegi.**

> ✅ Done 22 Nov 2026: database asia-southeast1, locked mode,
> member-only rules published — **verify they match the full text
> above (especially the `members/{uid}` self-write exception and
> the `users`/`invites` blocks) before the two-phone test.**
>
> ✅ Done 23 Nov 2026 ~00:03 PKT: the `trials` block (create-only,
> once-per-phone free trial) IS published now — the old "RULES
> UPDATE STILL NEEDED" warning no longer applies.

## 3. Authentication

- Sign-in method: **Phone** ON karein (family ke liye sab se asaan).
- Backup: **Email/Password** ON.
- Anonymous sign-in OFF rakhein — khoya hua phone circle kho dega.

> ✅ Done 22 Nov 2026: Phone + Email/Password ON, Anonymous OFF.

**Gmail OTP — v0.6 mein BAN GAYA (23 Nov 2026):** Firebase Auth mein
6-digit EMAIL OTP nahi hota — is liye code ka flow Cloud Function +
email sender se banaya gaya hai: `requestEmailCode` /
`verifyEmailCode` (`functions/index.js`), nodemailer SMTP se code
Gmail inbox mein, sirf SHA-256 hash RTDB mein save hota hai (code
kabhi save/log nahi hota). Login screen par teesra option
"Email code se login" hai. Deploy + SMTP setup neeche §4 mein —
bina in ke code wala login "not set up yet" kahega; password wala
login tab bhi chalta hai. SIM number par 6-digit SMS OTP aata hai
(Phone Auth).

## 4. Cloud Messaging (FCM) — alerts ke liye

- Cloud Messaging API enable karein.
- **Server key kabhi app mein NAHI dalni.** Notifications sirf server /
  Cloud Functions se bheji jayengi (SOS, battery-low, phone-off).
- Android 13+ par notification permission app pehli dafa khud mangegi.

> ✅ Done 22 Nov 2026: Cloud Messaging API (V1) enabled.

### Cloud Function — asal phone-to-phone push (v0.5, code DONE, deploy BAQI)

`functions/index.js` (`sendCircleEventPush`) — naye RTDB event par
circle ke baaqi members ke FCM tokens par push bhejta hai. v1
trigger hai (Spark free plan par chalta hai — v2 ko Blaze/card
chahiye hota, is liye v1 hi rakha hai).

**Deploy (Mujahid ka step — `firebase login` ek dafa chahiye):**

```bash
# 1. Node 20 + Firebase CLI install karein (ek dafa)
npm install -g firebase-tools

# 2. ApnaCircle project mein login (gigblow@gmail.com wala account)
firebase login
firebase use apnacircle-22ef3

# 3. Functions deploy karein (apnacircle-app folder se)
cd apnacircle-app
npm --prefix functions install
firebase deploy --only functions
```

Deploy ke baad Firebase console → Functions mein `sendCircleEventPush`
dikhega. Test: child ke phone se SOS dabayein → parent ke phone par
push aaye **jab app band ho** (pehle sirf khuli app par RTDB event
se aata tha). Bina deploy ke band app par push NAHI aayega — ye
deploy lazmi hai, optional nahi.

**Honest limit (v0.5):** deploy se pehle SOS sirf RTDB `events` node
se deliver hota hai (parent ka phone app khula ho to foran dikhta
hai). Server-side push Cloud Function ka kaam hai — app mein server
key kabhi nahi aayegi.

### Email OTP — 6-digit Gmail code (v0.6, code DONE, deploy + SMTP BAQI)

`functions/index.js` (`requestEmailCode` / `verifyEmailCode`) +
`functions/email_otp.js` (pure logic) — login screen ka teesra
option "Email code se login" inhi ko call karta hai. Flow:

1. App `requestEmailCode({email})` call karti hai → function
   random 6-digit code banata hai, sirf us ka SHA-256 hash RTDB
   `emailCodes/{sha256(email)}` mein save karta hai (code khud
   kabhi save nahi hota, kabhi log nahi hota), phir code nodemailer
   SMTP se Gmail inbox mein bhejta hai.
2. User code likhta hai → app `verifyEmailCode({email, code})`
   call karti hai → function hash milata hai, sahi ho to Auth user
   find-or-create kar ke custom token deta hai → app
   `signInWithCustomToken` se sign in ho jati hai. Code entry phir
   delete ho jati hai.

**Limits (code + app dono mein same):** code 10 minute ka; 5
ghalat try par lock (code delete, naya code mangwana parta hai);
aik email par 1 ghante mein max 5 code. RTDB rules badalne ki
zaroorat nahi — ye nodes sirf Admin SDK (function) parhta/likhta
hai, app kabhi seedha nahi.

**SMTP setup (deploy se pehle, parent ka step):** SMTP sirf
environment se aata hai — repo mein koi password ya email hardcode
NAHI hai. `functions/.env` file banayein (ye gitignored hai —
kabhi commit nahi hogi):

```bash
# functions/.env — sirf deploy machine par, repo mein NAHI
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=apnacircle@gmail.com
SMTP_FROM=ApnaCircle <apnacircle@gmail.com>
```

Password secret ke tor par set karein (kabhi `.env` ya chat mein
nahi — Gmail ke liye **App Password** use karein, asal password
nahi; Google account mein 2-Step Verification ON kar ke App
Passwords se 16-harf wala password banayein):

```bash
firebase functions:secrets:set SMTP_PASS
# prompt par App Password paste karein
```

Phir wahi deploy command — dono functions (push + email OTP)
aik saath deploy hote hain:

```bash
cd apnacircle-app
npm --prefix functions install
firebase deploy --only functions
```

Deploy ke baad console → Functions mein `requestEmailCode` aur
`verifyEmailCode` dikhenge. Test: login screen → "Email code" →
email → "Send code to Gmail" → code inbox mein aaye → verify →
sign in. **SMTP set na ho to** function saaf error deta hai
(`email-not-configured`) aur app "Email codes are not set up yet"
dikhati hai — kabhi fake "code bhej diya" nahi hota.

**Spark-plan sach (zaroori):** free Spark plan sirf Google
services tak outbound traffic deta hai, aur SMTP sending Spark par
routinely block hoti hai — is liye pehli asal code email
`email-send-failed` de sakti hai jab tak Blaze (billing) na lage.
Deploy + code Spark par chalte hain; live email ka faisla Blaze
ka hai — Mujahid ka faisla (Phone OTP wala hi sawal), card Lucky
kabhi nahi lagati.

## 5. Packages (pubspec.yaml mein add karein)

```yaml
firebase_core: ^3.6.0
firebase_auth: ^5.3.1
firebase_database: ^11.1.4
firebase_messaging: ^15.1.3
cloud_functions: ^5.1.3 # v0.6: email OTP callable functions ke liye
```

Phir `flutter pub get`, aur `main.dart` mein `main()` ke start mein:

```dart
await Firebase.initializeApp();
```

> ✅ Done 22 Nov 2026 (v0.3 code): packages add, `main.dart` mein
> guarded init — Firebase na ho to app demo mode mein chalti hai
> (crash nahi). **Database URL:** database asia-southeast1 mein
> hai (default us-central1 NAHI), is liye code
> `FirebaseDatabase.instanceFor(databaseURL: 'https://apnacircle-22ef3-default-rtdb.asia-southeast1.firebasedatabase.app')`
> use karta hai — warna reads/writes fail hote.
>
> **GitHub Actions (APK build) — IMPORTANT:** `google-services.json`
> gitignored hai, is liye runner par file NAHI hogi. Us build ki
> APK demo mode mein chalegi (koi sync nahi) jab tak json ko CI
> secret ke tor par inject na kiya jaye (workflow mein
> `google-services.json` likhna, secret se). `android/app/build.gradle.kts`
> mein google-services plugin sirf tab apply hota hai jab file
> maujood ho — bina file ke build phir bhi kamyab hota hai.

## 6. Test checklist (v0.3 complete tabhi hai jab ye teeno hon)

- [ ] Do phones: ek ki live location doosre ke map par dikhe.
- [ ] Parent phone se child ke liye app lock karein → child ke phone par
      lock lage (time window ke andar).
- [ ] SOS dabayein → parent's phone par push notification aaye.

## 7. Cost

Firebase ka free plan (Spark) is app ke shuru ke liye kaafi hai —
Realtime Database 1 GB storage + 10 GB/month download free. $5/year
plan ke andar rehne ke liye location updates 50 m / 60 s par throttled
hain (pehle se code mein hai). Agar usage barhe to Blaze (pay-as-you-go)
par jane se pehle Mujahid se poochna lazmi hai — **koi card nahi**.

## 8. Google Play Billing — $5/year product (v0.5, code DONE, product BAQI)

App mein `in_app_purchase` wired hai, product id:
**`apnacircle_family_yearly`**. Asal khareed sirf tab chalegi jab
product Play Console mein bane — tab tak Plan screen saaf kehti hai
"plan is not in the Play Store yet" (charge kabhi fake nahi hota).

**Play Console mein (Mujahid ka step — $25 developer account ke baad):**

1. Play Console → ApnaCircle app → Monetize → Products → Subscriptions.
2. Naya subscription banayein: Product ID **`apnacircle_family_yearly`**,
   naam "Family plan", base plan: 1 year, price **$5.00** (Pakistan mein
   PKR mein bhi dikhega — Google khud convert karta hai).
3. Subscription ko Active karein. App ko Play ke test track (internal
   testing) par upload karein — tab khareed test hogi.
4. **JazzCash / Easypaisa se Play subscription nahi bhari ja sakti** —
   Play Billing hi in-app rasta hai. Ye Play Store ka rule hai, app
   ka nahi.

> ⚠️ Jab tak product Active na ho, Plan screen ka Buy button
> "not in the Play Store yet" batayega — ye sahi behaviour hai,
> bug nahi.
