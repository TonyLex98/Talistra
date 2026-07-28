import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/djvu_service.dart';

const _pageSpacing = 4.0;
const _minZoom = 1.0;
const _maxZoom = 3.0;

/// The scan counterpart of the PDF reading surface: pages form one
/// continuous vertical document, with a single pan-and-pinch gesture.
class DjvuPageStackView extends StatefulWidget {
  const DjvuPageStackView({
    super.key,
    required this.document,
    required this.initialPage,
    required this.background,
    required this.imageFilter,
    required this.onPageChanged,
    required this.onZoomChanged,
  });

  final DjvuDocument document;
  final int initialPage;
  final Color background;
  final ColorFilter imageFilter;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<DjvuPageStackView> createState() => DjvuPageStackViewState();
}

class DjvuPageStackViewState extends State<DjvuPageStackView> {
  late final Future<List<DjvuPageInfo>> _infosFuture = Future.wait([
    for (var page = 0; page < widget.document.pageCount; page++)
      widget.document.pageInfo(page),
  ]);
  final Map<String, Future<Uint8List>> _renders = {};

  List<DjvuPageInfo>? _infos;
  List<double> _cumulativeY = const [];
  List<double> _pageHeights = const [];
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  double _zoom = _minZoom;
  Offset _scrollOffset = Offset.zero;
  Offset _gestureStartFocalContent = Offset.zero;
  double _gestureStartZoom = _minZoom;
  bool _initialPositioned = false;
  int _reportedPage = 1;
  bool _bubbleVisible = true;
  bool _scrubbing = false;

  double get _maxDx => math.max(0.0, _viewportWidth - _viewportWidth / _zoom);

  double get _totalHeight =>
      _pageHeights.isEmpty ? 0 : _cumulativeY.last + _pageHeights.last;

  void jumpToPage(int page) {
    if (_cumulativeY.isEmpty) return;
    final index = (page - 1).clamp(0, _cumulativeY.length - 1);
    setState(() {
      _scrollOffset = Offset(0, _cumulativeY[index]);
      _zoom = _minZoom;
      _reportedPage = index + 1;
      _bubbleVisible = true;
    });
    widget.onZoomChanged(false);
    widget.onPageChanged(index + 1);
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
  }

  void _ensureLayout(BoxConstraints constraints) {
    final infos = _infos;
    if (infos == null ||
        (constraints.maxWidth == _viewportWidth &&
            constraints.maxHeight == _viewportHeight &&
            _pageHeights.length == infos.length)) {
      return;
    }
    _viewportWidth = constraints.maxWidth;
    _viewportHeight = constraints.maxHeight;
    final cumulative = <double>[];
    final heights = <double>[];
    var y = 0.0;
    for (final info in infos) {
      cumulative.add(y);
      final aspect = info.aspectRatio.isFinite && info.aspectRatio > 0
          ? info.aspectRatio
          : 0.7;
      final height = _viewportWidth / aspect;
      heights.add(height);
      y += height + _pageSpacing;
    }
    _cumulativeY = cumulative;
    _pageHeights = heights;
    if (!_initialPositioned) {
      _initialPositioned = true;
      final index = (widget.initialPage - 1).clamp(0, infos.length - 1);
      _scrollOffset = Offset(0, _cumulativeY[index]);
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

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartZoom = _zoom;
    _gestureStartFocalContent = Offset(
      details.localFocalPoint.dx / _zoom + _scrollOffset.dx,
      details.localFocalPoint.dy / _zoom + _scrollOffset.dy,
    );
    if (!_bubbleVisible) setState(() => _bubbleVisible = true);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_pageHeights.isEmpty) return;
    final nextZoom = (_gestureStartZoom * details.scale)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    final maxDx = math.max(0.0, _viewportWidth - _viewportWidth / nextZoom);
    final maxDy = math.max(0.0, _totalHeight - _viewportHeight / nextZoom);
    setState(() {
      _zoom = nextZoom;
      _scrollOffset = Offset(
        (_gestureStartFocalContent.dx - details.localFocalPoint.dx / nextZoom)
            .clamp(0, maxDx),
        (_gestureStartFocalContent.dy - details.localFocalPoint.dy / nextZoom)
            .clamp(0, maxDy),
      );
    });
    widget.onZoomChanged(nextZoom > 1.015);
    _maybeReportPageChange();
  }

  void _onScaleEnd(ScaleEndDetails _) {
    if (!_bubbleVisible) setState(() => _bubbleVisible = true);
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

  void _updateScrub(double deltaY) {
    final maxDy = math.max(0.0, _totalHeight - _viewportHeight / _zoom);
    final track = math.max(1.0, _viewportHeight - 56);
    setState(() {
      _scrollOffset = Offset(
        _scrollOffset.dx,
        (_scrollOffset.dy + deltaY / track * maxDy).clamp(0, maxDy),
      );
    });
    _maybeReportPageChange();
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
            final maxDy = math.max(0, _totalHeight - _viewportHeight / _zoom);
            var lo = 0;
            for (var i = 0; i < _cumulativeY.length; i++) {
              lo = i;
              if (_cumulativeY[i] + _pageHeights[i] >= _scrollOffset.dy) break;
            }
            var hi = lo;
            final bottom = _scrollOffset.dy + _viewportHeight / _zoom;
            for (var i = lo; i < _cumulativeY.length; i++) {
              if (_cumulativeY[i] > bottom) break;
              hi = i;
            }
            lo = math.max(0, lo - 1);
            hi = math.min(_pageHeights.length - 1, hi + 1);
            final renderWidth =
                (_viewportWidth *
                        MediaQuery.devicePixelRatioOf(context) *
                        (_zoom > 1.015 ? 1.5 : 1))
                    .round()
                    .clamp(720, 1800);

            return Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: widget.background)),
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
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (var page = lo; page <= hi; page++)
                            Positioned(
                              key: ValueKey(page),
                              left: 0,
                              top: _cumulativeY[page],
                              width: _viewportWidth,
                              height: _pageHeights[page],
                              child: _DjvuStackPageImage(
                                future: _renders.putIfAbsent(
                                  '$page-$renderWidth',
                                  () => widget.document.renderPage(
                                    page,
                                    width: renderWidth,
                                    height:
                                        (renderWidth /
                                                _infos![page].aspectRatio)
                                            .round()
                                            .clamp(1, 4000),
                                  ),
                                ),
                                filter: widget.imageFilter,
                                background: widget.background,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  top:
                      8 +
                      (maxDy == 0
                          ? 0
                          : (_scrollOffset.dy / maxDy).clamp(0.0, 1.0) *
                                math.max(0, _viewportHeight - 56)),
                  child: GestureDetector(
                    onVerticalDragStart: (_) => setState(() {
                      _scrubbing = true;
                      _bubbleVisible = true;
                    }),
                    onVerticalDragUpdate: (details) =>
                        _updateScrub(details.delta.dy),
                    onVerticalDragEnd: (_) =>
                        setState(() => _scrubbing = false),
                    onVerticalDragCancel: () =>
                        setState(() => _scrubbing = false),
                    child: AnimatedOpacity(
                      opacity: _bubbleVisible || _scrubbing ? 1 : 0.62,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.drag_indicator,
                              size: 15,
                              color: Colors.white70,
                            ),
                            Text(
                              '$_reportedPage',
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
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DjvuStackPageImage extends StatelessWidget {
  const _DjvuStackPageImage({
    required this.future,
    required this.filter,
    required this.background,
  });

  final Future<Uint8List> future;
  final ColorFilter filter;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return ColoredBox(color: background);
        return ColorFiltered(
          colorFilter: filter,
          child: Image.memory(
            bytes,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        );
      },
    );
  }
}
