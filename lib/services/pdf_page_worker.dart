import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../utils/page_rotation.dart';
import '../utils/reflow_builder.dart';
import '../utils/sentence_finder.dart';

/// What the compact view needs of one PDF page: its text as blocks, and how
/// wide the page's text runs (the yardstick its figures are sized against).
class PdfPageData {
  const PdfPageData({
    required this.blocks,
    required this.columnWidth,
    required this.hasText,
  });

  final List<ReflowBlock> blocks;

  /// In PDF points.
  final double columnWidth;

  /// Whether the page had any text at all — false for a scan, or a page whose
  /// fonts garbled it (see `text_repair.dart`), which only OCR can read.
  final bool hasText;
}

/// Page [pageIndex] (0-based) of [document] as the compact view needs it.
/// Slow: this is the work [PdfPageWorker] takes off the UI isolate.
PdfPageData readPdfPage(PdfDocument document, int pageIndex) {
  final lines = extractPageLines(document, pageIndex);
  final pageSize = displayPageSize(document.pages[pageIndex]);
  return PdfPageData(
    blocks: buildReflowPageBlocks(lines, pageSize),
    columnWidth: pdfTextColumnWidth(lines, pageSize),
    hasText: lines.isNotEmpty,
  );
}

/// How wide the page's text runs, in PDF points: the yardstick a figure's
/// width is measured against, so a figure half as wide as the text on its
/// page is half as wide as the reflowed text.
double pdfTextColumnWidth(List<TextLine> lines, Size pageSize) {
  var left = double.infinity;
  var right = -double.infinity;
  for (final line in lines) {
    if (line.text.trim().length < 3) continue;
    left = math.min(left, line.bounds.left);
    right = math.max(right, line.bounds.right);
  }
  final width = right - left;
  // No text to measure against (a scan, a full-page plate): the page.
  if (!width.isFinite || width < pageSize.width * 0.3) return pageSize.width;
  return width;
}

/// Reads a PDF's pages on an isolate of their own.
///
/// Getting the text out of a page — extracting its lines, repairing the ones
/// a font garbled, working out its paragraphs and figures — takes tens of
/// milliseconds on a desktop and several times that on a phone, and on the
/// UI isolate every page turned to paid it before the page could be shown.
/// Here it costs the UI nothing: the worker keeps its own copy of the
/// document open and answers page by page with plain data.
class PdfPageWorker {
  PdfPageWorker._(this._isolate, this._commands, this._results);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _results;
  final Map<int, Completer<PdfPageData?>> _pending = {};
  int _nextId = 0;
  bool _closed = false;

  /// Files bigger than this are not opened a second time in memory: the copy
  /// would cost more than the smoothness is worth.
  static const int maxFileBytes = 150 * 1024 * 1024;

  /// Whether the worker is gone (closed, or crashed). Its pages are then read
  /// on the calling isolate as they always were.
  bool get isClosed => _closed;

  /// Starts a worker on the PDF at [path]. Completes once the worker has the
  /// document open — or with null if it can't (a file too big to be copied,
  /// a document that won't open twice).
  static Future<PdfPageWorker?> spawn(
    String path, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final results = ReceivePort();
    Isolate? isolate;
    try {
      if (await File(path).length() > maxFileBytes) {
        results.close();
        return null;
      }
      final handshake = Completer<SendPort?>();
      SendPort? commands;
      PdfPageWorker? worker;
      results.listen((message) {
        final started = worker;
        if (started != null) {
          started._onMessage(message);
          return;
        }
        if (message is SendPort) {
          commands = message;
        } else if (!handshake.isCompleted) {
          handshake.complete(message == 'ready' ? commands : null);
        }
      });
      isolate = await Isolate.spawn<(SendPort, String)>(_workerMain, (
        results.sendPort,
        path,
      ), onExit: results.sendPort);
      final port = await handshake.future.timeout(
        timeout,
        onTimeout: () => null,
      );
      if (port == null) {
        isolate.kill(priority: Isolate.immediate);
        results.close();
        return null;
      }
      return worker = PdfPageWorker._(isolate, port, results);
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      results.close();
      return null;
    }
  }

  /// Page [pageIndex] (0-based) as blocks, or null if it couldn't be read.
  Future<PdfPageData?> read(int pageIndex) {
    if (_closed) return Future.value(null);
    final id = _nextId++;
    final completer = Completer<PdfPageData?>();
    _pending[id] = completer;
    _commands.send([id, pageIndex]);
    return completer.future;
  }

  void _onMessage(Object? message) {
    // The isolate ended — killed, or crashed on something it couldn't read.
    if (message == null) {
      _shutDown();
      return;
    }
    if (message is! List || message.length < 4) return;
    final completer = _pending.remove(message[0] as int);
    if (completer == null) return;
    final blocks = message[1] as List?;
    completer.complete(
      blocks == null
          ? null
          : PdfPageData(
              blocks: blocks.cast<ReflowBlock>(),
              columnWidth: message[2] as double,
              hasText: message[3] as bool,
            ),
    );
  }

  void _shutDown() {
    if (_closed) return;
    _closed = true;
    _results.close();
    final waiting = [..._pending.values];
    _pending.clear();
    for (final completer in waiting) {
      completer.complete(null);
    }
  }

  void close() {
    if (_closed) return;
    _commands.send(null);
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _shutDown();
  }
}

Future<void> _workerMain((SendPort, String) init) async {
  final (replies, path) = init;
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  final PdfDocument document;
  try {
    document = PdfDocument(inputBytes: await File(path).readAsBytes());
  } catch (_) {
    replies.send('failed');
    return;
  }
  replies.send('ready');
  await for (final message in commands) {
    if (message is! List) break;
    final id = message[0] as int;
    try {
      final data = readPdfPage(document, message[1] as int);
      replies.send([id, data.blocks, data.columnWidth, data.hasText]);
    } catch (_) {
      // One page that can't be read doesn't end the others.
      replies.send([id, null, 0.0, false]);
    }
  }
  document.dispose();
  commands.close();
}
