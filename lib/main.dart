import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/gen/app_localizations.dart';
import 'screens/home_screen.dart';
import 'services/library_service.dart';
import 'services/model_download_service.dart';
import 'services/page_image_cache.dart';
import 'services/settings_service.dart';
import 'services/statistics_service.dart';
import 'services/translation_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: register a free Syncfusion Community License at
  // https://www.syncfusion.com/products/communitylicense to remove the
  // trial banner from the PDF viewer, then uncomment the line below:
  // SyncfusionLicense.registerLicense('YOUR_LICENSE_KEY');

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService.load(prefs);
  final library = await LibraryService.load(prefs);
  final thumbnailCache = await ThumbnailCache.create();
  final previewCache = await PagePreviewCache.create();
  final statistics = await StatisticsService.load(prefs);

  if (!settings.instructionsSeeded) {
    await _seedInstructionsPdf(settings, library);
  }

  runApp(
    TransReadeApp(
      settings: settings,
      library: library,
      thumbnailCache: thumbnailCache,
      previewCache: previewCache,
      statistics: statistics,
    ),
  );
}

// Adds the bundled user-guide PDF to the library exactly once, right after
// a fresh install — never again after that, even across later app updates
// or if the reader deletes it. Failure here (e.g. the asset is somehow
// missing) must never block app startup, so it's swallowed silently; the
// flag is only marked seeded on success, so a failed attempt can still be
// retried on the next cold start.
Future<void> _seedInstructionsPdf(
  SettingsService settings,
  LibraryService library,
) async {
  try {
    final data = await rootBundle.load(
      'assets/instructions/transread_guide.pdf',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final title = settings.appLocale.languageCode == 'ru'
        ? 'Инструкция — как пользоваться Litra'
        : 'Litra — User Guide';
    await library.importBytes(bytes: bytes, title: title);
    await settings.markInstructionsSeeded();
  } catch (error, stack) {
    debugPrint('Failed to seed instructions PDF: $error\n$stack');
  }
}

class TransReadeApp extends StatelessWidget {
  const TransReadeApp({
    super.key,
    required this.settings,
    required this.library,
    required this.thumbnailCache,
    required this.previewCache,
    required this.statistics,
  });

  final SettingsService settings;
  final LibraryService library;
  final ThumbnailCache thumbnailCache;
  final PagePreviewCache previewCache;
  final StatisticsService statistics;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        Provider<ThumbnailCache>.value(value: thumbnailCache),
        Provider<PagePreviewCache>.value(value: previewCache),
        ChangeNotifierProvider<StatisticsService>.value(value: statistics),
        Provider<TranslationService>(
          create: (_) => TranslationService(),
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProxyProvider<TranslationService, ModelDownloadService>(
          create: (context) =>
              ModelDownloadService(context.read<TranslationService>()),
          update: (context, translationService, previous) =>
              previous ?? ModelDownloadService(translationService),
        ),
      ],
      child: Consumer<SettingsService>(
        builder: (context, settings, _) {
          return MaterialApp(
            title: 'Litra',
            debugShowCheckedModeBanner: false,
            // One appearance for the whole app, built from the reading
            // settings (see [AppTheme.from]) — the library and settings
            // used to look like a different app from the reader.
            theme: AppTheme.from(settings),
            locale: settings.appLocale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
