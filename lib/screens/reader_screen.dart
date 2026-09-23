import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/page_image_cache.dart';
import '../services/reading_display_service.dart';
import '../services/search_index_cache.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../utils/pdf_region_renderer.dart';
import '../utils/sentence_finder.dart';
import '../utils/text_search.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/pdf_page_stack_view.dart';
import '../widgets/reflow_view.dart';
import '../widgets/book_search_bar.dart';
import '../widgets/translation_panel.dart';

/// Height of the reader's floating top bar (excluding the status bar
/// inset it sits under).
const double _barHeight = 50;

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final _pdfViewKey = GlobalKey<PdfPageStackViewState>();
  final _reflowKey = GlobalKey<ReflowPdfViewState>();
  late LibraryDocument _document;

  PdfDocument? _pdfDocument;
  PdfRegionRenderer? _renderer;
  final Map<int, List<TextLine>> _pageLinesCache = {};
  List<Size> _pageSizes = const [];

  int _pageCount = 0;
  int _currentPage = 1;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  // The word/sentence highlight is stored in PDF-space (page index + PDF
  // point bounds), not screen coordinates — [PdfPageStackView] positions
  // it itself, in the same content-space transform as the pages, so it
  // always tracks scrolling/zooming with no separate recompute needed.
  int? _selectedPageIndex;
  Rect? _selectedWordPdfBounds;
  List<Rect> _selectedSentenceLineBoundsPdf = const [];

  // Where the reader actually tapped (screen space), so the translation
  // card can float right next to the selection instead of always
  // docking to the bottom of the screen.
  Offset? _selectionAnchor;

  bool _reflowMode = false;
  double _reflowFontSize = 17;

  // The whole-book text index: built ONCE in a background isolate (page by
  // page) as soon as the document opens, and cached for the life of the
  // reader. Every search — and every keystroke that re-types the query — is
  // then a plain, instant substring scan over the cached block texts, so
  // searching never re-extracts the book. [_searchOpen] is whether the inline
  // search bar is showing.
  late final PdfSearchIndex _pdfSearchIndex = PdfSearchIndex();
  String _searchQuery = '';
  bool _searchOpen = false;

  /// A long-press-and-drag text selection in the PDF view: the selected
  /// text, whether the drag has finished (only then are actions offered),
  /// and whether the reader asked to translate it.
  String? _rangeText;
  bool _rangeSettled = false;
  bool _translateRange = false;

  // Shown instantly on open (before the real PDF has finished loading)
  // so reopening a document doesn't start from a blank screen.
  Uint8List? _previewBytes;

  // Reading statistics: a page only counts as "read" once the reader has
  // actually dwelt on it for a minimum stretch — a fling that blows
  // through several pages in under a second doesn't count any of them,
  // only pages someone plausibly looked at.
  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;
  DateTime? _pageEnteredAt;

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
    _pageCount = _document.pageCount;
    _pageEnteredAt = DateTime.now();
    _reflowMode = _document.reflowModeOrDefault;
    _reflowFontSize = _document.reflowFontSize;
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(_readingDisplay.enter(context.read<SettingsService>()));
    _loadPreview();
    _loadDocument();
  }

  Future<void> _loadPreview() async {
    final bytes = await context.read<PagePreviewCache>().read(
      widget.documentId,
    );
    if (mounted && bytes != null) setState(() => _previewBytes = bytes);
  }

  /// Fire-and-forget: re-renders whichever page is current and caches it
  /// to disk, so the NEXT time this document opens, [_loadPreview] has
  /// something to show immediately instead of a blank loading screen.
  void _cacheCurrentPagePreview() {
    final renderer = _renderer;
    final pageIndex = _currentPage - 1;
    if (renderer == null || pageIndex < 0 || pageIndex >= _pageSizes.length) {
      return;
    }
    final pageSize = _pageSizes[pageIndex];
    if (pageSize.width <= 0 || pageSize.height <= 0) return;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 2.5);
    final scale = (viewportWidth / pageSize.width) * dpr;
    renderer
        .renderRegion(
          pageIndex: pageIndex,
          pdfBounds: Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
          scale: scale,
        )
        .then((bytes) {
          if (bytes != null && mounted) {
            context.read<PagePreviewCache>().write(widget.documentId, bytes);
          }
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    // The reader may have hidden the system bars for full-screen reading;
    // the rest of the app expects them back.
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_readingDisplay.exit());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _flushDwellTime();
    unawaited(_pdfSearchIndex.cancel());
    _pdfDocument?.dispose();
    _renderer?.close();
    super.dispose();
  }

  /// Counts the time spent on the page being left as "read" only if it
  /// clears [_minDwellSeconds] — anything shorter is a flip-through, not
  /// reading, and is silently dropped rather than recorded.
  ///
  /// [page] is the page the time was spent on; it's marked as read (once —
  /// see [StatisticsService.recordReading]), so coming back to a page
  /// later adds time but not another page to the count.
  void _flushDwellTime({int? page}) {
    final enteredAt = _pageEnteredAt;
    if (enteredAt == null) return;
    final elapsed = DateTime.now().difference(enteredAt).inSeconds;
    _pageEnteredAt = null;
    if (elapsed < _minDwellSeconds) return;
    _statistics.recordReading(
      documentId: widget.documentId,
      seconds: elapsed.clamp(0, _maxCountedDwellSeconds),
      page: page ?? _currentPage,
    );
  }

  /// Reading time must only ever accrue while someone can actually see the
  /// page: without this, a document left open in a backgrounded app (or
  /// with the screen off) kept "reading" until the per-page cap ran out.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
  }

  /// Loads the PDF ourselves (rather than through a viewer widget), so
  /// this screen owns the document's lifetime directly — no more sharing
  /// it with a viewer that might dispose it out from under the reflow
  /// view when hidden.
  Future<void> _loadDocument() async {
    try {
      final bytes = await File(_document.filePath).readAsBytes();
      final doc = PdfDocument(inputBytes: bytes);
      final renderer = await PdfRegionRenderer.open(_document.filePath);
      if (!mounted) {
        doc.dispose();
        renderer.close();
        return;
      }
      final pageCount = doc.pages.count;
      final sizes = List.generate(pageCount, (i) {
        try {
          return doc.pages[i].size;
        } catch (_) {
          // A single malformed page shouldn't take down the whole document.
          return Size.zero;
        }
      });
      setState(() {
        _pdfDocument = doc;
        _renderer = renderer;
        _pageSizes = sizes;
        _pageCount = pageCount;
      });
      // Record that the document was opened even if the user never
      // changes pages (e.g. single-page PDFs, or leaving before scrolling).
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage.clamp(1, pageCount),
        pageCount: pageCount,
        reflowMode: _reflowMode,
      );
      _pdfSearchIndex.build(
        _document.filePath,
        documentId: widget.documentId,
        cache: context.read<SearchIndexCache>(),
      );
      _cacheCurrentPagePreview();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).openFailed('$e'))),
      );
    }
  }

  void _updateCurrentPage(int page) {
    if (page == _currentPage) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() => _currentPage = page);
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: page,
      pageCount: _pageCount,
      reflowMode: _reflowMode,
    );
    _cacheCurrentPagePreview();
  }

  void _onPageChangedFromView(int page) {
    _updateCurrentPage(page);
    _clearSelection();
  }

  void _onPdfViewSettled(
    double zoom,
    double scrollFraction,
    double scrollFractionX,
  ) {
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage,
      pageCount: _pageCount,
      pdfZoom: zoom,
      pdfScrollFraction: scrollFraction,
      pdfScrollFractionX: scrollFractionX,
    );
  }

  void _saveReflowFontSize() {
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage,
      pageCount: _pageCount,
      reflowFontSize: _reflowFontSize,
    );
  }

  void _onWordSelected(
    int pageIndex,
    WordHit hit,
    SentenceMatch? sentence,
    Offset screenAnchor,
  ) {
    setState(() {
      _selectedWord = hit.text;
      _selectedSentence = sentence;
      _selectedPageIndex = pageIndex;
      _selectedWordPdfBounds = hit.bounds;
      _selectedSentenceLineBoundsPdf = sentence?.lineBounds ?? const [];
      _selectionAnchor = screenAnchor;
    });
  }

  /// A tap on the page that didn't hit a word: dismisses an open
  /// translation, and otherwise does nothing — the top bar stays put.
  void _onTapEmptyArea() {
    _clearSelection();
  }

  void _clearSelection() {
    if (_selectedWord == null) return;
    setState(() {
      _selectedWord = null;
      _selectedSentence = null;
      _selectedPageIndex = null;
      _selectedWordPdfBounds = null;
      _selectedSentenceLineBoundsPdf = const [];
      _selectionAnchor = null;
    });
  }

  /// Long-press: standard select-and-copy for the word under the finger
  /// (a single word, not a full drag-handle text-range selection) —
  /// copies immediately and flashes the same highlight the tap gesture
  /// uses, without opening the translation card.
  /// A long-press-and-drag selection in the PDF view. Fires live while the
  /// finger moves and once more when it lifts; the copy/translate actions
  /// only appear for the settled selection, so they don't flicker in and
  /// out of existence mid-drag.
  void _onRangeSelected(String text, bool finished) {
    final trimmed = text.trim();
    if (finished && trimmed.isEmpty) {
      if (_rangeText != null) setState(() => _rangeText = null);
      return;
    }
    setState(() {
      _rangeText = trimmed.isEmpty ? null : trimmed;
      _rangeSettled = finished;
      // A word translation and a range selection are two different
      // answers to "what am I looking at" — showing both at once would
      // just be two cards fighting over the screen.
      if (trimmed.isNotEmpty) {
        _selectedWord = null;
        _selectedSentence = null;
        _selectedWordPdfBounds = null;
        _selectedSentenceLineBoundsPdf = const [];
      }
    });
  }

  void _clearRangeSelection() {
    _pdfViewKey.currentState?.clearRangeSelection();
    setState(() {
      _rangeText = null;
      _rangeSettled = false;
      _translateRange = false;
    });
  }

  void _copyRangeSelection() {
    final text = _rangeText;
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).copiedLabel),
        duration: const Duration(seconds: 2),
      ),
    );
    _clearRangeSelection();
  }

  /// The bar of actions for a settled range selection: how much was
  /// selected, and what can be done with it.
  Widget _buildRangeActions(
    SettingsService settings,
    TranslationService translationService,
  ) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = _rangeText!;

    if (_translateRange) {
      return Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: TranslationPanel(
          key: ValueKey(
            'range-$text-${settings.sourceLanguage}-${settings.targetLanguage}',
          ),
          word: text,
          sentenceMatch: null,
          source: settings.sourceLanguage,
          target: settings.targetLanguage,
          translationService: translationService,
          onClose: _clearRangeSelection,
        ),
      );
    }

    return Positioned(
      left: 12,
      right: 12,
      bottom: 16,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 20),
                tooltip: l10n.selectionCopy,
                onPressed: _copyRangeSelection,
              ),
              if (settings.translatorEnabled)
                IconButton(
                  icon: const Icon(Icons.translate, size: 20),
                  tooltip: l10n.selectionTranslate,
                  onPressed: () => setState(() => _translateRange = true),
                ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                tooltip: l10n.selectionClose,
                onPressed: _clearRangeSelection,
              ),
            ],
          ),
        ),
      ),
    );
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
      _reflowKey.currentState?.jumpToPage(target);
    } else {
      _pdfViewKey.currentState?.jumpToPage(target);
    }
    _updateCurrentPage(target);
  }

  /// Opens the inline search bar in the top bar (in place of the title), so
  /// the page stays visible below and a hit is highlighted right in the file.
  /// The index build is idempotent, so this is a no-op if it already started
  /// when the document opened.
  void _openSearch() {
    _clearSelection();
    _pdfSearchIndex.build(
      _document.filePath,
      documentId: widget.documentId,
      cache: context.read<SearchIndexCache>(),
    );
    setState(() => _searchOpen = true);
  }

  /// Closes the inline search bar: drops the highlight and restores the
  /// normal bar. The index itself is kept (it is the expensive part and is
  /// reused for the next search); only the active query is cleared.
  void _closeSearch() {
    _searchQuery = '';
    _reflowKey.currentState?.clearSearchHighlight();
    _pdfViewKey.currentState?.setSearchHighlight(null, null);
    setState(() => _searchOpen = false);
  }

  /// The search the [SearchBar] runs: a plain substring scan over the cached
  /// index. If the index is already built this is instant; if it is still
  /// building, hits stream in page by page as more pages finish.
  Future<void> _runSearch(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    _searchQuery = query;
    _pdfSearchIndex.build(
      _document.filePath,
      documentId: widget.documentId,
      cache: context.read<SearchIndexCache>(),
    );
    await _pdfSearchIndex.search(query, onBatch: onBatch, onDone: onDone);
  }

  void _onSearchSelect(SearchMatch match, List<SearchMatch> allMatches) {
    // Every other match on the same page as the one just landed on — washed
    // over fainter alongside it, so the reader can see at a glance where
    // this page's other hits are without losing track of the current one.
    final others = allMatches.where(
      (m) => m.pageIndex == match.pageIndex && m != match,
    );
    if (_reflowMode) {
      _reflowKey.currentState?.showSearchHighlight(
        match.pageIndex + 1,
        match.blockIndex,
        match.matchStart,
        match.matchEnd,
        others: [
          for (final m in others)
            (blockIndex: m.blockIndex, start: m.matchStart, end: m.matchEnd),
        ],
      );
    } else {
      // The original (rasterized) view has no live text to style, so its
      // highlight is a box in page-space; measure it on demand from the
      // page's real word geometry (the isolate can't send dart:ui rects).
      _ensurePdfBounds(match);
      for (final m in others) {
        _ensurePdfBounds(m);
      }
      _pdfViewKey.currentState?.setSearchHighlight(
        match.pageIndex,
        match.pdfBounds,
        otherPdfBounds: [
          for (final m in others)
            if (m.pdfBounds case final rect?) rect,
        ],
      );
      _pdfViewKey.currentState?.jumpToPage(
        match.pageIndex + 1,
        resetZoom: false,
      );
    }
    _updateCurrentPage(match.pageIndex + 1);
  }

  /// Fills in [match]'s page-space bounds for the original view's overlay, if
  /// the isolate hasn't already — the page's lines are extracted on demand and
  /// cached, so revisiting a hit is free.
  void _ensurePdfBounds(SearchMatch match) {
    if (match.pdfBounds != null) return;
    final doc = _pdfDocument;
    if (doc == null) return;
    final lines = _pageLinesCache.putIfAbsent(
      match.pageIndex,
      () => extractPageLines(doc, match.pageIndex),
    );
    final size = match.pageIndex < _pageSizes.length
        ? _pageSizes[match.pageIndex]
        : Size.zero;
    match.pdfBounds = findMatchPdfBounds(
      lines,
      _searchQuery,
      size,
      match.pageOccurrenceIndex,
    );
  }

  void _toggleReflow() {
    _clearSelection();
    setState(() => _reflowMode = !_reflowMode);
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage,
      pageCount: _pageCount,
      reflowMode: _reflowMode,
    );
    // Both views stay mounted the whole time (see build()), each keeping
    // its own scroll position — so only the view being switched TO needs
    // an explicit re-sync, in case the reader moved pages in the other
    // one since it was last visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_reflowMode) {
        _reflowKey.currentState?.jumpToPage(_currentPage);
      } else {
        // resetZoom: false — switching modes shouldn't discard a zoom
        // level the reader deliberately set for this file.
        _pdfViewKey.currentState?.jumpToPage(_currentPage, resetZoom: false);
      }
    });
  }

  Future<void> _quickLanguageSwitch() async {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.translationLanguageTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Consumer<SettingsService>(
                  builder: (context, settings, _) => Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          settings.sourceAppLanguage.flag,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(l10n.fromLanguage),
                        subtitle: Text(settings.sourceAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.sourceLanguage,
                            title: l10n.fromLanguagePickerTitle,
                          );
                          if (picked != null) {
                            settings.setSourceLanguage(picked);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_vert),
                        tooltip: l10n.swapLanguagesTooltip,
                        onPressed: settings.swapLanguages,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          settings.targetAppLanguage.flag,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(l10n.toLanguage),
                        subtitle: Text(settings.targetAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.targetLanguage,
                            title: l10n.toLanguagePickerTitle,
                          );
                          if (picked != null) {
                            settings.setTargetLanguage(picked);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(_clearSelection);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final translationService = context.read<TranslationService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // The content owns the whole screen and never reflows: the top
          // bar floats over it (see [_buildFloatingBar]) instead of taking
          // a slice of the layout, so showing and hiding the bar doesn't
          // shove the page up and down under the reader's eyes.
          Positioned.fill(
            child: SafeArea(
              child: _pdfDocument == null || _renderer == null
                  ? _buildLoadingPreview(settings)
                  : Stack(
                      children: [
                        // Both views stay mounted (just hidden via
                        // Offstage) so switching modes is an instant
                        // visibility swap, not a rebuild-from-scratch:
                        // each keeps its own scroll position and rendered
                        // page cache warm the whole time.
                        Offstage(
                          offstage: _reflowMode,
                          // Both views start below the (permanent) bar, so
                          // no line of text ever hides underneath it.
                          child: Padding(
                            padding: const EdgeInsets.only(top: _barHeight),
                            child: _buildPdfBody(settings, translationService),
                          ),
                        ),
                        Offstage(
                          offstage: !_reflowMode,
                          // Compact mode keeps its bar on screen the whole
                          // time (its controls are part of reading there),
                          // so its text starts below the bar instead of
                          // running underneath it. The PDF view needs no
                          // such offset: it scrolls, and its bar gets out
                          // of the way on its own.
                          child: Padding(
                            padding: const EdgeInsets.only(top: _barHeight),
                            child: _buildReflowBody(
                              settings,
                              translationService,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          _buildFloatingBar(l10n, settings, scheme),
        ],
      ),
    );
  }

  /// The reader's whole chrome: one compact row, floating over the page.
  ///
  /// It used to be a full AppBar *plus* a 44px second row (languages, text
  /// size, page counter) — about 100dp of permanent furniture over the
  /// text. Now everything that isn't needed constantly lives in the
  /// overflow menu, the page counter doubles as the title (tap to jump to
  /// a page), and in the PDF view the row fades out on its own once
  /// scrolling stops — like the page scrubber — so reading happens on a
  /// clean page. Rounded bottom corners and a soft shadow keep it clearly
  /// a separate surface floating above the text rather than something
  /// blending into it.
  Widget _buildFloatingBar(
    AppLocalizations l10n,
    SettingsService settings,
    ColorScheme scheme,
  ) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        // A shade off the page rather than the page colour itself, so the
        // bar reads as a separate surface floating above the text instead
        // of blending into it.
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
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                if (_searchOpen) ...[
                  Expanded(
                    child: BookSearchBar(
                      search: _runSearch,
                      onSelect: _onSearchSelect,
                      onClose: _closeSearch,
                    ),
                  ),
                ] else ...[
                  Expanded(child: _buildBarTitle(scheme)),
                  ..._buildBarActions(l10n, settings, scheme),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Page counter over the document title: the counter is the useful bit
  /// while reading (and the way into "go to page"), the title is there so
  /// you can still see what you're in.
  Widget _buildBarTitle(ColorScheme scheme) {
    return InkWell(
      onTap: _pageCount == 0 ? null : _jumpToPage,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _pageCount == 0 ? _document.title : '$_currentPage / $_pageCount',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (_pageCount > 0)
              Text(
                _document.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBarActions(
    AppLocalizations l10n,
    SettingsService settings,
    ColorScheme scheme,
  ) {
    return [
      if (_reflowMode) ...[
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.text_decrease, size: 22),
          tooltip: l10n.smallerText,
          onPressed: () {
            setState(
              () => _reflowFontSize = (_reflowFontSize - 1).clamp(13, 26),
            );
            _saveReflowFontSize();
          },
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.text_increase, size: 22),
          tooltip: l10n.largerText,
          onPressed: () {
            setState(
              () => _reflowFontSize = (_reflowFontSize + 1).clamp(13, 26),
            );
            _saveReflowFontSize();
          },
        ),
      ],
      // Translator on/off and the language pair sit right here on the bar:
      // they're the app's whole point, and burying them in a menu meant
      // that checking "am I translating, and from what into what?" took
      // two taps and a guess.
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
        onPressed: () =>
            settings.setTranslatorEnabled(!settings.translatorEnabled),
      ),
      if (settings.translatorEnabled)
        InkWell(
          onTap: _quickLanguageSwitch,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
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
          _reflowMode
              ? Icons.picture_as_pdf_outlined
              : Icons.auto_stories_outlined,
        ),
        tooltip: _reflowMode ? l10n.originalPdf : l10n.adaptToPhone,
        onPressed: _pageCount == 0 ? null : _toggleReflow,
      ),
      // The experimental split view is the only thing left that used to
      // need a menu, and it only applies in compact mode.
      if (_reflowMode && settings.translatorEnabled)
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 21,
          icon: Icon(
            Icons.splitscreen,
            color: settings.syncTranslationExperimental
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          tooltip: l10n.syncTranslationTooltip,
          onPressed: () => settings.setSyncTranslationExperimental(
            !settings.syncTranslationExperimental,
          ),
        ),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.search, size: 22),
        tooltip: l10n.searchTooltip,
        onPressed: _pageCount == 0 ? null : _openSearch,
      ),
    ];
  }

  Widget _buildLoadingPreview(SettingsService settings) {
    final bytes = _previewBytes;
    // A large PDF can take several real seconds to parse on a weak
    // device, and without an explicit background here this would
    // otherwise show straight through to the Scaffold's own background —
    // black in dark app theme — behind the (smaller, BoxFit.contain)
    // preview image, instead of the reading surface's own white default.
    return ColoredBox(
      color: settings.readingTheme.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            ColorFiltered(
              colorFilter: settings.readingTheme.pageImageFilter(
                contrast: settings.readingContrast,
                weight: settings.readingWeight,
              ),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  Widget _buildReflowBody(
    SettingsService settings,
    TranslationService translationService,
  ) {
    return ReflowPdfView(
      key: _reflowKey,
      document: _pdfDocument!,
      renderer: _renderer!,
      pageCount: _pageCount,
      initialPage: _currentPage,
      linesCache: _pageLinesCache,
      source: settings.sourceLanguage,
      target: settings.targetLanguage,
      translationService: translationService,
      fontSize: _reflowFontSize,
      readingTheme: settings.readingTheme,
      settings: settings,
      translatorEnabled: settings.translatorEnabled,
      syncTranslationExperimental: settings.syncTranslationExperimental,
      onPageChanged: _updateCurrentPage,
      onTapCenter: _onTapEmptyArea,
    );
  }

  Widget _buildPdfBody(
    SettingsService settings,
    TranslationService translationService,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            SizedBox.expand(
              child: PdfPageStackView(
                key: _pdfViewKey,
                document: _pdfDocument!,
                renderer: _renderer!,
                linesCache: _pageLinesCache,
                pageSizes: _pageSizes,
                initialPage: _currentPage,
                initialZoom: _document.pdfZoom,
                initialScrollFraction: _document.pdfScrollFraction,
                initialScrollFractionX: _document.pdfScrollFractionX,
                readingTheme: settings.readingTheme,
                readingContrast: settings.readingContrast,
                readingWeight: settings.readingWeight,
                selectedPageIndex: _selectedPageIndex,
                selectedWordPdfBounds: _selectedWordPdfBounds,
                selectedSentenceLineBoundsPdf: _selectedSentenceLineBoundsPdf,
                // Follows the reading theme, not the app's light/dark
                // scheme: the highlight sits on the (theme-filtered) page
                // image, so it has to stay legible against the reading
                // background rather than against app chrome.
                highlightColor: settings.readingTheme.accent,
                onWordSelected: settings.translatorEnabled
                    ? _onWordSelected
                    : (_, __, ___, ____) {},
                onRangeSelected: _onRangeSelected,
                onTapEmpty: _onTapEmptyArea,
                onPageChanged: _onPageChangedFromView,
                onViewSettled: _onPdfViewSettled,
              ),
            ),
            if (_selectedWord != null)
              ..._anchoredPanel(
                constraints.biggest,
                settings,
                translationService,
              ),
            if (_rangeText != null && _rangeSettled)
              _buildRangeActions(settings, translationService),
          ],
        );
      },
    );
  }

  /// Positions the translation card near [_selectionAnchor] (the actual
  /// tap point) instead of always docking it to the bottom of the
  /// screen: below the tap if there's room, above it otherwise; centered
  /// horizontally on the tap but clamped so it never runs off-screen.
  List<Widget> _anchoredPanel(
    Size viewport,
    SettingsService settings,
    TranslationService translationService,
  ) {
    const cardWidth = 320.0;
    final anchor =
        _selectionAnchor ?? Offset(viewport.width / 2, viewport.height / 2);
    final maxLeft = math.max(8.0, viewport.width - cardWidth - 8);
    final left = (anchor.dx - cardWidth / 2).clamp(8.0, maxLeft);
    final showBelow = anchor.dy < viewport.height * 0.6;

    return [
      Positioned(
        left: left,
        top: showBelow ? anchor.dy + 20 : null,
        bottom: showBelow ? null : viewport.height - anchor.dy + 20,
        width: cardWidth,
        child: TranslationPanel(
          key: ValueKey(
            '$_selectedWord-${settings.sourceLanguage}-${settings.targetLanguage}',
          ),
          word: _selectedWord!,
          sentenceMatch: _selectedSentence,
          source: settings.sourceLanguage,
          target: settings.targetLanguage,
          translationService: translationService,
          onClose: _clearSelection,
        ),
      ),
    ];
  }
}
