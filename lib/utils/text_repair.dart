import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Repairs, or refuses, the text a PDF page gives up.
///
/// A PDF's text is only as good as its fonts' character maps, and plenty of
/// real files ship fonts without one. Two things then come out of the
/// extractor, and both used to reach the compact view as «крокозябры»:
///
/// * Russian set in an old 8-bit font reads as Latin-1 — «Ïðèâåò» for
///   «Привет». Every letter is the Windows-1251 byte of the right one, so
///   the page is turned back into Cyrillic, character for character.
/// * Glyph codes with no letters behind them at all — private-use code
///   points, control characters, runs of symbols. There is no fixing that
///   from the text; the page is treated as having none, so the reader shows
///   its picture (and reads it by OCR where that is available) instead of
///   garbage.

/// [lines] repaired in place, or an empty list when they are beyond repair.
List<TextLine> repairPageLines(List<TextLine> lines) {
  if (lines.isEmpty) return lines;
  final all = StringBuffer();
  for (final line in lines) {
    all.write(line.text);
  }
  final text = all.toString();
  if (looksLikeCp1251AsLatin1(text)) {
    for (final line in lines) {
      line.text = cp1251FromLatin1(line.text);
      for (final word in line.wordCollection) {
        word.text = cp1251FromLatin1(word.text);
        for (final glyph in word.glyphs) {
          glyph.text = cp1251FromLatin1(glyph.text);
        }
      }
    }
    return lines;
  }
  if (looksLikeGarbage(text)) return const [];
  return lines;
}

bool _isLatin1Letter(int c) =>
    (c >= 0xC0 && c <= 0xFF && c != 0xD7 && c != 0xF7) ||
    c == 0xA8 ||
    c == 0xB8;

bool _isLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0xAA && c != 0xD7 && c != 0xF7 && !_isOddity(c) && _isAlphabetic(c));

/// Letters of the scripts a reader here reads — Latin, Greek, Cyrillic and
/// their extensions, and the big East Asian blocks. Punctuation and symbol
/// blocks are not letters.
bool _isAlphabetic(int c) =>
    (c >= 0xC0 && c <= 0x24F) ||
    (c >= 0x370 && c <= 0x52F) ||
    (c >= 0x1E00 && c <= 0x1FFF) ||
    (c >= 0x3040 && c <= 0x9FFF) ||
    (c >= 0xAC00 && c <= 0xD7AF) ||
    (c >= 0x600 && c <= 0x6FF) ||
    (c >= 0x590 && c <= 0x5FF);

bool _isOddity(int c) =>
    c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D ||
    (c >= 0xE000 && c <= 0xF8FF) ||
    c == 0xFFFD ||
    (c >= 0xFFF0);

/// Whether [text] is Windows-1251 read as Latin-1: most of its letters in the
/// Latin-1 supplement. Real French, German or Spanish has a few accented
/// letters among plain ones, never a majority.
bool looksLikeCp1251AsLatin1(String text) {
  var letters = 0;
  var latin1 = 0;
  for (final c in text.runes) {
    if (_isLatin1Letter(c)) {
      latin1++;
      letters++;
    } else if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
      letters++;
    } else if (c >= 0x400 && c <= 0x4FF) {
      // Real Cyrillic already there: nothing to repair.
      return false;
    }
  }
  return letters >= 8 && latin1 >= letters * 0.55;
}

/// [text] with every Latin-1 letter put back as the Cyrillic letter whose
/// Windows-1251 byte it is.
String cp1251FromLatin1(String text) {
  final out = StringBuffer();
  for (final c in text.runes) {
    if (c >= 0xC0 && c <= 0xFF) {
      out.writeCharCode(0x410 + (c - 0xC0));
    } else if (c == 0xA8) {
      out.writeCharCode(0x401);
    } else if (c == 0xB8) {
      out.writeCharCode(0x451);
    } else if (c == 0xB9) {
      out.writeCharCode(0x2116); // №
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Whether [text] is glyph codes rather than words: too many code points no
/// font maps to a character, or too few letters among the rest.
bool looksLikeGarbage(String text) {
  var visible = 0;
  var odd = 0;
  var letters = 0;
  var digits = 0;
  for (final c in text.runes) {
    if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) continue;
    visible++;
    if (_isOddity(c)) {
      odd++;
    } else if (_isLetter(c)) {
      letters++;
    } else if (c >= 0x30 && c <= 0x39) {
      digits++;
    }
  }
  if (visible < 20) return false;
  if (odd > visible * 0.1) return true;
  // A page of tables can be mostly digits; a page of prose is mostly
  // letters. A page that is neither is symbols standing in for letters.
  return letters + digits < visible * 0.5;
}
