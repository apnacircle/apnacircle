# ApnaCircle — Privacy Policy

**Last updated: 23 Nov 2026 (v0.5).**

**App name:** ApnaCircle — family location safety app.
**Developer:** Mujahid Siddique (individual developer account).
**Contact:** mujahidsiddique0786@gmail.com
**Play listing:** [PLAY_STORE_URL] — launch ke baad bharni hai.

## 1. Hum kya data lete hain — aur kyon

| Data | Kyon | Kab |
|---|---|---|
| Live location (GPS) | Family circle mein ek doosre ko dekhna, SOS, arrival alerts | Sirf jab member ne location sharing ON ki ho |
| Last location + time | Net band ho to aakhri location dikhana | Net off hone par, local save hoti hai |
| Battery level + online/offline | Battery-low aur phone-off alerts | Location update ke sath |
| Phone number | Family circle mein member pehchan aur SIM-call distance | Account banate waqt |
| Email address | Account sign-in aur verification link | Account banate waqt |
| App lock list | Parent jo apps lock kare (e.g. YouTube) | Sirf parent set karta hai |
| Chat messages | Family chat | Sirf circle ke members dekhte hain |
| Parent PIN (hash only) | Settings lock — PIN khud kabhi save nahi hota, sirf us ka SHA-256 hash | Parent PIN set karte waqt |
| SIM fingerprint (hash only) | SIM badalne par family ko alert | SIM check par — sirf operator ka hash, ICCID/IMSI kabhi nahi liye jate |
| Device hash (trial) | 7-day free trial sirf ek dafa per phone | Trial shuru karte waqt — Android ID ka SHA-256 hash, raw ID kabhi nahi |
| FCM push token | SOS / alerts ki push notification bhejna | Sign-in ke baad, sirf aap ke apne account par |
| Purchase status | Family plan subscription active hai ya nahi | Google Play Billing se khareed par (card details hum tak kabhi nahi aati) |

**Hum ye data NAHI lete:** contacts list, photos, browsing history,
bank / card details (payment Google Play Billing se hoti hai, card ki
details hum tak nahi aati), call recordings, SMS ka content (sirf
hamari apni "APNACIRCLE LOC:" location SMS parhi jati hai), aur kisi
bhi stranger ki location.

## 2. Location ka data kis ko dikhta hai

- Sirf **aap ke apne family circle (max 10 members)** ko.
- Koi ad company, koi teesra shakhs, aur koi stranger aap ki location
  nahi dekh sakta.
- **Location ka data becha nahi jata. Koi ad nahi hai.**

## 3. Location sharing band karna

- Member khud apni sharing band kar sakta hai — **agar parent ne
  Location Lock lagaya ho to nahi** (tab sirf parent PIN se khulega).
  Ye is liye hai taaki bache ki safety ke liye parent ko pata rahe.
- Location Lock sirf family circle ke andar kaam karta hai, aur
  parent hi is ko laga / hata sakta hai.

## 4. App Lock, Device Admin aur permissions

- **App Lock** ke liye app ko Accessibility permission chahiye hoti
  hai — ye sirf ye dekhne ke liye hai ke locked app khuli ya nahi,
  aur kuch parhne / likhne ke liye nahi.
- **Device Admin (uninstall protection):** agar parent is ko on kare
  to app uninstall karne se pehle admin band karna parta hai, aur
  band karte hi parent ko alert milta hai. Ye uninstall ko poori
  tarah rok nahi sakta — ye Android ki had hai, aur hum is se zyada
  ka daawa nahi karte.
- **Phone / Call Log permission** sirf SIM call par caller ki distance
  dikhane ke liye hai — number sirf aap ki apni screen par fasilah
  dikhane ke liye use hota hai.
- **SMS permission** sirf net band hone par aakhri location SMS se
  parent ko bhejne ke liye hai (parent ki marzi se), aur sirf hamari
  apni location SMS parhne ke liye hai.

## 5. Bachon ka data (Children)

- App family ke liye hai — bache sirf parent ki nigrani mein use karein.
- Parent apne bache ka account banata hai aur us ki settings control
  karta hai. Hum bache se seedha koi data nahi mangte.
- Bache ki location sirf us ke apne family circle ko dikhti hai.

## 6. Data kitne arse rehta hai aur delete kaise karein

- Location history: circle ke liye zaroori arse tak.
- **Account delete:** Settings → Delete account. Delete karte hi aap
  ka account, aap ki profile aur aap ke member entries delete ho
  jate hain. Jo chat messages aur alerts aap pehle bhej chuke hain,
  woh circle ki shared history mein reh sakte hain — woh sirf circle
  ke members ko dikhte hain. Jo circle aap ne parent ke tor par
  banaya tha, woh baaqi members ke liye chalta rehta hai.
- Agar aap chahte hain ke aap ka data abhi delete ho, to upar wale
  email (mujahidsiddique0786@gmail.com) par likhein — 30 din ke
  andar delete kar diya jayega.

## 7. Data kahan rehta hai

- Live data Firebase (Google) ke servers par rehta hai, jo ke
  [Firebase ki privacy policy](https://firebase.google.com/support/privacy)
  ke under hai. Aap ka data kisi aur mulk mein transfer ho sakta hai
  jahan Google ke server hon.
- Push notifications Google Firebase Cloud Messaging se bheji jati
  hain (Cloud Function ke zariye — server key kabhi app mein nahi hoti).
- Trial aur SIM-check ke hashes bhi Firebase Realtime Database mein
  rehte hain — raw Android ID, ICCID ya IMSI kabhi save nahi hote.

## 8. Tabdeeli

- Is policy mein tabdeeli ho to app mein aur Play listing par nayi
  date ke sath update kar di jayegi. Ahem tabdeeli ho to app ke andar
  bataya jayega.

**Effective date:** [LAUNCH_DATE] — launch ke din bharni hai.
