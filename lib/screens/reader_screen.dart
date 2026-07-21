import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/reflow_view.dart';
import '../widgets/translation_panel.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _viewerKey = GlobalKey();
  late final PdfViewerController _controller;
  late LibraryDocument _document;

  PdfDocument? _pdfDocument;
  final Map<int, List<TextLine>> _pageLinesCache = {};
  List<double> _pageAspectRatios = const [];

  int _pageCount = 0;
  int _currentPage = 1;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  Rect? _tapHighlightRect;
  List<Rect> _sentenceHighlightRects = const [];

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  bool _reflowMode = false;
  bool _reflowLoading = false;
  List<ReflowBlock>? _reflowBlocks;
  double _reflowFontSize = 17;

  @override
  void initState() {
    super.initState();
    _controller = PdfViewerController();
    _document = context
        .read<LibraryService>()
        .documents
        .firstWhere((d) => d.id == widget.documentId);
    _currentPage = _document.lastPage;
    _pageCount = _document.pageCount;
  }

  void _onDocumentLoaded(PdfDocumentLoadedDetails details) {
    final pageCount = details.document.pages.count;
    _pdfDocument = details.document;
    _pageAspectRatios = List.generate(pageCount, (i) {
      final size = details.document.pages[i].size;
      return size.width == 0 ? 1.4 : size.height / size.width;
    });
    setState(() => _pageCount = pageCount);
    if (_document.lastPage > 1 && _document.lastPage <= pageCount) {
      _controller.jumpToPage(_document.lastPage);
    }
    // Record that the document was opened even if the user never changes
    // pages (e.g. single-page PDFs, or leaving before scrolling).
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage.clamp(1, pageCount),
      pageCount: pageCount,
    );
  }

  void _onDocumentLoadFailed(PdfDocumentLoadFailedDetails details) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось открыть PDF: ${details.description}')),
    );
  }

  void _onPageChanged(PdfPageChangedDetails details) {
    setState(() {
      _currentPage = details.newPageNumber;
      _selectedWord = null;
      _selectedSentence = null;
      _tapHighlightRect = null;
      _sentenceHighlightRects = const [];
    });
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: details.newPageNumber,
      pageCount: _pageCount,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
  }

  /// [Listener] callbacks observe raw pointer events and don't compete in
  /// the gesture arena, so this fires reliably alongside SfPdfViewer's own
  /// pan/zoom recognizers (a wrapping GestureDetector's tap recognizer
  /// loses that arena to the viewer's internal recognizers and never
  /// fires). A "tap" here is just: little movement, released quickly.
  void _onPointerUp(PointerUpEvent event) {
    final downPosition = _pointerDownPosition;
    final downTime = _pointerDownTime;
    if (downPosition == null || downTime == null) return;
    final movedDistance = (event.position - downPosition).distance;
    final elapsed = DateTime.now().difference(downTime);
    if (movedDistance <= 14 && elapsed <= const Duration(milliseconds: 400)) {
      _handleTap(event.position);
    }
  }

  /// Maps a single tap to the word under it, using the page layout math
  /// Syncfusion itself uses (pages fit to viewport width, stacked with
  /// [pageSpacing], then the whole content is scrolled/zoomed) so we can
  /// hit-test against the PDF's own text geometry without any private API.
  void _handleTap(Offset globalPosition) {
    final document = _pdfDocument;
    final box = _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    if (document == null || box == null || _pageAspectRatios.isEmpty) {
      _clearSelection();
      return;
    }

    final local = box.globalToLocal(globalPosition);
    final viewportWidth = box.size.width;
    final zoom = _controller.zoomLevel == 0 ? 1.0 : _controller.zoomLevel;
    final scrollOffset = _controller.scrollOffset;

    final contentX = local.dx / zoom + scrollOffset.dx;
    final contentY = local.dy / zoom + scrollOffset.dy;

    const pageSpacing = 4.0;
    var cumulative = 0.0;
    int? pageIndex;
    var pageLocalY = 0.0;
    for (var i = 0; i < _pageAspectRatios.length; i++) {
      final pageHeight = viewportWidth * _pageAspectRatios[i];
      if (contentY < cumulative + pageHeight) {
        pageIndex = i;
        pageLocalY = contentY - cumulative;
        break;
      }
      cumulative += pageHeight + pageSpacing;
    }
    if (pageIndex == null || contentX < 0 || contentX > viewportWidth) {
      _clearSelection();
      return;
    }

    final pageSize = document.pages[pageIndex].size;
    if (pageSize.width == 0) {
      _clearSelection();
      return;
    }
    final scale = viewportWidth / pageSize.width;
    final pdfPoint = Offset(contentX / scale, pageLocalY / scale);

    List<TextLine> lines;
    try {
      lines = _pageLinesCache.putIfAbsent(
        pageIndex,
        () => extractPageLines(document, pageIndex!),
      );
    } catch (_) {
      _clearSelection();
      return;
    }

    final hit = hitTestWord(lines, pdfPoint);
    if (hit == null) {
      _clearSelection();
      return;
    }

    final sentence = findSentenceForWord(
      document: document,
      pageIndex: pageIndex,
      word: hit.text,
      cachedLines: lines,
    );

    // Convert PDF-space bounds back to screen space to flash highlights
    // where the user tapped: a strong one on the word, a fainter one over
    // the whole sentence it belongs to.
    Rect toScreenRect(Rect pdfBounds) {
      final left = (pdfBounds.left * scale - scrollOffset.dx) * zoom;
      final top = ((cumulative + pdfBounds.top * scale) - scrollOffset.dy) * zoom;
      return Rect.fromLTWH(
        left,
        top,
        pdfBounds.width * scale * zoom,
        pdfBounds.height * scale * zoom,
      );
    }

    setState(() {
      _selectedWord = hit.text;
      _selectedSentence = sentence;
      _tapHighlightRect = toScreenRect(hit.bounds);
      _sentenceHighlightRects = sentence == null
          ? const []
          : [for (final b in sentence.lineBounds) toScreenRect(b)];
    });
  }

  void _clearSelection() {
    if (_selectedWord == null) return;
    setState(() {
      _selectedWord = null;
      _selectedSentence = null;
      _tapHighlightRect = null;
      _sentenceHighlightRects = const [];
    });
  }

  Future<void> _jumpToPage() async {
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Перейти на страницу'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: '1 – $_pageCount'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)),
            child: const Text('Перейти'),
          ),
        ],
      ),
    );
    if (target != null && target >= 1 && target <= _pageCount) {
      _controller.jumpToPage(target);
    }
  }

  Future<void> _toggleReflow() async {
    if (_reflowMode) {
      setState(() => _reflowMode = false);
      return;
    }
    _clearSelection();
    if (_reflowBlocks != null) {
      setState(() => _reflowMode = true);
      return;
    }
    final document = _pdfDocument;
    if (document == null) return;
    setState(() {
      _reflowLoading = true;
      _reflowMode = true;
    });
    // Yield a frame so the loading spinner actually paints before the
    // synchronous extraction work blocks the UI thread.
    await Future.delayed(Duration.zero);
    List<ReflowBlock> blocks;
    try {
      blocks = buildReflowBlocks(document);
    } catch (_) {
      blocks = const [];
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось подготовить адаптированный вид')),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _reflowBlocks = blocks;
      _reflowLoading = false;
    });
  }

  Future<void> _quickLanguageSwitch() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Язык перевода', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Consumer<SettingsService>(
                  builder: (context, settings, _) => Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(settings.sourceAppLanguage.flag, style: const TextStyle(fontSize: 22)),
                        title: const Text('С какого языка'),
                        subtitle: Text(settings.sourceAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.sourceLanguage,
                            title: 'С какого языка переводить',
                          );
                          if (picked != null) settings.setSourceLanguage(picked);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_vert),
                        tooltip: 'Поменять местами',
                        onPressed: settings.swapLanguages,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(settings.targetAppLanguage.flag, style: const TextStyle(fontSize: 22)),
                        title: const Text('На какой язык'),
                        subtitle: Text(settings.targetAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.targetLanguage,
                            title: 'На какой язык переводить',
                          );
                          if (picked != null) settings.setTargetLanguage(picked);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(_clearSelection);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final translationService = context.read<TranslationService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_document.title, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            onPressed: _quickLanguageSwitch,
            icon: const Icon(Icons.translate, size: 18),
            label: Text(
              '${settings.sourceAppLanguage.flag} → ${settings.targetAppLanguage.flag}',
            ),
          ),
          if (_reflowMode) ...[
            IconButton(
              icon: const Icon(Icons.text_decrease, size: 20),
              tooltip: 'Меньше текст',
              onPressed: () => setState(
                () => _reflowFontSize = (_reflowFontSize - 1).clamp(13, 26),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.text_increase, size: 20),
              tooltip: 'Крупнее текст',
              onPressed: () => setState(
                () => _reflowFontSize = (_reflowFontSize + 1).clamp(13, 26),
              ),
            ),
          ] else
            TextButton(
              onPressed: _pageCount == 0 ? null : _jumpToPage,
              child: Text(_pageCount == 0 ? '' : '$_currentPage / $_pageCount'),
            ),
          IconButton(
            icon: Icon(_reflowMode ? Icons.picture_as_pdf_outlined : Icons.auto_stories_outlined),
            tooltip: _reflowMode ? 'Оригинал PDF' : 'Адаптировать под телефон',
            onPressed: _pageCount == 0 ? null : _toggleReflow,
          ),
        ],
      ),
      body: _reflowMode
          ? _buildReflowBody(translationService, settings)
          : _buildPdfBody(settings, translationService),
    );
  }

  Widget _buildReflowBody(TranslationService translationService, SettingsService settings) {
    if (_reflowLoading || _reflowBlocks == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Готовим адаптированный вид...'),
          ],
        ),
      );
    }
    if (_reflowBlocks!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('В этом документе не нашлось текста для адаптации.'),
        ),
      );
    }
    return ReflowView(
      blocks: _reflowBlocks!,
      source: settings.sourceLanguage,
      target: settings.targetLanguage,
      translationService: translationService,
      fontSize: _reflowFontSize,
    );
  }

  Widget _buildPdfBody(SettingsService settings, TranslationService translationService) {
    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          child: SfPdfViewer.file(
            File(_document.filePath),
            key: _viewerKey,
            controller: _controller,
            enableTextSelection: false,
            interactionMode: PdfInteractionMode.pan,
            onDocumentLoaded: _onDocumentLoaded,
            onDocumentLoadFailed: _onDocumentLoadFailed,
            onPageChanged: _onPageChanged,
          ),
        ),
        // The sentence gets a faint, steady tint on every line it spans;
        // the tapped word sits on top with a stronger tint. Both stay
        // visible for as long as the translation panel is open, so the
        // reader can see exactly what's being translated.
        if (_selectedWord != null) ...[
          for (final rect in _sentenceHighlightRects)
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          if (_tapHighlightRect != null)
            Positioned.fromRect(
              rect: _tapHighlightRect!,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
        ],
        if (_selectedWord != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: TranslationPanel(
              key: ValueKey(
                '$_selectedWord-${settings.sourceLanguage}-${settings.targetLanguage}',
              ),
              word: _selectedWord!,
              sentenceMatch: _selectedSentence,
              source: settings.sourceLanguage,
              target: settings.targetLanguage,
              translationService: translationService,
              onClose: _clearSelection,
            ),
          ),
      ],
    );
  }
}
