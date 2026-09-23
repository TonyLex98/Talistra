import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/sentence_finder.dart';
import '../utils/spreadsheet_pages.dart';
import '../utils/xlsx_decode.dart';
import 'translatable_text.dart';
import 'translation_panel.dart';

/// The spreadsheet's *original* view: the sheet as the sheet itself lays it
/// out — pan it in any direction, pinch to zoom, and change sheets by tab
/// along the bottom.
///
/// It is the counterpart to [SpreadsheetPageView]'s compact, paginated
/// reading, exactly as the PDF reader's page view is the counterpart of its
/// reflowed text, and for the same reason: a table has a layout of its own
/// that a reader may want to see rather than have folded into pages for them.
/// Both views keep the app's other controls identical — tap a word to
/// translate it, search and land on the hit — so switching modes changes what
/// is on screen, not how the reader works.
///
/// Only the cells inside the viewport are ever built, and where they go comes
/// from arithmetic on the pre-measured column widths and the fixed row height
/// rather than from layout. Panning translates an already-laid-out window, so
/// it costs a repaint rather than a re-layout of every cell, and scrolling a
/// ten-thousand-row sheet costs the same as looking at the forty rows on
/// screen.
class SpreadsheetGridView extends StatefulWidget {
  const SpreadsheetGridView({
    super.key,
    required this.sheets,
    required this.columnWidths,
    required this.initialCell,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.onViewChanged,
  });

  final List<SpreadsheetSheet> sheets;

  /// Measured text width of every column of every sheet, indexed like
  /// [sheets] — the same widths the paginated view lays its columns out with,
  /// which is why a cell's text never truncates differently in one mode than
  /// in the other.
  final List<List<double>> columnWidths;

  /// The cell to open on: the top-left of the page the reader was last on, so
  /// the two modes start where the other left off.
  final SheetCell initialCell;

  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;

  /// Read straight through for typography — see [TranslatableText].
  final SettingsService settings;

  final bool translatorEnabled;

  /// Called whenever the cell at the top-left of the viewport changes, so the
  /// reader can keep the page counter and the saved progress honest while
  /// panning.
  final ValueChanged<SheetCell> onViewChanged;

  static const double minScale = 0.5;
  static const double maxScale = 4;

  /// How far the sheet may be dragged past its own edges — enough that the
  /// last row or column can be brought clear of the screen edge, not so much
  /// that the reader can lose the table in a field of empty background.
  static const double overscroll = 48;

  @override
  State<SpreadsheetGridView> createState() => SpreadsheetGridViewState();
}

class SpreadsheetGridViewState extends State<SpreadsheetGridView>
    with SingleTickerProviderStateMixin {
  int _sheet = 0;
  double _scale = 1;
  Offset _offset = Offset.zero;

  // Where each sheet was left, so tabbing away and back returns to the same
  // corner of it rather than to the top.
  final Map<int, ({Offset offset, double scale})> _placed = {};

  Size _viewport = Size.zero;
  SheetCell? _awaitViewport;

  /// The cell at the top-left of the viewport as of the last frame — what the
  /// view aims to keep in view when the sheet's geometry changes under it.
  SheetCell? _anchor;

  // The search hit the reader landed on, and the other hits, washed fainter.
  // The others are bucketed by cell so painting a frame costs a lookup per
  // visible cell rather than a scan of every match in the book.
  SheetCellRange? _highlight;
  Map<({int sheet, int row, int column}), List<({int start, int end})>>
  _otherHighlights = const {};

  // The tapped word and its translation panel.
  int? _selectedRow;
  int? _selectedColumn;
  int? _selectedStart;
  int? _selectedEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  // Pan and pinch arrive as one scale gesture; a fling carries it on after
  // the fingers lift.
  Offset _focal = Offset.zero;
  double _gestureScale = 1;
  Ticker? _fling;
  FrictionSimulation? _flingX;
  FrictionSimulation? _flingY;
  double _flingAt = 0;

  static const double tabBarHeight = 40;

  List<double>? _edges;
  Object? _edgesKey;

  @override
  void initState() {
    super.initState();
    _sheet = widget.initialCell.sheetIndex.clamp(0, widget.sheets.length - 1);
    // Where that cell actually sits can only be worked out once the sheet has
    // been measured against a real viewport, and the view may be mounted
    // hidden (the reader's other mode is on screen) — so the aim is asked for
    // at the first layout that can carry it out.
    _awaitViewport = widget.initialCell;
  }

  @override
  void dispose() {
    _fling?.stop();
    _fling?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SpreadsheetGridView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheets == widget.sheets &&
        oldWidget.fontSize == widget.fontSize) {
      return;
    }
    // Every column width and row height changed, so the pixel offset being
    // looked at no longer points where it did. Keep the cell the reader was
    // looking at under their eyes instead of drifting through the sheet.
    final anchor = _anchor;
    if (anchor != null && anchor.sheetIndex == _sheet) _scrollTo(anchor);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifyViewChanged();
    });
  }

  // ---------------------------------------------------------------- geometry

  double get _textScale => MediaQuery.textScalerOf(context).scale(1);

  double _rowHeightFor(double scale) =>
      spreadsheetRowHeight(widget.fontSize, textScale: _textScale) * scale;

  double get _rowHeight => _rowHeightFor(_scale);

  SpreadsheetSheet get _sheetData => widget.sheets[_sheet];

  /// The left edge of every column of the sheet in view, plus the right edge
  /// of the last one, at the current zoom — so a cell's box is a subtraction
  /// away and nothing about the sheet has to be laid out to find it.
  List<double> get _columnEdges {
    final key = Object.hash(_sheet, _scale, widget.columnWidths);
    if (_edges != null && _edgesKey == key) return _edges!;
    final edges = <double>[0];
    var x = 0.0;
    for (final width in widget.columnWidths[_sheet]) {
      x += (width + 2 * spreadsheetCellPadding) * _scale;
      edges.add(x);
    }
    return _edges = edges;
  }

  double get _contentWidth => _columnEdges.last;

  double get _contentHeight => _sheetData.rows.length * _rowHeight;

  Offset _clamp(Offset offset) {
    double axis(double value, double content, double viewport) {
      if (viewport <= 0) return value;
      // A sheet shorter or narrower than the window has nowhere to pan: it
      // stays pinned to the corner it opens in, the way it does in Excel.
      if (content <= viewport) return 0;
      return value.clamp(
        viewport - content - SpreadsheetGridView.overscroll,
        SpreadsheetGridView.overscroll,
      );
    }

    return Offset(
      axis(offset.dx, _contentWidth, _viewport.width),
      axis(offset.dy, _contentHeight, _viewport.height),
    );
  }

  /// The rows (and columns) the viewport shows, plus one of overscan on each
  /// side so a pan never drags blank space in behind the last built cell.
  ({int first, int last}) _rowWindow() {
    final rows = _sheetData.rows.length;
    if (rows == 0) return (first: 0, last: -1);
    final height = _rowHeight;
    return (
      first: math.max(0, ((-_offset.dy - height) / height).floor()),
      last: math.min(
        rows - 1,
        ((-_offset.dy + _viewport.height) / height).ceil(),
      ),
    );
  }

  ({int first, int last}) _columnWindow() {
    final edges = _columnEdges;
    // The last column index is one short of the edge list, which carries its
    // right edge too.
    final lastColumn = edges.length - 2;
    if (lastColumn < 0) return (first: 0, last: -1);
    var first = 0;
    while (first < lastColumn && edges[first + 1] + _offset.dx <= 0) {
      first++;
    }
    var last = first;
    while (last < lastColumn && edges[last] + _offset.dx < _viewport.width) {
      last++;
    }
    return (first: math.max(0, first - 1), last: last);
  }

  // -------------------------------------------------------------------- public

  /// Shows a cell: switches to its sheet and brings it into view. With
  /// [start] and [end] it also washes over that run of the cell's text as the
  /// hit the reader is looking at.
  void showCell(
    SheetCell cell, {
    int? start,
    int? end,
    List<SheetCellRange> others = const [],
  }) {
    _stopFling();
    final byCell =
        <({int sheet, int row, int column}),
        List<({int start, int end})>>{};
    for (final other in others) {
      byCell
          .putIfAbsent(
            (sheet: other.sheetIndex, row: other.row, column: other.column),
            () => <({int start, int end})>[],
          )
          .add((start: other.start, end: other.end));
    }
    setState(() {
      _highlight = start == null || end == null
          ? null
          : (
              sheetIndex: cell.sheetIndex,
              row: cell.row,
              column: cell.column,
              start: start,
              end: end,
            );
      _otherHighlights = byCell;
      _clearSelection();
      if (cell.sheetIndex != _sheet) _openSheet(cell.sheetIndex);
      _scrollTo(cell);
    });
    _notifyViewChanged();
  }

  void clearSearchHighlight() {
    if (_highlight == null && _otherHighlights.isEmpty) return;
    setState(() {
      _highlight = null;
      _otherHighlights = const {};
    });
  }

  // ----------------------------------------------------------------- gestures

  void _onScaleStart(ScaleStartDetails details) {
    _stopFling();
    _focal = details.localFocalPoint;
    _gestureScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focal = details.localFocalPoint;
    setState(() {
      _offset += focal - _focal;
      final next = (_gestureScale * details.scale).clamp(
        SpreadsheetGridView.minScale,
        SpreadsheetGridView.maxScale,
      );
      if (next != _scale) {
        // A pinch is a zoom about the fingers, not a jump to a new scale:
        // whatever content was under them has to stay under them.
        final content = (focal - _offset) / _scale;
        _scale = next;
        _offset = focal - content * next;
      }
      _offset = _clamp(_offset);
      _focal = focal;
    });
    _notifyViewChanged();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.distanceSquared < 90000) return;
    _flingX = FrictionSimulation(1.015, 0, velocity.dx);
    _flingY = FrictionSimulation(1.015, 0, velocity.dy);
    _flingAt = 0;
    _fling ??= createTicker(_onFlingTick);
    _fling!.start();
  }

  void _onFlingTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final from = _flingAt;
    _flingAt = t;
    final delta = Offset(
      _flingX!.x(t) - _flingX!.x(from),
      _flingY!.x(t) - _flingY!.x(from),
    );
    setState(() => _offset = _clamp(_offset + delta));
    _notifyViewChanged();
    if (delta == Offset.zero || (_flingX!.isDone(t) && _flingY!.isDone(t))) {
      _stopFling();
    }
  }

  void _stopFling() {
    if (_fling?.isActive ?? false) _fling!.stop();
  }

  /// Brings [cell] to the middle of the viewport, or leaves the sheet alone
  /// when the cell is already in view.
  void _scrollTo(SheetCell cell) {
    if (_viewport.width <= 0 || _viewport.height <= 0) {
      _awaitViewport = cell;
      return;
    }
    final edges = _columnEdges;
    final column = math.min(cell.column, math.max(0, edges.length - 2));
    final top = cell.row * _rowHeight;
    final left = edges[column];
    final width = edges[column + 1] - left;
    var dx = _offset.dx;
    var dy = _offset.dy;
    if (top + dy < 0 || top + _rowHeight + dy > _viewport.height) {
      dy = _viewport.height / 2 - (top + _rowHeight / 2);
    }
    if (left + dx < 0 || left + width + dx > _viewport.width) {
      dx = _viewport.width / 2 - (left + width / 2);
    }
    _offset = _clamp(Offset(dx, dy));
  }

  void _openSheet(int sheet) {
    _placed[_sheet] = (offset: _offset, scale: _scale);
    setState(() {
      _sheet = sheet;
      final placed = _placed[sheet];
      _scale = placed?.scale ?? _scale;
      _offset = _clamp(placed?.offset ?? Offset.zero);
      _clearSelection();
    });
    _notifyViewChanged();
  }

  void _notifyViewChanged() {
    if (mounted) widget.onViewChanged(topLeftCell());
  }

  /// The cell sitting at the top-left of the viewport.
  SheetCell topLeftCell() {
    final rows = _sheetData.rows;
    final edges = _columnEdges;
    final x = -_offset.dx;
    var column = 0;
    while (column + 1 < edges.length && edges[column + 1] <= x) {
      column++;
    }
    final row = _offset.dy < 0 ? (-_offset.dy / _rowHeight).floor() : 0;
    return (
      sheetIndex: _sheet,
      row: row.clamp(0, math.max(0, rows.length - 1)),
      column: column,
    );
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.readingTheme.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _viewport = Size(
            constraints.maxWidth,
            math.max(0, constraints.maxHeight - tabBarHeight),
          );
          // A cell asked to be shown before there was a viewport to show it
          // in gets placed now: the sheet opens on the corner of it, the same
          // corner the paginated view was showing.
          final pending = _awaitViewport;
          if (pending != null) {
            _awaitViewport = null;
            final edges = _columnEdges;
            _offset = _clamp(
              Offset(
                -edges[math.min(pending.column, math.max(0, edges.length - 2))],
                -pending.row * _rowHeight,
              ),
            );
          }
          final edges = _columnEdges;
          final rows = _rowWindow();
          final columns = _columnWindow();
          _anchor = topLeftCell();
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: tabBarHeight,
                child: ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _GridPainter(
                              edges: edges,
                              rows: rows,
                              columns: columns,
                              rowHeight: _rowHeight,
                              offset: _offset,
                              viewport: _viewport,
                              theme: widget.readingTheme,
                            ),
                          ),
                        ),
                        Positioned.fill(child: _buildCells(rows, columns)),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: tabBarHeight,
                child: _buildTabs(),
              ),
              if (_selectedWord != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: tabBarHeight + 16,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: TranslationPanel(
                      key: ValueKey(
                        '$_selectedWord-${widget.source}-${widget.target}',
                      ),
                      word: _selectedWord!,
                      sentenceMatch: _selectedSentence,
                      source: widget.source,
                      target: widget.target,
                      translationService: widget.translationService,
                      onClose: () => setState(_clearSelection),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The window of cells the viewport shows, laid out in the sheet's own
  /// coordinates and then translated as a whole — which is what makes panning
  /// a repaint rather than a re-layout.
  Widget _buildCells(({int first, int last}) rows, ({int first, int last}) columns) {
    final cells = <Widget>[];
    if (_sheetData.rows.isEmpty || columns.last < columns.first) {
      return const SizedBox.shrink();
    }
    final sheetRows = _sheetData.rows;
    final rowHeight = _rowHeight;
    final fontSize = widget.fontSize * _scale;
    final padding = spreadsheetCellPadding * _scale;
    for (var r = rows.first; r <= rows.last; r++) {
      final row = sheetRows[r];
      for (var c = columns.first; c <= columns.last; c++) {
        final text = c < row.length ? row[c] : '';
        // An empty cell carries nothing to read, translate or match, so it
        // is left out of the tree entirely — most of a wide sheet's cells are
        // blank, and building a text widget for each one is what made the old
        // grid crawl.
        if (text.isEmpty) continue;
        cells.add(
          Positioned(
            left: _columnEdges[c],
            top: r * rowHeight,
            width: _columnEdges[c + 1] - _columnEdges[c],
            height: rowHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TranslatableText(
                  text: text,
                  settings: widget.settings,
                  fontSize: fontSize,
                  readingTheme: widget.readingTheme,
                  translatorEnabled: widget.translatorEnabled,
                  bold: r == 0,
                  maxLines: 1,
                  selectedStart: _isSelected(r, c) ? _selectedStart : null,
                  selectedEnd: _isSelected(r, c) ? _selectedEnd : null,
                  highlight: _highlightFor(r, c),
                  otherHighlights: _othersFor(r, c),
                  onWordTap: (start, end, word) =>
                      _onWordTap(r, c, start, end, word),
                ),
              ),
            ),
          ),
        );
      }
    }
    return Transform.translate(
      offset: _offset,
      child: Stack(clipBehavior: Clip.none, children: cells),
    );
  }

  bool _isSelected(int row, int column) =>
      _selectedRow == row && _selectedColumn == column;

  ({int start, int end})? _highlightFor(int row, int column) {
    final hl = _highlight;
    if (hl == null ||
        hl.sheetIndex != _sheet ||
        hl.row != row ||
        hl.column != column) {
      return null;
    }
    return (start: hl.start, end: hl.end);
  }

  List<({int start, int end})> _othersFor(int row, int column) =>
      _otherHighlights[(sheet: _sheet, row: row, column: column)] ?? const [];

  void _onWordTap(int row, int column, int start, int end, String word) {
    if (!widget.translatorEnabled) return;
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
      _selectedStart = start;
      _selectedEnd = end;
      _selectedWord = word;
      final sheetRows = _sheetData.rows;
      final cells = row < sheetRows.length ? sheetRows[row] : const <String>[];
      _selectedSentence = findSentenceInText(
        column < cells.length ? cells[column] : word,
        word,
      );
    });
  }

  void _clearSelection() {
    _selectedRow = null;
    _selectedColumn = null;
    _selectedStart = null;
    _selectedEnd = null;
    _selectedWord = null;
    _selectedSentence = null;
  }

  Widget _buildTabs() {
    if (widget.sheets.length < 2) return const SizedBox.shrink();
    final theme = widget.readingTheme;
    return ColoredBox(
      color: theme.secondaryBackground,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        itemCount: widget.sheets.length,
        itemBuilder: (context, index) {
          final selected = index == _sheet;
          return InkWell(
            onTap: () => _openSheet(index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? theme.accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Center(
                  child: Text(
                    widget.sheets[index].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: selected
                          ? theme.accent
                          : theme.onBackground.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The sheet's rules and its header band, drawn in one pass over exactly the
/// window of rows and columns being shown.
class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.edges,
    required this.rows,
    required this.columns,
    required this.rowHeight,
    required this.offset,
    required this.viewport,
    required this.theme,
  });

  final List<double> edges;
  final ({int first, int last}) rows;
  final ({int first, int last}) columns;
  final double rowHeight;
  final Offset offset;
  final Size viewport;
  final ReadingTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.last < rows.first || columns.last < columns.first) return;
    final left = offset.dx + edges[columns.first];
    final right = offset.dx + edges[columns.last + 1];
    final top = offset.dy + rows.first * rowHeight;
    final bottom = offset.dy + (rows.last + 1) * rowHeight;

    // The sheet's first line names every column, so it gets the header band
    // the paginated view gives it too.
    if (rows.first == 0) {
      canvas.drawRect(
        Rect.fromLTRB(left, offset.dy, right, offset.dy + rowHeight),
        Paint()..color = theme.secondaryBackground.withValues(alpha: 0.7),
      );
    }

    final line = Paint()
      ..color = theme.onBackground.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var r = rows.first; r <= rows.last + 1; r++) {
      final y = offset.dy + r * rowHeight;
      canvas.drawLine(Offset(left, y), Offset(right, y), line);
    }
    for (var c = columns.first; c <= columns.last + 1; c++) {
      final x = offset.dx + edges[c];
      canvas.drawLine(Offset(x, top), Offset(x, bottom), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      !identical(old.edges, edges) ||
      old.rows != rows ||
      old.columns != columns ||
      old.rowHeight != rowHeight ||
      old.offset != offset ||
      old.viewport != viewport ||
      old.theme != theme;
}
