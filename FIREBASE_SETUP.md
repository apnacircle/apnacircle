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

## 3. Authentication

- Sign-in method: **Phone** ON karein (family ke liye sab se asaan).
- Backup: **Email/Password** ON.
- Anonymous sign-in OFF rakhein — khoya hua phone circle kho dega.

> ✅ Done 22 Nov 2026: Phone + Email/Password ON, Anonymous OFF.

**Gmail OTP — honest note:** Firebase Auth mein 6-digit EMAIL OTP
nahi hota. Gmail channel ye hai: sign-up par verification LINK
Gmail inbox mein, aur password-reset email. SIM number par 6-digit
SMS OTP aata hai (Phone Auth). Agar Gmail par bhi 6-digit code
chahiye to Cloud Function + email sender lagna hoga — ye follow-up
hai, code mein fake nahi kiya gaya.

## 4. Cloud Messaging (FCM) — alerts ke liye

- Cloud Messaging API enable karein.
- **Server key kabhi app mein NAHI dalni.** Notifications sirf server /
  Cloud Functions se bheji jayengi (SOS, battery-low, phone-off).
- Android 13+ par notification permission app pehli dafa khud mangegi.

> ✅ Done 22 Nov 2026: Cloud Messaging API (V1) enabled.

**Honest limit (v0.3):** app mein FCM token + foreground/background
handlers wired hain, lekin ek phone se doosre phone ko push bhejne
ke liye SERVER chahiye (Cloud Function) — woh abhi nahi bana. Is
liye SOS abhi RTDB `events` node se deliver hota hai (parent ka
phone app khula ho to foran dikhta hai). Server-side push
Cloud Function ka follow-up hai — app mein server key kabhi nahi
aayegi.

## 5. Packages (pubspec.yaml mein add karein)

```yaml
firebase_core: ^3.6.0
firebase_auth: ^5.3.1
firebase_database: ^11.1.4
firebase_messaging: ^15.1.3
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
