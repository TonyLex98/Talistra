# Publishing TransRead — Google Play & RuStore

This covers everything from "I have the source code" to "the app is live,"
for both stores. Read it once end to end before starting — the two stores
share most of the same build artifact but have different account/review
requirements.

App identity, for reference throughout:
- Package name / Application ID: `com.transreade.transreade`
- Display name: **TransRead**
- Current version: `1.0.0+1` (`pubspec.yaml` → `version:`, format
  `versionName+versionCode`)

---

## 0. One-time prerequisites

- A Google account for the Play Console (one-time **$25 USD registration
  fee**, paid once, covers all your apps forever).
- A RuStore developer account (free) — register at
  https://console.rustore.ru. Requires either an individual (self-employed
  "самозанятый" works) or legal-entity registration, per RuStore's current
  rules — check their onboarding page for the latest requirements since
  this changes occasionally.
- A **privacy policy URL**, publicly reachable. Both stores require one
  even for an app with no accounts/analytics, because the app requests
  the file-picker/storage permission and (once you flip on real ads)
  bundles an ads SDK. The simplest route: write a short one-page policy
  (see §5) and host it for free as a GitHub Pages site or a Gist — any
  stable public URL works, it doesn't need to be fancy.
- Finish [docs/ADS_SETUP.md](ADS_SETUP.md) (swap in real AdMob IDs) before
  you submit for real — Play/RuStore review can reject a submission that
  ships Google's placeholder test ad unit IDs, since real users would see
  "Test Ad" banners.

---

## 1. Generate your release signing key

Android requires every release build to be signed with the same key for
the lifetime of the app (Play Store additionally re-signs with its own
"Play App Signing" key on top, but you still need to give it an initial
"upload key"). Do this once and keep the keystore file and its passwords
somewhere safe and backed up — **losing it means you can never publish an
update to the same app listing again.**

From the project root:

```
keytool -genkey -v -keystore android/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

`keytool` ships with any JDK (Flutter's bundled JDK works — if `keytool`
isn't found on your PATH, run it from inside
`<Android Studio install dir>/jbr/bin/`). It'll prompt for a store
password, your name/org, and a key password — remember these.

Then create `android/key.properties` (this file is already gitignored —
never commit it):

```properties
storePassword=<the store password you set>
keyPassword=<the key password you set>
keyAlias=upload
storeFile=upload-keystore.jks
```

The project's `android/app/build.gradle.kts` is already wired to pick
this file up automatically and sign release builds with it — you don't
need to touch any Gradle config. Until this file exists, release builds
silently fall back to debug signing (fine for local testing, **not**
fine to upload to a store).

---

## 2. Build the release artifacts

Google Play wants an **App Bundle** (`.aab`); RuStore accepts either an
`.aab` or a plain `.apk` (check current RuStore console requirements —
they've supported AAB for a while but always confirm on upload).

```
flutter build appbundle --release
flutter build apk --release
```

Outputs:
- `build/app/outputs/bundle/release/app-release.aab` (Play Store)
- `build/app/outputs/flutter-apk/app-release.apk` (RuStore, or Play if you
  ever need a direct APK)

Before building, bump the version in `pubspec.yaml`:
```
version: 1.0.0+1
```
Increment the number **after** the `+` (the build number / versionCode)
on every single upload to either store, even for a same-versionName hotfix
— stores reject a re-upload with a versionCode they've already seen. Bump
the part before `+` (versionName, e.g. `1.0.1`) whenever you want the
user-visible version string to change.

---

## 3. Google Play Console

1. https://play.google.com/console → **Create app**. Fill in name
   (TransRead), default language (Russian), app/game = App, free/paid =
   Free (unless you intend otherwise), and the two declarations
   (developer program policies + US export laws).
2. **Store listing** (Grow → Store presence → Main store listing):
   - Short description (max 80 chars) and full description (max 4000).
     Suggested short description (ru): «Читалка PDF с переводом слов и
     предложений прямо на устройстве». Feel free to refine.
   - App icon: 512×512 PNG. Regenerate from
     `android/app/src/main/res/mipmap-*/ic_launcher.png` at high res, or
     re-export from whatever source art was used for the launcher icon.
   - Feature graphic: 1024×500 PNG/JPG — a simple banner with the app
     name works fine for a first submission.
   - Phone screenshots: **minimum 2**, PNG/JPG, min dimension 320px, max
     3840px, 16:9 or 9:16 aspect. Take these from a real device/emulator
     running the app (Settings screen, reader with a translation popup
     visible, and the library are good choices) — reuse the same
     screenshots you'll use for the in-app instructions PDF (§ task #41)
     if convenient.
3. **App content** (Grow → Store presence → App content) — required
   before you can release to production:
   - Privacy policy: paste the URL from §0.
   - App access: declare there's no login required (all features are
     available without an account).
   - Ads: declare **yes, the app contains ads** once you've enabled real
     AdMob IDs (or **no** if you keep ads disabled for the initial
     release — either is fine, just answer truthfully for the build
     you're actually uploading).
   - Content rating questionnaire: answer honestly — this is a reading/
     translation utility with no user-generated content, no violence,
     etc., so it should land in the lowest rating tier automatically.
   - Target audience: 18+ or general audience per your judgment; nothing
     in the app is age-restricted.
   - Data safety form: declare what the app actually does. Currently:
     no personal data collected or shared by TransRead's own code; the
     only network activity is (a) the on-device ML Kit translation model
     download, which goes to Google's model CDN, not to you, and (b)
     once ads are enabled, the ads SDK's own standard ad-request/
     analytics traffic (declare per Google's AdMob data-safety guidance —
     they publish an exact checklist for apps using their SDK).
4. **Release → Production → Create new release**:
   - Upload the `.aab` from §2.
   - If this is the very first release, Play requires either **App
     Signing by Google Play** (recommended, default — upload your
     upload-key-signed bundle and Google re-signs it) — just accept the
     default, don't opt out.
   - Add release notes (what's new — for v1.0.0, something like "First
     release").
   - Save → Review release → Start rollout to Production (or use an
     **Internal testing** / **Closed testing** track first, which is
     recommended for a first-ever submission so you can install via a
     private link and sanity-check the listing before it's public).
5. Submit for review. First-time app review is commonly a few hours to a
   few days. You'll get an email either way; if rejected, the console
   shows the specific policy reason — fix and resubmit (does not require
   a new version, generally, unless they specifically ask for a build
   change).

### Play Store specifics worth knowing
- **64-bit requirement**: Flutter's default build already includes
  arm64-v8a, satisfied automatically — no action needed.
- **Target API level**: Play enforces a minimum `targetSdk` (updated
  roughly yearly). `targetSdk = flutter.targetSdkVersion` in
  `build.gradle.kts` tracks whatever your installed Flutter SDK
  currently defaults to — run `flutter upgrade` periodically and rebuild
  before each new submission so you don't fall behind Play's minimum.

---

## 4. RuStore

1. https://console.rustore.ru → register as a developer (individual or
   legal entity) → **Add app**.
2. Fill in the same category of listing info as Play: name, description,
   icon, screenshots, category, age rating (RuStore uses its own age-
   marking system, roughly analogous to Play's — answer the
   questionnaire the same honest way), privacy policy URL.
3. Upload the `.aab` or `.apk` from §2. RuStore's console will run its own
   automated + manual review; turnaround has historically been on the
   order of a day or two but check current SLAs in their console.
4. RuStore does **not** require Google Play Services to be present on the
   device, which matters for two things already covered elsewhere in this
   project:
   - AdMob (Google Play Services-based) may not serve reliably on
     RuStore-only devices. If ads matter to you specifically for RuStore
     users, see the **Yandex Ads** section in
     [docs/ADS_SETUP.md](ADS_SETUP.md).
   - `google_mlkit_translation` (used for on-device translation) also
     depends on Google Play Services/ML Kit being installed. On a device
     that truly has no Google services at all, the translation feature's
     model download will fail — but this is exactly why the app-wide
     translator on/off toggle exists: a user on such a device can turn
     translation off entirely and still use TransRead as a plain PDF/text
     reader (the mode the earlier work in this project specifically
     built for). Consider mentioning this in the RuStore listing
     description so it's not a surprise.
5. Signing: RuStore accepts the same signed artifact you built for Play
   in §2 — no separate keystore needed, reuse `android/upload-keystore.jks`.

---

## 5. Minimal privacy policy template

Host this (or your refined version) at any stable public URL and use
that URL in both stores' listings.

```
Privacy Policy — TransRead

TransRead is a PDF/document reader with optional on-device translation.

Data collection: TransRead does not collect, store, or transmit any
personal data to its developer. All documents you open, your reading
progress, and your settings are stored locally on your device only.

Translation: word/sentence translation runs fully on-device using
Google's ML Kit. The first time you use a language pair, its translation
model (a few dozen MB) is downloaded from Google's servers directly to
your device; after that, translation works fully offline. No text you
translate is sent to the developer.

Advertising: [if/when ads are enabled] TransRead shows ads via
[Google AdMob / Yandex Ads]. These SDKs may collect device identifiers
and usage data per their own privacy policies:
- Google AdMob: https://policies.google.com/privacy
- Yandex Ads: https://yandex.com/legal/confidential/

Contact: [your email or GitHub URL]

Last updated: [date]
```

Fill in the bracketed parts before publishing, and delete the
Advertising paragraph entirely for any release where ads are left off.

---

## 6. Checklist before every submission

- [ ] `pubspec.yaml` version bumped (both versionName and versionCode)
- [ ] Real AdMob (and/or Yandex) IDs in place if ads are enabled this
      release — no lingering test IDs (see ADS_SETUP.md)
- [ ] `android/key.properties` + `upload-keystore.jks` present locally
      (not committed) and release build signs with them, not debug
- [ ] `flutter build appbundle --release` and `flutter build apk --release`
      both succeed
- [ ] Fresh screenshots if the UI changed meaningfully since the last set
- [ ] Privacy policy URL still resolves
- [ ] Data safety / ads declarations still match what the build actually
      does
