import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../l10n/gen/app_localizations.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/page_rotation.dart';
import '../utils/pdf_region_renderer.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';
import '../utils/reflow_paginator.dart';
import '../utils/sentence_finder.dart';
import 'reading_selection_area.dart';
import 'translatable_text.dart';
import 'translation_panel.dart';

/// Phone-friendly reading view: the PDF's text is reflowed for the screen
/// and then *paginated* — each PDF page becomes as many swipeable
/// sub-pages as its text needs, so reading is a light left/right swipe
/// (or a tap near the screen edge) like an e-book, with no scrolling and
/// nothing ever half cut off at the bottom. Images, diagrams and tables
/// come across as real, zoomable pictures cropped to themselves.
class ReflowPdfView extends StatefulWidget {
  const ReflowPdfView({
    super.key,
    required this.document,
    required this.renderer,
    required this.pageCount,
    required this.initialPage,
    required this.linesCache,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.syncTranslationExperimental,
    required this.onPageChanged,
    required this.onTapCenter,
    this.onNoteSelection,
  });

  /// The reader asked to keep the passage they marked as a note.
  final void Function(String text)? onNoteSelection;

  final PdfDocument document;
  final PdfRegionRenderer renderer;
  final int pageCount;
  final int initialPage;
  final Map<int, List<TextLine>> linesCache;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;

  /// Read straight through for typography (font, weight, contrast) so the
  /// reading text is styled in exactly one place — see [readingTextStyle].
  final SettingsService settings;

  /// Master switch for the whole translation feature; when off, words
  /// are no longer tappable and no translation UI shows up at all.
  final bool translatorEnabled;

  /// Experimental opt-in (only meaningful while [translatorEnabled] is
  /// also true): splits the screen into the original on top and a live
  /// translation of the page being read on the bottom.
  final bool syncTranslationExperimental;

  final ValueChanged<int> onPageChanged;

  /// A tap in the middle of the page that didn't land on a word: shows or
  /// hides the chrome (the edges are page-turn zones instead).
  final VoidCallback onTapCenter;

  @override
  State<ReflowPdfView> createState() => ReflowPdfViewState();
}

/// Public so [ReaderScreen] can jump this view to a specific page (via a
/// [GlobalKey]) from its own "Go to page" dialog.
class ReflowPdfViewState extends State<ReflowPdfView>
    with SingleTickerProviderStateMixin {
  /// Where the reader is: which PDF page, and which sub-page inside it.
  int _pageIndex = 0;
  int _subPageIndex = 0;

  final Map<int, List<ReflowBlock>> _blocksCache = {};
  final Map<int, List<ReflowSubPage>> _subPagesCache = {};
  final Map<String, Future<Uint8List?>> _imageCache = {};

  /// The layout the cached pagination was computed for — a change in
  /// width, height or type size invalidates every paginated page.
  Size _paginationSize = Size.zero;
  double _paginationFontSize = 0;

  /// The typography the cached sub-pages were measured in: a new reading font
  /// or weight breaks every line somewhere else, so they are laid out again
  /// rather than painted wider than the page they were cut for.
  TextStyle? _paginationTypography;
  TextScaler? _paginationTextScaler;
  String? _warmedPosition;

  // Page turning follows the finger: the page is dragged along with it and
  // only settles (forward, or back where it was) when the finger lifts.
  //
  // [_dragOffset] is how far the current page has been moved, in pixels,
  // along [_dragAxis]; negative means towards the next page (dragging left,
  // or up). [_incoming] is the page being pulled in behind it, which is
  // built and shown while the drag is in progress so there's never a blank
  // edge. The controller is only used to finish the movement — either
  // carrying it through or snapping it back.
  late final AnimationController _turnController;
  Animation<double>? _settleAnimation;
  double _dragOffset = 0;
  Axis _dragAxis = Axis.horizontal;
  bool _dragAxisLocked = false;
  ({int page, int subPage})? _incoming;
  bool _commitOnSettle = false;

  int? _selectedBlockIndex;
  int? _selectedWordStart;
  int? _selectedWordEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  /// The long-press mark layer over the pages, so turning a page can also drop
  /// whatever the reader had marked.
  final GlobalKey<ReadingSelectionAreaState> _selectionKey =
      GlobalKey<ReadingSelectionAreaState>();

  // The search hit the reader is looking at: which page and block it sits in,
  // and the [start, end) range inside that block's text to wash over. Stored
  // in the view's own coordinates (page + block + offsets) so it survives
  // sub-page turns — the block is the stable unit, and a match spanning a
  // sub-page boundary keeps its highlight on whichever slice is showing.
  int _hlPage = -1;
  int? _hlBlockIndex;
  int? _hlStart;
  int? _hlEnd;

  // Every other match that also falls on [_hlPage], keyed by block index —
  // washed over fainter than the current hit, so the reader can see at a
  // glance where this page's other matches are without losing track of
  // which one next/previous is currently on.
  Map<int, List<(int start, int end)>> _hlOthers = const {};

  // The last content box the build laid out, kept so a search hit can be
  // mapped onto a sub-page index (which only exists once pagination has a
  // size to work with) without having to re-run a layout to find it.
  Size _lastContentSize = Size.zero;

  // Experimental sync translation: the translation of the sub-page being
  // read right now.
  Timer? _translateDebounce;
  String? _visibleTranslation;
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    _pageIndex = (widget.initialPage - 1).clamp(0, widget.pageCount - 1);
    _turnController =
        AnimationController(
            duration: const Duration(milliseconds: 220),
            vsync: this,
          )
          ..addListener(_onSettleTick)
          ..addStatusListener(_onSettleStatus);
    // Pagination is only known once the first layout has happened, and the
    // sync-translation pane needs it to know what's on screen — so the
    // first translation is kicked off right after that first frame,
    // otherwise the pane sat empty until the reader turned a page.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleTranslation());
  }

  @override
  void dispose() {
    _translateDebounce?.cancel();
    _turnController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ReflowPdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.syncTranslationExperimental !=
            widget.syncTranslationExperimental ||
        oldWidget.source != widget.source ||
        oldWidget.target != widget.target) {
      _visibleTranslation = null;
      _scheduleTranslation();
    }
  }

  void jumpToPage(int page) {
    final index = (page - 1).clamp(0, widget.pageCount - 1);
    setState(() {
      _pageIndex = index;
      _subPageIndex = 0;
      _clearSelection();
    });
    _scheduleTranslation();
  }

  /// Highlights a search hit: jumps to its page and marks the [matchStart,
  /// matchEnd) range of [blockIndex]'s text. The reader calls this from the
  /// search sheet whenever the reader lands on a match.
  void showSearchHighlight(
    int page,
    int blockIndex,
    int matchStart,
    int matchEnd, {
    List<({int blockIndex, int start, int end})> others = const [],
  }) {
    final index = (page - 1).clamp(0, widget.pageCount - 1);
    final subPage = _subPageForBlock(index, blockIndex, matchStart);
    final othersByBlock = <int, List<(int, int)>>{};
    for (final o in others) {
      (othersByBlock[o.blockIndex] ??= []).add((o.start, o.end));
    }
    setState(() {
      _pageIndex = index;
      _subPageIndex = subPage;
      _hlPage = index;
      _hlBlockIndex = blockIndex;
      _hlStart = matchStart;
      _hlEnd = matchEnd;
      _hlOthers = othersByBlock;
      _clearSelection();
    });
    _scheduleTranslation();
  }

  /// The sub-page that shows [matchStart] of [blockIndex], so a jump lands
  /// on the line the match actually sits on rather than the top of the page.
  int _subPageForBlock(int pageIndex, int blockIndex, int matchStart) {
    if (_lastContentSize.width <= 0 || _lastContentSize.height <= 0) return 0;
    final subPages = _subPagesFor(pageIndex, _lastContentSize);
    for (var i = 0; i < subPages.length; i++) {
      for (final slice in subPages[i]) {
        if (slice.blockIndex != blockIndex) continue;
        if (slice.start == slice.end) return i; // image block: whole thing
        if (matchStart >= slice.start && matchStart < slice.end) return i;
      }
    }
    return 0;
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

  // ---------------------------------------------------------------------
  // Content: blocks per PDF page, paginated for the current layout.
  // ---------------------------------------------------------------------

  List<ReflowBlock> _blocksFor(int pageIndex) {
    return _blocksCache.putIfAbsent(pageIndex, () {
      try {
        final lines = widget.linesCache.putIfAbsent(
          pageIndex,
          () => extractPageLines(widget.document, pageIndex),
        );
        final pageSize = displayPageSize(widget.document.pages[pageIndex]);
        _textColumnWidths[pageIndex] = _textColumnWidth(lines, pageSize);
        final blocks = [...buildReflowPageBlocks(lines, pageSize)];
        _measureFigures(pageIndex, blocks);
        return blocks;
      } catch (_) {
        return const [];
      }
    });
  }

  /// How wide the page's text runs, in PDF points: the yardstick a figure's
  /// width is measured against, so a figure half as wide as the text on its
  /// page is half as wide as the reflowed text.
  final Map<int, double> _textColumnWidths = {};

  static double _textColumnWidth(List<TextLine> lines, Size pageSize) {
    var left = double.infinity;
    var right = -double.infinity;
    for (final line in lines) {
      if (line.text.trim().length < 3) continue;
      left = math.min(left, line.bounds.left);
      right = math.max(right, line.bounds.right);
    }
    final width = right - left;
    // No text to measure against (a scan, a full-page plate): the page.
    if (!width.isFinite || width < pageSize.width * 0.3) return pageSize.width;
    return width;
  }

  /// Figures whose real extent is known. A figure starts out as the gap
  /// between two runs of text — a guess, full-width, often mostly paper —
  /// and is cropped to what is actually drawn in it before it is laid out
  /// for good (see [PdfRegionRenderer.renderTrimmedRegion]).
  final Set<String> _measuredFigures = {};

  /// Crops every figure of [pageIndex] to its ink and lays the page out
  /// again with the real sizes. The crop's image is kept, so painting the
  /// figure doesn't render it a second time. A gap that turns out blank
  /// stays in the list as an empty figure — block indices are what search
  /// hits point at — and takes no room.
  void _measureFigures(int pageIndex, List<ReflowBlock> blocks) {
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (!block.isImage) continue;
      final key = '$pageIndex-$i';
      if (!_measuredFigures.add(key)) continue;
      final region = widget.renderer.renderTrimmedRegion(
        pageIndex: pageIndex,
        pdfBounds: block.imageBounds!,
      );
      _imageCache[key] = region.then((r) => r?.bytes);
      region.then((r) {
        if (!mounted) return;
        final cached = _blocksCache[pageIndex];
        if (cached == null || i >= cached.length) return;
        final trimmed = r?.pdfBounds ?? Rect.zero;
        if (trimmed == cached[i].imageBounds) return;
        setState(() {
          cached[i] = ReflowBlock.image(trimmed);
          _subPagesCache.remove(pageIndex);
        });
      }).ignore();
    }
  }

  /// The size a figure is shown at: the width it has relative to its page's
  /// text, as in the PDF, and never taller than most of the screen.
  Size _figureSize(int pageIndex, ReflowBlock block, Size contentSize) {
    final bounds = block.imageBounds!;
    if (bounds.isEmpty) return Size.zero;
    final reference =
        _textColumnWidths[pageIndex] ??
        displayPageSize(widget.document.pages[pageIndex]).width;
    final aspect = bounds.height / bounds.width;
    var width = math.min(
      contentSize.width,
      bounds.width * contentSize.width / reference,
    );
    var height = width * aspect;
    final maxHeight = contentSize.height * 0.9;
    if (height > maxHeight) {
      height = maxHeight;
      width = height / aspect;
    }
    return Size(width, height);
  }

  TextStyle _styleFor(ReflowBlock block) {
    return readingTextStyle(
      settings: widget.settings,
      fontSize: widget.fontSize,
      sizeFactor: block.isHeading ? 1.16 : 1.0,
      heightFactor: block.isHeading ? 0.84 : 1.0,
      bold: block.isHeading,
    );
  }

  /// The style text will actually be *painted* with — the paginator has to
  /// measure with exactly this, including the ambient [DefaultTextStyle]
  /// (font family, and anything else the theme sets) and the system font
  /// scale, or its idea of how many lines fit is slightly off and the last
  /// line spills past the bottom of the sub-page.
  TextStyle _paintedStyleFor(ReflowBlock block) =>
      DefaultTextStyle.of(context).style.merge(_styleFor(block));

  List<ReflowSubPage> _subPagesFor(int pageIndex, Size contentSize) {
    final typography = _paintedStyleFor(
      const ReflowBlock.paragraph(''),
    ).copyWith(color: const Color(0x00000000));
    final textScaler = MediaQuery.textScalerOf(context);
    if (contentSize != _paginationSize ||
        widget.fontSize != _paginationFontSize ||
        typography != _paginationTypography ||
        textScaler != _paginationTextScaler) {
      _subPagesCache.clear();
      _paginationSize = contentSize;
      _paginationFontSize = widget.fontSize;
      _paginationTypography = typography;
      _paginationTextScaler = textScaler;
    }
    return _subPagesCache.putIfAbsent(pageIndex, () {
      final blocks = _blocksFor(pageIndex);
      final pages = paginateReflowBlocks(
        blocks: blocks,
        width: contentSize.width,
        height: contentSize.height,
        fontSize: widget.fontSize,
        styleFor: _paintedStyleFor,
        spanFor: (block, style) => readingTextSpan(
          text: block.text,
          formatRuns: block.formatRuns,
          style: style,
          settings: widget.settings,
          readingTheme: widget.readingTheme,
        ),
        blockSpacing: 16,
        imageSpacing: 20,
        textScaler: textScaler,
        imageSizeFor: (block) => _figureSize(pageIndex, block, contentSize),
      );
      // Even a page with nothing on it is one (empty) sub-page, so the
      // page-turn arithmetic never has to special-case zero.
      return pages.isEmpty ? [const <ReflowSlice>[]] : pages;
    });
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
      if (page + 1 >= widget.pageCount) return null;
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

  void _onDragStart() {
    _turnController.stop();
    _dragAxisLocked = false;
    _settleAnimation = null;
  }

  /// Moves the page with the finger. The axis is decided by the first bit
  /// of real movement and then held for the rest of the gesture, so a
  /// slightly diagonal swipe doesn't wobble between sideways and upwards.
  void _onDragUpdate(Offset delta, Size contentSize, Size viewport) {
    if (!_dragAxisLocked) {
      if (delta.distance < 0.6) return;
      _dragAxis = delta.dx.abs() >= delta.dy.abs()
          ? Axis.horizontal
          : Axis.vertical;
      _dragAxisLocked = true;
    }
    final movement = _dragAxis == Axis.horizontal ? delta.dx : delta.dy;
    var offset = _dragOffset + movement;
    // Left or up is forward, right or down is back.
    final direction = offset < 0 ? 1 : -1;
    final incoming = _neighbour(direction, contentSize);
    if (incoming == null) {
      // Nothing there to turn to: the page still gives a little, so the
      // edge of the book is something you feel rather than a dead swipe.
      offset = offset * 0.3;
    }
    final extent = _dragExtent(viewport);
    setState(() {
      _incoming = incoming;
      _dragOffset = offset.clamp(-extent, extent);
    });
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

  /// Runs the rest of the movement out to [target] — the full page width
  /// (or height) to complete the turn, or back to zero to abandon it.
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
    setState(() => _dragOffset = animation.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final target = _incoming;
    final commit = _commitOnSettle;
    _settleAnimation = null;
    _commitOnSettle = false;
    setState(() {
      _dragOffset = 0;
      _incoming = null;
      if (commit && target != null) {
        final pageChanged = target.page != _pageIndex;
        _pageIndex = target.page;
        _subPageIndex = target.subPage;
        _clearSelection();
        if (pageChanged) widget.onPageChanged(_pageIndex + 1);
      }
    });
    if (commit) _scheduleTranslation();
  }

  /// Build the adjacent sub-pages before a gesture begins. Otherwise their
  /// pagination competes with the opening frames of a swipe on a phone and
  /// makes the incoming page appear to jump into place.
  void _warmNeighbourPages(Size contentSize) {
    final position =
        '$_pageIndex:$_subPageIndex:${contentSize.width}:${contentSize.height}:$_paginationFontSize';
    if (_warmedPosition == position) return;
    _warmedPosition = position;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _warmedPosition != position) return;
      _neighbour(1, contentSize);
      _neighbour(-1, contentSize);
    });
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
    _selectionKey.currentState?.clearSelection();
  }

  /// The reader marked a passage with a long press and asked what it says. The
  /// card answers for the whole mark, so the word highlight steps aside.
  void _translateSelection(String text) {
    setState(() {
      _selectedBlockIndex = null;
      _selectedWordStart = null;
      _selectedWordEnd = null;
      _selectedSentence = null;
      _selectedWord = text;
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
    if (size == Size.zero) return;
    final subPages = _subPagesFor(_pageIndex, size);
    if (_subPageIndex >= subPages.length) return;
    final blocks = _blocksFor(_pageIndex);
    final text = _textOfSubPage(subPages[_subPageIndex], blocks);
    if (text.trim().isEmpty) {
      setState(() => _visibleTranslation = '');
      return;
    }
    setState(() => _translating = true);
    try {
      final result = await widget.translationService.translate(
        text: text,
        source: widget.source,
        target: widget.target,
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
      final block = blocks[slice.blockIndex];
      if (block.isImage) continue;
      if (buffer.isNotEmpty) buffer.write(slice.isFirstOfBlock ? '\n\n' : ' ');
      buffer.write(block.text.substring(slice.start, slice.end).trim());
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------
  // Rendering.
  // ---------------------------------------------------------------------

  static const _pagePadding = EdgeInsets.fromLTRB(20, 16, 20, 8);

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
          // sideways phone or a tablet the column is capped and centred
          // rather than running the whole width of the screen.
          // The card's own inset and border eat into the space the text has,
          // and pagination has to know that or the last line spills past
          // the bottom of the card.
          final available =
              constraints.maxWidth - _pagePadding.horizontal - _cardInset * 2;
          final columnWidth = math.min(available, widget.fontSize * 38);
          final sideMargin = (available - columnWidth) / 2;
          final contentSize = Size(
            columnWidth,
            // A few pixels of slack on top of the card inset: measurement
            // and painting can round line heights differently, and being
            // off by a fraction of a pixel per line adds up to a clipped
            // last line.
            paneHeight -
                _pagePadding.vertical -
                _footerHeight -
                _cardInset * 2 -
                8,
          );
          if (contentSize.width <= 0 || contentSize.height <= 0) {
            return const SizedBox.shrink();
          }
          _warmNeighbourPages(contentSize);
          _lastContentSize = contentSize;

          // The mark layer sits above the turnable area rather than inside a
          // page card: a selection region inside one claims a horizontal drag
          // for itself, and the swipe meant to turn the page never gets there.
          final reader = ReadingSelectionArea(
            key: _selectionKey,
            translatorEnabled: widget.translatorEnabled,
            onTranslateSelection: _translateSelection,
            onNoteSelection: widget.onNoteSelection,
            allText: () => reflowBlocksText(_blocksFor(_pageIndex)),
            child: _buildTurnableArea(
              context,
              constraints,
              contentSize,
              sideMargin,
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

  static const double _footerHeight = 22;

  Widget _buildTurnableArea(
    BuildContext context,
    BoxConstraints constraints,
    Size contentSize,
    double sideMargin,
  ) {
    final viewport = Size(constraints.maxWidth, constraints.maxHeight);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // A pan, not separate horizontal/vertical drags: the page follows the
      // finger either way — left or up for the next page, right or down for
      // the previous one.
      onPanStart: (_) => _onDragStart(),
      onPanUpdate: (details) =>
          _onDragUpdate(details.delta, contentSize, viewport),
      onPanEnd: (details) => _onDragEnd(
        _dragAxis == Axis.horizontal
            ? details.velocity.pixelsPerSecond.dx
            : details.velocity.pixelsPerSecond.dy,
        viewport,
      ),
      // Edge taps turn pages too — the standard e-reader alternative to
      // swiping, and much easier one-handed. The middle of the page is left
      // alone so tapping a word still translates it.
      onTapUp: (details) {
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
          widget.onTapCenter();
        }
      },
      child: ClipRect(
        child: Stack(
          children: [
            // Both cards move by exactly the same amount, so they travel
            // as one strip with a gap between them and never overlap: the
            // page you're leaving slides fully out as the next one slides
            // fully in, the way cards in a deck are dealt side by side.
            Positioned.fill(
              child: Transform.translate(
                offset: _offsetFor(_dragOffset),
                child: _card(
                  elevation: 0.35,
                  child: _buildSubPage(
                    _pageIndex,
                    _subPageIndex,
                    contentSize,
                    sideMargin,
                  ),
                ),
              ),
            ),
            if (_incoming case final incoming?)
              Positioned.fill(
                child: Transform.translate(
                  // Exactly one screen away on the side the finger is
                  // pulling from — edge to edge with the outgoing card,
                  // never on top of it.
                  offset: _offsetFor(
                    _dragOffset +
                        (_dragOffset < 0
                            ? _dragExtent(viewport)
                            : -_dragExtent(viewport)),
                  ),
                  child: _card(
                    elevation: 0.35 + 0.35 * _turnProgress(viewport),
                    child: _buildSubPage(
                      incoming.page,
                      incoming.subPage,
                      contentSize,
                      sideMargin,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// How far through a turn the gesture is, 0..1 — drives the depth cues.
  double _turnProgress(Size viewport) {
    final extent = _dragExtent(viewport);
    if (extent <= 0) return 0;
    return (_dragOffset.abs() / extent).clamp(0.0, 1.0);
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
    final blocks = _blocksFor(pageIndex);
    if (blocks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppLocalizations.of(context).noTextOnPage,
            style: TextStyle(color: widget.readingTheme.onBackground),
          ),
        ),
      );
    }
    final subPages = _subPagesFor(pageIndex, contentSize);
    final index = subPageIndex.clamp(0, subPages.length - 1);
    final slices = subPages[index];

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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < slices.length; i++)
                        _buildSlice(
                          pageIndex,
                          blocks,
                          slices[i],
                          isFirst: i == 0,
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: _footerHeight,
                  child: Center(
                    child: Text(
                      '${pageIndex + 1} · ${index + 1}/${subPages.length}',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.readingTheme.onBackground.withValues(
                          alpha: 0.45,
                        ),
                      ),
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
            child: TranslationPanel(
              key: ValueKey('$_selectedWord-${widget.source}-${widget.target}'),
              word: _selectedWord!,
              sentenceMatch: _selectedSentence,
              source: widget.source,
              target: widget.target,
              translationService: widget.translationService,
              onClose: () => setState(_clearSelection),
            ),
          ),
      ],
    );
  }

  Widget _buildSlice(
    int pageIndex,
    List<ReflowBlock> blocks,
    ReflowSlice slice, {
    required bool isFirst,
  }) {
    final block = blocks[slice.blockIndex];
    if (block.isImage) {
      return Padding(
        padding: EdgeInsets.only(top: isFirst ? 0 : 10, bottom: 10),
        child: _buildImageBlock(
          pageIndex,
          slice.blockIndex,
          block,
          _figureSize(pageIndex, block, _lastContentSize),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        // A paragraph continued from the previous sub-page starts flush at
        // the top; a new one gets its usual space above it.
        top: isFirst || !slice.isFirstOfBlock ? 0 : (block.isHeading ? 14 : 16),
      ),
      child: _buildParagraph(pageIndex, slice.blockIndex, block, slice),
    );
  }

  Widget _buildTranslationPane(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // SizedBox.expand, because a ColoredBox takes its size from its child:
    // with an empty translation the scroll view shrink-wrapped to the width
    // of its own padding, and the pane showed up as a narrow dark stripe
    // down the middle of the screen instead of a full-width panel.
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

  /// Renders one figure block, cropped to whatever is actually drawn in it
  /// (see [PdfRegionRenderer.renderTrimmedRegion]) — a diagram comes across
  /// as the diagram itself rather than a full-page-width band, and a gap
  /// that turned out to hold nothing resolves to null and takes up no room.
  /// The figure's image — the crop [_measureFigures] already rendered, or a
  /// fresh one if the cache let it go.
  Future<Uint8List?> _imageFor(int pageIndex, int blockIndex, Rect bounds) {
    final key = '$pageIndex-$blockIndex';
    return _imageCache.putIfAbsent(key, () async {
      final region = await widget.renderer.renderTrimmedRegion(
        pageIndex: pageIndex,
        pdfBounds: bounds,
      );
      return region?.bytes;
    });
  }

  /// A figure, at exactly the [size] the paginator reserved for it and
  /// centred in the column — the same room whether it has arrived yet or
  /// not, so nothing below it moves when it does.
  Widget _buildImageBlock(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
    Size size,
  ) {
    if (size.isEmpty) return const SizedBox.shrink();
    return Center(
      child: SizedBox.fromSize(
        size: size,
        child: FutureBuilder<Uint8List?>(
          future: _imageFor(pageIndex, blockIndex, block.imageBounds!),
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
            return GestureDetector(
              onTap: () => _openFullscreenImage(bytes),
              // Cropped figures carry the page's own white paper with them,
              // so they get the same reading-theme filter as a full page —
              // otherwise every figure is a glaring white patch in sepia or
              // dark mode.
              child: ColorFiltered(
                colorFilter: widget.readingTheme.pageImageFilter(
                  contrast: widget.settings.readingContrast,
                  weight: widget.settings.readingWeight,
                ),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openFullscreenImage(Uint8List bytes) {
    final background = widget.readingTheme.background;
    final foreground = widget.readingTheme.onBackground;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            backgroundColor: background,
            foregroundColor: foreground,
            elevation: 0,
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 6,
              child: ColorFiltered(
                colorFilter: widget.readingTheme.pageImageFilter(
                  contrast: widget.settings.readingContrast,
                  weight: widget.settings.readingWeight,
                ),
                child: Image.memory(bytes),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  void _onWordTap(
    int blockIndex,
    int wordStart,
    int wordEnd,
    String word,
    String blockText,
  ) {
    if (!widget.translatorEnabled) return;
    final sentence = findSentenceInText(blockText, word);
    setState(() {
      _selectedBlockIndex = blockIndex;
      _selectedWordStart = wordStart;
      _selectedWordEnd = wordEnd;
      _selectedWord = word;
      _selectedSentence = sentence;
    });
  }

  /// Builds one paragraph slice as tappable words.
  ///
  /// Offsets stay in the block's own coordinates (the slice only narrows
  /// which part is drawn), so a tapped word is looked up in the whole
  /// paragraph — the sentence it belongs to doesn't get cut off just
  /// because the sub-page boundary fell in the middle of it.
  Widget _buildParagraph(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
    ReflowSlice slice,
  ) {
    final baseStyle = _styleFor(block);
    final highlighted =
        blockIndex == _hlBlockIndex &&
        pageIndex == _hlPage &&
        _hlStart != null &&
        _hlEnd != null;
    final otherRanges = pageIndex == _hlPage
        ? (_hlOthers[blockIndex] ?? const <(int, int)>[])
        : const <(int, int)>[];

    TextStyle styleAt(
      int pos, {
      required bool selected,
      bool hot = false,
      bool otherHot = false,
    }) {
      var style = baseStyle;
      for (final run in block.formatRuns) {
        if (pos >= run.start && pos < run.end) {
          // The reader's own bold, through the variable font's weight axis:
          // a bare FontWeight.w700 is overridden by the axis the base style
          // already sets, and the run would come out no bolder at all. It is
          // also the weight the paginator measured this run at.
          if (run.bold) style = emphasisedReadingStyle(style, widget.settings);
          if (run.italic) style = style.copyWith(fontStyle: FontStyle.italic);
          break;
        }
      }
      if (otherHot) {
        style = style.copyWith(
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.14),
        );
      }
      if (hot) {
        style = style.copyWith(
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.32),
        );
      }
      if (selected) {
        // No change of weight: a wider word could wrap its line once more
        // than the paginator measured and push the last line off the page.
        style = style.copyWith(
          color: widget.readingTheme.accent,
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.22),
        );
      }
      return style;
    }

    bool isHot(int start, int end) =>
        highlighted && start < _hlEnd! && end > _hlStart!;

    bool isOtherHot(int start, int end) {
      for (final (s, e) in otherRanges) {
        if (start < e && end > s) return true;
      }
      return false;
    }

    final text = block.text;
    final spans = <InlineSpan>[];
    var last = slice.start;
    for (final match in _wordPattern.allMatches(
      text.substring(slice.start, slice.end),
    )) {
      final start = slice.start + match.start;
      final end = slice.start + match.end;
      if (start > last) {
        spans.add(
          TextSpan(
            text: text.substring(last, start),
            style: styleAt(
              last,
              selected: false,
              hot: isHot(last, start),
              otherHot: isOtherHot(last, start),
            ),
          ),
        );
      }
      final word = match.group(0)!;
      final isSelected =
          blockIndex == _selectedBlockIndex &&
          start == _selectedWordStart &&
          end == _selectedWordEnd;
      spans.add(
        TextSpan(
          text: word,
          style: styleAt(
            start,
            selected: isSelected,
            hot: isHot(start, end),
            otherHot: isOtherHot(start, end),
          ),
          recognizer: widget.translatorEnabled
              ? (TapGestureRecognizer()
                  ..onTap = () =>
                      _onWordTap(blockIndex, start, end, word, text))
              : null,
        ),
      );
      last = end;
    }
    if (last < slice.end) {
      spans.add(
        TextSpan(
          text: text.substring(last, slice.end),
          style: styleAt(
            last,
            selected: false,
            hot: isHot(last, slice.end),
            otherHot: isOtherHot(last, slice.end),
          ),
        ),
      );
    }
    return Text.rich(TextSpan(children: spans));
  }
}
