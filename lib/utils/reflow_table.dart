import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'reflow_builder.dart';

/// One cell of a table as its source wrote it: its text and the emphasis in
/// it, offsets into that text.
typedef TableCellText = ({String text, List<FormatRun> runs});

/// What goes between two cells of a row in a table's [ReflowBlock.text] —
/// what a copied or searched table reads as.
const String tableCellSeparator = ' | ';

/// A table as one block: its rows one to a line, their cells between bars,
/// with every cell's place in that text kept so the reader can draw them in
/// a grid. The first row is the header and is set bold, unless [header] is
/// false.
///
/// Rows shorter than the widest one are padded with empty cells, so every
/// row has a cell for every column.
ReflowBlock reflowTable(
  List<List<TableCellText>> rows, {
  List<TextAlign> alignments = const [],
  bool header = true,
  int quoteDepth = 0,
  int indent = 0,
  double? gapAbove,
}) {
  final columns = rows.fold<int>(0, (n, row) => math.max(n, row.length));
  final text = StringBuffer();
  final runs = <FormatRun>[];
  final cells = <List<({int start, int end})>>[];
  for (var r = 0; r < rows.length; r++) {
    if (r > 0) text.write('\n');
    final row = <({int start, int end})>[];
    for (var c = 0; c < columns; c++) {
      if (c > 0) text.write(tableCellSeparator);
      final cell = c < rows[r].length
          ? rows[r][c]
          : (text: '', runs: const <FormatRun>[]);
      final start = text.length;
      text.write(cell.text);
      row.add((start: start, end: text.length));
      for (final run in cell.runs) {
        runs.add(run.shifted(start));
      }
      if (header && r == 0 && cell.text.isNotEmpty) {
        runs.add(FormatRun(start: start, end: text.length, bold: true));
      }
    }
    cells.add(row);
  }
  runs.sort((a, b) => a.start.compareTo(b.start));
  return ReflowBlock.paragraph(
    text.toString(),
    formatRuns: runs,
    quoteDepth: quoteDepth,
    indent: indent,
    gapAbove: gapAbove,
    tableCells: cells,
    tableAlignments: alignments,
    tableHeader: header && rows.length > 1,
  );
}

/// The cells of [table] as their text and emphasis again — what
/// [reflowTable] made it from, header bold included.
List<List<TableCellText>> tableCellTexts(ReflowBlock table) => [
  for (final row in table.tableCells!)
    [
      for (final cell in row)
        (
          text: table.text.substring(cell.start, cell.end),
          runs: [
            for (final run in table.formatRuns)
              if (run.start < cell.end && run.end > cell.start)
                FormatRun(
                  start: math.max(run.start, cell.start) - cell.start,
                  end: math.min(run.end, cell.end) - cell.start,
                  bold: run.bold,
                  italic: run.italic,
                  code: run.code,
                  strike: run.strike,
                  link: run.link,
                ),
          ],
        ),
    ],
];

/// [table] cut between its rows into tables of about [maxChars] characters
/// each, every one after the first with the header again on top — how a
/// book too long to lay out at once is cut into its synthetic pages.
List<ReflowBlock> splitReflowTable(ReflowBlock table, int maxChars) {
  if (table.text.length <= maxChars) return [table];
  final rows = tableCellTexts(table);
  final header = table.tableHeader ? rows.first : null;
  int charsOf(List<TableCellText> row) =>
      row.fold<int>(row.length * 3, (n, cell) => n + cell.text.length);
  final pieces = <ReflowBlock>[];
  var current = [?header];
  var chars = 0;
  void close() {
    final first = pieces.isEmpty;
    pieces.add(
      reflowTable(
        current,
        alignments: table.tableAlignments ?? const [],
        // The header's bold is already among its cells' own runs.
        header: false,
        quoteDepth: table.quoteDepth,
        indent: table.indent,
        // A continuation is the same table on the next page.
        gapAbove: first ? table.gapAbove : 0,
      ).withTableHeader(header != null),
    );
    current = [?header];
    chars = 0;
  }

  for (var r = header != null ? 1 : 0; r < rows.length; r++) {
    current.add(rows[r]);
    chars += charsOf(rows[r]);
    if (chars >= maxChars && r + 1 < rows.length) close();
  }
  close();
  return pieces;
}

extension on ReflowBlock {
  /// The same table, its first row marked as its header or not.
  ReflowBlock withTableHeader(bool header) => ReflowBlock.paragraph(
    text,
    formatRuns: formatRuns,
    quoteDepth: quoteDepth,
    indent: indent,
    gapAbove: gapAbove,
    tableCells: tableCells,
    tableAlignments: tableAlignments,
    tableHeader: header,
  );
}

/// The geometry of a table in a reading column: how wide each column is and
/// how tall each row, worked out once and used by both the paginator (to
/// know how many rows fit on a page) and the painter (to draw them there) —
/// so a table is never measured one way and drawn another.
class ReflowTableLayout {
  const ReflowTableLayout({
    required this.columnWidths,
    required this.rowHeights,
  });

  /// Each column's width, its left rule and its cell padding included.
  final List<double> columnWidths;

  /// Each row's height, its bottom rule included.
  final List<double> rowHeights;

  /// The whole table's width, the rule down its right edge included.
  double get width => columnWidths.fold<double>(0, (a, b) => a + b) + tableRule;

  /// The height of rows `[from, to)` drawn as one piece: the rule along
  /// their top, the rows, and — for a piece that isn't the table's start —
  /// the header row again above them.
  double heightOf(int from, int to, {required bool repeatHeader}) {
    var height = tableRule;
    if (repeatHeader && rowHeights.isNotEmpty) height += rowHeights.first;
    for (var r = from; r < to; r++) {
      height += rowHeights[r];
    }
    return height;
  }
}

/// The width of the rules between and around cells.
const double tableRule = 1;

/// The room around a cell's text.
const double tableCellPadX = 8;
const double tableCellPadY = 5;

/// The horizontal room a cell takes besides its text: its padding and the
/// rule on its left.
const double _cellChrome = tableCellPadX * 2 + tableRule;

/// Lays a table out to fit [maxWidth]. [cells] is each cell exactly as it
/// will be painted — the span its text widget draws, rooted in the style
/// the widget is given — so a cell is measured the way it is drawn.
///
/// A column is as wide as its widest cell would like, when they all fit. When
/// they don't, every column gets at least its longest word, and the room left
/// goes to the columns in proportion to how much more they wanted — so a
/// column of short numbers stays narrow and the column of prose beside it
/// wraps. A table too wide even for that squeezes its words too.
ReflowTableLayout layoutReflowTable({
  required List<List<InlineSpan>> cells,
  required double maxWidth,
  required TextScaler textScaler,
}) {
  final columns = cells.fold<int>(0, (n, row) => math.max(n, row.length));
  if (columns == 0) {
    return const ReflowTableLayout(columnWidths: [], rowHeights: []);
  }
  final painters = [
    for (final row in cells)
      [
        for (final span in row)
          TextPainter(
            text: span,
            textDirection: TextDirection.ltr,
            textScaler: textScaler,
          )..layout(),
      ],
  ];
  try {
    final natural = List<double>.filled(columns, 0);
    final least = List<double>.filled(columns, 0);
    for (final row in painters) {
      for (var c = 0; c < row.length; c++) {
        // Rounded up, and a whisker more: a width measured to the pixel
        // wraps its last letter when rounding goes the other way.
        natural[c] = math.max(
          natural[c],
          row[c].maxIntrinsicWidth.ceilToDouble() + 1,
        );
        least[c] = math.max(
          least[c],
          row[c].minIntrinsicWidth.ceilToDouble() + 1,
        );
      }
    }
    final available = math.max(0.0, maxWidth - tableRule);
    final wanted = [for (final w in natural) w + _cellChrome];
    final minimum = [for (final w in least) w + _cellChrome];
    final wantedTotal = wanted.fold<double>(0, (a, b) => a + b);
    final minimumTotal = minimum.fold<double>(0, (a, b) => a + b);

    final List<double> widths;
    if (wantedTotal <= available) {
      widths = wanted;
    } else if (minimumTotal <= available) {
      final spare = available - minimumTotal;
      final want = wantedTotal - minimumTotal;
      widths = [
        for (var c = 0; c < columns; c++)
          (minimum[c] +
                  (want <= 0 ? 0 : spare * (wanted[c] - minimum[c]) / want))
              .floorToDouble(),
      ];
    } else {
      final scale = available / minimumTotal;
      widths = [for (final w in minimum) (w * scale).floorToDouble()];
    }

    final heights = <double>[];
    for (final row in painters) {
      var tallest = 0.0;
      for (var c = 0; c < row.length; c++) {
        row[c].layout(maxWidth: cellTextWidth(widths[c]));
        tallest = math.max(tallest, row[c].height);
      }
      heights.add(tallest + tableCellPadY * 2 + tableRule);
    }
    return ReflowTableLayout(columnWidths: widths, rowHeights: heights);
  } finally {
    for (final row in painters) {
      for (final painter in row) {
        painter.dispose();
      }
    }
  }
}

/// How wide the text of a cell in a column [columnWidth] wide is set.
double cellTextWidth(double columnWidth) =>
    math.max(1.0, columnWidth - _cellChrome);

/// The rows of a table whose text lies in `[start, end)` of its block — the
/// rows one slice of it holds.
({int from, int to}) tableRowsIn(ReflowBlock table, int start, int end) {
  final cells = table.tableCells!;
  var from = cells.length;
  var to = cells.length;
  for (var r = 0; r < cells.length; r++) {
    final rowStart = cells[r].first.start;
    if (from == cells.length && rowStart >= start) from = r;
    if (rowStart >= end) {
      to = r;
      break;
    }
  }
  return (from: math.min(from, to), to: to);
}
