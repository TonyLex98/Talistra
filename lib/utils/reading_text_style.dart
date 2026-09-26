import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// The face preformatted text is set in: a code block's indentation and a
/// table's columns only line up when every character is as wide as the next,
/// which no proportional reading font is. The platform's own monospace is
/// used rather than a bundled family, because none of the reading faces the
/// app ships is monospaced and a code panel is the one place where that
/// shows.
const String codeFontFamily = 'monospace';

/// Builds the text style reflowed reading text is set in, from the reader's
/// own typography settings: family, weight (driven through the bundled
/// variable fonts' weight axis) and ink contrast against the page.
///
/// One place for all of it, so the compact view, the plain-text view and
/// the settings preview can't drift apart — the preview has to show exactly
/// what reading will look like, or it isn't worth having.
TextStyle readingTextStyle({
  required SettingsService settings,
  required double fontSize,
  double sizeFactor = 1.0,
  double heightFactor = 1.0,
  bool bold = false,
}) {
  final font = settings.readingFont;
  final weight = bold
      ? (settings.readingWeight + 250).clamp(300, 900)
      : settings.readingWeight;
  return TextStyle(
    // Reading text specifies its own typography down to the last detail,
    // because a Material widget above a reader installs Material's UI text
    // style as the default, and a span inherits whatever it does not set
    // itself. That tracking is meant for 14px interface labels: it adds a
    // quarter point per character, so text comes out wider than the
    // measurements that paginated it and sized its columns — lines overflow
    // and cells truncate the very text that set their width.
    inherit: false,
    letterSpacing: 0,
    fontFamily: font.family,
    fontSize: fontSize * sizeFactor,
    height: 1.55 * heightFactor,
    color: settings.readingTheme.inkAt(settings.readingContrast),
    fontWeight: _nearestWeight(weight),
    // A variable font takes the exact weight through its axis; a static
    // family can only pick from the weights it ships, which fontWeight
    // above already handles.
    fontVariations: font.hasVariableWeight
        ? [FontVariation('wght', weight.toDouble())]
        : null,
  );
}

FontWeight _nearestWeight(int weight) {
  final index = ((weight / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}

/// [base] set in the reader's own bold weight.
///
/// Text the *source* emphasises — `**like this**` in a Markdown file, a bold
/// run in a PDF — goes through this rather than a hardcoded weight 700, so it
/// is exactly as heavy as the reader's typography setting asks for, and a
/// variable font still takes the exact weight through its axis.
TextStyle emphasisedReadingStyle(TextStyle base, SettingsService settings) {
  final weight = (settings.readingWeight + 250).clamp(300, 900);
  return base.copyWith(
    fontWeight: _nearestWeight(weight),
    fontVariations: settings.readingFont.hasVariableWeight
        ? [FontVariation('wght', weight.toDouble())]
        : base.fontVariations,
  );
}

final RegExp _readingWordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// One run of reading text: where it starts in the string, where it stops, and
/// whether it is a word rather than the punctuation and spaces between words.
typedef ReadingRun = ({int start, int end, bool word});

/// The runs [text] is shaped in: every word on its own, with the gaps between
/// them in runs of their own too.
///
/// [TranslatableText] needs the split so a tap can name the word under the
/// finger. Anything that measures how wide a line of reading text comes out
/// has to measure the same runs, because text shaped run by run is wider than
/// the same text shaped whole — kerning does not carry across a run boundary.
List<ReadingRun> readingTextRuns(String text) {
  final runs = <ReadingRun>[];
  var last = 0;
  for (final match in _readingWordPattern.allMatches(text)) {
    if (match.start > last) {
      runs.add((start: last, end: match.start, word: false));
    }
    runs.add((start: match.start, end: match.end, word: true));
    last = match.end;
  }
  if (last < text.length) {
    runs.add((start: last, end: text.length, word: false));
  }
  return runs;
}
