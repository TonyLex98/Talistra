import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart'
    show
        ClearSelectionEvent,
        RenderParagraph,
        SelectionEdgeUpdateEvent,
        SelectionHandler,
        SelectionRegistrar,
        SelectionStatus,
        TextGranularity;
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/markdown_blocks.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';
import '../utils/reflow_paginator.dart';
import '../utils/reflow_table.dart';
import '../utils/sentence_finder.dart';
import 'reading_selection_area.dart';
import 'reflow_source.dart';
import 'translatable_text.dart';
import 'translation_panel.dart';

/// The compact reading view, for every format: a book's pages reflowed for
/// the screen and cut into sub-pages, turned like an e-book — the page
/// follows the finger (sideways or up and down) and settles forward or back
/// when it lifts, a tap near either edge turns it too, and the footer says
/// which page of the book and which part of it is on screen.
///
/// What the pages hold comes from a [ReflowSource] — a PDF's reflowed text
/// and figures, a text book's paragraphs, a scan read by OCR — so reading a
/// DjVu, an FB2 or a Markdown file looks and moves exactly like reading a
/// PDF.
class PagedReflowView extends StatefulWidget {
  const PagedReflowView({
    super.key,
    required this.source,
    required this.initialPage,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.onPageChanged,
    this.initialFraction = 0,
    this.syncTranslationExperimental = false,
    this.onTapCenter,
    this.onNoteSelection,
  });

  final ReflowSource source;

  /// 1-based.
  final int initialPage;

  /// How far into [initialPage] to open, 0 to 1 — the part of the page the
  /// reader was looking at in the other view.
  final double initialFraction;

  final TranslateLanguage sourceLanguage;
  final TranslateLanguage targetLanguage;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;

  /// Read straight through for typography (font, weight, contrast) so the
  /// reading text is styled in exactly one place — see [readingTextStyle].
  final SettingsService settings;

  /// Master switch for the translation feature; when off, words are no
  /// longer tappable and no translation UI shows up at all.
  final bool translatorEnabled;

  /// Experimental: the screen split into the page on top and a live
  /// translation of what is on it below.
  final bool syncTranslationExperimental;

  /// Called with the 1-based page whenever the reader reaches another page.
  final ValueChanged<int> onPageChanged;

  /// A tap in the middle of the page that didn't land on a word (the edges
  /// turn the page instead).
  final VoidCallback? onTapCenter;

  /// The reader asked to keep the passage they marked as a note.
  final void Function(String text)? onNoteSelection;

  @override
  State<PagedReflowView> createState() => PagedReflowViewState();
}

/// Public so a reader screen can move this view (via a [GlobalKey]) from its
/// own "go to page", contents, search and reading aloud.
class PagedReflowViewState extends State<PagedReflowView>
    with SingleTickerProviderStateMixin {
  /// Where the reader is: which page, and which sub-page inside it.
  int _pageIndex = 0;
  int _subPageIndex = 0;

  /// Where [initialFraction] still has to be applied, once the first page
  /// has been laid out and there is a sub-page count to apply it to.
  double? _pendingFraction;

  final Map<int, List<ReflowSubPage>> _subPagesCache = {};
  ReflowLineCache _lineCache = ReflowLineCache();

  /// Each table's grid at the width it is set in, measured once for the
  /// paginator and read again to paint it. Dropped with [_lineCache].
  final Map<(ReflowBlock, double), ReflowTableLayout> _tableLayouts = {};

  /// The layout the cached sub-pages were measured for: a change of any of
  /// it lays every page out again.
  Size _paginationSize = Size.zero;
  double _paginationFontSize = 0;
  TextStyle? _paginationTypography;
  TextScaler? _paginationTextScaler;
  String? _warmedPosition;

  // Page turning follows the finger: the page is dragged along with it and
  // only settles (forward, or back where it was) when the finger lifts.
  //
  // [_dragOffset] is how far the current page has been moved, in pixels,
  // along [_dragAxis]; negative means towards the next page (dragging left,
  // or up). [_incoming] is the page being pulled in behind it, built and
  // shown while the drag is in progress so there's never a blank edge. The
  // controller only finishes the movement — carrying it through or
  // snapping it back.
  late final AnimationController _turnController;
  Animation<double>? _settleAnimation;
  // Held in a notifier, not in state: a page follows the finger on every
  // pointer event, and rebuilding both pages' text for each of them made the
  // turn stutter. Only the layer that moves listens (see [_movingCard]).
  final ValueNotifier<double> _dragValue = ValueNotifier<double>(0);
  double get _dragOffset => _dragValue.value;
  set _dragOffset(double value) => _dragValue.value = value;
  Axis _dragAxis = Axis.horizontal;
  bool _dragAxisLocked = false;
  ({int page, int subPage})? _incoming;
  bool _commitOnSettle = false;

  int? _selectedBlockIndex;
  int? _selectedWordStart;
  int? _selectedWordEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  final GlobalKey<ReadingSelectionAreaState> _selectionKey =
      GlobalKey<ReadingSelectionAreaState>();

  // A mark carried across pages. The system's selection only knows the page
  // on screen, so a reader who drags a mark to the edge of the page has the
  // page turned under their finger (see [_onGlobalPointer]) and the mark goes
  // on from where the page begins; [_markAnchor] is where it was started, on
  // whichever page that was, and [_markFixed] where it stands in for that on
  // the page now on screen.
  _TextPos? _markAnchor;
  _TextPos? _markFixed;

  /// What each paragraph (or table cell) of the page on screen has marked,
  /// keyed by where its text starts — see [_listen].
  final Map<String, _SliceMark> _marks = {};
  bool _listening = false;

  /// The selection region's own registrar and status, read from inside it.
  SelectionRegistrar? _selectionRegistrar;
  ValueListenable<SelectableRegionSelectionStatus>? _selectionStatus;

  final GlobalKey _pageAreaKey = GlobalKey();
  Offset? _pointer;
  int _pointersDown = 0;
  Timer? _edgeTimer;
  int _edgeDirection = 0;

  // The search hit the reader is looking at — page, block and the [start,
  // end) range inside the block — and every other hit on that page, keyed by
  // block, washed over fainter.
  int _hlPage = -1;
  int? _hlBlockIndex;
  int? _hlStart;
  int? _hlEnd;
  Map<int, List<({int start, int end})>> _hlOthers = const {};

  /// The content box the last build laid out, so a jump can find the
  /// sub-page it lands on without running a layout of its own.
  Size _lastContentSize = Size.zero;

  Timer? _translateDebounce;
  Timer? _warmTimer;
  String? _visibleTranslation;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    _pageIndex = (widget.initialPage - 1).clamp(0, widget.source.pageCount - 1);
    if (widget.initialFraction > 0) _pendingFraction = widget.initialFraction;
    widget.source.onPageChanged = _onSourcePageChanged;
    _turnController =
        AnimationController(
            duration: const Duration(milliseconds: 220),
            vsync: this,
          )
          ..addListener(_onSettleTick)
          ..addStatusListener(_onSettleStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleTranslation());
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
  }

  @override
  void didUpdateWidget(PagedReflowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.onPageChanged = null;
      widget.source.onPageChanged = _onSourcePageChanged;
      _subPagesCache.clear();
      _pageIndex = _pageIndex.clamp(0, widget.source.pageCount - 1);
    }
    if (oldWidget.syncTranslationExperimental !=
            widget.syncTranslationExperimental ||
        oldWidget.sourceLanguage != widget.sourceLanguage ||
        oldWidget.targetLanguage != widget.targetLanguage) {
      _visibleTranslation = null;
      _scheduleTranslation();
    }
  }

  @override
  void dispose() {
    if (widget.source.onPageChanged == _onSourcePageChanged) {
      widget.source.onPageChanged = null;
    }
    _translateDebounce?.cancel();
    _warmTimer?.cancel();
    _turnController.dispose();
    _dragValue.dispose();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _edgeTimer?.cancel();
    for (final mark in _marks.values) {
      mark.notifier.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Where the reader is, from outside.
  // ---------------------------------------------------------------------

  /// The page on screen, 1-based.
  int get currentPage => _pageIndex + 1;

  /// How far down the page the text at the top of the screen sits, 0 to 1 —
  /// where the original view scrolls to when the reader switches over.
  /// Measured on the page itself where the source knows its geometry (a
  /// PDF), by the sub-page's place among the page's sub-pages otherwise.
  double get pageFraction {
    if (_lastContentSize.isEmpty) return 0;
    final subPages = _subPagesFor(_pageIndex, _lastContentSize);
    final index = _subPageIndex.clamp(0, subPages.length - 1);
    final slices = subPages[index];
    if (slices.isNotEmpty) {
      final exact = widget.source.positionOf(
        _pageIndex,
        slices.first.blockIndex,
        slices.first.start,
      );
      if (exact != null) return exact;
    }
    return subPages.length <= 1 ? 0 : index / subPages.length;
  }

  /// Turns to [page] (1-based), [fraction] of the way into it.
  void jumpToPage(int page, {double fraction = 0}) {
    final index = (page - 1).clamp(0, widget.source.pageCount - 1);
    final changed = index != _pageIndex;
    setState(() {
      _pageIndex = index;
      _subPageIndex = 0;
      _pendingFraction = fraction > 0 ? fraction : null;
      _clearSelection();
    });
    if (changed) widget.onPageChanged(index + 1);
    _scheduleTranslation();
  }

  /// Turns to the sub-page showing [matchStart] of [blockIndex] on [page]
  /// (1-based) and washes the [matchStart, matchEnd) range of its text over.
  void showSearchHighlight(
    int page,
    int blockIndex,
    int matchStart,
    int matchEnd, {
    List<({int blockIndex, int start, int end})> others = const [],
  }) {
    final index = (page - 1).clamp(0, widget.source.pageCount - 1);
    final othersByBlock = <int, List<({int start, int end})>>{};
    for (final o in others) {
      (othersByBlock[o.blockIndex] ??= []).add((start: o.start, end: o.end));
    }
    final changed = index != _pageIndex;
    setState(() {
      _pageIndex = index;
      _subPageIndex = _subPageForOffset(index, blockIndex, matchStart);
      _pendingFraction = null;
      _hlPage = index;
      _hlBlockIndex = blockIndex;
      _hlStart = matchStart;
      _hlEnd = matchEnd;
      _hlOthers = othersByBlock;
      _clearSelection();
    });
    if (changed) widget.onPageChanged(index + 1);
    _scheduleTranslation();
  }

  void clearSearchHighlight() {
    if (_hlPage < 0) return;
    setState(() {
      _hlPage = -1;
      _hlBlockIndex = null;
      _hlStart = null;
      _hlEnd = null;
      _hlOthers = const {};
    });
  }

  /// The sub-page of [pageIndex] that shows character [offset] of
  /// [blockIndex] (or the block itself, for a figure).
  int _subPageForOffset(int pageIndex, int blockIndex, int offset) {
    if (_lastContentSize.isEmpty) return 0;
    final subPages = _subPagesFor(pageIndex, _lastContentSize);
    for (var i = 0; i < subPages.length; i++) {
      for (final slice in subPages[i]) {
        if (slice.blockIndex != blockIndex) continue;
        if (slice.start == slice.end) return i;
        if (offset >= slice.start && offset < slice.end) return i;
      }
    }
    // Past the last slice of the block: its last sub-page.
    for (var i = subPages.length - 1; i >= 0; i--) {
      if (subPages[i].any((s) => s.blockIndex == blockIndex)) return i;
    }
    // A block that takes no room at all — the blank gap at the foot of a PDF
    // page, a figure that turned out to be paper — is on no sub-page: the
    // place it stands for is where the text before it ends.
    for (var b = blockIndex - 1; b >= 0; b--) {
      for (var i = subPages.length - 1; i >= 0; i--) {
        if (subPages[i].any((s) => s.blockIndex == b)) return i;
      }
    }
    for (var i = 0; i < subPages.length; i++) {
      if (subPages[i].any((s) => s.blockIndex > blockIndex)) return i;
    }
    return 0;
  }

  /// What the top of the sub-page on screen holds — the anchor the reader's
  /// place is kept by when the page is laid out again (a new size, a new
  /// font, a figure that turned out smaller than its gap).
  ({int block, int offset})? _anchor() {
    final subPages = _subPagesCache[_pageIndex];
    if (subPages == null || subPages.isEmpty) return null;
    final slices = subPages[_subPageIndex.clamp(0, subPages.length - 1)];
    if (slices.isEmpty) return null;
    return (block: slices.first.blockIndex, offset: slices.first.start);
  }

  void _onSourcePageChanged(int pageIndex) {
    if (!mounted) return;
    final anchor = pageIndex == _pageIndex ? _anchor() : null;
    setState(() {
      _subPagesCache.remove(pageIndex);
      if (anchor != null) {
        _subPageIndex = _subPageForOffset(
          pageIndex,
          anchor.block,
          anchor.offset,
        );
      }
    });
    if (pageIndex == _pageIndex) _scheduleTranslation();
  }

  // ---------------------------------------------------------------------
  // Layout.
  // ---------------------------------------------------------------------

  TextStyle _styleFor(ReflowBlock block) {
    final markdown = widget.source.styleOf(block);
    final style = DefaultTextStyle.of(context).style.merge(
      readingTextStyle(
        settings: widget.settings,
        fontSize: widget.fontSize,
        sizeFactor: markdown?.sizeFactor ?? 1.0,
        heightFactor: markdown?.heightFactor ?? 1.0,
        bold: markdown?.bold ?? false,
      ),
    );
    return markdown?.monospace == true
        ? style.copyWith(fontFamily: codeFontFamily)
        : style;
  }

  /// The span one cell of [table] is painted as, rooted in the table's own
  /// style — what [TranslatableText] draws for `[start, end)` of its text.
  InlineSpan _cellSpan(ReflowBlock table, TextStyle style, int start, int end) {
    final text = table.text.substring(start, end);
    return TextSpan(
      style: style,
      children: [
        readingTextSpan(
          text: text,
          formatRuns: [
            for (final run in table.formatRuns)
              if (run.start < end && run.end > start)
                FormatRun(
                  start: math.max(run.start, start) - start,
                  end: math.min(run.end, end) - start,
                  bold: run.bold,
                  italic: run.italic,
                  code: run.code,
                  strike: run.strike,
                  link: run.link,
                ),
          ],
          style: style,
          settings: widget.settings,
          readingTheme: widget.readingTheme,
        ),
      ],
    );
  }

  ReflowTableLayout _tableLayout(ReflowBlock table, double width) =>
      _tableLayouts.putIfAbsent((table, width), () {
        final style = _styleFor(table);
        return layoutReflowTable(
          cells: [
            for (final row in table.tableCells!)
              [
                for (final cell in row)
                  _cellSpan(table, style, cell.start, cell.end),
              ],
          ],
          maxWidth: width,
          textScaler: MediaQuery.textScalerOf(context),
        );
      });

  List<ReflowSubPage> _subPagesFor(int pageIndex, Size contentSize) {
    final typography = _styleFor(
      const ReflowBlock.paragraph(''),
    ).copyWith(color: const Color(0x00000000));
    final textScaler = MediaQuery.textScalerOf(context);
    if (contentSize != _paginationSize ||
        widget.fontSize != _paginationFontSize ||
        typography != _paginationTypography ||
        textScaler != _paginationTextScaler) {
      final anchor = _anchor();
      if (typography != _paginationTypography ||
          widget.fontSize != _paginationFontSize ||
          contentSize.width != _paginationSize.width) {
        _lineCache = ReflowLineCache();
        _tableLayouts.clear();
      }
      _subPagesCache.clear();
      _paginationSize = contentSize;
      _paginationFontSize = widget.fontSize;
      _paginationTypography = typography;
      _paginationTextScaler = textScaler;
      // The same words stay on screen however the page is cut up now.
      if (anchor != null) {
        _subPageIndex = _subPageForOffset(
          _pageIndex,
          anchor.block,
          anchor.offset,
        );
      }
    }
    return _subPagesCache.putIfAbsent(pageIndex, () {
      final blocks = widget.source.blocksFor(pageIndex);
      final pages = paginateReflowBlocks(
        blocks: blocks,
        width: contentSize.width,
        height: contentSize.height,
        fontSize: widget.fontSize,
        styleFor: _styleFor,
        spanFor: (block, style) => readingTextSpan(
          text: block.text,
          formatRuns: block.formatRuns,
          style: style,
          settings: widget.settings,
          readingTheme: widget.readingTheme,
        ),
        lineCache: _lineCache,
        insetsFor: markdownBlockInsets,
        blockSpacing: _blockGap,
        imageSpacing: _figureSpacing,
        textScaler: textScaler,
        imageSizeFor: (block) =>
            widget.source.figureSize(pageIndex, block, contentSize),
        tableLayoutFor: _tableLayout,
      );
      // Even a page with nothing on it is one (empty) sub-page, so the
      // page-turn arithmetic never has to special-case zero.
      return pages.isEmpty ? [const <ReflowSlice>[]] : pages;
    });
  }

  /// Applies [PagedReflowView.initialFraction] (or a jump's fraction) once
  /// the page it is a fraction of has been laid out.
  void _applyPendingFraction(Size contentSize) {
    final fraction = _pendingFraction;
    if (fraction == null) return;
    // Nothing to place a fraction on until the page is in: it is kept, and
    // applied when the page arrives and lays itself out.
    if (widget.source.isLoading(_pageIndex)) return;
    _pendingFraction = null;
    final count = _subPagesFor(_pageIndex, contentSize).length;
    // The words that were at the top of the screen, where the page knows
    // where its words are; otherwise the same share of the way through.
    final exact = widget.source.offsetAt(_pageIndex, fraction);
    _subPageIndex = exact != null
        ? _subPageForOffset(_pageIndex, exact.block, exact.offset)
        : (fraction * count).floor().clamp(0, count - 1);
  }

  // ---------------------------------------------------------------------
  // Page turning.
  // ---------------------------------------------------------------------

  /// The page one step away in [direction] (+1 forward, -1 back), or null
  /// at the very start or end of the book.
  ({int page, int subPage})? _neighbour(int direction, Size contentSize) {
    final subPages = _subPagesFor(_pageIndex, contentSize);
    var page = _pageIndex;
    var subPage = _subPageIndex + direction;
    if (subPage >= subPages.length) {
      if (page + 1 >= widget.source.pageCount) return null;
      page += 1;
      subPage = 0;
    } else if (subPage < 0) {
      if (page == 0) return null;
      page -= 1;
      // Land on the *last* sub-page of the previous page, so going back
      // continues reading backwards instead of skipping to its top.
      subPage = _subPagesFor(page, contentSize).length - 1;
    }
    return (page: page, subPage: subPage);
  }

  /// Movement since the finger started, until it is enough to say which way
  /// the reader is turning (see [_onDragUpdate]).
  Offset _axisProbe = Offset.zero;

  /// How far the finger has dragged the page, before the resistance at the
  /// end of the book is applied to it for showing.
  double _rawDrag = 0;

  void _onDragStart() {
    _turnController.stop();
    _rawDrag = _dragOffset;
    _dragAxisLocked = false;
    _axisProbe = Offset.zero;
    _settleAnimation = null;
  }

  /// Moves the page with the finger. The axis is decided once the finger has
  /// gone a few pixels — by where it has gone in all, not by its first twitch
  /// — and then held for the rest of the gesture, so a slightly diagonal
  /// swipe doesn't wobble between sideways and upwards. What the finger did
  /// while that was being decided is not lost: the page starts under it.
  void _onDragUpdate(Offset delta, Size contentSize, Size viewport) {
    if (!_dragAxisLocked) {
      _axisProbe += delta;
      if (_axisProbe.distance < 4) return;
      _dragAxis = _axisProbe.dx.abs() >= _axisProbe.dy.abs()
          ? Axis.horizontal
          : Axis.vertical;
      _dragAxisLocked = true;
      delta = _axisProbe;
    }
    final movement = _dragAxis == Axis.horizontal ? delta.dx : delta.dy;
    _rawDrag += movement;
    // Left or up is forward, right or down is back.
    final direction = _rawDrag < 0 ? 1 : -1;
    final incoming = _neighbour(direction, contentSize);
    // Nothing there to turn to: the page still gives a little, so the edge
    // of the book is something you feel rather than a dead swipe.
    final offset = incoming == null ? _rawDrag * 0.3 : _rawDrag;
    final extent = _dragExtent(viewport);
    // Only a change of the page pulled in behind (the finger crossing where
    // it started) rebuilds anything; moving along just moves the layers.
    if (incoming != _incoming) {
      setState(() {
        _incoming = incoming;
        _dragOffset = offset.clamp(-extent, extent);
      });
    } else {
      _dragOffset = offset.clamp(-extent, extent);
    }
  }

  void _onDragEnd(double velocity, Size viewport) {
    final extent = _dragExtent(viewport);
    if (_incoming == null || _dragOffset == 0) {
      _settleTo(0, commit: false);
      return;
    }
    // Either far enough, or thrown hard enough in the direction of travel.
    final movedEnough = _dragOffset.abs() > extent * 0.26;
    final flung = velocity.abs() > 420 && velocity.sign == _dragOffset.sign;
    final stalled = velocity.abs() > 420 && velocity.sign != _dragOffset.sign;
    if ((movedEnough && !stalled) || flung) {
      _settleTo(_dragOffset.sign * extent, commit: true);
    } else {
      _settleTo(0, commit: false);
    }
  }

  double _dragExtent(Size viewport) =>
      _dragAxis == Axis.horizontal ? viewport.width : viewport.height;

  void _settleTo(double target, {required bool commit}) {
    _commitOnSettle = commit;
    _settleAnimation = Tween<double>(begin: _dragOffset, end: target).animate(
      CurvedAnimation(parent: _turnController, curve: Curves.easeInOutCubic),
    );
    _turnController.forward(from: 0);
  }

  void _onSettleTick() {
    final animation = _settleAnimation;
    if (animation == null) return;
    _dragOffset = animation.value;
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final target = _incoming;
    final commit = _commitOnSettle;
    _settleAnimation = null;
    _commitOnSettle = false;
    var pageChanged = false;
    setState(() {
      _dragOffset = 0;
      _incoming = null;
      if (commit && target != null) {
        pageChanged = target.page != _pageIndex;
        _pageIndex = target.page;
        _subPageIndex = target.subPage;
        _clearSelection();
      }
    });
    if (pageChanged) widget.onPageChanged(_pageIndex + 1);
    if (commit) _scheduleTranslation();
  }

  /// Lays the neighbouring sub-pages out before a gesture begins, so their
  /// pagination doesn't compete with the opening frames of a swipe.
  void _warmNeighbourPages(Size contentSize) {
    final position =
        '$_pageIndex:$_subPageIndex:${contentSize.width}:${contentSize.height}:$_paginationFontSize';
    if (_warmedPosition == position) return;
    _warmedPosition = position;
    _warmTimer?.cancel();
    // The pages around this one, laid out a page at a time once the reader
    // has settled on it — each in a step of its own, so that none of them
    // holds up a frame, and none is laid out at all for a reader who is
    // already turning on.
    final steps = <void Function()>[
      () => _neighbour(1, contentSize),
      () => _neighbour(-1, contentSize),
      for (var d = 2; d <= 3; d++)
        () {
          final page = _pageIndex + d;
          if (page < widget.source.pageCount &&
              !widget.source.isLoading(page)) {
            _subPagesFor(page, contentSize);
          }
        },
    ];
    void next(int step, Duration wait) {
      if (step >= steps.length) return;
      _warmTimer = Timer(wait, () {
        if (!mounted || _warmedPosition != position) return;
        steps[step]();
        next(step + 1, const Duration(milliseconds: 50));
      });
    }

    next(0, const Duration(milliseconds: 120));
  }

  /// Turns a page without a drag — the edge tap zones.
  void _turn(int delta, Size contentSize, Size viewport) {
    if (_turnController.isAnimating) return;
    final incoming = _neighbour(delta, contentSize);
    if (incoming == null) return;
    _dragAxis = Axis.horizontal;
    setState(() => _incoming = incoming);
    _settleTo(
      delta > 0 ? -_dragExtent(viewport) : _dragExtent(viewport),
      commit: true,
    );
  }

  void _clearSelection() {
    _selectedBlockIndex = null;
    _selectedWordStart = null;
    _selectedWordEnd = null;
    _selectedWord = null;
    _selectedSentence = null;
    _markAnchor = null;
    _markFixed = null;
    _selectionKey.currentState?.clearSelection();
  }

  // ---------------------------------------------------------------------
  // A mark dragged on past the page.
  // ---------------------------------------------------------------------

  /// How long a finger marking text has to rest by an edge of the page for
  /// the page to turn under it.
  static const _edgeDwell = Duration(milliseconds: 550);

  /// [child] (the text of [blockIndex] from [start] to [end] on [pageIndex])
  /// reporting what of it is marked, when it is on the page being read.
  Widget _listen(
    int pageIndex,
    int blockIndex,
    int start,
    int end,
    Widget child,
  ) {
    if (!_listening) return child;
    final key = '$pageIndex:$blockIndex:$start';
    final mark = _marks.putIfAbsent(
      key,
      () => _SliceMark(
        notifier: SelectionListenerNotifier(),
        key: GlobalKey(),
        page: pageIndex,
        block: blockIndex,
        start: start,
        end: end,
      ),
    );
    return KeyedSubtree(
      key: mark.key,
      child: SelectionListener(selectionNotifier: mark.notifier, child: child),
    );
  }

  /// The marks of the page on screen, in reading order.
  List<_SliceMark> _visibleMarks() {
    final marks = [
      for (final mark in _marks.values)
        if (mark.page == _pageIndex &&
            mark.notifier.registered &&
            mark.key.currentContext != null)
          mark,
    ]..sort((a, b) => a.pos(a.start).compareTo(b.pos(b.start)));
    return marks;
  }

  /// Forgets what the paragraphs of pages no longer on screen reported.
  void _dropStaleMarks() {
    _marks.removeWhere((_, mark) {
      if (mark.page == _pageIndex && mark.key.currentContext != null) {
        return false;
      }
      mark.notifier.dispose();
      return true;
    });
  }

  /// The part of the page on screen that is marked, in the page's own terms.
  ({_TextPos start, _TextPos end})? _visibleMark() {
    _TextPos? start;
    _TextPos? end;
    for (final mark in _visibleMarks()) {
      final details = mark.notifier.selection;
      final range = details.range;
      if (details.status != SelectionStatus.uncollapsed || range == null) {
        continue;
      }
      final from = mark.pos(
        mark.start + math.min(range.startOffset, range.endOffset),
      );
      final to = mark.pos(
        mark.start + math.max(range.startOffset, range.endOffset),
      );
      if (start == null || from.compareTo(start) < 0) start = from;
      if (end == null || to.compareTo(end) > 0) end = to;
    }
    if (start == null || end == null) return null;
    return (start: start, end: end);
  }

  /// The text of a mark that runs past the page on screen, from wherever it
  /// was started to wherever it has been dragged — or null for a mark that
  /// is all on this page, which the selection region reads for itself.
  String? _carriedMarkText() {
    final anchor = _markAnchor;
    final fixed = _markFixed;
    if (anchor == null || fixed == null) return null;
    final visible = _visibleMark();
    // A mark that no longer reaches the place standing in for its start is a
    // new one, made on this page.
    if (visible == null ||
        visible.start.compareTo(fixed) > 0 ||
        visible.end.compareTo(fixed) < 0) {
      _markAnchor = null;
      _markFixed = null;
      return null;
    }
    final start = anchor.compareTo(visible.start) < 0 ? anchor : visible.start;
    final end = anchor.compareTo(visible.end) > 0 ? anchor : visible.end;
    return _textBetween(start, end);
  }

  /// The book's text from [from] to [to], a blank line between blocks.
  String _textBetween(_TextPos from, _TextPos to) {
    final parts = <String>[];
    for (var page = from.page; page <= to.page; page++) {
      final blocks = widget.source.blocksFor(page);
      final first = page == from.page ? from.block : 0;
      final last = page == to.page ? to.block : blocks.length - 1;
      for (var i = first; i <= last && i < blocks.length; i++) {
        final block = blocks[i];
        if (block.isImage || block.isDivider) continue;
        final text = block.text;
        final start = page == from.page && i == from.block
            ? from.offset.clamp(0, text.length)
            : 0;
        final end = page == to.page && i == to.block
            ? to.offset.clamp(start, text.length)
            : text.length;
        final part = text.substring(start, end).trim();
        if (part.isNotEmpty) parts.add(part);
      }
    }
    return parts.join('\n\n');
  }

  @visibleForTesting
  String? get carriedSelectionText => _carriedMarkText();

  void _onGlobalPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      _pointersDown++;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointersDown = math.max(0, _pointersDown - 1);
    }
    if (_pointersDown != 1 || event is PointerUpEvent) {
      _pointer = null;
      _stopEdgeTimer();
      return;
    }
    _pointer = event.position;
    final direction = _edgeDirectionAt(event.position);
    if (direction == 0 || !_markBeingDragged) {
      _stopEdgeTimer();
      return;
    }
    if (_edgeTimer != null && direction == _edgeDirection) return;
    _stopEdgeTimer();
    _edgeDirection = direction;
    _edgeTimer = Timer(_edgeDwell, _onEdgeDwell);
  }

  void _stopEdgeTimer() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeDirection = 0;
  }

  /// Whether the reader is dragging a mark (or one of its handles) right now.
  bool get _markBeingDragged =>
      _selectionStatus?.value == SelectableRegionSelectionStatus.changing;

  /// +1 when [position] is at the page's end — its right edge, or the
  /// bottom below the text — -1 at its start, 0 anywhere else.
  int _edgeDirectionAt(Offset position) {
    final box = _pageAreaKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return 0;
    final local = box.globalToLocal(position);
    final size = box.size;
    if (local.dx < -20 ||
        local.dy < -20 ||
        local.dx > size.width + 20 ||
        local.dy > size.height + 20) {
      return 0;
    }
    const side = 28.0;
    final bottom = _footerHeight + _pagePadding.bottom + _cardInset + 6;
    final top = _pagePadding.top + _cardInset;
    if (local.dx > size.width - side || local.dy > size.height - bottom) {
      return 1;
    }
    if (local.dx < side || local.dy < top) return -1;
    return 0;
  }

  void _onEdgeDwell() {
    final direction = _edgeDirection;
    _edgeTimer = null;
    if (!mounted || !_markBeingDragged || _pointer == null) return;
    final contentSize = _lastContentSize;
    if (contentSize.isEmpty || _turnController.isAnimating) return;
    final target = _neighbour(direction, contentSize);
    if (target == null) return;
    final visible = _visibleMark();
    if (visible == null && _markAnchor == null) return;
    // Where the mark was started: the end the finger isn't dragging.
    _markAnchor ??= direction > 0 ? visible!.start : visible!.end;
    final pageChanged = target.page != _pageIndex;
    setState(() {
      _pageIndex = target.page;
      _subPageIndex = target.subPage;
      _selectedBlockIndex = null;
      _selectedWordStart = null;
      _selectedWordEnd = null;
    });
    if (pageChanged) widget.onPageChanged(_pageIndex + 1);
    // Two frames on: the first lays the new page out, and the selection
    // region takes in its paragraphs at the end of it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _dropStaleMarks();
        _continueMark(direction);
      });
      WidgetsBinding.instance.scheduleFrame();
      // Resting there longer turns the next page too.
      if (_pointer != null && _edgeDirectionAt(_pointer!) == direction) {
        _edgeDirection = direction;
        _edgeTimer = Timer(_edgeDwell, _onEdgeDwell);
      }
    });
  }

  /// Marks the page just turned to from where the mark comes into it — its
  /// start going forward, its end going back, or the mark's own start if
  /// that is on it — to the finger.
  void _continueMark(int direction) {
    final registrar = _selectionRegistrar;
    final pointer = _pointer;
    final anchor = _markAnchor;
    if (registrar is! SelectionHandler || pointer == null || anchor == null) {
      return;
    }
    final handler = registrar as SelectionHandler;
    final marks = _visibleMarks();
    if (marks.isEmpty) return;
    final pageStart = marks.first.pos(marks.first.start);
    final pageEnd = marks.last.pos(marks.last.end);
    final fixed = anchor.compareTo(pageStart) < 0
        ? pageStart
        : anchor.compareTo(pageEnd) > 0
        ? pageEnd
        : anchor;
    final point = _globalPointOf(fixed, marks);
    if (point == null) return;
    _markFixed = fixed;
    handler.dispatchSelectionEvent(const ClearSelectionEvent());
    handler.dispatchSelectionEvent(
      SelectionEdgeUpdateEvent.forStart(globalPosition: point),
    );
    handler.dispatchSelectionEvent(
      SelectionEdgeUpdateEvent.forEnd(
        globalPosition: pointer,
        granularity: TextGranularity.word,
      ),
    );
  }

  /// Where on screen character [pos] of the page on screen is drawn: the
  /// middle of its line, at its left edge.
  Offset? _globalPointOf(_TextPos pos, List<_SliceMark> marks) {
    for (final mark in marks) {
      if (mark.block != pos.block ||
          pos.offset < mark.start ||
          pos.offset > mark.end) {
        continue;
      }
      final paragraph = _paragraphIn(mark.key.currentContext);
      if (paragraph == null || !paragraph.hasSize) return null;
      final position = TextPosition(offset: pos.offset - mark.start);
      final caret = paragraph.getOffsetForCaret(position, Rect.zero);
      final height = paragraph.getFullHeightForCaret(position);
      // A hair inside the character, so the edge lands before it rather than
      // after the one it follows.
      return paragraph.localToGlobal(caret + Offset(1, height / 2));
    }
    return null;
  }

  static RenderParagraph? _paragraphIn(BuildContext? context) {
    RenderParagraph? found;
    void visit(RenderObject object) {
      if (found != null) return;
      if (object is RenderParagraph) {
        found = object;
        return;
      }
      object.visitChildren(visit);
    }

    final root = context?.findRenderObject();
    if (root != null) visit(root);
    return found;
  }

  /// The reader marked a passage and asked what it says. The card answers
  /// for the whole mark, so the word highlight steps aside.
  void _translateSelection(String text) {
    setState(() {
      _selectedBlockIndex = null;
      _selectedWordStart = null;
      _selectedWordEnd = null;
      _selectedSentence = null;
      _selectedWord = text;
    });
  }

  void _onWordTap(int blockIndex, int start, int end, String word) {
    if (!widget.translatorEnabled) return;
    final blocks = widget.source.blocksFor(_pageIndex);
    if (blockIndex >= blocks.length) return;
    setState(() {
      _selectedBlockIndex = blockIndex;
      _selectedWordStart = start;
      _selectedWordEnd = end;
      _selectedWord = word;
      _selectedSentence = findSentenceInText(blocks[blockIndex].text, word);
    });
  }

  // ---------------------------------------------------------------------
  // Sync translation of whatever is on screen.
  // ---------------------------------------------------------------------

  void _scheduleTranslation() {
    if (!widget.syncTranslationExperimental) return;
    _translateDebounce?.cancel();
    _translateDebounce = Timer(
      const Duration(milliseconds: 250),
      _translateVisible,
    );
  }

  Future<void> _translateVisible() async {
    final size = _paginationSize;
    if (size == Size.zero || !mounted) return;
    final subPages = _subPagesFor(_pageIndex, size);
    if (_subPageIndex >= subPages.length) return;
    final blocks = widget.source.blocksFor(_pageIndex);
    final text = _textOfSubPage(subPages[_subPageIndex], blocks);
    if (text.trim().isEmpty) {
      setState(() => _visibleTranslation = '');
      return;
    }
    setState(() => _translating = true);
    try {
      final result = await widget.translationService.translate(
        text: text,
        source: widget.sourceLanguage,
        target: widget.targetLanguage,
      );
      if (mounted) {
        setState(() {
          _visibleTranslation = result.translated;
          _translating = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _translating = false);
    }
  }

  String _textOfSubPage(ReflowSubPage subPage, List<ReflowBlock> blocks) {
    final buffer = StringBuffer();
    for (final slice in subPage) {
      if (slice.blockIndex >= blocks.length) continue;
      final block = blocks[slice.blockIndex];
      if (block.isImage || block.isDivider) continue;
      if (buffer.isNotEmpty) buffer.write(slice.isFirstOfBlock ? '\n\n' : ' ');
      buffer.write(block.text.substring(slice.start, slice.end).trim());
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------
  // Rendering.
  // ---------------------------------------------------------------------

  static const _pagePadding = EdgeInsets.fromLTRB(20, 16, 20, 8);
  static const double _footerHeight = 22;

  /// The room between blocks, and around a figure — shared by the
  /// paginator's budget and the painted page.
  static const double _blockGap = 16;
  static const double _figureSpacing = 20;

  /// Corner radius of a page card, and the gap around it that lets its
  /// shadow show.
  static const _cardRadius = 16.0;
  static const _cardInset = 3.0;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // A shade behind the cards, so the gap around a page reads as depth
      // rather than as a seam in one flat sheet.
      color: widget.readingTheme.secondaryBackground,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final paneHeight = widget.syncTranslationExperimental
              ? constraints.maxHeight / 2 - 1
              : constraints.maxHeight;
          // A line of text stops being comfortable past roughly 40em; on a
          // sideways phone or a tablet the column is capped and centred.
          // The card's own inset eats into the space the text has, and
          // pagination has to know that or the last line spills past the
          // bottom of the card.
          final available =
              constraints.maxWidth - _pagePadding.horizontal - _cardInset * 2;
          final columnWidth = math.min(available, widget.fontSize * 38);
          final sideMargin = (available - columnWidth) / 2;
          final contentSize = Size(
            columnWidth,
            // A few pixels of slack under the card inset, for the fraction
            // of a pixel painting and measuring can round apart per line.
            paneHeight -
                _pagePadding.vertical -
                _footerHeight -
                _cardInset * 2 -
                8,
          );
          if (contentSize.width <= 0 || contentSize.height <= 0) {
            return const SizedBox.shrink();
          }
          _lastContentSize = contentSize;
          widget.source.focusOn(_pageIndex);
          _subPagesFor(_pageIndex, contentSize);
          _applyPendingFraction(contentSize);
          _warmNeighbourPages(contentSize);

          // The mark layer sits above the turnable area rather than inside a
          // page card: a selection region inside one claims a horizontal drag
          // for itself, and the swipe meant to turn the page never gets there.
          final reader = ReadingSelectionArea(
            key: _selectionKey,
            translatorEnabled: widget.translatorEnabled,
            onTranslateSelection: _translateSelection,
            onNoteSelection: widget.onNoteSelection,
            allText: () =>
                reflowBlocksText(widget.source.blocksFor(_pageIndex)),
            markedText: _carriedMarkText,
            child: Builder(
              builder: (inside) {
                _selectionRegistrar = inside
                    .getInheritedWidgetOfExactType<SelectionRegistrarScope>()
                    ?.registrar;
                _selectionStatus = SelectableRegionSelectionStatusScope.maybeOf(
                  inside,
                );
                return _buildTurnableArea(constraints, contentSize, sideMargin);
              },
            ),
          );
          if (!widget.syncTranslationExperimental) return reader;
          return Column(
            children: [
              SizedBox(height: paneHeight, child: reader),
              Divider(height: 1, color: widget.readingTheme.readingDivider),
              Expanded(child: _buildTranslationPane(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTurnableArea(
    BoxConstraints constraints,
    Size contentSize,
    double sideMargin,
  ) {
    final viewport = Size(constraints.maxWidth, constraints.maxHeight);
    void onTapUp(TapUpDetails details) {
      if (_selectedWord != null) {
        setState(_clearSelection);
        return;
      }
      final x = details.localPosition.dx;
      if (x < viewport.width * 0.16) {
        _turn(-1, contentSize, viewport);
      } else if (x > viewport.width * 0.84) {
        _turn(1, contentSize, viewport);
      } else {
        widget.onTapCenter?.call();
      }
    }

    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        // A pan, not separate horizontal/vertical drags: the page follows
        // the finger either way — left or up for the next page, right or
        // down for the previous one.
        _PageTurnRecognizer:
            GestureRecognizerFactoryWithHandlers<_PageTurnRecognizer>(
              () => _PageTurnRecognizer(debugOwner: this),
              (instance) {
                instance
                  ..onStart = ((_) => _onDragStart())
                  ..onUpdate = ((details) =>
                      _onDragUpdate(details.delta, contentSize, viewport))
                  ..onEnd = ((details) => _onDragEnd(
                    _dragAxis == Axis.horizontal
                        ? details.velocity.pixelsPerSecond.dx
                        : details.velocity.pixelsPerSecond.dy,
                    viewport,
                  ));
              },
            ),
        // Edge taps turn pages too — the standard e-reader alternative to
        // swiping, and much easier one-handed. The middle is left alone so
        // a tap on a word still translates it.
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (instance) => instance.onTapUp = onTapUp,
            ),
      },
      child: ClipRect(
        key: _pageAreaKey,
        child: Stack(
          children: [
            // Both cards move by exactly the same amount, so they travel as
            // one strip and never overlap: the page being left slides out as
            // the next one slides in, like cards dealt side by side.
            _movingCard(
              viewport: viewport,
              behind: false,
              child: _buildSubPage(
                _pageIndex,
                _subPageIndex,
                contentSize,
                sideMargin,
              ),
            ),
            if (_incoming case final incoming?)
              _movingCard(
                viewport: viewport,
                behind: true,
                child: _buildSubPage(
                  incoming.page,
                  incoming.subPage,
                  contentSize,
                  sideMargin,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A page card that follows the drag. [child], the page itself, is built
  /// once and kept on a layer of its own, so a turn only ever moves that
  /// layer: nothing about the page is laid out or painted again per frame.
  /// [behind] is the page being pulled in, one screen away from the other.
  Widget _movingCard({
    required Size viewport,
    required bool behind,
    required Widget child,
  }) {
    final card = RepaintBoundary(child: child);
    final pixel = MediaQuery.devicePixelRatioOf(context);
    return Positioned.fill(
      child: ValueListenableBuilder<double>(
        valueListenable: _dragValue,
        child: card,
        builder: (context, drag, page) {
          final extent = _dragExtent(viewport);
          final travelled = behind
              ? drag + (drag < 0 ? extent : -extent)
              : drag;
          // Whole device pixels only: between them, text drawn on a layer
          // is resampled every frame and shimmers.
          final snapped = (travelled * pixel).roundToDouble() / pixel;
          final progress = extent <= 0
              ? 0.0
              : (drag.abs() / extent).clamp(0.0, 1.0);
          return Transform.translate(
            offset: _offsetFor(snapped),
            child: _card(
              elevation: behind ? 0.35 + 0.35 * progress : 0.35,
              child: page!,
            ),
          );
        },
      ),
    );
  }

  /// One page as a card: its own paper, rounded corners and a shadow that
  /// deepens as it lifts away from the page underneath.
  Widget _card({required Widget child, required double elevation}) {
    return Padding(
      padding: const EdgeInsets.all(_cardInset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.readingTheme.background,
          borderRadius: BorderRadius.circular(_cardRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10 + 0.16 * elevation),
              blurRadius: 8 + 22 * elevation,
              offset: Offset(0, 2 + 6 * elevation),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_cardRadius),
          child: child,
        ),
      ),
    );
  }

  Offset _offsetFor(double value) =>
      _dragAxis == Axis.horizontal ? Offset(value, 0) : Offset(0, value);

  Widget _buildSubPage(
    int pageIndex,
    int subPageIndex,
    Size contentSize,
    double sideMargin,
  ) {
    final blocks = widget.source.blocksFor(pageIndex);
    final subPages = _subPagesFor(pageIndex, contentSize);
    final index = subPageIndex.clamp(0, subPages.length - 1);
    final slices = subPages[index];
    final footer = TextStyle(
      fontSize: 11,
      color: widget.readingTheme.onBackground.withValues(alpha: 0.45),
    );
    // Only the page being read reports what is marked on it (see
    // [_marks]); the one being pulled in behind it during a turn doesn't.
    final listening = _listening;
    _listening =
        pageIndex == _pageIndex &&
        index == _subPageIndex.clamp(0, subPages.length - 1);
    final List<Widget> sliceWidgets;
    try {
      sliceWidgets = [
        for (var i = 0; i < slices.length; i++)
          _buildSlice(
            pageIndex,
            blocks,
            slices[i],
            contentSize,
            isFirst: i == 0,
          ),
      ];
    } finally {
      _listening = listening;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding:
                _pagePadding.add(EdgeInsets.symmetric(horizontal: sideMargin))
                    as EdgeInsets,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: blocks.isEmpty && widget.source.isLoading(pageIndex)
                      ? const Center(
                          child: SizedBox.square(
                            dimension: 26,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : blocks.isEmpty
                      ? Center(
                          child: Text(
                            AppLocalizations.of(context).noTextOnPage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: widget.readingTheme.onBackground,
                            ),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: sliceWidgets,
                        ),
                ),
                SizedBox(
                  height: _footerHeight,
                  child: Center(
                    child: Text(
                      '${pageIndex + 1} · ${index + 1}/${subPages.length}',
                      style: footer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_selectedWord != null && pageIndex == _pageIndex)
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: TranslationPanel(
                key: ValueKey(
                  '$_selectedWord-${widget.sourceLanguage}-${widget.targetLanguage}',
                ),
                word: _selectedWord!,
                sentenceMatch: _selectedSentence,
                source: widget.sourceLanguage,
                target: widget.targetLanguage,
                translationService: widget.translationService,
                onClose: () => setState(_clearSelection),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSlice(
    int pageIndex,
    List<ReflowBlock> blocks,
    ReflowSlice slice,
    Size contentSize, {
    required bool isFirst,
  }) {
    if (slice.blockIndex >= blocks.length) return const SizedBox.shrink();
    final block = blocks[slice.blockIndex];
    if (block.isImage) {
      final size = widget.source.figureSize(pageIndex, block, contentSize);
      if (size.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(
          top: isFirst ? 0 : _figureSpacing / 2,
          bottom: _figureSpacing / 2,
        ),
        child: _buildFigure(pageIndex, slice.blockIndex, block, size),
      );
    }
    // The gap above a block is exactly what the paginator reserved for it:
    // its own (a Markdown heading wants more air than a list item) or the
    // default, and none for a block continued from the previous sub-page.
    final gap = isFirst || !slice.isFirstOfBlock
        ? 0.0
        : (block.gapAbove ?? _blockGap);
    if (block.isDivider) {
      return Padding(
        padding: EdgeInsets.only(top: gap),
        child: SizedBox(
          height: 1,
          child: ColoredBox(
            color: widget.readingTheme.onBackground.withValues(alpha: 0.35),
          ),
        ),
      );
    }
    return Padding(
      key: ValueKey('${slice.blockIndex}-${slice.start}'),
      padding: EdgeInsets.only(top: gap),
      child: _framed(
        block,
        block.isTable
            ? _buildTable(pageIndex, block, slice, contentSize)
            : _buildParagraph(pageIndex, block, slice),
      ),
    );
  }

  /// The rows of a table that [slice] holds, drawn as a grid at exactly the
  /// size the paginator gave them — with the header row again on top when
  /// the slice continues a table from the sub-page before.
  Widget _buildTable(
    int pageIndex,
    ReflowBlock table,
    ReflowSlice slice,
    Size contentSize,
  ) {
    final insets = markdownBlockInsets(table);
    final layout = _tableLayout(
      table,
      math.max(20.0, contentSize.width - insets.left - insets.right),
    );
    final cells = table.tableCells!;
    final rows = tableRowsIn(table, slice.start, slice.end);
    final repeatHeader =
        table.tableHeader && !slice.isFirstOfBlock && rows.from > 0;
    final shown = [
      if (repeatHeader) 0,
      for (var r = rows.from; r < rows.to; r++) r,
    ];
    final theme = widget.readingTheme;
    final ruleColor = theme.onBackground.withValues(alpha: 0.28);
    final style = _styleFor(table);
    final alignments = table.tableAlignments ?? const <TextAlign>[];

    final children = <Widget>[];
    var top = tableRule;
    for (final r in shown) {
      final rowHeight = layout.rowHeights[r];
      if (r == 0 && table.tableHeader) {
        children.add(
          Positioned(
            left: 0,
            top: top,
            width: layout.width,
            height: rowHeight,
            child: ColoredBox(
              color: theme.onBackground.withValues(alpha: 0.06),
            ),
          ),
        );
      }
      var left = tableRule;
      for (var c = 0; c < cells[r].length; c++) {
        final columnWidth = layout.columnWidths[c];
        final cell = cells[r][c];
        final align = c < alignments.length ? alignments[c] : TextAlign.left;
        children.add(
          Positioned(
            left: left + tableCellPadX,
            top: top + tableCellPadY,
            width: cellTextWidth(columnWidth),
            height: rowHeight - tableRule - tableCellPadY * 2,
            child: Align(
              alignment: switch (align) {
                TextAlign.center => Alignment.topCenter,
                TextAlign.right || TextAlign.end => Alignment.topRight,
                _ => Alignment.topLeft,
              },
              child: _buildCell(
                pageIndex,
                slice.blockIndex,
                table,
                style,
                cell,
              ),
            ),
          ),
        );
        left += columnWidth;
      }
      top += rowHeight;
    }
    final height = math.min(
      contentSize.height,
      layout.heightOf(rows.from, rows.to, repeatHeader: repeatHeader),
    );
    return Align(
      alignment: Alignment.topLeft,
      child: ClipRect(
        child: SizedBox(
          width: layout.width,
          height: height,
          child: CustomPaint(
            foregroundPainter: _TableRulesPainter(
              columnWidths: layout.columnWidths,
              rowHeights: [for (final r in shown) layout.rowHeights[r]],
              color: ruleColor,
            ),
            child: Stack(clipBehavior: Clip.none, children: children),
          ),
        ),
      ),
    );
  }

  Widget _buildCell(
    int pageIndex,
    int blockIndex,
    ReflowBlock table,
    TextStyle style,
    ({int start, int end}) cell,
  ) {
    if (cell.start == cell.end) return const SizedBox.shrink();
    final onHitPage = pageIndex == _hlPage;
    final isCurrentHit = onHitPage && blockIndex == _hlBlockIndex;
    final selectedHere =
        pageIndex == _pageIndex && blockIndex == _selectedBlockIndex;
    return _listen(
      pageIndex,
      blockIndex,
      cell.start,
      cell.end,
      TranslatableText(
        text: table.text,
        start: cell.start,
        end: cell.end,
        settings: widget.settings,
        fontSize: widget.fontSize,
        readingTheme: widget.readingTheme,
        translatorEnabled: widget.translatorEnabled,
        style: style,
        formatRuns: table.formatRuns,
        selectedStart: selectedHere ? _selectedWordStart : null,
        selectedEnd: selectedHere ? _selectedWordEnd : null,
        highlight: isCurrentHit && _hlStart != null && _hlEnd != null
            ? (start: _hlStart!, end: _hlEnd!)
            : null,
        otherHighlights: onHitPage
            ? (_hlOthers[blockIndex] ?? const [])
            : const [],
        onWordTap: (start, end, word) =>
            _onWordTap(blockIndex, start, end, word),
      ),
    );
  }

  Widget _buildParagraph(int pageIndex, ReflowBlock block, ReflowSlice slice) {
    final blockIndex = slice.blockIndex;
    final onHitPage = pageIndex == _hlPage;
    final isCurrentHit = onHitPage && blockIndex == _hlBlockIndex;
    final selectedHere =
        pageIndex == _pageIndex && blockIndex == _selectedBlockIndex;
    // A slice of preformatted text ends on the line break its next slice
    // starts after. Painted, that break is one more (empty) line the
    // paginator never counted — the next line of the page runs off it.
    var end = slice.end;
    while (end > slice.start && block.text.codeUnitAt(end - 1) == 0x0A) {
      end--;
    }
    return _listen(
      pageIndex,
      blockIndex,
      slice.start,
      end,
      TranslatableText(
        text: block.text,
        start: slice.start,
        end: end,
        settings: widget.settings,
        fontSize: widget.fontSize,
        readingTheme: widget.readingTheme,
        translatorEnabled: widget.translatorEnabled,
        style: _styleFor(block),
        formatRuns: block.formatRuns,
        selectedStart: selectedHere ? _selectedWordStart : null,
        selectedEnd: selectedHere ? _selectedWordEnd : null,
        highlight: isCurrentHit && _hlStart != null && _hlEnd != null
            ? (start: _hlStart!, end: _hlEnd!)
            : null,
        otherHighlights: onHitPage
            ? (_hlOthers[blockIndex] ?? const [])
            : const [],
        onWordTap: (start, end, word) =>
            _onWordTap(blockIndex, start, end, word),
      ),
    );
  }

  /// A block's list indentation, blockquote bars and code panel. Each insets
  /// the text horizontally by exactly what [markdownBlockInsets] told the
  /// paginator, and none adds height.
  Widget _framed(ReflowBlock block, Widget content) {
    final theme = widget.readingTheme;
    for (var level = 0; level < block.quoteDepth; level++) {
      content = Container(
        padding: const EdgeInsets.only(
          left: markdownQuoteIndent - markdownQuoteBarWidth,
        ),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: markdownQuoteBarWidth,
              color: theme.accent.withValues(alpha: 0.55),
            ),
          ),
        ),
        child: content,
      );
    }
    if (block.isCode) {
      // A DecoratedBox, not a Container: a Container gives its border's
      // width as padding on all four sides, and the two pixels it added to
      // every panel's height were two pixels the paginator never counted —
      // the last line of a page of code ran off its bottom.
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.onBackground.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.onBackground.withValues(alpha: 0.14)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: markdownCodePadding),
          child: content,
        ),
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

  /// A figure at exactly the [size] the paginator reserved for it, centred
  /// in the column — the same room while it loads, so nothing below it moves
  /// when it arrives.
  Widget _buildFigure(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
    Size size,
  ) {
    return Center(
      child: SizedBox.fromSize(
        size: size,
        child: FutureBuilder<Uint8List?>(
          future: _figureFuture(pageIndex, blockIndex, block),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) {
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.readingTheme.onBackground.withValues(
                    alpha: 0.05,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              );
            }
            Widget image = Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
            if (widget.source.figuresArePaper) {
              // A figure cropped from a page carries the page's white paper
              // with it, so it takes the same reading-theme filter as a
              // whole page — or it would be a glaring patch in sepia or at
              // night.
              image = ColorFiltered(
                colorFilter: widget.readingTheme.pageImageFilter(
                  contrast: widget.settings.readingContrast,
                  weight: widget.settings.readingWeight,
                ),
                child: image,
              );
            }
            return GestureDetector(
              onTap: () => _openFullscreenImage(bytes),
              child: image,
            );
          },
        ),
      ),
    );
  }

  /// The source's figures, held on to: a FutureBuilder handed a new future
  /// every build would show its placeholder every frame.
  final Map<String, Future<Uint8List?>> _figures = {};

  Future<Uint8List?> _figureFuture(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
  ) {
    final key = '$pageIndex-$blockIndex-${block.imageBounds}';
    if (_figures.length > 64) _figures.clear();
    return _figures.putIfAbsent(
      key,
      () => widget.source.imageFor(pageIndex, blockIndex, block),
    );
  }

  void _openFullscreenImage(Uint8List bytes) {
    final background = widget.readingTheme.background;
    final foreground = widget.readingTheme.onBackground;
    Widget image = Image.memory(bytes);
    if (widget.source.figuresArePaper) {
      image = ColorFiltered(
        colorFilter: widget.readingTheme.pageImageFilter(
          contrast: widget.settings.readingContrast,
          weight: widget.settings.readingWeight,
        ),
        child: image,
      );
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            backgroundColor: background,
            foregroundColor: foreground,
            elevation: 0,
          ),
          body: Center(
            child: InteractiveViewer(minScale: 0.5, maxScale: 6, child: image),
          ),
        ),
      ),
    );
  }

  Widget _buildTranslationPane(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox.expand(
      child: ColoredBox(
        color: widget.readingTheme.secondaryBackground,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _translating || _visibleTranslation == null
              ? Row(
                  children: [
                    const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      l10n.syncTranslationTranslating,
                      style: TextStyle(
                        color: widget.readingTheme.onBackground.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                )
              : Text(
                  _visibleTranslation ?? '',
                  style: readingTextStyle(
                    settings: widget.settings,
                    fontSize: widget.fontSize,
                    heightFactor: 0.97,
                  ),
                ),
        ),
      ),
    );
  }
}

/// The page-turning drag: a pan that commits at the ordinary touch slop.
///
/// A pan normally waits for twice that, to tell its direction apart — and
/// the text-selection layer above the pages takes a horizontal drag at the
/// touch slop and claims it at once. So a sideways swipe never reached the
/// page: it went to the selection layer, and only vertical swipes turned
/// pages. At the same slop the page, being lower in the tree, sees the
/// finger first and wins; a long press still starts a selection, since that
/// is a different gesture.
class _PageTurnRecognizer extends PanGestureRecognizer {
  _PageTurnRecognizer({super.debugOwner});

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

/// The rules of a table's grid: round its edge, under every row and between
/// every two columns, each [tableRule] wide and inside the room the layout
/// gave it.
class _TableRulesPainter extends CustomPainter {
  _TableRulesPainter({
    required this.columnWidths,
    required this.rowHeights,
    required this.color,
  });

  final List<double> columnWidths;
  final List<double> rowHeights;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final height = math.min(
      size.height,
      rowHeights.fold<double>(tableRule, (a, b) => a + b),
    );
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, tableRule), paint);
    var y = tableRule;
    for (final rowHeight in rowHeights) {
      y += rowHeight;
      canvas.drawRect(
        Rect.fromLTWH(0, y - tableRule, size.width, tableRule),
        paint,
      );
    }
    var x = 0.0;
    for (final columnWidth in columnWidths) {
      canvas.drawRect(Rect.fromLTWH(x, 0, tableRule, height), paint);
      x += columnWidth;
    }
    canvas.drawRect(Rect.fromLTWH(x, 0, tableRule, height), paint);
  }

  @override
  bool shouldRepaint(_TableRulesPainter old) =>
      old.color != color ||
      old.columnWidths != columnWidths ||
      old.rowHeights.length != rowHeights.length;
}

/// A place in the book: character [offset] of block [block] on page [page].
typedef _TextPos = ({int page, int block, int offset});

extension on _TextPos {
  int compareTo(_TextPos other) {
    if (page != other.page) return page.compareTo(other.page);
    if (block != other.block) return block.compareTo(other.block);
    return offset.compareTo(other.offset);
  }
}

/// One paragraph (or table cell) of the page on screen, and what of it is
/// marked.
class _SliceMark {
  _SliceMark({
    required this.notifier,
    required this.key,
    required this.page,
    required this.block,
    required this.start,
    required this.end,
  });

  final SelectionListenerNotifier notifier;
  final GlobalKey key;
  final int page;
  final int block;

  /// The part of the block's text it shows.
  final int start;
  final int end;

  _TextPos pos(int offset) => (page: page, block: block, offset: offset);
}
