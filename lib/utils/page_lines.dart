import 'dart:math' as math;
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Shared page-geometry helpers used by everything that reads a PDF page's
/// text: the reflowed view, and the sentence lookup behind translation.
/// Both need the page's lines in true reading order and without the
/// running heads and page numbers that sit in the margins, and they have
/// to agree — otherwise the sentence a tap translates isn't the sentence
/// the reader sees.

/// Two lines are on the same visual row if their vertical spans overlap
/// (true even when one is a subscript/superscript sitting at a different
/// baseline than the text around it) — in which case reading order is
/// left-to-right; otherwise it's whichever sits higher on the page. This
/// is needed because [PdfTextExtractor] doesn't always return lines in
/// top-to-bottom visual order — notably, a page's footer/page-number can
/// come back positioned right after the header, long before the lines
/// that actually sit above it.
int readingOrderCompare(TextLine a, TextLine b) {
  final overlaps = a.bounds.top < b.bounds.bottom && b.bounds.top < a.bounds.bottom;
  if (overlaps) return a.bounds.left.compareTo(b.bounds.left);
  return a.bounds.top.compareTo(b.bounds.top);
}

/// [lines] with blank ones dropped, in reading order.
List<TextLine> orderedTextLines(List<TextLine> lines) {
  return [
    for (final line in lines)
      if (line.text.trim().isNotEmpty) line,
  ]..sort(readingOrderCompare);
}

/// The typical line height on the page — the yardstick for "is this gap
/// big?" questions. Median rather than mean so one oversized heading or
/// a stray full-page rule doesn't skew it.
double medianLineHeight(List<TextLine> lines) {
  final heights = [
    for (final line in lines)
      if (line.bounds.height > 0) line.bounds.height,
  ]..sort();
  return heights.isEmpty ? 12.0 : heights[heights.length ~/ 2];
}

/// The height of the page's *body* text: the most common line height,
/// rounded to the nearest point.
///
/// The median isn't good enough for this: a page mixing 8pt code listings
/// with 10pt prose can have a median that sits below the prose, and then
/// every ordinary paragraph line looks "bigger than normal" — which is how
/// heading detection ended up marking two thirds of a technical book as
/// headings. The most frequent height is the body text by definition.
double modalLineHeight(List<TextLine> lines) {
  final counts = <int, int>{};
  for (final line in lines) {
    if (line.bounds.height <= 0) continue;
    final key = line.bounds.height.round();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (counts.isEmpty) return medianLineHeight(lines);
  var bestHeight = counts.keys.first;
  var bestCount = 0;
  for (final entry in counts.entries) {
    // On a tie the smaller height wins: body text is never the largest
    // thing on a page.
    if (entry.value > bestCount || (entry.value == bestCount && entry.key < bestHeight)) {
      bestHeight = entry.key;
      bestCount = entry.value;
    }
  }
  return bestHeight.toDouble();
}

/// A line that is nothing but a page number (arabic or roman).
final _folioPattern = RegExp(r'^[0-9]{1,4}$|^[ivxlcdmIVXLCDM]{1,7}$');

/// Drops running heads and page numbers — the repeated furniture in a
/// page's top and bottom margins — from [lines] (which must be in reading
/// order).
///
/// Without this they read as part of the text: a running head sits close
/// enough to the first body line that it isn't even a paragraph break, so
/// it gets flowed straight into the opening sentence ("Сетевой уровень В
/// дистанционно-векторном алгоритме..."), and the page number lands glued
/// to the end of the last one. All three conditions have to hold before a
/// line is dropped, which is what keeps real content on a tight-margined
/// page safe: it sits in the outer margin band, it's much narrower than
/// the text column (a running head or folio always is), and it's
/// separated from the body by a clear vertical gap.
List<TextLine> withoutMarginFurniture(
  List<TextLine> lines,
  Size pageSize,
  double medianHeight,
) {
  const headerBand = 0.075;
  const footerBand = 0.08;
  const maxRelativeWidth = 0.6;
  if (pageSize.height <= 0) return lines;

  var columnLeft = double.infinity;
  var columnRight = -double.infinity;
  for (final line in lines) {
    columnLeft = math.min(columnLeft, line.bounds.left);
    columnRight = math.max(columnRight, line.bounds.right);
  }
  final columnWidth = columnRight - columnLeft;
  if (columnWidth <= 0) return lines;

  final headerLimit = pageSize.height * headerBand;
  final footerLimit = pageSize.height * (1 - footerBand);

  // Which lines even look like furniture: narrow, and out in a margin
  // band. The separation test below is then made against the *body* —
  // never against the neighbouring line — because a running head is
  // routinely extracted as several fragments ("ABOUT", "THIS", "BOOK",
  // plus the folio), and each fragment's neighbour is another fragment
  // sitting right beside it, so a neighbour-based gap test finds no gap
  // and every fragment protects the others from being dropped.
  bool inMarginBand(TextLine line) =>
      line.bounds.top < headerLimit || line.bounds.bottom > footerLimit;

  bool looksLikeFurniture(TextLine line) {
    if (line.bounds.width >= columnWidth * maxRelativeWidth) return false;
    return inMarginBand(line);
  }

  /// A bare page number out in a margin is unmistakable, and gets dropped
  /// on sight — no width or separation test, and regardless of how little
  /// else is on the page. (A page that is mostly one big figure has too
  /// few lines for the general test below to dare touch anything, which is
  /// exactly where stray folios were surviving.)
  bool isFolio(TextLine line) =>
      inMarginBand(line) && _folioPattern.hasMatch(line.text.trim());

  // Too few lines to tell running heads from content — a title page, or a
  // page holding nothing but a figure caption. Page numbers are still
  // dropped, since those need no context to recognise.
  if (lines.length < 4) {
    final kept = [
      for (final line in lines)
        if (!isFolio(line)) line,
    ];
    return kept.isEmpty ? lines : kept;
  }

  final body = [
    for (final line in lines)
      if (!looksLikeFurniture(line)) line,
  ];
  if (body.isEmpty) return lines;

  var bodyTop = double.infinity;
  var bodyBottom = -double.infinity;
  for (final line in body) {
    bodyTop = math.min(bodyTop, line.bounds.top);
    bodyBottom = math.max(bodyBottom, line.bounds.bottom);
  }

  final kept = <TextLine>[];
  for (final line in lines) {
    if (isFolio(line)) continue;
    if (looksLikeFurniture(line)) {
      final separated = line.bounds.bottom <= bodyTop
          ? bodyTop - line.bounds.bottom >= medianHeight
          : line.bounds.top - bodyBottom >= medianHeight;
      if (separated) continue;
    }
    kept.add(line);
  }
  // Never strip a page down to nothing on the strength of a heuristic.
  return kept.length >= 2 ? kept : lines;
}
