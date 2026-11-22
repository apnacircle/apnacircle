# ApnaCircle — Firebase: exact steps still needed (22 Nov 2026)

**Status: console DONE 22 Nov ~22:13 PKT (project `apnacircle`,
ID `apnacircle-22ef3`, Spark free, Analytics OFF, Android app
`com.apnacircle.app`, google-services.json in `android/app/`).
Code wiring (v0.3) is done in this repo. What is left: verify
the published RTDB rules match §2 below, inject
google-services.json into the GitHub Actions build (it is
gitignored), and run the TWO-PHONE test (§F).**
No step here needs a card — Firebase Spark (free) plan is enough to start.

## A. Firebase project (console.firebase.google.com)

- [x] **Add project** → name `apnacircle` → Google Analytics OFF
      (turn ON only if Mujahid asks for it).
- [x] Add **Android app** → package name **`com.apnacircle.app`**
      (must match `android/app/build.gradle` exactly — a wrong package
      means the app will not connect).
- [x] Download **`google-services.json`** → place in `android/app/`.
      It is in `.gitignore` (never committed to git — correct, it
      contains an API key). Never share it in chat / WhatsApp.

## B. Realtime Database (live location + locks + alerts + chat)

- [x] Build → Realtime Database → Create database → start in
      **Locked mode** → location **`asia-southeast1`** (Singapore,
      closest to Pakistan).
- [x] Data structure (already fixed in code,
      `lib/services/firebase_config.dart`):
      `circles/{circleId}/members/{memberId}/` (lat, lon, battery,
      isOnline, lastSeen, role), `locks/{memberId}/`,
      `alerts/{memberId}/` (14 alerts), `chat/` (messages).
- [ ] Set the **Rules** from `FIREBASE_SETUP.md` §2 — **VERIFY the
      published rules match the FULL text there** (the plain
      member-only block alone BREAKS joining a circle: a child who
      is not a member yet cannot write their own member node. The
      full text adds the self-write exception + `users/` +
      `invites/` blocks). **Never** set `.read: true` / public
      rules — the whole family's live location would be open to
      anyone.

## C. Authentication

- [x] Sign-in method **Phone** → ON (easiest for families).
- [x] Sign-in method **Email/Password** → ON (backup).
- [x] **Anonymous sign-in → OFF** (a lost phone would lose its circle).

## D. Cloud Messaging (FCM — push alerts: SOS, battery-low, phone-off)

- [x] Enable the **Cloud Messaging API**.
- [ ] **Server key NEVER goes in the app.** Notifications are sent
      only from a server / Cloud Functions (SOS, battery-low,
      phone-off). Android 13+ asks the notification permission itself
      on first run.
      **v0.3 honest note:** the in-app FCM wiring (token +
      handlers) is done, but there is NO server yet — so SOS
      delivery between phones currently uses the RTDB `events`
      node (parent sees it live while the app runs). Server-side
      push needs a Cloud Function (follow-up, no key in the app).

## E. Code wiring (after A–D, in the Flutter project)

- [x] Add to `pubspec.yaml`: `firebase_core ^3.6.0`,
      `firebase_auth ^5.3.1`, `firebase_database ^11.1.4`,
      `firebase_messaging ^15.1.3` — then `flutter pub get`.
- [x] In `main.dart`, at the start of `main()`:
      `await Firebase.initializeApp();` (guarded — falls back to
      local demo mode when Firebase is not configured).
- [x] Replace the local-only storage (`SharedPreferences` in v0.2)
      with Firebase Realtime Database calls in
      `lib/services/firebase_config.dart` (placeholders only today).
      Done in v0.3: `lib/services/sync_service.dart` (RTDB),
      `auth_service.dart` (Email + Phone OTP), `notification_service.dart`
      (FCM), `firebase_bootstrap.dart` (guarded init).
      **Database URL is explicit** (`instanceFor`, asia-southeast1)
      because the database is NOT in the default region.
- [x] Offline SMS fallback (v0.3 addition): `SmsLocationService`
      + native `SmsReceiver` — GPS fix by SMS to the parent when
      the child has no data (every 15 min, only when moved ≥ 50 m,
      parent numbers only). Last-location cache kept.
- [ ] **GitHub Actions build:** `google-services.json` is
      gitignored, so the runner build has NO Firebase config — its
      APK runs in demo mode until the json is injected as a CI
      secret. The google-services Gradle plugin applies only when
      the file exists (see `android/app/build.gradle.kts`).

## F. Test before calling Firebase "done"

- [ ] Two phones: one's live location appears on the other's map.
- [ ] Parent locks an app from the parent phone → it locks on the
      child's phone (inside the time window).
- [ ] Press SOS → parent's phone gets a push notification.

## G. Cost

- Spark (free) plan: Realtime Database 1 GB storage + 10 GB/month
  download free — enough to start. Location updates are already
  throttled in code (50 m / 60 s) to stay inside the $5/year plan.
- **Do NOT switch to Blaze (pay-as-you-go) without asking Mujahid
  first — no card.**
