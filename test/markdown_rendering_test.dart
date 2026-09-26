import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/markdown_blocks.dart';
import 'package:transreade/utils/reading_text_style.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/txt_paragraphs.dart';
import 'package:transreade/widgets/translatable_text.dart';
import 'package:transreade/widgets/txt_page_view.dart';

/// Read by [_pump], which builds the view the way the reader screen does.
late SettingsService settings;

/// A document with every structure the parser can produce in it, written long
/// enough that the pages have to be turned to read all of it.
const _markdown = '''
# Chapter one

Some running text that has to be laid out in a column, with a word or two of
its own left over at the end.

## A list

- apple
- citrus
  - lemon

1. one
2. two

> A quote, which is set inside a bar.
>
> ### Quoted heading

```dart
void main() {
  print('plain stars');
}
```

| Item | Qty |
|------|-----|
| Pen  | 12  |

---

Text after the rule, which is the last thing the book says and so the easiest
line to lose off the bottom of a page.
''';

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  double fontSize = 22,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: TxtPageView(
            pages: buildTxtPagesFromBlocks(parseMarkdownBlocks(markdown)),
            initialPage: 1,
            source: TranslateLanguage.english,
            target: TranslateLanguage.russian,
            translationService: TranslationService(),
            fontSize: fontSize,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: false,
            onPageChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The on-screen text drawn for [text], which has to be visible for this to
/// find it.
TranslatableText _shown(WidgetTester tester, String text) =>
    tester.widget<TranslatableText>(
      find.byWidgetPredicate(
        (widget) => widget is TranslatableText && widget.text == text,
      ),
    );

/// The first block of [blocks] that [test] picks out, failing clearly if the
/// document didn't produce one.
String _textOf(
  List<ReflowBlock> blocks,
  bool Function(ReflowBlock) test,
  String what,
) {
  final block = blocks.where(test).firstOrNull;
  expect(block, isNotNull, reason: 'no $what in the parsed document');
  return block!.text;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService.load(prefs);
  });

  testWidgets('a whole markdown book paints inside the space it was given', (
    tester,
  ) async {
    // The paginator measures a page with the very styles the view paints
    // with. If the two ever disagree, the last line runs off the bottom of
    // the page and Flutter reports the overflow itself — the bigger the
    // font, the fewer lines fit, and the faster a disagreement shows.
    await _pump(tester, _markdown, fontSize: 26);
    expect(tester.takeException(), isNull);
    expect(find.text('Chapter one'), findsOneWidget);
  });

  testWidgets('a heading is set larger than the running text below it', (
    tester,
  ) async {
    final blocks = parseMarkdownBlocks('# Title\n\nBody words.\n');
    await _pump(tester, '# Title\n\nBody words.\n');
    expect(
      _shown(tester, blocks.first.text).style!.fontSize,
      greaterThan(_shown(tester, blocks.last.text).style!.fontSize!),
    );
  });

  testWidgets('a code panel is monospace and takes no emphasis', (
    tester,
  ) async {
    const markdown = '```dart\n**not bold**\n```';
    final code = parseMarkdownBlocks(markdown).single;
    expect(code.isCode, isTrue);
    await _pump(tester, markdown);
    final shown = _shown(tester, code.text);
    expect(shown.style!.fontFamily, codeFontFamily);
    // Nothing inside the panel is emphasis, whatever its characters read as.
    expect(shown.formatRuns, isEmpty);
  });

  testWidgets('a table is set as preformatted text, header bold', (
    tester,
  ) async {
    const markdown = '| Item | Qty |\n|------|-----|\n| Pen  | 12  |';
    final table = parseMarkdownBlocks(markdown).single;
    await _pump(tester, markdown);
    final shown = _shown(tester, table.text);
    expect(shown.style!.fontFamily, codeFontFamily);
    expect(shown.formatRuns.single.bold, isTrue);
  });

  testWidgets('inline styling reaches the page as runs over the plain text', (
    tester,
  ) async {
    const markdown =
        'A **bold** word, *an italic* one, `code`, ~~removed~~ and '
        '[a link](https://example.com).';
    final block = parseMarkdownBlocks(markdown).single;
    await _pump(tester, markdown);
    final shown = _shown(tester, block.text);
    expect(
      shown.formatRuns.map((run) => block.text.substring(run.start, run.end)),
      ['bold', 'an italic', 'code', 'removed', 'a link'],
    );
  });

  testWidgets('a rule is drawn without a word of its own', (tester) async {
    final blocks = parseMarkdownBlocks('Before\n\n---\n\nAfter');
    expect(_textOf(blocks, (b) => b.isDivider, 'a rule'), isEmpty);
    await _pump(tester, 'Before\n\n---\n\nAfter');
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning the pages reaches every character the document has', (
    tester,
  ) async {
    final blocks = parseMarkdownBlocks(_markdown);
    await _pump(tester, _markdown);

    // A block split over pages is painted in slices, so walking the whole
    // book has to reassemble it from its pieces: anything the paginator
    // dropped, repeated or reordered shows up as a hole or an overlap here.
    final slices = <String, Set<({int start, int end})>>{};
    for (var page = 0; page < 30; page++) {
      for (final shown in tester.widgetList<TranslatableText>(
        find.byType(TranslatableText),
      )) {
        slices.putIfAbsent(shown.text, () => {}).add((
          start: shown.start,
          end: shown.end ?? shown.text.length,
        ));
      }
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }

    for (final block in blocks) {
      // A rule is a hairline, not a piece of text, so no word of it is ever
      // painted.
      if (block.text.isEmpty) continue;
      final Set<({int start, int end})> painted =
          slices[block.text] ?? const {};
      expect(
        painted.fold<int>(0, (sum, slice) => sum + slice.end - slice.start),
        block.text.length,
        reason: '${block.text} is painted once, whole and in order',
      );
      expect(
        painted.map((slice) => slice.start).reduce(math.min),
        0,
        reason: '${block.text} starts on a page',
      );
    }
  });
}
