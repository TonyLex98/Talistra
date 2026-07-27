import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A tiny disk cache for a single rendered PDF page image (PNG bytes) per
/// document, stored under its own subdirectory. Used for two distinct
/// purposes — a library thumbnail (always page 1) and a "last read page"
/// preview shown instantly while a document reopens — each gets its own
/// subdirectory since they're rendered at different resolutions.
class PageImageCache {
  PageImageCache._(this._dir);

  final Directory _dir;

  /// Opens (creating if needed) the cache directory [subdirectory].
  ///
  /// [legacySubdirectory], if given, is an older generation of the same
  /// cache whose contents are no longer valid and is deleted outright —
  /// the way to invalidate every cached image at once after a change in
  /// how pages are rasterized (they used to be rendered with a
  /// transparent background, which looked washed-out or invisible
  /// depending on what was behind them).
  static Future<PageImageCache> open(
    String subdirectory, {
    String? legacySubdirectory,
  }) async {
    final base = await getApplicationSupportDirectory();
    if (legacySubdirectory != null) {
      final legacy = Directory(p.join(base.path, legacySubdirectory));
      try {
        if (await legacy.exists()) await legacy.delete(recursive: true);
      } catch (_) {
        // Stale images we couldn't delete are only wasted disk space;
        // nothing reads that directory anymore either way.
      }
    }
    final dir = Directory(p.join(base.path, subdirectory));
    if (!await dir.exists()) await dir.create(recursive: true);
    return PageImageCache._(dir);
  }

  File _fileFor(String documentId) =>
      File(p.join(_dir.path, '$documentId.png'));

  Future<Uint8List?> read(String documentId) async {
    final file = _fileFor(documentId);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String documentId, Uint8List bytes) async {
    try {
      await _fileFor(documentId).writeAsBytes(bytes, flush: true);
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

/// The library list's first-page thumbnails.
class ThumbnailCache {
  ThumbnailCache(this._cache);
  final PageImageCache _cache;

  static Future<ThumbnailCache> create() async => ThumbnailCache(
    await PageImageCache.open(
      'thumbnails_v2',
      legacySubdirectory: 'thumbnails',
    ),
  );

  Future<Uint8List?> read(String documentId) => _cache.read(documentId);
  Future<void> write(String documentId, Uint8List bytes) =>
      _cache.write(documentId, bytes);
  Future<void> delete(String documentId) => _cache.delete(documentId);
}

/// A preview of whichever page the reader last had open, shown instantly
/// while the document's real content re-renders, instead of a blank
/// loading screen.
class PagePreviewCache {
  PagePreviewCache(this._cache);
  final PageImageCache _cache;

  static Future<PagePreviewCache> create() async => PagePreviewCache(
    await PageImageCache.open(
      'page_preview_v2',
      legacySubdirectory: 'page_preview',
    ),
  );

  Future<Uint8List?> read(String documentId) => _cache.read(documentId);
  Future<void> write(String documentId, Uint8List bytes) =>
      _cache.write(documentId, bytes);
  Future<void> delete(String documentId) => _cache.delete(documentId);
}
