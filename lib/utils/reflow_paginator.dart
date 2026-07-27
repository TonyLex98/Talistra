import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'reflow_builder.dart';

/// A piece of one [ReflowBlock] placed on a sub-page: either a whole image
/// block, or the character range `[start, end)` of a paragraph's text.
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

    final style = styleFor(block);
    var offset = 0;
    var firstSlice = true;
    while (offset < block.text.length) {
      final spacing = firstSlice && used > 0 ? blockSpacing : 0.0;
      final available = height - used - spacing;
      // Not even one line fits in what's left: start a fresh sub-page.
      // (Unless the sub-page is already empty, in which case the line has
      // to go somewhere and this one is as good as any.)
      final lineHeight = _measureLineHeight(style, width, fontSize, textScaler);
      if (available < lineHeight && used > 0) {
        closePage();
        continue;
      }

      final fits = _charactersThatFit(
        text: block.text,
        start: offset,
        style: style,
        width: width,
        maxHeight: math.max(available, lineHeight),
        textScaler: textScaler,
      );
      final end = math.max(offset + 1, fits.end);
      current.add(
        ReflowSlice(
          blockIndex: blockIndex,
          start: offset,
          end: end,
          isFirstOfBlock: firstSlice,
        ),
      );
      used += spacing + fits.height;
      offset = end;
      firstSlice = false;
      if (offset < block.text.length) closePage();
    }
  }

  closePage();
  return pages;
}

double _measureLineHeight(
  TextStyle style,
  double width,
  double fontSize,
  TextScaler textScaler,
) {
  final painter = TextPainter(
    text: TextSpan(text: 'Ag', style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: width);
  final height = painter.height;
  painter.dispose();
  return height > 0 ? height : fontSize * 1.5;
}

/// How much of `text` starting at [start] fits in [maxHeight], snapped to a
/// line boundary, plus the height that much text actually takes.
({int end, double height}) _charactersThatFit({
  required String text,
  required int start,
  required TextStyle style,
  required double width,
  required double maxHeight,
  required TextScaler textScaler,
}) {
  final remaining = text.substring(start);
  final painter = TextPainter(
    text: TextSpan(text: remaining, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: width);

  try {
    if (painter.height <= maxHeight) {
      return (end: text.length, height: painter.height);
    }
    final metrics = painter.computeLineMetrics();
    var lines = 0;
    var consumed = 0.0;
    for (final line in metrics) {
      if (consumed + line.height > maxHeight) break;
      consumed += line.height;
      lines++;
    }
    if (lines == 0) {
      // Nothing fits by the metrics (a very tall first line): take one
      // line anyway so pagination always makes progress.
      final first = metrics.isEmpty ? null : metrics.first;
      final cutoff = painter
          .getPositionForOffset(Offset(width, (first?.height ?? maxHeight) - 1))
          .offset;
      return (
        end: start + math.max(1, cutoff),
        height: first?.height ?? maxHeight,
      );
    }
    // The character at the start of the first line that did NOT fit is
    // exactly where this sub-page ends.
    final nextLineTop =
        metrics[lines - 1].baseline + metrics[lines - 1].descent + 1;
    final cutoff = painter.getPositionForOffset(Offset(0, nextLineTop)).offset;
    if (cutoff <= 0) return (end: text.length, height: painter.height);
    return (end: start + cutoff, height: consumed);
  } finally {
    painter.dispose();
  }
}
