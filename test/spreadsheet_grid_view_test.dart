import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:transreade/services/settings_service.dart';
import 'package:transreade/services/translation_service.dart';
import 'package:transreade/utils/spreadsheet_pages.dart';
import 'package:transreade/utils/xlsx_decode.dart';
import 'package:transreade/widgets/spreadsheet_grid_view.dart';

/// A sheet long enough that only a slice of it can be on screen at once, and
/// whose cells say their own row number — so "what is on screen" is a fact the
/// test can read straight off the text it finds.
List<List<String>> _rows(int count) => [
  ['Header', 'Second'],
  for (var r = 1; r <= count; r++) ['R$r', '${r * 3}'],
];

late SettingsService settings;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = SettingsService.load(prefs);
  });

  Future<void> pump(
    WidgetTester tester,
    GlobalKey<SpreadsheetGridViewState> key, {
    List<SpreadsheetSheet>? sheets,
    SheetCell initialCell = const (sheetIndex: 0, row: 0, column: 0),
    required void Function(({int sheetIndex, int row, int column})) onView,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: SpreadsheetGridView(
              key: key,
              sheets:
                  sheets ?? [SpreadsheetSheet(name: 'Лист1', rows: _rows(400))],
              columnWidths: [
                [80, 60],
                if ((sheets?.length ?? 1) > 1) [80, 60],
              ],
              initialCell: initialCell,
              source: TranslateLanguage.russian,
              target: TranslateLanguage.english,
              translationService: TranslationService(),
              fontSize: 16,
              readingTheme: settings.readingTheme,
              settings: settings,
              translatorEnabled: false,
              onViewChanged: onView,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('only the cells the viewport shows are built', (tester) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(tester, key, onView: (_) {});

    expect(find.text('Header'), findsOneWidget);
    expect(find.text('R5'), findsOneWidget);
    // Row 400 is two screens worth of rows away; building a widget per row of
    // the sheet is what this view exists to avoid.
    expect(find.text('R400'), findsNothing);
    // Empty cells carry nothing to read, so they are not in the tree either.
    expect(find.text(''), findsNothing);
  });

  testWidgets('panning reveals the rows below and reports the corner', (
    tester,
  ) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    final seen = <({int sheetIndex, int row, int column})>[];
    await pump(tester, key, onView: seen.add);

    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -600));
    await tester.pump();

    expect(find.text('R2'), findsNothing);
    expect(find.text('R30'), findsOneWidget);
    expect(seen.last.row, greaterThan(0));
    expect(seen.last.column, 0);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a sheet that fits the window cannot be dragged off its corner', (
    tester,
  ) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(
      tester,
      key,
      sheets: [SpreadsheetSheet(name: 'Лист1', rows: _rows(6))],
      onView: (_) {},
    );

    final before = tester.getTopLeft(find.text('Header'));
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, 240));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Every row is already on screen, so panning has nowhere to take the
    // sheet: it stays in the corner it opened in rather than drifting down
    // into the empty space below it.
    expect(tester.getTopLeft(find.text('Header')), before);
    expect(key.currentState!.topLeftCell().row, 0);
  });

  testWidgets('showing a cell brings it into view', (tester) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(tester, key, onView: (_) {});

    key.currentState!.showCell(
      (sheetIndex: 0, row: 320, column: 0),
      start: 0,
      end: 4,
    );
    await tester.pumpAndSettle();

    expect(find.text('R320'), findsOneWidget);
    expect(find.text('Header'), findsNothing);
  });

  testWidgets('opening wide is the same gesture as opening long', (
    tester,
  ) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(tester, key, onView: (_) {});

    // The sheet is only two columns wide here, so a cell in the second one is
    // already on screen; the view must not have slid away from it.
    key.currentState!.showCell((sheetIndex: 0, row: 4, column: 1));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsOneWidget);
    expect(find.text('R4'), findsOneWidget);
  });

  testWidgets('a pinch zooms the sheet about the fingers', (tester) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(tester, key, onView: (_) {});

    Future<void> pinch({required double from, required double to}) async {
      final a = await tester.createGesture();
      final b = await tester.createGesture();
      await a.down(Offset(200 - from / 2, 300));
      await b.down(Offset(200 + from / 2, 300));
      await a.moveBy(Offset(-(to - from) / 2, 0));
      await b.moveBy(Offset((to - from) / 2, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
    }

    final before = find.byType(Text).evaluate().length;
    double cellSize() {
      // The reader's own text is built as styled runs inside one Text.rich
      // per cell, so the size in play is the span's, not the widget's.
      final span = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SpreadsheetGridView),
              matching: find.byType(Text),
            ),
          )
          .first
          .textSpan! as TextSpan;
      return ((span.children!.first as TextSpan).style!.fontSize)!;
    }

    final headerSize = cellSize();

    // Fingers apart is a zoom in: the text grows and, since only the window
    // the viewport shows is built, fewer of the sheet's cells are in the tree.
    await pinch(from: 100, to: 300);
    expect(cellSize(), greaterThan(headerSize));
    expect(find.byType(Text).evaluate().length, lessThan(before));

    // Fingers together is the way back out, and the sheet holds its place at
    // the natural zoom rather than drifting off to wherever the maths landed.
    await pinch(from: 300, to: 100);
    await pinch(from: 100, to: 33);
    expect(cellSize(), lessThan(headerSize));
    expect(find.byType(Text).evaluate().length, greaterThan(before));
  });

  testWidgets('a second sheet is one tab away', (tester) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    final seen = <({int sheetIndex, int row, int column})>[];
    await pump(
      tester,
      key,
      sheets: [
        SpreadsheetSheet(name: 'Первый', rows: _rows(20)),
        SpreadsheetSheet(name: 'Второй', rows: _rows(20)),
      ],
      onView: seen.add,
    );

    expect(find.text('R1'), findsWidgets);
    await tester.tap(find.text('Второй'));
    await tester.pumpAndSettle();

    expect(seen.last.sheetIndex, 1);
    // Each sheet keeps its own place: the second one opens at its top, not
    // wherever the first happened to be.
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('a remembered sheet is remembered where it was left', (
    tester,
  ) async {
    final key = GlobalKey<SpreadsheetGridViewState>();
    await pump(
      tester,
      key,
      sheets: [
        SpreadsheetSheet(name: 'Первый', rows: _rows(20)),
        SpreadsheetSheet(name: 'Второй', rows: _rows(20)),
      ],
      onView: (_) {},
    );

    key.currentState!.showCell((sheetIndex: 0, row: 18, column: 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Второй'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Первый'));
    await tester.pumpAndSettle();

    expect(find.text('R18'), findsOneWidget);
  });
}
