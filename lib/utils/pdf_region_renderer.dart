import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import 'page_ink_bounds.dart';
import 'priority_queue.dart';

/// Renders a cropped region of a PDF page to PNG bytes, for embedding real
/// images/diagrams/tables inline in the reflowed reading view. Uses
/// `pdfx` purely for rasterization — `syncfusion_flutter_pdf` (used
/// everywhere else in this app) has no page-to-image API in its free
/// tier. Calls are serialized because native PDF rendering on Android
/// doesn't support opening a second page before the previous one closes.
class PdfRegionRenderer {
  PdfRegionRenderer._(this._document, this._path);

  /// A renderer with no document behind it, for a test to subclass and
  /// answer the renders itself.
  @visibleForTesting
  PdfRegionRenderer.forTesting() : _document = null, _path = null;

  final pdfx.PdfDocument? _document;

  /// The file behind [_document], for the native region renderer (see
  /// [_renderNative]); null when there is none to hand it.
  final String? _path;

  /// Renders a rectangle straight into a bitmap of its own size, which `pdfx`
  /// cannot: it draws the *whole page* at the requested scale and crops after,
  /// so a zoomed-in view needs a bitmap of the whole page at that zoom (tens or
  /// hundreds of megapixels), and its crop also reads the width from the wrong
  /// field and fails for any region not flush with the left edge.
  static const MethodChannel _native = MethodChannel('litra/pdf_region');

  /// Set once the platform has no native renderer (iOS, a test), so it is not
  /// asked again.
  bool _nativeMissing = false;

  /// The renders waiting for their turn. The plugin rasterizes one page at a
  /// time, so what matters is which one goes next (see [PriorityJobQueue]).
  final PriorityJobQueue _queue = PriorityJobQueue();

  /// Priorities, for callers to pick from: the page being looked at, the ones
  /// beside it, and background work that can wait for all of them.
  static const int priorityVisible = 0;
  static const int priorityNear = 10;
  static const int priorityBackground = 100;

  static Future<PdfRegionRenderer> open(String filePath) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    return PdfRegionRenderer._(document, filePath);
  }

  /// The page color rasterized *behind* the PDF's own content.
  ///
  /// This must be opaque. `pdfx` defaults to a fully transparent
  /// background, which looks badly broken for reading: a PDF's paper is
  /// almost never painted by the file itself, so with a transparent
  /// background every glyph's antialiased edge (and any partially
  /// transparent content) blends with whatever happens to be behind the
  /// image instead of with paper — black text turns washed-out grey over
  /// a light app surface, and effectively invisible black-on-black over a
  /// dark one. Real white paper here keeps text pure black and crisp; the
  /// reading theme then recolors the finished, opaque page image (see
  /// `ReadingThemeStyle.pageImageFilter`).
  static const _pageBackground = '#FFFFFF';

  /// High enough that glyph edges show no artefacts at reading size, low
  /// enough to encode quickly.
  static const _jpegQuality = 92;

  /// Renders the [pdfBounds] region (PDF points, page-local, top-down) of
  /// page [pageIndex] (0-based) to image bytes at [scale]x the PDF's native
  /// resolution.
  ///
  /// JPEG, not PNG, and that is a deliberate performance decision: PNG's
  /// deflate pass over a multi-megapixel page was the single most expensive
  /// step in getting a page on screen (the rasterizing itself is much
  /// cheaper), and it was paid twice — once encoding in the plugin, once
  /// decoding in Flutter. At [_jpegQuality] the difference on text is not
  /// visible at reading size, and pages appear several times faster. The
  /// paper is rendered opaque anyway, so JPEG's lack of an alpha channel
  /// costs nothing.
  ///
  /// [priority] says how soon (lower is sooner; see [priorityVisible]).
  /// [isStale], asked when the job's turn comes, says the result is no
  /// longer wanted — the page has scrolled away, the view is gone — and the
  /// render is skipped: null comes back instead, at no cost.
  Future<Uint8List?> renderRegion({
    required int pageIndex,
    required Rect pdfBounds,
    double scale = 2.0,
    int priority = priorityVisible,
    int Function()? livePriority,
    bool Function()? isStale,
  }) {
    return _queue.add<Uint8List?>(
      () => _renderNow(pageIndex, pdfBounds, scale),
      priority: priority,
      livePriority: livePriority,
      isStale: isStale,
    );
  }

  /// Renders [pdfBounds] cropped down to whatever is actually drawn inside
  /// it, or null when the region turns out to be blank paper.
  ///
  /// Used for the reflowed view's figures. A "figure" there is inferred
  /// from a large vertical gap between text lines, which is a guess: the
  /// gap may be a real diagram, or just a section break or the page's
  /// bottom margin, and it always spans the full page width even when the
  /// diagram inside it is small and centered. So the region is first
  /// rendered small, purely to be measured ([findInkBounds]), and only
  /// then re-rendered at reading resolution — cropped to the content, with
  /// [_trimPadding] points of breathing room around it. Blank gaps
  /// disappear instead of showing an empty white slab.
  Future<({Uint8List bytes, Rect pdfBounds})?> renderTrimmedRegion({
    required int pageIndex,
    required Rect pdfBounds,
    double scale = 2.5,
    double probeTargetWidth = 320,
    int priority = priorityVisible,
    int Function()? livePriority,
    bool Function()? isStale,
  }) async {
    if (pdfBounds.width <= 0 || pdfBounds.height <= 0) return null;
    final probeScale = math.min(1.0, probeTargetWidth / pdfBounds.width);
    final probe = await renderRegion(
      pageIndex: pageIndex,
      pdfBounds: pdfBounds,
      scale: probeScale <= 0 ? 1.0 : probeScale,
      priority: priority,
      livePriority: livePriority,
      isStale: isStale,
    );
    if (probe == null || probe.isEmpty) return null;

    final ink = await findInkBounds(probe);
    if (ink == null) return null;

    final trimmed = Rect.fromLTRB(
      math.max(
        pdfBounds.left,
        pdfBounds.left + ink.left * pdfBounds.width - _trimPadding,
      ),
      math.max(
        pdfBounds.top,
        pdfBounds.top + ink.top * pdfBounds.height - _trimPadding,
      ),
      math.min(
        pdfBounds.right,
        pdfBounds.left + ink.right * pdfBounds.width + _trimPadding,
      ),
      math.min(
        pdfBounds.bottom,
        pdfBounds.top + ink.bottom * pdfBounds.height + _trimPadding,
      ),
    );
    // A sliver this thin is a stray rule or the edge of a neighbouring
    // line, not a figure worth its own block in the reflowed text.
    if (trimmed.width < 8 || trimmed.height < 8) return null;

    final bytes = await renderRegion(
      pageIndex: pageIndex,
      pdfBounds: trimmed,
      scale: scale,
      priority: priority,
      livePriority: livePriority,
      isStale: isStale,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes: bytes, pdfBounds: trimmed);
  }

  static const double _trimPadding = 3.0;

  /// The page's native size in PDF points, e.g. to compute a render
  /// [scale] for a target pixel width without a separate `syncfusion_flutter_pdf`
  /// document just for sizing.
  Future<Size> pageSize(int pageIndex) async =>
      await _queue.add(() => _pageSizeNow(pageIndex)) ?? Size.zero;

  Future<Size> _pageSizeNow(int pageIndex) async {
    final page = await _document!.getPage(pageIndex + 1);
    try {
      return Size(page.width, page.height);
    } finally {
      await page.close();
    }
  }

  Future<Uint8List?> _renderNow(
    int pageIndex,
    Rect pdfBounds,
    double scale,
  ) async {
    final native = await _renderNative(pageIndex, pdfBounds, scale);
    if (native != null) return native;
    return _renderWithPdfx(pageIndex, pdfBounds, scale);
  }

  /// [pdfBounds] drawn at [scale] pixels per point into a bitmap of just that
  /// size. Null when this platform can't (or the file wouldn't open there), and
  /// the caller falls back to `pdfx`.
  Future<Uint8List?> _renderNative(
    int pageIndex,
    Rect pdfBounds,
    double scale,
  ) async {
    final path = _path;
    if (path == null || _nativeMissing || !Platform.isAndroid) return null;
    final width = math.max(1, (pdfBounds.width * scale).round());
    final height = math.max(1, (pdfBounds.height * scale).round());
    try {
      return await _native.invokeMethod<Uint8List>('render', {
        'path': path,
        'page': pageIndex,
        'left': pdfBounds.left,
        'top': pdfBounds.top,
        'width': width,
        'height': height,
        'scale': scale,
        'quality': _jpegQuality,
      });
    } on MissingPluginException {
      _nativeMissing = true;
      return null;
    } on PlatformException {
      // The file wouldn't open there (or the bitmap was too big): pdfx's turn.
      return null;
    }
  }

  Future<Uint8List?> _renderWithPdfx(
    int pageIndex,
    Rect pdfBounds,
    double scale,
  ) async {
    final page = await _document!.getPage(pageIndex + 1);
    try {
      final fullWidth = page.width * scale;
      final fullHeight = page.height * scale;
      final left = (pdfBounds.left * scale).clamp(0.0, fullWidth);
      final top = (pdfBounds.top * scale).clamp(0.0, fullHeight);
      final right = (pdfBounds.right * scale).clamp(left + 1, fullWidth);
      final bottom = (pdfBounds.bottom * scale).clamp(top + 1, fullHeight);

      final image = await page.render(
        width: fullWidth,
        height: fullHeight,
        format: pdfx.PdfPageImageFormat.jpeg,
        quality: _jpegQuality,
        backgroundColor: _pageBackground,
        cropRect: Rect.fromLTRB(left, top, right, bottom),
      );
      return image?.bytes;
    } finally {
      await page.close();
    }
  }

  Future<void> close() async {
    // What is still waiting is not going to be wanted.
    _queue.cancelAll();
    await _queue.idle;
    final path = _path;
    if (path != null && !_nativeMissing && Platform.isAndroid) {
      try {
        await _native.invokeMethod<void>('close', {'path': path});
      } on PlatformException {
        // Best effort: the file is going away anyway.
      } on MissingPluginException {
        // Nothing was opened.
      }
    }
    await _document?.close();
  }
}
