import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/read_aloud.dart';
import '../services/reading_display_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../utils/reflow_builder.dart';
import '../utils/ebook_text.dart';
import '../utils/markdown_blocks.dart';
import '../utils/text_decode.dart';
import '../utils/txt_paragraphs.dart';
import '../utils/text_search.dart';
import '../widgets/language_picker_sheet.dart';
import '../utils/table_of_contents.dart';
import '../widgets/book_search_bar.dart';
import '../widgets/contents_sheet.dart';
import '../widgets/reader_annotations.dart';
import '../widgets/reader_copy_menu.dart';
import '../widgets/paged_reflow_view.dart';
import '../widgets/reflow_source.dart';
import '../widgets/text_prompt_dialog.dart';

/// Reader for plain .txt files — deliberately much simpler than
/// [ReaderScreen]: no PDF/reflow mode toggle (there's no "original" to
/// switch back to), no per-page images, no experimental sync-translation.
/// Just the same tap-to-translate reading experience, font size, and
/// reading theme, over synthetic pages (see [buildTxtPages]).
/// Height of the floating top bar (excluding the status-bar inset it sits
/// under) — matched to the PDF reader's.
const double _barHeight = 50;

class TxtReaderScreen extends StatefulWidget {
  const TxtReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<TxtReaderScreen> createState() => _TxtReaderScreenState();
}

class _TxtReaderScreenState extends State<TxtReaderScreen>
    with WidgetsBindingObserver {
  final _pageViewKey = GlobalKey<PagedReflowViewState>();

  /// The book's synthetic pages, for the compact view every format shares.
  TextBookSource? _source;
  late LibraryDocument _document;

  List<List<ReflowBlock>> _pages = const [];
  bool _loading = true;
  String? _error;

  int _currentPage = 1;

  /// The book's chapters, read off its headings once it has loaded.
  List<TocEntry> _contents = const [];

  /// The voice reading the book out, made the first time it is asked for.
  ReadAloud? _readAloud;

  /// A speech engine for tests to put in place of the device's own.
  @visibleForTesting
  static SpeechEngine Function() speechEngine = DeviceSpeechEngine.new;
  double _fontSize = 17;
  bool _searchOpen = false;

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
    _fontSize = _document.reflowFontSize;
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(_readingDisplay.enter(context.read<SettingsService>()));
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(_document.filePath).readAsBytes();
      // Every reflowable format ends up here as paragraphs, so the reading
      // experience (pagination, tap-to-translate, typography) is identical
      // whether the file was a .txt, an EPUB or a Word document.
      //
      // Markdown is the exception: its structure *is* its text, so it is
      // parsed into blocks that carry their headings, lists, quotes and code
      // with them instead of being flattened into paragraphs.
      final isMarkdown = _document.isMarkdown;
      final format =
          ebookFormatFromName(_document.format) ??
          ebookFormatFromPath(_document.filePath) ??
          EbookFormat.txt;
      // Reading a whole book's markup is seconds of work on a big one — off
      // the UI isolate, or the reader freezes (and Android offers to close
      // it) before the first page is up.
      final pages = await compute(_readBook, (
        bytes: bytes,
        isMarkdown: isMarkdown,
        format: format,
      ));
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _source = TextBookSource(pages);
        _contents = tocFromPages(pages);
        _loading = false;
        // The saved page may be from an older layout of the book with more
        // pages in it; the counter and everything that indexes by it have to
        // agree with the one being shown.
        _currentPage = _currentPage.clamp(1, pages.isEmpty ? 1 : pages.length);
      });
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage,
        pageCount: pages.length,
      );
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
    _readAloud?.dispose();
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

  /// Same rule as the PDF reader: time only counts while the app is
  /// actually in the foreground, never with the screen off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
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
      pageCount: _pages.length,
    );
  }

  void _changeFontSize(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(13, 26));
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage,
      pageCount: _pages.length,
      reflowFontSize: _fontSize,
    );
  }

  /// Opens the inline search bar in the top bar (in place of the title).
  void _openSearch() {
    setState(() => _searchOpen = true);
  }

  /// Closes the inline search bar and drops the highlight.
  void _closeSearch() {
    _pageViewKey.currentState?.clearSearchHighlight();
    setState(() => _searchOpen = false);
  }

  /// The search the [BookSearchBar] runs. Plain text has no extraction step:
  /// the pages are already in memory, so a query is a substring scan
  /// delivered in one batch.
  Future<void> _runSearch(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    final pages = _pages.map((b) => b.map((x) => x.text).toList()).toList();
    final matches = searchInPages(pages, query);
    if (matches.isNotEmpty) onBatch(matches);
    onDone();
  }

  void _onSearchSelect(SearchMatch match, List<SearchMatch> allMatches) {
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
    _updateCurrentPage(match.pageIndex + 1);
  }

  /// What the reader's «Ещё» menu offers besides copying.
  List<ReaderMenuAction> _menuActions(AppLocalizations l10n) => [
    if (_pages.isNotEmpty)
      ReaderMenuAction(
        icon: Icons.toc,
        label: l10n.contentsAction,
        onSelected: _openContents,
      ),
    if (_pages.isNotEmpty)
      ReaderMenuAction(
        icon: _isReadingAloud ? Icons.stop_circle_outlined : Icons.volume_up,
        label: _isReadingAloud ? l10n.stopReadingAction : l10n.readAloudAction,
        onSelected: _isReadingAloud ? _stopReadingAloud : _startReadingAloud,
      ),
    if (_pages.isNotEmpty)
      ...annotationMenuActions(
        context,
        documentId: widget.documentId,
        currentPage: _currentPage,
        goTo: _goTo,
      ),
  ];

  bool get _isReadingAloud => _readAloud?.isReading ?? false;

  /// Reads the book out from the page on screen, the sentence being spoken
  /// washed over and the pages turning to follow it.
  Future<void> _startReadingAloud() async {
    final settings = context.read<SettingsService>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final readAloud = _readAloud ??= ReadAloud(speechEngine())
      ..addListener(_onReadAloudChanged);
    final started = await readAloud.start(
      languageCode: settings.sourceLanguage.bcpCode,
      fromPage: _currentPage,
      pageCount: _pages.length,
      blocksOf: (page) => _pages[page - 1],
      onSentence: (page, sentence) {
        if (!mounted) return;
        _pageViewKey.currentState?.showSearchHighlight(
          page,
          sentence.blockIndex,
          sentence.start,
          sentence.end,
        );
        _updateCurrentPage(page);
      },
      onFinished: () => _pageViewKey.currentState?.clearSearchHighlight(),
    );
    if (!started) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.ttsUnavailable)));
    }
  }

  Future<void> _stopReadingAloud() async {
    await _readAloud?.stop();
    _pageViewKey.currentState?.clearSearchHighlight();
  }

  void _onReadAloudChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openContents() async {
    final page = await showContentsSheet(
      context,
      entries: _contents,
      currentPage: _currentPage,
    );
    if (page == null || !mounted) return;
    _goTo(page);
  }

  /// Turns the book to [page] (1-based), from anywhere but a search.
  void _goTo(int page) {
    if (page < 1 || page > _pages.length) return;
    _pageViewKey.currentState?.jumpToPage(page);
    _updateCurrentPage(page);
  }

  Future<void> _jumpToPage() async {
    final target = await showGoToPageDialog(
      context,
      currentPage: _currentPage,
      pageCount: _pages.length,
    );
    if (target == null) return;
    _goTo(target);
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
          // Same shape as the PDF reader: the content owns the screen and
          // the bar floats above it, so both readers look and behave alike.
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(settings, translationService),
              ),
            ),
          ),
          _buildFloatingBar(l10n, settings, scheme),
          if (_isReadingAloud)
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: FloatingActionButton.small(
                tooltip: l10n.stopReadingAction,
                onPressed: _stopReadingAloud,
                child: const Icon(Icons.stop),
              ),
            ),
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
    final crowded = readerBarIsCrowded(
      context,
      translatorOn: settings.translatorEnabled,
    );
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
                      onTap: _pages.isEmpty ? null : _jumpToPage,
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
                              _pages.isEmpty
                                  ? _document.title
                                  : '$_currentPage / ${_pages.length}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_pages.isNotEmpty)
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
                  if (!crowded) ...[
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
                    icon: const Icon(Icons.search),
                    tooltip: l10n.searchTooltip,
                    onPressed: _pages.isEmpty ? null : _openSearch,
                  ),
                  ReaderCopyMenu(
                    actions: [
                      if (crowded)
                        ...textSizeMenuActions(
                          l10n,
                          smaller: () => _changeFontSize(-1),
                          larger: () => _changeFontSize(1),
                        ),
                      ..._menuActions(l10n),
                    ],
                    pageText: () => _pages.isEmpty
                        ? null
                        : reflowBlocksText(
                            // A page saved before the book was last laid out
                            // can lie past its end now.
                            _pages[(_currentPage - 1).clamp(
                              0,
                              _pages.length - 1,
                            )],
                          ),
                    bookText: () async => reflowPagesText(_pages),
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
    TranslationService translationService,
  ) {
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
    if (_pages.isEmpty) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).noTextOnPage),
          ),
        ),
      );
    }
    return PagedReflowView(
      key: _pageViewKey,
      source: _source!,
      initialPage: _currentPage,
      sourceLanguage: settings.sourceLanguage,
      targetLanguage: settings.targetLanguage,
      translationService: translationService,
      fontSize: _fontSize,
      readingTheme: settings.readingTheme,
      settings: settings,
      translatorEnabled: settings.translatorEnabled,
      syncTranslationExperimental:
          settings.translatorEnabled && settings.syncTranslationExperimental,
      onPageChanged: _updateCurrentPage,
      onNoteSelection: (text) => addNoteFromSelection(
        context,
        documentId: widget.documentId,
        page: _currentPage,
        quote: text,
      ),
    );
  }
}

/// A book's bytes read into its synthetic pages — the [compute] entry point,
/// top-level so nothing of the reader's own state goes to the isolate with it.
List<List<ReflowBlock>> _readBook(
  ({Uint8List bytes, bool isMarkdown, EbookFormat format}) book,
) => buildTxtPagesFromBlocks(
  book.isMarkdown
      ? parseMarkdownBlocks(decodeTextFile(book.bytes))
      : extractEbookBlocks(book.bytes, book.format),
);
