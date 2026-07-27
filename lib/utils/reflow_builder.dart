import 'dart:math' as math;
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
      runs: [
        ...last.runs,
        for (final r in entry.runs)
          FormatRun(
            start: r.start + shift,
            end: r.end + shift,
            bold: r.bold,
            italic: r.italic,
          ),
      ],
      allBold: last.allBold && entry.allBold,
    );
  }
  return merged;
}

/// A bold/italic run within a [ReflowBlock]'s text, as [start, end)
/// character offsets into that block's own `text` string.
class FormatRun {
  const FormatRun({
    required this.start,
    required this.end,
    required this.bold,
    required this.italic,
  });
  final int start;
  final int end;
  final bool bold;
  final bool italic;
}

/// One unit of a reflowed page: either a paragraph of text, or a region
/// that isn't text (almost always an image, chart or table) — carrying
/// its PDF-space bounds so it can be rendered as a real, zoomable image
/// instead of just a placeholder.
class ReflowBlock {
  const ReflowBlock.paragraph(
    this.text, {
    this.formatRuns = const [],
    this.isHeading = false,
  }) : imageBounds = null;
  const ReflowBlock.image(Rect bounds)
    : text = '',
      imageBounds = bounds,
      formatRuns = const [],
      isHeading = false;

  final String text;
  final Rect? imageBounds;

  /// A section heading rather than body text — set from the source PDF's
  /// own typography (a larger type size, or a fully bold line). Headings
  /// used to flow into the paragraph above them, since a book typically
  /// leaves less space above a heading than the paragraph-break
  /// threshold, and the reflowed page read as one unbroken slab.
  final bool isHeading;

  /// Bold/italic spans carried over from the source PDF's own font info
  /// (see [TextWord.fontStyle]), so reflowed text doesn't flatten
  /// emphasis into one plain style.
  final List<FormatRun> formatRuns;

  bool get isImage => imageBounds != null;
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
  return (
    text: trimmed,
    runs: [
      for (final r in runs)
        FormatRun(
          start: r.start - leadingTrim,
          end: r.end - leadingTrim,
          bold: r.bold,
          italic: r.italic,
        ),
    ],
  );
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
          isHeading: paragraphIsHeading,
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
  }

  void continueParagraph(_LineEntry entry) {
    final joined = joinLines(paragraph, entry.text, lexicon: lexicon);
    final shift = joined.length - entry.text.length;
    paragraphRuns = [
      ...paragraphRuns,
      for (final r in entry.runs)
        FormatRun(
          start: r.start + shift,
          end: r.end + shift,
          bold: r.bold,
          italic: r.italic,
        ),
    ];
    paragraph = joined;
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
