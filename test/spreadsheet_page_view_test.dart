import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/spreadsheet_pages.dart';
import 'package:transreade/utils/xlsx_decode.dart';
import 'package:transreade/widgets/spreadsheet_page_view.dart';

/// The rows of a sheet that fits two to a page, so the second page's cells
/// are provably not on screen until the reader turns to them.
const _rows = [
  ['Товар', 'Цена'],
  ['Ручка', '12'],
  ['Тетрадь', '34'],
  ['Ластик', '56'],
];

/// Read by [_Harness], which builds the view the way the reader screen does.
late SettingsService settings;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService.load(prefs);
  });

  List<SpreadsheetPage> pages({int rowsPerPage = 2}) => buildSpreadsheetPages(
    sheets: [SpreadsheetSheet(name: 'Лист1', rows: _rows)],
    columnWidths: [
      [80, 60],
    ],
    pageWidth: 1000,
    rowsPerPage: rowsPerPage,
  );

  Future<void> pump(
    WidgetTester tester,
    List<SpreadsheetPage> pages,
    GlobalKey<SpreadsheetPageViewState> key, {
    required void Function(int) onPageChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: SpreadsheetPageView(
              key: key,
              pages: pages,
              columnWidths: [
                [80, 60],
              ],
              initialPage: 1,
              source: TranslateLanguage.russian,
              target: TranslateLanguage.english,
              translationService: TranslationService(),
              fontSize: 16,
              readingTheme: settings.readingTheme,
              settings: settings,
              translatorEnabled: false,
              onPageChanged: onPageChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows one page of the table at a time', (tester) async {
    final key = GlobalKey<SpreadsheetPageViewState>();
    await pump(tester, pages(), key, onPageChanged: (_) {});

    expect(find.text('Товар'), findsOneWidget);
    expect(find.text('Ручка'), findsOneWidget);
    expect(find.text('Тетрадь'), findsNothing);
    expect(find.text('Лист1'), findsOneWidget);
  });

  testWidgets('a swipe turns the page and reports where the reader is', (
    tester,
  ) async {
    final key = GlobalKey<SpreadsheetPageViewState>();
    final seen = <int>[];
    await pump(tester, pages(), key, onPageChanged: seen.add);

    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.text('Тетрадь'), findsOneWidget);
    expect(find.text('Ручка'), findsNothing);
    expect(seen, [2]);
  });

  testWidgets('jumping to a page shows it', (tester) async {
    final key = GlobalKey<SpreadsheetPageViewState>();
    await pump(tester, pages(), key, onPageChanged: (_) {});

    key.currentState!.jumpToPage(3);
    await tester.pumpAndSettle();

    expect(find.text('Ластик'), findsOneWidget);
  });

  testWidgets('a search hit jumps to its page', (tester) async {
    final key = GlobalKey<SpreadsheetPageViewState>();
    await pump(tester, pages(), key, onPageChanged: (_) {});

    key.currentState!.showSearchHighlight(2, 3, 0, 6);
    await tester.pumpAndSettle();

    // Page 2's fourth cell is "Тетрадь", the match the reader landed on.
    expect(find.text('Тетрадь'), findsOneWidget);
  });

  testWidgets('a wider sheet is cut into column groups', (tester) async {
    final wide = buildSpreadsheetPages(
      sheets: [
        SpreadsheetSheet(
          name: 'Широкий',
          rows: [
            ['A', 'B', 'C'],
            ['1', '2', '3'],
          ],
        ),
      ],
      columnWidths: [
        [150, 150, 150],
      ],
      pageWidth: 340,
      rowsPerPage: 10,
    );
    expect(wide.map((p) => p.firstColumn), [0, 2]);

    final key = GlobalKey<SpreadsheetPageViewState>();
    await pump(tester, wide, key, onPageChanged: (_) {});
    expect(find.text('C'), findsNothing);

    key.currentState!.jumpToPage(2);
    await tester.pumpAndSettle();
    expect(find.text('C'), findsOneWidget);
    expect(find.text('A'), findsNothing);
  });

  testWidgets('re-paginating to a shorter book lands inside it', (
    tester,
  ) async {
    final seen = <int>[];
    await tester.pumpWidget(wrap(_Harness(pages: pages(), onPage: seen.add)));
    await tester.pumpAndSettle();

    final harness = tester.state<_HarnessState>(find.byType(_Harness));
    harness.viewKey.currentState!.jumpToPage(3);
    await tester.pumpAndSettle();
    expect(seen.last, 3);

    // A larger text size leaves fewer rows per page, so the book the reader is
    // standing in gets shorter under it. Correcting that must wait for the
    // frame to end — jumping during the build reports the new page back to the
    // reader while it is still building, which is illegal.
    await tester.pumpWidget(
      wrap(_Harness(pages: pages(rowsPerPage: 4), onPage: seen.add)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ластик'), findsOneWidget);
  });
}

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
);

/// The reader screen's own arrangement: a parent that records the current page
/// by calling setState from the view's callback.
class _Harness extends StatefulWidget {
  const _Harness({required this.pages, required this.onPage});

  final List<SpreadsheetPage> pages;
  final ValueChanged<int> onPage;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final viewKey = GlobalKey<SpreadsheetPageViewState>();

  @override
  Widget build(BuildContext context) {
    return SpreadsheetPageView(
      key: viewKey,
      pages: widget.pages,
      columnWidths: const [
        [80, 60],
      ],
      initialPage: 1,
      source: TranslateLanguage.russian,
      target: TranslateLanguage.english,
      translationService: TranslationService(),
      fontSize: 16,
      readingTheme: settings.readingTheme,
      settings: settings,
      translatorEnabled: false,
      onPageChanged: (page) {
        setState(() {});
        widget.onPage(page);
      },
    );
  }
}
