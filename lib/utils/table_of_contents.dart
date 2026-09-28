import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'reflow_builder.dart';

/// One line of a book's table of contents: what the chapter is called, how
/// deep it sits, and the (1-based) page it starts on.
class TocEntry {
  const TocEntry({
    required this.title,
    required this.level,
    required this.page,
  });

  final String title;

  /// 1 for a top-level chapter, deeper for its sections.
  final int level;

  /// 1-based, in the reader's own page numbers.
  final int page;
}

/// How deep a heading can be and still be worth a line in the contents: past
/// this a book's sub-sub-sections crowd out the chapters a reader is looking
/// for.
const int _deepestLevel = 3;

/// The contents of a text book, read off the headings in its pages — the
/// chapter titles of an FB2 or EPUB, a Markdown file's `#` lines.
///
/// A book that only uses deeper headings (a Markdown file whose sections are
/// all `###`) still gets them: the depths are counted from the shallowest one
/// the book has.
List<TocEntry> tocFromPages(List<List<ReflowBlock>> pages) {
  var shallowest = 7;
  for (final page in pages) {
    for (final block in page) {
      if (block.headingLevel > 0 && block.headingLevel < shallowest) {
        shallowest = block.headingLevel;
      }
    }
  }
  if (shallowest == 7) return const [];
  final entries = <TocEntry>[];
  for (var i = 0; i < pages.length; i++) {
    for (final block in pages[i]) {
      if (block.headingLevel == 0) continue;
      final level = block.headingLevel - shallowest + 1;
      if (level > _deepestLevel) continue;
      final title = _oneLine(block.text);
      if (title.isEmpty) continue;
      entries.add(TocEntry(title: title, level: level, page: i + 1));
    }
  }
  return entries;
}

/// The outline a PDF carries for itself, if it has one.
List<TocEntry> pdfOutline(PdfDocument document) {
  final entries = <TocEntry>[];
  void walk(PdfBookmarkBase bookmarks, int level) {
    for (var i = 0; i < bookmarks.count; i++) {
      final bookmark = bookmarks[i];
      final page = _pageOf(document, bookmark);
      final title = _oneLine(bookmark.title);
      if (page != null && title.isNotEmpty) {
        entries.add(TocEntry(title: title, level: level, page: page + 1));
      }
      if (level < _deepestLevel + 1) walk(bookmark, level + 1);
    }
  }

  try {
    walk(document.bookmarks, 1);
  } catch (_) {
    // A broken outline is a PDF without one, not a PDF that won't open.
  }
  return entries;
}

int? _pageOf(PdfDocument document, PdfBookmark bookmark) {
  try {
    final page =
        bookmark.destination?.page ??
        bookmark.namedDestination?.destination?.page;
    if (page == null) return null;
    final index = document.pages.indexOf(page);
    return index < 0 ? null : index;
  } catch (_) {
    return null;
  }
}

String _oneLine(String text) {
  final line = text.replaceAll(RegExp(r'\s*\n\s*'), '. ').trim();
  return line.length > 120 ? '${line.substring(0, 117)}…' : line;
}

/// The entry the reader is in now: the last one that starts on or before
/// [page], or null before the first.
int? currentTocIndex(List<TocEntry> entries, int page) {
  int? current;
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].page <= page) current = i;
  }
  return current;
}
