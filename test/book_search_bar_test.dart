import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/l10n/gen/app_localizations.dart';
import 'package:transreade/utils/text_search.dart';
import 'package:transreade/widgets/book_search_bar.dart';

SearchMatch _match(int page) => SearchMatch(
  pageIndex: page,
  blockIndex: 0,
  matchStart: 0,
  matchEnd: 3,
  snippet: 'snippet on page $page',
  pageOccurrenceIndex: 0,
);

/// Stands in for the reader's search: the test decides when matches arrive,
/// so a book whose index is still being built can be replayed exactly.
class _FakeSearch {
  void Function(List<SearchMatch>)? _onBatch;
  void Function()? _onDone;

  final List<SearchMatch> landed = [];

  Future<void> run(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    _onBatch = onBatch;
    _onDone = onDone;
  }

  void emit(List<SearchMatch> matches) => _onBatch?.call(matches);

  void finish() => _onDone?.call();
}

Future<void> _open(
  WidgetTester tester,
  _FakeSearch search, {
  required int readingPage,
  int Function()? reading,
}) async {
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
      home: Scaffold(
        body: BookSearchBar(
          search: search.run,
          readingPage: reading ?? () => readingPage,
          onSelect: (match, all) => search.landed.add(match),
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.enterText(find.byType(TextField), 'ищи');
  // The field debounces typing; this is the search actually starting.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a search opens on the match the reader would reach next', (
    tester,
  ) async {
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 4);
    search.emit([_match(1), _match(4), _match(7)]);
    await tester.pump();

    expect(search.landed.map((m) => m.pageIndex), [4]);
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('a match on the page being read beats one found earlier', (
    tester,
  ) async {
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 6);
    // Deliberately out of page order, the way a PDF index streams pages in.
    search.emit([_match(9), _match(2), _match(6)]);
    await tester.pump();

    expect(search.landed.map((m) => m.pageIndex), [6]);
  });

  testWidgets('a search with nothing ahead of the reader wraps to the start', (
    tester,
  ) async {
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 8);
    search.emit([_match(5), _match(1)]);
    await tester.pump();

    expect(search.landed.map((m) => m.pageIndex), [1]);
  });

  testWidgets('matches still arriving keep landing closer, never further', (
    tester,
  ) async {
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 4);
    search.emit([_match(20)]);
    await tester.pump();
    expect(search.landed.map((m) => m.pageIndex), [20]);

    search.emit([_match(9)]);
    await tester.pump();
    expect(search.landed.map((m) => m.pageIndex), [20, 9]);

    search.emit([_match(5)]);
    await tester.pump();
    expect(search.landed.last.pageIndex, 5);
  });

  testWidgets('stepping through matches stops the search moving on its own', (
    tester,
  ) async {
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 4);
    search.emit([_match(5), _match(9)]);
    await tester.pump();
    expect(search.landed.last.pageIndex, 5);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    expect(search.landed.last.pageIndex, 9);

    // The rest of the book turns up: the reader is on a match of their own
    // choosing now, so nothing moves them.
    search.emit([_match(4)]);
    await tester.pump();
    expect(search.landed.last.pageIndex, 9);
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('refining the query still searches from where the reader was', (
    tester,
  ) async {
    // The reader is where the last landing put them, not where they were
    // reading — a query refined one letter at a time must not start from
    // the hit the shorter one happened to open on.
    var page = 4;
    final search = _FakeSearch();
    await _open(tester, search, readingPage: 4, reading: () => page);
    search.emit([_match(2), _match(30)]);
    await tester.pump();
    expect(search.landed.last.pageIndex, 30);
    page = 30;

    await tester.enterText(find.byType(TextField), 'ищите');
    await tester.pump(const Duration(milliseconds: 400));
    search.emit([_match(2), _match(10), _match(40)]);
    await tester.pump();
    expect(search.landed.last.pageIndex, 10);
  });
}
