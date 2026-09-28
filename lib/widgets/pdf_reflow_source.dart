import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../utils/markdown_blocks.dart';
import '../utils/page_rotation.dart';
import '../utils/pdf_region_renderer.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import 'page_ocr.dart';
import 'reflow_source.dart';

/// A PDF's pages for the compact view: each page's text reflowed into
/// paragraphs, and the figures between them cropped from the page itself.
///
/// A figure is found as a gap between runs of text — a guess, full-width,
/// often mostly paper — so each is cropped to what is actually drawn in it
/// as soon as its page is read, and the page is then laid out again with the
/// figure's real size. The crop is kept for painting it.
class PdfReflowSource extends ReflowSource {
  PdfReflowSource({
    required this.document,
    required this.renderer,
    required this.linesCache,
    this.ocr,
  });

  /// How pages without usable text are read, when they can be: a scanned
  /// PDF, or a page whose fonts garbled its text (see `text_repair.dart`).
  final PageOcr? ocr;

  final PdfDocument document;
  final PdfRegionRenderer renderer;

  /// Shared with the reader, which needs the same lines for search and for
  /// the sentence behind a tapped word.
  final Map<int, List<TextLine>> linesCache;

  final Map<int, List<ReflowBlock>> _blocks = {};
  final Map<int, double> _textColumnWidths = {};
  final Map<String, Future<Uint8List?>> _figureImages = {};
  bool _disposed = false;

  @override
  int get pageCount => math.max(1, document.pages.count);

  @override
  bool get figuresArePaper => true;

  @override
  List<ReflowBlock> blocksFor(int pageIndex) {
    return _blocks.putIfAbsent(pageIndex, () {
      try {
        final lines = linesCache.putIfAbsent(
          pageIndex,
          () => extractPageLines(document, pageIndex),
        );
        final pageSize = displayPageSize(document.pages[pageIndex]);
        _textColumnWidths[pageIndex] = _textColumnWidth(lines, pageSize);
        final blocks = [...buildReflowPageBlocks(lines, pageSize)];
        if (lines.isEmpty && ocr != null) {
          // The page itself stands in (a single full-page figure) until its
          // text has been read off it.
          _readPage(pageIndex, pageSize);
        }
        _measureFigures(pageIndex, blocks);
        return blocks;
      } catch (_) {
        return const [];
      }
    });
  }

  /// A PDF heading is one undifferentiated style, a size up and bold — not
  /// the level-1 title a Markdown `#` is.
  @override
  MarkdownStyle? styleOf(ReflowBlock block) =>
      block.isHeading ? const MarkdownStyle(1.16, 0.84, bold: true) : null;

  /// Reads the text off page [pageIndex]'s picture and puts it in place of
  /// the picture — or leaves the picture, when nothing readable is on it.
  void _readPage(int pageIndex, Size pageSize) {
    final ocr = this.ocr!;
    ocr.read(
      page: pageIndex,
      pageHeight: pageSize.height,
      render: () async {
        // Wide enough for small print to be read, not so wide the
        // recognizer spends seconds on it.
        final scale = math.min(3.0, 2000 / math.max(1.0, pageSize.width));
        final bytes = await renderer.renderRegion(
          pageIndex: pageIndex,
          pdfBounds: Offset.zero & pageSize,
          scale: scale,
        );
        return bytes == null
            ? null
            : (bytes: bytes, height: pageSize.height * scale);
      },
      done: (blocks) {
        if (_disposed || blocks.isEmpty) return;
        _blocks[pageIndex] = blocks;
        onPageChanged?.call(pageIndex);
      },
    );
  }

  /// How wide the page's text runs, in PDF points: the yardstick a figure's
  /// width is measured against, so a figure half as wide as the text on its
  /// page is half as wide as the reflowed text.
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

  /// Crops every figure of [pageIndex] to its ink. A gap that turns out
  /// blank stays in the list as an empty figure — search hits point at
  /// blocks by index — and takes no room.
  void _measureFigures(int pageIndex, List<ReflowBlock> blocks) {
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (!block.isImage) continue;
      final region = renderer.renderTrimmedRegion(
        pageIndex: pageIndex,
        pdfBounds: block.imageBounds!,
      );
      final measured = region.then((r) {
        if (_disposed) return null;
        final trimmed = r?.pdfBounds ?? Rect.zero;
        final bytes = r?.bytes;
        final cached = _blocks[pageIndex];
        if (cached != null &&
            i < cached.length &&
            trimmed != cached[i].imageBounds) {
          cached[i] = ReflowBlock.image(trimmed);
          _figureImages['$pageIndex-$i-$trimmed'] = Future.value(bytes);
          onPageChanged?.call(pageIndex);
        }
        return bytes;
      });
      _figureImages['$pageIndex-$i-${block.imageBounds}'] = measured;
    }
  }

  @override
  Future<Uint8List?> imageFor(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
  ) {
    final key = '$pageIndex-$blockIndex-${block.imageBounds}';
    return _figureImages.putIfAbsent(key, () async {
      final region = await renderer.renderTrimmedRegion(
        pageIndex: pageIndex,
        pdfBounds: block.imageBounds!,
      );
      return region?.bytes;
    });
  }

  /// A figure keeps the width it has relative to its page's text, as in the
  /// PDF, capped at the column and at most of the page's height.
  @override
  Size figureSize(int pageIndex, ReflowBlock block, Size content) {
    final bounds = block.imageBounds!;
    if (bounds.isEmpty) return Size.zero;
    final reference =
        _textColumnWidths[pageIndex] ??
        displayPageSize(document.pages[pageIndex]).width;
    final aspect = bounds.height / bounds.width;
    var width = math.min(
      content.width,
      bounds.width * content.width / reference,
    );
    var height = width * aspect;
    final maxHeight = content.height * 0.9;
    if (height > maxHeight) {
      height = maxHeight;
      width = height / aspect;
    }
    return Size(width, height);
  }

  /// A paragraph's characters are taken to run evenly down the lines it was
  /// built from — the reflowed text has no line of the page to point at, but
  /// a place half-way through a paragraph is half-way down it.
  @override
  double? positionOf(int pageIndex, int blockIndex, int offset) {
    final blocks = blocksFor(pageIndex);
    if (blockIndex < 0 || blockIndex >= blocks.length) return null;
    final block = blocks[blockIndex];
    final top = block.sourceTop;
    final bottom = block.sourceBottom;
    final height = displayPageSize(document.pages[pageIndex]).height;
    if (top == null || bottom == null || height <= 0) return null;
    final along = block.text.isEmpty
        ? 0.0
        : (offset / block.text.length).clamp(0.0, 1.0);
    return ((top + (bottom - top) * along) / height).clamp(0.0, 1.0);
  }

  @override
  ({int block, int offset})? offsetAt(int pageIndex, double position) {
    final blocks = blocksFor(pageIndex);
    final height = displayPageSize(document.pages[pageIndex]).height;
    if (blocks.isEmpty || height <= 0) return null;
    final y = position.clamp(0.0, 1.0) * height;
    // The first block that reaches below the top of the screen: the one
    // the reader was starting to read.
    for (var i = 0; i < blocks.length; i++) {
      final top = blocks[i].sourceTop;
      final bottom = blocks[i].sourceBottom;
      if (top == null || bottom == null || bottom <= y) continue;
      if (blocks[i].isImage || y <= top || bottom <= top) {
        return (block: i, offset: 0);
      }
      final along = (y - top) / (bottom - top);
      return (block: i, offset: (blocks[i].text.length * along).floor());
    }
    return (block: blocks.length - 1, offset: blocks.last.text.length);
  }

  @override
  void dispose() {
    _disposed = true;
    onPageChanged = null;
    ocr?.cancel();
  }
}
