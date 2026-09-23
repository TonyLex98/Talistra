import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../utils/reading_text_style.dart';

/// A run of reading text with the interactions every reader shares over it:
/// a tap on a word selects it and asks for its translation, the search hit
/// the reader landed on is washed over with the reading accent, and the
/// other hits on the same page are washed over fainter.
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

  @override
  Widget build(BuildContext context) {
    final stop = (end ?? text.length).clamp(start, text.length);
    final baseStyle = readingTextStyle(
      settings: settings,
      fontSize: fontSize,
      bold: bold,
    );
    final hot = highlight;
    final others = otherHighlights;

    TextStyle styleAt({
      required bool selected,
      bool hot = false,
      bool otherHot = false,
    }) {
      if (selected) {
        return baseStyle.copyWith(
          fontWeight: FontWeight.w700,
          color: readingTheme.accent,
          backgroundColor: readingTheme.accent.withValues(alpha: 0.16),
        );
      }
      if (hot) {
        return baseStyle.copyWith(
          backgroundColor: readingTheme.accent.withValues(alpha: 0.32),
        );
      }
      if (otherHot) {
        return baseStyle.copyWith(
          backgroundColor: readingTheme.accent.withValues(alpha: 0.14),
        );
      }
      return baseStyle;
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
                run.word && run.start == selectedStart && run.end == selectedEnd,
            hot: overlaps(hot, from, to),
            otherHot: others.any((o) => overlaps(o, from, to)),
          ),
          recognizer: !run.word || !translatorEnabled
              ? null
              : (TapGestureRecognizer()
                  ..onTap = () => onWordTap(from, to, text.substring(from, to))),
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
