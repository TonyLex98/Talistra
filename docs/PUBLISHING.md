# Publishing Talistra to RuStore

Talistra is distributed without advertising. Do not add an advertising SDK,
advertising identifier, or advertising declaration to a release unless that
product decision changes.

## One-time signing setup

Create and safely back up the Android upload key:

```powershell
keytool -genkey -v -keystore android/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Create `android/key.properties` locally; it is ignored by Git:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=upload-keystore.jks
```

Never commit the key or its passwords. The same key must sign every future
update of this application.

## Build

Increase `version:` in `pubspec.yaml` before each upload, then run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build appbundle --release
flutter build apk --release
```

The AAB is at `build/app/outputs/bundle/release/app-release.aab`; the APK is
at `build/app/outputs/flutter-apk/app-release.apk`.

## RuStore release checklist

- Create the application in RuStore Console with the name **Talistra**.
- Use category **Books**; choose a second category only when it is relevant.
- Add a Russian short description, full description, icon, and phone
  screenshots that show the library, reading, DjVu/PDF, translation, and
  reading-display settings.
- Publish a public privacy-policy URL and add a support contact email.
- Declare: no account required, no advertising, and only the permissions and
  data practices that are actually present in the submitted build.
- Upload the signed AAB or APK, check the generated preview, and send the
  draft to moderation.

## Privacy-policy baseline

Talistra stores documents, progress, and settings locally on the device. The
optional translation models are downloaded once from the model provider and
then operate offline. Talistra has no advertising SDK and does not sell or share
reader data. Add the developer contact email and publication date before
hosting the policy.
