# Ads setup — switching from test IDs to your real account

The app currently ships with **Google's official published TEST IDs** for
AdMob. They are safe to build and even publish for internal testing as-is —
they only ever serve clearly-labeled placeholder creatives and never earn
real money — but you must replace them with your own IDs before a real,
public release, or AdMob will eventually suspend the account for invalid
traffic.

Ads only appear as a single small banner at the bottom of the **library
screen** (the file list). They never appear inside the reader (PDF or
reflow view), so reading itself is never interrupted — this was a
deliberate design choice, not a limitation.

## What you need to replace (2 values, both currently test IDs)

### 1. AdMob App ID

File: [`android/app/src/main/AndroidManifest.xml`](../android/app/src/main/AndroidManifest.xml)

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3940256099942544~3347511713"/>
```

Replace the `android:value` with your own App ID.

### 2. Banner ad unit ID

File: [`lib/services/ads_service.dart`](../lib/services/ads_service.dart)

```dart
static const String bannerAdUnitId = 'ca-app-pub-3940256099942544/6300978111';
```

Replace with your own banner ad unit ID.

## How to get your own IDs

1. Go to https://apps.admob.com and sign in (or create an account — it's
   free, tied to any Google account, no payment info needed just to get
   IDs and test the integration; you'll need payout/tax details later to
   actually receive earnings).
2. **Apps → Add app** → register the app (package name
   `com.transreade.transreade`, platform Android). This gives you the
   **App ID** (`ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY` format) — goes into
   the manifest.
3. Inside that app, **Ad units → Add ad unit → Banner**. This gives you
   the **ad unit ID** (`ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ` format) —
   goes into `ads_service.dart`.
4. If the app isn't published on Google Play yet, AdMob will show it as
   "not linked" — that's fine, ads still serve (in test/limited mode)
   until the Play listing goes live, at which point link it from the
   AdMob app settings page.

## Testing after swapping in real IDs

- Real ad units on an unpublished/unreviewed app may show blank or very
  few fills at first — this is normal, not a bug.
- To verify integration without touching your fill rate, register your
  test device: AdMob will print a line like
  `"Use RequestConfiguration.Builder().setTestDeviceIds(...)"` in Android
  logcat the first time a real ad unit ID is requested. Add that device
  ID via `MobileAds.instance.updateRequestConfiguration(...)` temporarily
  while testing, or just keep the current test ID in place until you're
  ready to submit to Play/RuStore, then swap both values in one commit
  right before the release build.

## Yandex Ads (RuStore alternative)

Google Play Services (and therefore AdMob) isn't guaranteed to be present
on all devices that install from RuStore. If you plan to distribute
specifically through RuStore and want ads to reliably serve there too,
the community package
[`yandex_mobileads`](https://pub.dev/packages/yandex_mobileads) is the
standard choice — it wraps Yandex's own Mobile Ads SDK, which doesn't
depend on Google Play Services.

This has **not** been implemented in code — only documented here, since
it's a separate SDK/account (Yandex.Ads: https://ads.yandex.com) with its
own app/ad-unit registration flow analogous to the AdMob steps above. If
you do add it, mirror the same pattern already in place:
- keep it isolated to `lib/services/ads_service.dart` (or a sibling
  `yandex_ads_service.dart`) so the rest of the app doesn't need to know
  which SDK is in use,
  and equally, only surface it on the library screen — not in the reader.

## Design decisions already baked in (don't need to be reconsidered)

- **No interstitials, no rewarded ads, no full-screen ads anywhere.** Only
  a single small banner, and only on the library screen.
- **Reader screens (PDF + reflow) are permanently ad-free.** This was an
  explicit requirement — reading must never be interrupted by ads.
- If an ad fails to load (no network, no fill, IDs not yet linked), the
  banner area simply collapses to zero height rather than showing a
  broken placeholder box.
