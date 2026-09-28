import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';

/// A run of reading text with the interactions every reader shares over it:
/// a tap on a word selects it and asks for its translation, the search hit
/// the reader landed on is washed over with the reading accent, and the
/// other hits on the same page are washed over fainter.
///
/// The styling the document itself carries — bold, italic, inline code, a
/// struck-through phrase, a link — goes in through [formatRuns] and is drawn
/// underneath all of that, so an emphasised word still highlights when a
/// search lands on it and still reads as the selected word.
///
/// Every reader that shows text the reader can tap — plain text, reflowed
/// PDF, a spreadsheet cell — draws it through this widget, so selecting,
/// translating and highlighting behave identically in all of them instead of
/// drifting apart one copy of the span builder at a time.
class TranslatableText extends StatelessWidget {
  const TranslatableText({
    super.key,
    required this.text,
    required this.settings,
    required this.fontSize,
    required this.readingTheme,
    required this.translatorEnabled,
    required this.onWordTap,
    this.start = 0,
    this.end,
    this.bold = false,
    this.maxLines,
    this.overflow,
    this.selectedStart,
    this.selectedEnd,
    this.highlight,
    this.otherHighlights = const [],
    this.formatRuns = const [],
    this.style,
  });

  /// The whole string this text was drawn from. Only `start..<end>` of it is
  /// painted, so a paginated block can be shown in several pieces without
  /// copying its text.
  final String text;

  final int start;

  /// Where painting stops; the end of [text] when omitted.
  final int? end;

  /// Read straight through for font, weight and ink contrast — see
  /// [readingTextStyle].
  final SettingsService settings;

  final double fontSize;
  final ReadingTheme readingTheme;

  /// Master switch for the translation feature: when off, words are no
  /// longer tappable and nothing is reported to [onWordTap].
  final bool translatorEnabled;

  /// Called with the `[start, end)` offsets of the tapped word in [text].
  final void Function(int start, int end, String word) onWordTap;

  /// Header rows (a spreadsheet's first line, a PDF's heading) are set in
  /// the reader's own bold weight rather than a hardcoded one.
  final bool bold;

  /// Set for text that has to stay inside a fixed box — a spreadsheet cell,
  /// which is one line wide and ellipsises rather than wrapping.
  final int? maxLines;
  final TextOverflow? overflow;

  /// The currently selected word's offsets in [text], if any.
  final int? selectedStart;
  final int? selectedEnd;

  /// The search hit to wash over, as offsets into [text].
  final ({int start, int end})? highlight;

  /// This page's other matches, fainter than [highlight].
  final List<({int start, int end})> otherHighlights;

  /// How the document sets parts of [text] itself, as offsets into the whole
  /// of it (so into `text`, not into this slice of it).
  final List<FormatRun> formatRuns;

  /// The style to set the text in, in place of the reader's plain body style
  /// — a heading's, or a code panel's monospace face. Whatever it is, it has
  /// to be the very style the block was paginated with, or the lines come
  /// out taller than the page allowed for them.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final stop = (end ?? text.length).clamp(start, text.length);
    final baseStyle =
        style ??
        readingTextStyle(settings: settings, fontSize: fontSize, bold: bold);
    final hot = highlight;
    final others = otherHighlights;

    // Which of the document's own emphases cover each character of the part
    // being painted, worked out in one pass over the runs. Asking "does any
    // run touch this word?" word by word instead is what a Markdown page
    // with a hundred inline-code spans pays for — twice the time to turn a
    // page over the same text with no styling at all.
    final emphasis = _emphasisBits(text, formatRuns, start, stop);

    // One style per distinct combination of emphases, and one per
    // combination the selection and the search hits then put on top of it.
    final styles = <int, TextStyle>{};
    TextStyle emphasised(int bits) {
      if (bits == 0) return baseStyle;
      return styles.putIfAbsent(
        bits,
        () => _emphasisStyle(baseStyle, bits, settings, readingTheme),
      );
    }

    TextStyle styleAt({
      required bool selected,
      bool hot = false,
      bool otherHot = false,
      required int from,
      required int to,
    }) {
      var bits = 0;
      for (var i = from - start; i < to - start; i++) {
        bits |= emphasis[i];
      }
      final style = emphasised(bits);
      // Only the words the reader has actually touched — the selected one and
      // the search hits — need a variant of that style. Everything else is
      // done: asking for a variant of an emphasised word that nothing is
      // selected on washes it in the faintest hit's accent.
      if (!selected && !hot && !otherHot) return style;
      // The variants are keyed above the plain style: a page of prose has
      // one selected word and at most a couple of hits, so this costs a
      // handful of entries however many spans ask for them.
      final key =
          (bits << 3) | (selected ? 1 : 0) | (hot ? 2 : 0) | (otherHot ? 4 : 0);
      return styles.putIfAbsent(key + (1 << 30), () {
        if (selected) {
          // Colour and a wash only: anything that changed the word's width
          // (a heavier weight, above all) could wrap its line once more than
          // the paginator measured, and push the page's last line off it.
          return style.copyWith(
            color: readingTheme.accent,
            backgroundColor: readingTheme.accent.withValues(alpha: 0.16),
          );
        }
        if (hot) {
          return style.copyWith(
            backgroundColor: readingTheme.accent.withValues(alpha: 0.32),
          );
        }
        return style.copyWith(
          backgroundColor: readingTheme.accent.withValues(alpha: 0.14),
        );
      });
    }

    bool overlaps(({int start, int end})? range, int from, int to) =>
        range != null && from < range.end && to > range.start;

    final spans = <InlineSpan>[];
    for (final run in readingTextRuns(text)) {
      final from = run.start < start ? start : run.start;
      final to = run.end > stop ? stop : run.end;
      if (from >= to) continue;
      final selected =
          run.word && run.start == selectedStart && run.end == selectedEnd;
      // One recognizer for the whole word, however many pieces it is drawn
      // in.
      final recognizer = !run.word || !translatorEnabled
          ? null
          : (TapGestureRecognizer()
              ..onTap = () => onWordTap(from, to, text.substring(from, to)));
      // Cut where the document's own emphasis changes, so a style covers
      // exactly its characters. Taking one style for a whole run gave the
      // space and the bracket beside an inline `code` word the monospace
      // face too — whose fallback line is taller — and the line painted
      // taller than the paginator had measured it.
      var pieceStart = from;
      for (var i = from + 1; i <= to; i++) {
        if (i < to && emphasis[i - start] == emphasis[pieceStart - start]) {
          continue;
        }
        spans.add(
          TextSpan(
            text: text.substring(pieceStart, i),
            style: styleAt(
              selected: selected,
              hot: overlaps(hot, pieceStart, i),
              otherHot: others.any((o) => overlaps(o, pieceStart, i)),
              from: pieceStart,
              to: i,
            ),
            recognizer: recognizer,
          ),
        );
        pieceStart = i;
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      // The block's own style as the paragraph's, not the ambient one: a
      // paragraph takes the metrics of its root style into every line, and
      // the Material default (Roboto 14 at 1.43) under a 16 pt serif made
      // each line a pixel or two taller than the paginator measured.
      style: baseStyle,
      maxLines: maxLines,
      overflow:
          overflow ??
          (maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis),
    );
  }
}

const int _boldBit = 1;
const int _italicBit = 2;
const int _codeBit = 4;
const int _strikeBit = 8;
const int _linkBit = 16;

/// For each character of `[start, stop)` of [text], the emphasis it is set
/// in: the bits of every [FormatRun] over it — and, for a letter, of every
/// run over any part of its word, since a word is set in one face or
/// another, never half and half. The spaces and punctuation between words
/// keep exactly their own, so a code or bold word's face doesn't spill onto
/// the space beside it.
///
/// The one definition the painter and the paginator both use: they have to
/// agree character by character, or a line is measured in one face and
/// drawn in another.
List<int> _emphasisBits(
  String text,
  List<FormatRun> runs,
  int start,
  int stop,
) {
  final emphasis = List<int>.filled(stop - start, 0);
  if (runs.isEmpty) return emphasis;
  final own = List<int>.filled(text.length, 0);
  for (final run in runs) {
    final from = run.start.clamp(0, text.length);
    final to = run.end.clamp(0, text.length);
    final bits =
        (run.bold ? _boldBit : 0) |
        (run.italic ? _italicBit : 0) |
        (run.code ? _codeBit : 0) |
        (run.strike ? _strikeBit : 0) |
        (run.link ? _linkBit : 0);
    for (var i = from; i < to; i++) {
      own[i] |= bits;
    }
  }
  for (final word in readingTextRuns(text)) {
    if (!word.word || word.end <= start || word.start >= stop) continue;
    var bits = 0;
    for (var i = word.start; i < word.end; i++) {
      bits |= own[i];
    }
    for (var i = word.start; i < word.end; i++) {
      own[i] = bits;
    }
  }
  for (var i = start; i < stop; i++) {
    emphasis[i - start] = own[i];
  }
  return emphasis;
}

/// [base] with the document's own emphases in [bits] put on top of it.
TextStyle _emphasisStyle(
  TextStyle base,
  int bits,
  SettingsService settings,
  ReadingTheme readingTheme,
) {
  var style = base;
  if (bits & _boldBit != 0) {
    style = emphasisedReadingStyle(style, settings);
  }
  if (bits & _italicBit != 0) {
    style = style.copyWith(fontStyle: FontStyle.italic);
  }
  if (bits & _codeBit != 0) {
    // A faint accent wash rather than a box: the span sits inside a line of
    // running text, and a panel would push that line apart.
    style = style.copyWith(
      fontFamily: codeFontFamily,
      backgroundColor: readingTheme.accent.withValues(alpha: 0.12),
    );
  }
  if (bits & _strikeBit != 0) {
    style = style.copyWith(
      decoration: TextDecoration.combine([
        TextDecoration.lineThrough,
        style.decoration ?? TextDecoration.none,
      ]),
    );
  }
  if (bits & _linkBit != 0) {
    style = style.copyWith(
      color: readingTheme.accent,
      decoration: TextDecoration.combine([
        TextDecoration.underline,
        style.decoration ?? TextDecoration.none,
      ]),
    );
  }
  return style;
}

/// [text] as [TranslatableText] sets it — each run of the document's own
/// emphasis in the face and weight it is painted in — for measuring.
///
/// A paginator that measured the plain text would be measuring narrower
/// lines than the page shows: inline code is monospace and bold is heavier,
/// so a paragraph thick with either wraps into more lines than its plain text
/// does, and the page's last lines end up past its bottom edge.
InlineSpan readingTextSpan({
  required String text,
  required List<FormatRun> formatRuns,
  required TextStyle style,
  required SettingsService settings,
  required ReadingTheme readingTheme,
}) {
  if (formatRuns.isEmpty) return TextSpan(text: text, style: style);
  final emphasis = _emphasisBits(text, formatRuns, 0, text.length);
  final styles = <int, TextStyle>{};
  final spans = <TextSpan>[];
  var from = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i < text.length && emphasis[i] == emphasis[from]) continue;
    final bits = emphasis[from];
    spans.add(
      TextSpan(
        text: text.substring(from, i),
        style: bits == 0
            ? style
            : styles.putIfAbsent(
                bits,
                () => _emphasisStyle(style, bits, settings, readingTheme),
              ),
      ),
    );
    from = i;
  }
  return TextSpan(children: spans);
}
