# ApnaCircle — Real Android App (Flutter)

**Status (22 Nov 2026): v0.3 source complete. `flutter analyze` clean (no issues),
`flutter test` 29/29 pass (18 old + 11 new Firebase/SMS tests). Firebase
console DONE (project `apnacircle-22ef3`, RTDB asia-southeast1, Auth Phone +
Email ON, FCM API enabled) and the code is wired for it — two-phone
admin/child sync is implemented, NOT yet tested on real phones (see
"Real-phone checklist"). This is the REAL native app, NOT the web demo
(`apnacircle-shareable-demo`).**

## v0.3 — kya naya hai (22 Nov 2026, "complete karo" order par)

1. **Firebase Auth — account-based:** sign in with **Phone (6-digit SMS
   OTP to the SIM)** or **Gmail (email + password)**. A circle belongs
   to an ACCOUNT, not a phone — parent naye phone par usi account se
   login kare to wahi circles + wahi PIN wapas. Auth screen pehli
   dafa khulti hai (ya Settings → Account & Circles). "Continue in
   demo mode" bhi hai — bina account ke app v0.2 jaisi local chalti hai.
2. **Realtime Database sync — do phone, aik circle:** parent circle
   banata hai → 6-digit invite code milta hai → child code se join
   karta hai. Parent ke phone se lock/alert badlo → child ke phone
   par live update. Live location (50 m / 60 s throttle) bhi dono
   taraf dikhti hai. **Multiple circles:** aik banda aik circle mein
   member aur dusri circles ka admin ho sakta hai — role har circle
   ke hisab se alag hai.
3. **FCM (push) wired:** token + foreground/background handlers,
   Android 13+ permission. **Honest limit:** ek phone se doosre ko
   push bhejne ke liye SERVER (Cloud Function) chahiye — woh abhi
   nahi bana, is liye SOS abhi RTDB `events` node se deliver hota
   hai (parent ka phone app khula ho to foran dikhta hai). Server
   key kabhi app mein nahi aayegi.
4. **Offline SMS location fallback (naya):** bache ke phone mein net
   na ho (Wi-Fi gaya, data off) to GPS fix (GPS ko net nahi chahiye)
   **SMS se parent ke number par** jata hai — zyada se zyada har
   15 min, sirf jab 50 m chala ho, sirf parent ke number par. Parent
   ke phone par SMS parh kar map par "SMS se aayi · [time]" dikhta
   hai. Permission pehle saaf wazahat ke saath mangi jati hai.
   **Limits (sach):** SMS live tracking nahi (15-min snapshot),
   signal + SMS balance chahiye, phone band ho to kuch nahi bhej
   sakta — aakhri location hi sab kuch hai.
5. **Parent PIN recovery:** PIN hash (SHA-256, PIN khud kabhi nahi)
   circle par save hota hai — naye phone par sign-in ke baad wahi
   PIN chalta hai.
6. **Offline state, imaandari se:** member offline ho to parent ko
   aakhri location + "Offline since [time]" dikhta hai; SMS wali
   location par "SMS se aayi" ka label hota hai.
7. **Guarded Firebase init:** Firebase project na ho to app demo
   mode mein chalti hai — crash nahi. Database URL explicit hai
   (`instanceFor`, asia-southeast1) kyunke database default region
   mein nahi hai.

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
   (har fix local save hota hai). **v0.3:** net off ho aur SMS fallback on ho
   to bache ki location SMS se aati hai ("SMS se aayi · [time]"); member
   offline ho to "Offline since [time]" dikhta hai. Live location do
   phones ke beech Firebase se sync hoti hai (sign-in + circle zaroori).
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
7. **Family chat** (text; voice/video v0.2 mein). **v0.3:** sign-in + circle
   ho to chat dono phones par live sync hoti hai (RTDB).
8. **Family plan $5/year, sirf parent pay kare, poori family cover, max 10.**
   Payment methods plan screen par dikhte hain — Pakistan: JazzCash, Easypaisa,
   bank transfer/debit card; International: Visa/Mastercard, Google Play
   billing, PayPal (where available). **Koi real payment is code mein charge
   nahi hoti** — asal charging Google Play Billing se hogi (v0.2).
   **7-day free trial (22 Nov 2026, once PER PHONE — 23 Nov 2026):** parent
   Plan screen se "Start 7-day free trial" dabaye, 7 din full plan free. Trial
   Android ID ke SHA-256 hash se `trials/{hash}` mein save hota hai — reinstall
   ya naye account se dobara nahi milta; alag phone ko apna aik trial milta hai.
   Factory reset Android ID badal deta hai, is liye reset phone ko naya trial
   mil sakta hai — ye qubool-shuda limit hai. Trial khatam hone par circle/data
   delete nahi hota, sirf Subscribe dikhaya jata hai.
9. **Lightweight, purane Android 5.0 (minSdk 21) se latest tak.**
10. **Stolen-phone / SIM-change alert (approved 22 Nov 2026, "G dal do"):**
    agar phone gum ho jaye aur chor phone band kar ke nayi SIM daal kar on
    kare, to parent/family ko alert mile — **aakhri location (band hone se
    pehle wali) AUR nayi location dono**. Tareeqa: SIM-change detection
    (ICCID/IMSI check) + boot par auto-start + nayi location milte hi alert.
    **Limits (sach):** nayi SIM mein net hona zaroori hai, warna alert tab
    jayega jab net mile; nayi SIM ka number aksar nahi milta — location +
    "SIM badal gayi" ki khabar milegi, number ki guarantee nahi; factory
    reset se app delete ho jayegi (neeche anti-tamper dekhein).
11. **Parent-phone-loss recovery (approved 22 Nov 2026, "Haan, ye bhi list mein add kar do"):**
    agar parent ka apna phone gum ho jaye (sara control usi phone mein tha),
    to woh kisi dusre phone se control le sakta hai — **control parent ke
    ACCOUNT se bandha hai, device se nahi**. (1) Parent naye phone par
    ApnaCircle install kar ke usi account se login kare to wahi circle, wahi
    PIN, full control wapas — bachon ke phone par kuch nahi karna padega,
    data Firebase cloud mein hai. (2) **OTP dono jagah aaye — SIM number par
    bhi AUR Gmail par bhi** (user, 22 Nov 2026 ~13:23 PKT): number gum ho jaye
    to SIM foran nikal bhi sakti hai, is liye OTP sirf SIM par nahi, Gmail par
    bhi aana chahiye — login/recovery ke liye dono option hon. Firebase Auth
    mein Phone + Email/Password dono ON rakhne hain. (3) Parent PIN account ke saath cloud mein save hona
    chahiye, taake naye phone par wahi PIN chale (sirf phone mein save nahi).
    (4) Optional: aik dusra trusted family member **co-parent / backup admin**
    ho, taake parent ka phone gum hote hi foran control us ke paas ho — naye
    phone ka intezar nahi. (5) Parent ka apna phone bhi circle ka member hai,
    to us ki aakhri location family dekh sakti hai.
12. **Anti-tamper / factory-reset protections (approved 22 Nov 2026):**
    (a) **Device Admin** — uninstall ki koshish par parent ko foran alert +
    rukawat (v0.2 mein abhi wired nahi hai, baaki hai);
    (b) **Device Owner** (phone setup ke waqt QR se, ek dafa) — Settings se
    factory reset ka option band ho jata hai;
    (c) **Google FRP (built-in)** — reset ke baad phone purane Google account
    ke password ke bagair nahi chalega, chor ke liye bekaar;
    **Limits (sach):** recovery-mode button reset ko koi app nahi rok sakti;
    **root / system-app wala raasta NAHI use karna** — warranty khatam, bank
    apps band, Play Store reject kar deta hai.
13. **Multiple circles / aik banda, kai admin (approved 22 Nov 2026):**
    aik shakhs aik circle mein member ho sakta hai AUR dusri jagah admin —
    koi limit nahi, jitni jagah chahiye. Misal: beta family circle mein
    member hai, lekin apna bank-team circle bana kar us ka admin hai, aur
    doston ka circle bana kar us ka bhi admin hai. Har circle ka apna admin,
    apne members, apna PIN aur apne locks hain — aik circle ka admin dusre
    circle ko nahi dekh sakta aur na control kar sakta hai. Role har circle
    ke hisab se alag hota hai (member yahan, admin wahan).

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

## Jo abhi baaki hai (v0.3 ke baad)

1. **Firebase — baaki cheezein (code ho gaya, test baaki):**
   * Published RTDB rules ko `FIREBASE_SETUP.md` §2 ke FULL text se
     match karein (sirf member-only block se Join circle FAIL hota
     hai — self-write exception + `users/`/`invites/` blocks lazmi).
   * GitHub Actions build mein `google-services.json` CI secret se
     inject karein (gitignored hai — bina is ke runner ki APK demo
     mode mein chalegi).
   * **Do-phone test (lazmi):** parent circle banaye → child code se
     join kare → live location, remote lock, SOS — teeno check karein.
   * FCM server-side push (Cloud Function) — abhi SOS RTDB events se
     deliver hota hai; band app par push ke liye server chahiye.
   * Gmail par 6-digit OTP code (Firebase mein built-in nahi — link
     hai; code ke liye Cloud Function + email sender chahiye).
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
6. **Stolen-phone / SIM-change alert + anti-tamper:** SIM-change detection
   (ICCID/IMSI), boot auto-start, Device Admin wiring, Device Owner setup
   guide (QR, ek dafa), FRP note. Limits upar Features 10–12 mein likhe
   hain — net ke bagair alert nahi, recovery reset nahi rukta, root nahi.
7. **Parent-phone-loss recovery — v0.3 mein code ho gaya:** account-based
   control, Email + Phone OTP login, PIN hash circle par save, "Restore
   my circles" (Circle screen). Baaki: do-phone test (naye phone par
   login → circle + PIN wapas). Co-parent / backup admin abhi nahi bana.

## Real-phone checklist (APK milne ke baad, launch se pehle)

Ye sab is VM par verify NAHI ho sakta — asal phone par karna lazmi hai:

- [ ] App Lock: Accessibility service enable karein, locked app kholein —
      PIN screen aaye. Time lock: 08:00 par lock, 14:00 par auto-unlock.
- [ ] SIM call: family member SIM se call kare — overlay par naam +
      distance (km) dikhe. Dual SIM par dono SIMs test karein.
- [ ] Location: do phones, ek ki live location doosre ke map par.
      Parent phone se child ko lock karein → child ke phone par lock
      lage (time window ke andar bhi).
- [ ] SOS / alerts: SOS dabane par parent ko notification (RTDB event —
      app khula ho; band app par push abhi server ke bagair nahi).
- [ ] Offline SMS: child ka data off karein → 15 min mein parent ko
      SMS location mile, map par "SMS se aayi" dikhe. SMS sirf parent
      ke number par jaye.
- [ ] Circles: parent naye phone par usi account se login kare → wahi
      circle + wahi PIN wapas (bache ke phone par kuch nahi karna).
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
