import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/sentence_finder.dart';
import '../utils/spreadsheet_pages.dart';
import 'translatable_text.dart';
import 'translation_panel.dart';

/// The spreadsheet counterpart to [TxtPageView]: the same swipe-a-page
/// reading surface, the same tap-a-word-to-translate behaviour and the same
/// search highlighting, drawing a table's cells instead of its paragraphs.
///
/// A page is one [SpreadsheetPage] — a run of rows of one sheet, cut to the
/// columns that fit the screen — so a workbook is read, counted and searched
/// page by page like any other book in the app.
///
/// Only the page being looked at is ever built, and its cells are laid out on
/// a fixed row height with pre-measured column widths, so opening a sheet of
/// ten thousand rows costs the same as one of forty.
class SpreadsheetPageView extends StatefulWidget {
  const SpreadsheetPageView({
    super.key,
    required this.pages,
    required this.columnWidths,
    required this.initialPage,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.onPageChanged,
  });

  final List<SpreadsheetPage> pages;

  /// Measured width of every column of every sheet, indexed like the
  /// sheets the pages came from.
  final List<List<double>> columnWidths;

  final int initialPage;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;

  /// Read straight through for typography — see [TranslatableText].
  final SettingsService settings;

  final bool translatorEnabled;
  final ValueChanged<int> onPageChanged;

  @override
  State<SpreadsheetPageView> createState() => SpreadsheetPageViewState();
}

/// Public so the reader screen can drive this view from its own "Go to page"
/// dialog and from the search bar, exactly as it drives [TxtPageView].
class SpreadsheetPageViewState extends State<SpreadsheetPageView> {
  late final PageController _pageController;
  int _currentPage = 0;

  // The search hit the reader is looking at: which cell of the page (its
  // block index, i.e. its position in reading order) and which characters of
  // that cell's text.
  int _hlPageIndex = -1;
  int? _hlBlockIndex;
  int? _hlStart;
  int? _hlEnd;
  List<({int blockIndex, int start, int end})> _hlOthers = const [];

  @override
  void initState() {
    super.initState();
    _currentPage = (widget.initialPage - 1).clamp(0, widget.pages.length - 1);
    _pageController = PageController(initialPage: _currentPage);
  }

  @override
  void didUpdateWidget(SpreadsheetPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pages == widget.pages) return;
    // Re-paginating (a font-size change, a new screen size) can leave the
    // reader past the end of the shorter or longer book that resulted.
    final last = widget.pages.isEmpty ? 0 : widget.pages.length - 1;
    if (_currentPage > last) {
      _currentPage = last;
      // Jumping fires a scroll notification that reaches the reader's page
      // changed callback, and a parent may not call setState while the tree is
      // still being built — so the correction waits for the frame to finish.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.jumpToPage(last);
      });
    }
  }

  void jumpToPage(int page) {
    final index = (page - 1).clamp(0, widget.pages.length - 1);
    _currentPage = index;
    if (_pageController.hasClients) _pageController.jumpToPage(index);
  }

  /// Highlights a search hit: shows [pageIndex] (1-based) and washes over the
  /// [matchStart, matchEnd) range of its [blockIndex]-th cell.
  void showSearchHighlight(
    int pageIndex,
    int blockIndex,
    int matchStart,
    int matchEnd, {
    List<({int blockIndex, int start, int end})> others = const [],
  }) {
    setState(() {
      _hlPageIndex = pageIndex - 1;
      _hlBlockIndex = blockIndex;
      _hlStart = matchStart;
      _hlEnd = matchEnd;
      _hlOthers = others;
    });
    jumpToPage(pageIndex);
  }

  void clearSearchHighlight() {
    setState(() {
      _hlPageIndex = -1;
      _hlBlockIndex = null;
      _hlStart = null;
      _hlEnd = null;
      _hlOthers = const [];
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.readingTheme.background,
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.pages.length,
        onPageChanged: (index) {
          setState(() => _currentPage = index);
          widget.onPageChanged(index + 1);
        },
        itemBuilder: (context, index) {
          final page = widget.pages[index];
          return _GridPage(
            key: ValueKey(
              '$index/${page.rows.length}/${page.firstColumn}/${widget.fontSize}',
            ),
            page: page,
            columnWidths: widget.columnWidths[page.sheetIndex],
            source: widget.source,
            target: widget.target,
            translationService: widget.translationService,
            fontSize: widget.fontSize,
            readingTheme: widget.readingTheme,
            settings: widget.settings,
            translatorEnabled: widget.translatorEnabled,
            highlight: index == _hlPageIndex && _hlBlockIndex != null
                ? (block: _hlBlockIndex, start: _hlStart, end: _hlEnd)
                : null,
            otherHighlights: index == _hlPageIndex ? _hlOthers : const [],
          );
        },
      ),
    );
  }
}

class _GridPage extends StatefulWidget {
  const _GridPage({
    super.key,
    required this.page,
    required this.columnWidths,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.highlight,
    required this.otherHighlights,
  });

  final SpreadsheetPage page;
  final List<double> columnWidths;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;

  /// The cell this page shows as the current search hit, if any.
  final ({int? block, int? start, int? end})? highlight;

  /// This page's other matches, washed over fainter than [highlight].
  final List<({int blockIndex, int start, int end})> otherHighlights;

  @override
  State<_GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<_GridPage> {
  int? _selectedBlock;
  int? _selectedStart;
  int? _selectedEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  double get _rowHeight => spreadsheetRowHeight(
    widget.fontSize,
    textScale: MediaQuery.textScalerOf(context).scale(1),
  );

  double _cellWidth(int column) {
    final index = widget.page.firstColumn + column;
    final text = index < widget.columnWidths.length
        ? widget.columnWidths[index]
        : 44;
    return text + 2 * spreadsheetCellPadding;
  }

  void _onWordTap(int block, int start, int end, String word) {
    if (!widget.translatorEnabled) return;
    setState(() {
      _selectedBlock = block;
      _selectedStart = start;
      _selectedEnd = end;
      _selectedWord = word;
      _selectedSentence = findSentenceInText(widget.page.blocks[block], word);
    });
  }

  void _clear() {
    setState(() {
      _selectedBlock = null;
      _selectedStart = null;
      _selectedEnd = null;
      _selectedWord = null;
      _selectedSentence = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final columnCount = page.columnCount;
    if (columnCount == 0) return const SizedBox.shrink();
    final gridWidth = [
      for (var c = 0; c < columnCount; c++) _cellWidth(c),
    ].reduce((a, b) => a + b);
    final gridHeight = page.rows.length * _rowHeight;

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: spreadsheetCaptionHeight,
                child: Text(
                  page.sheetName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.fontSize * 0.85,
                    fontWeight: FontWeight.w700,
                    color: widget.readingTheme.accent,
                  ),
                ),
              ),
              SizedBox(
                width: gridWidth,
                height: gridHeight,
                child: CustomPaint(
                  painter: _GridLinesPainter(
                    rows: page.rows.length,
                    columns: columnCount,
                    rowHeight: _rowHeight,
                    cellWidths: [
                      for (var c = 0; c < columnCount; c++) _cellWidth(c),
                    ],
                    headerRows: page.headerRowCount,
                    theme: widget.readingTheme,
                  ),
                  child: Column(
                    children: [
                      for (var r = 0; r < page.rows.length; r++)
                        SizedBox(
                          height: _rowHeight,
                          child: Row(
                            children: [
                              for (var c = 0; c < columnCount; c++)
                                _cell(r, c, columnCount),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_selectedWord != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
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
                onClose: _clear,
              ),
            ),
          ),
      ],
    );
  }

  Widget _cell(int row, int column, int columnCount) {
    final text = widget.page.rows[row][column];
    final width = _cellWidth(column);
    // An empty cell carries nothing to read, translate or match, so it is
    // left out of the tree entirely — most of a wide sheet's cells are blank,
    // and building a text widget for each one is what made the old grid crawl.
    if (text.isEmpty) return SizedBox(width: width, height: _rowHeight);
    final block = row * columnCount + column;
    final hl = widget.highlight;
    return SizedBox(
      width: width,
      height: _rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: spreadsheetCellPadding),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TranslatableText(
            text: text,
            settings: widget.settings,
            fontSize: widget.fontSize,
            readingTheme: widget.readingTheme,
            translatorEnabled: widget.translatorEnabled,
            bold: row < widget.page.headerRowCount,
            maxLines: 1,
            selectedStart: block == _selectedBlock ? _selectedStart : null,
            selectedEnd: block == _selectedBlock ? _selectedEnd : null,
            highlight: hl?.block == block
                ? (start: hl!.start!, end: hl.end!)
                : null,
            otherHighlights: [
              for (final o in widget.otherHighlights)
                if (o.blockIndex == block) (start: o.start, end: o.end),
            ],
            onWordTap: (start, end, word) =>
                _onWordTap(block, start, end, word),
          ),
        ),
      ),
    );
  }
}

/// Draws the table's rules in one pass: a grid of a hundred cells used to
/// mean a hundred decorated boxes, where this is a handful of lines.
class _GridLinesPainter extends CustomPainter {
  const _GridLinesPainter({
    required this.rows,
    required this.columns,
    required this.rowHeight,
    required this.cellWidths,
    required this.headerRows,
    required this.theme,
  });

  final int rows;
  final int columns;
  final double rowHeight;
  final List<double> cellWidths;
  final int headerRows;
  final ReadingTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    final widths = <double>[];
    var x = 0.0;
    for (final width in cellWidths) {
      x += width;
      widths.add(x);
    }
    final height = rows * rowHeight;
    final totalWidth = x;

    if (headerRows > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, totalWidth, headerRows * rowHeight),
        Paint()..color = theme.secondaryBackground.withValues(alpha: 0.7),
      );
    }

    final line = Paint()
      ..color = theme.onBackground.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var r = 1; r <= rows; r++) {
      final y = r * rowHeight;
      canvas.drawLine(Offset(0, y), Offset(totalWidth, y), line);
    }
    for (var c = 1; c < widths.length; c++) {
      canvas.drawLine(Offset(widths[c], 0), Offset(widths[c], height), line);
    }
    canvas.drawLine(Offset(0, 0), Offset(0, height), line);
    canvas.drawLine(Offset(0, 0), Offset(totalWidth, 0), line);
  }

  @override
  bool shouldRepaint(_GridLinesPainter old) =>
      old.rows != rows ||
      old.columns != columns ||
      old.rowHeight != rowHeight ||
      old.headerRows != headerRows ||
      old.theme != theme ||
      old.cellWidths.length != cellWidths.length;
}
