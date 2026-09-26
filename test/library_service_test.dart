import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/models/library_document.dart';
import 'package:transreade/services/library_service.dart';

const _key = 'library_documents';

LibraryDocument _doc({int lastPage = 3, String? filePath}) => LibraryDocument(
  id: 'book',
  title: 'Book',
  filePath: filePath ?? 'book.txt',
  addedAt: DateTime.utc(2026, 1, 1),
  sourceFingerprint: 'book_1',
  pageCount: 100,
  lastPage: lastPage,
  format: 'txt',
);

/// The page the persisted library says the reader is on, or null when nothing
/// has been written yet.
int? _savedPage(SharedPreferences prefs) {
  final raw = prefs.getStringList(_key);
  if (raw == null || raw.isEmpty) return null;
  return LibraryDocument.fromJson(
    jsonDecode(raw.first) as Map<String, dynamic>,
  ).lastPage;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The coalesced save only defers while the app is in the foreground.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a page turn moves the model now and the disk a moment later', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final service = LibraryService(prefs, [_doc()]);

    await service.updateProgress('book', lastPage: 44, pageCount: 100);

    expect(service.documents.single.lastPage, 44);
    expect(_savedPage(prefs), isNull);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(_savedPage(prefs), 44);
  });

  testWidgets('a run of page turns is one write, timed from the last of them', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final service = LibraryService(prefs, [_doc()]);

    // A swipe every half second: each turn has to cancel the write the
    // previous one queued, or the reader pays for a save per frame.
    for (var page = 10; page <= 13; page++) {
      await service.updateProgress('book', lastPage: page, pageCount: 100);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_savedPage(prefs), isNull);

    await tester.pump(const Duration(milliseconds: 600));
    expect(_savedPage(prefs), isNull);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_savedPage(prefs), 13);
  });

  testWidgets('leaving the reader writes the page that was still waiting', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final service = LibraryService(prefs, [_doc()]);

    await service.updateProgress('book', lastPage: 7, pageCount: 100);
    expect(_savedPage(prefs), isNull);

    service.saveNow();
    await tester.pump();
    expect(_savedPage(prefs), 7);
  });

  testWidgets('going to the background flushes the waiting page', (
    tester,
  ) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}library_service_book.txt',
    )..writeAsStringSync('once upon a time');
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, [
      jsonEncode(_doc(filePath: file.path).toJson()),
    ]);
    // Only load() — the way the app builds the service — watches for this.
    // Checking the file is real I/O, which fake time cannot wait for.
    late final LibraryService service;
    await tester.runAsync(
      () async => service = await LibraryService.load(prefs),
    );
    expect(service.documents.single.id, 'book');

    await service.updateProgress('book', lastPage: 21, pageCount: 100);
    expect(_savedPage(prefs), 3);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(_savedPage(prefs), 21);

    // The same moment finds a page turned while the app is away: nothing is
    // animating and the process may not survive, so there is nothing to wait
    // for — it goes straight out.
    await service.updateProgress('book', lastPage: 23, pageCount: 100);
    await tester.pump();
    expect(_savedPage(prefs), 23);

    service.dispose();
  });
}
