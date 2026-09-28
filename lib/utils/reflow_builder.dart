import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'page_lines.dart';
import 'text_join.dart';

/// One visual row of the page: its bounds, its rebuilt text, the
/// bold/italic runs inside that text, and whether the whole row is bold (a
/// heading tell).
/// [height] is deliberately *not* `bounds.height`: after merging a
/// subscript or superscript into its row, the row's bounding box is taller
/// than the type actually is, and comparing that against neighbouring rows
/// made every line of a formula-heavy paragraph look like a heading. This
/// keeps the height of the row's dominant fragment — its body text.
typedef _LineEntry = ({
  Rect bounds,
  double height,
  String text,
  List<FormatRun> runs,
  bool allBold,
});

/// Merges extracted lines that are really one visual row.
///
/// Subscripts and superscripts come back from the extractor as lines of
/// their own, sitting at their own baseline and their own (small) size —
/// so a formula-heavy page arrives as a stream of fragments ("убедиться,
/// что d", "v", "(z) = 5, d", "x", ...). Left as separate lines they break
/// the paragraph into slivers and, being surrounded by much smaller
/// neighbours, every full-size fragment looks like a heading. Rows that
/// overlap vertically belong together, and joining them first makes
/// everything downstream — paragraphs, headings, sentence lookup — see the
/// line a reader actually sees.
List<_LineEntry> _mergeVisualRows(List<_LineEntry> entries) {
  final merged = <_LineEntry>[];
  for (final entry in entries) {
    if (merged.isEmpty) {
      merged.add(entry);
      continue;
    }
    final last = merged.last;
    final overlap =
        math.min(last.bounds.bottom, entry.bounds.bottom) -
        math.max(last.bounds.top, entry.bounds.top);
    final minHeight = math.min(last.bounds.height, entry.bounds.height);
    final sameRow =
        minHeight > 0 &&
        overlap > minHeight * 0.5 &&
        entry.bounds.left >= last.bounds.left - 1;
    if (!sameRow) {
      merged.add(entry);
      continue;
    }
    // Same space rule as within a line: a real horizontal gap is a space,
    // a flush fragment is part of the same token ("d" + subscript "v").
    final gap = entry.bounds.left - last.bounds.right;
    final separator = gap >= math.max(1.0, minHeight * 0.15) ? ' ' : '';
    final shift = last.text.length + separator.length;
    merged[merged.length - 1] = (
      bounds: last.bounds.expandToInclude(entry.bounds),
      // Whichever fragment carries more text is the row's body type.
      height: entry.text.length > last.text.length ? entry.height : last.height,
      text: '${last.text}$separator${entry.text}',
      runs: [...last.runs, for (final r in entry.runs) r.shifted(shift)],
      allBold: last.allBold && entry.allBold,
    );
  }
  return merged;
}

/// A styled span within a [ReflowBlock]'s text, as [start, end) character
/// offsets into that block's own `text` string.
///
/// The PDF path only ever sets [bold] and [italic], read from the source's
/// own font info; the Markdown path additionally marks inline code, strike
/// and links, which the same renderer then draws.
class FormatRun {
  const FormatRun({
    required this.start,
    required this.end,
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.link = false,
  });
  final int start;
  final int end;
  final bool bold;
  final bool italic;

  /// Monospace, as inline code (`like this`) is set.
  final bool code;

  /// Struck through (`~~like this~~`).
  final bool strike;

  /// The label of a link (`[like this](url)`) — drawn in the accent colour
  /// and underlined, but still tapped for a translation like any other word.
  final bool link;

  /// The same run with its offsets moved [by] characters into a longer
  /// string — needed every time lines are joined, trimmed or merged.
  FormatRun shifted(int by) => FormatRun(
    start: start + by,
    end: end + by,
    bold: bold,
    italic: italic,
    code: code,
    strike: strike,
    link: link,
  );
}

/// One unit of a reflowed page: either a paragraph of text, or a region
/// that isn't text (almost always an image, chart or table) — carrying
/// its PDF-space bounds so it can be rendered as a real, zoomable image
/// instead of just a placeholder.
///
/// The extra fields below (`headingLevel`, [quoteDepth], [indent], [isCode],
/// [isDivider]) exist for Markdown, which declares its structure in the text
/// rather than in the page's geometry. A PDF block leaves them at their
/// defaults, so nothing about how a PDF page is laid out changes.
class ReflowBlock {
  const ReflowBlock.paragraph(
    this.text, {
    this.formatRuns = const [],
    this.headingLevel = 0,
    this.quoteDepth = 0,
    this.indent = 0,
    this.isCode = false,
    this.isDivider = false,
    this.gapAbove,
    this.sourceTop,
    this.sourceBottom,
    this.tableCells,
    this.tableAlignments,
    this.tableHeader = false,
  }) : imageBounds = null,
       imageBytes = null;
  ReflowBlock.image(Rect bounds)
    : text = '',
      imageBounds = bounds,
      imageBytes = null,
      formatRuns = const [],
      headingLevel = 0,
      quoteDepth = 0,
      indent = 0,
      isCode = false,
      isDivider = false,
      gapAbove = null,
      sourceTop = bounds.isEmpty ? null : bounds.top,
      sourceBottom = bounds.isEmpty ? null : bounds.bottom,
      tableCells = null,
      tableAlignments = null,
      tableHeader = false;

  /// A picture a book carries inside itself (an FB2 binary, an EPUB image):
  /// [bytes] is the encoded image and [size] its pixel size, which is all the
  /// paginator needs to give it room before it has been decoded.
  ReflowBlock.picture(Uint8List bytes, Size size)
    : text = '',
      imageBounds = Rect.fromLTWH(0, 0, size.width, size.height),
      imageBytes = bytes,
      formatRuns = const [],
      headingLevel = 0,
      quoteDepth = 0,
      indent = 0,
      isCode = false,
      isDivider = false,
      gapAbove = null,
      sourceTop = null,
      sourceBottom = null,
      tableCells = null,
      tableAlignments = null,
      tableHeader = false;

  final String text;

  /// Where the block's lines run on its PDF page, top to bottom, in the
  /// page's own points — what keeps the reader's place when they switch
  /// between the page and its reflowed text. Null for a block that came
  /// from anywhere but a page.
  final double? sourceTop;
  final double? sourceBottom;

  /// For a PDF figure, where it sits on the page; for a [ReflowBlock.picture],
  /// just its size. Either way its aspect ratio is what it is paginated by.
  final Rect? imageBounds;

  /// The encoded picture of a [ReflowBlock.picture]; null for a PDF figure,
  /// which is rendered from its page instead.
  final Uint8List? imageBytes;

  /// A section heading rather than body text — set from the source PDF's
  /// own typography (a larger type size, or a fully bold line). Headings
  /// used to flow into the paragraph above them, since a book typically
  /// leaves less space above a heading than the paragraph-break
  /// threshold, and the reflowed page read as one unbroken slab.
  bool get isHeading => headingLevel > 0;

  /// The Markdown heading depth, `#` through `######` (1 to 6), or 0 for
  /// body text. A PDF heading is one undifferentiated style, so it comes
  /// through as level 1; the compact PDF view only ever checks [isHeading].
  final int headingLevel;

  /// How deeply this block is nested inside blockquotes (`>`), which the
  /// reader draws as that many bars down its left edge.
  final int quoteDepth;

  /// How deeply this block is nested inside lists, in levels rather than
  /// characters, so a wrapped item lines up under its own marker.
  final int indent;

  /// Preformatted text — a fenced code block or a table. Set in the
  /// reader's monospace face, on a faint panel, with its own line breaks
  /// kept instead of reflowed.
  final bool isCode;

  /// A thematic break (`---`): no text, just a rule across the column.
  final bool isDivider;

  /// The gap this block wants above itself when it starts a new run on a
  /// sub-page, in place of the view's default block spacing. Null uses the
  /// default. Headings want more than a paragraph does.
  final double? gapAbove;

  /// Bold/italic spans carried over from the source PDF's own font info
  /// (see [TextWord.fontStyle]), so reflowed text doesn't flatten
  /// emphasis into one plain style.
  final List<FormatRun> formatRuns;

  /// For a table, where each cell's text sits in [text], row by row: the
  /// first row is its header. [text] holds the rows one to a line with their
  /// cells between bars, which is what is copied, searched and read aloud,
  /// while the reader draws the cells in a grid. Null for anything else.
  final List<List<({int start, int end})>>? tableCells;

  /// How each column of a table is aligned; missing columns are left
  /// aligned.
  final List<TextAlign>? tableAlignments;

  /// Whether a table's first row is its header: set bold and shaded, and
  /// shown again above the rows of every page the table continues onto.
  final bool tableHeader;

  bool get isImage => imageBounds != null;

  bool get isTable => tableCells != null;
}

/// The blocks as plain text — one blank line between them, empty ones (an
/// image, a rule) left out. This is what a reader copies when they want the
/// page or the whole book instead of one word.
String reflowBlocksText(Iterable<ReflowBlock> blocks) => [
  for (final block in blocks)
    if (block.text.trim().isNotEmpty) block.text.trim(),
].join('\n\n');

/// The same for a paginated book: every page's blocks, then the next page's.
String reflowPagesText(Iterable<Iterable<ReflowBlock>> pages) =>
    reflowPageTexts([
      for (final page in pages) page.map((block) => block.text),
    ]);

/// The same again for pages held as plain block texts — which is how the PDF
/// search index caches a book once it has read it.
String reflowPageTexts(Iterable<Iterable<String>> pages) {
  final texts = [
    for (final page in pages)
      [
        for (final text in page)
          if (text.trim().isNotEmpty) text.trim(),
      ].join('\n\n'),
  ]..removeWhere((text) => text.isEmpty);
  return texts.join('\n\n');
}

/// Recognizes a line that starts with a bullet or numbered-list marker
/// ("•", "-", "1.", "1)", "(2)", "a.", ...), so it can be kept as its own
/// block instead of being flowed into the paragraph before it — losing
/// every list marker in the reflowed view otherwise made it read as one
/// undifferentiated wall of text instead of a list.
final _listMarkerPattern = RegExp(
  r'^[•◦▪▸‣●○*][ \t]+|^[-–—][ \t]+|^\(?[0-9]{1,3}[.)][ \t]+|^\([a-zA-Zа-яА-Я][.)]?\)[ \t]+|^[a-zA-Zа-яА-Я][.)][ \t]+',
);

bool _looksLikeListItem(String text) => _listMarkerPattern.hasMatch(text);

/// Rebuilds [line]'s text word-by-word (rather than using [TextLine.text]
/// directly) so each word's bold/italic — from [TextWord.fontStyle], with
/// the font name as a fallback for PDFs that don't set the style flags —
/// can be recorded as a [FormatRun] against the exact same offsets.
({String text, List<FormatRun> runs, bool allBold}) _lineTextWithRuns(
  TextLine line,
) {
  final buffer = StringBuffer();
  final runs = <FormatRun>[];
  // The extractor usually hands back the space between two words as its
  // own entry in [wordCollection], but not always — a word set in a
  // different font run (an italic variable, say) frequently arrives with
  // no space entry before it, and concatenating blindly glued the two
  // together ("узел x" -> "узелх"), which is wrong on screen and breaks
  // both tap-to-translate and search on those words.
  //
  // The words' own bounds tell the two cases apart unambiguously:
  // fragments that really are one word ("V*" + "(") are exactly flush
  // (gap 0), whereas a dropped space leaves a gap of a good fraction of
  // the type size. Anything at least [spaceGapRatio] of the word's own
  // height counts as a real space.
  const spaceGapRatio = 0.15;
  var boldChars = 0;
  var letterChars = 0;
  var lastCharIsSpace = true;
  double? previousRight;
  for (final word in line.wordCollection) {
    final wordText = sanitizeExtractedText(word.text);
    if (wordText.isEmpty) continue;
    if (wordText.trim().isEmpty) {
      buffer.write(wordText);
      lastCharIsSpace = true;
      previousRight = word.bounds.right;
      continue;
    }
    if (!lastCharIsSpace && previousRight != null) {
      final minSpace = word.bounds.height > 0
          ? word.bounds.height * spaceGapRatio
          : 1.0;
      if (word.bounds.left - previousRight >= minSpace) {
        buffer.write(' ');
      }
    }
    final start = buffer.length;
    buffer.write(wordText);
    lastCharIsSpace = wordText.endsWith(' ');
    previousRight = word.bounds.right;
    final fontNameLower = word.fontName.toLowerCase();
    final bold =
        word.fontStyle.contains(PdfFontStyle.bold) ||
        fontNameLower.contains('bold');
    final italic =
        word.fontStyle.contains(PdfFontStyle.italic) ||
        fontNameLower.contains('italic') ||
        fontNameLower.contains('oblique');
    if (bold || italic) {
      runs.add(
        FormatRun(start: start, end: buffer.length, bold: bold, italic: italic),
      );
    }
    letterChars += wordText.trim().length;
    if (bold) boldChars += wordText.trim().length;
  }
  return (
    text: buffer.toString(),
    runs: runs,
    allBold: letterChars > 0 && boldChars == letterChars,
  );
}

/// Trims [text] and shifts [runs] to match, since [_lineTextWithRuns]
/// builds against the untrimmed line.
({String text, List<FormatRun> runs}) _trimWithRuns(
  String text,
  List<FormatRun> runs,
) {
  final leadingTrim = text.length - text.trimLeft().length;
  final trimmed = text.trim();
  if (leadingTrim == 0) return (text: trimmed, runs: runs);
  return (text: trimmed, runs: [for (final r in runs) r.shifted(-leadingTrim)]);
}

/// Splits a single PDF page's extracted [lines] into reflowed paragraphs
/// sized for phone reading, detecting non-text regions (images, charts,
/// tables) from unusually large vertical gaps — including a gap before
/// the first line or after the last one, since a header/footer figure has
/// no adjacent text on that side at all. List/bullet items are kept as
/// their own block (marker included) rather than merged into the
/// surrounding paragraph, so the reflowed page still reads as a list.
List<ReflowBlock> buildReflowPageBlocks(List<TextLine> lines, Size pageSize) {
  final orderedLines = orderedTextLines(lines);
  if (orderedLines.isEmpty) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return const [];
    return [
      ReflowBlock.image(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height)),
    ];
  }

  // Running heads/page numbers are dropped from the text, but the geometry
  // below still measures gaps against the page's *original* extremes —
  // otherwise the empty margin band a dropped running head used to occupy
  // would itself look like a big gap, i.e. like a figure.
  final contentLines = withoutMarginFurniture(
    orderedLines,
    pageSize,
    medianLineHeight(orderedLines),
  );

  final rows = <_LineEntry>[];
  for (final line in contentLines) {
    final built = _lineTextWithRuns(line);
    final trimmed = _trimWithRuns(built.text, built.runs);
    if (trimmed.text.isEmpty) continue;
    rows.add((
      bounds: line.bounds,
      height: line.bounds.height,
      text: trimmed.text,
      runs: trimmed.runs,
      allBold: built.allBold,
    ));
  }
  final nonEmpty = _mergeVisualRows(rows);

  // Heights are measured on the merged rows, not the raw extracted lines:
  // a page full of subscripts or figure labels would otherwise make the
  // "normal" line look enormous.
  final heights = [
    for (final row in nonEmpty)
      if (row.height > 0) row.height,
  ]..sort();
  final medianHeight = heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];
  final bodyHeight = _modalHeight(heights);
  if (nonEmpty.isEmpty) {
    if (pageSize.width <= 0 || pageSize.height <= 0) return const [];
    return [
      ReflowBlock.image(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height)),
    ];
  }
  final lexicon = buildPageLexicon(nonEmpty.map((e) => e.text));

  // Requiring a sizeable ABSOLUTE gap in addition to the relative
  // (median-based) one keeps a page with generous line spacing, a
  // section break, or lines that arrive slightly out of visual order
  // from being misread as "there's a picture here" when it's really
  // still just text a bit further down the page.
  final paragraphGapThreshold = medianHeight * 1.6;
  final imageGapThreshold = medianHeight * 4.5 < 46 ? 46.0 : medianHeight * 4.5;

  // A heading is set apart typographically rather than by spacing — books
  // routinely leave less room above a heading than between paragraphs — so
  // it has to be recognised from the source's own type. The reliable test
  // is *standing out from its neighbours*: a heading is bigger (or bolder)
  // than the lines around it, short, and doesn't read like a sentence.
  //
  // Comparing against a page-wide average instead was what went wrong
  // before: a page carrying a large figure has dozens of tiny label lines,
  // which drag the page's "normal" size down until every line of ordinary
  // prose looks oversized — and then each line of a paragraph became its
  // own heading, complete with the hyphen it was broken on left dangling
  // at the end. Neighbours can't be fooled that way.
  final headingFlags = List<bool>.filled(nonEmpty.length, false);
  for (var i = 0; i < nonEmpty.length; i++) {
    final entry = nonEmpty[i];
    final text = entry.text;
    if (text.length > 80) continue;
    if (text.endsWith('.') || text.endsWith(',') || text.endsWith(';')) {
      continue;
    }

    final height = entry.height;
    final previous = i > 0 ? nonEmpty[i - 1] : null;
    final next = i + 1 < nonEmpty.length ? nonEmpty[i + 1] : null;
    final neighbourHeight = math.max(previous?.height ?? 0, next?.height ?? 0);
    final standsOutBySize =
        height > bodyHeight * 1.12 && height > neighbourHeight * 1.12;
    // Bold only counts when the surrounding text isn't also bold —
    // otherwise a bold paragraph or a bold-set table breaks up line by
    // line.
    final standsOutByWeight =
        entry.allBold &&
        !(previous?.allBold ?? false) &&
        !(next?.allBold ?? false);
    headingFlags[i] = standsOutBySize || standsOutByWeight;
  }

  bool isHeadingAt(int index) => headingFlags[index];

  final blocks = <ReflowBlock>[];
  var paragraph = '';
  var paragraphRuns = <FormatRun>[];
  var paragraphIsHeading = false;
  var paragraphTop = 0.0;
  var paragraphBottom = 0.0;

  void flush() {
    final text = paragraph.trim();
    // One or two stray characters are never a paragraph: they're labels
    // lifted out of a diagram ("C1", "L"), which read as noise between
    // real paragraphs. The figure itself still carries them, since it's
    // rendered as an image.
    if (text.length <= 2) {
      paragraph = '';
      paragraphRuns = [];
      paragraphIsHeading = false;
      return;
    }
    if (text.isNotEmpty) {
      blocks.add(
        ReflowBlock.paragraph(
          text,
          formatRuns: paragraphRuns,
          headingLevel: paragraphIsHeading ? 1 : 0,
          sourceTop: paragraphTop,
          sourceBottom: paragraphBottom,
        ),
      );
    }
    paragraph = '';
    paragraphRuns = [];
    paragraphIsHeading = false;
  }

  void startParagraph(_LineEntry entry, int index) {
    paragraph = entry.text;
    paragraphRuns = List.of(entry.runs);
    paragraphIsHeading = isHeadingAt(index);
    paragraphTop = entry.bounds.top;
    paragraphBottom = entry.bounds.bottom;
  }

  void continueParagraph(_LineEntry entry) {
    final joined = joinLines(paragraph, entry.text, lexicon: lexicon);
    final shift = joined.length - entry.text.length;
    paragraphRuns = [
      ...paragraphRuns,
      for (final r in entry.runs) r.shifted(shift),
    ];
    paragraph = joined;
    paragraphBottom = math.max(paragraphBottom, entry.bounds.bottom);
  }

  final firstTop = orderedLines.first.bounds.top;
  if (firstTop > imageGapThreshold) {
    blocks.add(
      ReflowBlock.image(Rect.fromLTWH(0, 0, pageSize.width, firstTop)),
    );
  }

  double? previousBottom;
  for (var index = 0; index < nonEmpty.length; index++) {
    final entry = nonEmpty[index];
    final bounds = entry.bounds;
    final startsNewListItem = _looksLikeListItem(entry.text);
    // A heading breaks the flow on both sides: it never joins the
    // paragraph above it, and the body text under it starts fresh.
    final startsNewBlock =
        startsNewListItem || isHeadingAt(index) || paragraphIsHeading;
    if (previousBottom != null) {
      final gap = bounds.top - previousBottom;
      if (gap > imageGapThreshold) {
        flush();
        blocks.add(
          ReflowBlock.image(
            Rect.fromLTWH(0, previousBottom, pageSize.width, gap),
          ),
        );
        startParagraph(entry, index);
        previousBottom = bounds.bottom;
        continue;
      } else if (gap > paragraphGapThreshold || startsNewBlock) {
        flush();
        startParagraph(entry, index);
        previousBottom = bounds.bottom;
        continue;
      } else {
        continueParagraph(entry);
        previousBottom = bounds.bottom;
        continue;
      }
    }
    startParagraph(entry, index);
    previousBottom = bounds.bottom;
  }
  flush();

  final lastBottom = orderedLines.last.bounds.bottom;
  final trailingGap = pageSize.height - lastBottom;
  if (trailingGap > imageGapThreshold) {
    blocks.add(
      ReflowBlock.image(
        Rect.fromLTWH(0, lastBottom, pageSize.width, trailingGap),
      ),
    );
  }

  return blocks;
}

/// The most common height among [sortedHeights] (which must be sorted),
/// rounded to a point — the body text's size by definition. Ties go to the
/// smaller height, since body text is never the largest thing on a page.
double _modalHeight(List<double> sortedHeights) {
  if (sortedHeights.isEmpty) return 12.0;
  final counts = <int, int>{};
  for (final h in sortedHeights) {
    final key = h.round();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  var bestHeight = counts.keys.first;
  var bestCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > bestCount ||
        (entry.value == bestCount && entry.key < bestHeight)) {
      bestHeight = entry.key;
      bestCount = entry.value;
    }
  }
  return bestHeight.toDouble();
}
