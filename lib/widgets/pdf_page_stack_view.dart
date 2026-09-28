import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
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

/// How close to the top or bottom edge a dragged selection grip has to get
/// before the document starts scrolling under it. Wide enough to hit
/// comfortably with a thumb, narrow enough that a mark being widened in the
/// middle of the page never triggers it.
const double _autoScrollEdge = 64.0;

/// How far the document moves per tick while a grip is held at an edge, in
/// screen pixels. Slow enough that the word the grip lands on stays readable.
const double _autoScrollSpeed = 7.0;

const Duration _autoScrollTick = Duration(milliseconds: 16);

/// The grips' own geometry: a visible bar this wide, inside a touch target
/// this generous, kept this far inside the viewport.
const double _gripWidth = 5.0;
const double _gripHeight = 26.0;
const double _gripTouchSize = 44.0;
const double _gripMargin = 12.0;

/// The two corners of a mark, in the view's own screen coordinates: the
/// menu over a scan anchors itself on these exactly as the compact view's
/// anchors itself on the system selection's own.
typedef RangeAnchors = ({Offset above, Offset below});

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
  ///
  /// [anchors] are the mark's corners in this view's own coordinates — the
  /// reader anchors its action menu on those, the way the text readers
  /// anchor theirs on the system's selection anchors, so one menu looks and
  /// behaves the same whether the page is a picture or reflowed text. Null
  /// once the mark is gone.
  final void Function(String text, bool finished, RangeAnchors? anchors)
  onRangeSelected;
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

  /// The quantized zoom level the images currently held in [_imageFutures]
  /// were rasterized at. Zoom is applied with a [Transform] (a pure upscale
  /// of whatever bitmap we hold), so a page rendered at fit-to-width goes
  /// soft the moment the reader pinches out — thin lines in a diagram blur to
  /// mush. To keep the page crisp the visible pages are re-rasterized at a
  /// resolution that tracks the zoom (see [_renderScaleFor]); whenever the
  /// quantized zoom moves past a tier, the stale lower-resolution bitmaps are
  /// dropped so the pages re-render sharp (see [_pruneImageCache]).
  double _renderedZoomTier = _minZoom;

  /// The part of the page on screen, rendered on its own at exactly the
  /// zoom it is seen at — so zoomed-in text is as sharp as the screen can
  /// show, not a whole-page bitmap blown up past the size a phone can hold.
  /// Asked for once the view comes to rest at a zoom above 1.
  ({int page, Rect pdfBounds, Uint8List bytes})? _detail;

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

  // A search hit to wash over in the (picture-only) original view: which page
  // and the page-space rect of the matched run of words. Set by the reader
  // from the search sheet; null clears it. [_searchHighlightOtherRectsPdf]
  // are every other match that also falls on this page — drawn fainter, so
  // the reader can see at a glance where the rest of this page's hits are
  // without losing track of which one next/previous is currently on.
  int? _searchHighlightPage;
  Rect? _searchHighlightRectPdf;
  List<Rect> _searchHighlightOtherRectsPdf = const [];

  /// Marks a search hit to draw as a highlight rectangle in page-space, or
  /// clears it when [pageIndex] is null. [otherPdfBounds] are this page's
  /// other matches, drawn as a fainter wash alongside the current one.
  void setSearchHighlight(
    int? pageIndex,
    Rect? pdfBounds, {
    List<Rect> otherPdfBounds = const [],
  }) {
    final page = pageIndex?.clamp(0, widget.pageSizes.length - 1);
    if (page == _searchHighlightPage &&
        pdfBounds == _searchHighlightRectPdf &&
        listEquals(otherPdfBounds, _searchHighlightOtherRectsPdf)) {
      return;
    }
    setState(() {
      _searchHighlightPage = page;
      _searchHighlightRectPdf = pdfBounds;
      _searchHighlightOtherRectsPdf = otherPdfBounds;
    });
  }

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
    _autoScrollTimer?.cancel();
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

  /// Renders the part of the page on screen at the zoom it is seen at (see
  /// [_detail]), or drops the one there was when the view is back at 1x.
  void _requestDetail() {
    if (_zoom <= 1.01 || _pageHeights.isEmpty || _contentWidth <= 0) {
      if (_detail != null) setState(() => _detail = null);
      return;
    }
    final page = (_reportedPage - 1).clamp(0, _pageHeights.length - 1);
    final size = widget.pageSizes[page];
    if (size.width <= 0 || size.height <= 0) return;
    final pageRect = Rect.fromLTWH(
      _pageLeft,
      _cumulativeY[page],
      _contentWidth,
      _pageHeights[page],
    );
    final visible = Rect.fromLTWH(
      _scrollOffset.dx,
      _scrollOffset.dy,
      _viewportWidth / _zoom,
      _viewportHeight / _zoom,
    ).intersect(pageRect);
    if (visible.width <= 0 || visible.height <= 0) return;
    final pageScale = _contentWidth / size.width;
    final pdfBounds = Rect.fromLTWH(
      (visible.left - _pageLeft) / pageScale,
      (visible.top - _cumulativeY[page]) / pageScale,
      visible.width / pageScale,
      visible.height / pageScale,
    );
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 4.0);
    final image = widget.renderer.renderRegion(
      pageIndex: page,
      pdfBounds: pdfBounds,
      scale: pageScale * dpr * _zoom,
    );
    image.then((bytes) {
      if (!mounted || bytes == null || bytes.isEmpty) return;
      // Only if the view is still where it was asked for: a tile that lands
      // after the reader zoomed back out would sit over the page for nothing.
      if (_zoom <= 1.01) return;
      setState(
        () => _detail = (page: page, pdfBounds: pdfBounds, bytes: bytes),
      );
    }).ignore();
  }

  void _reportViewSettled() {
    _requestDetail();
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
    _reanchorSelection();
    _reportViewSettled();
  }

  /// Re-reports the mark's corners without rebuilding the mark: after a
  /// scroll or a pinch the text is the same, only its place on screen has
  /// moved, and the menu anchored on it has to move with it.
  void _reanchorSelection() {
    if (!_hasRangeSelection) return;
    widget.onRangeSelected(_selectionText, true, selectionAnchors());
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
      _reanchorSelection();
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
      widget.onRangeSelected('', true, null);
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
  // exactly one word and nothing more. Instead each page's extracted words
  // are flattened into one reading-order list ([buildPageWords]), which
  // turns "select from here to there" into a pair of [WordPosition]s —
  // the long press sets both, the finger or either grip then moves one of
  // them, across lines and across pages, until it lifts.
  //
  // Crossing a page break is what the grips are for: holding a grip near
  // the top or bottom edge scrolls the document under the finger, so a
  // mark can be dragged from the bottom of one page to the top of the
  // next instead of stopping dead at the margin.
  // ---------------------------------------------------------------------

  final Map<int, List<PageWord>> _pageWordsCache = {};
  final Map<int, Set<String>> _pageLexiconCache = {};

  /// The mark, as its two ends. Kept in document order (`start` never
  /// after `end`); dragging one end past the other swaps them, and the
  /// finger keeps steering whichever end it ended up on.
  WordPosition? _selectionStart;
  WordPosition? _selectionEnd;
  List<MarkedLine> _selectionRectsPdf = const [];
  String _selectionText = '';

  /// Which grip the finger currently holds (0 = start, 1 = end), and where
  /// that finger is on screen — the scroll ticks re-resolve the mark's end
  /// from the pointer, not from the grip, since the grip is drawn over the
  /// text and the text is what is moving.
  int? _heldGrip;
  Offset? _gripPointer;
  Timer? _autoScrollTimer;

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

  Set<String> _lexiconForPage(int pageIndex) {
    return _pageLexiconCache.putIfAbsent(
      pageIndex,
      () => buildPageLexicon(_wordsForPage(pageIndex).map((w) => w.text)),
    );
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

  /// The word a screen point marks: the nearest one on the page under the
  /// finger, wherever on that page it happens to be.
  WordPosition? _wordPositionAt(Offset screenPoint) {
    final hit = _pageHitAt(screenPoint);
    if (hit == null) return null;
    final index = wordIndexAt(_wordsForPage(hit.pageIndex), hit.pdfPoint);
    if (index == null) return null;
    return (pageIndex: hit.pageIndex, wordIndex: index);
  }

  void _handleLongPress(Offset screenPoint) {
    final position = _wordPositionAt(screenPoint);
    if (position == null) return;
    _selectionStart = position;
    _selectionEnd = position;
    _heldGrip = 1;
    _gripPointer = screenPoint;
    _recomputeSelection(finished: false);
    _updateAutoScroll();
  }

  /// Moves the end the finger is steering to whatever word is under it.
  void _extendSelection(Offset screenPoint) {
    _gripPointer = screenPoint;
    // Re-armed on every move of the finger, whether or not the mark grew: a
    // grip resting on the bottom edge has already marked the last word it can
    // see, and from there the page has to come to the finger.
    _updateAutoScroll();
    final grip = _heldGrip;
    if (grip == null || _selectionStart == null || _selectionEnd == null) {
      return;
    }
    final position = _wordPositionAt(screenPoint);
    if (position == null) return;
    final current = grip == 0 ? _selectionStart! : _selectionEnd!;
    if (position == current) return;
    _moveGripTo(grip, position);
    _recomputeSelection(finished: false);
  }

  /// Re-points one end of the mark, swapping the two ends if that put the
  /// mark backwards — and handing the finger the end it is now actually
  /// dragging, so continuing to move keeps widening the mark the way the
  /// finger implies rather than fighting the swap.
  void _moveGripTo(int grip, WordPosition position) {
    if (grip == 0) {
      _selectionStart = position;
      if (compareWordPositions(_selectionStart!, _selectionEnd!) > 0) {
        final swap = _selectionStart;
        _selectionStart = _selectionEnd;
        _selectionEnd = swap;
        _heldGrip = 1;
      }
    } else {
      _selectionEnd = position;
      if (compareWordPositions(_selectionEnd!, _selectionStart!) < 0) {
        final swap = _selectionStart;
        _selectionStart = _selectionEnd;
        _selectionEnd = swap;
        _heldGrip = 0;
      }
    }
  }

  /// Rebuilds the mark's text and rectangles from its two ends, and reports
  /// both — with the screen-space corners a menu anchors itself on.
  void _recomputeSelection({required bool finished}) {
    final start = _selectionStart;
    final end = _selectionEnd;
    if (start == null || end == null) return;
    final words = flattenWordRange(
      start: start,
      end: end,
      wordsForPage: _wordsForPage,
    );
    if (words.isEmpty) return;
    final lexicon = <String>{};
    for (var page = start.pageIndex; page <= end.pageIndex; page++) {
      lexicon.addAll(_lexiconForPage(page));
    }
    final selection = buildWordRangeSelection(
      words,
      0,
      words.length - 1,
      // The pages' own vocabulary, so copied text keeps real compound
      // hyphens and loses the hyphenation ones (see [joinLines]).
      lexicon: lexicon,
    );
    setState(() {
      _selectionRectsPdf = selection.rects;
      _selectionText = selection.text;
    });
    widget.onRangeSelected(selection.text, finished, selectionAnchors());
  }

  void _finishSelection() {
    _stopAutoScroll();
    _heldGrip = null;
    _gripPointer = null;
    if (_selectionEnd == null) return;
    _recomputeSelection(finished: true);
  }

  /// The mark's first and last line, in screen coordinates: what both the
  /// menu's anchors and the grips' positions are measured from.
  ({Rect first, Rect last})? _markCorners() {
    if (_selectionRectsPdf.isEmpty) return null;
    final first = _screenRectFor(_selectionRectsPdf.first);
    final last = _screenRectFor(_selectionRectsPdf.last);
    if (first == null || last == null) return null;
    return (first: first, last: last);
  }

  /// The mark's corners on screen: where a menu should sit above the mark,
  /// and where it should fall back to below it — the same pair of anchors
  /// `TextSelectionToolbarLayoutDelegate` is handed for real text.
  ///
  /// In this view's own coordinates, which is the space the reader lays the
  /// menu in — the view fills the screen it is read on, the same way the
  /// system's own anchors are the coordinates of the surface they mark.
  RangeAnchors? selectionAnchors() {
    final corners = _markCorners();
    if (corners == null) return null;
    // A mark the reader has panned partly past the edge still gets its menu
    // on screen, at the edge it went past.
    double inside(double dy) => dy.clamp(0.0, math.max(0.0, _viewportHeight));
    return (
      above: Offset(corners.first.left, inside(corners.first.top)),
      below: Offset(corners.last.right, inside(corners.last.bottom)),
    );
  }

  /// Where the two grips belong: the start grip at the left edge of the
  /// mark's first line, the end grip at the right edge of its last.
  ///
  /// Clamped to the viewport, because a mark that has been dragged partly
  /// past the edge has to keep both of its grips reachable.
  ({Offset start, Offset end})? gripAnchors() {
    final corners = _markCorners();
    if (corners == null) return null;
    Offset clamp(Offset point) => Offset(
      point.dx.clamp(
        _gripMargin,
        math.max(_gripMargin, _viewportWidth - _gripMargin),
      ),
      point.dy.clamp(
        _gripMargin,
        math.max(_gripMargin, _viewportHeight - _gripMargin),
      ),
    );
    return (
      start: clamp(Offset(corners.first.left, corners.first.bottom)),
      end: clamp(Offset(corners.last.right, corners.last.bottom)),
    );
  }

  Rect? _screenRectFor(MarkedLine line) {
    final content = _contentRectFor(line.pageIndex, line.bounds);
    if (content == null) return null;
    return Rect.fromLTWH(
      (content.left - _scrollOffset.dx) * _zoom,
      (content.top - _scrollOffset.dy) * _zoom,
      content.width * _zoom,
      content.height * _zoom,
    );
  }

  // --- dragging a grip -------------------------------------------------

  void _gripDragStart(int grip, Offset localPoint) {
    _flingController.stop();
    _longPressTimer?.cancel();
    _longPressFired = false;
    setState(() {
      _heldGrip = grip;
      _gripPointer = localPoint;
    });
    _updateAutoScroll();
    _pokeBubble();
  }

  void _gripDragUpdate(int grip, Offset localPoint) {
    _extendSelection(localPoint);
  }

  void _gripDragEnd() {
    _finishSelection();
    _reportViewSettled();
  }

  /// Starts, keeps or stops the scroll that runs while a grip is held near
  /// the top or bottom edge.
  void _updateAutoScroll() {
    final pointer = _gripPointer;
    if (pointer == null || _heldGrip == null) {
      _stopAutoScroll();
      return;
    }
    final edge = _autoScrollEdge;
    double direction = 0;
    if (pointer.dy < edge) {
      direction = -1;
    } else if (pointer.dy > _viewportHeight - edge) {
      direction = 1;
    }
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (direction == 0) return;
    _autoScrollTimer = Timer.periodic(_autoScrollTick, (_) {
      _scrollUnderGrip(direction);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _scrollUnderGrip(double direction) {
    final pointer = _gripPointer;
    if (pointer == null) {
      _stopAutoScroll();
      return;
    }
    final maxDy = math.max(0.0, _totalContentHeight - _viewportHeight / _zoom);
    // The scroll offset is in content space and the grip is on screen, so
    // a zoomed-in page has to move proportionally less to keep up with the
    // finger's edge.
    final newDy = (_scrollOffset.dy + direction * _autoScrollSpeed / _zoom)
        .clamp(0.0, maxDy);
    if (newDy == _scrollOffset.dy) {
      // Out of document to scroll — the mark simply stops growing here.
      _stopAutoScroll();
      return;
    }
    setState(() => _scrollOffset = Offset(_scrollOffset.dx, newDy));
    _maybeReportPageChange();
    _pokeBubble();
    final position = _wordPositionAt(pointer);
    final grip = _heldGrip;
    if (position != null && grip != null) _moveGripTo(grip, position);
    _recomputeSelection(finished: false);
  }

  /// Called when the reader dismisses the selection (a tap elsewhere, or
  /// closing the actions that go with it).
  void clearRangeSelection() {
    if (!_hasRangeSelection && _selectionStart == null) return;
    _stopAutoScroll();
    setState(() {
      _selectionStart = null;
      _selectionEnd = null;
      _selectionRectsPdf = const [];
      _selectionText = '';
      _heldGrip = null;
      _gripPointer = null;
    });
  }

  /// «Выбрать всё» over a scan: the whole page being read, marked. The
  /// picture-only view has no text region to select through, so this does
  /// by word index what [SelectionArea.selectAll] does for a real one.
  void selectAllOnCurrentPage() {
    final page = (_selectionStart?.pageIndex ?? _reportedPage - 1).clamp(
      0,
      widget.pageSizes.isEmpty ? 0 : widget.pageSizes.length - 1,
    );
    final words = _wordsForPage(page);
    if (words.isEmpty) return;
    _selectionStart = (pageIndex: page, wordIndex: 0);
    _selectionEnd = (pageIndex: page, wordIndex: words.length - 1);
    _heldGrip = null;
    _gripPointer = null;
    _recomputeSelection(finished: true);
  }

  double _renderScaleFor(
    int pageIndex,
    double dpr,
    double supersample,
    double zoomTier,
  ) {
    final size = widget.pageSizes[pageIndex];
    if (size.width <= 0) return dpr * zoomTier;
    final scale = (_contentWidth / size.width) * dpr * supersample * zoomTier;
    // A whole page at a high zoom is a bitmap bigger than a phone can
    // decode; past this many pixels the visible part is rendered on its own
    // instead (see [_detail]), so the page itself can stop here.
    const maxPixels = 14e6;
    final pixels = size.width * size.height * scale * scale;
    if (pixels <= maxPixels) return scale;
    return scale * math.sqrt(maxPixels / pixels);
  }

  /// The zoom level a page's bitmap should be rasterized at, quantized into
  /// a few tiers. Zoom is applied with a [Transform] (a pure upscale of the
  /// bitmap we hold), so a page rendered at fit-to-width goes soft the moment
  /// the reader pinches out — thin lines in a diagram blur to mush. Re-
  /// rasterizing at a resolution that tracks the zoom keeps the page crisp.
  ///
  /// The tiers are deliberately coarse: a continuous scale would re-render on
  /// every pinch frame (rasterizing is the most expensive step in the whole
  /// view), so we only re-render when the zoom crosses a tier boundary. The
  /// top tier matches the max zoom, so at full zoom the page is rendered at
  /// exactly the pixels on screen — no upscale at all.
  ///
  /// Rounded *up*: a page shown at 1.2x from a bitmap rendered for 1.0x is a
  /// bitmap stretched by a fifth, and stretched text is soft text. Rendering
  /// for the next tier up only ever shrinks a bitmap on its way to the screen.
  double _zoomRenderScale() {
    const tiers = [1.0, 1.25, 1.5, 2.0];
    for (final t in tiers) {
      if (_zoom <= t + 0.01) return t;
    }
    return tiers.last;
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

  void _pruneImageCache(int lo, int hi, double zoomTier) {
    // A change of zoom tier means every cached bitmap was rasterized at the
    // wrong resolution for the new zoom, so drop them all and let the pages
    // re-render at the new scale (see [_zoomRenderScale]).
    if (zoomTier != _renderedZoomTier) {
      _renderedZoomTier = zoomTier;
      _imageFutures.clear();
    }
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
          _reanchorSelection();
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

  /// The two grips at the ends of a mark.
  ///
  /// They are drawn in screen space rather than over the page, so a grip
  /// stays the size a thumb can hit at any zoom, and they sit above the
  /// reading surface in the widget tree, which means a drag that starts on
  /// one belongs to the mark and never to the page underneath it.
  List<Widget> _buildGrips() {
    final anchors = gripAnchors();
    if (anchors == null) return const [];
    return [_buildGrip(0, anchors.start), _buildGrip(1, anchors.end)];
  }

  Widget _buildGrip(int index, Offset anchor) {
    return Positioned(
      left: (anchor.dx - _gripTouchSize / 2).clamp(
        0.0,
        math.max(0.0, _viewportWidth - _gripTouchSize),
      ),
      top: (anchor.dy - _gripTouchSize / 2).clamp(
        0.0,
        math.max(0.0, _viewportHeight - _gripTouchSize),
      ),
      width: _gripTouchSize,
      height: _gripTouchSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            _gripDragStart(index, _viewLocal(details.globalPosition)),
        onPanUpdate: (details) =>
            _gripDragUpdate(index, _viewLocal(details.globalPosition)),
        onPanEnd: (_) => _gripDragEnd(),
        onPanCancel: _gripDragEnd,
        child: Center(
          child: Container(
            width: _gripWidth,
            height: _gripHeight,
            decoration: BoxDecoration(
              color: widget.highlightColor,
              borderRadius: BorderRadius.circular(_gripWidth / 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A global point (what a gesture reports) in this view's own space,
  /// which is the space every hit test here works in.
  Offset _viewLocal(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return global;
    return box.globalToLocal(global);
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
        // The screen's own density, whatever it is: a cap of 3x stretched
        // every page on the phones denser than that, and stretched text is
        // blurred text. No supersampling on top of it either — a bitmap
        // bigger than the screen is shrunk on the way there, and shrinking
        // thins the strokes of small type into grey.
        final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 4.0);
        const supersample = 1.0;
        // The sharp render resolution tracks the zoom tier, so zooming in
        // re-rasterizes at higher resolution instead of just upscaling the
        // fit-width bitmap (which is what made thin lines go soft).
        final zoomTier = _zoomRenderScale();

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
        _pruneImageCache(lo, hi, zoomTier);

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
            _renderScaleFor(visibleIndex, dpr, supersample, zoomTier),
          );
          for (var i = lo; i <= hi; i++) {
            if (i == visibleIndex) continue;
            _previewFor(i);
            _imageFor(i, _renderScaleFor(i, dpr, supersample, zoomTier));
          }
        }

        final searchRect = _searchHighlightPage != null
            ? _contentRectFor(_searchHighlightPage, _searchHighlightRectPdf)
            : null;
        final searchOtherRects = <Rect>[
          if (_searchHighlightPage != null)
            for (final r in _searchHighlightOtherRectsPdf)
              if (_contentRectFor(_searchHighlightPage, r) case final rect?)
                rect,
        ];
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
            if (_contentRectFor(r.pageIndex, r.bounds) case final rect?) rect,
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
                      if (_detail case final detail?)
                        if (_contentRectFor(detail.page, detail.pdfBounds)
                            case final rect?)
                          Positioned.fromRect(
                            key: ValueKey(
                              'detail-${detail.page}-${detail.pdfBounds}',
                            ),
                            rect: rect,
                            child: IgnorePointer(
                              child: ColorFiltered(
                                colorFilter: widget.readingTheme
                                    .pageImageFilter(
                                      contrast: widget.readingContrast,
                                      weight: widget.readingWeight,
                                    ),
                                child: Image.memory(
                                  detail.bytes,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.medium,
                                ),
                              ),
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
                      // The page's other matches, faint, go down first so
                      // the current one (full strength, right below) always
                      // reads as the stronger mark if they ever overlap.
                      for (final rect in searchOtherRects)
                        _Highlight(
                          rect: rect,
                          color: theme.wordHighlight.withValues(alpha: 0.35),
                          theme: theme,
                        ),
                      if (searchRect != null)
                        _Highlight(
                          rect: searchRect,
                          color: theme.wordHighlight,
                          theme: theme,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ..._buildGrips(),
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
        // Medium (mipmapped) for both: the sharp render meets the screen
        // pixel for pixel at its own zoom tier and is scaled a little either
        // side of it in between, and bilinear filtering alone drops the
        // thin strokes of small type when a bitmap is scaled down.
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
