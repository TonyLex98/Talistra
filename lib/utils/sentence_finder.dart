import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A word found under a tap, with its PDF-space bounds (page-local points).
class WordHit {
  const WordHit({required this.text, required this.bounds});
  final String text;
  final Rect bounds;
}

/// Finds the word whose bounds contain [point] (page-local PDF points),
/// with a small [padding] tolerance so near-misses at the edge of a
/// glyph still register.
WordHit? hitTestWord(List<TextLine> lines, Offset point, {double padding = 3}) {
  for (final line in lines) {
    if (!line.bounds.inflate(padding).contains(point)) continue;
    for (final word in line.wordCollection) {
      if (word.bounds.inflate(padding).contains(point)) {
        return WordHit(text: word.text, bounds: word.bounds);
      }
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
SentenceMatch? findSentenceForWord({
  required PdfDocument document,
  required int pageIndex,
  required String word,
  List<TextLine>? cachedLines,
}) {
  final lines =
      cachedLines ??
      PdfTextExtractor(
        document,
      ).extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
  if (lines.isEmpty) return null;

  final buffer = StringBuffer();
  final lineRanges = <({int start, int end})>[];
  for (final line in lines) {
    final start = buffer.length;
    buffer.write(line.text);
    lineRanges.add((start: start, end: buffer.length));
    buffer.write(' ');
  }
  final pageText = buffer.toString();
  final wordLower = word.toLowerCase();

  for (final range in _splitSentenceRanges(pageText)) {
    final sentence = pageText.substring(range.start, range.end).trim();
    final idx = _findWholeWordIndex(sentence.toLowerCase(), wordLower);
    if (idx == -1) continue;

    final lineBounds = <Rect>[
      for (var i = 0; i < lines.length; i++)
        if (lineRanges[i].start < range.end && lineRanges[i].end > range.start)
          lines[i].bounds,
    ];

    return SentenceMatch(
      sentence: sentence,
      wordStart: idx,
      wordEnd: idx + word.length,
      lineBounds: lineBounds,
    );
  }
  return null;
}

/// Finds the sentence inside [text] that contains [word] — the same
/// matching used by [findSentenceForWord], but for plain text that isn't
/// tied to PDF page geometry (e.g. reflowed paragraphs).
SentenceMatch? findSentenceInText(String text, String word) {
  final wordLower = word.toLowerCase();
  for (final range in _splitSentenceRanges(text)) {
    final sentence = text.substring(range.start, range.end).trim();
    final idx = _findWholeWordIndex(sentence.toLowerCase(), wordLower);
    if (idx != -1) {
      return SentenceMatch(
        sentence: sentence,
        wordStart: idx,
        wordEnd: idx + word.length,
        lineBounds: const [],
      );
    }
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

/// Naive sentence splitter: breaks after '.', '!' or '?' when followed by
/// whitespace or end of text, returning raw (untrimmed) [start, end)
/// offsets into [text] so callers can map a sentence back to the page
/// geometry it came from. Good enough for a reading aid, not meant to be
/// linguistically perfect.
List<({int start, int end})> _splitSentenceRanges(String text) {
  final ranges = <({int start, int end})>[];
  var sentenceStart = 0;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '.' || ch == '!' || ch == '?') {
      final rest = i + 1 < text.length ? text.substring(i + 1) : '';
      if (rest.isEmpty || rest.startsWith(' ') || rest.startsWith('\n')) {
        ranges.add((start: sentenceStart, end: i + 1));
        sentenceStart = i + 1;
      }
    }
  }
  if (sentenceStart < text.length) {
    ranges.add((start: sentenceStart, end: text.length));
  }
  return ranges;
}
