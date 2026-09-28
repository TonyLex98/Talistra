import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../services/djvu_service.dart';
import '../utils/reflow_builder.dart';
import 'page_ocr.dart';
import 'reflow_source.dart';

/// A DjVu book's pages for the compact view: the text layer the file carries,
/// where it carries one; for a page without one, the text read off the scan
/// by OCR — and, while that is being read (or where nothing can be), the
/// scan itself.
///
/// Most DjVu books are scans with no text layer at all, which used to mean
/// no compact view either.
class DjvuReflowSource extends ReflowSource {
  DjvuReflowSource({
    required this.document,
    required List<List<ReflowBlock>> textLayer,
    this.ocr,
  }) : pages = [...textLayer];

  final DjvuDocument document;
  final PageOcr? ocr;

  /// Each page's text as it is known now: the text layer's, then OCR's as
  /// pages are read. The reader's search and copying read this too.
  final List<List<ReflowBlock>> pages;

  final Map<int, DjvuPageInfo> _info = {};
  final Set<int> _started = {};
  bool _disposed = false;

  @override
  int get pageCount => math.max(1, document.pageCount);

  @override
  bool get figuresArePaper => true;

  /// Whether the book reads in the compact view at all: it has a text layer
  /// somewhere, or its pages can be read.
  bool get readable =>
      pages.any((page) => page.isNotEmpty) || (ocr?.available ?? false);

  @override
  List<ReflowBlock> blocksFor(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pages.length) return const [];
    final page = pages[pageIndex];
    if (page.isNotEmpty) return page;
    if (_started.add(pageIndex)) _start(pageIndex);
    final info = _info[pageIndex];
    // The scan, until its text has been read (or for good, where it can't
    // be); nothing at all for the moment before its size is known.
    return info == null
        ? const []
        : [
            ReflowBlock.image(
              Rect.fromLTWH(
                0,
                0,
                info.width.toDouble(),
                info.height.toDouble(),
              ),
            ),
          ];
  }

  Future<void> _start(int pageIndex) async {
    final DjvuPageInfo info;
    try {
      info = await document.pageInfo(pageIndex);
    } catch (_) {
      return;
    }
    if (_disposed) return;
    _info[pageIndex] = info;
    onPageChanged?.call(pageIndex);
    ocr?.read(
      page: pageIndex,
      pageHeight: info.height.toDouble(),
      render: () async {
        final size = _ocrSize(info);
        final bytes = await document.renderPage(
          pageIndex,
          width: size.width.round(),
          height: size.height.round(),
        );
        return (bytes: bytes, height: size.height);
      },
      done: (blocks) {
        if (_disposed || blocks.isEmpty) return;
        pages[pageIndex] = blocks;
        onPageChanged?.call(pageIndex);
      },
    );
  }

  /// A scan is read at its own resolution, up to what the recognizer needs
  /// for small print.
  static Size _ocrSize(DjvuPageInfo info) {
    final scale = math.min(1.0, 2200 / math.max(1, info.width));
    return Size(info.width * scale, info.height * scale);
  }

  @override
  Future<Uint8List?> imageFor(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
  ) async {
    final info = _info[pageIndex];
    if (info == null) return null;
    final scale = math.min(1.0, 1600 / math.max(1, info.width));
    try {
      return await document.renderPage(
        pageIndex,
        width: (info.width * scale).round(),
        height: (info.height * scale).round(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  double? positionOf(int pageIndex, int blockIndex, int offset) {
    final info = _info[pageIndex];
    if (info == null || info.height <= 0) return null;
    final blocks = blocksFor(pageIndex);
    if (blockIndex < 0 || blockIndex >= blocks.length) return null;
    final block = blocks[blockIndex];
    final top = block.sourceTop;
    final bottom = block.sourceBottom;
    if (top == null || bottom == null) return null;
    final along = block.text.isEmpty
        ? 0.0
        : (offset / block.text.length).clamp(0.0, 1.0);
    return ((top + (bottom - top) * along) / info.height).clamp(0.0, 1.0);
  }

  @override
  ({int block, int offset})? offsetAt(int pageIndex, double position) {
    final info = _info[pageIndex];
    final blocks = blocksFor(pageIndex);
    if (info == null || blocks.isEmpty) return null;
    final y = position.clamp(0.0, 1.0) * info.height;
    for (var i = 0; i < blocks.length; i++) {
      final top = blocks[i].sourceTop;
      final bottom = blocks[i].sourceBottom;
      if (top == null || bottom == null) return null;
      if (bottom <= y) continue;
      if (y <= top || bottom <= top) return (block: i, offset: 0);
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
