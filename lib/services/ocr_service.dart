import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/reflow_builder.dart';
import '../utils/text_join.dart';

/// Reading the text off a picture of a page — a DjVu scan without a text
/// layer, a PDF that is only page images, a page whose fonts garbled their
/// text — so the compact view has words to reflow, tap and translate.
///
/// On the device, with no network: Google ML Kit's text recognizer. It reads
/// Latin script (English, German, French, Spanish, Italian, Polish and every
/// other language written in it), Chinese, Japanese, Korean and Devanagari.
/// It does not read Cyrillic, Greek or Arabic script — asked to, it returns
/// Latin lookalikes, which is worse than nothing — so a book in one of those
/// shows its page instead.

/// One paragraph read off a page, and where on the page image it was.
class OcrParagraph {
  const OcrParagraph({
    required this.text,
    required this.top,
    required this.bottom,
  });

  final String text;

  /// In pixels of the image it was read from.
  final double top;
  final double bottom;

  Map<String, dynamic> toJson() => {'t': text, 'y0': top, 'y1': bottom};

  factory OcrParagraph.fromJson(Map<String, dynamic> json) => OcrParagraph(
    text: json['t'] as String,
    top: (json['y0'] as num).toDouble(),
    bottom: (json['y1'] as num).toDouble(),
  );
}

/// What reads the text: ML Kit in the app, a stand-in in tests.
abstract class OcrEngine {
  /// Whether this engine can read text in [languageCode] (BCP-47).
  bool supports(String languageCode);

  /// The paragraphs of the page in [image] (PNG or JPEG), in reading
  /// order.
  Future<List<OcrParagraph>> recognize(
    Uint8List image, {
    required String languageCode,
  });
}

/// [OcrEngine] over ML Kit's on-device text recognizer.
class MlKitOcrEngine implements OcrEngine {
  final Map<mlkit.TextRecognitionScript, mlkit.TextRecognizer> _recognizers =
      {};

  static mlkit.TextRecognitionScript? _scriptFor(String languageCode) {
    final language = languageCode.split(RegExp('[-_]')).first.toLowerCase();
    const cyrillicGreekArabicEtc = {
      'ru', 'uk', 'be', 'bg', 'mk', 'sr', 'kk', 'ky', 'tg', 'mn', //
      'el', 'ar', 'fa', 'ur', 'he', 'yi', 'th', 'ka', 'hy', 'ta', 'te', //
      'kn', 'bn', 'gu', 'am',
    };
    if (cyrillicGreekArabicEtc.contains(language)) return null;
    return switch (language) {
      'zh' => mlkit.TextRecognitionScript.chinese,
      'ja' => mlkit.TextRecognitionScript.japanese,
      'ko' => mlkit.TextRecognitionScript.korean,
      'hi' || 'mr' || 'ne' => mlkit.TextRecognitionScript.devanagiri,
      _ => mlkit.TextRecognitionScript.latin,
    };
  }

  @override
  bool supports(String languageCode) => _scriptFor(languageCode) != null;

  @override
  Future<List<OcrParagraph>> recognize(
    Uint8List image, {
    required String languageCode,
  }) async {
    final script = _scriptFor(languageCode);
    if (script == null) return const [];
    final recognizer = _recognizers.putIfAbsent(
      script,
      () => mlkit.TextRecognizer(script: script),
    );
    // The recognizer takes a file (or raw camera frames); a page image goes
    // through a temporary file.
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(dir.path, 'ocr_${DateTime.now().microsecondsSinceEpoch}.img'),
    );
    await file.writeAsBytes(image, flush: true);
    try {
      final result = await recognizer.processImage(
        mlkit.InputImage.fromFilePath(file.path),
      );
      return [
        for (final block in result.blocks)
          if (_paragraphOf(block) case final paragraph?) paragraph,
      ];
    } finally {
      unawaited(file.delete().then((_) {}, onError: (_) {}));
    }
  }

  static OcrParagraph? _paragraphOf(mlkit.TextBlock block) {
    var text = '';
    for (final line in block.lines) {
      final part = line.text.trim();
      if (part.isEmpty) continue;
      text = text.isEmpty ? part : joinLines(text, part);
    }
    if (text.trim().length < 2) return null;
    return OcrParagraph(
      text: text,
      top: block.boundingBox.top,
      bottom: block.boundingBox.bottom,
    );
  }

  void close() {
    for (final recognizer in _recognizers.values) {
      unawaited(recognizer.close());
    }
    _recognizers.clear();
  }
}

/// Pages already read, kept on the phone: a page is read once, ever.
class OcrCache {
  OcrCache._(this._dir);

  final Directory _dir;

  static Future<OcrCache> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'ocr_v1'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return OcrCache._(dir);
  }

  /// A cache in [dir] — for tests.
  @visibleForTesting
  factory OcrCache.at(Directory dir) => OcrCache._(dir);

  File _fileFor(String documentId, int page, String languageCode) =>
      File(p.join(_dir.path, documentId, '${page}_$languageCode.json'));

  Future<({List<OcrParagraph> paragraphs, double imageHeight})?> read(
    String documentId,
    int page,
    String languageCode,
  ) async {
    final file = _fileFor(documentId, page, languageCode);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        paragraphs: [
          for (final entry in json['p'] as List)
            OcrParagraph.fromJson(entry as Map<String, dynamic>),
        ],
        imageHeight: (json['h'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String documentId,
    int page,
    String languageCode,
    List<OcrParagraph> paragraphs,
    double imageHeight,
  ) async {
    final file = _fileFor(documentId, page, languageCode);
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'h': imageHeight,
          'p': [for (final paragraph in paragraphs) paragraph.toJson()],
        }),
      );
    } catch (_) {
      // Only means the page is read again next time.
    }
  }

  Future<void> forget(String documentId) async {
    final dir = Directory(p.join(_dir.path, documentId));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// The paragraphs read off a page as blocks for the compact view, each
/// remembering how far down the page ([imageHeight] pixels tall, shown
/// [pageHeight] points tall) it was.
List<ReflowBlock> ocrBlocks(
  List<OcrParagraph> paragraphs, {
  required double imageHeight,
  required double pageHeight,
}) {
  final scale = imageHeight > 0 ? pageHeight / imageHeight : 1.0;
  return [
    for (final paragraph in paragraphs)
      ReflowBlock.paragraph(
        paragraph.text,
        sourceTop: paragraph.top * scale,
        sourceBottom: paragraph.bottom * scale,
      ),
  ];
}

/// Reads pages one at a time, the page asked for most recently first: the
/// reader turning pages faster than they can be read wants the one in front
/// of them, not the ones they have already passed.
class OcrQueue {
  final List<({Future<void> Function() job, Object key})> _waiting = [];
  bool _running = false;

  void add(Object key, Future<void> Function() job) {
    _waiting.removeWhere((entry) => entry.key == key);
    _waiting.add((job: job, key: key));
    if (!_running) unawaited(_drain());
  }

  Future<void> _drain() async {
    _running = true;
    while (_waiting.isNotEmpty) {
      final next = _waiting.removeLast();
      try {
        await next.job();
      } catch (_) {
        // One page that couldn't be read doesn't stop the others.
      }
    }
    _running = false;
  }

  void clear() => _waiting.clear();
}
