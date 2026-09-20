import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/reading_text_style.dart';
import '../utils/reflow_builder.dart';
import '../utils/reflow_paginator.dart';
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
  Size _paginationSize = Size.zero;
  double _paginationFontSize = 0;
  List<_TextSubPage> _subPages = const [];
  bool _initialPositionApplied = false;

  // The search hit the reader is looking at, in source-page / block /
  // [start, end) coordinates. Only the sub-page that actually holds the block
  // is told to wash its accent over that range.
  int _hlSourcePage = -1;
  int? _hlBlockIndex;
  int? _hlStart;
  int? _hlEnd;

  // Every other match that also falls on [_hlSourcePage] — washed over
  // fainter than the current hit, on whichever sub-page each one lands on.
  List<({int blockIndex, int start, int end})> _hlOthers = const [];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialPage - 1);
  }

  void jumpToPage(int page) {
    final index = _subPages.indexWhere((item) => item.sourcePage == page - 1);
    if (index >= 0) _pageController.jumpToPage(index);
  }

  /// Highlights a search hit: jumps to the sub-page that shows [matchStart]
  /// of [blockIndex] on [page] (1-based) and marks the [matchStart, matchEnd)
  /// range of its text.
  void showSearchHighlight(
    int page,
    int blockIndex,
    int matchStart,
    int matchEnd, {
    List<({int blockIndex, int start, int end})> others = const [],
  }) {
    setState(() {
      _hlSourcePage = page - 1;
      _hlBlockIndex = blockIndex;
      _hlStart = matchStart;
      _hlEnd = matchEnd;
      _hlOthers = others;
    });
    _jumpToHighlight();
  }

  void clearSearchHighlight() {
    setState(() {
      _hlSourcePage = -1;
      _hlBlockIndex = null;
      _hlStart = null;
      _hlEnd = null;
      _hlOthers = const [];
    });
  }

  void _jumpToHighlight() {
    if (_hlSourcePage < 0 || _subPages.isEmpty) return;
    final index = _highlightSubPageIndex();
    if (index >= 0) _pageController.jumpToPage(index);
  }

  int _highlightSubPageIndex() {
    for (var i = 0; i < _subPages.length; i++) {
      if (_subPages[i].sourcePage != _hlSourcePage) continue;
      for (final slice in _subPages[i].slices) {
        if (slice.blockIndex != _hlBlockIndex) continue;
        if (slice.start == slice.end) return i;
        if (_hlStart! >= slice.start && _hlStart! < slice.end) return i;
      }
    }
    return _subPages.indexWhere((p) => p.sourcePage == _hlSourcePage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.readingTheme.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _paginateIfNeeded(constraints.biggest, context);
          if (_subPages.isEmpty) return const SizedBox.shrink();
          if (!_initialPositionApplied) {
            _initialPositionApplied = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final index = _subPages.indexWhere(
                (item) => item.sourcePage == widget.initialPage - 1,
              );
              if (index >= 0) _pageController.jumpToPage(index);
            });
          }
          return PageView.builder(
            controller: _pageController,
            itemCount: _subPages.length,
            onPageChanged: (index) =>
                widget.onPageChanged(_subPages[index].sourcePage + 1),
            itemBuilder: (context, index) {
              final page = _subPages[index];
              final isHl =
                  index == _highlightSubPageIndex() && _hlBlockIndex != null;
              return _TxtPage(
                key: ValueKey(index),
                blocks: page.blocks,
                slices: page.slices,
                source: widget.source,
                target: widget.target,
                translationService: widget.translationService,
                fontSize: widget.fontSize,
                readingTheme: widget.readingTheme,
                settings: widget.settings,
                translatorEnabled: widget.translatorEnabled,
                highlight: isHl
                    ? (block: _hlBlockIndex, start: _hlStart, end: _hlEnd)
                    : null,
                otherHighlights: page.sourcePage == _hlSourcePage
                    ? _hlOthers
                    : const [],
              );
            },
          );
        },
      ),
    );
  }

  void _paginateIfNeeded(Size size, BuildContext context) {
    if (size == _paginationSize && widget.fontSize == _paginationFontSize) {
      return;
    }
    _paginationSize = size;
    _paginationFontSize = widget.fontSize;
    final available = size.width - 40;
    final width = math.min(available, widget.fontSize * 38);
    final height = size.height - 54;
    final pages = <_TextSubPage>[];
    for (var sourcePage = 0; sourcePage < widget.pages.length; sourcePage++) {
      final blocks = widget.pages[sourcePage];
      final slices = paginateReflowBlocks(
        blocks: blocks,
        width: width,
        height: height,
        fontSize: widget.fontSize,
        styleFor: (_) => DefaultTextStyle.of(context).style.merge(
          readingTextStyle(
            settings: widget.settings,
            fontSize: widget.fontSize,
          ),
        ),
        blockSpacing: 16,
        imageSpacing: 16,
        textScaler: MediaQuery.textScalerOf(context),
        // The renderer gives every slice a fixed 16px bottom margin (see the
        // per-slice Padding below), plus a little more that scales with font
        // size: each wrapped line's real painted height drifts from the
        // paginator's per-line measurement by a sub-pixel amount, and a
        // paragraph with enough wrapped lines can accumulate that into
        // several visible pixels — more of a problem the bigger the font
        // (and so the fewer characters, the more lines, per paragraph).
        trailingSpacing: 16 + widget.fontSize,
      );
      for (final slicePage in slices) {
        pages.add(
          _TextSubPage(
            sourcePage: sourcePage,
            blocks: blocks,
            slices: slicePage,
          ),
        );
      }
    }
    _subPages = pages;
  }
}

class _TextSubPage {
  const _TextSubPage({
    required this.sourcePage,
    required this.blocks,
    required this.slices,
  });
  final int sourcePage;
  final List<ReflowBlock> blocks;
  final List<ReflowSlice> slices;
}

class _TxtPage extends StatefulWidget {
  const _TxtPage({
    super.key,
    required this.blocks,
    required this.slices,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.settings,
    required this.translatorEnabled,
    this.highlight,
    this.otherHighlights = const [],
  });

  final List<ReflowBlock> blocks;
  final List<ReflowSlice> slices;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final SettingsService settings;
  final bool translatorEnabled;

  /// Which block's [start, end) range of text this sub-page should wash over
  /// with the search accent, or null if this sub-page holds no match.
  final ({int? block, int? start, int? end})? highlight;

  /// This sub-page's other matches (same source page, different block or
  /// range from [highlight]) — washed over fainter than the current one.
  final List<({int blockIndex, int start, int end})> otherHighlights;

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

  Widget _buildParagraph(int blockIndex, ReflowBlock block, ReflowSlice slice) {
    final text = block.text;
    final baseStyle = readingTextStyle(
      settings: widget.settings,
      fontSize: widget.fontSize,
    );
    final hl = widget.highlight;
    final hotStart = hl?.start;
    final hotEnd = hl?.end;
    final otherRanges = widget.otherHighlights
        .where((o) => o.blockIndex == blockIndex)
        .toList();

    TextStyle styleAt({
      required bool selected,
      bool hot = false,
      bool otherHot = false,
    }) {
      if (selected) {
        return baseStyle.copyWith(
          fontWeight: FontWeight.w700,
          color: widget.readingTheme.accent,
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.16),
        );
      }
      if (hot) {
        return baseStyle.copyWith(
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.32),
        );
      }
      if (otherHot) {
        return baseStyle.copyWith(
          backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.14),
        );
      }
      return baseStyle;
    }

    bool isHot(int start, int end) {
      if (hotStart == null || hotEnd == null || hl == null) return false;
      if (hl.block != blockIndex) return false;
      return start < hotEnd && end > hotStart;
    }

    bool isOtherHot(int start, int end) {
      for (final o in otherRanges) {
        if (start < o.end && end > o.start) return true;
      }
      return false;
    }

    final spans = <InlineSpan>[];
    var last = slice.start;
    for (final match in _wordPattern.allMatches(
      text.substring(slice.start, slice.end),
    )) {
      final start = slice.start + match.start;
      final end = slice.start + match.end;
      if (start > last) {
        spans.add(
          TextSpan(
            text: text.substring(last, start),
            style: styleAt(
              selected: false,
              hot: isHot(last, start),
              otherHot: isOtherHot(last, start),
            ),
          ),
        );
      }
      final word = match.group(0)!;
      final isSelected =
          blockIndex == _selectedBlockIndex &&
          start == _selectedWordStart &&
          end == _selectedWordEnd;
      spans.add(
        TextSpan(
          text: word,
          style: styleAt(
            selected: isSelected,
            hot: isHot(start, end),
            otherHot: isOtherHot(start, end),
          ),
          recognizer: widget.translatorEnabled
              ? (TapGestureRecognizer()
                  ..onTap = () => _onWordTap(blockIndex, start, end, word))
              : null,
        ),
      );
      last = end;
    }
    if (last < slice.end) {
      spans.add(
        TextSpan(
          text: text.substring(last, slice.end),
          style: styleAt(
            selected: false,
            hot: isHot(last, slice.end),
            otherHot: isOtherHot(last, slice.end),
          ),
        ),
      );
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
            return Padding(
              padding: EdgeInsets.fromLTRB(sideMargin, 18, sideMargin, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.slices.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: 16,
                        top: i == 0 || !widget.slices[i].isFirstOfBlock
                            ? 0
                            : 16,
                      ),
                      child: _buildParagraph(
                        widget.slices[i].blockIndex,
                        widget.blocks[widget.slices[i].blockIndex],
                        widget.slices[i],
                      ),
                    ),
                ],
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
                key: ValueKey(
                  '$_selectedWord-${widget.source}-${widget.target}',
                ),
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
