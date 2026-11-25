# ApnaCircle — Real Android App (Flutter)

**Status (23 Nov 2026): v0.5 source complete. `flutter analyze` clean (no issues),
`flutter test` 49/49 pass. Firebase console DONE (project `apnacircle-22ef3`, RTDB asia-southeast1, Auth Phone +
Email ON, FCM API enabled) and the code is wired for it — two-phone
admin/child sync is implemented, NOT yet tested on real phones (see
"Real-phone checklist"). This is the REAL native app, NOT the web demo
(`apnacircle-shareable-demo`). GitHub Actions builds the APK on push
(runs #28, #43, #59 all SUCCESS — v0.4 APK delivered 23 Nov 2026).**

## v0.6 — kya naya hai (23 Nov 2026, "abhi bana do" order par)

**Gmail par 6-digit OTP code — AB BAN GAYA.** Firebase Auth mein
6-digit EMAIL code built-in nahi hota (sirf verification LINK hota
hai) — is liye code ka poora flow khud banaya gaya hai: Cloud
Function + email sender.

1. **Cloud Function (`functions/index.js` — naya):**
   `requestEmailCode` + `verifyEmailCode` (https.onCall, v1 — Spark
   plan par chalte hain). Code sirf SHA-256 hash ki shakal mein
   RTDB `emailCodes/{sha256(email)}` mein save hota hai — code khud
   kabhi save nahi hota, kabhi log nahi hota; email bhi raw nahi
   save hoti (key us ka hash hai). **Limits:** code 10 minute ka,
   5 ghalat try par lock (code delete), aik email par 1 ghante mein
   max 5 code. Sahi code par function Auth user find-or-create kar
   ke custom token deta hai.
2. **Email sender (nodemailer, SMTP):** code Gmail inbox mein
   nodemailer se bheja jata hai. SMTP sirf environment se aata hai
   (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`)
   — repo mein koi password ya email hardcode NAHI hai. SMTP set na
   ho to function saaf error deta hai (`email-not-configured`) aur
   kabhi ye nahi kehta ke code bhej diya.
3. **App — "Email code se login" (login screen ka teesra option):**
   Phone (SMS OTP) aur Gmail (password + link) waisi ki waisi hain —
   kuch nahi badla. Naya flow: email likho → "Send code to Gmail"
   → 6-digit code likho → "Verify code & Sign in". Ghalat/expired/
   zyada try ki plain-language messages EN + UR dono mein hain.
   Resend button rate limit manta hai (jaldi dobara bhejo to saaf
   error dikhta hai).
4. **Tests:** Dart 8 naye tests (code format, hash, expiry, attempt
   limit, EN+UR messages, login screen par teesra option) + Node 8
   tests (`functions/email_otp.test.js`). Kul: analyze clean,
   **57/57 Flutter tests pass**, `flutter build bundle` exit 0.
5. **Deploy + SMTP setup baaqi hai (FIREBASE_SETUP.md §4 dekhein):**
   `firebase deploy --only functions` + SMTP env set karna hai —
   tab tak code wala login "not set up yet" kahega (password wala
   login chalta rehta hai). **Spark-plan sach:** free Spark plan
   sirf Google services tak outbound traffic deta hai, aur SMTP
   sending Spark par routinely block hoti hai — pehli asal code
   email `email-send-failed` de to Blaze (billing) hi hal hai; ye
   Mujahid ka faisla hai (Phone OTP wala hi sawal), card Lucky
   kabhi nahi lagati.

## v0.5 — kya naya hai (23 Nov 2026, "complete bana do" order par)

1. **SIM-call REAL number:** `MainActivity.kt` ab `READ_PHONE_STATE` +
   `READ_CALL_LOG` dono mangta hai (pehle sirf Phone State tha — Android 10+
   number sirf Call Log ke sath deta hai). Settings mein wazahat ke sath
   "Allow" ka button hai; bina permission ke number khali aata hai (ye
   Android ka rule hai, bug nahi). **Limit (sach):** dual-SIM ka
   behaviour har phone par alag ho sakta hai — asal phone par test lazmi.
2. **Device Admin (uninstall protection):** `ApnaCircleDeviceAdminReceiver`
   + Settings mein enable/disable + status. Admin on ho to Android app
   uninstall nahi hone deta — pehle admin band karna parta hai, aur band
   karte hi parent ko RTDB event se alert milta hai. **Sach:** koi app
   uninstall ko poori tarah BLOCK nahi kar sakti — ye extra step + alert
   hai, na-todne-wala lock nahi.
3. **SIM-change alert + boot auto-start:** `BootReceiver` har reboot par
   SIM fingerprint (operator ka SHA-256 hash — ICCID/IMSI kabhi nahi,
   Android 10+ normal apps ko woh deta hi nahi) check karta hai; badli
   ho to pending event + notification, app khulte hi RTDB event parent
   ko. **Limits (sach):** same-carrier SIM swap detect nahi hota; nayi
   SIM ko alert ke liye net chahiye; factory reset se app delete ho
   jati hai.
4. **Cloud Function — asal phone-to-phone push:** `functions/index.js`
   (`sendCircleEventPush`) — naye RTDB event par circle ke baaqi members
   ke FCM tokens par push bhejta hai. v1 trigger (Spark free plan par
   chalta hai; v2 ko Blaze/card chahiye hota — is liye v1 hi rakha hai).
   Deploy abhi NAHI hua — `firebase login` + `firebase deploy --only
   functions` parent ka step hai (FIREBASE_SETUP.md §4).
5. **App icon:** asli icon (dark green shield + location pin) ab launcher
   icon hai — mipmap sizes + adaptive icon, `assets/icon/app_icon_1024.png`
   source.
6. **Account delete (Play requirement):** Settings → Delete account —
   confirm dialog, phir RTDB se apna `users/{uid}` node + apne member
   nodes delete, phir Auth account delete, local data clear (trial cache
   rehta hai taaki delete ke baad demo mode mein trial dobara na mile).
   Recent-login chahiye ho to "Sign in again first" batata hai.
7. **Play Billing ($5/year):** `in_app_purchase` + product id
   `apnacircle_family_yearly`; Plan screen ka Subscribe button ab asal
   store flow kholta hai. Product abhi Play Console mein NAHI hai — tab
   tak screen saaf kehti hai "plan is not in the Play Store yet"; charge
   kabhi fake nahi hota. Asal khareed sirf Play Console listing + $25
   account ke baad chalegi.
8. **Privacy policy complete:** `PRIVACY_POLICY.md` poori bhar di —
   contact email **mujahidsiddique0786@gmail.com** (Mujahid ne diya,
   23 Nov 2026 ~07:58 PKT). [PLAY_STORE_URL] aur [LAUNCH_DATE]
   launch par bharne hain.

## v0.3 — kya naya hai (22 Nov 2026, "complete karo" order par)

1. **Firebase Auth — account-based:** sign in with **Phone (6-digit SMS
   OTP to the SIM)**, **Gmail (email + password)** ya **Email code
   (v0.6 — Gmail inbox mein 6-digit code, password nahi chahiye)**.
   A circle belongs
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
4. **Map — OpenStreetMap (v0.6.15):** Google Maps hata diya — map
   tab blank tha kyun ke key nahi thi, aur key ke liye Google Cloud
   billing (card) chahiye hoti hai. Ab map OpenStreetMap hai
   (flutter_map 8.3.2 + latlong2): free, koi key nahi, koi card
   nahi — tiles internet se aate hain. Attribution "© OpenStreetMap
   contributors" map par hamesha dikhta hai (OSM licence).
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
3. **Live location on OpenStreetMap** — har member ki location, distance (km),
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
    mein Phone + Email/Password dono ON rakhne hain — aur v0.6 se Gmail par
    6-digit code bhi aata hai ("Email code se login", Cloud Function + SMTP;
    deploy + SMTP setup baaqi hai). (3) Parent PIN account ke saath cloud mein save hona
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

# 2. Map key — koi nahi chahiye (v0.6.15): map OpenStreetMap hai,
#    free, no API key, no card. Tiles internet se aate hain.

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

## Jo abhi baaki hai (v0.6 ke baad)

1. **Firebase — baaki cheezein:**
   * **Cloud Function deploy (lazmi, parent ka step):** `firebase login`
     + `firebase deploy --only functions` (FIREBASE_SETUP.md §4) — bina
     is ke band app par push nahi aayega, SOS sirf khuli app par dikhega.
   * **Do-phone test (lazmi):** parent circle banaye → child code se
     join kare → live location, remote lock, SOS — teeno check karein.
   * **Email-code login (v0.6) — deploy + SMTP baaqi:** code ban gaya
     (functions + app + tests), lekin live code tabhi aayega jab
     `firebase deploy --only functions` ho aur SMTP env set ho
     (FIREBASE_SETUP.md §4). Spark plan par SMTP block ho sakti hai —
     Blaze/billing Mujahid ka faisla hai.
   * Phone OTP (SMS) ke liye Firebase ko billing (Blaze) chahiye —
     22 Nov 2026 ko `BILLING_NOT_ENABLED` error aaya tha. Bina card ke
     Phone OTP nahi chalega; Gmail login billing ke baghair chalta hai.
2. **Native App Lock enforcement — WIRED in v0.6.3 (23 Nov 2026):**
   `AppLockService.kt` is now declared in AndroidManifest.xml +
   res/xml/accessibility_service_config.xml, with a dedicated native
   LockActivity (parent PIN screen; correct PIN = 5-minute grant for
   that app only). Dart subscribes to locks at Home (not only when
   the Locks tab opens) and the service reloads rules whenever the
   parent changes them. Custom apps added by name are resolved to
   real packages on the child's phone. **Root cause of "App lock nhi
   ho rhi" (23 Nov 2026): the service was never declared before
   v0.6.3, so Android could never run it. WHAT THE USER MUST ENABLE
   ON THE CHILD'S PHONE (nothing else works without this): Settings
   → Accessibility → ApnaCircle App Lock → ON (Android shows a
   warning — normal). The Locks screen shows ON/OFF + an Enable
   button. Honest limits: the child CAN turn the service off in
   Settings (Android rule — Device Admin + the deactivation alert
   are the tripwire, not a lock); it cannot block uninstall; a
   grant expiring while an app is open does not kick the child out
   (blocks re-entry only); an app not installed yet cannot be
   blocked by name. Play needs a declaration + video for
   Accessibility + QUERY_ALL_PACKAGES.
3. **Background location — WIRED in v0.6.4 (23 Nov 2026):**
   Root cause of members going stale ("— away", "Offline since
   08:38"): the app only ever asked for while-in-use location and
   only fetched it while the Map screen was open. Now: after
   while-in-use is granted, the app explains why in plain words
   and sends the user to the app's Settings page to pick "Allow all
   the time" (Android 11+ cannot grant it from a dialog); a
   foreground service (flutter_foreground_task, type `location`,
   declared in AndroidManifest.xml — the plugin does NOT declare
   its own service) then publishes the member's location every
   60 s (same 50 m / 60 s throttle) even when the app is closed,
   with a permanent notification "ApnaCircle is sharing your
   location with your family". The Map screen shows a status card
   — "Location sharing ON (always)" green / "Only while using the
   app" amber / "OFF" red — re-checked on every resume. The
   service starts automatically in a circle with "always"
   permission and stops when the user leaves all circles.
   **Child cannot turn location off (parent order, 23 Nov 2026
   ~10:34 PKT):** the in-app Location Lock switch is parent-PIN
   gated, and the service deliberately does NOT stop on the in-app
   sharing flag. **Honest limit:** NO app can block the phone's
   system GPS switch (Settings / quick panel) — Android does not
   allow it. Instead, the background task detects the switch-off
   at once and publishes ONE `locationOff` alert to the circle
   (with the last known location), so the parent is told
   immediately. Other honest limits: the service can still be
   stopped by swiping the app away on some phones, by aggressive
   battery savers (Xiaomi / Oppo / Vivo), or by Android under
   memory pressure — the battery-optimization exemption (asked
   once) lowers the risk, it does not remove it; auto-restart on
   boot is best-effort (Android 12+ restricts BOOT_COMPLETED
   foreground-service starts). The SMS offline fallback still
   needs the app open. **WHAT THE USER MUST ENABLE ON EACH
   CHILD'S PHONE:** Map tab → card must say "Location sharing ON
   (always)"; if not, tap "Turn on always" → Location → "Allow
   all the time" (and accept the battery-optimization prompt).
   The parent cannot enable it remotely. Play needs a declaration
   + video justification for background location at launch.
4. **Real SIM-call distance overlay — WIRED in v0.6.5 (23 Nov 2026):**
   Root cause of "call karnay pay distance show ho" not happening:
   CallOverlayScreen existed but its ONLY trigger was the test
   button on the Map screen — nothing ever showed it on a real
   call. Now: `CallStateReceiver` (manifest-registered, so it works
   even with the app dead) listens for PHONE_STATE (incoming) and
   NEW_OUTGOING_CALL (dialled number). It matches the number
   against a compact member cache Dart rewrites into
   SharedPreferences on EVERY member change
   (`apnacircle_call_cache`: normalized phone → name + last
   lat/lon; my location comes from my own member entry) and shows
   a small native WindowManager overlay (CallOverlayManager) OVER
   the call screen — name + distance ("3.6 km away" / "Location
   unknown" when either side has no fix). It stays up while the
   call is answered (OFFHOOK), hides on IDLE, and tapping it
   dismisses it. A non-member caller shows NOTHING — never an
   overlay for a stranger. **Honest limits:** (a) the overlay
   needs "Display over other apps" — without it nothing can
   appear, and the Settings screen says so plainly; on Oppo /
   Xiaomi an extra "Display pop-up windows" toggle may also be
   needed. (b) Incoming numbers need READ_CALL_LOG on Android 10+
   (without it the number arrives empty — Android rule). (c)
   Outgoing numbers need PROCESS_OUTGOING_CALLS; the
   NEW_OUTGOING_CALL broadcast is deprecated on Android 10+
   (CallRedirectionService replaces it for *redirecting* calls,
   which needs a system role grant — NOT taken in v0.6.5) but is
   still delivered to holders of the permission for observing the
   number; on Android 15+ it is no longer ordered and receivers
   cannot launch background activities — the overlay is a window,
   not an activity, so it still works. If Android ever stops
   delivering it, the fallback is the call-screening role. (d)
   Dual SIM: the broadcast carries no SIM slot, so the overlay
   cannot say which SIM the call is on. (e) WhatsApp / app calls
   have no SIM number and never show the overlay. **WHAT THE USER
   MUST ENABLE ON EACH PHONE:** Settings → "Call distance
   overlay" must say ON (tap Allow → "Display over other apps"
   → ON); Phone + Call Log permission must also be granted
   (same screen). Test: family member calls on SIM → overlay
   with name + distance; you call a member → same overlay.
5. **Battery on its own schedule — v0.6.6 (23 Nov 2026):**
   Root cause of the user's frozen battery (his phone: status
   bar 59%, app still showing the 82% from 09:24): the battery
   used to ride ONLY on a location publish, and location
   publishes are throttled to "moved >= 50 m" — a member sitting
   at home never moved, so no publish ever happened. Now the
   battery is published on its OWN schedule, independent of the
   movement throttle: at least every 15 minutes, and immediately
   on any >= 2% change (BatteryPublishTracker, pure + tested).
   Both publish paths use it: the background task publishes a
   battery-only update (`battery` + `batteryAt`, never location)
   when the fix is unchanged or missing, and the foreground loop
   does the same when there is no GPS fix. The 60 s / 50 m
   throttle still applies to LOCATION only. A failed battery
   read (-1) never overwrites a real level on the server. The
   member node now carries `batteryAt`, and a level older than
   30 minutes is marked "(old)" on the member row so a stale
   value is never mistaken for a live one.
6. **Invisible-only performance — v0.6.7 (23 Nov 2026):** accuracy-first
   rule (user order): NOTHING in this version may make any live
   value look delayed or stale. (a) Faster cold start: the
   network-bound startup work (FCM token fetch + notification
   permission prompt, circle-list server refresh, SIM-change and
   Device Admin pending-alert publishes) now runs AFTER the first
   frame (`_runPostFrameStartup` in main.dart); before the first
   frame only local SharedPreferences loads + Firebase init run.
   (b) Chat pagination: the live subscription loads only the
   newest 50 messages (was: the whole history, re-downloaded in
   full on every new message); older pages load via "Load older
   messages" (`loadOlderChatMessages`, `mergeChatMessages` —
   a live update merges, never drops loaded older pages).
   (c) Map tab is built lazily: `_mapTab` (FlutterMap + markers +
   member cards) used to be constructed on EVERY build even on
   other tabs; now only the selected tab is built.
   Deliberately NOT changed: the 60 s / 50 m location rule, the
   15-min battery rule, any publish timing, and no stale value is
   ever shown as live. Skipped: APK minify/R8 (runtime safety
   cannot be proven by tests + CI build alone on a safety app),
   per-ABI APK splits (would change the CI artifact / delivery),
   payload trimming (publish payloads already carry only fields
   screens read), unused assets (pubspec declares none).
7. **Play Store + WhatsApp Business lock — v0.6.8 (24 Nov 2026):**
   User-reported: both apps did NOT lock although the parent typed
   their names in the custom-add box and locked them. Two causes:
   (a) neither was in the presets (only YouTube, Facebook,
   WhatsApp, Chrome, TikTok, PUBG), so they could only be added
   by name; (b) the name matching was exact-label / substring
   only — "whatsapp business" does not contain "wa business", and
   "playstore" (one word) is not the label "Play Store" — so the
   custom entries never resolved to a package and never locked.
   Fix, three layers: (1) both are now presets with exact package
   names (Play Store `com.android.vending`, WhatsApp Business
   `com.whatsapp.w4b`, always-locked); (2) known short forms
   resolve immediately when the parent adds them
   (`AppLockService.knownPackageForName` — "WA Business" /
   "WhatsApp Business" -> w4b, "Playstore" / "Play Store" /
   "Google Play Store" -> vending), and the child's phone runs
   the same map natively (MainActivity `resolvePackageForName`,
   now also normalized-label matching: spaces/punctuation/case
   ignored, so "Playstore" finds "Play Store"); (3) entries the
   parent ALREADY added are healed when the parent opens the
   Locks tab (`_loadTargetLocks` resolves known aliases to real
   packages and re-publishes, so the child's phone gets them on
   next sync). Note: the child's phone was OFFLINE (no data) on
   24 Nov morning, so synced lock rules may not have reached it
   at all — the child must be online for any new lock to arrive.
   Nothing else changed: no location/battery/publish timing,
   no SOS, no call overlay, no trial/auth changes.
8. **Alert toggle that turned itself off — v0.6.9 (24 Nov 2026):**
   User-reported ~10:01 PKT: an alert switched ON kept turning
   itself OFF. Cause: the members node in RTDB never carries
   alert changes — `publishMyLocation` writes lat/lon/battery
   only, and alerts live in the separate `alerts/{memberId}` node
   — so every members snapshot arrived with the join-time alerts
   and overwrote the toggle the parent had just set, then `_save`
   persisted the reverted value. The child's phone was offline
   ("no data"), so no round-trip ever refreshed the members node.
   Fix: `FamilyService.applyRemoteMembers` keeps each existing
   member's LOCAL alerts when merging a remote members snapshot;
   only the alerts node (`subscribeAlerts`) may change them.
   Location, battery and online state still come from the
   snapshot. Same version, second half of the fix: (a) a toggle
   whose publish never landed (phone offline) is now tracked as
   pending — saved in SharedPreferences, retried on the next
   members event, and a stale server value never overwrites it
   while it is pending, so the toggle can no longer flip back
   OFF on its own; pending survives an app restart. (b) The two
   Locks-screen switches did nothing at all before — they only
   did a local setState and were never saved. They are now part
   of the locks node (`locks/{memberId}` gains `locationLocked`
   and `internetAlert`, old nodes read back with both ON):
   Location Lock makes the child's Map card say "Location is
   locked by your parent — turn sharing back on", and the
   background service already alerts the parent when sharing
   goes off; Internet-off alert arms a background check that
   reports the offline window (2 min or longer) to the parent
   when the phone is back online, labelled with when the
   internet went off. Honest limits: no app can block the
   phone's system GPS switch (Android limit) — the lock is the
   prompt plus the parent alert; an internet-off alert can only
   arrive after the phone is back online (no channel while
   offline except SMS, which covers location only). Tests: 18 in
   `test/v069_test.dart` (4 merge + 4 LockSettings + 5
   InternetOffTracker + 2 fake-sync end-to-end + 3 card
   wording); full suite 178/178 pass.
9. **Loud emergency alerts — v0.6.10 (24 Nov 2026):**
   User-reported ~10:19 PKT: an SOS/alert only showed as a silent
   red line INSIDE the app after someone opened it — no sound, no
   notification outside the app. For an emergency that is useless.
   Fix, app side only: (a) a dedicated "ApnaCircle Alerts"
   channel (IMPORTANCE_HIGH, sound + vibration + lights), created
   at startup, and the manifest points FCM's default channel at
   it — so a push arriving while the app is closed/killed is
   shown by the system on THIS loud channel; (b) foreground FCM
   pushes ring loud via a local notification (SOS with a
   full-screen intent — rings over the lock screen like an
   incoming call; other alerts ring loud without taking over the
   screen); (c) RTDB circle events arriving while the app is open
   also ring loud on top of the red banner, deduped against the
   FCM path (60 s window, shared type+sender+minute key) so one
   alert rings once, not twice; (d) tapping an alert notification
   opens the app on the Alerts tab. `USE_FULL_SCREEN_INTENT` was
   already declared in the manifest — Play Store needs a
   declaration/justification for it at submission (calling/alarm
   use case; SOS is the alarm-like case here — Google reviews
   this, approval is not guaranteed). Honest limits: push needs
   internet on the RECEIVER's phone — if a member's phone is
   offline (no data), no push can arrive (SMS fallback covers
   location only, not alerts); a user can still mute the channel
   or turn on Do Not Disturb (Android lets them); the Cloud
   Function `sendCircleEventPush` is STILL NOT deployed, so no
   push is sent at all while the app is closed — deploy it first
   (parent's step, code already exists since v0.5). Also: a
   message that carries a `notification` payload is displayed by
   the system itself, so SOS full-screen while killed needs the
   function to send data-only pushes (function code NOT changed
   in this version). Nothing else changed: no location/battery
   timing, no app-lock presets, no toggles, no trial/auth, no
   Cloud Function code. Tests: 10 new in `test/v0610_test.dart`.
10. **Family chat notifications — v0.6.11 (24 Nov 2026):**
   User-reported ~11:07 PKT: in the family chat, when someone sent
   a message nobody knew unless they opened the app. Like WhatsApp,
   a message now appears OUTSIDE the app — sender's name as the
   title + a short preview + sound — so members know a message
   arrived. Fix: (a) a SEPARATE "ApnaCircle Chat" channel (normal
   importance, sound + vibration) — chat NEVER rings like an SOS
   call, and it is a different channel from the v0.6.10 alerts
   channel, so it can be muted separately; (b) the app watches the
   circle's chat node live (FamilyService, first page = history,
   only genuinely new messages ring) and FCM pushes while the app
   is closed/background — both paths deduped by message id, so one
   message rings once, not twice; (c) NO notification for my own
   messages, and NO notification while the user is already looking
   at that circle's chat screen (same as WhatsApp); (d) tapping a
   chat notification opens the app on the Chat tab; (e) new Cloud
   Function `sendChatMessagePush` (CODE ONLY, not deployed) —
   sends the other members a DATA-ONLY push (sender name + preview)
   when a chat message is written; data-only on purpose, so the
   system never shows it on the loud alerts channel. Honest
   limits: the push needs the Cloud Function deployed first
   (parent's step, same deploy as the v0.5 event push — code
   already here) AND internet on the RECEIVER's phone — an offline
   member gets nothing until back online (chat history still syncs
   when they reconnect); a user can mute the chat channel in system
   settings; the message preview is visible on the lock screen,
   like WhatsApp (family app, acceptable). Nothing else changed:
   no location/battery timing, no app-lock, no toggles, no
   trial/auth, no SOS/alert behaviour, no alert-channel change.
   Tests: 18 new in `test/v0611_test.dart`.
   Build fix (24 Nov 2026, run #204): v0.6.10's CI build FAILED —
   `flutter_local_notifications` needs core library desugaring.
   Fixed in `android/app/build.gradle.kts`:
   `isCoreLibraryDesugaringEnabled = true` +
   `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")`.
   (First tried 2.0.4 — run #215 proved the plugin needs 2.1.4+.)
   Local checks cannot catch this (they never run Gradle) — CI is
   the only proof.
11. **Battery drain fix — v0.6.12 (25 Nov 2026):**
   User-reported ~07:23 PKT: the app drained his phone battery
   heavily — he saw it himself. Cause (verified in code): the
   background task runs every 60 s, 24/7, and took a FRESH
   high-accuracy GPS fix EVERY cycle (~1,440 GPS fixes/day). The
   50 m / 60 s throttle ran AFTER the fix, so it saved server
   writes but never saved battery — a phone sitting at home all
   day still fired the GPS radio every minute.
   Fix (new `LocationService.efficientFix`, used by the background
   cycle only): cheapest first — (a) a fresh OS-cached fix
   (≤ 2 min old) near our last fix proves the phone has not moved:
   use it, power nothing; (b) otherwise ONE low-power fix
   (cell/WiFi, medium accuracy, 10 s limit) checks for movement;
   (c) GPS only when that check suggests movement (> 50 m), when
   there is no baseline yet, or when the accurate baseline is
   older than 30 min (re-baseline cap). Steady state while
   stationary: roughly one GPS fix per 30 min instead of one per
   minute, plus a cheap cell/WiFi check every few minutes.
   Accuracy rule HONOURED: the 60 s cycle and the 50 m / 60 s
   publish throttle are unchanged — a real move is still caught
   within ~60 s, and what the parent sees (and when) is exactly
   what it was before; only HOW the fix is obtained changed.
   The foreground Map loop still takes a fresh high-accuracy fix
   (`currentFix`, unchanged) — the user is looking at the map.
   Honest note: exact battery saving varies by phone and must be
   checked on the user's phone (Settings → Battery) after install;
   on some phones the OS last-known cache does not update from
   low-power fixes, in which case the cycle does a cheap check
   every 60 s instead of every few minutes — still far cheaper
   than a GPS fix every minute. Deliberately left alone: the
   battery-level read every cycle (one cheap platform call, needed
   for the ≥ 2% change check), the connectivity check, the
   foreground-service notification text (only updated on a real
   publish), RTDB listeners (subscriptions, not polling).
   Tests: 17 new in `test/v0612_test.dart`.
12. **Uninstall protection — v0.6.13 (25 Nov 2026):**
   User order (~12:02–12:15 PKT): bacha app delete kar ke gayab
   ho gayi (mehvish ne app delete ki, parent ki list se gayab) —
   child apni marzi se app delete NA kar sake; delete karne par
   parent ka code (PIN) manga jaye; aur parent jab chahe apna code
   daal kar khud delete kar sake — apni app bhi.
   **Aik hi PIN — jo app lock kholta hai, wohi
   uninstall/account-delete/sign-out par bhi chalta hai.** Koi
   doosra code nahi hai: sab kuch usi stored parent PIN hash
   (`apnacircle:<pin>` SHA-256, wahi scheme jo LockActivity use
   karti hai) se verify hota hai.
   (a) **Device Owner QR setup (asal rok):** Settings →
   "Uninstall protection (Device Owner)" — parent PIN ke baad QR
   dikhta hai (APK download URL + optional Wi-Fi; checksum is
   phone par installed app ke signing certificate se banta hai).
   Bachay ka phone factory-reset (ya naya) → welcome screen par
   6 dafa tap → QR scan → Android APK download kar ke device
   owner bana deta hai. Us ke baad Settings se uninstall hota hi
   nahi. Parent ki taraf se hatane ka raasta: app ke andar se
   PIN-gated "Remove protection" (clearDeviceOwnerApp) — parent
   ka code hamesha chalta hai, woh kabhi lock out nahi hota.
   (b) **Device Admin — fauran alert:** admin band karte hi
   receiver pending flag likhta hai; background task (har 60 s)
   usay aik minute ke andar parent ko `adminDisabled` event bhej
   deta hai — ab parent ko ye jaanne ke liye child ke app dobara
   kholne ka intezar nahi. Next-start publish backup ke tor par
   rehta hai.
   (c) **Parent dekh sakta hai kaun protected hai:** har member
   node par `protection` field (owner/admin/none/unknown) publish
   hota hai; parent ki Map screen par har row par "Protected" /
   "Admin only" / "Not protected" likha aata hai.
   (d) **"Child gayab" notice:** kisi CHILD ki last update 2
   ghante se purani ho to us ki row par saaf warning aati hai
   ("2 ghante se koi update nahi — app delete ya phone off ho
   sakta hai"). Sirf in-app line — koi loud notification nahi
   (no-data aam baat hai). "Offline since [time]" waisa ka waisa.
   (e) **App ke andar ke escape hatches par parent PIN:** child
   role ke liye "Delete my account" aur "Sign out" (Circle screen
   aur Settings dono) aur Device Admin band karna — sab par
   parent PIN. Parent role par kabhi gate nahi. Koi hash kahin na
   mile to escape BLOCK hota hai (fail closed), kabhi bina
   verify ke nahi khulta.
   **Offline rule (user ka sawal: "net band ho to uninstall kar
   le?"):** enforcement kabhi network par nahi hai — Device
   Admin / Device Owner Android khud phone par naafiz karta hai,
   net off ho to bhi uninstall rukta hai. Parent PIN hash har
   member ke phone par locally cached hota hai
   (`flutter.parent_pin_sha256`, wahi key jo LockActivity
   parhti hai) — pehli sync ke baad har PIN gate net off par bhi
   chalta hai. Admin-off alert net off par fauran NAHI ja sakta
   (koi channel hi nahi — honest limit): woh durably queued
   rehta hai (pending flag sirf kamyab publish par clear hota
   hai) aur network aate hi ya app dobara chalte hi bhej diya
   jata hai; aur agar app hi delete ho gayi to 2-ghante wali
   khamoshi wali notice hi backstop hai.
   **Honest limits:** QR setup ke liye ek dafa factory reset
   chahiye (ya naya phone) — pehle se set-up phone par bina reset
   ke nahi ho sakta. Recovery-mode factory reset phir bhi phone
   wipe kar deta hai — koi app usay rok nahi sakti. Google FRP
   laagu rehta hai. QR sirf usi exact APK build ke liye valid
   hai jis se generate hua (CI builds har run par fresh debug key
   se sign hoti hain — wahi build URL par rakhein jo QR banate
   waqt phone par installed hai). PIN bache se secret rakhein —
   jo code janta hai, woh protection hata sakta hai; parent PIN
   bhool jaye to sirf factory reset hi protection hatata hai.
   Play Store submission par device-owner use ki justification
   chahiye hogi (family-safety / parental control). System ki
   uninstall screen par koi app apna PIN prompt NAHI laga sakti —
   ye Android ki screen hai; usay Device Admin / Device Owner hi
   rokte hain.
   Tests: `test/v0613_test.dart` (protection mapping + member
   field, 2-hour threshold, QR payload fields, adminDisabled
   shape, escape gate, removal gate dono directions, offline
   cases — cached-hash PIN verify, admin-status path, flag key).
13. **Wrong distance — v0.6.14 (25 Nov 2026):**
   User report (~12:36 PKT): "distance be saiii show nhi ho
   raha". Wajah: Map tab par har member ka distance aik
   HARDCODED Lahore point (31.5204, 74.3587) se napaa jata tha —
   har phone par, hamesha. Jahanian (~295 km Lahore se) wale
   user ko khud aur ghar walon ko "295.4 km away" dikhta tha.
   Call-overlay preview screen mein wahi constants thay. Haversine
   helper khud theek tha — "from" point ghalat tha. Native
   SIM-call overlay kabhi mutasir nahi hua: us ka cache Dart
   meri REAL published location se likhti hai.
   Fix: viewer ki position ab live resolve hoti hai — fresh GPS
   fix, warna last known fix, warna meri apni published member
   entry (`lib/core/viewer_position.dart`). Position pata na ho
   to distance '—' dikhta hai, kabhi made-up number nahi. Lahore
   sirf map ke initial camera ka fallback reh gaya hai — distance
   ke liye kabhi use nahi hota. Apni row fresh fix par ~0 m
   parhti hai (koi special case nahi — live position se natural).
   Phone par check: kisi member ke paas khade ho kar dekho — us
   ka distance chand metres aana chahiye, sau km nahi.
   **Call overlay — "na card na distance" (user, ~12:42 PKT):**
   jab mehvish call karti thi to card aata hi nahi tha — distance
   ghalat nahi, card hi nahi. Wajah: Gmail se login karne wale
   member ki `phone` field mein un ka EMAIL hota hai
   (`phoneNumber ?? email` fallback), aur email kabhi SIM number
   se match nahi hota — overlay trigger hi nahi hota tha. Koi UI
   number daalne ki thi hi nahi.
   (a) **Join time number:** "Join a circle" ab 6-digit code ke
   SAATH member ka mobile number bhi mangta hai — dono zaroori.
   Number validate hota hai (asli phone format, 10–13 digits,
   kabhi email nahi); bina / ghalat number ke join refuse hota
   hai, saaf message ke saath. Join ye number member node ki
   `phone` field mein likhta hai (email fallback khatam).
   (b) **Baad mein badalne ka option:** Locks screen par (jahan
   parent member manage karta hai) "Call distance — member's
   mobile number" — pehle se join hue members (mehvish) ke liye.
   Sirf parent, PIN-gated (wahi parent PIN); bacha apna number
   khud nahi badal sakta. Number server par likhte hi call-member
   cache refresh hota hai — agli SIM call par card aata hai.
   (c) **Overlay ki "my" position:** native cache ki myLat/myLon
   ab freshest real position hoti hai — live/last-known fix,
   stale published entry se behtar (`resolveCacheMyPosition`,
   `lib/core/call_member_cache.dart`). Dono na hon to distance
   nahi dikhta ('—'), kabhi made-up nahi. Trigger/permission
   (overlay permission) waisa ka waisa — masla number ka tha,
   permission ka nahi.
   **Note:** joining ab code ke saath mobile number bhi mangta
   hai — wahi number call-distance card ko chalata hai. Gmail
   login se app ko number milta hi nahi, is liye ye zaroori hai.
   Tests: `test/v0614_test.dart` (resolution precedence, 0 m /
   200 m / 3.6 km, unknown → '—', Jahanian regression, cache
   my-position freshest-wins, join validation, Gmail-never-matches,
   +92 vs 03… matching, parent-only change guard).
14. **OpenStreetMap — v0.6.15 (25 Nov 2026):** Google Maps hata
   diya — map tab blank tha kyun ke key nahi thi, aur key ke liye
   Google Cloud billing (card) chahiye hoti hai. Ab map
   OpenStreetMap hai (flutter_map 8.3.2 + latlong2): free, koi key
   nahi, koi card nahi — tiles internet se aate hain (offline par
   tiles nahi dikhte, members list phir bhi chalti hai). Attribution
   "© OpenStreetMap contributors" map par hamesha dikhta hai
   (OSM licence). Lahore sirf initial camera ka fallback hai —
   distance ke liye kabhi use nahi hota (v0.6.14 waisa ka waisa).
   Follow-me button camera ko meri live position par le jata hai;
   member card par tap us member par centre karta hai; pehli fix
   par camera aik dafa meri jagah par aata hai. `MAPS_API_KEY`
   (manifest, build.gradle.kts, gradle.properties) aur
   `google_maps_flutter` poori tarah hata diye gaye.
   Tests: `test/v0615_test.dart` (tile URL, marker conversion,
   camera fallback, attribution/user-agent constants) + v0.6.7
   widget test ab `FlutterMap` check karta hai.
   **Re-join after removal (rules v2 ke liye zaroori fix):**
   parent ne jis member ko remove kiya tha, wo code se dobara join
   kare to us ka member node dobara likha jata hai — pehle
   `joinCircle` role entry maujood hone par node likhta hi nahi
   tha, aur v2 rules mein `ensureMyMemberNode` bhi use wapas nahi
   bana sakta (read-first check membership gayab hone par DENIED
   hota hai). Is liye join ab node seedha likhta hai, bina read
   kiye (self-write v2 mein hamesha allowed hai). Tests:
   `test/v0615_test.dart` mein re-join group.
15. **Remove a member — v0.6.16 (25 Nov 2026):** parent apni Map
   screen par kisi bhi member ki row par "⋮" dabaye → "Remove from
   circle" → confirm dialog ("They can re-join with the invite
   code.") → parent PIN → member list se nikal jata hai. Sirf
   parent ko dikhta hai (child ko kabhi nahi), apni row par kabhi
   nahi, aur ghalat PIN par kuch nahi hota. Nikala hua member code
   se dobara join kar sakta hai. **Honest note:** abhi deploy hue
   rules v1 mein nikale hue member ki app apna node dobara bana
   sakti hai (agli location publish par) — removal hamesha ke liye
   tabhi pakka hoga jab rules v2 deploy hon. Tests:
   `test/v0616_test.dart` (guard, service, widget flow).
6. **Google Play Billing — asal khareed:** product
   `apnacircle_family_yearly` Play Console mein banana hai (subscription,
   $5/year) + Play developer account ($25, parent khud). Tab tak Plan
   screen "not in the Play Store yet" kehti hai.
6. **Privacy policy:** contact email bhar diya gaya (v0.5/v0.6);
   [PLAY_STORE_URL] aur [LAUNCH_DATE] launch par.
7. **Parent-phone-loss recovery — v0.3 mein code ho gaya:** account-based
   control, Email + Phone OTP login, PIN hash circle par save, "Restore
   my circles" (Circle screen). Baaki: do-phone test (naye phone par
   login → circle + PIN wapas). Co-parent / backup admin abhi nahi bana.
8. **Device Owner setup guide (QR, ek dafa)** — abhi nahi likha; FRP note
   Features 12 mein hai. **Root / system-app raasta kabhi nahi.**

## Real-phone checklist (APK milne ke baad, launch se pehle)

Ye sab is VM par verify NAHI ho sakta — asal phone par karna lazmi hai:

- [ ] App Lock: child's phone — Settings → Accessibility →
      ApnaCircle App Lock ON (Locks screen must show ON). Lock an
      app, open it — PIN screen must appear (LockActivity). Correct
      PIN = 5-minute grant, then it locks again. Time lock: 08:00
      par lock, 14:00 par auto-unlock; overnight window bhi test karein.
- [ ] SIM call: family member SIM se call kare — overlay par naam +
      distance (km) dikhe. Dual SIM par dono SIMs test karein.
- [ ] Location: do phones, ek ki live location doosre ke map par.
      Parent phone se child ko lock karein → child ke phone par lock
      lage (time window ke andar bhi).
- [ ] Battery (v0.6.6): ghar par baithe member ki battery 15 min
      mein update honi chahiye (bina hile); 30 min purani battery
      "(old)" ke saath dikhe.
- [ ] App Lock (v0.6.8): parent phone se Play Store aur WhatsApp
      Business lock karein → child ke phone (online + App Lock
      service ON) par dono khulte hi PIN screen aaye; "WA Business"
      ya "Playstore" naam se add karne par bhi lock lage.
- [ ] SOS / alerts (v0.6.10): SOS dabane par doosre phone par
      LOUD notification aani chahiye — awaz + vibration, app
      khula ho ya band; SOS par full-screen ring (call ki tarah),
      tap karne par Alerts tab khule. Band app par push sirf
      Cloud Function deploy ke baad aayega — pehle deploy karein,
      phir test karein. Do dafa ring nahi honi chahiye (FCM +
      RTDB dedupe). Phone silent / Do Not Disturb par ho to
      notification dab sakti hai (Android ki limit).
- [ ] Alerts (v0.6.9): parent phone se kisi member ka alert ON karein →
      app band karke dobara kholein (ya doosre member ki location
      update hone dein) → toggle ON hi rehna chahiye, khud OFF nahi
      hona chahiye; phir child ke phone (online) par usi alert ki
      value check karein — wahan bhi ON honi chahiye.
- [ ] Chat (v0.6.11): aik phone se family chat mein message bhejein →
      doosre phone par (app band ho ya Map tab par) sender ka naam +
      preview ke saath notification aani chahiye, awaz ke saath;
      apna khud ka message kabhi notification nahi banta; jis chat
      ko dekh rahe hain us ka notification nahi aana chahiye; tap
      karne par Chat tab khule. Band app par push sirf Cloud
      Function deploy ke baad aayega — pehle deploy karein, phir
      test karein. Aik message ki awaz do dafa nahi aani chahiye
      (FCM + RTDB dedupe).
- [ ] SIM-change: child ke phone mein dusri SIM daal kar reboot karein —
      parent ko "SIM card changed" alert mile (nayi SIM mein net zaroori).
- [ ] Distance (v0.6.14): do phones paas khade hon → ek doosre ka
      distance chand metres aana chahiye (sau km nahi); apni row
      ~0 m parhni chahiye. Kisi member ke paas ja kar dekho —
      distance ghatna chahiye, badhna nahi. Call preview (home
      screen ka phone button) mein bhi caller ka distance apni
      asal jagah se napna chahiye.
- [ ] Map (v0.6.15): Map tab par asal map (sadkein/gali) dikhe, sirf
      beige rang nahi; har member ka marker dikhe; neeche-left
      "© OpenStreetMap contributors" dikhe. Follow-me button
      dabayein → camera meri jagah par aaye. Member card par tap
      karein → camera us member par aaye. Data off ho to tiles na
      dikhein, list phir bhi dikhe.
- [ ] Re-join after removal (v0.6.15, rules v2): parent kisi member
      ko remove kare → wo code se dobara join kare → parent ki list
      mein wo dobara dikhna chahiye (pehle dikhta hi nahi tha).
- [ ] Remove member (v0.6.16): parent kisi member ki row par "⋮"
      → "Remove from circle" → confirm → parent PIN → member list
      se gayab ho jaye; ghalat PIN par kuch na ho; child ke phone
      par "⋮" dikhe hi nahi; wo code se dobara join kare → dobara
      dikhna chahiye.
- [ ] Device Admin: Settings se protection ON karein → uninstall ki
      koshish karein (rukni chahiye) → admin band karein → parent ko
      alert mile.
- [ ] Uninstall protection (v0.6.13): parent ki Map screen par har
      member ke saath "Protected" / "Admin only" / "Not protected"
      dikhe. Child ke phone par Settings → "Delete my account" /
      "Sign out" / "Remove protection" dabayein → parent PIN manga
      jaye; ghalat PIN par kuch na ho; sahi PIN (wahi jo app lock
      kholta hai) par kaam ho. Net OFF kar ke bhi yehi gates test
      karein — PIN gate net ke baghair bhi chalna chahiye (hash
      locally cached hai). Admin band karein → aik minute ke andar
      parent ko alert mile; net off par alert queued rahe aur
      network aate hi pahunche. Child 2 ghante khamosh rahe →
      parent ki screen par "2 ghante se koi update nahi" wali line
      dikhe. Device Owner QR: sirf factory-reset / naye phone par
      test karein (pehle se set-up phone par nahi ho sakta); QR
      scan ke baad Settings se uninstall ka option hi na ho;
      parent apna code daal kar "Remove protection" kare → phir
      uninstall ho sake.
- [ ] SIM call (v0.6.5): family member SIM se call kare — overlay par naam +
      distance (km) dikhe. Aap member ko call karein — wahi overlay dikhe.
      Pehle Settings mein Phone + Call Log ki ijazat dein AUR "Call
      distance overlay" ON karein (Display over other apps). Dual SIM
      par dono SIMs test karein. Overlay par tap karne se wo band ho.
      Non-member ki call par kuch nahi dikhna chahiye.
- [ ] SIM call number (v0.6.14): Gmail se join hue member (mehvish) ki
      call par card aana chahiye. Pehle Locks screen par us ka mobile
      number save karein (parent PIN) → phir us ki SIM call par card +
      asal distance dikhe. Naya join: code ke saath number na dein to
      join refuse ho; email number ke tor par dein to refuse ho.
- [ ] Account delete: Settings → Delete account → confirm → account
      delete ho, dobara sign in na ho.
- [ ] App icon: home screen par naya icon (green shield + pin) dikhe.
- [ ] Offline SMS: child ka data off karein → 15 min mein parent ko
      SMS location mile, map par "SMS se aayi" dikhe. SMS sirf parent
      ke number par jaye.
- [ ] Circles: parent naye phone par usi account se login kare → wahi
      circle + wahi PIN wapas (bache ke phone par kuch nahi karna).
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

## APK build status — 23 Nov 2026 (update)
- GitHub Actions builds the APK on every push (`.github/workflows/build-apk.yml`).
  Runs #28 (v0.2), #43 (v0.3) aur #59 (v0.4, trial) — teeno SUCCESS.
  APK: run ke Artifacts (`apnacircle-apk`) se download karein.
- Is VM par `flutter build apk` ABHI BHI NAHI chalta (Gradle daemon ka
  loopback TCP intercept hota hai — neeche purani tafseel). Local proof:
  `flutter analyze` clean + `flutter test` 49/49 + `flutter build bundle` exit 0.
- **Purani tafseel (22 Nov 2026, fast-track attempt):** is VM mein shuru mein
  Flutter / Dart / Java / Android SDK kuch nahi tha. Flutter 3.24.5 download
  kar ke install kiya (`~/flutter-sdk`), JDK 17 (Temurin) bhi install kiya —
  `flutter analyze` clean aur `flutter test` 9/9 pass ho gaye. Android SDK
  bhi manual install kar liya (`~/android-sdk`: platform-tools, platform-34,
  build-tools 34.0.0, licenses) — `sdkmanager` ka Java HTTP stack is VM ke
  authenticated egress proxy (CONNECT tunnel) se guzar nahi pata
  (`HttpURLConnection.doTunneling` mein `NoSuchElementException`), is liye
  packages `curl` se download kiye. Gradle daemon ka IPC bhi pehle fail hua
  (`Could not receive a message from the daemon`) — ye
  `-Djava.net.preferIPv4Stack=true` se theek ho gaya aur build 77 second tak
  chala. **Aakhri blocker:** Gradle ke dependency downloads (Android Gradle
  Plugin 8.3.2, `dl.google.com` aur `repo.maven.apache.org` se) mein
  `java.net.SocketException: Connection reset` aata hai — Java ka TLS is VM
  ke egress proxy se reset ho jata hai, jab ke `curl` se wahi URLs 200 OK
  dete hain. Ye is VM ke network/proxy ki pabandi hai, code ki ghalti nahi.
- **Fastest way to get the APK (about 10 minutes, no card, no new account
  needed if you already have a free GitHub account):**
  1. Push this folder to a free GitHub repo.
  2. The file `.github/workflows/build-apk.yml` is already in the project —
     GitHub Actions builds the APK automatically on push.
  3. Download it from the run's Artifacts (`apnacircle-apk`).
