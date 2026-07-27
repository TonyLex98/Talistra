import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import 'translation_panel.dart';

/// Plain-text counterpart to [ReflowPdfView] (see reflow_view.dart) — same
/// tap-to-translate word/sentence selection and reading-theme styling, but
/// over synthetic pages of plain paragraphs instead of PDF-derived blocks,
/// and without any of the PDF-only features (embedded images, the
/// experimental split-screen sync-translation pane).
class TxtPageView extends StatefulWidget {
  const TxtPageView({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    required this.onPageChanged,
  });

  final List<List<ReflowBlock>> pages;
  final int initialPage;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;
  final ValueChanged<int> onPageChanged;

  @override
  State<TxtPageView> createState() => TxtPageViewState();
}

/// Public so the reader screen can jump this view to a specific page (via
/// a [GlobalKey]) from its own "Go to page" dialog.
class TxtPageViewState extends State<TxtPageView> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialPage - 1);
  }

  void jumpToPage(int page) => _pageController.jumpToPage(page - 1);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.readingTheme.background,
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.pages.length,
        onPageChanged: (index) => widget.onPageChanged(index + 1),
        itemBuilder: (context, index) => _TxtPage(
          key: ValueKey(index),
          blocks: widget.pages[index],
          source: widget.source,
          target: widget.target,
          translationService: widget.translationService,
          fontSize: widget.fontSize,
          readingTheme: widget.readingTheme,
          settings: widget.settings,
          translatorEnabled: widget.translatorEnabled,
        ),
      ),
    );
  }
}

class _TxtPage extends StatefulWidget {
  const _TxtPage({
    super.key,
    required this.blocks,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
  });

  final List<ReflowBlock> blocks;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;

  @override
  State<_TxtPage> createState() => _TxtPageState();
}

class _TxtPageState extends State<_TxtPage> {
  int? _selectedBlockIndex;
  int? _selectedWordStart;
  int? _selectedWordEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  void _onWordTap(int blockIndex, int wordStart, int wordEnd, String word) {
    if (!widget.translatorEnabled) return;
    final sentence = findSentenceInText(widget.blocks[blockIndex].text, word);
    setState(() {
      _selectedBlockIndex = blockIndex;
      _selectedWordStart = wordStart;
      _selectedWordEnd = wordEnd;
      _selectedWord = word;
      _selectedSentence = sentence;
    });
  }

  void _clear() {
    setState(() {
      _selectedBlockIndex = null;
      _selectedWordStart = null;
      _selectedWordEnd = null;
      _selectedWord = null;
      _selectedSentence = null;
    });
  }

  static final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  Widget _buildParagraph(int blockIndex, ReflowBlock block) {
    final text = block.text;
    final baseStyle = readingTextStyle(
      settings: widget.settings,
      fontSize: widget.fontSize,
    );

    TextStyle styleAt({required bool selected}) {
      if (!selected) return baseStyle;
      return baseStyle.copyWith(
        fontWeight: FontWeight.w700,
        color: widget.readingTheme.accent,
        backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.16),
      );
    }

    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _wordPattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start), style: baseStyle));
      }
      final word = match.group(0)!;
      final isSelected = blockIndex == _selectedBlockIndex &&
          match.start == _selectedWordStart &&
          match.end == _selectedWordEnd;
      spans.add(
        TextSpan(
          text: word,
          style: styleAt(selected: isSelected),
          recognizer: widget.translatorEnabled
              ? (TapGestureRecognizer()..onTap = () => _onWordTap(blockIndex, match.start, match.end, word))
              : null,
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    return Text.rich(TextSpan(children: spans));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // A line of text stops being comfortable much past 40em, so on a
            // sideways phone or a tablet the column is capped and centred
            // instead of stretching the full width of the screen.
            final available = constraints.maxWidth - 40;
            final columnWidth = math.min(available, widget.fontSize * 38);
            final sideMargin = 20 + (available - columnWidth) / 2;
            return ListView.builder(
              padding: EdgeInsets.fromLTRB(sideMargin, 18, sideMargin, 140),
              itemCount: widget.blocks.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _buildParagraph(index, widget.blocks[index]),
              ),
            );
          },
        ),
        if (_selectedWord != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: TranslationPanel(
                key: ValueKey('$_selectedWord-${widget.source}-${widget.target}'),
                word: _selectedWord!,
                sentenceMatch: _selectedSentence,
                source: widget.source,
                target: widget.target,
                translationService: widget.translationService,
                onClose: _clear,
              ),
            ),
          ),
      ],
    );
  }
}
