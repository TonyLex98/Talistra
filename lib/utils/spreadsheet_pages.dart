import 'package:flutter/painting.dart';

import 'reading_text_style.dart';
import 'xlsx_decode.dart';

/// Horizontal padding inside a cell, and the height of one row of the grid.
///
/// Both the paginator (how many rows fit a page) and the view (where each
/// row is drawn) read these, so a page never claims more rows than the view
/// can actually show.
const double spreadsheetCellPadding = 10;

/// The sheet's name, shown above every page of it so a reader flipping
/// through a flattened workbook always knows where they are.
const double spreadsheetCaptionHeight = 26;

/// The grid's own margins, subtracted from the reader's height before
/// counting how many rows fit a page.
const double spreadsheetPagePadding = 20;

double spreadsheetRowHeight(double fontSize, {double textScale = 1.0}) =>
    fontSize * textScale * 1.55 + 12;

/// One cell of a sheet, addressed the way the sheet itself addresses it.
///
/// The paginated and the original views name the same cell differently — a
/// page knows its cells by reading-order block index, the grid by row and
/// column — so both sides speak this, and a search hit found through one
/// view can be shown by the other.
typedef SheetCell = ({int sheetIndex, int row, int column});

/// A cell plus the run of characters inside it to wash over.
typedef SheetCellRange = ({
  int sheetIndex,
  int row,
  int column,
  int start,
  int end,
});

/// How many columns a sheet uses: the length of its longest row.
int sheetColumnCount(SpreadsheetSheet sheet) {
  var columnCount = 0;
  for (final row in sheet.rows) {
    if (row.length > columnCount) columnCount = row.length;
  }
  return columnCount;
}

/// The width of each column's *text*, so a renderer can lay the whole sheet
/// out without measuring it cell by cell. A cell's box is this plus
/// [spreadsheetCellPadding] on each side, which the view adds.
///
/// [style] is the style the sheet's data cells are painted in and [boldStyle]
/// the one its header line is painted in; measuring with anything else sizes
/// columns that the rendered text then does not fit into.
///
/// Only a bounded sample of the sheet's rows is measured: a column's width
/// is settled by its header and a handful of typical cells, and measuring
/// every one of a hundred thousand rows to find the single widest would cost
/// more than the whole rest of opening the file.
List<double> measureColumnWidths(
  SpreadsheetSheet sheet, {
  required TextStyle style,
  required TextStyle boldStyle,
  TextScaler textScaler = TextScaler.noScaling,
  double minColumnWidth = 44,
  double maxColumnWidth = 320,
  int samples = 60,
}) {
  final columnCount = sheetColumnCount(sheet);
  if (columnCount == 0) return const [];

  final widths = List<double>.filled(columnCount, minColumnWidth);
  // Laid out with no width constraint, so a column is measured as the single
  // line the cell shows it as rather than as a wrapped paragraph.
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  );
  void measure(String text, int column, TextStyle style) {
    if (text.isEmpty || widths[column] >= maxColumnWidth) return;
    painter
      // Measured as the runs the cell is painted in, not as one string: a
      // word-by-word split loses the kerning across its seams and comes out
      // wider, and a column sized to the whole-string measurement truncates
      // the very cell that set its width.
      ..text = TextSpan(
        children: [
          for (final run in readingTextRuns(text))
            TextSpan(text: text.substring(run.start, run.end), style: style),
        ],
      )
      ..layout();
    final needed = painter.width.ceilToDouble().clamp(0.0, maxColumnWidth);
    if (needed > widths[column]) widths[column] = needed;
  }

  // The header line is always measured: it is the widest text in most real
  // tables, and missing it clips the one row that names every column.
  if (sheet.rows.isNotEmpty) {
    for (var c = 0; c < sheet.rows.first.length; c++) {
      measure(sheet.rows.first[c], c, boldStyle);
    }
  }
  final stride = sheet.rows.length <= samples
      ? 1
      : (sheet.rows.length / samples).ceil();
  for (var r = 0; r < sheet.rows.length; r++) {
    if (r != 0 && r % stride != 0) continue;
    final row = sheet.rows[r];
    for (var c = 0; c < row.length; c++) {
      measure(row[c], c, style);
    }
  }
  return widths;
}

/// One page of a workbook: a run of one sheet's rows, sliced to a run of its
/// columns.
class SpreadsheetPage {
  SpreadsheetPage({
    required this.sheetIndex,
    required this.sheetName,
    required this.firstRow,
    required this.firstColumn,
    required this.rows,
    required this.headerRowCount,
    required this.repeatsHeader,
  });

  final int sheetIndex;
  final String sheetName;

  /// Index of the first data row of this page in the sheet, so going back to
  /// a page later lands on the same place in the file.
  final int firstRow;

  /// Index of the first column this page shows. A sheet too wide for the
  /// screen is cut into column groups, the way a printer would.
  final int firstColumn;

  /// The page's rows, header line first when one is repeated here. Every row
  /// has exactly [columnCount] cells.
  final List<List<String>> rows;

  /// How many leading rows of [rows] are the sheet's header, repeated so a
  /// page in the middle of a long table still says what its columns are.
  final int headerRowCount;

  /// Whether this page's first row is that repeated header rather than one of
  /// the page's own rows of data — which is what tells the two apart again
  /// later: without it a hit on a repeated header would be read as a hit on
  /// the sheet's second line.
  final bool repeatsHeader;

  int get columnCount => rows.isEmpty ? 0 : rows.first.length;

  /// Every cell on the page, left to right and top to bottom.
  ///
  /// This is the block list the shared search runs over, so a match's block
  /// index names the exact cell it fell in and the view can wash over it.
  late final List<String> blocks = [for (final row in rows) ...row];

  /// The row of the sheet that this page's [displayedRow]-th row was taken
  /// from.
  int sheetRowOf(int displayedRow) =>
      repeatsHeader && displayedRow == 0
      ? 0
      : firstRow + displayedRow - (repeatsHeader ? 1 : 0);

  /// The sheet cell the [blockIndex]-th block of this page came from, so the
  /// original grid view can show a hit the paginated one found.
  SheetCell cellOf(int blockIndex) => (
    sheetIndex: sheetIndex,
    row: sheetRowOf(blockIndex ~/ columnCount),
    column: firstColumn + blockIndex % columnCount,
  );
}

/// The page that shows [row], [column] of a sheet, as its zero-based index —
/// or null when the workbook has no page for that cell (an empty sheet).
///
/// Used to keep the page counter honest while the reader pans through the
/// original grid: the grid's position is a cell, and the number the reader
/// sees has to be the page that cell would be read on.
int? findPageForCell(
  List<SpreadsheetPage> pages, {
  required int sheetIndex,
  required int row,
  required int column,
}) {
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    if (page.sheetIndex != sheetIndex) continue;
    if (column < page.firstColumn) continue;
    if (column >= page.firstColumn + page.columnCount) continue;
    final dataRows = page.rows.length - (page.repeatsHeader ? 1 : 0);
    if (row >= page.firstRow && row < page.firstRow + dataRows) return i;
  }
  return null;
}

/// Turns the workbook's sheets into one continuous run of pages.
///
/// Every sheet is folded into the same sequence rather than kept behind tabs,
/// so a workbook is read — and searched, counted, translated and bookmarked
/// by page number — exactly like any other book in the app.
///
/// [columnWidths] is the measured width of each column of each sheet, in the
/// same order as [sheets]; [pageWidth] is what the columns have to fit into,
/// padding included.
List<SpreadsheetPage> buildSpreadsheetPages({
  required List<SpreadsheetSheet> sheets,
  required List<List<double>> columnWidths,
  required double pageWidth,
  required int rowsPerPage,
  double cellPadding = 0,
  bool repeatHeader = true,
}) {
  final pages = <SpreadsheetPage>[];
  for (var s = 0; s < sheets.length; s++) {
    final sheet = sheets[s];
    if (sheet.rows.isEmpty || rowsPerPage < 1) continue;
    final widths = columnWidths[s];
    for (final group in _columnGroups(
      widths,
      pageWidth: pageWidth,
      cellPadding: cellPadding,
    )) {
      // A sheet's first line is read as its header: it says what the columns
      // are, so it is set in the header style wherever it shows, and repeated
      // at the top of every page after the first.
      final hasHeader = repeatHeader && sheet.rows.length > 1;
      final header =
          hasHeader && rowsPerPage > 1 && sheet.rows.length > rowsPerPage
          ? _slice(sheet.rows.first, group)
          : null;
      // A page always holds the same number of rows, so on the pages after
      // the first the repeated header takes one of those slots rather than
      // pushing the page over height. The first page needs no repeat: its
      // first row is the header already.
      final bodyRows = header == null ? rowsPerPage : rowsPerPage - 1;
      var first = 0;
      while (first < sheet.rows.length) {
        final count = first == 0 ? rowsPerPage : bodyRows;
        final rows = <List<String>>[];
        final repeatsHeader = header != null && first > 0;
        if (repeatsHeader) rows.add(List.of(header));
        for (
          var r = first;
          r < (first + count).clamp(0, sheet.rows.length);
          r++
        ) {
          rows.add(_slice(sheet.rows[r], group));
        }
        pages.add(
          SpreadsheetPage(
            sheetIndex: s,
            sheetName: sheet.name,
            firstRow: first,
            firstColumn: group.first,
            rows: rows,
            headerRowCount: hasHeader ? 1 : 0,
            repeatsHeader: repeatsHeader,
          ),
        );
        first += count;
      }
    }
  }
  return pages;
}

/// The columns of one page: a contiguous run, `first` inclusive and `last`
/// exclusive.
typedef _ColumnGroup = ({int first, int last});

/// Cuts a sheet's columns into groups that fit the page, left to right.
///
/// A column wider than the page still gets a group of its own — clipping it
/// beats dropping the data.
List<_ColumnGroup> _columnGroups(
  List<double> widths, {
  required double pageWidth,
  required double cellPadding,
}) {
  final groups = <_ColumnGroup>[];
  var first = 0;
  var used = 0.0;
  for (var c = 0; c < widths.length; c++) {
    final width = widths[c] + cellPadding;
    if (c > first && used + width > pageWidth) {
      groups.add((first: first, last: c));
      first = c;
      used = 0;
    }
    used += width;
  }
  groups.add((first: first, last: widths.length));
  return groups;
}

List<String> _slice(List<String> row, _ColumnGroup group) => [
  for (var c = group.first; c < group.last; c++) c < row.length ? row[c] : '',
];
