import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Central place for ad configuration.
///
/// **Before a real release**, replace [bannerAdUnitId] below AND the
/// `com.google.android.gms.ads.APPLICATION_ID` meta-data in
/// `android/app/src/main/AndroidManifest.xml` with your own AdMob IDs
/// (from https://apps.admob.com). Both are currently set to Google's
/// published TEST IDs, which are safe to ship as-is during development —
/// they only ever serve clearly-labeled placeholder ads and never earn
/// real revenue. See docs/ADS_SETUP.md for the full checklist.
class AdsService {
  AdsService._();

  static const String bannerAdUnitId = 'ca-app-pub-3940256099942544/6300978111';

  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    await MobileAds.instance.initialize();
  }
}

/// A single, unobtrusive banner — sized to its natural (small) banner
/// dimensions, not a full-width takeover — meant for the library screen
/// only. Deliberately never shown anywhere in the reading views
/// themselves, so reading stays uninterrupted; and it simply disappears
/// (rather than showing a broken placeholder) if no ad loads, e.g. with
/// no network.
class LibraryBannerAd extends StatefulWidget {
  const LibraryBannerAd({super.key});

  @override
  State<LibraryBannerAd> createState() => _LibraryBannerAdState();
}

class _LibraryBannerAdState extends State<LibraryBannerAd> {
  BannerAd? _bannerAd;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // The ads SDK's platform channels (and its internal lifecycle timers)
    // never resolve under `flutter test`'s fake binary messenger, which
    // would otherwise hang `pumpAndSettle()` forever — so skip it there.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await AdsService.ensureInitialized();
      final ad = BannerAd(
        adUnitId: AdsService.bannerAdUnitId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            if (mounted) setState(() => _loaded = true);
          },
          onAdFailedToLoad: (ad, error) {
            ad.dispose();
          },
        ),
      );
      _bannerAd = ad;
      await ad.load();
    } catch (_) {
      // No ads SDK available / offline / not yet configured — the
      // library screen just renders without the banner row.
    }
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _bannerAd;
    if (!_loaded || ad == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
