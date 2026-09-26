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
    const boldBit = 1, italicBit = 2, codeBit = 4, strikeBit = 8, linkBit = 16;
    final emphasis = List<int>.filled(stop - start, 0);
    for (final run in formatRuns) {
      if (run.end <= start || run.start >= stop) continue;
      final from = (run.start < start ? start : run.start) - start;
      final to = (run.end > stop ? stop : run.end) - start;
      final bits =
          (run.bold ? boldBit : 0) |
          (run.italic ? italicBit : 0) |
          (run.code ? codeBit : 0) |
          (run.strike ? strikeBit : 0) |
          (run.link ? linkBit : 0);
      for (var i = from; i < to; i++) {
        emphasis[i] |= bits;
      }
    }

    // One style per distinct combination of emphases, and one per
    // combination the selection and the search hits then put on top of it.
    final styles = <int, TextStyle>{};
    TextStyle emphasised(int bits) {
      if (bits == 0) return baseStyle;
      return styles.putIfAbsent(bits, () {
        var style = baseStyle;
        if (bits & boldBit != 0) {
          style = emphasisedReadingStyle(style, settings);
        }
        if (bits & italicBit != 0) {
          style = style.copyWith(fontStyle: FontStyle.italic);
        }
        if (bits & codeBit != 0) {
          // A faint accent wash rather than a box: the span sits inside a
          // line of running text, and a panel would push that line apart.
          style = style.copyWith(
            fontFamily: codeFontFamily,
            backgroundColor: readingTheme.accent.withValues(alpha: 0.12),
          );
        }
        if (bits & strikeBit != 0) {
          style = style.copyWith(
            decoration: TextDecoration.combine([
              TextDecoration.lineThrough,
              style.decoration ?? TextDecoration.none,
            ]),
          );
        }
        if (bits & linkBit != 0) {
          style = style.copyWith(
            color: readingTheme.accent,
            decoration: TextDecoration.combine([
              TextDecoration.underline,
              style.decoration ?? TextDecoration.none,
            ]),
          );
        }
        return style;
      });
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
          return style.copyWith(
            fontWeight: FontWeight.w700,
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
      spans.add(
        TextSpan(
          text: text.substring(from, to),
          style: styleAt(
            selected:
                run.word &&
                run.start == selectedStart &&
                run.end == selectedEnd,
            hot: overlaps(hot, from, to),
            otherHot: others.any((o) => overlaps(o, from, to)),
            from: from,
            to: to,
          ),
          recognizer: !run.word || !translatorEnabled
              ? null
              : (TapGestureRecognizer()
                  ..onTap = () =>
                      onWordTap(from, to, text.substring(from, to))),
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow:
          overflow ??
          (maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis),
    );
  }
}
