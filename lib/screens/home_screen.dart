import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/ads_service.dart';
import '../services/incoming_file_service.dart';
import '../services/library_service.dart';
import '../services/page_image_cache.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../widgets/document_tile.dart';
import '../widgets/model_suggestion_card.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';
import 'txt_reader_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _importing = false;
  List<TranslateLanguage> _missingModels = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// Startup order matters: if the app was launched by another app handing
  /// it a document ("Open with"), that document is what the reader asked
  /// for — reopening the last-read book as well would bury it.
  Future<void> _bootstrap() async {
    final openedIncoming = await IncomingFileService.instance.listen(_onIncomingFile);
    if (!mounted) return;
    _checkMissingModels();
    if (!openedIncoming) _resumeLastDocument();
  }

  // Resumes straight into whichever document (and page/mode) the reader
  // last had open, instead of always landing on the library — this only
  // ever fires once, right after a cold start, since initState only runs
  // once for this screen's lifetime; returning here via the back button
  // after that does NOT re-trigger it.
  void _resumeLastDocument() {
    final lastId = context.read<SettingsService>().lastDocumentId;
    if (lastId == null) return;
    final exists = context.read<LibraryService>().documents.any((d) => d.id == lastId);
    if (!exists) return;
    _openDocument(lastId);
  }

  /// A document opened from another app ("Open with", or the share sheet).
  void _onIncomingFile(String path) {
    if (!mounted) return;
    _importPath(path, p.basename(path));
  }

  /// Routes to the right reader for [documentId]'s format — plain .txt
  /// files get the much simpler [TxtReaderScreen]; everything else (PDF)
  /// keeps using the full [ReaderScreen].
  void _openDocument(String documentId) {
    final document = context.read<LibraryService>().documents.firstWhere((d) => d.id == documentId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => document.isTextDocument
            ? TxtReaderScreen(documentId: documentId)
            : ReaderScreen(documentId: documentId),
      ),
    );
  }

  Future<void> _checkMissingModels() async {
    final settings = context.read<SettingsService>();
    if (!settings.translatorEnabled) return;
    final translation = context.read<TranslationService>();
    final missing = await translation.missingModels(
      settings.sourceLanguage,
      settings.targetLanguage,
    );
    if (mounted) setState(() => _missingModels = missing);
  }

  /// Formats offered in the picker. PDF keeps its page-image reader; the
  /// rest are reflowable text formats and open in the paginated text
  /// reader (see [extractEbookParagraphs]).
  ///
  /// DjVu is deliberately absent: decoding it needs a native library
  /// (djvulibre) that has no Dart or Flutter binding, so it can't be read
  /// without shipping and maintaining a per-platform native build.
  static const _supportedExtensions = ['pdf', 'txt', 'epub', 'fb2', 'rtf', 'docx'];

  Future<void> _importFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _supportedExtensions,
      withData: false,
    );
    final picked = result?.files.single;
    if (picked?.path == null) return;
    if (!mounted) return;
    await _importPath(picked!.path!, picked.name);
  }

  /// Imports a file that came from anywhere — the picker, or another app
  /// via "Open with"/share (see [IncomingFileService]) — and opens it.
  Future<void> _importPath(String path, String fileName) async {
    setState(() => _importing = true);
    try {
      final library = context.read<LibraryService>();
      final title = p.basenameWithoutExtension(fileName);
      final extension = p.extension(fileName).toLowerCase().replaceFirst('.', '');
      final document = extension == 'pdf' || extension.isEmpty
          ? await library.importPdf(sourcePath: path, title: title)
          : await library.importText(sourcePath: path, title: title, format: extension);
      if (!mounted) return;
      _openDocument(document.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).openFailed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final library = context.watch<LibraryService>();
    final documents = library.documents;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TransRead'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.translate,
              color: settings.translatorEnabled ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            tooltip: settings.translatorEnabled ? l10n.translatorOnTooltip : l10n.translatorOffTooltip,
            onPressed: () => settings.setTranslatorEnabled(!settings.translatorEnabled),
          ),
          IconButton(
            icon: Icon(Icons.query_stats, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
            tooltip: l10n.statisticsTooltip,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StatisticsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTooltip,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (settings.translatorEnabled && _missingModels.isNotEmpty)
            ModelSuggestionCard(
              key: ValueKey(_missingModels.join(',')),
              languages: _missingModels,
              onDone: _checkMissingModels,
            ),
          Expanded(
            child: documents.isEmpty ? _buildEmptyState(context) : _buildList(documents),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _importFile,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_importing ? l10n.importingLabel : l10n.addPdfLabel),
      ),
      // Shown only here on the library screen — never inside the reader —
      // so reading itself always stays uninterrupted by ads.
      bottomNavigationBar: const LibraryBannerAd(),
    );
  }

  Widget _buildList(List<LibraryDocument> documents) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      buildDefaultDragHandles: false,
      itemCount: documents.length,
      onReorder: (oldIndex, newIndex) {
        final ids = documents.map((d) => d.id).toList();
        if (newIndex > oldIndex) newIndex -= 1;
        final id = ids.removeAt(oldIndex);
        ids.insert(newIndex, id);
        context.read<LibraryService>().reorder(ids);
      },
      itemBuilder: (context, index) {
        final doc = documents[index];
        return DocumentTile(
          key: ValueKey(doc.id),
          document: doc,
          index: index,
          onTap: () => _openDocument(doc.id),
          onDelete: () => _deleteDocument(doc.id),
          onToggleStar: () => context.read<LibraryService>().toggleStarred(doc.id),
        );
      },
    );
  }

  Future<void> _deleteDocument(String id) async {
    final library = context.read<LibraryService>();
    final thumbnails = context.read<ThumbnailCache>();
    final previews = context.read<PagePreviewCache>();
    // Statistics go too: the totals on the statistics screen would
    // otherwise keep counting a book that's no longer in the library,
    // while the per-book list below them (which can only show documents
    // it can name) quietly leaves it out.
    final statistics = context.read<StatisticsService>();
    await library.remove(id);
    unawaited(thumbnails.delete(id));
    unawaited(previews.delete(id));
    unawaited(statistics.forget(id));
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_rounded, size: 72, color: scheme.primary),
            const SizedBox(height: 20),
            Text(
              l10n.emptyLibraryTitle,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.emptyLibrarySubtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
