import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/reading_display_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../utils/reading_text_style.dart';
import '../utils/spreadsheet_pages.dart';
import '../utils/text_search.dart';
import '../utils/xlsx_decode.dart';
import '../utils/xls_decode.dart';
import '../widgets/book_search_bar.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/reader_copy_menu.dart';
import '../widgets/spreadsheet_grid_view.dart';
import '../widgets/spreadsheet_page_view.dart';

/// Height of the floating top bar (excluding the status-bar inset it sits
/// under) — matched to the other readers'.
const double _barHeight = 50;

/// Reader for spreadsheets (.xlsx/.xls).
///
/// A table is read one of two ways, and the reader picks which with the same
/// button every other reader has: the *compact* view paginates the workbook
/// into a book — every sheet's rows cut into pages, a sheet too wide for the
/// screen cut into column groups the way a printer would cut it — and the
/// *original* view shows the sheet as it actually is, pannable and zoomable
/// with a tab per sheet.
///
/// Pagination is what lets a spreadsheet share the app's reading controls
/// down to the last detail — page counter and jump, text size, the translator
/// and its language pair, whole-book search — and the original view keeps
/// them all: it is the same search, the same tap-a-word-to-translate, the
/// same bar, only over the unfolded sheet instead of the page.
class XlsxReaderScreen extends StatefulWidget {
  const XlsxReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<XlsxReaderScreen> createState() => _XlsxReaderScreenState();
}

class _XlsxReaderScreenState extends State<XlsxReaderScreen>
    with WidgetsBindingObserver {
  final _pageViewKey = GlobalKey<SpreadsheetPageViewState>();
  final _gridViewKey = GlobalKey<SpreadsheetGridViewState>();
  late LibraryDocument _document;

  List<SpreadsheetSheet> _sheets = const [];
  bool _loading = true;
  String? _error;

  /// False shows the sheet as it is laid out ([SpreadsheetGridView]); true
  /// shows it paginated for reading ([SpreadsheetPageView]). Same meaning,
  /// same name and same persisted flag as in the PDF reader.
  late bool _reflowMode;
  int _currentPage = 1;
  double _fontSize = 17;
  bool _searchOpen = false;

  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;
  DateTime? _pageEnteredAt;
  Timer? _progressSave;

  // Looked up once, in initState, and reused in dispose() — a fresh
  // context.read() there is unsafe (the element may already be deactivated
  // by the time dispose runs, e.g. when a rename elsewhere in the tree
  // triggers a rebuild that tears this route down).
  late final ReadingDisplayService _readingDisplay;
  late final StatisticsService _statistics;

  @override
  void initState() {
    super.initState();
    _readingDisplay = context.read<ReadingDisplayService>();
    _statistics = context.read<StatisticsService>();
    _document = context.read<LibraryService>().documents.firstWhere(
      (d) => d.id == widget.documentId,
    );
    _currentPage = _document.lastPage;
    _fontSize = _document.reflowFontSize;
    _reflowMode = _document.reflowModeOrDefault;
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(_readingDisplay.enter(context.read<SettingsService>()));
    _load();
  }

  /// Decoding runs off the UI isolate: unzipping and parsing a workbook's
  /// XML is the slow part of opening a spreadsheet, and a big file used to
  /// freeze the screen while it happened.
  Future<void> _load() async {
    try {
      final sheets = await compute(
        _decodeWorkbook,
        _DecodeRequest(path: _document.filePath, format: _document.format),
      );
      if (!mounted) return;
      setState(() {
        _sheets = sheets;
        _loading = false;
      });
      // The page count is only known once the sheets have been laid out;
      // that is what [_layoutFor] reports back. Until then this just records
      // that the document was opened.
      _saveProgress();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _progressSave?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_readingDisplay.exit());
    _flushDwellTime();
    super.dispose();
  }

  void _flushDwellTime() {
    final enteredAt = _pageEnteredAt;
    if (enteredAt == null) return;
    final elapsed = DateTime.now().difference(enteredAt).inSeconds;
    _pageEnteredAt = null;
    if (elapsed < _minDwellSeconds) return;
    _statistics.recordReading(
      documentId: widget.documentId,
      seconds: elapsed.clamp(0, _maxCountedDwellSeconds),
      page: _currentPage,
    );
  }

  /// Same rule as every other reader: time only counts while the app is
  /// actually in the foreground, never with the screen off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
  }

  void _updateCurrentPage(int page, {bool settle = false}) {
    if (page == _currentPage) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() => _currentPage = page);
    // Panning the original grid crosses page after page in one gesture; the
    // counter follows at once, but the write to storage waits for the reader
    // to stop, so a scroll never turns into a persist per frame.
    if (settle) {
      _progressSave?.cancel();
      _progressSave = Timer(const Duration(milliseconds: 700), _saveProgress);
    } else {
      _saveProgress();
    }
  }

  void _saveProgress() {
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage.clamp(1, math.max(1, _pageCount)),
      pageCount: _pageCount,
      reflowMode: _reflowMode,
      reflowFontSize: _fontSize,
    );
  }

  void _changeFontSize(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(13, 26));
    _saveProgress();
  }

  /// Opens the inline search bar in the top bar (in place of the title).
  void _openSearch() {
    setState(() => _searchOpen = true);
  }

  /// Closes the inline search bar and drops the highlight.
  void _closeSearch() {
    _pageViewKey.currentState?.clearSearchHighlight();
    _gridViewKey.currentState?.clearSearchHighlight();
    setState(() => _searchOpen = false);
  }

  /// The search the [BookSearchBar] runs. Every page's cells are already in
  /// memory, so a query is a substring scan delivered in one batch — the
  /// same shape the plain-text reader uses.
  Future<void> _runSearch(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    final pages = _grid?.pages ?? const <SpreadsheetPage>[];
    final matches = searchInPages([for (final p in pages) p.blocks], query);
    if (matches.isNotEmpty) onBatch(matches);
    onDone();
  }

  void _onSearchSelect(SearchMatch match, List<SearchMatch> allMatches) {
    final pages = _grid?.pages;
    if (pages == null || match.pageIndex >= pages.length) return;
    final page = pages[match.pageIndex];
    if (_reflowMode) {
      _pageViewKey.currentState?.showSearchHighlight(
        match.pageIndex + 1,
        match.blockIndex,
        match.matchStart,
        match.matchEnd,
        others: [
          for (final m in allMatches)
            if (m.pageIndex == match.pageIndex && m != match)
              (blockIndex: m.blockIndex, start: m.matchStart, end: m.matchEnd),
        ],
      );
    } else {
      // The hit was found through the page's reading order; the grid needs
      // the sheet cell behind it, which is the same cell seen from the other
      // side.
      _gridViewKey.currentState?.showCell(
        page.cellOf(match.blockIndex),
        start: match.matchStart,
        end: match.matchEnd,
        others: [
          for (final m in allMatches)
            if (m.pageIndex == match.pageIndex && m != match)
              _rangeOf(page.cellOf(m.blockIndex), m),
        ],
      );
    }
    _updateCurrentPage(match.pageIndex + 1);
  }

  static SheetCellRange _rangeOf(SheetCell cell, SearchMatch match) => (
    sheetIndex: cell.sheetIndex,
    row: cell.row,
    column: cell.column,
    start: match.matchStart,
    end: match.matchEnd,
  );

  /// Panning the original grid moves the reader through the same pages the
  /// compact view counts, so the counter keeps saying where they are either
  /// way.
  void _onGridCellChanged(SheetCell cell) {
    if (!_reflowMode) {
      final pages = _grid?.pages;
      if (pages == null) return;
      final index = findPageForCell(
        pages,
        sheetIndex: cell.sheetIndex,
        row: cell.row,
        column: cell.column,
      );
      if (index != null) _updateCurrentPage(index + 1, settle: true);
    }
  }

  /// The two views show the same book from two ends, so switching aims the
  /// one becoming visible at where the other was.
  void _toggleMode() {
    final page = _pageAt(_currentPage);
    setState(() => _reflowMode = !_reflowMode);
    _saveProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || page == null) return;
      if (_reflowMode) {
        _pageViewKey.currentState?.jumpToPage(_currentPage);
      } else {
        _gridViewKey.currentState?.showCell((
          sheetIndex: page.sheetIndex,
          row: page.firstRow,
          column: page.firstColumn,
        ));
      }
    });
  }

  SpreadsheetPage? _pageAt(int page) {
    final pages = _grid?.pages;
    if (pages == null || pages.isEmpty) return null;
    return pages[(page - 1).clamp(0, pages.length - 1)];
  }

  Future<void> _jumpToPage() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.goToPageTitle),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.goToPageHint(_pageCount)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)),
            child: Text(l10n.go),
          ),
        ],
      ),
    );
    if (target == null || target < 1 || target > _pageCount) return;
    if (_reflowMode) {
      _pageViewKey.currentState?.jumpToPage(target);
    } else {
      final page = _pageAt(target);
      if (page != null) {
        _gridViewKey.currentState?.showCell((
          sheetIndex: page.sheetIndex,
          row: page.firstRow,
          column: page.firstColumn,
        ));
      }
    }
    _updateCurrentPage(target);
  }

  // ------------------------------------------------------------- pagination

  /// The workbook cut into pages, with the column widths that cut was made
  /// from. Recomputed whenever the sheet contents, the text size, the reading
  /// type, or the page it has to fit changes shape — and only then. The screen
  /// is deliberately reduced to the two numbers that actually alter the book
  /// (its width, and how many rows fit a page), because a sliding keyboard
  /// would otherwise re-cut the whole workbook on every frame of its
  /// animation while changing neither.
  _GridLayout? _grid;
  List<SpreadsheetSheet>? _gridSheets;
  double _gridFontSize = 0;
  double _gridPageWidth = 0;
  int _gridRowsPerPage = 0;
  String _gridFontKey = '';
  int _pageCount = 0;

  _GridLayout _layoutFor(
    SettingsService settings, {
    required double pageWidth,
    required int rowsPerPage,
  }) {
    final fontKey =
        '${settings.readingFont.family}/${settings.readingWeight}/'
        '${settings.readingContrast}/${MediaQuery.textScalerOf(context).scale(1)}';
    final grid = _grid;
    if (grid != null &&
        identical(_gridSheets, _sheets) &&
        _gridFontSize == _fontSize &&
        _gridPageWidth == pageWidth &&
        _gridRowsPerPage == rowsPerPage &&
        _gridFontKey == fontKey) {
      return grid;
    }

    final style = readingTextStyle(settings: settings, fontSize: _fontSize);
    final boldStyle = readingTextStyle(
      settings: settings,
      fontSize: _fontSize,
      bold: true,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final widths = [
      for (final sheet in _sheets)
        measureColumnWidths(
          sheet,
          style: style,
          boldStyle: boldStyle,
          textScaler: textScaler,
          maxColumnWidth: pageWidth - 2 * spreadsheetCellPadding,
        ),
    ];
    final pages = buildSpreadsheetPages(
      sheets: _sheets,
      columnWidths: widths,
      pageWidth: pageWidth,
      rowsPerPage: rowsPerPage,
      cellPadding: 2 * spreadsheetCellPadding,
    );

    _grid = _GridLayout(pages: pages, columnWidths: widths);
    _gridSheets = _sheets;
    _gridFontSize = _fontSize;
    _gridPageWidth = pageWidth;
    _gridRowsPerPage = rowsPerPage;
    _gridFontKey = fontKey;
    if (pages.length != _pageCount) {
      _pageCount = pages.length;
      // The library tile shows "page X of Y", so the count belongs there as
      // soon as it is known — reported after the frame, never during it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentPage > _pageCount) {
          // Re-opening after a text-size change can leave the remembered
          // page past the end of the shorter book that resulted.
          _currentPage = _pageCount;
          // Only the view on screen can be told about it; the hidden one is
          // re-aimed when the reader switches to it.
          if (_reflowMode) {
            _pageViewKey.currentState?.jumpToPage(_currentPage);
          }
        }
        _saveProgress();
      });
    }
    return _grid!;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final translationService = context.read<TranslationService>();
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    // The Scaffold shrinks the body by the on-screen keyboard, so the page
    // budget has to shrink with it — otherwise the rows counted for a full
    // screen overflow the bare half of one the keyboard leaves behind.
    final area = Size(
      media.size.width - media.padding.left - media.padding.right,
      media.size.height -
          media.padding.top -
          media.padding.bottom -
          media.viewInsets.bottom -
          _barHeight,
    );
    final textScale = media.textScaler.scale(1);
    // The grid sits inside 12px of page margin on each side, and each cell
    // adds its own padding around the text it holds.
    final pageWidth = math.max(80.0, area.width - 24);
    final usableHeight =
        area.height -
        spreadsheetPagePadding -
        spreadsheetCaptionHeight -
        4; // slack, so a rounding difference never clips the last row
    final rowsPerPage = math.max(
      1,
      (usableHeight / spreadsheetRowHeight(_fontSize, textScale: textScale))
          .floor(),
    );

    return Scaffold(
      body: Stack(
        children: [
          // Same shape as every other reader: the content owns the screen
          // and the bar floats above it.
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(
                  settings,
                  translationService,
                  pageWidth: pageWidth,
                  rowsPerPage: rowsPerPage,
                ),
              ),
            ),
          ),
          _buildFloatingBar(l10n, settings, scheme),
        ],
      ),
    );
  }

  /// The reader's single compact row, floating over the page — page counter
  /// (tap to jump), text size, translator toggle and the language pair, all
  /// in the reading palette.
  Widget _buildFloatingBar(
    AppLocalizations l10n,
    SettingsService settings,
    ColorScheme scheme,
  ) {
    final hasPages = _pageCount > 0;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: settings.readingTheme.secondaryBackground,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: SizedBox(
            height: _barHeight,
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                if (_searchOpen)
                  Expanded(
                    child: BookSearchBar(
                      search: _runSearch,
                      readingPage: () => _currentPage - 1,
                      onSelect: _onSearchSelect,
                      onClose: _closeSearch,
                    ),
                  )
                else ...[
                  Expanded(
                    child: InkWell(
                      onTap: hasPages ? _jumpToPage : null,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              hasPages
                                  ? '$_currentPage / $_pageCount'
                                  : _document.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (hasPages)
                              Text(
                                _document.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.text_decrease),
                    tooltip: l10n.smallerText,
                    onPressed: () => _changeFontSize(-1),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.text_increase),
                    tooltip: l10n.largerText,
                    onPressed: () => _changeFontSize(1),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 21,
                    icon: Icon(
                      Icons.translate,
                      color: settings.translatorEnabled
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
                    tooltip: settings.translatorEnabled
                        ? l10n.translatorOnTooltip
                        : l10n.translatorOffTooltip,
                    onPressed: () => settings.setTranslatorEnabled(
                      !settings.translatorEnabled,
                    ),
                  ),
                  if (settings.translatorEnabled)
                    InkWell(
                      onTap: () => showQuickLanguageSwitch(context),
                      borderRadius: BorderRadius.circular(9),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Text(
                              settings.sourceAppLanguage.flag,
                              style: const TextStyle(fontSize: 13),
                            ),
                            Icon(
                              Icons.arrow_right_alt,
                              size: 15,
                              color: scheme.onSurfaceVariant,
                            ),
                            Text(
                              settings.targetAppLanguage.flag,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: Icon(
                      _reflowMode ? Icons.grid_on : Icons.auto_stories_outlined,
                    ),
                    tooltip: _reflowMode
                        ? l10n.originalSheet
                        : l10n.adaptToPhone,
                    onPressed: hasPages ? _toggleMode : null,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.search),
                    tooltip: l10n.searchTooltip,
                    onPressed: hasPages ? _openSearch : null,
                  ),
                  ReaderCopyMenu(
                    pageText: () => _pageAt(_currentPage)?.text,
                    bookText: () =>
                        spreadsheetPagesText(_grid?.pages ?? const []),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    SettingsService settings,
    TranslationService translationService, {
    required double pageWidth,
    required int rowsPerPage,
  }) {
    if (_loading) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).openFailed(error)),
          ),
        ),
      );
    }
    if (_sheets.isEmpty) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).spreadsheetEmpty),
          ),
        ),
      );
    }
    final grid = _layoutFor(
      settings,
      pageWidth: pageWidth,
      rowsPerPage: rowsPerPage,
    );
    if (grid.pages.isEmpty) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).spreadsheetEmpty),
          ),
        ),
      );
    }
    // Both views stay mounted (just hidden, via Offstage) so switching modes
    // is an instant change of what is visible rather than a rebuild from
    // scratch: each keeps its own place in the workbook warm the whole time,
    // and the reader lands back where they left it when they come.
    final page = _pageAt(_currentPage) ?? grid.pages.first;
    return Stack(
      children: [
        Offstage(
          offstage: !_reflowMode,
          child: SpreadsheetPageView(
            key: _pageViewKey,
            pages: grid.pages,
            columnWidths: grid.columnWidths,
            initialPage: _currentPage,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            translationService: translationService,
            fontSize: _fontSize,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: settings.translatorEnabled,
            onPageChanged: _updateCurrentPage,
          ),
        ),
        Offstage(
          offstage: _reflowMode,
          child: SpreadsheetGridView(
            key: _gridViewKey,
            sheets: _sheets,
            columnWidths: grid.columnWidths,
            initialCell: (
              sheetIndex: page.sheetIndex,
              row: page.firstRow,
              column: page.firstColumn,
            ),
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            translationService: translationService,
            fontSize: _fontSize,
            readingTheme: settings.readingTheme,
            settings: settings,
            translatorEnabled: settings.translatorEnabled,
            onViewChanged: _onGridCellChanged,
          ),
        ),
      ],
    );
  }
}

class _GridLayout {
  const _GridLayout({required this.pages, required this.columnWidths});

  final List<SpreadsheetPage> pages;
  final List<List<double>> columnWidths;
}

/// What to decode, and where from — sent to the isolate as one value.
class _DecodeRequest {
  const _DecodeRequest({required this.path, required this.format});

  final String path;
  final String format;
}

/// Top-level so it can run on another isolate.
List<SpreadsheetSheet> _decodeWorkbook(_DecodeRequest request) {
  final bytes = File(request.path).readAsBytesSync();
  return request.format == 'xls' ? decodeXls(bytes) : decodeXlsx(bytes);
}
