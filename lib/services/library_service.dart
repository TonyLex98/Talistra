import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_document.dart';
import 'backup.dart';

/// Owns the list of PDFs the user has imported, persisting it as JSON in
/// SharedPreferences and keeping the actual files in the app's private
/// documents folder so they survive even if the original was a temporary
/// share-sheet copy.
class LibraryService extends ChangeNotifier {
  LibraryService(this._prefs, this._documents);

  static const _key = 'library_documents';

  final SharedPreferences _prefs;
  final List<LibraryDocument> _documents;

  /// Starred documents are pinned above everything else. Within a group
  /// (starred / not starred), anything the reader has manually dragged
  /// keeps that explicit order; documents that were never touched or
  /// starred fall back to the library's original recency sort, and sort
  /// after every manually-ordered document in their group.
  List<LibraryDocument> get documents => List.unmodifiable(
    _documents..sort((a, b) {
      if (a.starred != b.starred) return a.starred ? -1 : 1;
      final aOrder = a.manualOrder;
      final bOrder = b.manualOrder;
      if (aOrder != null || bOrder != null) {
        if (aOrder == null) return 1;
        if (bOrder == null) return -1;
        return aOrder.compareTo(bOrder);
      }
      return b.lastOpenedAt.compareTo(a.lastOpenedAt);
    }),
  );

  static Future<LibraryService> load(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_key) ?? const [];
    final docs = <LibraryDocument>[];
    for (final entry in raw) {
      try {
        final doc = LibraryDocument.fromJson(
          jsonDecode(entry) as Map<String, dynamic>,
        );
        if (await File(doc.filePath).exists()) docs.add(doc);
      } catch (_) {
        // Skip corrupted entries rather than failing the whole library.
      }
    }
    return LibraryService(prefs, docs).._watchForBackground();
  }

  /// Reading progress is written once per page the reader turns, and a page
  /// turn is a swipe: serializing the whole library to disk in the middle of
  /// one is just the kind of work that makes a big book stutter. The model
  /// still updates at once — only the write waits, for a moment's quiet in
  /// the reading or for the app going to the background.
  static const _saveDelay = Duration(milliseconds: 1200);
  Timer? _pendingSave;
  AppLifecycleListener? _lifecycle;

  void _watchForBackground() {
    _lifecycle = AppLifecycleListener(onPause: saveNow, onDetach: saveNow);
  }

  /// Writes the library out without waiting for the coalesced save.
  void saveNow() {
    _pendingSave?.cancel();
    _pendingSave = null;
    unawaited(_persist());
  }

  void _scheduleSave() {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      // Nothing is animating now, and the process may not live to see a
      // timer fire — write it while there is still a moment.
      saveNow();
      return;
    }
    _pendingSave?.cancel();
    _pendingSave = Timer(_saveDelay, saveNow);
  }

  @override
  void dispose() {
    _pendingSave?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Told when a book comes back into the library that a restored backup
  /// knew under another id — so the notes and statistics kept for that id
  /// can move onto the book's new one.
  void Function(String backupId, String documentId)? onRestoredFromBackup;

  /// [document] with the progress a restored backup kept for the same file,
  /// if it kept any — the other half of `restoreBackup`, for the books that
  /// weren't in the library when it ran.
  LibraryDocument _adoptFromBackup(LibraryDocument document) {
    final pending = _prefs.getStringList(pendingRestoreKey);
    if (pending == null || pending.isEmpty) return document;
    for (var i = 0; i < pending.length; i++) {
      final LibraryDocument saved;
      try {
        saved = LibraryDocument.fromJson(
          jsonDecode(pending[i]) as Map<String, dynamic>,
        );
      } catch (_) {
        continue;
      }
      if (saved.sourceFingerprint != document.sourceFingerprint) continue;
      unawaited(
        _prefs.setStringList(pendingRestoreKey, [...pending]..removeAt(i)),
      );
      onRestoredFromBackup?.call(saved.id, document.id);
      return withProgressOf(document, saved);
    }
    return document;
  }

  Future<void> _persist() async {
    final raw = _documents.map((d) => jsonEncode(d.toJson())).toList();
    await _prefs.setStringList(_key, raw);
  }

  /// Copies [sourcePath] into the app's private storage and adds it to the
  /// library under [title]. If a file with the same name and size was
  /// already imported, returns that existing entry instead of duplicating
  /// it — re-picking the same PDF just opens it.
  Future<LibraryDocument> importPdf({
    required String sourcePath,
    required String title,
  }) => _importFile(sourcePath: sourcePath, title: title, format: 'pdf');

  /// Same as [importPdf], for the text formats (txt, epub, fb2, rtf,
  /// docx) — [format] is the file's extension, which is what the reader
  /// uses later to decide how to pull the text out of it.
  Future<LibraryDocument> importText({
    required String sourcePath,
    required String title,
    required String format,
  }) => _importFile(sourcePath: sourcePath, title: title, format: format);

  Future<LibraryDocument> _importFile({
    required String sourcePath,
    required String title,
    required String format,
  }) async {
    final sourceFile = File(sourcePath);
    final fingerprint =
        '${p.basename(sourcePath)}_${await sourceFile.length()}';

    for (final existing in _documents) {
      if (existing.sourceFingerprint == fingerprint &&
          await File(existing.filePath).exists()) {
        return existing;
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final filesDir = Directory(p.join(docsDir.path, 'pdfs'));
    if (!await filesDir.exists()) await filesDir.create(recursive: true);

    final id =
        '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
    final destPath = p.join(filesDir.path, '$id.$format');
    await sourceFile.copy(destPath);

    final document = LibraryDocument(
      id: id,
      title: title,
      filePath: destPath,
      addedAt: DateTime.now(),
      sourceFingerprint: fingerprint,
      format: format,
    );
    final adopted = _adoptFromBackup(document);
    _documents.add(adopted);
    await _persist();
    notifyListeners();
    return adopted;
  }

  /// Adds a document from raw bytes rather than a picked file — used to
  /// seed the bundled first-install instructions PDF, which ships as an
  /// asset rather than something the reader picked themselves.
  Future<LibraryDocument> importBytes({
    required Uint8List bytes,
    required String title,
    String format = 'pdf',
    String? sourceFingerprint,
  }) async {
    // The same file picked again opens what it became the first time.
    if (sourceFingerprint != null) {
      for (final existing in _documents) {
        if (existing.sourceFingerprint == sourceFingerprint &&
            await File(existing.filePath).exists()) {
          return existing;
        }
      }
    }
    final docsDir = await getApplicationDocumentsDirectory();
    final pdfsDir = Directory(p.join(docsDir.path, 'pdfs'));
    if (!await pdfsDir.exists()) await pdfsDir.create(recursive: true);

    final id =
        '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
    final destPath = p.join(pdfsDir.path, '$id.$format');
    await File(destPath).writeAsBytes(bytes);

    final document = LibraryDocument(
      id: id,
      title: title,
      filePath: destPath,
      addedAt: DateTime.now(),
      sourceFingerprint: sourceFingerprint ?? 'bundled_$id',
      format: format,
    );
    final adopted = _adoptFromBackup(document);
    _documents.add(adopted);
    await _persist();
    notifyListeners();
    return adopted;
  }

  Future<void> updateProgress(
    String id, {
    required int lastPage,
    required int pageCount,
    bool? reflowMode,
    double? pdfZoom,
    double? pdfScrollFraction,
    double? pdfScrollFractionX,
    double? reflowFontSize,
  }) async {
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    _documents[index] = _documents[index].copyWith(
      lastPage: lastPage,
      pageCount: pageCount,
      reflowMode: reflowMode,
      pdfZoom: pdfZoom,
      pdfScrollFraction: pdfScrollFraction,
      pdfScrollFractionX: pdfScrollFractionX,
      reflowFontSize: reflowFontSize,
      lastOpenedAt: DateTime.now(),
    );
    _scheduleSave();
    notifyListeners();
  }

  /// Records the reader's own drag-to-reorder of the library list:
  /// [orderedIds] is the full, currently-displayed list in its new order.
  /// Assigning every one of them an explicit position (rather than just
  /// the one that moved) keeps the whole arrangement stable — otherwise
  /// an untouched document sorting by recency could jump back in front
  /// of ones the reader deliberately placed around it.
  Future<void> reorder(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      final index = _documents.indexWhere((d) => d.id == orderedIds[i]);
      if (index == -1) continue;
      _documents[index] = _documents[index].copyWith(manualOrder: i);
    }
    await _persist();
    notifyListeners();
  }

  /// Renames a document. Only the library entry's own [LibraryDocument.title]
  /// changes — the underlying file on disk keeps its internal `<id>.<format>`
  /// name, so nothing else (thumbnail cache key, statistics, file path) needs
  /// to move.
  Future<void> rename(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    if (_documents[index].title == trimmed) return;
    _documents[index] = _documents[index].copyWith(title: trimmed);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleStarred(String id) async {
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    _documents[index] = _documents[index].copyWith(
      starred: !_documents[index].starred,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    final doc = _documents.removeAt(index);
    await _persist();
    notifyListeners();
    final file = File(doc.filePath);
    if (await file.exists()) await file.delete();
  }
}
