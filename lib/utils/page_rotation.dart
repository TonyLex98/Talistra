import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A PDF page's /Rotate, the way it is shown.
///
/// The text extractor reads a page in the orientation its content is drawn
/// in — size and every coordinate — while the page renderer draws it turned
/// the way the file asks, which is what the reader sees. On a rotated page
/// the two disagreed: the page was stretched to the wrong proportions,
/// highlights and marks landed beside their words, and a figure in the
/// compact view was cropped from somewhere else on the page. Everything the
/// app takes from the extractor goes through here, into the orientation
/// the page is shown in.

/// Quarter turns clockwise the page is shown at: 0 to 3.
int quarterTurnsOf(PdfPage page) {
  try {
    return switch (page.rotation) {
      PdfPageRotateAngle.rotateAngle90 => 1,
      PdfPageRotateAngle.rotateAngle180 => 2,
      PdfPageRotateAngle.rotateAngle270 => 3,
      _ => 0,
    };
  } catch (_) {
    return 0;
  }
}

/// The page's size as shown.
Size displayPageSize(PdfPage page) {
  final size = page.size;
  return quarterTurnsOf(page).isOdd ? Size(size.height, size.width) : size;
}

/// [rect], given in the page's unrotated top-down coordinates (page size
/// [unrotated]), as it lies on the page turned [quarterTurns] clockwise.
Rect rotateToDisplay(Rect rect, Size unrotated, int quarterTurns) {
  final w = unrotated.width;
  final h = unrotated.height;
  switch (quarterTurns % 4) {
    case 1:
      return Rect.fromLTRB(
        h - rect.bottom,
        rect.left,
        h - rect.top,
        rect.right,
      );
    case 2:
      return Rect.fromLTRB(
        w - rect.right,
        h - rect.bottom,
        w - rect.left,
        h - rect.top,
      );
    case 3:
      return Rect.fromLTRB(
        rect.top,
        w - rect.right,
        rect.bottom,
        w - rect.left,
      );
    default:
      return rect;
  }
}

/// Turns every line, word and glyph of [lines] (extracted from [page]) into
/// the orientation the page is shown in. In place: the extractor's results
/// are made for this call and nothing else holds them.
List<TextLine> linesAsDisplayed(PdfPage page, List<TextLine> lines) {
  final turns = quarterTurnsOf(page);
  if (turns == 0) return lines;
  final size = page.size;
  for (final line in lines) {
    line.bounds = rotateToDisplay(line.bounds, size, turns);
    for (final word in line.wordCollection) {
      word.bounds = rotateToDisplay(word.bounds, size, turns);
      for (final glyph in word.glyphs) {
        glyph.bounds = rotateToDisplay(glyph.bounds, size, turns);
      }
    }
  }
  return lines;
}
