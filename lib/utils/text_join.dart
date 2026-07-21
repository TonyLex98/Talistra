final _letterPattern = RegExp(r'\p{L}', unicode: true);
bool isLetter(String ch) => ch.isNotEmpty && _letterPattern.hasMatch(ch);

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
String joinLines(String previous, String next) {
  if (previous.isEmpty) return next;
  if (next.isEmpty) return previous;

  if (previous.endsWith('-') && previous.length >= 2) {
    final beforeHyphen = previous[previous.length - 2];
    final nextFirst = next[0];
    if (isLetter(beforeHyphen) && isLetter(nextFirst) && nextFirst == nextFirst.toLowerCase()) {
      return previous.substring(0, previous.length - 1) + next;
    }
  }
  return '$previous $next';
}

/// Whether [pos] sits strictly inside a run of letters in [text] (i.e.
/// the characters immediately before and after it are both letters) —
/// used to avoid truncating a sentence window mid-word.
bool isMidWord(String text, int pos) {
  if (pos <= 0 || pos >= text.length) return false;
  return isLetter(text[pos - 1]) && isLetter(text[pos]);
}
