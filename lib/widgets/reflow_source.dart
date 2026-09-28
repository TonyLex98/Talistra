import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../utils/markdown_blocks.dart';
import '../utils/reflow_builder.dart';

/// Where the compact view's pages come from.
///
/// Every format reads the same way in compact mode — the same page cards,
/// the same turning, the same footer — because they all go through one view
/// ([PagedReflowView]) and differ only in this: how many pages there are, what
/// blocks each page holds, and how a figure is drawn.
///
/// A page's blocks may change after they were first asked for: a PDF
/// figure is cropped to its ink, a scanned page is read by OCR. The source
/// then calls [onPageChanged] and the view lays that page out again.
abstract class ReflowSource {
  int get pageCount;

  /// The blocks of page [pageIndex] (0-based) as they are known now. Cheap
  /// after the first call for a page; may start work that later calls
  /// [onPageChanged].
  List<ReflowBlock> blocksFor(int pageIndex);

  /// Whether page [pageIndex]'s blocks are still being read — [blocksFor]
  /// then answers with nothing yet and calls [onPageChanged] when it has
  /// something. The view shows a page like that as loading, rather than as a
  /// page with no text on it, and does not settle a place on it until it is
  /// in.
  bool isLoading(int pageIndex) => false;

  /// The view says which page the reader is on, so a source that reads ahead
  /// knows where to read from. Called whenever it changes.
  void focusOn(int pageIndex) {}

  /// Set by the view: told which page's blocks changed.
  void Function(int pageIndex)? onPageChanged;

  /// The typography a block asks for on top of the reader's own; null for
  /// plain body text.
  MarkdownStyle? styleOf(ReflowBlock block) => markdownStyle(block);

  /// The picture of an image block.
  Future<Uint8List?> imageFor(
    int pageIndex,
    int blockIndex,
    ReflowBlock block,
  ) async => block.imageBytes;

  /// The size an image block is shown at in a column of [content] size:
  /// as wide as the column, never taller than most of it.
  Size figureSize(int pageIndex, ReflowBlock block, Size content) {
    final bounds = block.imageBounds!;
    if (bounds.isEmpty) return Size.zero;
    final aspect = bounds.height / bounds.width;
    var width = content.width;
    var height = width * aspect;
    final maxHeight = content.height * 0.9;
    if (height > maxHeight) {
      height = maxHeight;
      width = height / aspect;
    }
    return Size(width, height);
  }

  /// Whether image blocks are photographs of paper (a PDF figure, a scan)
  /// that take the reading theme's page filter, rather than a book's own
  /// illustrations, which are shown as they are.
  bool get figuresArePaper => false;

  /// Where character [offset] of block [blockIndex] sits down its page, 0
  /// at the top to 1 at the bottom, or null when the page has no geometry
  /// to say (a text book's pages are only text).
  double? positionOf(int pageIndex, int blockIndex, int offset) => null;

  /// The block and character that sit [position] (0 to 1) down page
  /// [pageIndex], or null when the page has no geometry to say.
  ({int block, int offset})? offsetAt(int pageIndex, double position) => null;

  /// Stops any work in flight.
  void dispose() {}
}

/// The pages of a book that is text from the start — TXT, FB2, EPUB, DOCX,
/// RTF, Markdown, XML, HTML — already cut into synthetic pages.
class TextBookSource extends ReflowSource {
  TextBookSource(this.pages);

  final List<List<ReflowBlock>> pages;

  @override
  int get pageCount => math.max(1, pages.length);

  @override
  List<ReflowBlock> blocksFor(int pageIndex) =>
      pageIndex >= 0 && pageIndex < pages.length ? pages[pageIndex] : const [];
}
