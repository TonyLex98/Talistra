import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/djvu_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';

const double _barHeight = 50;

class DjvuReaderScreen extends StatefulWidget {
  const DjvuReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<DjvuReaderScreen> createState() => _DjvuReaderScreenState();
}

class _DjvuReaderScreenState extends State<DjvuReaderScreen>
    with WidgetsBindingObserver {
  late final LibraryDocument _document;
  late final PageController _pageController;

  DjvuDocument? _djvu;
  String? _error;
  int _currentPage = 1;
  DateTime? _pageEnteredAt;

  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;

  @override
  void initState() {
    super.initState();
    _document = context.read<LibraryService>().documents.firstWhere(
      (document) => document.id == widget.documentId,
    );
    _currentPage = math.max(1, _document.lastPage);
    _pageController = PageController(initialPage: _currentPage - 1);
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    _open();
  }

  Future<void> _open() async {
    DjvuDocument? document;
    try {
      document = await DjvuDocument.open(_document.filePath);
      if (!mounted) {
        await document.close();
        return;
      }
      final restoredPage = _currentPage.clamp(1, document.pageCount);
      setState(() {
        _djvu = document;
        _currentPage = restoredPage;
      });
      if (_pageController.hasClients &&
          _pageController.page?.round() != restoredPage - 1) {
        _pageController.jumpToPage(restoredPage - 1);
      }
      unawaited(
        context.read<LibraryService>().updateProgress(
          widget.documentId,
          lastPage: restoredPage,
          pageCount: document.pageCount,
        ),
      );
    } catch (error) {
      if (document != null) await document.close();
      if (!mounted) return;
      setState(
        () => _error = error is PlatformException && error.code == 'djvu_error'
            ? AppLocalizations.of(context).djvuInvalidDocument
            : '$error',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushDwellTime();
    _pageController.dispose();
    final document = _djvu;
    if (document != null) unawaited(document.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
  }

  void _flushDwellTime() {
    final enteredAt = _pageEnteredAt;
    if (enteredAt == null) return;
    final elapsed = DateTime.now().difference(enteredAt).inSeconds;
    _pageEnteredAt = null;
    if (elapsed < _minDwellSeconds) return;
    context.read<StatisticsService>().recordReading(
      documentId: widget.documentId,
      seconds: elapsed.clamp(0, _maxCountedDwellSeconds),
      page: _currentPage,
    );
  }

  void _onPageChanged(int index) {
    final page = index + 1;
    if (page == _currentPage) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() => _currentPage = page);
    final document = _djvu;
    if (document == null) return;
    unawaited(
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: page,
        pageCount: document.pageCount,
      ),
    );
  }

  Future<void> _jumpToPage() async {
    final document = _djvu;
    if (document == null) return;
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.goToPageTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.goToPageHint(document.pageCount),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(controller.text)),
            child: Text(l10n.go),
          ),
        ],
      ),
    );
    controller.dispose();
    if (target == null || target < 1 || target > document.pageCount) return;
    await _pageController.animateToPage(
      target - 1,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showTextLayer() async {
    final document = _djvu;
    if (document == null) return;
    final pageIndex = _currentPage - 1;
    final textFuture = document.pageText(pageIndex);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context
          .read<SettingsService>()
          .readingTheme
          .secondaryBackground,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.35,
        maxChildSize: 0.94,
        builder: (context, scrollController) => FutureBuilder<String?>(
          future: textFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            // DjVu text zones often contain a newline for every OCR word or
            // column fragment. Let Flutter wrap one clean stream naturally;
            // otherwise narrow phones display words split into staircase-like
            // fragments even though the page text itself is valid.
            final text = snapshot.data?.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (snapshot.hasError || text == null || text.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    AppLocalizations.of(context).djvuNoTextLayer,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
              children: [
                Text(
                  AppLocalizations.of(context).djvuTextLayer,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SelectableText(
                  text,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(height: 1.55),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: settings.readingTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(settings, l10n),
              ),
            ),
          ),
          _buildFloatingBar(settings, l10n),
        ],
      ),
    );
  }

  Widget _buildBody(SettingsService settings, AppLocalizations l10n) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(l10n.openFailed(error), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final document = _djvu;
    if (document == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(l10n.djvuOpening),
          ],
        ),
      );
    }
    return PageView.builder(
      controller: _pageController,
      itemCount: document.pageCount,
      allowImplicitScrolling: true,
      physics: const PageScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => _DjvuPage(
        key: ValueKey(index),
        document: document,
        pageIndex: index,
        background: settings.readingTheme.background,
        imageFilter: settings.readingTheme.pageImageFilter(
          contrast: settings.readingContrast,
          weight: settings.readingWeight,
        ),
      ),
    );
  }

  Widget _buildFloatingBar(SettingsService settings, AppLocalizations l10n) {
    final document = _djvu;
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: settings.readingTheme.secondaryBackground,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.38),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        child: Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: SizedBox(
            height: _barHeight,
            child: Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: InkWell(
                    onTap: document == null ? null : _jumpToPage,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            document == null
                                ? _document.title
                                : '$_currentPage / ${document.pageCount}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (document != null)
                            Text(
                              _document.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.article_outlined),
                  tooltip: l10n.djvuTextLayer,
                  onPressed: document == null ? null : _showTextLayer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DjvuPage extends StatefulWidget {
  const _DjvuPage({
    super.key,
    required this.document,
    required this.pageIndex,
    required this.background,
    required this.imageFilter,
  });

  final DjvuDocument document;
  final int pageIndex;
  final Color background;
  final ColorFilter imageFilter;

  @override
  State<_DjvuPage> createState() => _DjvuPageState();
}

class _DjvuPageState extends State<_DjvuPage> {
  late final Future<DjvuPageInfo> _info = widget.document.pageInfo(
    widget.pageIndex,
  );
  final Map<int, Future<Uint8List>> _renders = {};
  final TransformationController _transformation = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final zoomed = _transformation.value.getMaxScaleOnAxis() > 1.015;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  @override
  void dispose() {
    _transformation
      ..removeListener(_onTransformChanged)
      ..dispose();
    super.dispose();
  }

  void _toggleZoom() {
    _transformation.value = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()..scaleByDouble(2, 2, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.background,
      child: FutureBuilder<DjvuPageInfo>(
        future: _info,
        builder: (context, infoSnapshot) {
          if (infoSnapshot.hasError) {
            return _PageError(error: '${infoSnapshot.error}');
          }
          final info = infoSnapshot.data;
          if (info == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return LayoutBuilder(
            builder: (context, constraints) {
              final pixelRatio = MediaQuery.devicePixelRatioOf(context);
              // Keep the first paint cheap on low-end 32-bit phones. Entering
              // zoom mode requests a separate high-resolution render, so the
              // base page remains quick without becoming blurry when enlarged.
              final renderWidth = _zoomed
                  ? 1600
                  : (constraints.maxWidth * pixelRatio).round().clamp(
                      720,
                      1200,
                    );
              final renderHeight = (renderWidth / info.aspectRatio)
                  .round()
                  .clamp(1, 4000);
              final render = _renders.putIfAbsent(
                renderWidth,
                () => widget.document.renderPage(
                  widget.pageIndex,
                  width: renderWidth,
                  height: renderHeight,
                ),
              );
              return FutureBuilder<Uint8List>(
                future: render,
                builder: (context, imageSnapshot) {
                  if (imageSnapshot.hasError) {
                    return _PageError(error: '${imageSnapshot.error}');
                  }
                  final bytes = imageSnapshot.data;
                  if (bytes == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final pageImage = Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 14,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: ColorFiltered(
                            colorFilter: widget.imageFilter,
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  if (!_zoomed) {
                    // Do not keep an InteractiveViewer in the tree at the
                    // base scale: its scale recognizer claims ordinary
                    // one-finger drags before the surrounding PageView can
                    // turn the page.
                    return GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _toggleZoom,
                      child: pageImage,
                    );
                  }
                  return GestureDetector(
                    onDoubleTap: _toggleZoom,
                    child: InteractiveViewer(
                      transformationController: _transformation,
                      minScale: 1,
                      maxScale: 4,
                      boundaryMargin: const EdgeInsets.all(48),
                      clipBehavior: Clip.none,
                      child: pageImage,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _PageError extends StatelessWidget {
  const _PageError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          AppLocalizations.of(context).djvuPageFailed(error),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
