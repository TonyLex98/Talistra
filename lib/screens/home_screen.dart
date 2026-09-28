import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/library_document.dart';
import '../services/djvu_service.dart';
import '../services/annotation_service.dart';
import '../services/image_document.dart';
import '../services/incoming_file_service.dart';
import '../services/library_service.dart';
import '../services/ocr_service.dart';
import '../services/page_image_cache.dart';
import '../services/settings_service.dart';
import '../services/statistics_service.dart';
import '../services/translation_service.dart';
import '../services/vocabulary_service.dart';
import '../utils/document_format.dart';
import '../utils/pdf_unlock.dart';
import '../widgets/document_tile.dart';
import '../widgets/model_suggestion_card.dart';
import 'djvu_reader_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'statistics_screen.dart';
import 'txt_reader_screen.dart';
import 'vocabulary_screen.dart';
import 'xlsx_reader_screen.dart';

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
    final openedIncoming = await IncomingFileService.instance.listen(
      _onIncomingFile,
    );
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
    final document = context
        .read<LibraryService>()
        .documents
        .where((d) => d.id == lastId)
        .firstOrNull;
    // Older builds could import a generic .bin supplied by a file manager
    // and then try to paginate its binary data forever on startup.
    if (document == null || !_bookExtensions.contains(document.format)) return;
    _openDocument(lastId);
  }

  /// A document opened from another app ("Open with", or the share sheet).
  void _onIncomingFile(String path) {
    if (!mounted) return;
    _importPath(path, p.basename(path), replaceReaderStack: true);
  }

  /// Routes to the right reader for [documentId]'s format — plain .txt
  /// files get the much simpler [TxtReaderScreen]; everything else (PDF)
  /// keeps using the full [ReaderScreen].
  void _openDocument(String documentId, {bool replaceReaderStack = false}) {
    final document = context.read<LibraryService>().documents.firstWhere(
      (d) => d.id == documentId,
    );
    if (!_bookExtensions.contains(document.format)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).unsupportedDocumentFormat),
        ),
      );
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) {
        if (document.isDjvu) {
          return DjvuReaderScreen(documentId: documentId);
        }
        if (document.isXlsx) {
          return XlsxReaderScreen(documentId: documentId);
        }
        if (document.isTextDocument) {
          return TxtReaderScreen(documentId: documentId);
        }
        return ReaderScreen(documentId: documentId);
      },
    );
    if (replaceReaderStack) {
      Navigator.of(context).pushAndRemoveUntil(route, (route) => route.isFirst);
    } else {
      Navigator.of(context).push(route);
    }
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

  /// PDF keeps its page-image reader; the rest are reflowable text formats
  /// and open in the paginated text reader (see [extractEbookParagraphs]).
  static const _bookExtensions = {
    'pdf',
    'txt',
    'md',
    'xml',
    'html',
    'epub',
    'fb2',
    'rtf',
    'docx',
    'djvu',
    'djv',
    'xlsx',
    'xls',
  };

  Future<void> _importFile() async {
    final result = await FilePicker.pickFiles(
      // Android's document picker maps custom extensions to MIME types.
      // DjVu/DJV are missing from that mapping on some devices, so valid
      // books disappear from the picker. Keep the picker permissive and let
      // our signature-aware importer validate the selected document instead.
      type: FileType.any,
      withData: false,
    );
    final picked = result?.files.single;
    if (picked?.path == null) return;
    if (!mounted) return;
    await _importPath(picked!.path!, picked.name);
  }

  /// Imports a file that came from anywhere — the picker, or another app
  /// via "Open with"/share (see [IncomingFileService]) — and opens it.
  Future<void> _importPath(
    String path,
    String fileName, {
    bool replaceReaderStack = false,
  }) async {
    setState(() => _importing = true);
    try {
      final library = context.read<LibraryService>();
      final title = p.basenameWithoutExtension(fileName);
      final detected = await detectDocumentFormat(path, fileName: fileName);
      final String format;
      if (detected != null &&
          (supportedBookFormats.contains(detected) ||
              supportedImageFormats.contains(detected) ||
              supportedArchiveFormats.contains(detected))) {
        format = detected;
      } else {
        // A file Talistra has no reader for is not necessarily one it can't
        // show: anything that really is text can be read as a plain .txt
        // book. Ask, rather than quietly refuse or quietly guess.
        switch (await _offerAsPlainText(path)) {
          case null:
            throw const _UnsupportedDocumentException();
          case false:
            // The reader said no. That is an answer, not an error to report.
            return;
          case true:
            format = 'txt';
        }
      }
      if (format == 'zip') {
        final document = await _importArchive(path, fileName, library);
        if (document != null && mounted) {
          _openDocument(document.id, replaceReaderStack: replaceReaderStack);
        }
        return;
      }
      if (supportedImageFormats.contains(format)) {
        // A picture opens as a book of one page (see image_document.dart).
        final bytes = await File(path).readAsBytes();
        final document = await library.importBytes(
          bytes: await imageToPdf(bytes),
          title: title,
          sourceFingerprint: 'image_${p.basename(fileName)}_${bytes.length}',
        );
        if (!mounted) return;
        _openDocument(document.id, replaceReaderStack: replaceReaderStack);
        return;
      }
      if (format == 'djvu') {
        // A matching header alone is not enough: parse the directory before
        // adding the file so truncated/corrupt DjVu downloads never become
        // permanent dead entries in the library.
        final validation = await DjvuDocument.open(path);
        await validation.close();
      }
      var source = path;
      if (format == 'pdf') {
        final unlocked = await _unlockPdfIfNeeded(path, fileName);
        // The reader closed the password dialog: nothing to add.
        if (unlocked == null) return;
        source = unlocked;
      }
      final document = format == 'pdf'
          ? await library.importPdf(sourcePath: source, title: title)
          : await library.importText(
              sourcePath: path,
              title: title,
              format: format,
            );
      if (!mounted) return;
      _openDocument(document.id, replaceReaderStack: replaceReaderStack);
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final message = switch (e) {
        _UnsupportedDocumentException() => l10n.unsupportedDocumentFormat,
        PlatformException(code: 'djvu_error') => l10n.openFailed(
          l10n.djvuInvalidDocument,
        ),
        _ => l10n.openFailed('$e'),
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// The PDF at [path], or — when it needs a password — an unlocked copy of it
  /// once the reader has given the password (see `pdf_unlock.dart`). Null when
  /// they gave up.
  Future<String?> _unlockPdfIfNeeded(String path, String fileName) async {
    // Read in the isolate itself: a big PDF isn't worth copying across.
    final lock = await compute(_pdfLockOfFile, path);
    if (lock == PdfLock.open) return path;
    if (!mounted) return null;
    setState(() => _importing = false);
    final unlocked = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _PdfPasswordDialog(path: path),
    );
    if (unlocked == null || !mounted) return null;
    setState(() => _importing = true);
    final folder = Directory(
      p.join((await getTemporaryDirectory()).path, 'unlocked'),
    );
    await folder.create(recursive: true);
    final copy = File(p.join(folder.path, p.basename(fileName)));
    await copy.writeAsBytes(unlocked, flush: true);
    return copy.path;
  }

  /// Offers a file nothing else could read to be opened as a plain-text
  /// book, and says whether the reader took the offer — or null when it was
  /// never worth making, because the bytes are not text at all (see
  /// [fileLooksLikeText]).
  Future<bool?> _offerAsPlainText(String path) async {
    if (!await fileLooksLikeText(path)) return null;
    if (!mounted) return false;
    setState(() => _importing = false);
    final l10n = AppLocalizations.of(context);
    final asText =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.unknownFormatTitle),
            content: Text(l10n.unknownFormatAsText),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.openAsPlainText),
              ),
            ],
          ),
        ) ==
        true;
    if (!mounted) return false;
    if (asText) setState(() => _importing = true);
    return asText;
  }

  /// A ZIP is a container, not an e-book format. We only offer actual books
  /// from inside it, so an EPUB itself still goes through its normal reader.
  Future<LibraryDocument?> _importArchive(
    String path,
    String archiveName,
    LibraryService library,
  ) async {
    final archive = ZipDecoder().decodeBytes(
      await File(path).readAsBytes(),
      verify: true,
    );
    if (archive.files.length > 2000) {
      throw const FormatException('The archive contains too many files');
    }
    final books = <_ArchivedBook>[];
    var expandedBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      expandedBytes += file.size;
      if (expandedBytes > 500 * 1024 * 1024) {
        throw const FormatException('The unpacked archive is too large');
      }
      if (file.size > 250 * 1024 * 1024) continue;
      final bytes = archiveFileBytes(file);
      final format = detectDocumentFormatBytes(bytes, fileName: file.name);
      if (format != null && supportedBookFormats.contains(format)) {
        books.add(_ArchivedBook(file.name, format, bytes));
      } else if (format != null && supportedImageFormats.contains(format)) {
        books.add(_ArchivedBook(file.name, format, bytes));
      }
    }
    if (books.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).archiveNoBooks)),
        );
      }
      return null;
    }
    // A ZIP of nothing but pictures — scans, a comic — is one book of them,
    // a page each, in the order their names count.
    if (books.length > 1 &&
        books.every((book) => supportedImageFormats.contains(book.format))) {
      books.sort((a, b) => compareNaturally(a.name, b.name));
      return library.importBytes(
        bytes: await imagesToPdf([for (final book in books) book.bytes]),
        title: p.basenameWithoutExtension(archiveName),
        sourceFingerprint:
            'zip_images_${p.basename(path)}_${books.length}_$expandedBytes',
      );
    }
    final picked = books.length == 1
        ? books.single
        : await _pickArchiveBook(books);
    if (picked == null) return null;
    final isImage = supportedImageFormats.contains(picked.format);
    final document = await library.importBytes(
      bytes: isImage ? await imageToPdf(picked.bytes) : picked.bytes,
      title: p.basenameWithoutExtension(picked.name),
      format: isImage ? 'pdf' : picked.format,
      sourceFingerprint:
          'zip_${p.basename(path)}_${picked.name}_${picked.bytes.length}',
    );
    if (picked.format == 'djvu') {
      try {
        final validation = await DjvuDocument.open(document.filePath);
        await validation.close();
      } catch (_) {
        await library.remove(document.id);
        rethrow;
      }
    }
    return document;
  }

  Future<_ArchivedBook?> _pickArchiveBook(List<_ArchivedBook> books) =>
      showModalBottomSheet<_ArchivedBook>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Text(
                  AppLocalizations.of(context).archiveChooseBook,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final book in books)
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: Text(
                    p.basename(book.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(book.format.toUpperCase()),
                  onTap: () => Navigator.pop(sheetContext, book),
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsService>();
    final library = context.watch<LibraryService>();
    final documents = library.documents;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Talistra'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.translate,
              color: settings.translatorEnabled
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            tooltip: settings.translatorEnabled
                ? l10n.translatorOnTooltip
                : l10n.translatorOffTooltip,
            onPressed: () =>
                settings.setTranslatorEnabled(!settings.translatorEnabled),
          ),
          IconButton(
            icon: Icon(
              Icons.query_stats,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            tooltip: l10n.statisticsTooltip,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const StatisticsScreen())),
          ),
          IconButton(
            // A card box, not the translate glyph — that one is the
            // translator's own switch, and two buttons wearing it read as
            // one feature twice.
            icon: Badge(
              isLabelVisible: context.watch<VocabularyService>().due.isNotEmpty,
              label: Text('${context.watch<VocabularyService>().due.length}'),
              child: Icon(
                Icons.style_outlined,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            tooltip: l10n.vocabularyTooltip,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const VocabularyScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTooltip,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
            child: documents.isEmpty
                ? _buildEmptyState(context)
                : _buildList(documents),
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
    );
  }

  Widget _buildList(List<LibraryDocument> documents) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      // No dedicated handle icon (touch platforms drag the whole tile via
      // long-press instead) — the handle icon this default only adds is for
      // mouse-driven platforms, which this app doesn't target.
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
          onTap: () => _openDocument(doc.id),
          onDelete: () => _deleteDocument(doc.id),
          onToggleStar: () =>
              context.read<LibraryService>().toggleStarred(doc.id),
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
    final annotations = context.read<AnnotationService>();
    // Pages a scan had read by OCR go with it.
    OcrCache? ocr;
    try {
      ocr = context.read<OcrCache>();
    } on ProviderNotFoundException {
      // No OCR in this build of the tree (a test).
    }
    await library.remove(id);
    unawaited(annotations.removeDocument(id));
    if (ocr != null) unawaited(ocr.forget(id));
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchivedBook {
  const _ArchivedBook(this.name, this.format, this.bytes);

  final String name;
  final String format;
  final Uint8List bytes;
}

class _UnsupportedDocumentException implements Exception {
  const _UnsupportedDocumentException();
}

PdfLock _pdfLockOfFile(String path) => pdfLockOf(File(path).readAsBytesSync());

Uint8List? _unlockPdfFile(({String path, String password}) request) =>
    unlockPdf(File(request.path).readAsBytesSync(), request.password);

/// Asks for a PDF's password, checking it before closing: resolves to the
/// unlocked bytes, or null when the reader cancels.
class _PdfPasswordDialog extends StatefulWidget {
  const _PdfPasswordDialog({required this.path});

  final String path;

  @override
  State<_PdfPasswordDialog> createState() => _PdfPasswordDialogState();
}

class _PdfPasswordDialogState extends State<_PdfPasswordDialog> {
  final _controller = TextEditingController();
  bool _checking = false;
  bool _wrong = false;
  bool _obscured = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _wrong = false;
    });
    final unlocked = await compute(_unlockPdfFile, (
      path: widget.path,
      password: _controller.text,
    ));
    if (!mounted) return;
    if (unlocked != null) {
      Navigator.of(context).pop(unlocked);
      return;
    }
    setState(() {
      _checking = false;
      _wrong = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.pdfPasswordTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: _obscured,
        enabled: !_checking,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: l10n.pdfPasswordHint,
          errorText: _wrong ? l10n.pdfPasswordWrong : null,
          suffixIcon: IconButton(
            icon: Icon(_obscured ? Icons.visibility : Icons.visibility_off),
            tooltip: l10n.pdfPasswordHint,
            onPressed: () => setState(() => _obscured = !_obscured),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.open),
        ),
      ],
    );
  }
}
