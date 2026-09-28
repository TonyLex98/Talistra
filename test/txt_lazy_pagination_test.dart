import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/widgets/translatable_text.dart';
import 'package:transreade/widgets/paged_reflow_view.dart';
import 'package:transreade/widgets/reflow_source.dart';

late SettingsService settings;

/// The one view under test, kept across [tester.pumpWidget] calls so the same
/// state sees a resize rather than being rebuilt from scratch.
final _key = GlobalKey<PagedReflowViewState>();

/// A book of [count] source pages, one paragraph each, each saying which page
/// it is — so a test can tell where the reader ended up.
List<List<ReflowBlock>> _book(int count) => [
  for (var i = 0; i < count; i++)
    <ReflowBlock>[
      ReflowBlock.paragraph(
        'Page ${i + 1}: '
                'Words fill the page up so that a paragraph of this book takes a '
                'screenful of its own and the reader has to have laid it out to show '
                'it at all. ' *
            6,
      ),
    ],
];

Future<void> _pump(
  WidgetTester tester,
  List<List<ReflowBlock>> pages, {
  int initialPage = 1,
  double height = 600,
  double fontSize = 18,
  void Function(int page)? onPage,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: height,
          child: PagedReflowView(
            key: _key,
            source: TextBookSource(pages),
            initialPage: initialPage,
            sourceLanguage: TranslateLanguage.english,
            targetLanguage: TranslateLanguage.russian,
            translationService: TranslationService(),
            fontSize: fontSize,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: false,
            onPageChanged: onPage ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

/// Whether the text of source page [page] (1-based) is on screen.
bool _isShown(WidgetTester tester, int page) => find
    .byWidgetPredicate(
      (widget) =>
          widget is TranslatableText &&
          widget.text.startsWith('Page $page: ') &&
          widget.end != null &&
          widget.end! > widget.start,
    )
    .evaluate()
    .isNotEmpty;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService.load(prefs);
  });

  testWidgets('the book is laid out a few pages at a time', (tester) async {
    final pages = _book(400);
    await _pump(tester, pages);
    await tester.pump();
    expect(_isShown(tester, 1), isTrue);
    expect(_isShown(tester, 400), isFalse);
    // The rest arrives on its own, and the reader can go to the end of it.
    await tester.pumpAndSettle();
    _key.currentState!.jumpToPage(400);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 400), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a jump to a page the book has not reached yet waits for it', (
    tester,
  ) async {
    await _pump(tester, _book(400));
    await tester.pump();
    _key.currentState!.jumpToPage(390);
    // The layout is nowhere near page 390. Asking the page view to move there
    // outright would stop it on the last page it happens to have built and
    // drop the jump on the floor — so the jump has to wait to be affordable.
    expect(_isShown(tester, 390), isFalse);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 390), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a book deep in it lands on the saved page', (
    tester,
  ) async {
    await _pump(tester, _book(400), initialPage: 330);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 330), isTrue);
  });

  testWidgets('a book reopened deep in it is not reported anywhere else', (
    tester,
  ) async {
    // A page view only knows the length of the part of the book it has
    // measured, so a jump past that measures the move against the extent it
    // had before it and reports the last page it had felt its way to. The
    // reader is looking at the page they left; a report that says otherwise
    // must not be taken as where they are, or the book reopens pages away
    // from where it was put down.
    final reported = <int>[];
    await _pump(tester, _book(620), initialPage: 500, onPage: reported.add);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 500), isTrue);
    expect(reported.where((page) => page != 500), isEmpty);
    // A page the reader turns themselves is their own doing, and has to reach
    // the reader — the suppression above is only for the jump's own report.
    // A swipe turns a sub-page; the book's page changes once the last of
    // page 500's sub-pages has been turned.
    final told = reported.length;
    for (var i = 0; i < 6 && reported.length == told; i++) {
      await tester.drag(find.byType(PagedReflowView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }
    expect(reported.length, greaterThan(told));
    expect(reported.last, 501);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resize keeps a jump that is still waiting', (tester) async {
    final pages = _book(620);
    await _pump(tester, pages, height: 400);
    await tester.pump();
    _key.currentState!.jumpToPage(500);
    // Closing the dialog that asked for the page gives the column back its
    // height: every split has to be done again, and the page on the way to
    // which that happens has to survive the restart.
    await _pump(tester, pages, height: 600);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 500), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resize keeps the page being read', (tester) async {
    final pages = _book(400);
    await _pump(tester, pages);
    await tester.pumpAndSettle();
    _key.currentState!.jumpToPage(300);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 300), isTrue);
    // The keyboard: a shorter column, so every split has to be done again.
    await _pump(tester, pages, height: 320);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 300), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a search hit beyond the laid out pages waits to highlight', (
    tester,
  ) async {
    await _pump(tester, _book(400));
    await tester.pump();
    final text = 'Page 380: ';
    _key.currentState!.showSearchHighlight(380, 0, 0, text.length);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 380), isTrue);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TranslatableText &&
            widget.text.startsWith(text) &&
            widget.highlight != null,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a book with nothing in it asks for nothing', (tester) async {
    final empty = [
      for (var i = 0; i < 20; i++) <ReflowBlock>[ReflowBlock.paragraph('')],
    ];
    await _pump(tester, empty);
    _key.currentState!.jumpToPage(10);
    // A jump that can never be satisfied has to stop asking, or the reader
    // burns frames chasing it forever.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bigger font keeps the page being read', (tester) async {
    final pages = _book(400);
    await _pump(tester, pages);
    await tester.pumpAndSettle();
    _key.currentState!.jumpToPage(250);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 250), isTrue);
    await _pump(tester, pages, fontSize: 26);
    await tester.pumpAndSettle();
    expect(_isShown(tester, 250), isTrue);
    expect(tester.takeException(), isNull);
  });
}
