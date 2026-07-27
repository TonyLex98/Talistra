import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../services/settings_service.dart';
import '../utils/page_words.dart';
import '../utils/pdf_region_renderer.dart';
import '../utils/sentence_finder.dart';
import '../utils/text_join.dart';

const double _pageSpacing = 4.0;
const double _minZoom = 1.0;
const double _maxZoom = 3.0;

/// How much screen-space horizontal drag is absorbed before a drag starts
/// panning sideways at all. Below this, small incidental horizontal
/// drift while scrolling down (e.g. a slightly diagonal swipe, or pages
/// with paragraphs of different widths) doesn't move the page
/// horizontally; a deliberate, larger sideways drag still pans smoothly
/// past it, picking up exactly where the frozen position left off (no
/// jump at the threshold).
const double _horizontalDeadZone = 56.0;

/// How long after the last scroll, drag or tap the page-number scrubber
/// stays up before fading away. Long enough to read the page number and
/// reach for the thumb, short enough to leave reading undisturbed.
const Duration _idleDelay = Duration(milliseconds: 3000);

/// A from-scratch, continuously-scrolling PDF page stack rendered from
/// rasterized page images (via [PdfRegionRenderer]/pdfx), replacing
/// Syncfusion's `SfPdfViewer` for the main reading view.
///
/// This exists specifically so pan/zoom is driven by our own gesture
/// math instead of a black-box internal `TransformationController`:
/// Syncfusion's viewer applies every pointer-move delta directly to its
/// own private transform, so there's no way to intercept or dampen a
/// delta before it lands (any correction we make from the outside is
/// immediately overwritten by the next frame's raw delta, fighting the
/// user's drag instead of smoothing it). Owning the transform ourselves
/// lets a small drag be absorbed as a dead zone instead.
class PdfPageStackView extends StatefulWidget {
  const PdfPageStackView({
    super.key,
    required this.document,
    required this.renderer,
    required this.linesCache,
    required this.pageSizes,
    required this.initialPage,
    required this.initialZoom,
    required this.initialScrollFraction,
    required this.initialScrollFractionX,
    required this.readingTheme,
    required this.readingContrast,
    required this.readingWeight,
    required this.selectedPageIndex,
    required this.selectedWordPdfBounds,
    required this.selectedSentenceLineBoundsPdf,
    required this.highlightColor,
    required this.onWordSelected,
    required this.onRangeSelected,
    required this.onTapEmpty,
    required this.onPageChanged,
    required this.onViewSettled,
  });

  final PdfDocument document;
  final PdfRegionRenderer renderer;
  final Map<int, List<TextLine>> linesCache;
  final List<Size> pageSizes;
  final int initialPage;

  /// Restores exactly where the reader left off in THIS file: the zoom
  /// level, how far into [initialPage] they'd scrolled vertically (0..1),
  /// and how far they'd panned horizontally (0..1 of the available pan
  /// range at that zoom) — set once from persisted per-document state
  /// and otherwise left alone. The horizontal pan is one setting for the
  /// whole book, same as zoom, not something tied to a single page.
  final double initialZoom;
  final double initialScrollFraction;
  final double initialScrollFractionX;
  final ReadingTheme readingTheme;

  /// Extra ink contrast (0..1) and ink weight (300..800) for the page
  /// image — see [ReadingThemeStyle.pageImageFilter].
  final double readingContrast;
  final int readingWeight;

  final int? selectedPageIndex;
  final Rect? selectedWordPdfBounds;
  final List<Rect> selectedSentenceLineBoundsPdf;
  final Color highlightColor;

  /// [screenAnchor] is the raw screen-space tap point (before any
  /// content/zoom conversion), so a caller can anchor a translation
  /// popup right next to where the reader actually tapped instead of
  /// always docking it to the bottom of the screen.
  final void Function(
    int pageIndex,
    WordHit hit,
    SentenceMatch? sentence,
    Offset screenAnchor,
  )
  onWordSelected;

  /// Long-press then drag: a text-range selection. Fires continuously as
  /// the finger moves (with [finished] false) and once more when it lifts,
  /// so the reader can show the selected text live and only offer the
  /// copy/translate actions once the selection has settled.
  final void Function(String text, bool finished) onRangeSelected;
  final VoidCallback onTapEmpty;
  final ValueChanged<int> onPageChanged;

  /// Fired after a gesture ends (and whenever [jumpToPage] is called)
  /// with the current zoom, vertical scroll-fraction-within-page, and
  /// horizontal pan fraction, so the reader can persist all three per
  /// document.
  final void Function(
    double zoom,
    double scrollFraction,
    double scrollFractionX,
  )
  onViewSettled;

  @override
  State<PdfPageStackView> createState() => PdfPageStackViewState();
}

class PdfPageStackViewState extends State<PdfPageStackView>
    with SingleTickerProviderStateMixin {
  double _zoom = _minZoom;
  Offset _scrollOffset = Offset.zero;

  double _viewportWidth = 0;
  double _viewportHeight = 0;

  /// How wide a page is drawn, and where its left edge sits.
  ///
  /// In portrait a page simply fills the width. Turn the phone sideways and
  /// that would blow the page up to a width where only a slice of it fits
  /// on screen, and reading turns into two-axis panning — so in landscape
  /// the page is fitted to the *height* instead and centred, with paper
  /// margins either side, which is how a book actually reads across.
  double _contentWidth = 0;
  double _pageLeft = 0;
  List<double> _cumulativeY = const [];
  List<double> _pageHeights = const [];
  bool _initializedPosition = false;
  int _reportedPage = 0;

  final Map<int, Future<Uint8List?>> _imageFutures = {};

  /// A cheap, low-resolution render of the same pages. Rasterizing a page
  /// at reading sharpness takes long enough to notice, so every page is
  /// asked for twice: this one first (a fraction of the pixels, so it lands
  /// almost immediately and the reader sees the page rather than blank
  /// paper), then the sharp one, which quietly replaces it.
  final Map<int, Future<Uint8List?>> _previewFutures = {};

  double _gestureStartZoom = 1.0;
  Offset _gestureStartFocalScreen = Offset.zero;
  Offset _gestureStartFocalContent = Offset.zero;
  bool _horizontalUnlocked = false;
  double _totalMoveDistance = 0;
  DateTime? _gestureStartTime;
  int _activePointerCount = 0;
  Timer? _longPressTimer;
  bool _longPressFired = false;

  late final AnimationController _flingController;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    _flingController = AnimationController.unbounded(vsync: this)
      ..addListener(_onFlingTick);
    _pokeBubble();
  }

  // The page-number scrubber comes to full strength on any scroll/tap
  // activity and dims down shortly after things go quiet, rather than
  // sitting at full contrast over the page all the time. It never
  // disappears completely, since it's also the grab handle for dragging
  // through the document.
  bool _bubbleVisible = true;
  bool _scrubbing = false;
  Timer? _hideBubbleTimer;

  void _pokeBubble() {
    _hideBubbleTimer?.cancel();
    if (!_bubbleVisible) setState(() => _bubbleVisible = true);
    _hideBubbleTimer = Timer(_idleDelay, () {
      if (!mounted || _scrubbing) return;
      setState(() => _bubbleVisible = false);
    });
  }

  @override
  void dispose() {
    _hideBubbleTimer?.cancel();
    _flingController.dispose();
    super.dispose();
  }

  /// Jumps to [page] (1-based) — used by the reader's "Go to page" dialog
  /// (which also wants the zoom reset, since it's a deliberate jump to an
  /// unrelated page) and when switching back from reflow mode (which
  /// does NOT want zoom touched, since the reader may have deliberately
  /// zoomed this file and expects it to stay that way across modes).
  ///
  /// A mode-switch re-sync (`resetZoom: false`) that targets the exact
  /// page this view is already showing is a no-op: this view was mounted
  /// the whole time reflow was visible and already has the reader's real
  /// scroll position within that page, which jumping to the page's top
  /// would otherwise needlessly throw away every single time modes are
  /// toggled without actually having moved pages in between.
  void jumpToPage(int page, {bool resetZoom = true}) {
    if (_cumulativeY.isEmpty) return;
    final index = (page - 1).clamp(0, widget.pageSizes.length - 1);
    if (!resetZoom && index + 1 == _reportedPage) return;
    _flingController.stop();
    setState(() {
      // Only a deliberate "go to page" jump re-centers horizontally too —
      // a mode-switch re-sync must leave the reader's own horizontal pan
      // position exactly where it was, the same way it already leaves
      // zoom untouched, since both are one setting for the whole book,
      // not something that should reset just because a different page
      // number came into view.
      final dx = resetZoom ? 0.0 : _scrollOffset.dx;
      _scrollOffset = Offset(dx, _cumulativeY[index]);
      if (resetZoom) _zoom = _minZoom;
    });
    _reportedPage = index + 1;
    _pokeBubble();
    _reportViewSettled();
  }

  double get _maxDx => math.max(0.0, _viewportWidth - _viewportWidth / _zoom);

  void _reportViewSettled() {
    if (_pageHeights.isEmpty) return;
    final page = (_reportedPage - 1).clamp(0, _pageHeights.length - 1);
    final fraction = _pageHeights[page] > 0
        ? ((_scrollOffset.dy - _cumulativeY[page]) / _pageHeights[page]).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final maxDx = _maxDx;
    final fractionX = maxDx > 0
        ? (_scrollOffset.dx / maxDx).clamp(0.0, 1.0)
        : 0.0;
    widget.onViewSettled(_zoom, fraction, fractionX);
  }

  void _ensureLayout(double viewportWidth, double viewportHeight) {
    final contentWidth = _fittedContentWidth(viewportWidth, viewportHeight);
    if (viewportWidth == _viewportWidth &&
        viewportHeight == _viewportHeight &&
        contentWidth == _contentWidth) {
      return;
    }
    _viewportHeight = viewportHeight;

    // Capture the current logical position (which page, how far into
    // it) against the OLD layout before recomputing page heights for
    // the new width, and restore it afterwards — otherwise a raw pixel
    // scrollOffset silently points at the wrong spot once page heights
    // change (e.g. after a rotation flips the viewport's aspect ratio).
    int? capturedPage;
    double? capturedFraction;
    if (_cumulativeY.isNotEmpty) {
      var page = 0;
      for (var i = 0; i < _cumulativeY.length; i++) {
        page = i;
        if (_cumulativeY[i] + _pageHeights[i] >= _scrollOffset.dy) break;
      }
      capturedPage = page;
      capturedFraction = _pageHeights[page] > 0
          ? (_scrollOffset.dy - _cumulativeY[page]) / _pageHeights[page]
          : 0.0;
    }
    // Same idea horizontally: the reader's pan position only means
    // anything relative to the pan range at the OLD viewport width, so
    // capture it as a fraction here and re-apply against the new range
    // below — otherwise a rotation (or any other width change) leaves a
    // stale raw pixel offset that no longer lines up with anything.
    final oldMaxDx = _maxDx;
    final capturedFractionX = oldMaxDx > 0
        ? (_scrollOffset.dx / oldMaxDx).clamp(0.0, 1.0)
        : 0.0;

    _viewportWidth = viewportWidth;
    _contentWidth = contentWidth;
    _pageLeft = ((viewportWidth - contentWidth) / 2).clamp(0.0, viewportWidth);
    final cumulative = <double>[];
    final heights = <double>[];
    var y = 0.0;
    for (final size in widget.pageSizes) {
      cumulative.add(y);
      // A malformed page (zero, negative, or non-finite MediaBox — seen
      // in some real-world PDFs) falls back to a standard-ish aspect
      // ratio instead of poisoning every page after it: an unguarded
      // NaN/Infinity here would propagate through the running sum and
      // silently blank out the rest of the document.
      var h = contentWidth * 1.4;
      if (size.width > 0 &&
          size.height > 0 &&
          size.width.isFinite &&
          size.height.isFinite) {
        final candidate = contentWidth * (size.height / size.width);
        if (candidate.isFinite && candidate > 0) h = candidate;
      }
      heights.add(h);
      y += h + _pageSpacing;
    }
    _cumulativeY = cumulative;
    _pageHeights = heights;

    if (capturedPage != null &&
        capturedFraction != null &&
        capturedPage < _pageHeights.length) {
      _scrollOffset = Offset(
        capturedFractionX * _maxDx,
        _cumulativeY[capturedPage] +
            capturedFraction * _pageHeights[capturedPage],
      );
    }
  }

  /// The width to draw pages at: the viewport in portrait, and whatever
  /// makes the page fit vertically in landscape.
  double _fittedContentWidth(double viewportWidth, double viewportHeight) {
    if (viewportWidth <= viewportHeight || viewportHeight <= 0) {
      return viewportWidth;
    }
    var aspect = 1.4;
    for (final size in widget.pageSizes) {
      if (size.width > 0 &&
          size.height > 0 &&
          size.width.isFinite &&
          size.height.isFinite) {
        aspect = size.height / size.width;
        break;
      }
    }
    // A hair under the full height, so a page turn doesn't clip.
    final fitted = (viewportHeight * 0.98) / aspect;
    return math.min(viewportWidth, fitted);
  }

  double get _totalContentHeight =>
      _pageHeights.isEmpty ? 0 : _cumulativeY.last + _pageHeights.last;

  Offset _screenToContent(Offset screen) {
    return Offset(
      screen.dx / _zoom + _scrollOffset.dx,
      screen.dy / _zoom + _scrollOffset.dy,
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _flingController.stop();
    _activePointerCount = details.pointerCount;
    _gestureStartZoom = _zoom;
    _gestureStartFocalScreen = details.localFocalPoint;
    _gestureStartFocalContent = _screenToContent(details.localFocalPoint);
    _horizontalUnlocked = false;
    _totalMoveDistance = 0;
    _gestureStartTime = DateTime.now();
    _pokeBubble();

    _longPressFired = false;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 450), () {
      if (_activePointerCount <= 1 && _totalMoveDistance <= 14) {
        _longPressFired = true;
        _handleLongPress(_gestureStartFocalScreen);
      }
    });
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_viewportWidth <= 0) return;
    // Once a long press has taken hold, the same finger is drawing a text
    // selection — it must not also scroll the page under it.
    if (_longPressFired) {
      _extendSelection(details.localFocalPoint);
      return;
    }
    _pokeBubble();
    // A pinch briefly reports pointerCount back down to 1 as fingers
    // lift, so once a gesture has ever seen 2+ pointers it's remembered
    // for the rest of the gesture (see _onScaleEnd).
    if (details.pointerCount > _activePointerCount) {
      _activePointerCount = details.pointerCount;
    }
    if (_activePointerCount > 1) _longPressTimer?.cancel();

    final newZoom = (_gestureStartZoom * details.scale).clamp(
      _minZoom,
      _maxZoom,
    );
    final totalDx = details.localFocalPoint.dx - _gestureStartFocalScreen.dx;
    _totalMoveDistance =
        (details.localFocalPoint - _gestureStartFocalScreen).distance;
    if (_totalMoveDistance > 14) _longPressTimer?.cancel();

    double effectiveFocalX;
    if (_horizontalUnlocked) {
      final sign = totalDx >= 0 ? 1 : -1;
      effectiveFocalX = details.localFocalPoint.dx - sign * _horizontalDeadZone;
    } else if (totalDx.abs() >= _horizontalDeadZone) {
      _horizontalUnlocked = true;
      final sign = totalDx >= 0 ? 1 : -1;
      effectiveFocalX = details.localFocalPoint.dx - sign * _horizontalDeadZone;
    } else {
      effectiveFocalX = _gestureStartFocalScreen.dx;
    }

    var newDx = _gestureStartFocalContent.dx - effectiveFocalX / newZoom;
    var newDy =
        _gestureStartFocalContent.dy - details.localFocalPoint.dy / newZoom;

    final maxDx = math.max(0.0, _viewportWidth - _viewportWidth / newZoom);
    newDx = newDx.clamp(0.0, maxDx);
    final maxDy = math.max(
      0.0,
      _totalContentHeight - _viewportHeight / newZoom,
    );
    newDy = newDy.clamp(0.0, maxDy);

    setState(() {
      _zoom = newZoom;
      _scrollOffset = Offset(newDx, newDy);
    });
    _maybeReportPageChange();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _longPressTimer?.cancel();
    if (_longPressFired) {
      // The long press was a selection gesture; releasing the finger ends
      // it (and must not also register as a tap).
      _finishSelection();
      _reportViewSettled();
      return;
    }
    final start = _gestureStartTime;
    final elapsed = start == null
        ? const Duration(seconds: 1)
        : DateTime.now().difference(start);
    // Only a genuine single-finger tap should open a translation — a
    // pinch that happens to end with very little net movement (common
    // right as the second finger lifts) must never be mistaken for one.
    if (_activePointerCount <= 1 &&
        _totalMoveDistance <= 14 &&
        elapsed <= const Duration(milliseconds: 400)) {
      _handleTap(_gestureStartFocalScreen);
    } else if (_activePointerCount <= 1 && !_horizontalUnlocked) {
      // A fast vertical flick keeps scrolling with momentum, like any
      // normal scroll view, instead of stopping dead the instant the
      // finger lifts.
      final velocityY = details.velocity.pixelsPerSecond.dy;
      if (velocityY.abs() > 200) {
        _startFling(-velocityY / _zoom);
      }
    }
    _reportViewSettled();
  }

  void _startFling(double contentVelocity) {
    final maxDy = math.max(0.0, _totalContentHeight - _viewportHeight / _zoom);
    if (maxDy <= 0) return;
    _flingController.value = _scrollOffset.dy;
    final simulation = ClampingScrollSimulation(
      position: _scrollOffset.dy,
      velocity: contentVelocity,
    );
    _flingController.animateWith(simulation);
  }

  void _onFlingTick() {
    final maxDy = math.max(0.0, _totalContentHeight - _viewportHeight / _zoom);
    final newDy = _flingController.value.clamp(0.0, maxDy);
    if (newDy != _scrollOffset.dy) {
      setState(() => _scrollOffset = Offset(_scrollOffset.dx, newDy));
      _maybeReportPageChange();
    }
    if (newDy <= 0 || newDy >= maxDy) {
      _flingController.stop();
      _reportViewSettled();
    }
  }

  void _maybeReportPageChange() {
    if (_pageHeights.isEmpty) return;
    var page = 0;
    for (var i = 0; i < _cumulativeY.length; i++) {
      page = i;
      if (_cumulativeY[i] + _pageHeights[i] >= _scrollOffset.dy) break;
    }
    final pageNumber = page + 1;
    if (pageNumber != _reportedPage) {
      _reportedPage = pageNumber;
      widget.onPageChanged(pageNumber);
    }
  }

  ({int pageIndex, WordHit hit, List<TextLine> lines})? _wordAtScreenPoint(
    Offset screenPoint,
  ) {
    if (_pageHeights.isEmpty) return null;
    final content = _screenToContent(screenPoint);
    int? pageIndex;
    for (var i = 0; i < _cumulativeY.length; i++) {
      if (content.dy < _cumulativeY[i] + _pageHeights[i]) {
        pageIndex = i;
        break;
      }
    }
    final pageX = content.dx - _pageLeft;
    if (pageIndex == null || pageX < 0 || pageX > _contentWidth) return null;
    final pageLocalY = content.dy - _cumulativeY[pageIndex];
    final pageSize = widget.pageSizes[pageIndex];
    if (pageSize.width <= 0) return null;
    final scale = _contentWidth / pageSize.width;
    final pdfPoint = Offset(pageX / scale, pageLocalY / scale);

    List<TextLine> lines;
    try {
      lines = widget.linesCache.putIfAbsent(
        pageIndex,
        () => extractPageLines(widget.document, pageIndex!),
      );
    } catch (_) {
      return null;
    }

    final hit = hitTestWord(lines, pdfPoint);
    if (hit == null) return null;
    return (pageIndex: pageIndex, hit: hit, lines: lines);
  }

  void _handleTap(Offset screenPoint) {
    if (_hasRangeSelection) {
      clearRangeSelection();
      widget.onRangeSelected('', true);
      return;
    }
    final found = _wordAtScreenPoint(screenPoint);
    if (found == null) {
      widget.onTapEmpty();
      return;
    }
    final sentence = findSentenceForWord(
      document: widget.document,
      pageIndex: found.pageIndex,
      word: found.hit.text,
      wordBounds: found.hit.bounds,
      cachedLines: found.lines,
    );
    widget.onWordSelected(found.pageIndex, found.hit, sentence, screenPoint);
  }

  // ---------------------------------------------------------------------
  // Range selection.
  //
  // The page is a picture, so there's no text layer for Flutter's own
  // selection handles to work with: a long press used to be able to grab
  // exactly one word and nothing more. Instead the page's extracted words
  // are flattened into one reading-order list per page ([buildPageWords]),
  // which turns "select from here to there" into a range of indices —
  // the long press sets the anchor, and dragging moves the far end,
  // across lines, until the finger lifts.
  // ---------------------------------------------------------------------

  final Map<int, List<PageWord>> _pageWordsCache = {};
  final Map<int, Set<String>> _pageLexiconCache = {};

  int? _selectionPageIndex;
  int? _selectionAnchorWord;
  int? _selectionFocusWord;
  List<Rect> _selectionRectsPdf = const [];

  bool get _hasRangeSelection => _selectionRectsPdf.isNotEmpty;

  List<PageWord> _wordsForPage(int pageIndex) {
    return _pageWordsCache.putIfAbsent(pageIndex, () {
      try {
        final lines = widget.linesCache.putIfAbsent(
          pageIndex,
          () => extractPageLines(widget.document, pageIndex),
        );
        return buildPageWords(lines);
      } catch (_) {
        return const [];
      }
    });
  }

  /// Which page a screen point falls on, and where inside that page in
  /// PDF points — the shared first half of every hit test here.
  ({int pageIndex, Offset pdfPoint})? _pageHitAt(Offset screenPoint) {
    if (_pageHeights.isEmpty) return null;
    final content = _screenToContent(screenPoint);
    int? pageIndex;
    for (var i = 0; i < _cumulativeY.length; i++) {
      if (content.dy < _cumulativeY[i] + _pageHeights[i]) {
        pageIndex = i;
        break;
      }
    }
    if (pageIndex == null) return null;
    final pageSize = widget.pageSizes[pageIndex];
    if (pageSize.width <= 0) return null;
    final scale = _contentWidth / pageSize.width;
    return (
      pageIndex: pageIndex,
      pdfPoint: Offset(
        (content.dx - _pageLeft) / scale,
        (content.dy - _cumulativeY[pageIndex]) / scale,
      ),
    );
  }

  void _handleLongPress(Offset screenPoint) {
    final hit = _pageHitAt(screenPoint);
    if (hit == null) return;
    final words = _wordsForPage(hit.pageIndex);
    final index = wordIndexAt(words, hit.pdfPoint);
    if (index == null) return;
    _selectionPageIndex = hit.pageIndex;
    _selectionAnchorWord = index;
    _updateSelection(index, finished: false);
  }

  /// Extends the live selection to whatever word is under the finger now.
  /// A drag that strays onto another page is ignored rather than jumping:
  /// the anchor's page owns the selection until the finger lifts.
  void _extendSelection(Offset screenPoint) {
    final anchorPage = _selectionPageIndex;
    if (anchorPage == null) return;
    final hit = _pageHitAt(screenPoint);
    if (hit == null || hit.pageIndex != anchorPage) return;
    final index = wordIndexAt(_wordsForPage(anchorPage), hit.pdfPoint);
    if (index == null || index == _selectionFocusWord) return;
    _updateSelection(index, finished: false);
  }

  void _updateSelection(int focusWord, {required bool finished}) {
    final pageIndex = _selectionPageIndex;
    final anchor = _selectionAnchorWord;
    if (pageIndex == null || anchor == null) return;
    final words = _wordsForPage(pageIndex);
    if (words.isEmpty) return;
    final selection = buildWordRangeSelection(
      words,
      anchor,
      focusWord,
      // The page's own vocabulary, so copied text keeps real compound
      // hyphens and loses the hyphenation ones (see [joinLines]).
      lexicon: _pageLexiconCache.putIfAbsent(
        pageIndex,
        () => buildPageLexicon(words.map((w) => w.text)),
      ),
    );
    setState(() {
      _selectionFocusWord = focusWord;
      _selectionRectsPdf = selection.rects;
    });
    widget.onRangeSelected(selection.text, finished);
  }

  void _finishSelection() {
    final focus = _selectionFocusWord;
    if (focus == null) return;
    _updateSelection(focus, finished: true);
  }

  /// Called when the reader dismisses the selection (a tap elsewhere, or
  /// closing the actions that go with it).
  void clearRangeSelection() {
    if (!_hasRangeSelection && _selectionPageIndex == null) return;
    setState(() {
      _selectionPageIndex = null;
      _selectionAnchorWord = null;
      _selectionFocusWord = null;
      _selectionRectsPdf = const [];
    });
  }

  double _renderScaleFor(int pageIndex, double dpr, double supersample) {
    final width = widget.pageSizes[pageIndex].width;
    if (width <= 0) return dpr;
    return (_contentWidth / width) * dpr * supersample;
  }

  Future<Uint8List?> _previewFor(int pageIndex) {
    return _previewFutures.putIfAbsent(
      pageIndex,
      () => widget.renderer.renderRegion(
        pageIndex: pageIndex,
        pdfBounds: Rect.fromLTWH(
          0,
          0,
          widget.pageSizes[pageIndex].width,
          widget.pageSizes[pageIndex].height,
        ),
        // Logical resolution, no device-pixel multiplier: roughly a tenth
        // of the pixels of the sharp render, and it only has to hold up for
        // the moment before that arrives.
        scale: widget.pageSizes[pageIndex].width <= 0
            ? 1.0
            : _contentWidth / widget.pageSizes[pageIndex].width,
      ),
    );
  }

  Future<Uint8List?> _imageFor(int pageIndex, double renderScale) {
    return _imageFutures.putIfAbsent(
      pageIndex,
      () => widget.renderer.renderRegion(
        pageIndex: pageIndex,
        pdfBounds: Rect.fromLTWH(
          0,
          0,
          widget.pageSizes[pageIndex].width,
          widget.pageSizes[pageIndex].height,
        ),
        scale: renderScale,
      ),
    );
  }

  void _pruneImageCache(int lo, int hi) {
    _imageFutures.removeWhere((key, _) => key < lo - 2 || key > hi + 2);
    _previewFutures.removeWhere((key, _) => key < lo - 4 || key > hi + 4);
  }

  Rect? _contentRectFor(int? pageIndex, Rect? pdfBounds) {
    if (pageIndex == null ||
        pdfBounds == null ||
        pageIndex >= widget.pageSizes.length ||
        pageIndex >= _cumulativeY.length) {
      return null;
    }
    final pageSize = widget.pageSizes[pageIndex];
    if (pageSize.width <= 0) return null;
    final scale = _contentWidth / pageSize.width;
    return Rect.fromLTWH(
      _pageLeft + pdfBounds.left * scale,
      _cumulativeY[pageIndex] + pdfBounds.top * scale,
      pdfBounds.width * scale,
      pdfBounds.height * scale,
    );
  }

  double get _maxDyForScrub =>
      math.max(0.0, _totalContentHeight - _viewportHeight / _zoom);

  /// The right-edge pill showing the current page — and a real scroll
  /// thumb, not just a readout: it sits at the document's current position
  /// and dragging it moves through the document, which is the only fast
  /// way to cross a 900-page book (a page-by-page swipe never gets there,
  /// and the "go to page" dialog needs a number you may not know).
  Widget _buildScrubber(int currentPage) {
    final maxDy = _maxDyForScrub;
    final trackHeight = math.max(
      0.0,
      _viewportHeight - _scrubberMargin * 2 - _scrubberHeight,
    );
    final progress = maxDy > 0
        ? (_scrollOffset.dy / maxDy).clamp(0.0, 1.0)
        : 0.0;

    return Positioned(
      right: 4,
      top: _scrubberMargin + progress * trackHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) {
          _flingController.stop();
          setState(() => _scrubbing = true);
          _pokeBubble();
        },
        onVerticalDragUpdate: (details) {
          if (trackHeight <= 0 || maxDy <= 0) return;
          final newDy =
              (_scrollOffset.dy + details.delta.dy / trackHeight * maxDy).clamp(
                0.0,
                maxDy,
              );
          setState(() => _scrollOffset = Offset(_scrollOffset.dx, newDy));
          _maybeReportPageChange();
          _pokeBubble();
        },
        onVerticalDragEnd: (_) {
          setState(() => _scrubbing = false);
          _pokeBubble();
          _reportViewSettled();
        },
        onVerticalDragCancel: () {
          setState(() => _scrubbing = false);
          _reportViewSettled();
        },
        child: AnimatedOpacity(
          // Gone, not just faded: while reading it would otherwise sit
          // there permanently, over the text. Any scroll brings it back.
          opacity: _bubbleVisible || _scrubbing ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          child: Container(
            height: _scrubberHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: _scrubbing ? 0.85 : 0.62),
              borderRadius: BorderRadius.circular(_scrubberHeight / 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.drag_indicator,
                  size: 15,
                  color: Colors.white70,
                ),
                const SizedBox(width: 2),
                Text(
                  '$currentPage',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensureLayout(constraints.maxWidth, constraints.maxHeight);
        if (_cumulativeY.isEmpty) return const SizedBox.shrink();

        if (!_initializedPosition) {
          _initializedPosition = true;
          final index = (widget.initialPage - 1).clamp(
            0,
            widget.pageSizes.length - 1,
          );
          final fraction = widget.initialScrollFraction.clamp(0.0, 1.0);
          final fractionX = widget.initialScrollFractionX.clamp(0.0, 1.0);
          _scrollOffset = Offset(
            fractionX * _maxDx,
            _cumulativeY[index] + fraction * _pageHeights[index],
          );
          _reportedPage = index + 1;
        }

        // Render a little above the device's own pixel density: matching
        // it exactly looks slightly soft for body text, which benefits
        // from some supersampling to read as crisp black rather than grey.
        // Kept modest on purpose — rasterizing costs time proportional to
        // the *square* of this factor, and every page of a big book pays
        // it, which is the difference between a page appearing at once and
        // appearing a second later.
        final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.5, 3.0);
        const supersample = 1.25;

        var lo = 0;
        for (var i = 0; i < _cumulativeY.length; i++) {
          lo = i;
          if (_cumulativeY[i] + _pageHeights[i] >= _scrollOffset.dy) break;
        }
        var hi = lo;
        final viewportBottom = _scrollOffset.dy + _viewportHeight / _zoom;
        for (var i = lo; i < _cumulativeY.length; i++) {
          if (_cumulativeY[i] > viewportBottom) break;
          hi = i;
        }
        lo = math.max(0, lo - 1);
        hi = math.min(_pageHeights.length - 1, hi + 1);
        _pruneImageCache(lo, hi);

        // Rasterizing is serialized in the native plugin, so the order
        // requests go in *is* the order they come back: the page being
        // looked at is asked for first, and its neighbours (prefetched for
        // a smooth scroll) queue up behind it. Asking in plain top-to-
        // bottom order instead meant the page above the current one was
        // always rendered first, delaying the one on screen.
        //
        // And while the scrubber is being dragged, nothing is requested at
        // all: a drag crosses dozens of pages, and every one of them used
        // to enqueue a full-page render that couldn't be cancelled, so by
        // the time the finger stopped there was a backlog of stale pages
        // to grind through before the page actually being looked at got
        // its turn. Nothing is requested until the drag settles.
        final visibleIndex = (_reportedPage - 1).clamp(lo, hi);
        if (!_scrubbing) {
          // Order is everything, since the plugin rasterizes one page at a
          // time: the page being looked at gets its quick preview first,
          // then its sharp render, and only then do the neighbours queue up.
          _previewFor(visibleIndex);
          _imageFor(
            visibleIndex,
            _renderScaleFor(visibleIndex, dpr, supersample),
          );
          for (var i = lo; i <= hi; i++) {
            if (i == visibleIndex) continue;
            _previewFor(i);
            _imageFor(i, _renderScaleFor(i, dpr, supersample));
          }
        }

        final wordRect = _contentRectFor(
          widget.selectedPageIndex,
          widget.selectedWordPdfBounds,
        );
        final sentenceRects = <Rect>[
          for (final r in widget.selectedSentenceLineBoundsPdf)
            if (_contentRectFor(widget.selectedPageIndex, r) case final rect?)
              rect,
        ];

        final selectionRects = <Rect>[
          for (final r in _selectionRectsPdf)
            if (_contentRectFor(_selectionPageIndex, r) case final rect?) rect,
        ];

        final currentPage = math.min(_reportedPage, widget.pageSizes.length);
        final theme = widget.readingTheme;

        return Stack(
          children: [
            // The reading surface is a solid, deliberately theme-independent
            // background (defaulting to white, like the vast majority of
            // real PDFs) — without it, the spacing between pages and any
            // margin around them would show the app's own Scaffold
            // background straight through, which is black in dark mode.
            //
            // Positioned.fill, not a bare ColoredBox: a Stack lays its
            // non-positioned children out with *loose* constraints, and a
            // childless ColoredBox takes the smallest size it's allowed —
            // i.e. 0x0 — so as a plain child it silently painted nothing
            // at all and the Scaffold showed through anyway.
            Positioned.fill(
              child: ColoredBox(color: widget.readingTheme.background),
            ),
            ClipRect(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: Transform(
                  transform: Matrix4.identity()
                    ..scaleByDouble(_zoom, _zoom, 1.0, 1.0)
                    ..translateByDouble(
                      -_scrollOffset.dx,
                      -_scrollOffset.dy,
                      0.0,
                      1.0,
                    ),
                  // No explicit size here: a Box can never legally be
                  // bigger than the (viewport-sized, tight) constraints
                  // handed down from the parent, so sizing this to the
                  // full scrollable content height would just get clamped
                  // back to viewport size. Instead this Stack stays
                  // viewport-sized and its Positioned children (in
                  // content-space coordinates, which routinely fall far
                  // outside those bounds) are left unclipped — Positioned
                  // children are allowed to render outside their Stack's
                  // own bounds; only the outer [ClipRect] needs to (and
                  // does) constrain what's visible.
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = lo; i <= hi; i++)
                        Positioned(
                          key: ValueKey(i),
                          left: _pageLeft,
                          top: _cumulativeY[i],
                          width: _contentWidth,
                          height: _pageHeights[i],
                          child: _PdfPageImage(
                            key: ValueKey('page-$i'),
                            future: _imageFutures[i],
                            previewFuture: _previewFutures[i],
                            readingTheme: widget.readingTheme,
                            contrast: widget.readingContrast,
                            weight: widget.readingWeight,
                          ),
                        ),
                      // Order matters: the sentence wash goes down first,
                      // then the word or the dragged selection on top of
                      // it, so a word inside its own sentence still reads
                      // as the stronger mark.
                      for (final rect in sentenceRects)
                        _Highlight(
                          rect: rect,
                          color: theme.sentenceHighlight,
                          theme: theme,
                        ),
                      for (final rect in selectionRects)
                        _Highlight(
                          rect: rect,
                          color: theme.rangeHighlight,
                          theme: theme,
                        ),
                      if (wordRect != null)
                        _Highlight(
                          rect: wordRect,
                          color: theme.wordHighlight,
                          theme: theme,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _buildScrubber(currentPage),
          ],
        );
      },
    );
  }
}

/// The scrubber's own geometry: a pill on the right edge, sitting at
/// whatever fraction of the document is currently on screen.
const double _scrubberHeight = 40;
const double _scrubberMargin = 8;

/// One highlight rectangle over the page, blended like a marker pen so it
/// can be strong enough to see without dimming the text under it (see
/// [ReadingThemeStyle.highlightBlendMode]).
class _Highlight extends StatelessWidget {
  const _Highlight({
    required this.rect,
    required this.color,
    required this.theme,
  });

  final Rect rect;
  final Color color;
  final ReadingTheme theme;

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            backgroundBlendMode: theme.highlightBlendMode,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _PdfPageImage extends StatefulWidget {
  const _PdfPageImage({
    super.key,
    required this.future,
    required this.previewFuture,
    required this.readingTheme,
    required this.contrast,
    required this.weight,
  });

  /// The sharp render, and the quick low-resolution one that stands in
  /// until it arrives. Either may be null when nothing has been asked for
  /// yet (during a scrubber drag), in which case the page shows as blank
  /// reading surface.
  final Future<Uint8List?>? future;
  final Future<Uint8List?>? previewFuture;
  final ReadingTheme readingTheme;
  final double contrast;
  final int weight;

  @override
  State<_PdfPageImage> createState() => _PdfPageImageState();
}

class _PdfPageImageState extends State<_PdfPageImage> {
  Uint8List? _preview;
  Uint8List? _sharp;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_PdfPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.future != widget.future ||
        oldWidget.previewFuture != widget.previewFuture) {
      _listen();
    }
  }

  void _listen() {
    widget.previewFuture?.then((bytes) {
      // Once the sharp page is in, a late preview is of no interest.
      if (!mounted || bytes == null || bytes.isEmpty || _sharp != null) return;
      setState(() => _preview = bytes);
    }).ignore();
    widget.future?.then((bytes) {
      if (!mounted || bytes == null || bytes.isEmpty) return;
      setState(() => _sharp = bytes);
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _sharp ?? _preview;
    if (bytes == null) return ColoredBox(color: widget.readingTheme.background);
    // The page arrives as opaque white paper with the file's own colors on
    // it; the reading theme is applied here, to the finished image (see
    // [ReadingThemeStyle.pageImageFilterAt]).
    return ColorFiltered(
      colorFilter: widget.readingTheme.pageImageFilter(
        contrast: widget.contrast,
        weight: widget.weight,
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        // Scaling a low-resolution stand-in up to page size looks better
        // smoothed than blocky.
        filterQuality: _sharp != null
            ? FilterQuality.low
            : FilterQuality.medium,
      ),
    );
  }
}
