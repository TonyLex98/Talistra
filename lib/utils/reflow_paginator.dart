import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'reflow_builder.dart';

/// A piece of one [ReflowBlock] placed on a sub-page: either a whole image
/// or divider block, or the character range `[start, end)` of a paragraph's
/// text.
///
/// Ranges rather than copies of the text, because everything else —
/// tap-to-translate, the bold/italic runs, the sentence lookup — is
/// expressed in offsets into the block's own full text, and must keep
/// working no matter which sub-page a word ended up on.
class ReflowSlice {
  const ReflowSlice({
    required this.blockIndex,
    required this.start,
    required this.end,
    required this.isFirstOfBlock,
  });

  final int blockIndex;
  final int start;
  final int end;

  /// Whether this slice starts its block — a continuation gets no extra
  /// space above it, so a paragraph broken across two sub-pages reads as
  /// one paragraph rather than two.
  final bool isFirstOfBlock;
}

/// One screenful of reflowed content.
typedef ReflowSubPage = List<ReflowSlice>;

/// How far one block's text sits in from the left and right edges of the
/// reading column — a blockquote's bars, a list's nesting, a code panel's
/// own padding.
typedef ReflowInsets = ({double left, double right});

/// Lays a PDF page's reflowed [blocks] out into screen-sized sub-pages, so
/// the compact view can be turned page by page with a swipe like an e-book
/// instead of scrolled as one long column.
///
/// Paragraphs are split at real line boundaries (measured with the same
/// [TextPainter] Flutter will lay them out with, so the split lands exactly
/// where the visible line breaks are), and a figure is measured from its
/// own aspect ratio, which is known from the PDF long before the image
/// itself has been rasterized.
List<ReflowSubPage> paginateReflowBlocks({
  required List<ReflowBlock> blocks,
  required double width,
  required double height,
  required double fontSize,
  required TextStyle Function(ReflowBlock block) styleFor,
  required double blockSpacing,
  required double imageSpacing,
  required TextScaler textScaler,
  // Extra space every text slice takes up below itself, for callers that
  // render a fixed bottom margin per slice rather than only a gap between
  // blocks (see `blockSpacing`). Defaults to 0 for callers that don't.
  double trailingSpacing = 0.0,
  // Used by callers that remember nothing between layouts. A book's reader
  // passes one (see [ReflowLineCache]) so that a height change re-packs
  // already-measured lines instead of laying the book out again.
  ReflowLineCache? lineCache,
  // Per-block horizontal inset, for content that is drawn inside something
  // (a quote, an indented list item). Measuring a block's lines at any
  // wider than they will be painted is how a page overflows at the bottom.
  ReflowInsets Function(ReflowBlock block)? insetsFor,
  // How a block's text is set once its own emphasis is on it — bold heavier,
  // inline code in monospace. Those runs are wider than the plain text, so a
  // block that has them has to be measured the way it will be painted, or
  // its lines wrap more often on screen than they did here. Blocks without
  // runs, and callers that pass nothing, are measured as plain text.
  InlineSpan Function(ReflowBlock block, TextStyle style)? spanFor,
}) {
  if (blocks.isEmpty || width <= 0 || height <= 0) return const [];

  final pages = <ReflowSubPage>[];
  var current = <ReflowSlice>[];
  var used = 0.0;

  void closePage() {
    if (current.isEmpty) return;
    pages.add(current);
    current = <ReflowSlice>[];
    used = 0.0;
  }

  for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
    final block = blocks[blockIndex];
    final gap = block.gapAbove ?? blockSpacing;

    if (block.isImage) {
      final bounds = block.imageBounds!;
      final aspect = bounds.width > 0 ? bounds.height / bounds.width : 1.0;
      // A figure is displayed with BoxFit.contain inside the column width,
      // and never taller than the screen it has to fit on.
      final imageHeight = math.min(width * aspect, height * 0.9) + imageSpacing;
      if (used > 0 && used + imageHeight > height) closePage();
      current.add(
        ReflowSlice(
          blockIndex: blockIndex,
          start: 0,
          end: 0,
          isFirstOfBlock: true,
        ),
      );
      used += imageHeight;
      if (used >= height) closePage();
      continue;
    }

    if (block.isDivider) {
      const ruleHeight = 1.0;
      final spacing = used > 0 ? gap : 0.0;
      if (used > 0 && used + spacing + ruleHeight + trailingSpacing > height) {
        closePage();
      }
      current.add(
        ReflowSlice(
          blockIndex: blockIndex,
          start: 0,
          end: 0,
          isFirstOfBlock: true,
        ),
      );
      used += spacing + ruleHeight + trailingSpacing;
      continue;
    }

    final style = styleFor(block);
    final insets = insetsFor?.call(block) ?? (left: 0.0, right: 0.0);
    // Whatever is left after the block's own inset is the width its lines
    // are laid out in — and have to be measured in, or the painted lines
    // come out one taller than the page was budgeted for.
    final textWidth = math.max(20.0, width - insets.left - insets.right);
    if (block.text.isEmpty) continue;
    // One layout of the whole block, read back as the lines it breaks into.
    // Measuring every page break by re-laying out the text left over behind
    // it cost a layout pass per break, and a book's worth of breaks made a
    // big document unopenable.
    final span = block.formatRuns.isEmpty || spanFor == null
        ? TextSpan(text: block.text, style: style)
        : spanFor(block, style);
    final lines =
        lineCache?.measure(
          text: block.text,
          runs: block.formatRuns,
          span: span,
          style: style,
          width: textWidth,
          textScaler: textScaler,
          fallbackHeight: fontSize * 1.5,
        ) ??
        _measureLines(
          text: block.text,
          span: span,
          width: textWidth,
          textScaler: textScaler,
          fallbackHeight: fontSize * 1.5,
        );
    var line = 0;
    var firstSlice = true;
    while (line < lines.count) {
      final spacing = firstSlice && used > 0 ? gap : 0.0;
      // Room for this slice's own trailing margin is reserved up front, not
      // just added to the bookkeeping after the fact — otherwise a slice
      // greedily packed right up to the page edge, with its margin tacked on
      // afterwards, runs past `height` by `trailingSpacing`.
      final available = height - used - spacing - trailingSpacing;
      final startLine = line;
      var consumed = 0.0;
      while (line < lines.count &&
          consumed + lines.heights[line] <= available) {
        consumed += lines.heights[line];
        line++;
      }
      if (line == startLine) {
        // Not even one line fits in what's left of this page.
        if (used > 0) {
          closePage();
          continue;
        }
        // On a page of its own the line has to go somewhere.
        consumed = lines.heights[line];
        line++;
      }
      current.add(
        ReflowSlice(
          blockIndex: blockIndex,
          start: lines.starts[startLine],
          end: line < lines.count ? lines.starts[line] : block.text.length,
          isFirstOfBlock: firstSlice,
        ),
      );
      // Some callers (see [trailingSpacing]) render every slice with its own
      // bottom margin, not just a gap before a new block starts — that has
      // to be budgeted here too or the last line on a page runs past `height`.
      used += spacing + consumed + trailingSpacing;
      firstSlice = false;
      if (line < lines.count) closePage();
    }
  }

  closePage();
  return pages;
}

/// The lines one block's text breaks into: the character each line starts at,
/// and how tall it is.
///
/// The starts are the exact boundaries the block is sliced at, so a block's
/// slices tile its text — nothing is lost or doubled where a page ends.
class ReflowLines {
  const ReflowLines(this.starts, this.heights);

  final List<int> starts;
  final List<double> heights;

  int get count => starts.length;
}

/// Remembers the measured [ReflowBlock] line breaks of a book, so that
/// re-paginating it — the keyboard opening, any other height change — re-packs
/// lines that are already known instead of laying the whole book out again.
///
/// A block's breaks depend on its text, its style and the width it is set in,
/// and not at all on how tall a page has to hold them, which is exactly the
/// one thing those re-paginations change.
class ReflowLineCache {
  // [runs] is compared by identity: a block's runs are one list for as long
  // as the block lives, and it is only there to tell two blocks with the same
  // text but different emphasis apart.
  final Map<
    ({
      String text,
      List<FormatRun> runs,
      TextStyle style,
      double width,
      TextScaler textScaler,
    }),
    ReflowLines
  >
  _measured = {};

  // Enough for a book's worth of paragraphs; past it the old entries are
  // text the reader has scrolled away from and won't come back to.
  static const _maxBlocks = 20000;

  ReflowLines measure({
    required String text,
    required List<FormatRun> runs,
    required InlineSpan span,
    required TextStyle style,
    required double width,
    required TextScaler textScaler,
    required double fallbackHeight,
  }) {
    final shape = (
      text: text,
      runs: runs,
      style: style,
      width: width,
      textScaler: textScaler,
    );
    final known = _measured[shape];
    if (known != null) return known;
    final lines = _measureLines(
      text: text,
      span: span,
      width: width,
      textScaler: textScaler,
      fallbackHeight: fallbackHeight,
    );
    if (_measured.length >= _maxBlocks) _measured.clear();
    return _measured[shape] = lines;
  }
}

/// Lays [text] (set as [span]) out once at [width] and reads its line breaks
/// and the height of each line off the result.
ReflowLines _measureLines({
  required String text,
  required InlineSpan span,
  required double width,
  required TextScaler textScaler,
  required double fallbackHeight,
}) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: width);
  try {
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) return ReflowLines([0], [fallbackHeight]);
    final starts = List<int>.filled(metrics.length, 0);
    final heights = List<double>.filled(metrics.length, fallbackHeight);
    // A line's top is a y coordinate inside it, so `top + 1` still lands on
    // that line however the metrics rounded — and the starts have to keep
    // walking forward for the slices built out of them to tile the text.
    //
    // A line's height is read as the distance from its top to the next one's
    // (and the last one's to the bottom of the paragraph), not off
    // [LineMetrics.height]: that one is rounded, and a page of lines each a
    // fraction of a pixel taller than it was counted as adds up to a last
    // line that no longer fits.
    var upTo = 0;
    var top = 0.0;
    for (var i = 0; i < metrics.length; i++) {
      final line = metrics[i];
      final bottom = i + 1 < metrics.length
          ? metrics[i + 1].baseline - metrics[i + 1].ascent
          : painter.height;
      final measured = bottom - top;
      heights[i] = measured > 0 ? measured : fallbackHeight;
      top = bottom;
      if (i == 0) {
        starts[i] = 0;
        continue;
      }
      final offset = painter
          .getPositionForOffset(Offset(0, line.baseline - line.ascent + 1))
          .offset;
      starts[i] = upTo = math.max(upTo, math.min(offset, text.length));
    }
    return ReflowLines(starts, heights);
  } finally {
    painter.dispose();
  }
}
