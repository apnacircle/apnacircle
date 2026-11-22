# ApnaCircle — APK ke liye push kaise karein (1 step baaki hai)

**Status (22 Nov 2026):** Code tayyar hai aur git mein commit ho gaya hai
(commit `27b27f3`, 54 files, branch `main`). **APK abhi nahi bana** — is VM
par Gradle ka daemon loopback ki wajah se nahi chalta, is liye APK GitHub
Actions se banega. Koi GitHub account is machine par login nahi hai
(`gh auth status` = not logged in, GitHub connector = not_connected),
is liye push ke liye ek GitHub account chahiye.

## Jo chahiye (sirf ek cheez)

* Ek **free GitHub account** (github.com par free banta hai, koi card nahi
  chahiye) + ek **khali public repo** (naam: `apnacircle`).

## Push karne ke commands (is folder mein)

```bash
cd ~/workspace/apnacircle-app
git remote add origin https://github.com/<AAPKA-USERNAME>/apnacircle.git
git push -u origin main
```

GitHub username/password nahi mangta — pehli push par browser mein sign-in
hoga ya personal access token mangega (token GitHub → Settings →
Developer settings → Personal access tokens se banta hai).

## APK kahan milega

1. GitHub repo kholein → **Actions** tab → **Build ApnaCircle APK** run.
2. Push karte hi run khud shuru ho jata hai (5–10 minute).
3. Run ke neeche **Artifacts → apnacircle-apk** se `app-release.apk`
   download karein (90 din tak rehta hai).

Workflow file: `.github/workflows/build-apk.yml` (pehle se mojood hai).

## Agar Muse se karwana ho

Muse app mein GitHub connect karein (Connectors → GitHub), phir Lucky
repo bana kar push kar degi — is ke liye Mujahid ko sirf GitHub par
sign-in karna hoga, koi password chat mein nahi dena.
