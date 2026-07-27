import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:pdfx/pdfx.dart' as pdfx;

import 'page_ink_bounds.dart';

/// Renders a cropped region of a PDF page to PNG bytes, for embedding real
/// images/diagrams/tables inline in the reflowed reading view. Uses
/// `pdfx` purely for rasterization — `syncfusion_flutter_pdf` (used
/// everywhere else in this app) has no page-to-image API in its free
/// tier. Calls are serialized because native PDF rendering on Android
/// doesn't support opening a second page before the previous one closes.
class PdfRegionRenderer {
  PdfRegionRenderer._(this._document);

  final pdfx.PdfDocument _document;
  Future<void> _queue = Future<void>.value();

  static Future<PdfRegionRenderer> open(String filePath) async {
    final document = await pdfx.PdfDocument.openFile(filePath);
    return PdfRegionRenderer._(document);
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
  Future<Uint8List?> renderRegion({
    required int pageIndex,
    required Rect pdfBounds,
    double scale = 2.0,
  }) {
    final result = _queue.then((_) => _renderNow(pageIndex, pdfBounds, scale));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
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
  }) async {
    if (pdfBounds.width <= 0 || pdfBounds.height <= 0) return null;
    final probeScale = math.min(1.0, probeTargetWidth / pdfBounds.width);
    final probe = await renderRegion(
      pageIndex: pageIndex,
      pdfBounds: pdfBounds,
      scale: probeScale <= 0 ? 1.0 : probeScale,
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
    );
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes: bytes, pdfBounds: trimmed);
  }

  static const double _trimPadding = 3.0;

  /// The page's native size in PDF points, e.g. to compute a render
  /// [scale] for a target pixel width without a separate `syncfusion_flutter_pdf`
  /// document just for sizing.
  Future<Size> pageSize(int pageIndex) {
    final result = _queue.then((_) => _pageSizeNow(pageIndex));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Size> _pageSizeNow(int pageIndex) async {
    final page = await _document.getPage(pageIndex + 1);
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
    final page = await _document.getPage(pageIndex + 1);
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

  Future<void> close() => _queue.then((_) => _document.close());
}
