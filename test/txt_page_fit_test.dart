import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/markdown_blocks.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/txt_paragraphs.dart';
import 'package:transreade/widgets/translatable_text.dart';
import 'package:transreade/widgets/txt_page_view.dart';

late SettingsService settings;

final _key = GlobalKey<TxtPageViewState>();

/// Paragraphs the way an FB2 novel hands them over: Cyrillic prose of every
/// length, from a line of dialogue to a paragraph that runs over a page.
List<String> _novel() {
  const sentence =
      'Он долго смотрел в окно, где над крышами медленно поднималось '
      'серое утро, и думал о том, что всё это уже когда-то было. ';
  return [
    for (var i = 0; i < 120; i++)
      i % 5 == 0 ? '— Да, — сказал он.' : sentence * (1 + (i * 7) % 9),
  ];
}

Future<void> _loadFont(String family, String asset) async {
  final loader = FontLoader(
    family,
  )..addFont(Future.value(ByteData.sublistView(File(asset).readAsBytesSync())));
  await loader.load();
}

Future<void> _pump(
  WidgetTester tester,
  List<List<ReflowBlock>> pages, {
  required double fontSize,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 392,
          height: 700,
          child: TxtPageView(
            key: _key,
            pages: pages,
            initialPage: 1,
            source: TranslateLanguage.russian,
            target: TranslateLanguage.english,
            translationService: TranslationService(),
            fontSize: fontSize,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: true,
            onPageChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Turns through the first [count] screens, failing on the first one whose
/// text runs past the bottom of the page.
Future<void> _turnPages(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    expect(tester.takeException(), isNull, reason: 'screen $i overflowed');
    await tester.drag(find.byType(PageView), const Offset(-392, 0));
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    await _loadFont('Literata', 'assets/fonts/Literata.ttf');
    await _loadFont('Inter', 'assets/fonts/Inter.ttf');
    await _loadFont('EBGaramond', 'assets/fonts/EBGaramond.ttf');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService.load(prefs);
  });

  for (final fontSize in [15.0, 17.0, 19.0, 22.0, 26.0]) {
    testWidgets('no line is cut off at the bottom at ${fontSize}px', (
      tester,
    ) async {
      final pages = buildTxtPagesFromParagraphs(_novel());
      await _pump(tester, pages, fontSize: fontSize);
      await _turnPages(tester, 30);
    });
  }

  for (final fontSize in [16.0, 19.0, 24.0]) {
    testWidgets(
      'inline code and bold are measured as painted at ${fontSize}px',
      (tester) async {
        // Emphasis is set wider than the plain text around it — code in a
        // monospace face, bold at a heavier weight — so a paragraph thick with
        // it wraps into more lines than its plain text would.
        final source = [
          for (var i = 0; i < 60; i++)
            'Вызовите `configureReaderPagination()` и **обязательно проверьте** '
                    'результат `layoutResult.overflowedLines`, прежде чем '
                    '**передавать страницу** в `PageView.builder`. ' *
                (1 + i % 4),
        ].join('\n\n');
        final pages = buildTxtPagesFromBlocks(parseMarkdownBlocks(source));
        await _pump(tester, pages, fontSize: fontSize);
        await _turnPages(tester, 25);
      },
    );
  }

  testWidgets('a tapped word keeps the width it was paginated at', (
    tester,
  ) async {
    // A tapped word is repainted in the translation card's highlight. If that
    // made it any wider, its line could wrap once more than the paginator
    // measured, and the page's last line would be pushed off the bottom.
    const text =
        'Он долго смотрел в окно, где над крышами медленно поднималось серое '
        'утро, и думал о том, что всё это уже когда-то было, и не раз.';
    final words = RegExp(r'[\p{L}]+', unicode: true).allMatches(text);
    Future<Size> layOut({int? start, int? end}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: TranslatableText(
                key: const ValueKey('text'),
                text: text,
                settings: settings,
                fontSize: 19,
                readingTheme: settings.readingTheme,
                translatorEnabled: true,
                selectedStart: start,
                selectedEnd: end,
                onWordTap: (_, _, _) {},
              ),
            ),
          ),
        ),
      );
      final box = tester.renderObject<RenderBox>(find.byType(RichText));
      return box.size;
    }

    final plain = await layOut();
    for (final word in words) {
      final selected = await layOut(start: word.start, end: word.end);
      expect(selected, plain, reason: 'selecting "${word[0]}" moved the text');
    }
  });

  testWidgets('a new reading font lays the book out again', (tester) async {
    // Laid out in a compact face, then read in a much wider one: the size of
    // the column hasn't changed, but every line break has.
    await settings.setReadingFont(ReadingFont.ebGaramond);
    final pages = buildTxtPagesFromParagraphs(_novel());
    await _pump(tester, pages, fontSize: 19);
    await settings.setReadingFont(ReadingFont.inter);
    await _pump(tester, pages, fontSize: 19);
    await _turnPages(tester, 20);
  });
}
