import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/djvu_service.dart';
import '../services/library_service.dart';
import '../services/reading_display_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import '../utils/text_search.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/djvu_page_stack_view.dart';
import '../widgets/book_search_bar.dart';
import '../widgets/reader_annotations.dart';
import '../widgets/reader_copy_menu.dart';
import '../widgets/translation_panel.dart';
import '../widgets/txt_page_view.dart';

const double _barHeight = 50;

List<ReflowBlock> _reflowDjvuText(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  final blocks = <ReflowBlock>[];
  for (final chunk in raw.split(RegExp(r'[\x00\x0b\x1d\x1f]'))) {
    final lines = chunk
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) continue;
    var text = lines.first;
    for (final line in lines.skip(1)) {
      final joinsHyphen =
          text.endsWith('-') &&
          line.isNotEmpty &&
          RegExp(r'[a-zа-яё]', caseSensitive: false).hasMatch(line[0]);
      text = joinsHyphen
          ? '${text.substring(0, text.length - 1)}$line'
          : '$text $line';
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) blocks.add(ReflowBlock.paragraph(text));
  }
  return blocks;
}

class DjvuReaderScreen extends StatefulWidget {
  const DjvuReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<DjvuReaderScreen> createState() => _DjvuReaderScreenState();
}

class _DjvuReaderScreenState extends State<DjvuReaderScreen>
    with WidgetsBindingObserver {
  late final LibraryDocument _document;
  final _textPageViewKey = GlobalKey<TxtPageViewState>();
  final _originalStackKey = GlobalKey<DjvuPageStackViewState>();

  DjvuDocument? _djvu;
  String? _error;
  int _currentPage = 1;
  bool _reflowMode = true;
  double _fontSize = 17;
  bool _textLoading = false;
  List<List<ReflowBlock>>? _textPages;
  bool _searchOpen = false;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;
  DateTime? _pageEnteredAt;

  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;

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
      (document) => document.id == widget.documentId,
    );
    _currentPage = math.max(1, _document.lastPage);
    _fontSize = _document.reflowFontSize;
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(_readingDisplay.enter(context.read<SettingsService>()));
    _open();
  }

  Future<void> _open() async {
    DjvuDocument? document;
    try {
      document = await DjvuDocument.open(_document.filePath);
      if (!mounted) {
        await document.close();
        return;
      }
      final restoredPage = _currentPage.clamp(1, document.pageCount);
      setState(() {
        _djvu = document;
        _currentPage = restoredPage;
        _textLoading = true;
      });
      unawaited(
        context.read<LibraryService>().updateProgress(
          widget.documentId,
          lastPage: restoredPage,
          pageCount: document.pageCount,
          reflowMode: true,
        ),
      );
      unawaited(_loadText(document));
    } catch (error) {
      if (document != null) await document.close();
      if (!mounted) return;
      setState(
        () => _error = error is PlatformException && error.code == 'djvu_error'
            ? AppLocalizations.of(context).djvuInvalidDocument
            : '$error',
      );
    }
  }

  Future<void> _loadText(DjvuDocument document) async {
    try {
      // DjVu text zones are lightweight compared with rendering page
      // bitmaps. Loading them once gives this format the exact same
      // paginated, theme-aware and translatable reading surface as EPUB,
      // FB2, DOCX, RTF and TXT.
      final rawPages = await Future.wait(
        List.generate(document.pageCount, document.pageText),
      );
      if (!mounted || _djvu != document) return;
      final extractedPages = rawPages
          .map(_reflowDjvuText)
          .toList(growable: false);
      final hasText = extractedPages.any((page) => page.isNotEmpty);
      final pages = hasText
          ? extractedPages
                .map(
                  (page) => page.isEmpty
                      ? <ReflowBlock>[
                          ReflowBlock.paragraph(
                            AppLocalizations.of(context).djvuNoTextLayer,
                          ),
                        ]
                      : page,
                )
                .toList(growable: false)
          : extractedPages;
      setState(() {
        _textPages = pages;
        _textLoading = false;
        // Image-only scans still open correctly: there is simply nothing
        // to reflow, so use the original page view for those documents.
        if (!hasText) _reflowMode = false;
      });
      unawaited(
        context.read<LibraryService>().updateProgress(
          widget.documentId,
          lastPage: _currentPage,
          pageCount: document.pageCount,
          reflowMode: hasText,
        ),
      );
    } catch (_) {
      if (!mounted || _djvu != document) return;
      setState(() {
        _textLoading = false;
        _reflowMode = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_readingDisplay.exit());
    _flushDwellTime();
    final document = _djvu;
    if (document != null) unawaited(document.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
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

  void _onPageChanged(int index) {
    final page = index + 1;
    if (page == _currentPage) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() {
      _currentPage = page;
      _selectedWord = null;
      _selectedSentence = null;
    });
    final document = _djvu;
    if (document == null) return;
    unawaited(
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: page,
        pageCount: document.pageCount,
        reflowMode: _reflowMode,
      ),
    );
  }

  void _changeOriginalZoom(double delta) {
    _originalStackKey.currentState?.changeZoom(delta);
  }

  /// The scan view settles (a gesture ends, a jump lands): persist the
  /// zoom, the position within the page, and the horizontal pan, exactly
  /// like the PDF reader does, so reopening this file lands the reader
  /// where they left off.
  void _onOriginalViewSettled(
    double zoom,
    double scrollFraction,
    double scrollFractionX,
  ) {
    final document = _djvu;
    if (document == null) return;
    unawaited(
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage,
        pageCount: document.pageCount,
        reflowMode: _reflowMode,
        pdfZoom: zoom,
        pdfScrollFraction: scrollFraction,
        pdfScrollFractionX: scrollFractionX,
      ),
    );
  }

  Future<void> _jumpToPage() async {
    final document = _djvu;
    if (document == null) return;
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.goToPageTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.goToPageHint(document.pageCount),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(controller.text)),
            child: Text(l10n.go),
          ),
        ],
      ),
    );
    controller.dispose();
    if (target == null) return;
    _goTo(target);
  }

  /// Turns the book to [page] (1-based), in whichever view is showing.
  void _goTo(int page) {
    final document = _djvu;
    if (document == null || page < 1 || page > document.pageCount) return;
    if (_reflowMode) {
      _textPageViewKey.currentState?.jumpToPage(page);
      _onPageChanged(page - 1);
    } else {
      _originalStackKey.currentState?.jumpToPage(page);
    }
  }

  void _changeFontSize(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(13, 26));
    final document = _djvu;
    if (document == null) return;
    unawaited(
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage,
        pageCount: document.pageCount,
        reflowMode: _reflowMode,
        reflowFontSize: _fontSize,
      ),
    );
  }

  /// Opens the inline search bar in the top bar (in place of the title), so
  /// the page stays visible below and a hit is highlighted right in the file.
  void _openSearch() {
    setState(() => _searchOpen = true);
  }

  /// Closes the inline search bar and drops the highlight.
  void _closeSearch() {
    _textPageViewKey.currentState?.clearSearchHighlight();
    setState(() => _searchOpen = false);
  }

  /// The search the [BookSearchBar] runs. DjVu's text is already in memory
  /// (no extraction), so a query is a plain substring scan delivered in one
  /// batch — no isolate, no streaming.
  Future<void> _runSearch(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    final pages = _textPages;
    if (pages == null) {
      onDone();
      return;
    }
    final texts = [
      for (final blocks in pages) [for (final b in blocks) b.text],
    ];
    final matches = searchInPages(texts, query);
    if (matches.isNotEmpty) onBatch(matches);
    onDone();
  }

  /// The page the reader is on, as text. Both views show the same page of the
  /// same book, so the original scan copies the OCR text behind it too.
  String? _copyPageText() {
    final pages = _textPages;
    if (pages == null) return null;
    final index = _currentPage - 1;
    if (index < 0 || index >= pages.length) return null;
    return reflowBlocksText(pages[index]);
  }

  String? _copyBookText() {
    final pages = _textPages;
    return pages == null ? null : reflowPagesText(pages);
  }

  void _onSearchSelect(SearchMatch match, List<SearchMatch> allMatches) {
    // A hit only ever comes from the OCR text, which the original scan view
    // has no way to draw a highlight over (it has no live text, only the
    // bitmap) — so land on the reflowed view to actually show it, the same
    // way tapping the translate button while looking at the scan does.
    _onPageChanged(match.pageIndex);
    if (!_reflowMode) _toggleReflow();
    final others = [
      for (final m in allMatches)
        if (m.pageIndex == match.pageIndex && m != match)
          (blockIndex: m.blockIndex, start: m.matchStart, end: m.matchEnd),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _textPageViewKey.currentState?.showSearchHighlight(
        match.pageIndex + 1,
        match.blockIndex,
        match.matchStart,
        match.matchEnd,
        others: others,
      );
    });
  }

  void _toggleReflow() {
    final document = _djvu;
    if (document == null) return;
    final pages = _textPages;
    if (_reflowMode) {
      setState(() {
        _reflowMode = false;
        _selectedWord = null;
        _selectedSentence = null;
      });
    } else if (pages != null && pages.any((page) => page.isNotEmpty)) {
      setState(() {
        _reflowMode = true;
        _selectedWord = null;
        _selectedSentence = null;
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _textPageViewKey.currentState?.jumpToPage(_currentPage),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).djvuNoTextLayer)),
      );
      return;
    }
    unawaited(
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage,
        pageCount: document.pageCount,
        reflowMode: _reflowMode,
      ),
    );
  }

  Future<void> _quickLanguageSwitch() async {
    final l10n = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Consumer<SettingsService>(
            builder: (context, settings, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.translationLanguageTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
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
                    if (picked != null) settings.setSourceLanguage(picked);
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
                    if (picked != null) settings.setTargetLanguage(picked);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: settings.readingTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(settings, l10n),
              ),
            ),
          ),
          _buildFloatingBar(settings, l10n),
          if (!_reflowMode && _selectedWord != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: TranslationPanel(
                key: ValueKey(
                  'djvu-$_selectedWord-${settings.sourceLanguage}-${settings.targetLanguage}',
                ),
                word: _selectedWord!,
                sentenceMatch: _selectedSentence,
                source: settings.sourceLanguage,
                target: settings.targetLanguage,
                translationService: context.read<TranslationService>(),
                onClose: () => setState(() {
                  _selectedWord = null;
                  _selectedSentence = null;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(SettingsService settings, AppLocalizations l10n) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(l10n.openFailed(error), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final document = _djvu;
    if (document == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.djvuOpening),
          ],
        ),
      );
    }
    if (_reflowMode) {
      final pages = _textPages;
      if (_textLoading || pages == null) {
        return ColoredBox(
          color: settings.readingTheme.background,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(l10n.djvuOpening),
              ],
            ),
          ),
        );
      }
      final translationService = context.read<TranslationService>();
      return TxtPageView(
        key: _textPageViewKey,
        pages: pages,
        initialPage: _currentPage,
        source: settings.sourceLanguage,
        target: settings.targetLanguage,
        translationService: translationService,
        fontSize: _fontSize,
        readingTheme: settings.readingTheme,
        settings: settings,
        translatorEnabled: settings.translatorEnabled,
        onPageChanged: (page) => _onPageChanged(page - 1),
      );
    }
    return DjvuPageStackView(
      key: _originalStackKey,
      document: document,
      initialPage: _currentPage,
      initialZoom: _document.pdfZoom,
      initialScrollFraction: _document.pdfScrollFraction,
      initialScrollFractionX: _document.pdfScrollFractionX,
      background: settings.readingTheme.background,
      imageFilter: settings.readingTheme.pageImageFilter(
        contrast: settings.readingContrast,
        weight: settings.readingWeight,
      ),
      onPageChanged: (page) => _onPageChanged(page - 1),
      onZoomChanged: (_) {},
      onViewSettled: _onOriginalViewSettled,
    );
  }

  Widget _buildFloatingBar(SettingsService settings, AppLocalizations l10n) {
    final document = _djvu;
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: settings.readingTheme.secondaryBackground,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.38),
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
                      onTap: document == null ? null : _jumpToPage,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              document == null
                                  ? _document.title
                                  : '$_currentPage / ${document.pageCount}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (document != null)
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
                  if (_reflowMode) ...[
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
                  ] else ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: const Icon(Icons.zoom_out),
                      tooltip: l10n.zoomOut,
                      onPressed: () => _changeOriginalZoom(-0.5),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: const Icon(Icons.zoom_in),
                      tooltip: l10n.zoomIn,
                      onPressed: () => _changeOriginalZoom(0.5),
                    ),
                  ],
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
                    onPressed: () {
                      // Translation works on the real reflowed OCR text. When
                      // the reader asks for it while looking at the scan,
                      // switch to that text at the same source page instead of
                      // leaving a seemingly enabled but unusable button over a
                      // bitmap.
                      if (!_reflowMode &&
                          _textPages?.any((page) => page.isNotEmpty) == true) {
                        if (!settings.translatorEnabled) {
                          settings.setTranslatorEnabled(true);
                        }
                        _toggleReflow();
                      } else {
                        settings.setTranslatorEnabled(
                          !settings.translatorEnabled,
                        );
                      }
                    },
                  ),
                  if (_reflowMode && settings.translatorEnabled)
                    InkWell(
                      onTap: _quickLanguageSwitch,
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
                      _reflowMode
                          ? Icons.image_outlined
                          : Icons.auto_stories_outlined,
                    ),
                    tooltip: _reflowMode
                        ? l10n.originalDocument
                        : l10n.adaptToPhone,
                    onPressed: document == null || _textLoading
                        ? null
                        : _toggleReflow,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.search),
                    tooltip: l10n.searchTooltip,
                    onPressed: _textPages == null ? null : _openSearch,
                  ),
                  ReaderCopyMenu(
                    actions: [
                      if (_djvu != null)
                        ...annotationMenuActions(
                          context,
                          documentId: widget.documentId,
                          currentPage: _currentPage,
                          goTo: _goTo,
                        ),
                    ],
                    pageText: _copyPageText,
                    bookText: _copyBookText,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DjvuPageLegacy extends StatefulWidget {
  const DjvuPageLegacy({
    super.key,
    required this.document,
    required this.pageIndex,
    required this.background,
    required this.imageFilter,
    required this.translatorEnabled,
    required this.onWordSelected,
    required this.onPageTurn,
    required this.onZoomChanged,
  });

  final DjvuDocument document;
  final int pageIndex;
  final Color background;
  final ColorFilter imageFilter;
  final bool translatorEnabled;
  final ValueChanged<DjvuWord> onWordSelected;
  final ValueChanged<int> onPageTurn;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<DjvuPageLegacy> createState() => _DjvuPageState();
}

class _DjvuPageState extends State<DjvuPageLegacy> {
  late final Future<DjvuPageInfo> _info = widget.document.pageInfo(
    widget.pageIndex,
  );
  late final Future<List<DjvuWord>> _words = widget.document.pageWords(
    widget.pageIndex,
  );
  final Map<int, Future<Uint8List>> _renders = {};
  final TransformationController _transformation = TransformationController();
  final Map<int, Offset> _pointers = {};
  bool _zoomed = false;
  bool _manualPinching = false;
  double _pinchStartDistance = 1;
  double _pinchStartScale = 1;
  Offset _pinchFocalPoint = Offset.zero;
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final zoomed = _transformation.value.getMaxScaleOnAxis() > 1.015;
    if (zoomed != _zoomed && mounted) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  void dispose() {
    _transformation
      ..removeListener(_onTransformChanged)
      ..dispose();
    super.dispose();
  }

  void _toggleZoom() {
    _transformation.value = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()..scaleByDouble(2, 2, 1, 1));
  }

  void changeZoom(double delta) {
    final current = _transformation.value.getMaxScaleOnAxis();
    final next = (current + delta).clamp(1.0, 4.0);
    if ((next - current).abs() < 0.001) return;
    if (next <= 1.015) {
      _transformation.value = Matrix4.identity();
      return;
    }
    final center = _viewportSize.center(Offset.zero);
    _transformation.value = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(next, next, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (!_zoomed && _pointers.length == 2) {
      final points = _pointers.values.toList(growable: false);
      _manualPinching = true;
      _pinchStartDistance = (points[0] - points[1]).distance.clamp(
        1,
        double.infinity,
      );
      _pinchStartScale = _transformation.value.getMaxScaleOnAxis();
      _pinchFocalPoint = (points[0] + points[1]) / 2;
      widget.onZoomChanged(true);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (!_manualPinching || _pointers.length < 2) return;
    final points = _pointers.values.take(2).toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    final scale = (_pinchStartScale * distance / _pinchStartDistance).clamp(
      1.0,
      4.0,
    );
    final focal = _pinchFocalPoint;
    _transformation.value = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2 && _manualPinching) {
      setState(() => _manualPinching = false);
    }
  }

  Future<void> _handleWordTap(
    TapUpDetails details,
    DjvuPageInfo info,
    BoxConstraints constraints,
  ) async {
    if (!widget.translatorEnabled) return;
    final words = await _words;
    if (!mounted || words.isEmpty) return;
    final scenePoint = _zoomed
        ? _transformation.toScene(details.localPosition)
        : details.localPosition;
    const horizontalPadding = 10.0;
    const verticalPadding = 12.0;
    final availableWidth = math.max(
      1.0,
      constraints.maxWidth - horizontalPadding * 2,
    );
    final availableHeight = math.max(
      1.0,
      constraints.maxHeight - verticalPadding * 2,
    );
    final imageWidth = math.min(
      availableWidth,
      availableHeight * info.aspectRatio,
    );
    final imageHeight = imageWidth / info.aspectRatio;
    final imageLeft = (constraints.maxWidth - imageWidth) / 2;
    final imageTop = (constraints.maxHeight - imageHeight) / 2;
    if (scenePoint.dx < imageLeft ||
        scenePoint.dx > imageLeft + imageWidth ||
        scenePoint.dy < imageTop ||
        scenePoint.dy > imageTop + imageHeight) {
      return;
    }
    final pagePoint = Offset(
      (scenePoint.dx - imageLeft) / imageWidth * info.width,
      (scenePoint.dy - imageTop) / imageHeight * info.height,
    );
    DjvuWord? hit;
    var smallestArea = double.infinity;
    for (final word in words) {
      final expanded = word.bounds.inflate(
        math.max(3, word.bounds.height * 0.18),
      );
      if (expanded.contains(pagePoint) &&
          word.bounds.width * word.bounds.height < smallestArea) {
        hit = word;
        smallestArea = word.bounds.width * word.bounds.height;
      }
    }
    if (hit != null) widget.onWordSelected(hit);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: FutureBuilder<DjvuPageInfo>(
        future: _info,
        builder: (context, infoSnapshot) {
          if (infoSnapshot.hasError) {
            return _PageError(error: '${infoSnapshot.error}');
          }
          final info = infoSnapshot.data;
          if (info == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              _viewportSize = constraints.biggest;
              final pixelRatio = MediaQuery.devicePixelRatioOf(context);
              // Keep the first paint cheap on low-end 32-bit phones. Entering
              // zoom mode requests a separate high-resolution render, so the
              // base page remains quick without becoming blurry when enlarged.
              final renderWidth = _zoomed
                  ? 1600
                  : (constraints.maxWidth * pixelRatio).round().clamp(
                      720,
                      1200,
                    );
              final renderHeight = (renderWidth / info.aspectRatio)
                  .round()
                  .clamp(1, 4000);
              final render = _renders.putIfAbsent(
                renderWidth,
                () => widget.document.renderPage(
                  widget.pageIndex,
                  width: renderWidth,
                  height: renderHeight,
                ),
              );
              return FutureBuilder<Uint8List>(
                future: render,
                builder: (context, imageSnapshot) {
                  if (imageSnapshot.hasError) {
                    return _PageError(error: '${imageSnapshot.error}');
                  }
                  final bytes = imageSnapshot.data;
                  if (bytes == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final pageImage = Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: ColorFiltered(
                            colorFilter: widget.imageFilter,
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  final viewport = _zoomed
                      ? InteractiveViewer(
                          transformationController: _transformation,
                          minScale: 1,
                          maxScale: 4,
                          panEnabled: !_manualPinching,
                          scaleEnabled: !_manualPinching,
                          boundaryMargin: const EdgeInsets.all(48),
                          clipBehavior: Clip.none,
                          child: pageImage,
                        )
                      : pageImage;
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerEnd,
                    onPointerCancel: _onPointerEnd,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (details) =>
                          _handleWordTap(details, info, constraints),
                      onDoubleTap: _toggleZoom,
                      onHorizontalDragEnd: _zoomed
                          ? null
                          : (details) {
                              final velocity =
                                  details.primaryVelocity ??
                                  details.velocity.pixelsPerSecond.dx;
                              if (velocity.abs() < 240) return;
                              widget.onPageTurn(velocity < 0 ? 1 : -1);
                            },
                      child: viewport,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _PageError extends StatelessWidget {
  const _PageError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          AppLocalizations.of(context).djvuPageFailed(error),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
