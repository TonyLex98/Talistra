import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../services/pdf_page_worker.dart';
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
    this.worker,
  });

  /// Reads pages off the UI isolate, when there is one (see
  /// [PdfPageWorker]). Without it — a file too big to open twice, or the
  /// moments before the worker has the document open — pages are read here,
  /// one at a time, as they are asked for.
  PdfPageWorker? worker;

  /// Hands the source a worker that has finished opening the document. From
  /// then on pages are read there, and the ones around the reader ahead of
  /// time.
  void attachWorker(PdfPageWorker started) {
    if (_disposed) {
      started.close();
      return;
    }
    worker = started;
    _dispatch();
  }

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

  /// Pages read ahead of the one on screen, and behind it: turning a page
  /// then finds the next already read. Forward reaches further than back —
  /// people read on.
  static const int _ahead = 4;
  static const int _behind = 2;

  /// The page the reader last asked for: what is read first, and the middle
  /// of what is read around it.
  int _focus = 0;
  final Set<int> _asked = {};
  final Set<int> _inFlight = {};
  bool _dispatching = false;

  @override
  bool isLoading(int pageIndex) =>
      !_blocks.containsKey(pageIndex) && _usesWorker;

  bool get _usesWorker => worker != null && !worker!.isClosed && !_disposed;

  @override
  List<ReflowBlock> blocksFor(int pageIndex) {
    final known = _blocks[pageIndex];
    if (known != null) return known;
    if (_usesWorker) {
      // Asked for, so read — and the view told when it is: it is waiting.
      _asked.add(pageIndex);
      _dispatch();
      return const [];
    }
    return _blocks.putIfAbsent(pageIndex, () {
      try {
        return _adopt(pageIndex, _readHere(pageIndex));
      } catch (_) {
        return const [];
      }
    });
  }

  PdfPageData _readHere(int pageIndex) {
    final lines = linesCache.putIfAbsent(
      pageIndex,
      () => extractPageLines(document, pageIndex),
    );
    final pageSize = displayPageSize(document.pages[pageIndex]);
    return PdfPageData(
      blocks: buildReflowPageBlocks(lines, pageSize),
      columnWidth: pdfTextColumnWidth(lines, pageSize),
      hasText: lines.isNotEmpty,
    );
  }

  /// Takes in a page just read: keeps it, starts the reading of its picture
  /// if it turned out to have no text, and measures its figures.
  List<ReflowBlock> _adopt(int pageIndex, PdfPageData data) {
    _textColumnWidths[pageIndex] = data.columnWidth;
    final blocks = [...data.blocks];
    if (!data.hasText && ocr != null) {
      // The page itself stands in (a single full-page figure) until its
      // text has been read off it.
      _readPage(pageIndex, displayPageSize(document.pages[pageIndex]));
    }
    // Stored before the figures are measured: a measured figure replaces its
    // block in this very list.
    _blocks[pageIndex] = blocks;
    _measureFigures(pageIndex, blocks);
    return blocks;
  }

  /// How soon a render for [pageIndex] is worth having: the page being read
  /// ahead of its neighbours, and all of them ahead of the rest.
  int _priorityOf(int pageIndex) =>
      PdfRegionRenderer.priorityVisible + 2 * (pageIndex - _focus).abs();

  @override
  void focusOn(int pageIndex) {
    if (pageIndex == _focus && _dispatching) return;
    _focus = pageIndex;
    // Pages the view asked for while the reader was passing them are not
    // worth reading now that they are far behind: if it wants one again, it
    // asks again.
    _asked.removeWhere((page) => (page - pageIndex).abs() > 6);
    if (_usesWorker) _dispatch();
  }

  /// Which pages the worker should read, in the order it should: the one on
  /// screen, then ahead and behind it, nearest first.
  List<int> _wanted() {
    final pages = <int>[
      _focus,
      for (var d = 1; d <= math.max(_ahead, _behind); d++) ...[
        if (d <= _ahead) _focus + d,
        if (d <= _behind) _focus - d,
      ],
      // A page the view asked for, however far away it has been left since
      // (a jump, a search hit): it is waiting for it.
      ..._asked,
    ];
    return [
      for (final page in pages)
        if (page >= 0 &&
            page < pageCount &&
            !_blocks.containsKey(page) &&
            !_inFlight.contains(page))
          page,
    ];
  }

  /// Sends the worker the next page to read, one at a time: the worker takes
  /// requests in order, so what is sent is chosen when it is idle — by where
  /// the reader is then, not where they were when it was asked.
  void _dispatch() {
    if (_dispatching || !_usesWorker) return;
    final wanted = _wanted();
    if (wanted.isEmpty) return;
    final page = wanted.first;
    _dispatching = true;
    _inFlight.add(page);
    worker!.read(page).then((data) {
      _inFlight.remove(page);
      _dispatching = false;
      if (_disposed) return;
      if (data == null) {
        // The worker couldn't read it (or is gone): here, as before.
        try {
          _adopt(page, _readHere(page));
        } catch (_) {
          _blocks[page] = const [];
        }
      } else {
        _adopt(page, data);
      }
      // Only a page the view is waiting for is worth a re-layout; the
      // others are simply there when it gets to them.
      if (_asked.remove(page)) onPageChanged?.call(page);
      _dispatch();
    }).ignore();
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
          livePriority: () => _priorityOf(pageIndex),
          isStale: () => _disposed,
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
        livePriority: () => _priorityOf(pageIndex),
        isStale: () => _disposed,
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
        livePriority: () => _priorityOf(pageIndex),
        isStale: () => _disposed,
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
    worker?.close();
  }
}
