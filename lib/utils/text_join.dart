final _letterPattern = RegExp(r'\p{L}', unicode: true);
bool isLetter(String ch) => ch.isNotEmpty && _letterPattern.hasMatch(ch);

final _ligatures = <String, String>{
  '\u{FB00}': 'ff',
  '\u{FB01}': 'fi',
  '\u{FB02}': 'fl',
  '\u{FB03}': 'ffi',
  '\u{FB04}': 'ffl',
  '\u{FB05}': 'st',
  '\u{FB06}': 'st',
};

/// Matches characters that come out of PDF text extraction looking like
/// mystery glyphs (tofu boxes) rather than real, portable text:
///  - Private Use Area codepoints (U+E000-U+F8FF, plus the two
///    supplementary PUA planes): custom/symbol fonts map their own glyphs
///    here with no ToUnicode mapping, so outside the original embedded
///    font they carry no real meaning — usually decorative bullets/icons,
///    but PDFs sometimes also (mis)use this range for ordinary letters in
///    a custom-encoded font, which is what shows up as an "unknown
///    symbol" in place of a short common word.
///  - Zero-width characters and the byte-order-mark, which render as
///    nothing but can silently glue two separate words together.
final _junkGlyphPattern = RegExp(
  '[\u{E000}-\u{F8FF}\u{F0000}-\u{FFFFD}\u{100000}-\u{10FFFD}'
  '\u{200B}\u{200C}\u{200D}\u{FEFF}]',
  unicode: true,
);

const _softHyphen = '\u{00AD}';
const _nonBreakingSpace = '\u{00A0}';

/// Some PDFs embed a font whose encoding is really Windows-1252 (common
/// in older Word-exported documents) but ship a broken or missing
/// ToUnicode CMap for its upper byte range — so instead of the intended
/// typographic character, text extraction hands back the raw byte value
/// reinterpreted as a Unicode codepoint, landing in the C1 control range
/// (U+0080-U+009F) where it renders as an invisible/tofu-box glyph. Seen
/// in the wild as an em dash or curly quote vanishing into a mystery box
/// ("others▯ thank you", "It▯s a stronger work"). Undefined slots in this
/// byte range fall back to a space rather than leaving the control char.
const _cp1252ControlRange = <String, String>{
  '\u{80}': '€', '\u{82}': '‚', '\u{83}': 'ƒ', '\u{84}': '„',
  '\u{85}': '…', '\u{86}': '†', '\u{87}': '‡', '\u{88}': 'ˆ',
  '\u{89}': '‰', '\u{8A}': 'Š', '\u{8B}': '‹', '\u{8C}': 'Œ',
  '\u{8E}': 'Ž', '\u{91}': '‘', '\u{92}': '’', '\u{93}': '“',
  '\u{94}': '”', '\u{95}': '•', '\u{96}': '–', '\u{97}': '—',
  '\u{98}': '˜', '\u{99}': '™', '\u{9A}': 'š', '\u{9B}': '›',
  '\u{9C}': 'œ', '\u{9E}': 'ž', '\u{9F}': 'Ÿ',
};
final _cp1252ControlPattern = RegExp('[\u{80}-\u{9F}]', unicode: true);

String _fixMisdecodedCp1252(String text) {
  if (!_cp1252ControlPattern.hasMatch(text)) return text;
  return text.replaceAllMapped(
    _cp1252ControlPattern,
    (match) => _cp1252ControlRange[match[0]] ?? ' ',
  );
}

final _cyrillicPattern = RegExp(r'[Ѐ-ӿ]');
bool _isCyrillic(String ch) => ch.isNotEmpty && _cyrillicPattern.hasMatch(ch);

/// Some PDFs (seen in a Russian textbook whose heading font had a broken
/// ToUnicode mapping) encode a discretionary/soft hyphen inside a long
/// Cyrillic word as a literal "/" instead — "Дистан/ционно-векторный" for
/// "Дистанционно-векторный".
///
/// A bare slash between two Cyrillic runs is genuinely ambiguous: it's a
/// broken hyphen in that case, but an ordinary slash in
/// "генерирование/получение". What separates them is where the break
/// falls — hyphenation splits *one* word, so the fragment in front of the
/// break is a word fragment (short), whereas a real slash joins two whole
/// words, and Russian whole words on the left of a slash are longer than
/// that. Hence the deliberately narrow window below: 5..8 Cyrillic
/// letters before the slash and 5+ after. Anything else — a longer left
/// side ("генерирование/получение"), a short one ("и/или", "вкл/выкл"),
/// or non-Cyrillic text (URLs, "I/O", "gguf/resolve/main") — is left
/// exactly as it came out of the PDF, since wrongly deleting a slash
/// welds two real words together, which is worse than leaving one in.
String _stripMidWordSlashArtifact(String text) {
  final slashIndex = text.indexOf('/');
  if (slashIndex <= 0 || slashIndex >= text.length - 1) return text;
  var before = 0;
  for (var i = slashIndex - 1; i >= 0 && _isCyrillic(text[i]); i--) {
    before++;
  }
  var after = 0;
  for (var i = slashIndex + 1; i < text.length && _isCyrillic(text[i]); i++) {
    after++;
  }
  final looksLikeBrokenHyphen = before >= 5 && before <= 8 && after >= 5;
  if (!looksLikeBrokenHyphen) return text;
  return text.substring(0, slashIndex) + text.substring(slashIndex + 1);
}

/// A lone Latin letter welded to the front of a Cyrillic word ("ZКаждый"
/// for "Каждый") — a glyph from a font whose ToUnicode mapping points at
/// the wrong codepoint, and which the page itself doesn't draw at all
/// (typically a paragraph-indent or spacing glyph). Real text never runs
/// a single Latin capital straight into a Cyrillic word with no space, so
/// this only ever fires on the artifact. The letter is deleted rather
/// than spaced out because there is nothing there visually to preserve —
/// a genuinely adjacent word would have arrived with a measurable gap,
/// which the reflow builder turns into a real space before this runs.
final _latinGlyphGluedToCyrillicWord = RegExp(
  r'(?<![\p{L}\p{N}])[A-Za-z](?=[А-ЯЁ][а-яё])',
  unicode: true,
);

/// Cleans up text pulled out of `syncfusion_flutter_pdf`'s extractor
/// before it's shown or matched against: expands common typographic
/// ligatures ("ﬁ" -> "fi") so words read and search correctly, turns a
/// soft hyphen/non-breaking space into their plain equivalents, and drops
/// characters that only had meaning inside a font this app doesn't have
/// (see [_junkGlyphPattern]) — those show up otherwise as a stray
/// "unknown symbol" box, most often in place of small/odd glyphs a
/// custom-encoded PDF font used for common short words.
String sanitizeExtractedText(String text) {
  if (text.isEmpty) return text;
  var result = _fixMisdecodedCp1252(text);
  _ligatures.forEach((from, to) => result = result.replaceAll(from, to));
  result = result
      .replaceAll(_softHyphen, '')
      .replaceAll(_nonBreakingSpace, ' ')
      .replaceAll(_junkGlyphPattern, ' ');
  result = result.replaceAll(_questionMarkInsideWord, '');
  result = joinEmbeddedHyphenBreaks(result);
  result = _stripMidWordSlashArtifact(result);
  result = result.replaceAll(_latinGlyphGluedToCyrillicWord, '');
  return result;
}

/// A bare hyphen directly followed by a newline, inside a single chunk of
/// extracted text, is unambiguously a line-break hyphenation ("exam-\nple")
/// rather than punctuation — a real dash is never immediately followed by
/// a line break with no space. Collapses those (and any other embedded
/// newlines, which reflow doesn't want mid-paragraph) down to a single
/// joined word or a plain space, same rule [joinLines] uses at the
/// line-to-line boundary.
String joinEmbeddedHyphenBreaks(String text) {
  if (!text.contains('\n')) return text;
  final buffer = StringBuffer();
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] != '\n') continue;
    final before = text.substring(start, i);
    final nextChar = i + 1 < text.length ? text[i + 1] : '';
    final beforeHyphen = before.length >= 2 ? before[before.length - 2] : '';
    final isSoftHyphenBreak = before.endsWith('-') &&
        isLetter(beforeHyphen) &&
        isLetter(nextChar) &&
        nextChar == nextChar.toLowerCase();
    buffer.write(isSoftHyphenBreak ? before.substring(0, before.length - 1) : '$before ');
    start = i + 1;
  }
  buffer.write(text.substring(start));
  return buffer.toString();
}

final _lexiconWordPattern = RegExp(r'\p{L}{4,}', unicode: true);
final _trailingWordPattern = RegExp(r'\p{L}+$', unicode: true);
final _leadingWordPattern = RegExp(r'^\p{L}+', unicode: true);

/// Every word of 4+ letters that appears as a *whole* word in
/// [lineTexts], lowercased — a page's own miniature lexicon, used by
/// [joinLines] to tell a real compound word from a hyphenation break.
///
/// A fragment left in front of a line-ending hyphen is deliberately not
/// counted: it's the very thing being judged, so letting it vouch for
/// itself would make the test circular.
Set<String> buildPageLexicon(Iterable<String> lineTexts) {
  final words = <String>{};
  for (final line in lineTexts) {
    final endsHyphenated = line.endsWith('-');
    final text = endsHyphenated ? line.substring(0, line.length - 1) : line;
    for (final match in _lexiconWordPattern.allMatches(text)) {
      if (endsHyphenated && match.end == text.length) continue;
      words.add(match.group(0)!.toLowerCase());
    }
  }
  return words;
}

/// Joins two consecutive lines of PDF text, undoing line-break
/// hyphenation ("exam-" + "ple" -> "example") while leaving real hyphens
/// and dashes untouched.
///
/// Badly-structured PDFs sometimes wrap a word across two lines with a
/// plain ASCII hyphen ("-") glued directly to the end of the first line,
/// which then makes whole-word search fail (it only ever sees "exam" or
/// "ple", never "example"). A genuine dash used as punctuation is either
/// a real em/en-dash character or has a space before it — neither looks
/// like that, so only a bare '-' touching the previous letter, at the
/// very end of a line, followed by a lowercase letter, is treated as a
/// soft line-break and merged; anything else is joined with a space.
///
/// That rule alone can't see the difference between a split word and a
/// compound one that happens to break at its own hyphen — "узел-" +
/// "сосед" is the compound "узел-сосед", but "вектор-" + "ную" is one
/// word — and dropping the hyphen welds real compounds together
/// ("узелсосед"). Pass [lexicon] (see [buildPageLexicon]) to resolve
/// that: in a compound *both* halves are words in their own right,
/// whereas a split leaves at least one half a fragment, so the hyphen
/// survives only on positive evidence for both halves.
String joinLines(String previous, String next, {Set<String>? lexicon}) {
  if (previous.isEmpty) return next;
  if (next.isEmpty) return previous;

  if (previous.endsWith('-') && previous.length >= 2) {
    final beforeHyphen = previous[previous.length - 2];
    final nextFirst = next[0];
    if (isLetter(beforeHyphen) && isLetter(nextFirst) && nextFirst == nextFirst.toLowerCase()) {
      if (lexicon != null && _isRealCompound(previous, next, lexicon)) {
        return '$previous$next';
      }
      return previous.substring(0, previous.length - 1) + next;
    }
  }
  return '$previous $next';
}

bool _isRealCompound(String previous, String next, Set<String> lexicon) {
  final left = _trailingWordPattern
      .firstMatch(previous.substring(0, previous.length - 1))
      ?.group(0)
      ?.toLowerCase();
  final right = _leadingWordPattern.firstMatch(next)?.group(0)?.toLowerCase();
  return left != null &&
      right != null &&
      left.length >= 4 &&
      right.length >= 4 &&
      lexicon.contains(left) &&
      lexicon.contains(right);
}

/// A question mark *inside* a word ("коэ?ф?фициенты", "тра?фика").
///
/// No real word contains one: it's a discretionary hyphen whose font had
/// no usable mapping, so extraction fell back to "?". Removing it puts the
/// word back together — leaving it in makes the page read as if it were
/// full of typos.
final _questionMarkInsideWord = RegExp(r'(?<=\p{L})\?(?=\p{L})', unicode: true);

const _leadingTrimChars = {'«', '"', '“', '‘', "'", '(', '[', '{', '¿', '¡', '—', '–', '-', '.', ','};
const _trailingTrimChars = {'.', ',', ';', ':', '!', '?', '…', '»', '"', '”', '’', "'", ')', ']', '}', '—', '–'};
const _closerToOpener = {')': '(', ']': '[', '}': '{', '»': '«', '”': '“'};

/// Strips the punctuation hanging off a word picked out of a page, so a
/// tap on the last word of a clause looks up "agents" rather than
/// "agents," — which is what gets shown, translated, and searched for.
///
/// A closing bracket or quote is only dropped when the word doesn't
/// contain its opener, so tokens that legitimately carry brackets
/// ("V*(y)", "(iii)") aren't left unbalanced.
String trimWordPunctuation(String word) {
  var start = 0;
  var end = word.length;
  while (start < end && _leadingTrimChars.contains(word[start])) {
    start++;
  }
  while (end > start) {
    final ch = word[end - 1];
    if (!_trailingTrimChars.contains(ch)) break;
    final opener = _closerToOpener[ch];
    if (opener != null && word.substring(start, end).contains(opener)) break;
    end--;
  }
  final trimmed = word.substring(start, end);
  // Never hand back an empty word: punctuation-only tokens (a lone dash,
  // a stray bracket) are still what the reader tapped.
  return trimmed.isEmpty ? word : trimmed;
}

/// Whether [pos] sits strictly inside a run of letters in [text] (i.e.
/// the characters immediately before and after it are both letters) —
/// used to avoid truncating a sentence window mid-word.
bool isMidWord(String text, int pos) {
  if (pos <= 0 || pos >= text.length) return false;
  return isLetter(text[pos - 1]) && isLetter(text[pos]);
}
