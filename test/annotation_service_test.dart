import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/services/annotation_service.dart';
import 'package:transreade/widgets/annotations_sheet.dart';

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('a bookmark goes on and comes off', () async {
    final service = AnnotationService.load(prefs);
    expect(await service.toggleBookmark('book', 12), isTrue);
    expect(service.isBookmarked('book', 12), isTrue);
    expect(service.isBookmarked('book', 13), isFalse);
    expect(service.isBookmarked('other', 12), isFalse);
    expect(await service.toggleBookmark('book', 12), isFalse);
    expect(service.isBookmarked('book', 12), isFalse);
  });

  test('notes and bookmarks survive a restart, in page order', () async {
    final service = AnnotationService.load(prefs);
    await service.addNote(
      documentId: 'book',
      page: 30,
      quote: 'passage',
      note: ' mine ',
    );
    await service.toggleBookmark('book', 4);
    final note = (await service.addNote(
      documentId: 'book',
      page: 9,
      quote: 'no thought',
      note: '',
    ));
    expect(note.note, isNull);

    final reloaded = AnnotationService.load(prefs);
    final kept = reloaded.forDocument('book');
    expect(kept.map((a) => a.page), [4, 9, 30]);
    expect(kept.first.isBookmark, isTrue);
    expect(kept.last.quote, 'passage');
    expect(kept.last.note, 'mine');
  });

  test('a removed book takes its notes with it', () async {
    final service = AnnotationService.load(prefs);
    await service.toggleBookmark('gone', 1);
    await service.toggleBookmark('kept', 1);
    await service.removeDocument('gone');
    expect(service.forDocument('gone'), isEmpty);
    expect(service.forDocument('kept'), hasLength(1));
  });

  test('a broken entry costs only itself', () {
    final decoded = AnnotationService.decode(
      '[{"id":"a","documentId":"b","page":1,"createdAt":"2026-01-01T00:00:00"},'
      '{"id":"broken"}]',
    );
    expect(decoded.single.id, 'a');
    expect(AnnotationService.decode('not json'), isEmpty);
  });

  testWidgets('the sheet lists what was left and turns to it', (tester) async {
    final service = AnnotationService.load(prefs);
    await service.toggleBookmark('book', 3);
    await service.addNote(
      documentId: 'book',
      page: 8,
      quote: 'Всё проходит.',
      note: 'и это пройдёт',
    );
    int? picked;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: service,
        child: MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showAnnotationsSheet(
                  context,
                  documentId: 'book',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Стр. 3'), findsOneWidget);
    expect(find.text('Всё проходит.'), findsOneWidget);
    expect(find.text('и это пройдёт'), findsOneWidget);

    // Deleting the bookmark takes it off the list at once.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('Стр. 3'), findsNothing);

    await tester.tap(find.text('Стр. 8'));
    await tester.pumpAndSettle();
    expect(picked, 8);
  });
}
