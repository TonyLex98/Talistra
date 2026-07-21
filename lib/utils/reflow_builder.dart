import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'text_join.dart';

enum ReflowBlockType { paragraph, image }

/// One unit of a reflowed page: either a paragraph of text, or a region
/// that isn't text (almost always an image, chart or table) — carrying
/// its PDF-space bounds so it can be rendered as a real, zoomable image
/// instead of just a placeholder.
class ReflowBlock {
  const ReflowBlock.paragraph(this.text) : imageBounds = null;
  const ReflowBlock.image(Rect bounds) : text = '', imageBounds = bounds;

  final ReflowBlockType type = ReflowBlockType.paragraph;
  final String text;
  final Rect? imageBounds;

  bool get isImage => imageBounds != null;
}

/// Splits a single PDF page's extracted [lines] into reflowed paragraphs
/// sized for phone reading, detecting non-text regions (images, charts,
/// tables) from unusually large vertical gaps — including a gap before
/// the first line or after the last one, since a header/footer figure has
/// no adjacent text on that side at all.
List<ReflowBlock> buildReflowPageBlocks(List<TextLine> lines, Size pageSize) {
  final nonEmpty = lines.where((l) => l.text.trim().isNotEmpty).toList();
  if (nonEmpty.isEmpty) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return const [];
    return [ReflowBlock.image(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height))];
  }

  final heights = nonEmpty.map((l) => l.bounds.height).where((h) => h > 0).toList()..sort();
  final medianHeight = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];

  final blocks = <ReflowBlock>[];
  var paragraph = '';

  void flush() {
    final text = paragraph.trim();
    if (text.isNotEmpty) blocks.add(ReflowBlock.paragraph(text));
    paragraph = '';
  }

  final firstTop = nonEmpty.first.bounds.top;
  if (firstTop > medianHeight * 3) {
    blocks.add(ReflowBlock.image(Rect.fromLTWH(0, 0, pageSize.width, firstTop)));
  }

  double? previousBottom;
  for (final line in nonEmpty) {
    final text = line.text.trim();
    if (previousBottom != null) {
      final gap = line.bounds.top - previousBottom;
      if (gap > medianHeight * 3) {
        flush();
        blocks.add(
          ReflowBlock.image(Rect.fromLTWH(0, previousBottom, pageSize.width, gap)),
        );
        paragraph = text;
        previousBottom = line.bounds.bottom;
        continue;
      } else if (gap > medianHeight * 1.6) {
        flush();
        paragraph = text;
        previousBottom = line.bounds.bottom;
        continue;
      } else {
        paragraph = joinLines(paragraph, text);
        previousBottom = line.bounds.bottom;
        continue;
      }
    }
    paragraph = text;
    previousBottom = line.bounds.bottom;
  }
  flush();

  final lastBottom = nonEmpty.last.bounds.bottom;
  final trailingGap = pageSize.height - lastBottom;
  if (trailingGap > medianHeight * 3) {
    blocks.add(ReflowBlock.image(Rect.fromLTWH(0, lastBottom, pageSize.width, trailingGap)));
  }

  return blocks;
}
