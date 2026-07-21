import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/translation_service.dart';
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
  final _reflowKey = GlobalKey<ReflowPdfViewState>();
  late final PdfViewerController _controller;
  late LibraryDocument _document;

  PdfDocument? _pdfDocument;
  final Map<int, List<TextLine>> _pageLinesCache = {};
  List<double> _pageAspectRatios = const [];

  int _pageCount = 0;
  int _currentPage = 1;
  String? _selectedWord;
  SentenceMatch? _selectedSentence;

  // The word/sentence highlight is stored in PDF-space (page index + PDF
  // point bounds), not screen coordinates: screen position is recomputed
  // from these on every build, including ones triggered by the scroll/zoom
  // listener below, so the highlight tracks the text instead of staying
  // frozen at the screen position it was tapped at.
  int? _selectedPageIndex;
  Rect? _selectedWordPdfBounds;
  List<Rect> _selectedSentenceLineBoundsPdf = const [];

  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;

  bool _reflowMode = false;
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
    _controller.addListener(_onViewerTransformChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onViewerTransformChanged);
    super.dispose();
  }

  // Scrolling or zooming while a translation is open needs to reposition
  // the highlight (its screen position depends on scroll/zoom), not just
  // leave it stuck where it was tapped.
  void _onViewerTransformChanged() {
    if (_selectedWord != null) setState(() {});
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
    _updateCurrentPage(details.newPageNumber);
    _clearSelection();
  }

  void _updateCurrentPage(int page) {
    setState(() => _currentPage = page);
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: page,
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

    setState(() {
      _selectedWord = hit.text;
      _selectedSentence = sentence;
      _selectedPageIndex = pageIndex;
      _selectedWordPdfBounds = hit.bounds;
      _selectedSentenceLineBoundsPdf = sentence?.lineBounds ?? const [];
    });
  }

  /// Recomputes a stored PDF-space rect into the CURRENT screen position,
  /// using whatever scroll offset/zoom the viewer has right now — called
  /// fresh on every build so the highlight tracks scrolling instead of
  /// staying frozen at the position it was tapped at.
  Rect? _pdfRectToScreen(int pageIndex, Rect pdfBounds) {
    final document = _pdfDocument;
    final box = _viewerKey.currentContext?.findRenderObject() as RenderBox?;
    if (document == null || box == null || pageIndex >= _pageAspectRatios.length) {
      return null;
    }
    final viewportWidth = box.size.width;
    if (viewportWidth <= 0) return null;
    final zoom = _controller.zoomLevel == 0 ? 1.0 : _controller.zoomLevel;
    final scrollOffset = _controller.scrollOffset;
    const pageSpacing = 4.0;
    var cumulative = 0.0;
    for (var i = 0; i < pageIndex; i++) {
      cumulative += viewportWidth * _pageAspectRatios[i] + pageSpacing;
    }
    final pageSize = document.pages[pageIndex].size;
    if (pageSize.width == 0) return null;
    final scale = viewportWidth / pageSize.width;
    final left = (pdfBounds.left * scale - scrollOffset.dx) * zoom;
    final top = ((cumulative + pdfBounds.top * scale) - scrollOffset.dy) * zoom;
    return Rect.fromLTWH(
      left,
      top,
      pdfBounds.width * scale * zoom,
      pdfBounds.height * scale * zoom,
    );
  }

  void _clearSelection() {
    if (_selectedWord == null) return;
    setState(() {
      _selectedWord = null;
      _selectedSentence = null;
      _selectedPageIndex = null;
      _selectedWordPdfBounds = null;
      _selectedSentenceLineBoundsPdf = const [];
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
    if (target == null || target < 1 || target > _pageCount) return;
    if (_reflowMode) {
      _reflowKey.currentState?.jumpToPage(target);
    } else {
      _controller.jumpToPage(target);
    }
  }

  void _toggleReflow() {
    _clearSelection();
    setState(() => _reflowMode = !_reflowMode);
    // Reflow is rebuilt fresh each time (it already opens at
    // widget.initialPage), but the PDF view stays alive the whole time, so
    // only it needs an explicit re-sync — and only if it's not already on
    // the right page, since a no-op jump would still force a re-layout.
    if (!_reflowMode && _controller.pageNumber != _currentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _controller.jumpToPage(_currentPage);
      });
    }
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
          ],
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
      // The PDF view stays mounted AND actually painting at all times
      // (never Offstage) instead of one view replacing the other: besides
      // SfPdfViewer.dispose() releasing its syncfusion PdfDocument (which
      // reflow reads from), fully hiding it also let it evict its
      // rendered-page cache, making it re-rasterize from scratch — and
      // thus feel very slow — every time you switched back. A near-zero
      // opacity keeps it rendering (so its cache stays warm) while being
      // invisible and untouchable behind reflow.
      body: Stack(
        children: [
          IgnorePointer(
            ignoring: _reflowMode,
            child: Opacity(
              opacity: _reflowMode ? 0.001 : 1,
              child: _buildPdfBody(settings, translationService),
            ),
          ),
          if (_pdfDocument != null && _reflowMode)
            _buildReflowBody(settings, translationService),
        ],
      ),
    );
  }

  Widget _buildReflowBody(SettingsService settings, TranslationService translationService) {
    final document = _pdfDocument;
    if (document == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ReflowPdfView(
      key: _reflowKey,
      filePath: _document.filePath,
      document: document,
      pageCount: _pageCount,
      initialPage: _currentPage,
      linesCache: _pageLinesCache,
      source: settings.sourceLanguage,
      target: settings.targetLanguage,
      translationService: translationService,
      fontSize: _reflowFontSize,
      readingTheme: settings.readingTheme,
      onPageChanged: _updateCurrentPage,
    );
  }

  Widget _buildPdfBody(SettingsService settings, TranslationService translationService) {
    // Recomputed from PDF-space bounds on every build (including ones the
    // scroll/zoom listener triggers) so the highlight tracks scrolling
    // instead of staying frozen at the position it was tapped at.
    Rect? wordRect;
    final sentenceRects = <Rect>[];
    if (_selectedWord != null && _selectedPageIndex != null) {
      if (_selectedWordPdfBounds != null) {
        wordRect = _pdfRectToScreen(_selectedPageIndex!, _selectedWordPdfBounds!);
      }
      for (final pdfRect in _selectedSentenceLineBoundsPdf) {
        final rect = _pdfRectToScreen(_selectedPageIndex!, pdfRect);
        if (rect != null) sentenceRects.add(rect);
      }
    }

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
        for (final rect in sentenceRects)
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
        if (wordRect != null)
          Positioned.fromRect(
            rect: wordRect,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
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
