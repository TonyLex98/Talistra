import 'package:syncfusion_flutter_pdf/pdf.dart';

enum ReflowBlockType { paragraph, imageGap }

/// One unit of reflowed content: either a paragraph of text, or a marker
/// where the original page had a large visual gap (almost always an image,
/// chart or table) that this text-only reflow can't reproduce — the
/// reader can switch back to the original PDF to see it.
class ReflowBlock {
  const ReflowBlock.paragraph(this.text) : type = ReflowBlockType.paragraph;
  const ReflowBlock.imageGap() : text = '', type = ReflowBlockType.imageGap;

  final ReflowBlockType type;
  final String text;
}

/// Rebuilds a whole document's extracted text as a flowing list of
/// paragraphs sized for phone reading, instead of the PDF's fixed page
/// layout. Paragraphs are detected from vertical spacing between lines:
/// a normal line-to-line gap continues the paragraph, a bigger gap starts
/// a new one, and an unusually large gap is treated as a skipped image.
List<ReflowBlock> buildReflowBlocks(PdfDocument document) {
  final allLines = PdfTextExtractor(document).extractTextLines();
  if (allLines.isEmpty) return const [];

  final heightsByPage = <int, List<double>>{};
  for (final line in allLines) {
    if (line.bounds.height > 0) {
      heightsByPage.putIfAbsent(line.pageIndex, () => []).add(line.bounds.height);
    }
  }
  final medianHeightByPage = <int, double>{
    for (final entry in heightsByPage.entries)
      entry.key: (entry.value..sort())[entry.value.length ~/ 2],
  };

  final blocks = <ReflowBlock>[];
  final buffer = StringBuffer();
  double? previousBottom;
  int? previousPageIndex;

  void flushParagraph() {
    final text = buffer.toString().trim();
    if (text.isNotEmpty) blocks.add(ReflowBlock.paragraph(text));
    buffer.clear();
  }

  for (final line in allLines) {
    final text = line.text.trim();
    if (text.isEmpty) continue;

    final pageChanged = previousPageIndex != null && previousPageIndex != line.pageIndex;
    if (pageChanged) {
      flushParagraph();
    } else if (previousBottom != null) {
      final medianHeight = medianHeightByPage[line.pageIndex] ?? 12.0;
      final gap = line.bounds.top - previousBottom;
      if (gap > medianHeight * 3) {
        flushParagraph();
        blocks.add(const ReflowBlock.imageGap());
      } else if (gap > medianHeight * 1.6) {
        flushParagraph();
      } else {
        buffer.write(' ');
      }
    }

    buffer.write(text);
    previousBottom = line.bounds.bottom;
    previousPageIndex = line.pageIndex;
  }
  flushParagraph();
  return blocks;
}
