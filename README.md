# ApnaCircle — Real Android App (Flutter)

**Status (22 Nov 2026): v0.2 source complete. `flutter analyze` clean (no issues),
`flutter test` 18/18 pass (9 old + 9 new time-lock tests). No APK built yet
in this environment — see "APK kyon nahi bana" below. This is the REAL
native app, NOT the web demo (`apnacircle-shareable-demo`).**

## v0.2 — kya naya hai (22 Nov 2026, "jaldi complete karo" order par)

1. **Time Lock (web demo jaisa):** har app ke liye do modes —
   * **Always lock** — har waqt lock, sirf parent PIN se khule.
   * **Time lock** — owner koi bhi start/end time + din (Mon–Sun chips)
     **ek dafa** set kare; app har scheduled din khud lock aur khud
     unlock hoti hai, roz set nahi karna. Company example: **PUBG,
     Mon–Fri, 08:00–14:00** (preset). Overnight windows (22:00–06:00)
     bhi chalte hain. Logic: `lib/core/time_lock.dart` (pure, tested);
     UI: `lib/screens/locks_screen.dart` (mode switch, time picker,
     day chips, live "Locked now / Open now" status). Mode/time/day
     badalna bhi parent PIN se hota hai.
2. **Native stubs behtar:** `MainActivity.kt` mein ab PhoneStateListener
   asal ringing number record karta hai (SharedPreferences + memory) aur
   `applyLocks` poora schedule (packages + mode + time window) save karta
   hai; `AppLockService.kt` mein foreground-app check + time-window
   evaluation (Dart jaisa logic, overnight included) aur locked app par
   PIN-gate screen par bounce. **Dono abhi bhi real phone par test nahi
   hue — neeche "real-phone checklist" dekhein, fake claim nahi.**
3. **Firebase placeholders + checklist:** `lib/services/firebase_config.dart`
   (koi real project/account nahi, koi firebase package add nahi) aur
   `FIREBASE_SETUP.md` (project, Realtime DB rules, Auth, FCM, packages,
   cost — 1–2 hours ka kaam, normal machine par).
4. **Google Maps key placeholder:** key ab code mein hardcode nahi —
   `MAPS_API_KEY` `gradle.properties` / `local.properties` se aata hai
   (`android/app/build.gradle` manifestPlaceholders), default
   `YOUR_GOOGLE_MAPS_API_KEY`. Real key build machine par set hogi.
5. **Privacy policy draft:** `PRIVACY_POLICY.md` (placeholders
   [CONTACT_EMAIL] / [PLAY_STORE_URL] / [LAUNCH_DATE] bharne hain —
   Play submit se pehle confirm karna hai).
6. **Tests:** 9 naye time-lock tests (window active/inactive, overnight,
   next start, days summary, JSON round-trip, PUBG preset,
   lockedPackagesNow filter).

Family location safety app — Mujahid's idea, name FINAL: **ApnaCircle**.

## Features (jo is code mein hain)

1. **Language:** pehli screen par English / Urdu select, Settings mein bhi change.
   Urdu poora RTL hai.
2. **Family circle, max 10 members** — 11th member add nahi hota (UI + `FamilyService`
   dono mein check hai).
3. **Live location on Google Maps** — har member ki location, distance (km),
   battery, online/offline. **Net off ho to aakhri location + time** dikhta hai
   (har fix local save hota hai).
4. **SIM call caller distance (km)** — normal SIM call par caller ka naam,
   number aur aap se fasla. WhatsApp call zaroori nahi. (Android only — iOS
   par Apple SIM call ki info nahi deta.)
5. **14 alerts, har ek ka alag on/off, sirf parent PIN se:**
   SOS, low battery, phone off, internet off, arrive home/school, leave home,
   fall (elderly), long stay, no movement, SMS location when net off,
   shake SOS, loud SOS on silent, auto-call 1122 (sirf parent opt-in par),
   location viewed.
6. **Locks (sirf parent ki admin app se, parent PIN se):**
   * Location Lock — member khud location band nahi kar sakta.
   * Internet-off alert (Android data/Wi-Fi toggle ko koi normal app poora
     lock nahi kar sakti — is liye alert + aakhri location; README mein sach
     likha hai).
   * App Lock — YouTube, Facebook, WhatsApp, Chrome, TikTok, PUBG + **parent
     koi bhi app naam likh kar add kar ke lock kar sakta hai** (custom app add).
7. **Family chat** (text; voice/video v0.2 mein).
8. **Family plan $5/year, sirf parent pay kare, poori family cover, max 10.**
   Payment methods plan screen par dikhte hain — Pakistan: JazzCash, Easypaisa,
   bank transfer/debit card; International: Visa/Mastercard, Google Play
   billing, PayPal (where available). **Koi real payment is code mein charge
   nahi hoti** — asal charging Google Play Billing se hogi (v0.2).
9. **Lightweight, purane Android 5.0 (minSdk 21) se latest tak.**

## Project structure

```
lib/
  main.dart                 entry point (providers)
  app.dart                  theme + first-screen routing
  core/
    constants.dart          product decisions (10 members, $5/year, 1122…)
    alerts.dart             14 alerts enum + defaults
    language_service.dart   English/Urdu
    location_service.dart   GPS + last-location cache (throttled: 50 m / 60 s)
    call_distance_service.dart  Haversine km + SIM-call channel
    app_lock_service.dart   preset + custom app lock list
    shake_sos_service.dart  shake gesture detection
  l10n/                     app_en.dart, app_ur.dart (same keys)
  models/                   member.dart, chat_message.dart
  services/
    pin_service.dart        parent PIN = SHA-256 hash, kabhi plain text nahi
    family_service.dart     circle (max 10), alerts, location updates
  screens/                  language, PIN setup, map, call overlay,
                            alerts, locks, chat, plan, settings
  widgets/                  (pin_gate_dialog.dart is in screens/)
android/                    manifest (permissions), MainActivity.kt
                            (method channels), AppLockService.kt (STUB)
test/                       9 unit tests (alerts, Haversine, PIN hash, JSON)
```

## APK kaise banayein (build machine par)

```bash
# 1. Flutter 3.24.5 + JDK 17 + Android SDK (platform 34, build-tools 34.0.0)
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk

# 2. Google Maps API key (Google Cloud, key ko app par restrict karein)
#    android/app/src/main/AndroidManifest.xml mein
#    YOUR_GOOGLE_MAPS_API_KEY ki jagah apni key likhein.

# 3. Pehli dafa
flutter pub get

# 4. Check + test
flutter analyze
flutter test

# 5. Test APK (debug, seedha mobile par install karne ke liye)
flutter build apk --debug
# file: build/app/outputs/flutter-apk/app-debug.apk

# 6. Release APK / AAB (Play Store ke liye)
#    Pehle keystore banayein (keytool) aur android/key.properties
#    mein path/password likhein — keystore KABHI commit na karein.
flutter build apk --release
flutter build appbundle --release   # Play Store ko AAB chahiye
```

## APK is environment mein kyon nahi bana (sach, verify kiya gaya)

* Is VM mein shuru mein Flutter / Dart / Java / Android SDK kuch nahi tha.
* Flutter 3.24.5 download kar ke install kiya (`~/flutter-sdk`), JDK 17
  (Temurin) bhi install kiya — `flutter analyze` clean aur `flutter test`
  9/9 pass ho gaye.
* Android SDK bhi manual install kar liya (`~/android-sdk`: platform-tools,
  platform-34, build-tools 34.0.0, licenses) — `sdkmanager` ka Java HTTP
  stack is VM ke authenticated egress proxy (CONNECT tunnel) se guzar
  nahi pata (`HttpURLConnection.doTunneling` mein `NoSuchElementException`),
  is liye packages `curl` se download kiye.
* Gradle 8.4 bhi `curl` se download kiya. Gradle daemon ka IPC bhi
  pehle fail hua (`Could not receive a message from the daemon`) —
  ye `-Djava.net.preferIPv4Stack=true` se theek ho gaya aur build 77
  second tak chala.
* **Aakhri blocker:** Gradle ke dependency downloads (Android Gradle
  Plugin 8.3.2, `dl.google.com` aur `repo.maven.apache.org` se) mein
  `java.net.SocketException: Connection reset` aata hai — Java ka TLS
  is VM ke egress proxy se reset ho jata hai, jab ke `curl` se wahi
  URLs 200 OK dete hain. Ye is VM ke network/proxy ki pabandi hai,
  code ki ghalti nahi.
* **Natija: is VM par APK build verify NAHI hua. Koi APK file maujood
  nahi hai aur ye claim nahi kiya ja raha ke APK ban gaya.**
* Aik normal build machine (ya GitHub Actions / Codemagic / apna PC)
  par upar wale steps se APK ban jana chahiye — `flutter analyze` +
  tests clean hain, is liye code ki taraf se koi blocker nazar nahi
  aa raha. Wahan `android/gradle/wrapper/gradle-wrapper.properties`
  mein distributionUrl pehle se https wali hai (local file wala
  workaround wapas hata diya gaya hai).

## Play Store launch — kya kya chahiye (Mujahid khud karega)

* **Google Play developer account: $25 one-time, non-refundable.** Ye
  payment Mujahid khud apne card se karega — Lucky kabhi card use nahi
  karti. Agar launch na ho to bhi $25 wapas nahi milte, lekin account
  lifetime rehta hai, dobara $25 nahi dene hote.
* **Identity verification:** CNIC / passport se (Google khud karta hai).
* **Closed testing: 12 testers, 14 din** — naye personal account par lazmi
  hai. 12 log (family/dost) apne Gmail se tester banenge.
* **Privacy policy ka link, app mein account delete ka option, aur
  reviewers ke liye demo login** — Play Store mangta hai (v0.2 mein).
* **Sensitive permissions — Play Store sakhti karta hai:**
  background location, SMS, CALL_LOG / phone state, Accessibility
  (App Lock), QUERY_ALL_PACKAGES. Har ek ke liye Play Console mein
  declaration + video justification deni hogi. Agar Google kisi
  permission ko mana kar de to us feature ka rasta badalna padega
  (masalan App Lock ke liye Family Link jaisa tareeqa). Ye submission
  se pehle check karna lazmi hai.

## Jo abhi baaki hai (v0.1 se v1 tak)

1. **Firebase:** Realtime Database (live location + parent ka remote
   control), Cloud Messaging (alerts), Auth (accounts). Abhi data local
   (SharedPreferences) hai — doosre phone par live sync nahi hoga.
   Placeholders + checklist tayyar hain: `lib/services/firebase_config.dart`
   aur `FIREBASE_SETUP.md` (koi project abhi nahi bana).
2. **Native App Lock enforcement:** `AppLockService.kt` v0.2 mein
   foreground check + time-window evaluation karta hai, lekin PIN
   overlay abhi MainActivity launch hai (dedicated LockActivity +
   Device Admin baaki) —
   AccessibilityService se locked app ko rokna + PIN screen, aur Device
   Admin taaki bacha app uninstall na kar sake. Asal phone par test
   lazmi hai.
3. **Native SIM-call detection:** `MainActivity.kt` mein
   `incomingNumber` abhi `null` deta hai — TelephonyManager /
   CallScreeningService se asal ringing number lena baaki hai.
4. **Google Maps API key** — placeholder system tayyar hai (upar v0.2
   point 4 dekhein); real key build machine par set karni hai. **App icon**
   abhi Flutter ka default hai.
5. **Google Play Billing** ($5/year subscription) + **privacy policy**
   (draft `PRIVACY_POLICY.md` mein hai, placeholders bharne hain).

## Real-phone checklist (APK milne ke baad, launch se pehle)

Ye sab is VM par verify NAHI ho sakta — asal phone par karna lazmi hai:

- [ ] App Lock: Accessibility service enable karein, locked app kholein —
      PIN screen aaye. Time lock: 08:00 par lock, 14:00 par auto-unlock.
- [ ] SIM call: family member SIM se call kare — overlay par naam +
      distance (km) dikhe. Dual SIM par dono SIMs test karein.
- [ ] Location: do phones, ek ki live location doosre ke map par.
- [ ] SOS / alerts: SOS dabane par parent ko notification (Firebase ke baad).
- [ ] Device Admin: bacha ApnaCircle uninstall na kar sake.
- [ ] Account delete + privacy policy link (Play requirement).
6. **iOS:** baad mein — iOS par SIM-call distance Apple ki pabandi ki
   wajah se nahi ho sakta.

## Zaroori notes

* **Koi Play Console account nahi banaya, koi card use nahi hua, kuch
  khareeda nahi gaya.**
* Location sirf us ki marzi se share hoti hai jo share kare — bina
  permission ke kisi ko track nahi karte. Koi ad nahi, location ka
  data becha nahi jayega.
* Demo PIN `1234` sirf web demo mein tha — is real app mein koi
  default PIN nahi hai; parent pehli dafa apna PIN set karta hai.

## APK build status — 22 Nov 2026 (fast-track attempt)
- `flutter analyze`: clean. `flutter test`: 9/9 passed. Source is ready.
- **No APK exists yet.** Root cause found by test (not guesswork): on this VM,
  Java loopback TCP is intercepted — a Java program sending `ABCDEFGH12345678`
  over 127.0.0.1 receives `muse: Other TCP ...` instead, while the same test in
  Python works fine. Gradle's daemon talks to its client over loopback TCP, so
  every build dies with `Could not receive a message from the daemon`
  (`Unexpected type tag 109` = 'm' of "muse"). No Gradle setting can fix this
  here. Also the egress-proxy password rotates, so any proxy password saved in
  gradle.properties goes stale (and Gradle reads /root/.gradle, not ~/.gradle).
- **Fastest way to get the APK (about 10 minutes, no card, no new account
  needed if you already have a free GitHub account):**
  1. Push this folder to a free GitHub repo.
  2. The file `.github/workflows/build-apk.yml` is already in the project —
     GitHub Actions builds the APK automatically on push.
  3. Download it from the run's Artifacts (`apnacircle-apk`).
  - Or on any normal PC/Mac: install Flutter 3.24.5 + JDK 17 + Android SDK 34,
    then run `flutter pub get && flutter build apk --release` in this folder.
    The wrapper now points at the local Gradle 8.4 zip, so no wrapper download.
