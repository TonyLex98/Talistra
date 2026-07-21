import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../services/translation_service.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import 'translation_panel.dart';

/// Phone-friendly reading view: the PDF's text reflowed into wrapped,
/// readable paragraphs (images/tables are skipped with a marker — they
/// stay visible in the original PDF view). Tapping a word looks it up the
/// same way the PDF view does.
class ReflowView extends StatefulWidget {
  const ReflowView({
    super.key,
    required this.blocks,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
  });

  final List<ReflowBlock> blocks;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;

  @override
  State<ReflowView> createState() => _ReflowViewState();
}

class _ReflowViewState extends State<ReflowView> {
  int? _selectedBlockIndex;
  int? _selectedWordStart;
  int? _selectedWordEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  void _onWordTap(int blockIndex, int wordStart, int wordEnd, String word) {
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Word taps are handled per-span below (each word has its own
        // TapGestureRecognizer); a wrapping GestureDetector here would
        // compete with those in the same gesture arena and swallow taps,
        // so "empty space" simply does nothing rather than closing the
        // panel — use the panel's own close button for that instead.
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 140),
          itemCount: widget.blocks.length,
          itemBuilder: (context, index) {
            final block = widget.blocks[index];
            if (block.type == ReflowBlockType.imageGap) {
              return _buildImageGapMarker(context);
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _buildParagraph(context, index, block.text),
            );
          },
        ),
        if (_selectedWord != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
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
      ],
    );
  }

  Widget _buildImageGapMarker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 16, color: scheme.outline),
          const SizedBox(width: 6),
          Text(
            'изображение или таблица — смотрите в оригинале',
            style: TextStyle(color: scheme.outline, fontSize: 12),
          ),
        ],
      ),
    );
  }

  static final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  Widget _buildParagraph(BuildContext context, int blockIndex, String text) {
    final scheme = Theme.of(context).colorScheme;
    final baseStyle = TextStyle(
      fontSize: widget.fontSize,
      height: 1.55,
      color: scheme.onSurface,
    );
    final highlightStyle = baseStyle.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.primary,
      backgroundColor: scheme.primaryContainer.withValues(alpha: 0.5),
    );

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
          style: isSelected ? highlightStyle : baseStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () => _onWordTap(blockIndex, match.start, match.end, word),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    return Text.rich(TextSpan(children: spans));
  }
}
