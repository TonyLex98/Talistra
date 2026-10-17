import 'reflow_builder.dart';
import 'reflow_table.dart';
import 'text_join.dart';

/// How many characters roughly make up one synthetic "page" of a plain
/// text file — just enough for progress tracking, the page counter, and
/// reading statistics to behave the same way they do for PDF/reflow, even
/// though a .txt file has no real page boundaries. Not meant to match an
/// actual on-screen page exactly.
const _targetPageChars = 2400;

/// Splits raw plain-text content into paragraphs, then groups those into
/// synthetic pages of roughly [_targetPageChars] each, so a .txt document gets
/// the same page-based reading experience — progress bar, "page X of Y",
/// per-book statistics — as PDF/reflow.
///
/// A blank line always ends a paragraph. A single line break is the hard part,
/// because a text file uses it for two opposite things: a book saved with
/// every line cut at 70 columns wants its lines joined back into prose, while
/// a poem, a list, a log or a file with one paragraph per line wants each
/// break kept. Joining everything — as this once did — poured a whole such
/// file into one block. See [splitPlainTextParagraphs] for how the two are told apart.
List<List<ReflowBlock>> buildTxtPages(String rawText) {
  return buildTxtPagesFromParagraphs(splitPlainTextParagraphs(rawText));
}

/// The paragraphs of a plain-text file's [rawText], with its line breaks dealt
/// with as [buildTxtPages] describes.
///
/// The width the file was wrapped at is read off the file itself — the 90th
/// percentile of its line lengths, which ignores the short last line of each
/// paragraph. A run of lines is hard-wrapped prose when nearly all of them
/// reach close to that width: then the breaks are joined away. Otherwise they
/// were put there on purpose: long lines (prose written one paragraph per
/// line) become paragraphs of their own, short ones (verse, lists) stay one
/// block with their breaks kept.
List<String> splitPlainTextParagraphs(String rawText) {
  final text = rawText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lengths = <int>[
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim().length,
  ]..sort();
  final wrapWidth = lengths.isEmpty
      ? 0
      : lengths[(lengths.length * 0.9).floor().clamp(0, lengths.length - 1)];

  final paragraphs = <String>[];
  for (final chunk in text.split(RegExp(r'\n\s*\n+'))) {
    final lines = [
      for (final line in chunk.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) continue;
    if (lines.length == 1) {
      paragraphs.add(lines.single);
    } else if (_isHardWrapped(lines, wrapWidth)) {
      paragraphs.add(lines.reduce(joinLines));
    } else if (lines.fold<int>(0, (sum, line) => sum + line.length) >=
        _proseLineChars * lines.length) {
      paragraphs.addAll(lines);
    } else {
      paragraphs.add(lines.join('\n'));
    }
  }
  return paragraphs;
}

/// Lines this long on average are prose, not verse or list entries.
const _proseLineChars = 80;

/// Whether [lines] (two or more) are one paragraph that was cut at about
/// [wrapWidth] columns: every line but the last runs nearly to that width.
bool _isHardWrapped(List<String> lines, int wrapWidth) {
  if (wrapWidth < 40) return false;
  final full = lines.length - 1;
  var reaching = 0;
  for (var i = 0; i < full; i++) {
    if (lines[i].length >= wrapWidth * 0.75) reaching++;
  }
  return reaching >= full * 0.8;
}

/// Same grouping, for the formats that already hand their text over as
/// paragraphs (EPUB, FB2, RTF, DOCX — see `extractEbookParagraphs`).
List<List<ReflowBlock>> buildTxtPagesFromParagraphs(List<String> paragraphs) {
  return buildTxtPagesFromBlocks([
    for (final text in paragraphs) ReflowBlock.paragraph(text),
  ]);
}

/// Groups blocks that already carry their own structure (a Markdown file's
/// headings, lists and code panels — see `parseMarkdownBlocks`) into
/// synthetic pages, weighting each by the text it actually holds so a page
/// of bulleted items doesn't count as longer than a paragraph of prose.
///
/// Every block is first cut down to page size (see [_splitOversized]),
/// because a block bigger than a page would otherwise *be* a page — one
/// 2 MB Markdown file's opening paragraph turned its first page into four
/// hundred screens, which the reader's page counter, saved progress and
/// "go to page" jump all read as a book stuck on page 1.
List<List<ReflowBlock>> buildTxtPagesFromBlocks(List<ReflowBlock> blocks) {
  if (blocks.isEmpty) return const [];

  final pages = <List<ReflowBlock>>[];
  var current = <ReflowBlock>[];
  var currentChars = 0;
  for (final block in _splitOversized(blocks)) {
    current.add(block);
    currentChars += block.text.length;
    if (currentChars >= _targetPageChars) {
      pages.add(current);
      current = [];
      currentChars = 0;
    }
  }
  if (current.isNotEmpty) pages.add(current);
  return pages;
}

/// Breaks every block longer than a synthetic page into page-sized pieces.
List<ReflowBlock> _splitOversized(List<ReflowBlock> blocks) {
  final split = <ReflowBlock>[];
  for (final block in blocks) {
    if (block.isTable) {
      split.addAll(splitReflowTable(block, _targetPageChars));
      continue;
    }
    if (block.isImage ||
        block.isDivider ||
        block.text.length <= _targetPageChars) {
      split.add(block);
      continue;
    }
    var start = 0;
    while (start < block.text.length) {
      final limit = start + _targetPageChars;
      final end = limit < block.text.length
          ? _breakAt(block.text, start, limit)
          : block.text.length;
      split.add(_pieceOf(block, start, end, first: start == 0));
      start = end;
    }
  }
  return split;
}

/// Where to cut a block that runs past the page limit: the end of the last
/// word (or, in preformatted text, the last line) that still fits in the
/// back half of the page, so a cut never lands mid-word and never leaves a
/// page half empty because one long word crossed the line.
int _breakAt(String text, int start, int limit) {
  final floor = start + _targetPageChars ~/ 2;
  // Preformatted text keeps its own line breaks, so a cut there lands at the
  // start of a line rather than mid-word.
  for (var i = limit; i > floor; i--) {
    if (text.codeUnitAt(i - 1) == 0x0a) return i;
  }
  for (var i = limit; i > floor; i--) {
    if (_isSpace(text.codeUnitAt(i - 1)) && !_isSpace(text.codeUnitAt(i))) {
      return i;
    }
  }
  return limit;
}

bool _isSpace(int byte) => byte == 0x20 || byte == 0x09 || byte == 0x0a;

/// [block]'s text between [start] and [end], with its structure kept and its
/// format runs shifted onto the new offsets.
ReflowBlock _pieceOf(
  ReflowBlock block,
  int start,
  int end, {
  required bool first,
}) {
  return ReflowBlock.paragraph(
    block.text.substring(start, end),
    formatRuns: [
      for (final run in block.formatRuns)
        if (run.end > start && run.start < end)
          FormatRun(
            start: (run.start < start ? start : run.start) - start,
            end: (run.end > end ? end : run.end) - start,
            bold: run.bold,
            italic: run.italic,
            code: run.code,
            strike: run.strike,
            link: run.link,
          ),
    ],
    headingLevel: block.headingLevel,
    quoteDepth: block.quoteDepth,
    indent: block.indent,
    isCode: block.isCode,
    // A continuation is the same paragraph on the next page, not a new one,
    // so it asks for no space above itself.
    gapAbove: first ? block.gapAbove : 0,
  );
}
