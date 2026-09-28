import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/markdown_blocks.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';
import '../utils/reflow_paginator.dart';
import '../utils/sentence_finder.dart';
import 'reading_selection_area.dart';
import 'translatable_text.dart';
import 'translation_panel.dart';

/// Plain-text counterpart to [ReflowPdfView] (see reflow_view.dart) — same
/// tap-to-translate word/sentence selection and reading-theme styling, but
/// over synthetic pages of plain paragraphs instead of PDF-derived blocks,
/// and without any of the PDF-only features (embedded images, the
/// experimental split-screen sync-translation pane).
///
/// The blocks it is given can carry more than plain paragraphs: a Markdown
/// file's headings, lists, quotes, code panels and rules are laid out here
/// too, through the style and inset hooks the paginator already measures
/// with (see [markdownStyle] and [markdownBlockInsets]). A .txt file's blocks
/// ask for none of that and come out exactly as they used to.
class TxtPageView extends StatefulWidget {
  const TxtPageView({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.onPageChanged,
    this.onNoteSelection,
  });

  /// The reader asked to keep the passage they marked as a note.
  final void Function(String text)? onNoteSelection;

  final List<List<ReflowBlock>> pages;
  final int initialPage;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;
  final ValueChanged<int> onPageChanged;

  @override
  State<TxtPageView> createState() => TxtPageViewState();
}

/// Public so the reader screen can jump this view to a specific page (via
/// a [GlobalKey]) from its own "Go to page" dialog.
class TxtPageViewState extends State<TxtPageView> {
  late final PageController _pageController;
  Size _paginationSize = Size.zero;
  double _paginationFontSize = 0;

  /// The typography the layout was measured in — see [_typography].
  TextStyle? _paginationTypography;
  List<_TextSubPage> _subPages = <_TextSubPage>[];

  // How far into the book the layout has reached. The sub-pages are laid out
  // a chunk per frame — see [_chunkBudget] — and this is the source page that
  // chunk continues from.
  int _paginatedThrough = 0;
  bool _chunkScheduled = false;

  // Where the reader is, in source pages, and a jump it is waiting for
  // because that part of the book has not been laid out yet.
  int _currentSourcePage = 0;
  int? _pendingJumpSourcePage;

  // The typography the current layout was measured with, kept so a chunk can
  // be laid out in a frame callback rather than only during build.
  TextStyle _baseStyle = const TextStyle();
  TextScaler _textScaler = TextScaler.noScaling;

  // The reading column the current layout is measured in, and the line breaks
  // remembered for it (see [ReflowLineCache]).
  double _columnWidth = 0;
  double _pageHeight = 0;
  ReflowLineCache _lineCache = ReflowLineCache();
  int _lineCacheKey = -1;

  // The search hit the reader is looking at, in source-page / block /
  // [start, end) coordinates. Only the sub-page that actually holds the block
  // is told to wash its accent over that range.
  int _hlSourcePage = -1;
  int? _hlBlockIndex;
  int? _hlStart;
  int? _hlEnd;

  // Every other match that also falls on [_hlSourcePage] — washed over
  // fainter than the current hit, on whichever sub-page each one lands on.
  List<({int blockIndex, int start, int end})> _hlOthers = const [];

  // What the translation card is showing, and — when it was opened by a tap
  // on a word — where that word is, so its page can wash it over. This lives
  // here rather than on the page because a long-press mark covers several
  // blocks at once (and can reach into the next page), and because the card
  // has to survive the page it was opened on being turned.
  int? _panelPageIndex;
  int? _panelBlockIndex;
  int? _panelWordStart;
  int? _panelWordEnd;
  String? _panelText;
  SentenceMatch? _panelSentence;

  final GlobalKey<ReadingSelectionAreaState> _selectionKey =
      GlobalKey<ReadingSelectionAreaState>();

  /// Laying the whole book out at once is what made a two-megabyte document
  /// unopenable (tens of seconds of it, in one frame, with the system
  /// declaring the app dead halfway through), so it goes a few milliseconds
  /// at a time and the reader shows the pages that are ready.
  static const _chunkBudget = Duration(milliseconds: 6);

  /// A bigger slice of the same work when the reader asked for a page that
  /// isn't laid out yet and is waiting for it.
  static const _urgentChunkBudget = Duration(milliseconds: 24);

  /// How far the layout has run ahead of the pages the reader has actually
  /// been shown before it is worth rebuilding the book to let them see the
  /// rest. Rebuilding means re-laying out the page in front of them, which is
  /// the one thing that must not happen in the middle of a swipe.
  static const _rebuildLead = 64;

  /// How many sub-pages the layout has to be ahead of the reader before a
  /// swipe is worth pausing it for.
  static const _scrollPauseLead = 8;

  /// How many sub-pages the last build showed the reader. The layout runs
  /// ahead of this; a jump has to wait for a build to catch up before it can
  /// turn to a page the PageView doesn't know about yet.
  int _builtCount = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _currentSourcePage = math.max(0, widget.initialPage - 1);
    _pendingJumpSourcePage = _currentSourcePage > 0 ? _currentSourcePage : null;
  }

  void jumpToPage(int page) => _requestJump(page - 1);

  /// Whether the page view is moving because of a jump we made ourselves.
  ///
  /// A page view only knows the length of the part of the book it has
  /// measured, so the report a jump into a book that is still arriving
  /// provokes names the last page it had measured rather than the one it
  /// moved to — and it is delivered inside the call, before anything has been
  /// laid out again. The reader is where the jump put them, which is what the
  /// jump itself records; only a report from a page they turned counts.
  bool _movingToJump = false;

  /// Jumps to the first sub-page of a source page, or asks the layout to do
  /// it as soon as that page has been reached.
  void _requestJump(int sourcePage) {
    if (sourcePage < 0 || sourcePage >= widget.pages.length) return;
    final index = _subPageIndexOf(sourcePage);
    if (index >= 0 && index < _builtCount && _pageController.hasClients) {
      _pendingJumpSourcePage = null;
      _jumpToSubPage(index);
      return;
    }
    setState(() => _pendingJumpSourcePage = sourcePage);
  }

  void _jumpToSubPage(int index) {
    _movingToJump = true;
    _pageController.jumpToPage(index);
    _movingToJump = false;
    _currentSourcePage = _subPages[index].sourcePage;
  }

  /// The sub-page that shows [sourcePage] — its first one, or the one holding
  /// a search hit that is waiting on that page. -1 while the layout has not
  /// reached it.
  int _subPageIndexOf(int sourcePage) {
    if (sourcePage >= _paginatedThrough) return -1;
    if (sourcePage == _hlSourcePage && _hlBlockIndex != null) {
      final highlighted = _highlightSubPageIndex();
      if (highlighted >= 0) return highlighted;
    }
    return _subPages.indexWhere((item) => item.sourcePage >= sourcePage);
  }

  /// Whether a jump the reader asked for can be honoured yet. Returns false
  /// (and keeps the jump waiting) while the PageView has not been rebuilt
  /// with the pages it needs: jumping past its item count would stop the
  /// reader at the last page it knows about and call that the end of the
  /// book.
  bool _applyPendingJump() {
    final target = _pendingJumpSourcePage;
    if (target == null) return false;
    if (_subPages.isEmpty) {
      // The book has nothing in it to turn to after all.
      _pendingJumpSourcePage = null;
      return true;
    }
    var index = _subPageIndexOf(target);
    if (index < 0 && _paginatedThrough >= widget.pages.length) {
      // The whole book is laid out and the page the reader asked for is not
      // in it — the closest thing to it is as good as it gets.
      index = _subPages.length - 1;
    }
    if (index < 0 || index >= _builtCount || !_pageController.hasClients) {
      return false;
    }
    _pendingJumpSourcePage = null;
    _jumpToSubPage(index);
    return true;
  }

  /// Highlights a search hit: jumps to the sub-page that shows [matchStart]
  /// of [blockIndex] on [page] (1-based) and marks the [matchStart, matchEnd)
  /// range of its text.
  void showSearchHighlight(
    int page,
    int blockIndex,
    int matchStart,
    int matchEnd, {
    List<({int blockIndex, int start, int end})> others = const [],
  }) {
    _clearPanel();
    setState(() {
      _hlSourcePage = page - 1;
      _hlBlockIndex = blockIndex;
      _hlStart = matchStart;
      _hlEnd = matchEnd;
      _hlOthers = others;
    });
    _jumpToHighlight();
  }

  void clearSearchHighlight() {
    setState(() {
      _hlSourcePage = -1;
      _hlBlockIndex = null;
      _hlStart = null;
      _hlEnd = null;
      _hlOthers = const [];
    });
  }

  void _jumpToHighlight() {
    if (_hlSourcePage < 0) return;
    _requestJump(_hlSourcePage);
  }

  int _highlightSubPageIndex() {
    for (var i = 0; i < _subPages.length; i++) {
      if (_subPages[i].sourcePage != _hlSourcePage) continue;
      for (final slice in _subPages[i].slices) {
        if (slice.blockIndex != _hlBlockIndex) continue;
        if (slice.start == slice.end) return i;
        if (_hlStart! >= slice.start && _hlStart! < slice.end) return i;
      }
    }
    return _subPages.indexWhere((p) => p.sourcePage == _hlSourcePage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// The style a block is *painted* and measured in — the reader's own
  /// typography with the block's heading level or monospace face on top of
  /// it, merged into the ambient text style exactly as Flutter will lay it
  /// out. The paginator and the text widget both go through this, so a page
  /// can't be measured for one height and shown at another.
  TextStyle _styledOn(ReflowBlock block, TextStyle base) {
    final markdown = markdownStyle(block);
    return base.merge(
      readingTextStyle(
        settings: widget.settings,
        fontSize: widget.fontSize,
        sizeFactor: markdown?.sizeFactor ?? 1.0,
        heightFactor: markdown?.heightFactor ?? 1.0,
        bold: markdown?.bold ?? false,
      ),
    );
  }

  /// The monospace face a code panel or a table is set in, on top of
  /// _styledOn's size and leading.
  TextStyle _codeStyleOn(ReflowBlock block, TextStyle base) =>
      _styledOn(block, base).copyWith(fontFamily: codeFontFamily);

  /// Everything about the body style that decides where its lines break —
  /// face, weight, size, leading — with the ink taken out, so a new reading
  /// theme or contrast repaints the book without laying it out again, and a
  /// new font or weight lays it out again instead of painting it wider than
  /// the page it was measured for.
  TextStyle _typography(BuildContext context) => _styledOn(
    const ReflowBlock.paragraph(''),
    DefaultTextStyle.of(context).style,
  ).copyWith(color: const Color(0x00000000));

  /// A block with its own emphasis set on it, for the paginator to measure
  /// exactly as [TranslatableText] will paint it.
  InlineSpan _spanForPagination(ReflowBlock block, TextStyle style) =>
      readingTextSpan(
        text: block.text,
        formatRuns: block.formatRuns,
        style: style,
        settings: widget.settings,
        readingTheme: widget.readingTheme,
      );

  /// The style the paginator measures a block with — the same one it will be
  /// painted in.
  TextStyle _styleForPagination(ReflowBlock block) => block.isCode
      ? _codeStyleOn(block, _baseStyle)
      : _styledOn(block, _baseStyle);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.readingTheme.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _paginateIfNeeded(constraints.biggest, context);
          _schedulePaginationChunk();
          _builtCount = _subPages.length;
          if (_subPages.isEmpty) return const SizedBox.shrink();
          return Stack(
            children: [
              // The mark layer sits above the pager rather than inside each
              // page: a region inside a page claims the horizontal drag for
              // itself, and the swipe that turns the page never happens.
              ReadingSelectionArea(
                key: _selectionKey,
                translatorEnabled: widget.translatorEnabled,
                onTranslateSelection: _translateSelection,
                onNoteSelection: widget.onNoteSelection,
                allText: _allText,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _subPages.length,
                  onPageChanged: (index) {
                    if (_movingToJump) return;
                    _clearPanel();
                    _currentSourcePage = _subPages[index].sourcePage;
                    widget.onPageChanged(_currentSourcePage + 1);
                  },
                  itemBuilder: (context, index) {
                    final page = _subPages[index];
                    final isHl =
                        _hlBlockIndex != null &&
                        index == _highlightSubPageIndex();
                    final base = DefaultTextStyle.of(context).style;
                    return _TxtPage(
                      key: ValueKey(index),
                      pageHeight: _pageHeight,
                      blocks: page.blocks,
                      slices: page.slices,
                      fontSize: widget.fontSize,
                      readingTheme: widget.readingTheme,
                      settings: widget.settings,
                      translatorEnabled: widget.translatorEnabled,
                      styleFor: (block) => block.isCode
                          ? _codeStyleOn(block, base)
                          : _styledOn(block, base),
                      selectedBlockIndex: index == _panelPageIndex
                          ? _panelBlockIndex
                          : null,
                      selectedWordStart: _panelWordStart,
                      selectedWordEnd: _panelWordEnd,
                      onWordTap: (blockIndex, start, end, word) =>
                          _onWordTap(index, blockIndex, start, end, word),
                      highlight: isHl
                          ? (block: _hlBlockIndex, start: _hlStart, end: _hlEnd)
                          : null,
                      otherHighlights: page.sourcePage == _hlSourcePage
                          ? _hlOthers
                          : const [],
                    );
                  },
                ),
              ),
              if (_panelText case final text?)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: TranslationPanel(
                      key: ValueKey('$text-${widget.source}-${widget.target}'),
                      word: text,
                      sentenceMatch: _panelSentence,
                      source: widget.source,
                      target: widget.target,
                      translationService: widget.translationService,
                      onClose: _clearPanel,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The reader tapped a word: show its translation and wash that word over on
  /// the page it belongs to.
  void _onWordTap(
    int pageIndex,
    int blockIndex,
    int start,
    int end,
    String word,
  ) {
    if (!widget.translatorEnabled) return;
    final sentence = findSentenceInText(
      _subPages[pageIndex].blocks[blockIndex].text,
      word,
    );
    setState(() {
      _panelPageIndex = pageIndex;
      _panelBlockIndex = blockIndex;
      _panelWordStart = start;
      _panelWordEnd = end;
      _panelText = word;
      _panelSentence = sentence;
    });
  }

  /// The page the reader is on, as one block of text — what «Копировать всё»
  /// takes, laid out with the breaks the book has rather than the ones the
  /// selection layer happens to report.
  String? _allText() {
    final pages = widget.pages;
    final index = _currentSourcePage;
    if (index < 0 || index >= pages.length) return null;
    return reflowBlocksText(pages[index]);
  }

  /// The reader marked a passage and asked what it says. A mark and a tapped
  /// word are two answers to "what am I looking at", so the word's own
  /// highlight steps aside for the card.
  void _translateSelection(String text) {
    setState(() {
      _panelPageIndex = null;
      _panelBlockIndex = null;
      _panelWordStart = null;
      _panelWordEnd = null;
      _panelSentence = null;
      _panelText = text;
    });
  }

  void _clearPanel() {
    if (_panelText == null) return;
    _selectionKey.currentState?.clearSelection();
    setState(() {
      _panelPageIndex = null;
      _panelBlockIndex = null;
      _panelWordStart = null;
      _panelWordEnd = null;
      _panelText = null;
      _panelSentence = null;
    });
  }

  /// Lays out the part of the book the reader needs right now, and asks for
  /// the rest to keep arriving a chunk per frame.
  void _paginateIfNeeded(Size size, BuildContext context) {
    final typography = _typography(context);
    if (size == _paginationSize &&
        widget.fontSize == _paginationFontSize &&
        typography == _paginationTypography &&
        MediaQuery.textScalerOf(context) == _textScaler) {
      return;
    }
    _restartPagination(size, context);
    // The page the reader is looking at has to exist in the frame that asks
    // for it, so the first chunk is laid out right here.
    _runPaginationChunk();
  }

  /// Throws the layout away—every split depends on the column it was measured
  /// in, so a resize (the keyboard, the font size) invalidates all of it—and
  /// remembers where the reader was so the new layout can put it back there
  /// as soon as it has reached that far.
  void _restartPagination(Size size, BuildContext context) {
    // A jump the reader asked for that the layout has not reached yet outranks
    // the page they are looking at: the layout is running towards it, and a
    // resize in the middle of that (closing the "go to page" dialog, most of
    // all) would otherwise throw the request away and leave them where the
    // old layout happened to have stopped.
    _pendingJumpSourcePage ??= _currentSourcePage > 0
        ? _currentSourcePage
        : null;
    _paginationSize = size;
    _paginationFontSize = widget.fontSize;
    _paginationTypography = _typography(context);
    _baseStyle = DefaultTextStyle.of(context).style;
    _textScaler = MediaQuery.textScalerOf(context);
    _columnWidth = math.min(size.width - 40, widget.fontSize * 38);
    _pageHeight = size.height - 54;
    // The measured line breaks stay valid across a height change — the
    // keyboard, above all, which used to make the reader lay the whole book
    // out again — and are worth nothing once the column or the type changed.
    final measureKey = Object.hash(
      _columnWidth,
      widget.fontSize,
      _textScaler,
      _paginationTypography,
    );
    if (measureKey != _lineCacheKey) {
      _lineCacheKey = measureKey;
      _lineCache = ReflowLineCache();
    }
    _subPages = <_TextSubPage>[];
    _paginatedThrough = 0;
  }

  /// Whether the reader is in the middle of turning a page and the layout has
  /// already run well ahead of them. Laying out the rest of the book is worth
  /// a few milliseconds of every frame — except while the page they are
  /// dragging is animating, where those milliseconds are the difference
  /// between a swipe that keeps up and one that stutters.
  bool get _pauseForScroll {
    if (_pendingJumpSourcePage != null) return false;
    if (!_pageController.hasClients) return false;
    final position = _pageController.position;
    if (!position.isScrollingNotifier.value) return false;
    final shown = (_pageController.page ?? 0).round();
    return _subPages.length - shown > _scrollPauseLead;
  }

  /// Picks the layout back up on the next frame, and keeps doing that until
  /// the whole book is done.
  void _schedulePaginationChunk() {
    if (_chunkScheduled) return;
    final waitingForJump = _pendingJumpSourcePage != null;
    if (!waitingForJump && _paginatedThrough >= widget.pages.length) return;
    _chunkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chunkScheduled = false;
      if (!mounted) return;
      if (_paginatedThrough < widget.pages.length && !_pauseForScroll) {
        _runPaginationChunk();
      }
      final jumped = _applyPendingJump();
      // Showing the reader pages they haven't asked for yet is not worth
      // disturbing them for: the book is only rebuilt once the layout has a
      // good lead on what is on screen, once a jump is waiting on it, or once
      // it has finished and the page count is final.
      final finished = _paginatedThrough >= widget.pages.length;
      if (jumped ||
          finished ||
          _subPages.length >= _builtCount + _rebuildLead ||
          _builtCount == 0) {
        setState(() {});
      }
      _schedulePaginationChunk();
    });
    // Rebuilding is not what keeps the layout going, so a frame that shows
    // the reader nothing new still has to be asked for by name.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Lays out source pages until the frame budget runs out, always at least
  /// one—less than that would be a frame of pure overhead and no page.
  void _runPaginationChunk() {
    final budget = _pendingJumpSourcePage == null
        ? _chunkBudget
        : _urgentChunkBudget;
    final watch = Stopwatch()..start();
    do {
      _paginateSourcePage(_paginatedThrough);
      _paginatedThrough++;
    } while (_paginatedThrough < widget.pages.length && watch.elapsed < budget);
  }

  void _paginateSourcePage(int sourcePage) {
    final blocks = widget.pages[sourcePage];
    final slices = paginateReflowBlocks(
      blocks: blocks,
      width: _columnWidth,
      height: _pageHeight,
      fontSize: widget.fontSize,
      styleFor: _styleForPagination,
      lineCache: _lineCache,
      insetsFor: markdownBlockInsets,
      spanFor: _spanForPagination,
      blockSpacing: 16,
      imageSpacing: _pictureSpacing,
      textScaler: _textScaler,
      // The renderer gives every slice a fixed 16px bottom margin (see the
      // per-slice Padding below), plus a little more that scales with font
      // size: each wrapped line's real painted height drifts from the
      // paginator's per-line measurement by a sub-pixel amount, and a
      // paragraph with enough wrapped lines can accumulate that into
      // several visible pixels — more of a problem the bigger the font
      // (and so the fewer characters, the more lines, per paragraph).
      trailingSpacing: 16 + widget.fontSize,
    );
    for (final slicePage in slices) {
      _subPages.add(
        _TextSubPage(sourcePage: sourcePage, blocks: blocks, slices: slicePage),
      );
    }
  }
}

/// The space a picture keeps below itself — budgeted by the paginator and
/// painted by [_TxtPage] alike.
const double _pictureSpacing = 16;

class _TextSubPage {
  const _TextSubPage({
    required this.sourcePage,
    required this.blocks,
    required this.slices,
  });
  final int sourcePage;
  final List<ReflowBlock> blocks;
  final List<ReflowSlice> slices;
}

/// One screen of reflowed text: the slices the paginator cut this page into,
/// each drawn in the style it was measured with.
///
/// It paints and lays out; what the reader does to the text it reports up to
/// [TxtPageView], which owns the translation card and the long-press mark.
class _TxtPage extends StatelessWidget {
  const _TxtPage({
    super.key,
    required this.pageHeight,
    required this.blocks,
    required this.slices,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.styleFor,
    required this.onWordTap,
    this.selectedBlockIndex,
    this.selectedWordStart,
    this.selectedWordEnd,
    this.highlight,
    this.otherHighlights = const [],
  });

  final List<ReflowBlock> blocks;
  final List<ReflowSlice> slices;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;

  /// The height the paginator filled — a picture is never set taller than
  /// the share of it the paginator gave the picture.
  final double pageHeight;

  /// The style each block is painted in — the same one it was paginated
  /// with, so this view never has to re-derive the heading sizes or the
  /// monospace face.
  final TextStyle Function(ReflowBlock block) styleFor;

  /// Called with the block and the `[start, end)` offsets of the word the
  /// reader tapped.
  final void Function(int blockIndex, int start, int end, String word)
  onWordTap;

  /// The word the translation card is answering for, in this page's terms.
  final int? selectedBlockIndex;
  final int? selectedWordStart;
  final int? selectedWordEnd;

  /// Which block's [start, end) range of text this sub-page should wash over
  /// with the search accent, or null if this sub-page holds no match.
  final ({int? block, int? start, int? end})? highlight;

  /// This sub-page's other matches (same source page, different block or
  /// range from [highlight]) — washed over fainter than the current one.
  final List<({int blockIndex, int start, int end})> otherHighlights;

  Widget _buildParagraph(int blockIndex, ReflowBlock block, ReflowSlice slice) {
    final hl = highlight;
    return TranslatableText(
      text: block.text,
      start: slice.start,
      end: slice.end,
      settings: settings,
      fontSize: fontSize,
      readingTheme: readingTheme,
      translatorEnabled: translatorEnabled,
      style: styleFor(block),
      formatRuns: block.formatRuns,
      selectedStart: blockIndex == selectedBlockIndex
          ? selectedWordStart
          : null,
      selectedEnd: blockIndex == selectedBlockIndex ? selectedWordEnd : null,
      highlight: hl?.block == blockIndex
          ? (start: hl!.start!, end: hl.end!)
          : null,
      otherHighlights: [
        for (final o in otherHighlights)
          if (o.blockIndex == blockIndex) (start: o.start, end: o.end),
      ],
      onWordTap: (start, end, word) => onWordTap(blockIndex, start, end, word),
    );
  }

  /// A Markdown rule: drawn as one hairline across the column, in the colour
  /// the theme already uses for its own separators.
  Widget _buildDivider(ReflowBlock block) {
    return SizedBox(
      height: 1,
      child: ColoredBox(
        color: readingTheme.onBackground.withValues(alpha: 0.35),
      ),
    );
  }

  /// Wraps a slice's content in everything it is set inside: its list
  /// indentation, one bar per level of blockquote, and a panel for
  /// preformatted text.
  ///
  /// Every one of these insets the text horizontally by exactly the amount
  /// [markdownBlockInsets] told the paginator to measure its lines against,
  /// and none of them adds a pixel of height — a panel taller than its own
  /// text would push the last line off the page.
  Widget _framed(ReflowBlock block, Widget content) {
    for (var level = 0; level < block.quoteDepth; level++) {
      content = Container(
        padding: const EdgeInsets.only(
          left: markdownQuoteIndent - markdownQuoteBarWidth,
        ),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: markdownQuoteBarWidth,
              color: readingTheme.accent.withValues(alpha: 0.55),
            ),
          ),
        ),
        child: content,
      );
    }
    if (block.isCode) {
      final theme = readingTheme;
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: markdownCodePadding),
        decoration: BoxDecoration(
          color: theme.onBackground.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.onBackground.withValues(alpha: 0.14)),
        ),
        child: content,
      );
    }
    if (block.indent > 0) {
      content = Padding(
        padding: EdgeInsets.only(left: block.indent * markdownListIndent),
        child: content,
      );
    }
    return content;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A line of text stops being comfortable much past 40em, so on a
        // sideways phone or a tablet the column is capped and centred
        // instead of stretching the full width of the screen.
        final available = constraints.maxWidth - 40;
        final columnWidth = math.min(available, fontSize * 38);
        final sideMargin = 20 + (available - columnWidth) / 2;
        return Padding(
          padding: EdgeInsets.fromLTRB(sideMargin, 18, sideMargin, 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < slices.length; i++)
                _buildSlice(i, slices[i], columnWidth),
            ],
          ),
        );
      },
    );
  }

  /// A picture the book carries, fitted to the column at the height the
  /// paginator reserved for it (see `paginateReflowBlocks`), with the same
  /// spacing below it that it budgeted.
  Widget _buildPicture(ReflowBlock block, double columnWidth) {
    final bounds = block.imageBounds!;
    final aspect = bounds.width > 0 ? bounds.height / bounds.width : 1.0;
    final height = math.min(columnWidth * aspect, pageHeight * 0.9);
    return Padding(
      padding: const EdgeInsets.only(bottom: _pictureSpacing),
      child: SizedBox(
        height: height,
        child: Image.memory(
          block.imageBytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // Decoded no bigger than it is shown: a cover scanned at print
          // resolution is tens of megabytes decoded at full size.
          cacheWidth: (columnWidth * 3).round(),
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildSlice(int index, ReflowSlice slice, double columnWidth) {
    final block = blocks[slice.blockIndex];
    if (block.isImage) {
      return block.imageBytes == null
          ? const SizedBox.shrink()
          : _buildPicture(block, columnWidth);
    }
    // The gap above a block is its own — a Markdown heading wants more air
    // than the next list item does — and is exactly what the paginator
    // reserved for it.
    final gap = index == 0 || !slice.isFirstOfBlock
        ? 0.0
        : (block.gapAbove ?? 16);
    final content = block.isDivider
        ? _buildDivider(block)
        : _buildParagraph(slice.blockIndex, block, slice);
    return Padding(
      key: ValueKey('${slice.blockIndex}-${slice.start}'),
      padding: EdgeInsets.only(top: gap, bottom: 16),
      child: _framed(block, content),
    );
  }
}
