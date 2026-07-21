import 'dart:typed_data';
import 'dart:ui';

import 'package:pdfx/pdfx.dart' as pdfx;

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

  /// Renders the [pdfBounds] region (PDF points, page-local, top-down) of
  /// page [pageIndex] (0-based) to PNG bytes at [scale]x the PDF's native
  /// resolution.
  Future<Uint8List?> renderRegion({
    required int pageIndex,
    required Rect pdfBounds,
    double scale = 2.0,
  }) {
    final result = _queue.then((_) => _renderNow(pageIndex, pdfBounds, scale));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Uint8List?> _renderNow(int pageIndex, Rect pdfBounds, double scale) async {
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
        format: pdfx.PdfPageImageFormat.png,
        cropRect: Rect.fromLTRB(left, top, right, bottom),
      );
      return image?.bytes;
    } finally {
      await page.close();
    }
  }

  Future<void> close() => _queue.then((_) => _document.close());
}
