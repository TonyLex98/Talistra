import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/gen/app_localizations.dart';
import 'screens/home_screen.dart';
import 'services/annotation_service.dart';
import 'services/app_reloader.dart';
import 'services/library_service.dart';
import 'services/model_download_service.dart';
import 'services/page_image_cache.dart';
import 'services/reading_display_service.dart';
import 'services/search_index_cache.dart';
import 'services/settings_service.dart';
import 'services/statistics_service.dart';
import 'services/translation_service.dart';
import 'services/vocabulary_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: register a free Syncfusion Community License at
  // https://www.syncfusion.com/products/communitylicense to remove the
  // trial banner from the PDF viewer, then uncomment the line below:
  // SyncfusionLicense.registerLicense('YOUR_LICENSE_KEY');

  final prefs = await SharedPreferences.getInstance();
  final stored = await StoredServices.load(prefs);
  final thumbnailCache = await ThumbnailCache.create();
  final previewCache = await PagePreviewCache.create();
  final searchIndexCache = await SearchIndexCache.open();
  final readingDisplay = ReadingDisplayService();

  if (!stored.settings.instructionsSeeded) {
    await _seedInstructionsPdf(stored.settings, stored.library);
  }

  runApp(
    _TalistraHost(
      prefs: prefs,
      initial: stored,
      thumbnailCache: thumbnailCache,
      previewCache: previewCache,
      searchIndexCache: searchIndexCache,
      readingDisplay: readingDisplay,
    ),
  );
}

/// The services that live in SharedPreferences — everything a restored
/// backup changes underneath the app, and so everything that has to be
/// loaded again after one.
class StoredServices {
  StoredServices._(
    this.settings,
    this.library,
    this.statistics,
    this.annotations,
    this.vocabulary,
  );

  final SettingsService settings;
  final LibraryService library;
  final StatisticsService statistics;
  final AnnotationService annotations;
  final VocabularyService vocabulary;

  static Future<StoredServices> load(SharedPreferences prefs) async {
    final services = StoredServices._(
      SettingsService.load(prefs),
      await LibraryService.load(prefs),
      await StatisticsService.load(prefs),
      AnnotationService.load(prefs),
      VocabularyService.load(prefs),
    );
    // A book a restored backup knew comes back under a new id; what was
    // kept for the old one follows it.
    services.library.onRestoredFromBackup = (backupId, documentId) {
      unawaited(services.annotations.reassign(backupId, documentId));
      unawaited(services.statistics.reassign(backupId, documentId));
    };
    return services;
  }

  void dispose() {
    library.dispose();
    settings.dispose();
    statistics.dispose();
    annotations.dispose();
    vocabulary.dispose();
  }
}

class _TalistraHost extends StatefulWidget {
  const _TalistraHost({
    required this.prefs,
    required this.initial,
    required this.thumbnailCache,
    required this.previewCache,
    required this.searchIndexCache,
    required this.readingDisplay,
  });

  final SharedPreferences prefs;
  final StoredServices initial;
  final ThumbnailCache thumbnailCache;
  final PagePreviewCache previewCache;
  final SearchIndexCache searchIndexCache;
  final ReadingDisplayService readingDisplay;

  @override
  State<_TalistraHost> createState() => _TalistraHostState();
}

class _TalistraHostState extends State<_TalistraHost> {
  late StoredServices _stored = widget.initial;

  Future<void> _reload() async {
    await widget.prefs.reload();
    final fresh = await StoredServices.load(widget.prefs);
    if (!mounted) return;
    final old = _stored;
    setState(() => _stored = fresh);
    // Nothing is listening to the old ones once this frame is built.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  Widget build(BuildContext context) {
    return TalistraApp(
      settings: _stored.settings,
      library: _stored.library,
      thumbnailCache: widget.thumbnailCache,
      previewCache: widget.previewCache,
      searchIndexCache: widget.searchIndexCache,
      statistics: _stored.statistics,
      readingDisplay: widget.readingDisplay,
      annotations: _stored.annotations,
      vocabulary: _stored.vocabulary,
      reload: _reload,
    );
  }
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
    required this.annotations,
    required this.vocabulary,
    this.reload,
  });

  /// Loads the stored services again (see [AppReloader]); nothing to do in a
  /// test that built them itself.
  final Future<void> Function()? reload;

  final SettingsService settings;
  final LibraryService library;
  final ThumbnailCache thumbnailCache;
  final PagePreviewCache previewCache;
  final SearchIndexCache searchIndexCache;
  final StatisticsService statistics;
  final ReadingDisplayService readingDisplay;
  final AnnotationService annotations;
  final VocabularyService vocabulary;

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
        ChangeNotifierProvider<AnnotationService>.value(value: annotations),
        ChangeNotifierProvider<VocabularyService>.value(value: vocabulary),
        Provider<AppReloader>.value(value: AppReloader(reload ?? () async {})),
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
