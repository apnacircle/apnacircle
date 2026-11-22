# ApnaCircle — Firebase setup checklist (v0.2)

**Status (22 Nov 2026): NO Firebase project exists yet. Nothing has been
created, no account used, no card used.** Ye checklist tab poori hogi jab
Mujahid kahe ke Firebase project banayein, ya jo developer APK banaye woh
apne Firebase account se banaye. Code mein sirf placeholders hain
(`lib/services/firebase_config.dart`) — wahan asal values tab likhi
jayengi jab project bane. Time estimate: 1–2 hours.

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
  members/{memberId}/   lat, lon, battery, isOnline, lastSeen, role
  locks/{memberId}/     apps: [{package, locked, mode, window:{start,end,days}}]
  alerts/{memberId}/    {sos: true, lowBattery: true, ...}   // 14 alerts
  chat/                 [{from, text, at}]
```

3. Rules — shuru mein ye (sirf signed-in users, sirf apna circle):

```json
{
  "rules": {
    "circles": {
      "$circleId": {
        ".read": "auth != null && root.child('circles/' + $circleId + '/members/' + auth.uid).exists()",
        ".write": "auth != null && root.child('circles/' + $circleId + '/members/' + auth.uid).exists()"
      }
    }
  }
}
```

**Rules ko test kiye baghair "public" (`.read: true`) kabhi na karein —
puri family ki live location khul jayegi.**

## 3. Authentication

- Sign-in method: **Phone** ON karein (family ke liye sab se asaan).
- Backup: **Email/Password** ON.
- Anonymous sign-in OFF rakhein — khoya hua phone circle kho dega.

## 4. Cloud Messaging (FCM) — alerts ke liye

- Cloud Messaging API enable karein.
- **Server key kabhi app mein NAHI dalni.** Notifications sirf server /
  Cloud Functions se bheji jayengi (SOS, battery-low, phone-off).
- Android 13+ par notification permission app pehli dafa khud mangegi.

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

## 6. Test checklist (v0.2 complete tabhi hai jab ye teeno hon)

- [ ] Do phones: ek ki live location doosre ke map par dikhe.
- [ ] Parent phone se child ke liye app lock karein → child ke phone par
      lock lage (time window ke andar).
- [ ] SOS dabayein → parent ke phone par push notification aaye.

## 7. Cost

Firebase ka free plan (Spark) is app ke shuru ke liye kaafi hai —
Realtime Database 1 GB storage + 10 GB/month download free. $5/year
plan ke andar rehne ke liye location updates 50 m / 60 s par throttled
hain (pehle se code mein hai). Agar usage barhe to Blaze (pay-as-you-go)
par jane se pehle Mujahid se poochna lazmi hai — **koi card nahi**.
