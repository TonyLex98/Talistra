import 'reflow_builder.dart';

/// How many characters roughly make up one synthetic "page" of a plain
/// text file — just enough for progress tracking, the page counter, and
/// reading statistics to behave the same way they do for PDF/reflow, even
/// though a .txt file has no real page boundaries. Not meant to match an
/// actual on-screen page exactly.
const _targetPageChars = 2400;

/// Splits raw plain-text content into paragraphs (blank-line separated),
/// then groups those into synthetic pages of roughly [_targetPageChars]
/// each, so a .txt document gets the same page-based reading experience —
/// progress bar, "page X of Y", per-book statistics — as PDF/reflow.
List<List<ReflowBlock>> buildTxtPages(String rawText) {
  final normalized = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return buildTxtPagesFromParagraphs(
    normalized
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.replaceAll('\n', ' ').trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(),
  );
}

/// Same grouping, for the formats that already hand their text over as
/// paragraphs (EPUB, FB2, RTF, DOCX — see `extractEbookParagraphs`).
List<List<ReflowBlock>> buildTxtPagesFromParagraphs(List<String> paragraphs) {
  if (paragraphs.isEmpty) return const [];

  final pages = <List<ReflowBlock>>[];
  var current = <ReflowBlock>[];
  var currentChars = 0;
  for (final text in paragraphs) {
    current.add(ReflowBlock.paragraph(text));
    currentChars += text.length;
    if (currentChars >= _targetPageChars) {
      pages.add(current);
      current = [];
      currentChars = 0;
    }
  }
  if (current.isNotEmpty) pages.add(current);
  return pages;
}
