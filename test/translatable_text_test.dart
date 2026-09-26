import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/utils/reading_text_style.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/widgets/translatable_text.dart';

/// Read by [_paint], which builds the widget the way the readers do.
late SettingsService settings;

/// Everything every reader asks of its text: the document's own emphasis, the
/// selected word, the search hits, and a tap that names the word it landed on.
const _sentence = 'the quick brown fox';

/// Offsets of three of [_sentence]'s four words within it.
const _quick = (start: 4, end: 9);
const _brown = (start: 10, end: 15);
const _fox = (start: 16, end: 19);

/// Pumps [_sentence] sliced to `start..<end>` and returns the spans it painted.
Future<List<TextSpan>> _paint(
  WidgetTester tester, {
  int start = 0,
  int? end,
  List<FormatRun> formatRuns = const [],
  int? selectedStart,
  int? selectedEnd,
  ({int start, int end})? highlight,
  List<({int start, int end})> otherHighlights = const [],
  bool translatorEnabled = true,
  void Function(int start, int end, String word)? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TranslatableText(
          text: _sentence,
          start: start,
          end: end,
          formatRuns: formatRuns,
          settings: settings,
          fontSize: 18,
          readingTheme: settings.readingTheme,
          translatorEnabled: translatorEnabled,
          selectedStart: selectedStart,
          selectedEnd: selectedEnd,
          highlight: highlight,
          otherHighlights: otherHighlights,
          onWordTap: onTap ?? (a, b, c) {},
        ),
      ),
    ),
  );
  final root = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
  return (root.children ?? const []).cast<TextSpan>();
}

/// The spans of a page nothing emphasises, to ask what plain looks like.
Future<List<TextSpan>> _plain(WidgetTester tester) => _paint(tester);

TextSpan _word(List<TextSpan> spans, String word) =>
    spans.firstWhere((span) => span.text == word);

double _wash(TextSpan span) => span.style!.backgroundColor!.a;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService.load(await SharedPreferences.getInstance());
  });

  testWidgets('a word under two runs is set in both of them', (tester) async {
    final plain = _word(await _plain(tester), 'quick').style!;
    final spans = await _paint(
      tester,
      formatRuns: const [
        FormatRun(start: 4, end: 9, bold: true),
        FormatRun(start: 6, end: 15, italic: true),
      ],
    );
    // The run asking for bold stops mid-word, so 'the' is untouched and
    // 'brown' takes only the italic that covers all of it.
    final quick = _word(spans, 'quick').style!;
    expect(quick.fontWeight!.value, greaterThan(plain.fontWeight!.value));
    expect(quick.fontStyle, FontStyle.italic);
    // Emphasis of its own is no reason to wash a word over — that wash
    // belongs to the search hits.
    expect(quick.backgroundColor, isNull);
    final brown = _word(spans, 'brown').style!;
    expect(brown.fontWeight, plain.fontWeight);
    expect(brown.fontStyle, FontStyle.italic);
    expect(brown.backgroundColor, isNull);
    expect(_word(spans, 'the').style, plain);
  });

  testWidgets('inline code, a strike and a link each take their own face', (
    tester,
  ) async {
    final spans = await _paint(
      tester,
      formatRuns: const [
        FormatRun(start: 4, end: 9, code: true),
        FormatRun(start: 10, end: 15, strike: true),
        FormatRun(start: 16, end: 19, link: true),
      ],
    );
    expect(_word(spans, 'quick').style!.fontFamily, codeFontFamily);
    expect(_wash(_word(spans, 'quick')), closeTo(0.12, 0.001));
    expect(_word(spans, 'brown').style!.decoration, TextDecoration.lineThrough);
    expect(_word(spans, 'brown').style!.backgroundColor, isNull);
    expect(_word(spans, 'fox').style!.decoration, TextDecoration.underline);
    expect(_word(spans, 'fox').style!.color, settings.readingTheme.accent);
    expect(_word(spans, 'fox').style!.backgroundColor, isNull);
    expect(_word(spans, 'the').style!.backgroundColor, isNull);
  });

  testWidgets('emphasis outside the painted slice never leaks into it', (
    tester,
  ) async {
    final expected = _word(await _plain(tester), 'brown').style;
    // Only 'brown' is on this page; the runs sit on the words either side.
    final spans = await _paint(
      tester,
      start: _brown.start,
      end: _brown.end,
      formatRuns: const [
        FormatRun(start: 0, end: 9, bold: true),
        FormatRun(start: 16, end: 19, italic: true),
      ],
    );
    expect(spans.map((span) => span.text), ['brown']);
    expect(spans.single.style, expected);
  });

  testWidgets('a run over part of a word sets the whole word', (tester) async {
    final plain = await _plain(tester);
    final spans = await _paint(
      tester,
      formatRuns: const [FormatRun(start: 12, end: 13, bold: true)],
    );
    expect(
      _word(spans, 'brown').style!.fontWeight!.value,
      greaterThan(_word(plain, 'brown').style!.fontWeight!.value),
    );
    expect(_word(spans, 'quick').style, _word(plain, 'quick').style);
  });

  testWidgets('the selected word keeps the document emphasis under its own', (
    tester,
  ) async {
    final spans = await _paint(
      tester,
      formatRuns: const [FormatRun(start: 4, end: 9, italic: true, code: true)],
      selectedStart: _quick.start,
      selectedEnd: _quick.end,
    );
    final selected = _word(spans, 'quick').style!;
    expect(selected.fontStyle, FontStyle.italic);
    expect(selected.fontFamily, codeFontFamily);
    expect(selected.fontWeight, FontWeight.w700);
    expect(selected.color, settings.readingTheme.accent);
    expect(_wash(_word(spans, 'quick')), closeTo(0.16, 0.001));
    // The wash belongs to the chosen word alone.
    expect(_word(spans, 'the').style!.backgroundColor, isNull);
  });

  testWidgets('the hit landed on is stronger than the page\'s other hits', (
    tester,
  ) async {
    final spans = await _paint(
      tester,
      highlight: _brown,
      otherHighlights: const [_fox],
    );
    expect(_wash(_word(spans, 'brown')), closeTo(0.32, 0.001));
    expect(_wash(_word(spans, 'fox')), closeTo(0.14, 0.001));
    expect(_word(spans, 'the').style!.backgroundColor, isNull);
  });

  testWidgets('a hit that only clips a word washes over all of it', (
    tester,
  ) async {
    final spans = await _paint(tester, highlight: (start: 14, end: 17));
    expect(_wash(_word(spans, 'brown')), closeTo(0.32, 0.001));
    expect(_wash(_word(spans, 'fox')), closeTo(0.32, 0.001));
  });

  testWidgets('a tap reports the word as an offset into the whole block', (
    tester,
  ) async {
    ({int start, int end, String word})? tapped;
    // The second page of a block starts partway into its text; the reader has
    // to be told where in the original the word it translates sits.
    final spans = await _paint(
      tester,
      start: _brown.start,
      onTap: (start, end, word) =>
          tapped = (start: start, end: end, word: word),
    );
    expect(spans.map((span) => span.text), ['brown', ' ', 'fox']);
    final recognizer = _word(spans, 'brown').recognizer as TapGestureRecognizer;
    recognizer.onTap!();
    expect(tapped, (start: 10, end: 15, word: 'brown'));
    // The gaps between words carry no tap target.
    expect(_word(spans, ' ').recognizer, isNull);
  });

  testWidgets('with translation off, no word is tappable', (tester) async {
    final spans = await _paint(tester, translatorEnabled: false);
    expect(spans.every((span) => span.recognizer == null), isTrue);
  });
}
