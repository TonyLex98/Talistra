import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/djvu_service.dart';

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

/// The narrowest and widest raster widths the native decoder will take
/// (the Android side clamps requests to the same ceiling).
const int _minRenderWidth = 480;
const int _maxRenderWidth = 2400;

/// How wide neighbour pages are prefetched at — they're only glimpsed
/// while scrolling, so they don't pay full-resolution cost up front.
const int _neighborWidthCap = 1400;

/// The scan counterpart of the PDF reading surface: pages form one
/// continuous vertical document, with a single pan-and-pinch gesture,
/// fling momentum, and a page scrubber that fades away while reading.
class DjvuPageStackView extends StatefulWidget {
  const DjvuPageStackView({
    super.key,
    required this.document,
    required this.initialPage,
    required this.initialZoom,
    required this.initialScrollFraction,
    required this.initialScrollFractionX,
    required this.background,
    required this.imageFilter,
    required this.onPageChanged,
    required this.onZoomChanged,
    required this.onViewSettled,
  });

  final DjvuDocument document;
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

  final Color background;
  final ColorFilter imageFilter;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<bool> onZoomChanged;

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
  State<DjvuPageStackView> createState() => DjvuPageStackViewState();
}

class DjvuPageStackViewState extends State<DjvuPageStackView>
    with SingleTickerProviderStateMixin {
  late final Future<List<DjvuPageInfo>> _infosFuture = Future.wait([
    for (var page = 0; page < widget.document.pageCount; page++)
      widget.document.pageInfo(page),
  ]);
  final Map<int, Future<Uint8List?>> _imageFutures = {};
  final Map<int, Future<Uint8List?>> _previewFutures = {};

  List<DjvuPageInfo>? _infos;
  List<double> _cumulativeY = const [];
  List<double> _pageHeights = const [];
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
  double _zoom = _minZoom;
  Offset _scrollOffset = Offset.zero;
  bool _initialPositioned = false;
  int _reportedPage = 1;

  double _gestureStartZoom = _minZoom;
  Offset _gestureStartFocalScreen = Offset.zero;
  Offset _gestureStartFocalContent = Offset.zero;
  bool _horizontalUnlocked = false;
  int _activePointerCount = 0;

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
    final index = (page - 1).clamp(0, _cumulativeY.length - 1);
    if (!resetZoom && index + 1 == _reportedPage) return;
    _flingController.stop();
    setState(() {
      // Only a deliberate "go to page" jump re-centers horizontally too —
      // a mode-switch re-sync must leave the reader's own horizontal pan
      // position exactly where it was, the same way it already leaves
      // zoom untouched.
      final dx = resetZoom ? 0.0 : _scrollOffset.dx;
      _scrollOffset = Offset(dx, _cumulativeY[index]);
      if (resetZoom) _zoom = _minZoom;
      _bubbleVisible = true;
    });
    _reportedPage = index + 1;
    widget.onZoomChanged(_zoom > 1.015);
    widget.onPageChanged(index + 1);
    _pokeBubble();
    _reportViewSettled();
  }

  void changeZoom(double delta) {
    final next = (_zoom + delta).clamp(_minZoom, _maxZoom).toDouble();
    if ((next - _zoom).abs() < 0.001) return;
    final focal = Offset(_viewportWidth / 2, _viewportHeight / 2);
    final content = Offset(
      focal.dx / _zoom + _scrollOffset.dx,
      focal.dy / _zoom + _scrollOffset.dy,
    );
    final maxDx = math.max(0.0, _viewportWidth - _viewportWidth / next);
    final maxDy = math.max(0.0, _totalHeight - _viewportHeight / next);
    setState(() {
      _zoom = next;
      _scrollOffset = Offset(
        (content.dx - focal.dx / next).clamp(0, maxDx),
        (content.dy - focal.dy / next).clamp(0, maxDy),
      );
      _bubbleVisible = true;
    });
    widget.onZoomChanged(next > 1.015);
    _pokeBubble();
    _reportViewSettled();
  }

  double get _maxDx => math.max(0.0, _viewportWidth - _viewportWidth / _zoom);

  double get _totalHeight =>
      _pageHeights.isEmpty ? 0 : _cumulativeY.last + _pageHeights.last;

  void _reportViewSettled() {
    if (_pageHeights.isEmpty) return;
    final page = (_reportedPage - 1).clamp(0, _pageHeights.length - 1);
    final fraction = _pageHeights[page] > 0
        ? ((_scrollOffset.dy - _cumulativeY[page]) / _pageHeights[page])
            .clamp(0.0, 1.0)
        : 0.0;
    final maxDx = _maxDx;
    final fractionX = maxDx > 0
        ? (_scrollOffset.dx / maxDx).clamp(0.0, 1.0)
        : 0.0;
    widget.onViewSettled(_zoom, fraction, fractionX);
  }

  void _ensureLayout(BoxConstraints constraints) {
    final infos = _infos;
    if (infos == null ||
        (constraints.maxWidth == _viewportWidth &&
            constraints.maxHeight == _viewportHeight &&
            _fittedContentWidth(
              constraints.maxWidth,
              constraints.maxHeight,
            ) ==
                _contentWidth)) {
      return;
    }

    // Capture the current logical position (which page, how far into
    // it) against the OLD layout before recomputing page heights for
    // the new width, and restore it afterwards — otherwise a raw pixel
    // scrollOffset silently points at the wrong spot once page heights
    // change (e.g. after a rotation flips the viewport's aspect ratio).
    int? capturedPage;
    double? capturedFraction;
    if (_pageHeights.isNotEmpty) {
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

    _viewportWidth = constraints.maxWidth;
    _viewportHeight = constraints.maxHeight;
    _contentWidth = _fittedContentWidth(constraints.maxWidth, constraints.maxHeight);
    _pageLeft = ((constraints.maxWidth - _contentWidth) / 2).clamp(
      0.0,
      constraints.maxWidth,
    );
    final cumulative = <double>[];
    final heights = <double>[];
    var y = 0.0;
    for (final info in infos) {
      cumulative.add(y);
      final aspect = info.aspectRatio.isFinite && info.aspectRatio > 0
          ? info.aspectRatio
          : 0.7;
      final height = _contentWidth / aspect;
      heights.add(height);
      y += height + _pageSpacing;
    }
    _cumulativeY = cumulative;
    _pageHeights = heights;

    if (capturedPage != null && capturedFraction != null) {
      _scrollOffset = Offset(
        capturedFractionX * _maxDx,
        _cumulativeY[capturedPage] +
            capturedFraction * _pageHeights[capturedPage],
      );
    } else if (!_initialPositioned) {
      _initialPositioned = true;
      final index = (widget.initialPage - 1).clamp(0, infos.length - 1);
      final fraction = widget.initialScrollFraction.clamp(0.0, 1.0);
      final fractionX = widget.initialScrollFractionX.clamp(0.0, 1.0);
      _scrollOffset = Offset(
        fractionX * _maxDx,
        _cumulativeY[index] + fraction * _pageHeights[index],
      );
      _reportedPage = index + 1;
    } else {
      _scrollOffset = Offset(
        _scrollOffset.dx.clamp(0, _maxDx),
        _scrollOffset.dy.clamp(
          0,
          math.max(0, _totalHeight - _viewportHeight / _zoom),
        ),
      );
    }
  }

  /// The width to draw pages at: the viewport in portrait, and whatever
  /// makes the page fit vertically in landscape.
  double _fittedContentWidth(double viewportWidth, double viewportHeight) {
    final infos = _infos;
    if (viewportWidth <= viewportHeight ||
        viewportHeight <= 0 ||
        infos == null ||
        infos.isEmpty) {
      return viewportWidth;
    }
    var aspect = 0.7;
    for (final info in infos) {
      if (info.aspectRatio.isFinite && info.aspectRatio > 0) {
        aspect = info.aspectRatio;
        break;
      }
    }
    // A hair under the full height, so a page turn doesn't clip.
    final fitted = viewportHeight * 0.98 * aspect;
    return math.min(viewportWidth, fitted);
  }

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
    _pokeBubble();
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_viewportWidth <= 0) return;
    _pokeBubble();
    // A pinch briefly reports pointerCount back down to 1 as fingers
    // lift, so once a gesture has ever seen 2+ pointers it's remembered
    // for the rest of the gesture.
    if (details.pointerCount > _activePointerCount) {
      _activePointerCount = details.pointerCount;
    }

    final nextZoom = (_gestureStartZoom * details.scale)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    final totalDx = details.localFocalPoint.dx - _gestureStartFocalScreen.dx;

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

    final maxDx = math.max(0.0, _viewportWidth - _viewportWidth / nextZoom);
    final maxDy = math.max(
      0.0,
      _totalHeight - _viewportHeight / nextZoom,
    );
    setState(() {
      _zoom = nextZoom;
      _scrollOffset = Offset(
        (_gestureStartFocalContent.dx - effectiveFocalX / nextZoom).clamp(
          0.0,
          maxDx,
        ),
        (_gestureStartFocalContent.dy -
                details.localFocalPoint.dy /
                    nextZoom)
            .clamp(0.0, maxDy),
      );
    });
    widget.onZoomChanged(nextZoom > 1.015);
    _maybeReportPageChange();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_activePointerCount <= 1 && !_horizontalUnlocked) {
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
    final maxDy = math.max(0.0, _totalHeight - _viewportHeight / _zoom);
    if (maxDy <= 0) return;
    _flingController.value = _scrollOffset.dy;
    final simulation = ClampingScrollSimulation(
      position: _scrollOffset.dy,
      velocity: contentVelocity,
    );
    _flingController.animateWith(simulation);
  }

  void _onFlingTick() {
    final maxDy = math.max(0.0, _totalHeight - _viewportHeight / _zoom);
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
    // In a continuous reader the page at the very top can be only its
    // trailing footer. Report the page the reader is actually looking at,
    // matching the PDF stack instead of leaving the header one page behind.
    final focusY = _scrollOffset.dy + _viewportHeight / _zoom * 0.35;
    var page = 0;
    for (var i = 0; i < _cumulativeY.length; i++) {
      page = i;
      if (_cumulativeY[i] + _pageHeights[i] >= focusY) break;
    }
    if (page + 1 == _reportedPage) return;
    _reportedPage = page + 1;
    widget.onPageChanged(_reportedPage);
  }

  /// A cheap, low-resolution render of the same pages. Rasterizing a page
  /// at reading sharpness takes long enough to notice, so every page is
  /// asked for twice: this one first (a fraction of the pixels, so it lands
  /// almost immediately and the reader sees the page rather than blank
  /// paper), then the sharp one, which quietly replaces it.
  Future<Uint8List?> _previewFor(int pageIndex, int width) {
    final key = pageIndex * _keyStride + width;
    return _previewFutures.putIfAbsent(
      key,
      () => _render(pageIndex, width),
    );
  }

  Future<Uint8List?> _imageFor(int pageIndex, int width) {
    final key = pageIndex * _keyStride + width;
    return _imageFutures.putIfAbsent(
      key,
      () => _render(pageIndex, width),
    );
  }

  /// The raster width for the page the reader is actually looking at: the
  /// scan's own pixel width, clamped to what the decoder takes. See the
  /// comment in [build] about why a scanned page wants its native
  /// resolution rather than a screen-fit one.
  int _sharpWidthFor(int page) {
    final native = _infos![page].width;
    if (native <= 0) return 1200;
    return native.clamp(_minRenderWidth, _maxRenderWidth).toInt();
  }

  /// Neighbour pages are only glimpsed while scrolling, so they queue up at
  /// a reduced width — a fraction of the pixels, decoded in a fraction of
  /// the time. The moment one of them becomes the page being looked at, it
  /// is re-asked for at full resolution and quietly swapped in over the
  /// cheap one.
  int _neighborWidthFor(int page) {
    final native = _infos![page].width;
    if (native <= 0) return 900;
    return math.min(native, _neighborWidthCap)
        .clamp(_minRenderWidth, _maxRenderWidth)
        .toInt();
  }

  Future<Uint8List?> _render(int pageIndex, int width) async {
    final info = _infos![pageIndex];
    final aspect = info.aspectRatio.isFinite && info.aspectRatio > 0
        ? info.aspectRatio
        : 0.7;
    try {
      return await widget.document.renderPage(
        pageIndex,
        width: width,
        height: (width / aspect).round().clamp(1, 4000),
      );
    } catch (_) {
      return null;
    }
  }

  void _pruneImageCache(int lo, int hi) {
    _imageFutures.removeWhere((key, _) {
      final page = key ~/ _keyStride;
      return page < lo - 2 || page > hi + 2;
    });
    _previewFutures.removeWhere((key, _) {
      final page = key ~/ _keyStride;
      return page < lo - 4 || page > hi + 4;
    });
  }

  double get _maxDyForScrub =>
      math.max(0.0, _totalHeight - _viewportHeight / _zoom);

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
    return FutureBuilder<List<DjvuPageInfo>>(
      future: _infosFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        _infos = snapshot.data;
        return LayoutBuilder(
          builder: (context, constraints) {
            _ensureLayout(constraints);
            if (_cumulativeY.isEmpty) return const SizedBox.shrink();

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

            // A DjVu page is a photograph of paper: it has a fixed amount
            // of detail in it, and the page's own pixel width (from
            // [DjvuPageInfo.width]) is exactly how much. So the page being
            // looked at is rasterized at its *native* resolution (capped by
            // what the decoder will take) — never "just enough to fill the
            // screen", which throws letterforms away before they reach the
            // glass, and never more, which would only upscale the
            // photograph. At native, every zoom level then samples the
            // full-detail image: a clean downscale at zoom 1, near 1:1 at
            // the top of the range. (This is the difference from a PDF:
            // its text is vector and re-appears crisp at any resolution,
            // while a scan only ever has the pixels it was born with.)
            final previewWidth = (_contentWidth * 2).round().clamp(320, 1000);

            // Rasterizing is serialized in the native plugin, so the order
            // requests go in *is* the order they come back: the page being
            // looked at is asked for first, and its neighbours (prefetched
            // for a smooth scroll) queue up behind it.
            //
            // And while the scrubber is being dragged, nothing is requested
            // at all: a drag crosses dozens of pages, and every one of them
            // used to enqueue a full-page render that couldn't be cancelled,
            // so by the time the finger stopped there was a backlog of
            // stale pages to grind through before the page actually being
            // looked at got its turn. Nothing is requested until the drag
            // settles.
            final visibleIndex = (_reportedPage - 1).clamp(lo, hi);
            if (!_scrubbing) {
              // Order is everything, since the plugin rasterizes one page at
              // a time: the page being looked at gets its quick preview
              // first, then its full-resolution render, and only then do the
              // neighbours queue up (at a reduced width — see
              // [_neighborWidthFor]).
              _previewFor(visibleIndex, previewWidth);
              _imageFor(visibleIndex, _sharpWidthFor(visibleIndex));
              for (var i = lo; i <= hi; i++) {
                if (i == visibleIndex) continue;
                _previewFor(i, previewWidth);
                _imageFor(i, _neighborWidthFor(i));
              }
            }

            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: widget.background),
                ),
                ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: Transform(
                      transform: Matrix4.identity()
                        ..scaleByDouble(_zoom, _zoom, 1, 1)
                        ..translateByDouble(
                          -_scrollOffset.dx,
                          -_scrollOffset.dy,
                          0,
                          1,
                        ),
                      // No explicit size here: a Box can never legally be
                      // bigger than the (viewport-sized, tight) constraints
                      // handed down from the parent, so sizing this to the
                      // full scrollable content height would just get
                      // clamped back to viewport size. Instead this Stack
                      // stays viewport-sized and its Positioned children
                      // (in content-space coordinates, which routinely fall
                      // far outside those bounds) are left unclipped —
                      // only the outer [ClipRect] needs to constrain what's
                      // visible.
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var page = lo; page <= hi; page++)
                            Positioned(
                              key: ValueKey('page-$page'),
                              left: _pageLeft,
                              top: _cumulativeY[page],
                              width: _contentWidth,
                              height: _pageHeights[page],
                              child: _DjvuStackPageImage(
                                key: ValueKey('img-$page'),
                                // The page being looked at is drawn from
                                // its full-resolution render; its
                                // neighbours from the reduced-width one
                                // (which they upgrade to the moment they
                                // become the page being looked at).
                                future: _imageFutures[
                                    page * _keyStride +
                                    (page == visibleIndex
                                        ? _sharpWidthFor(page)
                                        : _neighborWidthFor(page))],
                                previewFuture: _previewFutures[
                                    page * _keyStride + previewWidth],
                                filter: widget.imageFilter,
                                background: widget.background,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                _buildScrubber(
                  math.min(_reportedPage, widget.document.pageCount),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The scrubber's own geometry: a pill on the right edge, sitting at
/// whatever fraction of the document is currently on screen.
const double _scrubberHeight = 40;
const double _scrubberMargin = 8;

/// The cache key packs page index and pixel width into one int, so
/// [DjvuPageStackViewState._pruneImageCache] can evict by page alone.
const int _keyStride = 1000000;

class _DjvuStackPageImage extends StatefulWidget {
  const _DjvuStackPageImage({
    super.key,
    required this.future,
    required this.previewFuture,
    required this.filter,
    required this.background,
  });

  /// The sharp render, and the quick low-resolution one that stands in
  /// until it arrives. Either may be null when nothing has been asked for
  /// yet (during a scrubber drag), in which case the page shows as blank
  /// reading surface.
  final Future<Uint8List?>? future;
  final Future<Uint8List?>? previewFuture;
  final ColorFilter filter;
  final Color background;

  @override
  State<_DjvuStackPageImage> createState() => _DjvuStackPageImageState();
}

class _DjvuStackPageImageState extends State<_DjvuStackPageImage> {
  Uint8List? _preview;
  Uint8List? _sharp;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_DjvuStackPageImage oldWidget) {
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
    if (bytes == null) return ColoredBox(color: widget.background);
    // The page arrives as opaque paper with the file's own colors on it;
    // the reading theme is applied here, to the finished image.
    return ColorFiltered(
      colorFilter: widget.filter,
      child: Image.memory(
        bytes,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        // Pages now arrive at (or above) display resolution, so sampling
        // is a downscale; linear filtering keeps downsampled type smooth
        // instead of stair-stepped (and the low-res stand-in still looks
        // better smoothed than blocky while it lasts).
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
