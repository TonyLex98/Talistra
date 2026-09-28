import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/widgets/paged_reflow_view.dart';
import 'package:transreade/widgets/reflow_source.dart';

late SettingsService settings;
final _key = GlobalKey<PagedReflowViewState>();

String _paragraph(int page, int n) =>
    'Page $page paragraph $n. ${'Words that fill the line up and wrap. ' * 5}';

/// Pages of a few long paragraphs each: every page is several screens.
List<List<ReflowBlock>> _book(int pages) => [
  for (var p = 1; p <= pages; p++)
    [for (var n = 1; n <= 4; n++) ReflowBlock.paragraph(_paragraph(p, n))],
];

/// A source whose page 1 changes after it was first shown — the way a page
/// read by OCR does.
class _ChangingSource extends TextBookSource {
  _ChangingSource(super.pages);

  void replace(int page, List<ReflowBlock> blocks) {
    pages[page] = blocks;
    onPageChanged?.call(page);
  }
}

Future<List<int>> _pump(
  WidgetTester tester,
  ReflowSource source, {
  int initialPage = 1,
  double initialFraction = 0,
}) async {
  final reported = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: PagedReflowView(
            key: _key,
            source: source,
            initialPage: initialPage,
            initialFraction: initialFraction,
            sourceLanguage: TranslateLanguage.english,
            targetLanguage: TranslateLanguage.russian,
            translationService: TranslationService(),
            fontSize: 18,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: false,
            onPageChanged: reported.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return reported;
}

/// The footer: "page · sub-page/sub-pages".
String _footer(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((t) => RegExp(r'^\d+ · \d+/\d+$').hasMatch(t));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService.load(await SharedPreferences.getInstance());
  });

  testWidgets('a sideways swipe turns the page — past the selection layer', (
    tester,
  ) async {
    await _pump(tester, TextBookSource(_book(3)));
    expect(_footer(tester), startsWith('1 · 1/'));
    await tester.timedDrag(
      find.byType(PagedReflowView),
      const Offset(-250, 0),
      const Duration(milliseconds: 250),
    );
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 2/'));
    await tester.timedDrag(
      find.byType(PagedReflowView),
      const Offset(250, 0),
      const Duration(milliseconds: 250),
    );
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 1/'));
  });

  testWidgets('an upward swipe turns it too', (tester) async {
    await _pump(tester, TextBookSource(_book(3)));
    await tester.timedDrag(
      find.byType(PagedReflowView),
      const Offset(0, -350),
      const Duration(milliseconds: 250),
    );
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 2/'));
  });

  testWidgets('taps at the edges turn forward and back', (tester) async {
    await _pump(tester, TextBookSource(_book(3)));
    await tester.tapAt(const Offset(395, 300));
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 2/'));
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 1/'));
  });

  testWidgets('turning past a page\'s last part reports the next page', (
    tester,
  ) async {
    final reported = await _pump(tester, TextBookSource(_book(3)));
    final parts = int.parse(_footer(tester).split('/').last);
    for (var i = 0; i < parts; i++) {
      await tester.tapAt(const Offset(395, 300));
      await tester.pumpAndSettle();
    }
    expect(_footer(tester), startsWith('2 · 1/'));
    expect(reported, [2]);
    // And back again lands on the last part of page 1, not its top.
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();
    expect(_footer(tester), '1 · $parts/$parts');
  });

  testWidgets('a page opened part-way lands part-way into it', (tester) async {
    await _pump(tester, TextBookSource(_book(3)), initialPage: 2);
    final parts = int.parse(_footer(tester).split('/').last);
    // Opened afresh — the way switching over from the page view opens it.
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      TextBookSource(_book(3)),
      initialPage: 2,
      initialFraction: 0.99,
    );
    expect(_footer(tester), '2 · $parts/$parts');
  });

  testWidgets('a page whose text arrives later is laid out again', (
    tester,
  ) async {
    final source = _ChangingSource(_book(2));
    await _pump(tester, source);
    expect(
      find.textContaining('Page 1 paragraph 1', findRichText: true),
      findsWidgets,
    );
    source.replace(0, [const ReflowBlock.paragraph('Read by OCR.')]);
    await tester.pumpAndSettle();
    expect(_footer(tester), '1 · 1/1');
    expect(
      find.textContaining('Read by OCR.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a jump lands on its page and says so', (tester) async {
    final reported = await _pump(tester, TextBookSource(_book(5)));
    _key.currentState!.jumpToPage(4);
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('4 · 1/'));
    expect(reported, [4]);
    expect(_key.currentState!.currentPage, 4);
  });

  testWidgets('the first page gives a steady third of a drag at the edge', (
    tester,
  ) async {
    await _pump(tester, TextBookSource(_book(3)));
    final text = find.textContaining('Page 1 paragraph 1', findRichText: true);
    final before = tester.getTopLeft(text.first);
    final gesture = await tester.startGesture(const Offset(200, 300));
    // Right, at the start of the book: there is no page to turn back to.
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final moved = tester.getTopLeft(text.first).dx - before.dx;
    // 200 px of finger, resisted to about 30% — not shrinking away to
    // nothing as more events arrive.
    expect(moved, inInclusiveRange(40, 80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 1/'));
  });

  testWidgets('a sideways swipe never moves the page up or down', (
    tester,
  ) async {
    await _pump(tester, TextBookSource(_book(3)));
    final text = find.textContaining('Page 1 paragraph 1', findRichText: true);
    final before = tester.getTopLeft(text.first);
    final gesture = await tester.startGesture(const Offset(300, 300));
    // A wobbly finger: mostly left, with the odd twitch up and down.
    const twitches = [1.0, -2.0, 1.5, -1.0, 2.0, -1.5, 1.0, -2.0];
    for (var i = 0; i < twitches.length * 3; i++) {
      await gesture.moveBy(Offset(-12, twitches[i % twitches.length]));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(text.first).dy, closeTo(before.dy, 0.01));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_footer(tester), startsWith('1 · 2/'));
  });
}
