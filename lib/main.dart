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
import 'services/reading_display_service.dart';
import 'services/search_index_cache.dart';
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
  final searchIndexCache = await SearchIndexCache.open();
  final statistics = await StatisticsService.load(prefs);
  final readingDisplay = ReadingDisplayService();

  if (!settings.instructionsSeeded) {
    await _seedInstructionsPdf(settings, library);
  }

  runApp(
    TalistraApp(
      settings: settings,
      library: library,
      thumbnailCache: thumbnailCache,
      previewCache: previewCache,
      searchIndexCache: searchIndexCache,
      statistics: statistics,
      readingDisplay: readingDisplay,
    ),
  );
}

// Adds the bundled user-guide PDF once for each guide version. A later guide
// migration replaces only the older bundled copy, never a reader-imported
// document. Failure here must never block startup; the flag is marked only
// after success so a failed attempt is retried on the next cold start.
Future<void> _seedInstructionsPdf(
  SettingsService settings,
  LibraryService library,
) async {
  try {
    final data = await rootBundle.load(
      'assets/instructions/talistra_guide.pdf',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final title = settings.appLocale.languageCode == 'ru'
        ? 'Инструкция — как пользоваться Talistra'
        : 'Talistra — User Guide';
    // Replace only a previous bundled guide after an app update. A document
    // imported by the reader is never removed here.
    for (final document in library.documents) {
      if (document.sourceFingerprint.startsWith('bundled_') &&
          (document.title.contains('Litra') ||
              document.title.contains('Talistra'))) {
        await library.remove(document.id);
      }
    }
    await library.importBytes(
      bytes: bytes,
      title: title,
      sourceFingerprint: 'bundled_talistra_guide_v5',
    );
    await settings.markInstructionsSeeded();
  } catch (error, stack) {
    debugPrint('Failed to seed instructions PDF: $error\n$stack');
  }
}

class TalistraApp extends StatelessWidget {
  const TalistraApp({
    super.key,
    required this.settings,
    required this.library,
    required this.thumbnailCache,
    required this.previewCache,
    required this.searchIndexCache,
    required this.statistics,
    required this.readingDisplay,
  });

  final SettingsService settings;
  final LibraryService library;
  final ThumbnailCache thumbnailCache;
  final PagePreviewCache previewCache;
  final SearchIndexCache searchIndexCache;
  final StatisticsService statistics;
  final ReadingDisplayService readingDisplay;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<LibraryService>.value(value: library),
        Provider<ThumbnailCache>.value(value: thumbnailCache),
        Provider<PagePreviewCache>.value(value: previewCache),
        Provider<SearchIndexCache>.value(value: searchIndexCache),
        ChangeNotifierProvider<StatisticsService>.value(value: statistics),
        Provider<ReadingDisplayService>(
          create: (_) => readingDisplay,
          dispose: (_, service) => service.dispose(),
        ),
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
            title: 'Talistra',
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
