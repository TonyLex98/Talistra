import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/pdf_region_renderer.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import 'translation_panel.dart';

/// Phone-friendly reading view: each PDF page becomes one reflow page —
/// same page count and position as the original, so switching between
/// views keeps your place — with paragraphs wrapped for the screen width
/// and images/diagrams/tables rendered as real, pinch-zoomable pictures
/// rather than placeholders.
class ReflowPdfView extends StatefulWidget {
  const ReflowPdfView({
    super.key,
    required this.filePath,
    required this.document,
    required this.pageCount,
    required this.initialPage,
    required this.linesCache,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
    required this.onPageChanged,
  });

  final String filePath;
  final PdfDocument document;
  final int pageCount;
  final int initialPage;
  final Map<int, List<TextLine>> linesCache;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;
  final ValueChanged<int> onPageChanged;

  @override
  State<ReflowPdfView> createState() => ReflowPdfViewState();
}

/// Public so [ReaderScreen] can jump this view to a specific page (via a
/// [GlobalKey]) from its own "Go to page" dialog, the same way it drives
/// the PDF viewer's controller.
class ReflowPdfViewState extends State<ReflowPdfView> {
  late final PageController _pageController;
  PdfRegionRenderer? _renderer;
  final Map<String, Future<Uint8List?>> _imageCache = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialPage - 1);
    _openRenderer();
  }

  void jumpToPage(int page) {
    _pageController.jumpToPage(page - 1);
  }

  Future<void> _openRenderer() async {
    final renderer = await PdfRegionRenderer.open(widget.filePath);
    if (!mounted) {
      renderer.close();
      return;
    }
    setState(() => _renderer = renderer);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _renderer?.close();
    super.dispose();
  }

  Future<Uint8List?> _imageFor(int pageIndex, int blockIndex, Rect bounds) {
    final key = '$pageIndex-$blockIndex';
    return _imageCache.putIfAbsent(
      key,
      () => _renderer!.renderRegion(pageIndex: pageIndex, pdfBounds: bounds),
    );
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    // The reading surface defaults to (and usually stays) plain white,
    // independent of the app's own light/dark theme — see [ReadingTheme].
    return ColoredBox(
      color: widget.readingTheme.background,
      child: renderer == null
          ? const Center(child: CircularProgressIndicator())
          : PageView.builder(
              controller: _pageController,
              itemCount: widget.pageCount,
              onPageChanged: (index) => widget.onPageChanged(index + 1),
              itemBuilder: (context, index) {
                return _ReflowPage(
                  key: ValueKey(index),
                  pageIndex: index,
                  document: widget.document,
                  linesCache: widget.linesCache,
                  imageFor: _imageFor,
                  source: widget.source,
                  target: widget.target,
                  translationService: widget.translationService,
                  fontSize: widget.fontSize,
                  readingTheme: widget.readingTheme,
                );
              },
            ),
    );
  }
}

class _ReflowPage extends StatefulWidget {
  const _ReflowPage({
    super.key,
    required this.pageIndex,
    required this.document,
    required this.linesCache,
    required this.imageFor,
    required this.source,
    required this.target,
    required this.translationService,
    required this.fontSize,
    required this.readingTheme,
  });

  final int pageIndex;
  final PdfDocument document;
  final Map<int, List<TextLine>> linesCache;
  final Future<Uint8List?> Function(int pageIndex, int blockIndex, Rect bounds) imageFor;
  final TranslateLanguage source;
  final TranslateLanguage target;
  final TranslationService translationService;
  final double fontSize;
  final ReadingTheme readingTheme;

  @override
  State<_ReflowPage> createState() => _ReflowPageState();
}

class _ReflowPageState extends State<_ReflowPage> {
  late final List<ReflowBlock> _blocks;

  int? _selectedBlockIndex;
  int? _selectedWordStart;
  int? _selectedWordEnd;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  @override
  void initState() {
    super.initState();
    final lines = widget.linesCache.putIfAbsent(
      widget.pageIndex,
      () => extractPageLines(widget.document, widget.pageIndex),
    );
    final pageSize = widget.document.pages[widget.pageIndex].size;
    _blocks = buildReflowPageBlocks(lines, pageSize);
  }

  void _onWordTap(int blockIndex, int wordStart, int wordEnd, String word) {
    final sentence = findSentenceInText(_blocks[blockIndex].text, word);
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

  void _openFullscreenImage(Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 6,
              child: Image.memory(bytes),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_blocks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('На этой странице не нашлось текста для адаптации.'),
        ),
      );
    }
    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 140),
          itemCount: _blocks.length,
          itemBuilder: (context, index) {
            final block = _blocks[index];
            if (block.isImage) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: _buildImageBlock(index, block),
              );
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

  Widget _buildImageBlock(int blockIndex, ReflowBlock block) {
    return FutureBuilder<Uint8List?>(
      future: widget.imageFor(widget.pageIndex, blockIndex, block.imageBounds!),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => _openFullscreenImage(bytes),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        );
      },
    );
  }

  static final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  Widget _buildParagraph(BuildContext context, int blockIndex, String text) {
    final baseStyle = TextStyle(
      fontSize: widget.fontSize,
      height: 1.55,
      color: widget.readingTheme.onBackground,
    );
    final highlightStyle = baseStyle.copyWith(
      fontWeight: FontWeight.w700,
      color: widget.readingTheme.accent,
      backgroundColor: widget.readingTheme.accent.withValues(alpha: 0.16),
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
