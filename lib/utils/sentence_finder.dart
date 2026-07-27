import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'page_lines.dart';
import 'text_join.dart';

/// A word found under a tap, with its PDF-space bounds (page-local points).
class WordHit {
  const WordHit({required this.text, required this.bounds});
  final String text;
  final Rect bounds;
}

/// Finds the word whose bounds contain [point] (page-local PDF points),
/// with a small [padding] tolerance so near-misses at the edge of a
/// glyph still register.
///
/// Syncfusion's [TextLine.wordCollection] includes whitespace runs as
/// entries of their own (e.g. "This", " ", "is", " ", "page" — not just
/// the non-blank words), and some poorly-structured PDFs split one
/// visual word into several text runs (typically at a font/style
/// change) with no such whitespace entry between them, so a tap would
/// otherwise only ever select half the word. But that signal alone isn't
/// always reliable — some extractors omit the whitespace entry even
/// between two genuinely separate words — so a merge additionally
/// requires the two runs' bounds to actually be touching (near-zero
/// horizontal gap); a real inter-word gap, even without its own
/// whitespace token, is left alone.
WordHit? hitTestWord(List<TextLine> lines, Offset point, {double padding = 3}) {
  for (final line in lines) {
    if (!line.bounds.inflate(padding).contains(point)) continue;
    final words = line.wordCollection;
    final texts = [for (final w in words) sanitizeExtractedText(w.text)];
    final touchThreshold = (line.bounds.height * 0.1).clamp(0.35, 1.5);
    for (var i = 0; i < words.length; i++) {
      if (texts[i].trim().isEmpty) continue;
      if (!words[i].bounds.inflate(padding).contains(point)) continue;

      var left = i;
      var right = i;
      while (left > 0 &&
          texts[left - 1].trim().isNotEmpty &&
          words[left].bounds.left - words[left - 1].bounds.right < touchThreshold) {
        left--;
      }
      while (right < words.length - 1 &&
          texts[right + 1].trim().isNotEmpty &&
          words[right + 1].bounds.left - words[right].bounds.right < touchThreshold) {
        right++;
      }

      if (left == right) {
        return WordHit(text: trimWordPunctuation(texts[i]), bounds: words[i].bounds);
      }
      final buffer = StringBuffer();
      var bounds = words[left].bounds;
      for (var k = left; k <= right; k++) {
        buffer.write(texts[k]);
        bounds = bounds.expandToInclude(words[k].bounds);
      }
      return WordHit(text: trimWordPunctuation(buffer.toString()), bounds: bounds);
    }
  }
  return null;
}

/// The sentence that contains a looked-up word: the text, where inside it
/// the word sits, and the PDF-space bounds of every line the sentence
/// spans (so the reader can flash the whole sentence on the page, not
/// just the tapped word).
class SentenceMatch {
  const SentenceMatch({
    required this.sentence,
    required this.wordStart,
    required this.wordEnd,
    required this.lineBounds,
  });

  final String sentence;
  final int wordStart;
  final int wordEnd;
  final List<Rect> lineBounds;
}

/// Finds the sentence on [pageIndex] of [document] that contains [word],
/// so the reader can show translation in context, not just word-by-word.
/// Returns null if the page has no text or the word can't be located.
/// [wordBounds] is where the tapped word actually sits on the page, and
/// matters more than it looks: without it the sentence can only be found
/// by searching the page text for the word, which lands on the *first*
/// place that word occurs. Tap "agents" in a bullet halfway down a page
/// that also says "applications or agents" in its opening paragraph, and
/// the panel would translate that opening sentence instead — the right
/// word, the wrong sentence. With the bounds, the search starts from the
/// line the finger was actually on.
SentenceMatch? findSentenceForWord({
  required PdfDocument document,
  required int pageIndex,
  required String word,
  Rect? wordBounds,
  List<TextLine>? cachedLines,
}) {
  final lines =
      cachedLines ??
      PdfTextExtractor(
        document,
      ).extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
  if (lines.isEmpty) return null;

  // The page's text has to be assembled exactly the way the reflowed view
  // assembles it (same shared helpers): in true reading order, and with
  // running heads and page numbers stripped. Otherwise the "sentence"
  // offered for translation starts with the running head and ends with
  // the page number — and worse, in the raw extractor order those can
  // arrive in the middle of the page, splicing furniture into the middle
  // of a real sentence.
  final ordered = orderedTextLines(lines);
  if (ordered.isEmpty) return null;
  Size pageSize;
  try {
    pageSize = document.pages[pageIndex].size;
  } catch (_) {
    pageSize = Size.zero;
  }
  final contentLines = withoutMarginFurniture(ordered, pageSize, medianLineHeight(ordered));

  // Lines are joined with [joinLines] so a word split across two lines by
  // a line-break hyphen ("exam-" / "ple") reads as one continuous token —
  // otherwise a whole-word search for it would never match.
  final lineTexts = [for (final line in contentLines) sanitizeExtractedText(line.text)];
  final lexicon = buildPageLexicon(lineTexts.map((t) => t.trim()));
  final buffer = StringBuffer();
  final lineRanges = <({int start, int end})>[];
  for (final text in lineTexts) {
    if (buffer.isEmpty) {
      buffer.write(text);
      lineRanges.add((start: 0, end: buffer.length));
      continue;
    }
    final joined = joinLines(buffer.toString(), text, lexicon: lexicon);
    buffer.clear();
    buffer.write(joined);
    lineRanges.add((start: joined.length - text.length, end: joined.length));
  }
  final pageText = buffer.toString();

  final match = _matchSentence(
    pageText,
    word,
    hintOffset: _offsetOfTappedWord(contentLines, lineTexts, lineRanges, word, wordBounds),
  );
  if (match == null) return null;

  final lineBounds = <Rect>[
    for (var i = 0; i < contentLines.length; i++)
      if (lineRanges[i].start < match.rangeEnd && lineRanges[i].end > match.rangeStart)
        contentLines[i].bounds,
  ];

  return SentenceMatch(
    sentence: match.sentence,
    wordStart: match.wordStart,
    wordEnd: match.wordEnd,
    lineBounds: lineBounds,
  );
}

/// Where in the assembled page text the tapped word sits, if it can be
/// pinned down: the line whose bounds contain [wordBounds], plus the
/// word's offset inside that line. Returns null when there's nothing to
/// go on, which puts the search back to "first occurrence on the page".
int? _offsetOfTappedWord(
  List<TextLine> contentLines,
  List<String> lineTexts,
  List<({int start, int end})> lineRanges,
  String word,
  Rect? wordBounds,
) {
  if (wordBounds == null || contentLines.isEmpty) return null;

  var bestLine = -1;
  var bestOverlap = 0.0;
  for (var i = 0; i < contentLines.length; i++) {
    final intersection = contentLines[i].bounds.intersect(wordBounds);
    if (intersection.width <= 0 || intersection.height <= 0) continue;
    final overlap = intersection.width * intersection.height;
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      bestLine = i;
    }
  }
  if (bestLine < 0) return null;

  final lineStart = lineRanges[bestLine].start;
  final inLine = _findWholeWordIndex(lineTexts[bestLine].toLowerCase(), word.toLowerCase());
  return inLine == -1 ? lineStart : lineStart + inLine;
}

/// Finds the sentence inside [text] that contains [word] — the same
/// matching used by [findSentenceForWord], but for plain text that isn't
/// tied to PDF page geometry (e.g. reflowed paragraphs).
SentenceMatch? findSentenceInText(String text, String word) {
  final match = _matchSentence(text, word);
  if (match == null) return null;
  return SentenceMatch(
    sentence: match.sentence,
    wordStart: match.wordStart,
    wordEnd: match.wordEnd,
    lineBounds: const [],
  );
}

/// A translatable sentence runs from one punctuation mark to the next —
/// it isn't padded out to some minimum by pulling in neighboring
/// sentences. The one safety net that still applies is a MAXIMUM: a
/// badly-structured PDF can lack sentence-ending punctuation for a whole
/// page, which would otherwise turn "the sentence" into everything up to
/// the next period.
const _maxSentenceLength = 320;

/// Locates [word] as a whole word inside [text], within the single
/// naive punctuation-delimited sentence it falls in — trimmed down to
/// [_maxSentenceLength] (snapped to word boundaries, centered on the
/// word) only if that sentence runs unreasonably long (missing
/// punctuation). Returns the final sentence text, the word's position
/// within it, and the absolute [text] offsets it came from (so callers
/// with page geometry can map it back to lines).
({String sentence, int wordStart, int wordEnd, int rangeStart, int rangeEnd})? _matchSentence(
  String text,
  String word, {
  int? hintOffset,
}) {
  final wordLower = word.toLowerCase();
  final allRanges = _splitSentenceRanges(text);

  // With a position to go on, the sentence containing it is tried first
  // and everything else only as a fallback — so the answer is the
  // sentence the reader actually touched, not merely one that happens to
  // contain the same word.
  final ranges = <({int start, int end})>[];
  if (hintOffset != null) {
    for (final range in allRanges) {
      if (hintOffset >= range.start && hintOffset < range.end) ranges.add(range);
    }
  }
  ranges.addAll(allRanges);

  for (var i = 0; i < ranges.length; i++) {
    final range = ranges[i];
    final candidate = text.substring(range.start, range.end);
    final relIdx = _findWholeWordIndex(candidate.toLowerCase(), wordLower);
    if (relIdx == -1) continue;
    final wordAbsStart = range.start + relIdx;

    var start = range.start;
    var end = range.end;

    if (end - start > _maxSentenceLength) {
      final half = _maxSentenceLength ~/ 2;
      var windowStart = wordAbsStart - half;
      var windowEnd = wordAbsStart + word.length + half;
      if (windowStart < start) {
        windowEnd += start - windowStart;
        windowStart = start;
      }
      if (windowEnd > end) {
        windowStart -= windowEnd - end;
        windowEnd = end;
      }
      windowStart = windowStart.clamp(start, end);
      windowEnd = windowEnd.clamp(start, end);
      while (windowStart > start && isMidWord(text, windowStart)) {
        windowStart--;
      }
      while (windowEnd < end && isMidWord(text, windowEnd)) {
        windowEnd++;
      }
      start = windowStart;
      end = windowEnd;
    }

    final sentence = text.substring(start, end).trim();
    final idx = _findWholeWordIndex(sentence.toLowerCase(), wordLower);
    if (idx == -1) continue;
    return (
      sentence: sentence,
      wordStart: idx,
      wordEnd: idx + word.length,
      rangeStart: start,
      rangeEnd: end,
    );
  }
  return null;
}

/// Extracts the text lines for a page; cache the result per page to avoid
/// re-parsing the content stream on every tap.
List<TextLine> extractPageLines(PdfDocument document, int pageIndex) {
  return PdfTextExtractor(
    document,
  ).extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
}

/// Finds the word inside [sentence] that best matches [word], so a
/// translated word can be highlighted inside its translated sentence.
/// Translation APIs give no word-alignment info, and inflected languages
/// (e.g. Russian adjectives agreeing in gender: "быстрый" vs "быстрая")
/// mean an exact match often fails — so this falls back to the token
/// sharing the longest prefix with [word].
({int start, int end})? findFuzzyWordMatch(String sentence, String word) {
  final wordLower = word.trim().toLowerCase();
  if (wordLower.isEmpty) return null;

  final tokens = <({int start, int end, String text})>[];
  final buffer = StringBuffer();
  var tokenStart = -1;
  for (var i = 0; i <= sentence.length; i++) {
    final ch = i < sentence.length ? sentence[i] : '';
    if (_isLetter(ch)) {
      tokenStart = tokenStart == -1 ? i : tokenStart;
      buffer.write(ch);
    } else if (tokenStart != -1) {
      tokens.add((start: tokenStart, end: i, text: buffer.toString().toLowerCase()));
      buffer.clear();
      tokenStart = -1;
    }
  }

  for (final t in tokens) {
    if (t.text == wordLower) return (start: t.start, end: t.end);
  }

  ({int start, int end})? best;
  var bestShared = 0;
  for (final t in tokens) {
    final shared = _commonPrefixLength(t.text, wordLower);
    final shorter = wordLower.length < t.text.length ? wordLower.length : t.text.length;
    final threshold = shorter >= 3 ? 3 : shorter;
    if (shared >= threshold && shared > bestShared) {
      bestShared = shared;
      best = (start: t.start, end: t.end);
    }
  }
  return best;
}

int _commonPrefixLength(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a[i] == b[i]) {
    i++;
  }
  return i;
}

final _letterPattern = RegExp(r'\p{L}', unicode: true);
bool _isLetter(String ch) => ch.isNotEmpty && _letterPattern.hasMatch(ch);

/// Finds [needleLower] inside [haystackLower] as a whole word (not part of
/// a longer word), returning its start index or -1.
int _findWholeWordIndex(String haystackLower, String needleLower) {
  if (needleLower.isEmpty) return -1;
  var start = 0;
  while (true) {
    final idx = haystackLower.indexOf(needleLower, start);
    if (idx == -1) return -1;
    final before = idx > 0 ? haystackLower[idx - 1] : '';
    final afterIdx = idx + needleLower.length;
    final after = afterIdx < haystackLower.length ? haystackLower[afterIdx] : '';
    if (!_isLetter(before) && !_isLetter(after)) return idx;
    start = idx + 1;
  }
}

/// Full stops that don't end a sentence: an abbreviation's own dot. A
/// sentence break after one of these is what turns "На рис. 4.30
/// проиллюстрирована работа алгоритма" into two fragments, neither of
/// which translates to anything sensible.
const _abbreviations = <String>{
  // Russian
  'рис', 'табл', 'стр', 'см', 'гл', 'т', 'п', 'д', 'др', 'пр', 'вып', 'изд',
  'напр', 'ср', 'ок', 'млн', 'млрд', 'тыс', 'руб', 'г', 'гг', 'вв', 'им',
  'сокр', 'англ', 'лат', 'ул', 'разд', 'прим',
  // English
  'fig', 'eq', 'vs', 'etc', 'no', 'vol', 'ch', 'pp', 'al', 'cf', 'ed', 'dr',
  'mr', 'mrs', 'ms', 'st', 'approx', 'sec', 'ex', 'ref',
};

const _sentenceTerminators = {'.', '!', '?', '…'};

/// Quotes and brackets that belong to the sentence they close, so the
/// break lands after them rather than inside them.
const _closingMarks = {'"', '»', '”', '’', "'", ')', ']'};

/// Characters a new sentence can legitimately begin with, besides an
/// uppercase letter — an opening quote, a bracket, or a dialogue dash.
const _sentenceOpeners = {'«', '"', '“', '(', '[', '—', '–', '-', "'", '‘'};

bool _isSpace(String ch) => ch == ' ' || ch == '\n' || ch == '\t' || ch == ' ';

/// Sentence splitter: breaks after '.', '!', '?' or '…' followed by
/// whitespace (or end of text), returning raw (untrimmed) [start, end)
/// offsets into [text] so callers can map a sentence back to the page
/// geometry it came from.
///
/// A period is the ambiguous one — it also ends abbreviations, initials
/// and decimal numbers — so a break there additionally requires that the
/// word in front of it isn't an initial or a known abbreviation, and that
/// what follows actually looks like the start of a sentence. That last
/// test is what keeps "рис. 4.30" and "т. е." whole, since a digit or a
/// lowercase word never starts a new sentence. Still a reading aid, not a
/// linguistically complete parser.
const _listMarkers = {'•', '◦', '▪', '‣', '●', '○', '–', '—'};

/// A list item starts a new sentence even though the text before it may
/// have ended with a colon: technical books introduce bullets with
/// "...robust systems: • Chapter 1 maps ...", and without this break the
/// sentence offered for translation stretches from the lead-in across the
/// whole bullet.
bool _startsListItem(String text, int index) {
  if (!_listMarkers.contains(text[index])) return false;
  if (index == 0 || !_isSpace(text[index - 1])) return false;
  final next = index + 1;
  return next < text.length && _isSpace(text[next]);
}

List<({int start, int end})> _splitSentenceRanges(String text) {
  final ranges = <({int start, int end})>[];
  var sentenceStart = 0;
  for (var i = 0; i < text.length; i++) {
    if (_startsListItem(text, i) && i > sentenceStart) {
      ranges.add((start: sentenceStart, end: i));
      sentenceStart = i;
      continue;
    }
    if (!_sentenceTerminators.contains(text[i])) continue;

    var end = i + 1;
    while (end < text.length && _closingMarks.contains(text[end])) {
      end++;
    }
    if (end < text.length && !_isSpace(text[end])) continue;
    if (text[i] == '.' && !_periodEndsSentence(text, i, end)) continue;

    ranges.add((start: sentenceStart, end: end));
    sentenceStart = end;
  }
  if (sentenceStart < text.length) {
    ranges.add((start: sentenceStart, end: text.length));
  }
  return ranges;
}

bool _periodEndsSentence(String text, int dotIndex, int afterClosing) {
  var wordStart = dotIndex;
  while (wordStart > 0 && _isLetter(text[wordStart - 1])) {
    wordStart--;
  }
  final word = text.substring(wordStart, dotIndex).toLowerCase();
  // A single letter before the dot is an initial ("А. С. Пушкин", "e. g.").
  if (word.length == 1) return false;
  if (_abbreviations.contains(word)) return false;

  var next = afterClosing;
  while (next < text.length && _isSpace(text[next])) {
    next++;
  }
  // Trailing punctuation at the very end of the page text ends whatever
  // sentence it's in.
  if (next >= text.length) return true;
  final ch = text[next];
  if (_isLetter(ch)) return ch.toUpperCase() == ch;
  return _sentenceOpeners.contains(ch);
}
