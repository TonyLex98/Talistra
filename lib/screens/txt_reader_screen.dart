import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/library_service.dart';
import '../services/reading_display_service.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../utils/reflow_builder.dart';
import '../utils/ebook_text.dart';
import '../utils/txt_paragraphs.dart';
import '../utils/text_search.dart';
import '../widgets/language_picker_sheet.dart';
import '../widgets/book_search_bar.dart';
import '../widgets/txt_page_view.dart';

/// Reader for plain .txt files — deliberately much simpler than
/// [ReaderScreen]: no PDF/reflow mode toggle (there's no "original" to
/// switch back to), no per-page images, no experimental sync-translation.
/// Just the same tap-to-translate reading experience, font size, and
/// reading theme, over synthetic pages (see [buildTxtPages]).
/// Height of the floating top bar (excluding the status-bar inset it sits
/// under) — matched to the PDF reader's.
const double _barHeight = 50;

class TxtReaderScreen extends StatefulWidget {
  const TxtReaderScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<TxtReaderScreen> createState() => _TxtReaderScreenState();
}

class _TxtReaderScreenState extends State<TxtReaderScreen>
    with WidgetsBindingObserver {
  final _pageViewKey = GlobalKey<TxtPageViewState>();
  late LibraryDocument _document;

  List<List<ReflowBlock>> _pages = const [];
  bool _loading = true;
  String? _error;

  int _currentPage = 1;
  double _fontSize = 17;
  bool _searchOpen = false;

  static const _minDwellSeconds = 3;
  static const _maxCountedDwellSeconds = 600;
  DateTime? _pageEnteredAt;

  @override
  void initState() {
    super.initState();
    _document = context.read<LibraryService>().documents.firstWhere(
      (d) => d.id == widget.documentId,
    );
    _currentPage = _document.lastPage;
    _fontSize = _document.reflowFontSize;
    _pageEnteredAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    context.read<SettingsService>().setLastDocumentId(widget.documentId);
    unawaited(
      context.read<ReadingDisplayService>().enter(
        context.read<SettingsService>(),
      ),
    );
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(_document.filePath).readAsBytes();
      // Every reflowable format ends up here as paragraphs, so the reading
      // experience (pagination, tap-to-translate, typography) is identical
      // whether the file was a .txt, an EPUB or a Word document.
      final format = ebookFormatFromPath(_document.filePath) ?? EbookFormat.txt;
      final paragraphs = extractEbookParagraphs(bytes, format);
      final pages = buildTxtPagesFromParagraphs(paragraphs);
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _loading = false;
      });
      context.read<LibraryService>().updateProgress(
        widget.documentId,
        lastPage: _currentPage.clamp(1, pages.isEmpty ? 1 : pages.length),
        pageCount: pages.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(context.read<ReadingDisplayService>().exit());
    _flushDwellTime();
    super.dispose();
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

  /// Same rule as the PDF reader: time only counts while the app is
  /// actually in the foreground, never with the screen off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pageEnteredAt ??= DateTime.now();
    } else {
      _flushDwellTime();
    }
  }

  void _updateCurrentPage(int page) {
    if (page == _currentPage) return;
    _flushDwellTime();
    _pageEnteredAt = DateTime.now();
    setState(() => _currentPage = page);
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: page,
      pageCount: _pages.length,
    );
  }

  void _changeFontSize(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(13, 26));
    context.read<LibraryService>().updateProgress(
      widget.documentId,
      lastPage: _currentPage,
      pageCount: _pages.length,
      reflowFontSize: _fontSize,
    );
  }

  /// Opens the inline search bar in the top bar (in place of the title).
  void _openSearch() {
    setState(() => _searchOpen = true);
  }

  /// Closes the inline search bar and drops the highlight.
  void _closeSearch() {
    _pageViewKey.currentState?.clearSearchHighlight();
    setState(() => _searchOpen = false);
  }

  /// The search the [BookSearchBar] runs. Plain text has no extraction step:
  /// the pages are already in memory, so a query is a substring scan
  /// delivered in one batch.
  Future<void> _runSearch(
    String query, {
    required void Function(List<SearchMatch>) onBatch,
    required void Function() onDone,
  }) async {
    final pages = _pages.map((b) => b.map((x) => x.text).toList()).toList();
    final matches = searchInPages(pages, query);
    if (matches.isNotEmpty) onBatch(matches);
    onDone();
  }

  void _onSearchSelect(SearchMatch match) {
    _pageViewKey.currentState?.showSearchHighlight(
      match.pageIndex + 1,
      match.blockIndex,
      match.matchStart,
      match.matchEnd,
    );
    _updateCurrentPage(match.pageIndex + 1);
  }

  Future<void> _jumpToPage() async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: '$_currentPage');
    final target = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.goToPageTitle),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.goToPageHint(_pages.length),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)),
            child: Text(l10n.go),
          ),
        ],
      ),
    );
    if (target == null || target < 1 || target > _pages.length) return;
    _pageViewKey.currentState?.jumpToPage(target);
    _updateCurrentPage(target);
  }

  Future<void> _quickLanguageSwitch() async {
    final l10n = AppLocalizations.of(context);
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
                Text(
                  l10n.translationLanguageTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Consumer<SettingsService>(
                  builder: (context, settings, _) => Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          settings.sourceAppLanguage.flag,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(l10n.fromLanguage),
                        subtitle: Text(settings.sourceAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.sourceLanguage,
                            title: l10n.fromLanguagePickerTitle,
                          );
                          if (picked != null) {
                            settings.setSourceLanguage(picked);
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_vert),
                        tooltip: l10n.swapLanguagesTooltip,
                        onPressed: settings.swapLanguages,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Text(
                          settings.targetAppLanguage.flag,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(l10n.toLanguage),
                        subtitle: Text(settings.targetAppLanguage.displayName),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final picked = await showLanguagePicker(
                            context: context,
                            current: settings.targetLanguage,
                            title: l10n.toLanguagePickerTitle,
                          );
                          if (picked != null) {
                            settings.setTargetLanguage(picked);
                          }
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final translationService = context.read<TranslationService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          // Same shape as the PDF reader: the content owns the screen and
          // the bar floats above it, so both readers look and behave alike.
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: _barHeight),
                child: _buildBody(settings, translationService),
              ),
            ),
          ),
          _buildFloatingBar(l10n, settings, scheme),
        ],
      ),
    );
  }

  /// The reader's single compact row, floating over the page — page counter
  /// (tap to jump), text size, translator toggle and the language pair, all
  /// in the reading palette.
  Widget _buildFloatingBar(
    AppLocalizations l10n,
    SettingsService settings,
    ColorScheme scheme,
  ) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: settings.readingTheme.secondaryBackground,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.45),
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
                if (_searchOpen)
                  Expanded(
                    child: BookSearchBar(
                      search: _runSearch,
                      onSelect: _onSearchSelect,
                      onClose: _closeSearch,
                    ),
                  )
                else ...[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.search),
                    tooltip: l10n.searchTooltip,
                    onPressed: _pages.isEmpty ? null : _openSearch,
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: _pages.isEmpty ? null : _jumpToPage,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _pages.isEmpty
                                  ? _document.title
                                  : '$_currentPage / ${_pages.length}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_pages.isNotEmpty)
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
                    iconSize: 22,
                    icon: const Icon(Icons.text_decrease),
                    tooltip: l10n.smallerText,
                    onPressed: () => _changeFontSize(-1),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 22,
                    icon: const Icon(Icons.text_increase),
                    tooltip: l10n.largerText,
                    onPressed: () => _changeFontSize(1),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 21,
                    icon: Icon(
                      Icons.translate,
                      color: settings.translatorEnabled
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                    ),
                    tooltip: settings.translatorEnabled
                        ? l10n.translatorOnTooltip
                        : l10n.translatorOffTooltip,
                    onPressed: () => settings.setTranslatorEnabled(
                      !settings.translatorEnabled,
                    ),
                  ),
                  if (settings.translatorEnabled)
                    InkWell(
                      onTap: _quickLanguageSwitch,
                      borderRadius: BorderRadius.circular(9),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Text(
                              settings.sourceAppLanguage.flag,
                              style: const TextStyle(fontSize: 13),
                            ),
                            Icon(
                              Icons.arrow_right_alt,
                              size: 15,
                              color: scheme.onSurfaceVariant,
                            ),
                            Text(
                              settings.targetAppLanguage.flag,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    SettingsService settings,
    TranslationService translationService,
  ) {
    if (_loading) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).openFailed(error)),
          ),
        ),
      );
    }
    if (_pages.isEmpty) {
      return ColoredBox(
        color: settings.readingTheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppLocalizations.of(context).noTextOnPage),
          ),
        ),
      );
    }
    return TxtPageView(
      key: _pageViewKey,
      pages: _pages,
      initialPage: _currentPage,
      source: settings.sourceLanguage,
      target: settings.targetLanguage,
      translationService: translationService,
      fontSize: _fontSize,
      readingTheme: settings.readingTheme,
      settings: settings,
      translatorEnabled: settings.translatorEnabled,
      onPageChanged: _updateCurrentPage,
    );
  }
}
