import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A disk cache for a PDF's whole-book search index — the reflowed block
/// texts for every page — keyed by document id.
///
/// Extracting and reflowing every page is the slow part of a PDF search
/// (real seconds, even minutes on a large book, off the UI isolate). It
/// depends only on the file's own bytes, which never change once a document
/// is imported (see [LibraryDocument] / `LibraryService.rename` — renaming
/// only touches the title, not the stored `<id>.<format>` file), so once
/// built the index is valid for the document's lifetime and only needs
/// building the very first time it is searched, not every time the reader
/// reopens it.
class SearchIndexCache {
  SearchIndexCache._(this._dir);

  final Directory _dir;

  static Future<SearchIndexCache> open() async {
    final base = await getApplicationSupportDirectory();
    // v2: the page text is now repaired (or dropped) where a font garbled
    // it, and read in the page's shown orientation — an index built before
    // that holds text the reader no longer shows, so it is built again.
    final dir = Directory(p.join(base.path, 'search_index_v2'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final old = Directory(p.join(base.path, 'search_index_v1'));
    if (await old.exists()) {
      try {
        await old.delete(recursive: true);
      } catch (_) {
        // Stale files only cost space.
      }
    }
    return SearchIndexCache._(dir);
  }

  File _fileFor(String documentId) =>
      File(p.join(_dir.path, '$documentId.json'));

  Future<List<List<String>>?> read(String documentId) async {
    final file = _fileFor(documentId);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return (decoded as List)
          .map((page) => (page as List).cast<String>())
          .toList();
    } catch (_) {
      // A corrupt or unreadable cache entry is just a cache miss.
      return null;
    }
  }

  Future<void> write(String documentId, List<List<String>> pages) async {
    try {
      await _fileFor(documentId).writeAsString(jsonEncode(pages));
    } catch (_) {
      // A failed cache write just means next time is a cache miss too.
    }
  }

  Future<void> delete(String documentId) async {
    final file = _fileFor(documentId);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
