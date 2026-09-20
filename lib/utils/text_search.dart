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
    required this.pageOccurrenceIndex,
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

  /// This match's position among every match of the same query on this
  /// page (0 = the first one), counted in reading order across blocks.
  ///
  /// The reflow view never needs this — it already has [blockIndex] and
  /// [matchStart]/[matchEnd] to highlight the exact spot. The *original*
  /// PDF view has no such precise reference (it re-locates the query from
  /// scratch in the page's raw word geometry, a different text extraction
  /// entirely), so this is how it tells two matches on the same page apart:
  /// "highlight the Nth occurrence", not just "the first one" every time.
  final int pageOccurrenceIndex;

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
  var occurrenceIndex = 0;
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
          pageOccurrenceIndex: occurrenceIndex,
        ),
      );
      occurrenceIndex++;
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

/// The whole-book text index for one PDF, built once in one or two
/// background isolates and cached. See the note above for why it exists.
///
/// A book with enough pages to be worth it is split into two halves and
/// extracted by two isolates in parallel — the dominant cost is per-page PDF
/// text extraction, which is embarrassingly parallel (one page's extraction
/// never depends on another's), so two isolates roughly halve the wall-clock
/// time on any device with more than one usable core.
class PdfSearchIndex {
  /// Block texts for every page, filled in (possibly out of order, by
  /// whichever worker gets there first) as the isolates work. `null` until a
  /// build has started.
  List<List<String>>? _pages;

  /// Parallel to [_pages]: whether that page has actually been written yet
  /// (an unfilled page's `List<String>` slot isn't otherwise distinguishable
  /// from a real, empty page).
  List<bool> _filled = const [];
  int _filledCount = 0;
  int _totalPages = 0;

  /// Whether [_totalPages] is known yet. Until it is, `isReady` must not
  /// read as true just because nothing has been filled in.
  bool _countKnown = false;

  final List<Isolate> _isolates = [];
  final List<ReceivePort> _ports = [];
  int _pendingWorkers = 0;
  bool _building = false;

  /// The active search, if any: the query being reported and the batch + done
  /// callbacks to fire as more pages finish and once the scan is complete.
  String? _activeQuery;
  void Function(List<SearchMatch> batch)? _activeOnBatch;
  VoidCallback? _activeOnDone;
  final Set<int> _reportedPages = {};

  /// True once every page has been indexed.
  bool get isReady => _countKnown && _filledCount == _totalPages;

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
        _totalPages = cached.length;
        _filled = List<bool>.filled(cached.length, true);
        _filledCount = cached.length;
        _countKnown = true;
        _building = false;
        _reportNewPages();
        _finishActiveSearch();
        return;
      }
    }
    final total = await Isolate.run(() => _pageCount(filePath));
    if (!_building) return; // cancelled while the count was in flight
    _totalPages = total;
    _countKnown = true;
    _pages = List<List<String>>.generate(total, (_) => const []);
    _filled = List<bool>.filled(total, false);
    if (total == 0) {
      _building = false;
      _finishActiveSearch();
      return;
    }
    // Not worth splitting a short book — one isolate's spin-up cost would
    // eat the saving.
    final ranges = total >= 40
        ? [(0, total ~/ 2), (total ~/ 2, total)]
        : [(0, total)];
    _pendingWorkers = ranges.length;
    for (final (start, end) in ranges) {
      final port = ReceivePort();
      _ports.add(port);
      port.listen((message) {
        if (message is Map) {
          final page = message['page'] as int;
          final blocks = (message['blocks'] as List).cast<String>();
          if (page < _pages!.length && !_filled[page]) {
            _pages![page] = blocks;
            _filled[page] = true;
            _filledCount++;
          }
          _reportNewPages();
        } else if (message == 'done') {
          port.close();
          _pendingWorkers--;
          if (_pendingWorkers <= 0) {
            _building = false;
            _isolates.clear();
            _ports.clear();
            _reportNewPages();
            _finishActiveSearch();
            if (documentId != null && cache != null && _pages != null) {
              unawaited(cache.write(documentId, _pages!));
            }
          }
        }
      });
      _isolates.add(
        await Isolate.spawn(_worker, [filePath, port.sendPort, start, end]),
      );
    }
  }

  /// Scans pages that have become newly indexed since the last report for
  /// the active query, streaming any hits. No-op if no search is active.
  void _reportNewPages() {
    final query = _activeQuery;
    final pages = _pages;
    if (query == null || pages == null) return;
    final batch = <SearchMatch>[];
    for (var i = 0; i < _filled.length; i++) {
      if (!_filled[i] || _reportedPages.contains(i)) continue;
      _reportedPages.add(i);
      batch.addAll(_searchPageBlocks(pages[i], query, i));
    }
    if (batch.isNotEmpty) _activeOnBatch?.call(batch);
    if (isReady) _finishActiveSearch();
  }

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
    _reportedPages.clear();
    _reportNewPages();
    if (isReady) _finishActiveSearch();
  }

  /// Cancels any in-flight build and drops the cached index. The reader calls
  /// this in dispose so the isolates and their memory are released.
  Future<void> cancel() async {
    final isolates = _isolates.toList();
    final ports = _ports.toList();
    _isolates.clear();
    _ports.clear();
    _building = false;
    _activeOnDone = null;
    _activeQuery = null;
    _activeOnBatch = null;
    _reportedPages.clear();
    _pages = null;
    _filled = const [];
    _filledCount = 0;
    _totalPages = 0;
    _countKnown = false;
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    for (final port in ports) {
      port.close();
    }
  }

  static Future<int> _pageCount(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      return document.pages.count;
    } finally {
      document.dispose();
    }
  }

  /// The isolate body: extract the block texts of pages `[start, end)` and
  /// send them back one page at a time. Runs entirely off the UI isolate; it
  /// only ever sends plain values.
  static Future<void> _worker(List args) async {
    final filePath = args[0] as String;
    final sendPort = args[1] as SendPort;
    final start = args[2] as int;
    final end = args[3] as int;
    final bytes = await File(filePath).readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      for (var i = start; i < end; i++) {
        sendPort.send({'page': i, 'blocks': _pageBlockTexts(document, i)});
      }
    } finally {
      document.dispose();
    }
    sendPort.send('done');
  }
}

/// Locates the [occurrenceIndex]-th occurrence (0 = first) of [query] in a
/// single PDF page's extracted words and returns its page-space bounding
/// box, or null.
///
/// This exists so the *original* (rasterized) PDF view can drop a highlight
/// rectangle over a search hit: a picture has no live text to style, so the
/// only thing to draw is a box, and the box has to come from the page's real
/// word geometry rather than the reflowed text. [occurrenceIndex] matters
/// whenever a page has more than one hit — without it, every match on the
/// same page would resolve to the same (first) box, and pressing
/// next/previous through them would look like nothing happened.
Rect? findMatchPdfBounds(
  List<TextLine> lines,
  String query,
  Size pageSize,
  int occurrenceIndex,
) {
  final needle = normalizeQuery(query).toLowerCase();
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

  var index = -1;
  var from = 0;
  for (var occ = 0; occ <= occurrenceIndex; occ++) {
    index = haystack.indexOf(needle, from);
    if (index == -1) return null;
    from = index + needle.length;
  }
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
