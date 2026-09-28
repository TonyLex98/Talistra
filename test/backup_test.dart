import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/models/library_document.dart';
import 'package:transreade/services/annotation_service.dart';
import 'package:transreade/services/backup.dart';
import 'package:transreade/services/library_service.dart';
import 'package:transreade/services/statistics_service.dart';
import 'package:transreade/services/vocabulary_service.dart';

class _FakePaths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

LibraryDocument _book(String id, String fingerprint, {int lastPage = 1}) =>
    LibraryDocument(
      id: id,
      title: 'Book $id',
      filePath: '/nowhere/$id.fb2',
      addedAt: DateTime.utc(2026, 1, 1),
      sourceFingerprint: fingerprint,
      pageCount: 300,
      lastPage: lastPage,
      format: 'fb2',
    );

/// Everything one phone holds: a book half read, a note in it, a word kept,
/// some reading time — and a setting changed.
Future<String> _backupOfFirstPhone() async {
  SharedPreferences.setMockInitialValues({
    'library_documents': [
      jsonEncode(_book('old-id', 'novel.fb2_1000', lastPage: 142).toJson()),
    ],
    'reading_font': 'lora',
    'last_document_id': 'old-id',
    'reading_statistics_v3': jsonEncode({
      'seconds': {'old-id': 3600},
      'readPages': {
        'old-id': [1, 2, 3],
      },
      'dailySeconds': {'2026-02-01': 3600},
      'dailyPages': {
        '2026-02-01': ['old-id:1', 'old-id:2', 'old-id:3'],
      },
    }),
  });
  final prefs = await SharedPreferences.getInstance();
  await AnnotationService.load(
    prefs,
  ).addNote(documentId: 'old-id', page: 140, quote: 'passage', note: 'thought');
  await VocabularyService.load(
    prefs,
  ).add(word: 'serendipity', sourceLanguage: 'en', targetLanguage: 'ru');
  return createBackup(prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a backup restores onto the same book on another phone', () async {
    final backup = await _backupOfFirstPhone();

    // The new phone has the same file under a new id, read to page 1.
    SharedPreferences.setMockInitialValues({
      'library_documents': [
        jsonEncode(_book('new-id', 'novel.fb2_1000').toJson()),
      ],
    });
    final prefs = await SharedPreferences.getInstance();
    await restoreBackup(prefs, backup);

    final library = await LibraryService.load(prefs);
    // The file isn't really there in a test, so read the stored entry.
    final stored = LibraryDocument.fromJson(
      jsonDecode(prefs.getStringList('library_documents')!.single)
          as Map<String, dynamic>,
    );
    library.dispose();
    expect(stored.id, 'new-id');
    expect(stored.lastPage, 142);
    expect(prefs.getString('reading_font'), 'lora');
    // What only mattered on the first phone stays there.
    expect(prefs.getString('last_document_id'), isNull);

    final note = AnnotationService.load(prefs).forDocument('new-id').single;
    expect((note.page, note.quote, note.note), (140, 'passage', 'thought'));
    expect(VocabularyService.load(prefs).entries.single.word, 'serendipity');
    final stats = await StatisticsService.load(prefs);
    expect(stats.byDocument.single.documentId, 'new-id');
    expect(stats.totalSeconds, 3600);
    expect(stats.totalPages, 3);
  });

  test('restoring the same backup twice changes nothing more', () async {
    final backup = await _backupOfFirstPhone();
    final prefs = await SharedPreferences.getInstance();
    await restoreBackup(prefs, backup);
    await restoreBackup(prefs, backup);
    expect(AnnotationService.load(prefs).forDocument('old-id'), hasLength(1));
    expect(VocabularyService.load(prefs).entries, hasLength(1));
    expect((await StatisticsService.load(prefs)).totalSeconds, 3600);
  });

  test('anything but a backup is refused and changes nothing', () async {
    SharedPreferences.setMockInitialValues({'reading_font': 'inter'});
    final prefs = await SharedPreferences.getInstance();
    for (final raw in ['not json', '{"format":"other"}', '[1,2]']) {
      await expectLater(restoreBackup(prefs, raw), throwsFormatException);
    }
    expect(prefs.getString('reading_font'), 'inter');
  });

  testWidgets('a book added later picks its progress up from the backup', (
    tester,
  ) async {
    final backup = await tester.runAsync(_backupOfFirstPhone);
    final dir = Directory.systemTemp.createTempSync('talistra_backup_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePaths(dir.path);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await restoreBackup(prefs, backup!);
    expect(prefs.getStringList(pendingRestoreKey), hasLength(1));

    final library = LibraryService(prefs, []);
    addTearDown(library.dispose);
    final moved = <(String, String)>[];
    library.onRestoredFromBackup = (from, to) => moved.add((from, to));
    // The same file, picked again: same name, same size.
    final source = File('${dir.path}/novel.fb2')
      ..writeAsBytesSync(List.filled(1000, 32));
    final document = (await tester.runAsync(
      () => library.importText(
        sourcePath: source.path,
        title: 'novel',
        format: 'fb2',
      ),
    ))!;
    expect(document.lastPage, 142);
    expect(moved, [('old-id', document.id)]);
    expect(prefs.getStringList(pendingRestoreKey), isEmpty);
  });
}
