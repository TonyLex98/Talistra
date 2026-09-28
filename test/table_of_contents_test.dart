import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/table_of_contents.dart';
import 'package:transreade/widgets/contents_sheet.dart';

ReflowBlock _h(int level, String text) =>
    ReflowBlock.paragraph(text, headingLevel: level);

ReflowBlock _p(String text) => ReflowBlock.paragraph(text);

void main() {
  group('text books', () {
    test('headings become entries on the page they open', () {
      final toc = tocFromPages([
        [_h(1, 'Книга'), _p('…')],
        [_p('…'), _h(2, 'Глава 1\nНачало')],
        [_h(3, 'Часть'), _h(5, 'Слишком глубоко')],
      ]);
      expect(toc.map((e) => (e.title, e.level, e.page)), [
        ('Книга', 1, 1),
        ('Глава 1. Начало', 2, 2),
        ('Часть', 3, 3),
      ]);
    });

    test('depth counts from the shallowest heading the book uses', () {
      final toc = tocFromPages([
        [_h(3, 'One')],
        [_h(4, 'One.a')],
      ]);
      expect(toc.map((e) => e.level), [1, 2]);
    });

    test('a book without headings has no contents', () {
      expect(
        tocFromPages([
          [_p('just prose')],
        ]),
        isEmpty,
      );
    });

    test('the current chapter is the last one started', () {
      final toc = [
        const TocEntry(title: 'a', level: 1, page: 3),
        const TocEntry(title: 'b', level: 1, page: 10),
      ];
      expect(currentTocIndex(toc, 1), isNull);
      expect(currentTocIndex(toc, 3), 0);
      expect(currentTocIndex(toc, 9), 0);
      expect(currentTocIndex(toc, 40), 1);
    });
  });

  test('a PDF outline is read with its nesting and pages', () async {
    final source = PdfDocument();
    for (var i = 0; i < 5; i++) {
      source.pages.add();
    }
    final chapter = source.bookmarks.add('Chapter')
      ..destination = PdfDestination(source.pages[1]);
    chapter.add('Section').destination = PdfDestination(source.pages[3]);
    final bytes = await source.save();
    source.dispose();

    final document = PdfDocument(inputBytes: bytes);
    final toc = pdfOutline(document);
    document.dispose();
    expect(toc.map((e) => (e.title, e.level, e.page)), [
      ('Chapter', 1, 2),
      ('Section', 2, 4),
    ]);
  });

  testWidgets('the sheet lists the chapters and answers with a page', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
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
              onPressed: () async {
                picked = await showContentsSheet(
                  context,
                  entries: const [
                    TocEntry(title: 'Первая', level: 1, page: 1),
                    TocEntry(title: 'Вторая', level: 1, page: 7),
                  ],
                  currentPage: 8,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Оглавление'), findsOneWidget);
    await tester.tap(find.text('Вторая'));
    await tester.pumpAndSettle();
    expect(picked, 7);
  });
}
