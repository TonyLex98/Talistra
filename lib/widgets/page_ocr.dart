import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/ocr_service.dart';
import '../utils/reflow_builder.dart';

/// Reading one book's pages by OCR for its compact view: cached pages come
/// straight from the phone, the rest are rendered and read one at a time,
/// the page the reader is on first.
class PageOcr {
  PageOcr({
    required this.engine,
    required this.cache,
    required this.documentId,
    required this.languageCode,
  });

  final OcrEngine engine;
  final OcrCache cache;
  final String documentId;
  final String languageCode;

  final OcrQueue _queue = OcrQueue();
  final Set<int> _asked = {};
  bool _cancelled = false;

  /// Whether this book's language can be read at all.
  bool get available => engine.supports(languageCode);

  /// Reads page [page] once: [render] draws it ([height] pixels tall), and
  /// [done] is given its text as blocks — nothing, when there was none.
  void read({
    required int page,
    required double pageHeight,
    required Future<({Uint8List bytes, double height})?> Function() render,
    required void Function(List<ReflowBlock> blocks) done,
  }) {
    if (!available || !_asked.add(page)) return;
    _queue.add(page, () async {
      if (_cancelled) return;
      final cached = await cache.read(documentId, page, languageCode);
      if (cached != null) {
        if (!_cancelled) {
          done(
            ocrBlocks(
              cached.paragraphs,
              imageHeight: cached.imageHeight,
              pageHeight: pageHeight,
            ),
          );
        }
        return;
      }
      final image = await render();
      if (image == null || _cancelled) {
        _asked.remove(page);
        return;
      }
      final paragraphs = await engine.recognize(
        image.bytes,
        languageCode: languageCode,
      );
      await cache.write(
        documentId,
        page,
        languageCode,
        paragraphs,
        image.height,
      );
      if (_cancelled) return;
      done(
        ocrBlocks(
          paragraphs,
          imageHeight: image.height,
          pageHeight: pageHeight,
        ),
      );
    });
  }

  void cancel() {
    _cancelled = true;
    _queue.clear();
  }
}

/// The OCR for [documentId] in [languageCode], from the app's engine and
/// cache — or null where they aren't provided (a test that doesn't need
/// them).
PageOcr? pageOcrFor(
  BuildContext context, {
  required String documentId,
  required String languageCode,
}) {
  try {
    return PageOcr(
      engine: context.read<OcrEngine>(),
      cache: context.read<OcrCache>(),
      documentId: documentId,
      languageCode: languageCode,
    );
  } on ProviderNotFoundException {
    return null;
  }
}
