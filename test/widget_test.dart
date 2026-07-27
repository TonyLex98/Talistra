import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/main.dart';
import 'package:transreade/services/library_service.dart';
import 'package:transreade/services/page_image_cache.dart';
import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/statistics_service.dart';

// path_provider has no platform channel handler under `flutter test`, so
// any call through it hangs forever instead of throwing — point it at a
// throwaway temp directory instead.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String _path = Directory.systemTemp
      .createTempSync('transread_test_')
      .path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;

  @override
  Future<String?> getTemporaryPath() async => _path;
}

void main() {
  PathProviderPlatform.instance = _FakePathProviderPlatform();

  testWidgets('Home screen shows empty library state', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    // Real file I/O (the thumbnail/preview caches touch the real
    // filesystem) never resolves inside testWidgets' fake-async zone —
    // it has to run through runAsync to actually complete.
    late final SettingsService settings;
    late final LibraryService library;
    late final ThumbnailCache thumbnailCache;
    late final PagePreviewCache previewCache;
    late final StatisticsService statistics;
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      settings = SettingsService.load(prefs);
      library = await LibraryService.load(prefs);
      thumbnailCache = await ThumbnailCache.create();
      previewCache = await PagePreviewCache.create();
      statistics = await StatisticsService.load(prefs);
    });

    await tester.pumpWidget(
      TransReadeApp(
        settings: settings,
        library: library,
        thumbnailCache: thumbnailCache,
        previewCache: previewCache,
        statistics: statistics,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Litra'), findsOneWidget);
    expect(find.text('Ваша библиотека пуста'), findsOneWidget);
  });
}
