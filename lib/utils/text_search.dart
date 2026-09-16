import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfDocument, TextLine;

import '../services/search_index_cache.dart';
import 'page_words.dart';
import 'reflow_builder.dart';
import 'sentence_finder.dart';
import 'text_join.dart';

/// One place in the book where [query] occurs.
///
/// The location is expressed two ways at once, because the same search has
/// to drive both reading modes of the PDF reader:
///
///  * [blockIndex] + [matchStart]/[matchEnd] are character offsets into one
///    [ReflowBlock]'s own text — that is what the *reflowed* view (PDF
///    reflow, and every text format) highlights, and it is how the reader
///    jumps to the exact sub-page the match sits on.
///  * [pdfBounds] is the same match in PDF page-space (page-local points) —
///    that is what the *original* PDF view draws as an overlay rectangle,
///    since a rasterized page has no live text to style.
///
/// [pdfBounds] is null for formats that have no original page geometry to
/// point at (plain text, e-books) — they only ever read reflowed. It is also
/// null on a hit that comes back from the PDF search isolate before the main
/// thread has had a chance to measure it; the reader fills it in on demand.
class SearchMatch {
  SearchMatch({
    required this.pageIndex,
    required this.blockIndex,
    required this.matchStart,
    required this.matchEnd,
    required this.snippet,
    this.pdfBounds,
  });

  /// Zero-based index of the page (source page) the match is on.
  final int pageIndex;

  /// Which block of that page the match is in.
  final int blockIndex;

  /// [matchStart, matchEnd) inside [ReflowBlock.text] of [blockIndex].
  final int matchStart;
  final int matchEnd;

  /// A short context line centred on the match, for the results list.
  final String snippet;

  /// The match in PDF page-space, for the original view's overlay (null for
  /// text-only formats, and until the reader measures it).
  Rect? pdfBounds;
}

/// Normalizes [query] for searching: the app's own text is already cleaned
/// of extraction artifacts, so the query just needs the same ligature and
/// junk-glyph fixes applied before it can be looked up.
String normalizeQuery(String query) {
  return sanitizeExtractedText(query.trim()).trim();
}

/// Finds every occurrence of [query] in one page's [blocks] (its reflowed
/// block texts, in reading order). Image blocks are skipped (no text).
List<SearchMatch> _searchPageBlocks(
  List<String> blocks,
  String query,
  int page,
) {
  final needle = normalizeQuery(query).toLowerCase();
  if (needle.isEmpty) return const [];
  final matches = <SearchMatch>[];
  for (var block = 0; block < blocks.length; block++) {
    final text = blocks[block];
    if (text.isEmpty) continue;
    final haystack = text.toLowerCase();
    var from = 0;
    while (true) {
      final index = haystack.indexOf(needle, from);
      if (index == -1) break;
      final end = index + needle.length;
      matches.add(
        SearchMatch(
          pageIndex: page,
          blockIndex: block,
          matchStart: index,
          matchEnd: end,
          snippet: _snippet(text, index, end),
        ),
      );
      from = end;
      if (end == index) break;
    }
  }
  return matches;
}

/// Finds every occurrence of [query] across [pages] (a page is its blocks,
/// exactly as the reflowed view lays them out), in reading order. Used by the
/// text formats, whose pages are already in memory — no extraction, no
/// isolate, just a substring scan.
List<SearchMatch> searchInPages(List<List<String>> pages, String query) {
  final needle = normalizeQuery(query).toLowerCase();
  if (needle.isEmpty) return const [];
  final matches = <SearchMatch>[];
  for (var page = 0; page < pages.length; page++) {
    matches.addAll(_searchPageBlocks(pages[page], query, page));
  }
  return matches;
}

/// A short, trimmed context line around [start, end) — enough to recognize
/// where the match is without dumping the whole paragraph into the list.
String _snippet(String text, int start, int end) {
  const width = 44;
  var lo = start - width;
  var hi = end + width;
  if (lo < 0) lo = 0;
  if (hi > text.length) hi = text.length;
  // Nudge the window out to the nearest word boundary so it doesn't start
  // and end mid-word.
  while (lo > 0 && _isLetter(text[lo])) {
    lo--;
  }
  while (hi < text.length && _isLetter(text[hi - 1])) {
    hi++;
  }
  var snippet = text.substring(lo, hi).trim();
  snippet = snippet.replaceAll(RegExp(r'\s+'), ' ');
  return (lo > 0 ? '…' : '') + snippet + (hi < text.length ? '…' : '');
}

final _letterPattern = RegExp(r'\p{L}', unicode: true);
bool _isLetter(String ch) => ch.isNotEmpty && _letterPattern.hasMatch(ch);

/// The work a single page needs before it can be searched: its reflowed
/// block texts, exactly as the reflowed view would lay them out — so a hit's
/// [SearchMatch.blockIndex] still points at the right block for highlighting.
List<String> _pageBlockTexts(PdfDocument document, int index) {
  try {
    final lines = extractPageLines(document, index);
    Size pageSize;
    try {
      pageSize = document.pages[index].size;
    } catch (_) {
      pageSize = Size.zero;
    }
    final blocks = buildReflowPageBlocks(lines, pageSize);
    return blocks.map((b) => b.text).toList();
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// The slow part of a PDF search is extracting + reflowing every page — on a
// 900-page book it takes many seconds to minutes, and it must never run on
// the UI isolate (Android's ANR watchdog fires at ~5s). Crucially it is
// independent of the *query*: the block texts are the same no matter what the
// reader types. So the index is built ONCE, in a background isolate, page by
// page, and kept in memory for the life of the reader. Every subsequent
// search — and every keystroke that re-types the query — is then a plain,
// instant substring scan over the cached strings. That is what makes
// searching feel immediate instead of re-scanning the whole book each time.
//
// The index is started the moment the book opens, so by the time the reader
// reaches for the search field it is (partly) already built. While a build is
// in flight, [search] reports matches from the pages that are done and keeps
// streaming them in as more pages finish; once the build completes it is done.
//
// Only plain values cross the isolate boundary (page index + block-text
// strings), because `dart:ui` geometry cannot be sent; the page-space
// highlight rect is measured on the main isolate afterwards.
// ---------------------------------------------------------------------------

/// The whole-book text index for one PDF, built once in a background isolate
/// and cached. See the note above for why it exists.
class PdfSearchIndex {
  /// Block texts for every page, filled in as the isolate works. `null`
  /// until a build has started; entries are filled in page order.
  List<List<String>>? _pages;

  /// How many pages have been indexed so far (a prefix of [_pages]).
  int _indexed = 0;

  /// Whether the total page count has been reported by the isolate. Until it
  /// has, [_pages] is empty and `_indexed == 0`, which would otherwise make
  /// [_isSearchComplete] read `0 >= 0` as "done" — so a search typed in the
  /// first couple seconds would finish instantly with zero results.
  bool _countKnown = false;

  Isolate? _isolate;
  ReceivePort? _port;
  bool _building = false;

  /// The active search, if any: the query being reported and the batch + done
  /// callbacks to fire as more pages finish and once the scan is complete.
  String? _activeQuery;
  void Function(List<SearchMatch> batch)? _activeOnBatch;
  VoidCallback? _activeOnDone;

  /// True once every page has been indexed.
  bool get isReady => _pages != null && _indexed == _pages!.length;

  /// Starts building the index for [filePath] if it isn't already. Idempotent:
  /// calling it again while a build runs (or after it finished) is a no-op, so
  /// the reader can fire it from both "book opened" and "search opened".
  ///
  /// If [documentId] and [cache] are given, a previously cached index for
  /// this document is used instead of re-extracting the PDF (instant), and a
  /// freshly built index is saved there once done — the file never changes
  /// after import, so the extraction only has to happen once per book, ever.
  Future<void> build(
    String filePath, {
    String? documentId,
    SearchIndexCache? cache,
  }) async {
    if (_building || _pages != null) return;
    _building = true;
    if (documentId != null && cache != null) {
      final cached = await cache.read(documentId);
      if (cached != null) {
        _pages = cached;
        _indexed = cached.length;
        _countKnown = true;
        _building = false;
        _reportNewPages();
        _finishActiveSearch();
        return;
      }
    }
    _pages = <List<String>>[];
    _port = ReceivePort();
    final sendPort = _port!.sendPort;
    _port!.listen((message) {
      if (message is int) {
        _pages!.length = message;
        _countKnown = true;
      } else if (message is Map) {
        final page = message['page'] as int;
        final blocks = (message['blocks'] as List).cast<String>();
        if (page < _pages!.length) _pages![page] = blocks;
        _indexed = page + 1;
        _reportNewPages();
      } else if (message == 'done') {
        _building = false;
        _isolate = null;
        _port?.close();
        _port = null;
        _reportNewPages();
        _finishActiveSearch();
        if (documentId != null && cache != null && _pages != null) {
          unawaited(cache.write(documentId, _pages!));
        }
      }
    });
    _isolate = await Isolate.spawn(_worker, [filePath, sendPort]);
  }

  /// Scans the pages that have become newly indexed since the last report for
  /// the active query, streaming any hits. No-op if no search is active.
  void _reportNewPages() {
    final query = _activeQuery;
    if (query == null || _pages == null) return;
    final pages = _pages!;
    final to = _indexed;
    if (to == 0) return;
    final from = _reportedUpTo;
    if (to <= from) return;
    final batch = <SearchMatch>[];
    for (var i = from; i < to && i < pages.length; i++) {
      batch.addAll(_searchPageBlocks(pages[i], query, i));
    }
    _reportedUpTo = to;
    if (batch.isNotEmpty) _activeOnBatch?.call(batch);
    if (_isSearchComplete()) _finishActiveSearch();
  }

  int _reportedUpTo = 0;

  bool _isSearchComplete() =>
      _pages != null && _countKnown && _indexed >= _pages!.length;

  void _finishActiveSearch() {
    final onDone = _activeOnDone;
    _activeOnDone = null;
    _activeQuery = null;
    _activeOnBatch = null;
    if (onDone != null) onDone();
  }

  /// Runs a search over the index for [query]. Reports already-indexed hits
  /// through [onBatch] (possibly several times, as the build fills in more
  /// pages) and [onDone] once the whole book has been scanned. If the index is
  /// already built this is a single instant scan; if it is still building the
  /// results stream in page by page. [build] must have been called first.
  Future<void> search(
    String query, {
    required void Function(List<SearchMatch> batch) onBatch,
    required void Function() onDone,
  }) async {
    _activeQuery = query;
    _activeOnBatch = onBatch;
    _activeOnDone = onDone;
    _reportedUpTo = 0;
    _reportNewPages();
    if (_isSearchComplete()) _finishActiveSearch();
  }

  /// Cancels any in-flight build and drops the cached index. The reader calls
  /// this in dispose so the isolate and its memory are released.
  Future<void> cancel() async {
    final isolate = _isolate;
    final port = _port;
    _isolate = null;
    _port = null;
    _building = false;
    _activeOnDone = null;
    _activeQuery = null;
    _activeOnBatch = null;
    _pages = null;
    _indexed = 0;
    if (isolate != null) isolate.kill(priority: Isolate.immediate);
    port?.close();
  }

  /// The isolate body: extract every page's block texts and send them back one
  /// page at a time (the page index first, so the receiver can pre-allocate).
  /// Runs entirely off the UI isolate; it only ever sends plain values.
  static Future<void> _worker(List args) async {
    final filePath = args[0] as String;
    final sendPort = args[1] as SendPort;
    final bytes = await File(filePath).readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      final total = document.pages.count;
      sendPort.send(total);
      for (var i = 0; i < total; i++) {
        sendPort.send({'page': i, 'blocks': _pageBlockTexts(document, i)});
      }
    } finally {
      document.dispose();
    }
    sendPort.send('done');
  }
}

/// Locates [query] in a single PDF page's extracted words and returns the
/// page-space bounding box of the first matching run of words, or null.
///
/// This exists so the *original* (rasterized) PDF view can drop a highlight
/// rectangle over a search hit: a picture has no live text to style, so the
/// only thing to draw is a box, and the box has to come from the page's real
/// word geometry rather than the reflowed text.
Rect? findMatchPdfBounds(List<TextLine> lines, String query, Size pageSize) {
  final needle = normalizeQuery(query);
  if (needle.isEmpty) return null;

  final words = buildPageWords(lines);
  if (words.isEmpty) return null;

  // Flatten the page into one lowercased string with each word's start/end
  // recorded, so a multi-word query can be found across word boundaries the
  // same way the text search does.
  final buffer = StringBuffer();
  final wordSpans = <(int start, int end)>[];
  for (var i = 0; i < words.length; i++) {
    final start = buffer.length;
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(words[i].text);
    wordSpans.add((start, buffer.length));
  }
  final haystack = buffer.toString().toLowerCase();
  final index = haystack.indexOf(needle.toLowerCase());
  if (index == -1) return null;
  final end = index + needle.length;

  var bounds = Rect.zero;
  var any = false;
  for (var i = 0; i < words.length; i++) {
    final span = wordSpans[i];
    if (span.$2 <= index || span.$1 >= end) continue;
    final rect = words[i].bounds;
    bounds = any ? bounds.expandToInclude(rect) : rect;
    any = true;
  }
  return any ? bounds.deflate(0.5) : null;
}
