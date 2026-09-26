import 'dart:math' as math;
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' show TextLine;

import 'page_lines.dart';
import 'text_join.dart';

/// One word on a page, in reading order, with the geometry needed to hit-
/// test it and to draw a highlight over it.
class PageWord {
  const PageWord({
    required this.text,
    required this.bounds,
    required this.lineIndex,
    this.pageIndex = 0,
  });

  final String text;
  final Rect bounds;

  /// Which line of the page this word belongs to — a selection is built
  /// and highlighted line by line, and lines are what get joined back
  /// together (undoing hyphenation) when the selected text is copied.
  ///
  /// For a list flattened over several pages ([flattenWordRange]) these
  /// run continuously across the page breaks, so "line of the page" means
  /// "line of the mark".
  final int lineIndex;

  /// Which page the word is on. A single page's own list leaves it at 0;
  /// only a mark that runs across pages needs it, since its rectangles
  /// have to be drawn in the coordinates of the page they came from.
  final int pageIndex;
}

/// Where a mark begins or ends: the reading-order index of a word on a page.
typedef WordPosition = ({int pageIndex, int wordIndex});

/// One line of a mark, in the PDF coordinates of the page it lies on.
typedef MarkedLine = ({int pageIndex, Rect bounds});

/// Orders two positions the way a reader goes through a book: page first,
/// then the word within it.
int compareWordPositions(WordPosition a, WordPosition b) {
  if (a.pageIndex != b.pageIndex) return a.pageIndex.compareTo(b.pageIndex);
  return a.wordIndex.compareTo(b.wordIndex);
}

/// The words between [start] and [end] over however many pages that spans,
/// flattened into one reading-order list.
///
/// The point of renumbering the lines is that a mark which began on one
/// page and was dragged onto the next is then *the same shape* as a mark
/// inside a single page — so [buildWordRangeSelection], and the
/// hyphenation-undoing join it does across lines, needs no second version
/// for the multi-page case.
List<PageWord> flattenWordRange({
  required WordPosition start,
  required WordPosition end,
  required List<PageWord> Function(int pageIndex) wordsForPage,
}) {
  if (end.pageIndex < start.pageIndex) return const [];
  final result = <PageWord>[];
  var lineBase = 0;
  for (var page = start.pageIndex; page <= end.pageIndex; page++) {
    final words = wordsForPage(page);
    if (words.isEmpty) continue;
    final from = (page == start.pageIndex ? start.wordIndex : 0).clamp(
      0,
      words.length - 1,
    );
    final to = (page == end.pageIndex ? end.wordIndex : words.length - 1).clamp(
      0,
      words.length - 1,
    );
    for (var i = from; i <= to; i++) {
      final word = words[i];
      result.add(
        PageWord(
          text: word.text,
          bounds: word.bounds,
          lineIndex: lineBase + word.lineIndex,
          pageIndex: page,
        ),
      );
    }
    lineBase += words.last.lineIndex + 1;
  }
  return result;
}

/// Flattens a page's [lines] into one reading-order list of words, so a
/// selection can be expressed as a simple range of indices — which is
/// what makes "drag from this word to that word" possible across lines.
List<PageWord> buildPageWords(List<TextLine> lines) {
  final ordered = orderedTextLines(lines);
  final words = <PageWord>[];
  for (var lineIndex = 0; lineIndex < ordered.length; lineIndex++) {
    for (final word in ordered[lineIndex].wordCollection) {
      final text = sanitizeExtractedText(word.text);
      if (text.trim().isEmpty) continue;
      words.add(
        PageWord(text: text, bounds: word.bounds, lineIndex: lineIndex),
      );
    }
  }
  return words;
}

/// The index of the word at [point] (page-local PDF points).
///
/// A drag that wanders into a margin, a gap between lines, or past the end
/// of a line still has to resolve to *something* — otherwise the selection
/// visibly freezes whenever the finger isn't exactly over a glyph. So a
/// miss falls back to the nearest word on the nearest line rather than to
/// null, and only a page with no words at all returns null.
int? wordIndexAt(List<PageWord> words, Offset point, {double padding = 2}) {
  if (words.isEmpty) return null;

  int? bestOnLine;
  var bestOnLineDistance = double.infinity;
  int? bestAnywhere;
  var bestAnywhereDistance = double.infinity;

  for (var i = 0; i < words.length; i++) {
    final bounds = words[i].bounds;
    if (bounds.inflate(padding).contains(point)) return i;

    final verticallyInside =
        point.dy >= bounds.top - padding && point.dy <= bounds.bottom + padding;
    final horizontalDistance = point.dx < bounds.left
        ? bounds.left - point.dx
        : point.dx > bounds.right
        ? point.dx - bounds.right
        : 0.0;
    if (verticallyInside && horizontalDistance < bestOnLineDistance) {
      bestOnLineDistance = horizontalDistance;
      bestOnLine = i;
    }
    final verticalDistance = (bounds.center.dy - point.dy).abs();
    final distance = verticalDistance * 4 + horizontalDistance;
    if (distance < bestAnywhereDistance) {
      bestAnywhereDistance = distance;
      bestAnywhere = i;
    }
  }
  return bestOnLine ?? bestAnywhere;
}

/// The text and highlight rectangles for the words `[from, to]` (either
/// order), as a proper piece of prose: words joined with a space only
/// where the page actually has one, and lines joined the same way the
/// reflowed view joins them, so a word hyphenated across two lines comes
/// out whole and a real compound keeps its hyphen.
({String text, List<MarkedLine> rects}) buildWordRangeSelection(
  List<PageWord> words,
  int from,
  int to, {
  Set<String>? lexicon,
}) {
  if (words.isEmpty) return (text: '', rects: const []);
  final start = math.max(0, math.min(from, to));
  final end = math.min(words.length - 1, math.max(from, to));

  final rects = <MarkedLine>[];
  final lineTexts = <String>[];

  var i = start;
  while (i <= end) {
    final lineIndex = words[i].lineIndex;
    final pageIndex = words[i].pageIndex;
    final buffer = StringBuffer();
    var rect = words[i].bounds;
    double? previousRight;
    while (i <= end && words[i].lineIndex == lineIndex) {
      final word = words[i];
      if (previousRight != null) {
        // Same rule the reflow builder uses: a real gap means a space,
        // flush fragments ("V*" + "(") are one word.
        final minSpace = word.bounds.height > 0
            ? word.bounds.height * 0.15
            : 1.0;
        if (word.bounds.left - previousRight >= minSpace) buffer.write(' ');
      }
      buffer.write(word.text);
      rect = rect.expandToInclude(word.bounds);
      previousRight = word.bounds.right;
      i++;
    }
    rects.add((pageIndex: pageIndex, bounds: rect));
    lineTexts.add(buffer.toString().trim());
  }

  var text = '';
  for (final lineText in lineTexts) {
    text = text.isEmpty
        ? lineText
        : joinLines(text, lineText, lexicon: lexicon);
  }
  return (text: text, rects: rects);
}
