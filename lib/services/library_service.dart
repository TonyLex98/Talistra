import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_document.dart';

/// Owns the list of PDFs the user has imported, persisting it as JSON in
/// SharedPreferences and keeping the actual files in the app's private
/// documents folder so they survive even if the original was a temporary
/// share-sheet copy.
class LibraryService extends ChangeNotifier {
  LibraryService(this._prefs, this._documents);

  static const _key = 'library_documents';

  final SharedPreferences _prefs;
  final List<LibraryDocument> _documents;

  List<LibraryDocument> get documents => List.unmodifiable(
    _documents..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt)),
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
    return LibraryService(prefs, docs);
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
  }) async {
    final sourceFile = File(sourcePath);
    final fingerprint = '${p.basename(sourcePath)}_${await sourceFile.length()}';

    for (final existing in _documents) {
      if (existing.sourceFingerprint == fingerprint &&
          await File(existing.filePath).exists()) {
        return existing;
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final pdfsDir = Directory(p.join(docsDir.path, 'pdfs'));
    if (!await pdfsDir.exists()) await pdfsDir.create(recursive: true);

    final id = '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}';
    final destPath = p.join(pdfsDir.path, '$id.pdf');
    await sourceFile.copy(destPath);

    final document = LibraryDocument(
      id: id,
      title: title,
      filePath: destPath,
      addedAt: DateTime.now(),
      sourceFingerprint: fingerprint,
    );
    _documents.add(document);
    await _persist();
    notifyListeners();
    return document;
  }

  Future<void> updateProgress(
    String id, {
    required int lastPage,
    required int pageCount,
  }) async {
    final index = _documents.indexWhere((d) => d.id == id);
    if (index == -1) return;
    _documents[index] = _documents[index].copyWith(
      lastPage: lastPage,
      pageCount: pageCount,
      lastOpenedAt: DateTime.now(),
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
