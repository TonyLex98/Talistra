import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/services/ocr_service.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/widgets/page_ocr.dart';

class _FakeEngine implements OcrEngine {
  int calls = 0;

  @override
  bool supports(String languageCode) => languageCode != 'ru';

  @override
  Future<List<OcrParagraph>> recognize(
    Uint8List image, {
    required String languageCode,
  }) async {
    calls++;
    return const [
      OcrParagraph(text: 'The first paragraph.', top: 100, bottom: 300),
      OcrParagraph(text: 'The second one.', top: 400, bottom: 500),
    ];
  }
}

void main() {
  late Directory dir;
  late _FakeEngine engine;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('talistra_ocr');
    engine = _FakeEngine();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  PageOcr ocr(String language) => PageOcr(
    engine: engine,
    cache: OcrCache.at(dir),
    documentId: 'book',
    languageCode: language,
  );

  Future<List<ReflowBlock>> read(PageOcr ocr, {int page = 0}) {
    final result = <List<ReflowBlock>>[];
    ocr.read(
      page: page,
      pageHeight: 800,
      render: () async => (bytes: Uint8List(4), height: 1000.0),
      done: result.add,
    );
    return Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return result.isEmpty;
    }).then((_) => result.single);
  }

  test('a page is read into blocks that know where they were', () async {
    final blocks = await read(ocr('en'));
    expect(blocks.map((b) => b.text), [
      'The first paragraph.',
      'The second one.',
    ]);
    // 1000 px of image shown as 800 pt of page.
    expect(blocks.first.sourceTop, 80);
    expect(blocks.first.sourceBottom, 240);
  });

  test('a page read once is never read again', () async {
    await read(ocr('en'));
    await read(ocr('en'));
    expect(engine.calls, 1);
  });

  test('a language the engine can\'t read is not tried', () async {
    final russian = ocr('ru');
    expect(russian.available, isFalse);
    var done = false;
    russian.read(
      page: 0,
      pageHeight: 800,
      render: () async => (bytes: Uint8List(4), height: 1000.0),
      done: (_) => done = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(done, isFalse);
    expect(engine.calls, 0);
  });

  test('ML Kit reads Latin and CJK scripts, not Cyrillic', () {
    final engine = MlKitOcrEngine();
    for (final code in ['en', 'de', 'fr', 'es', 'pl', 'zh', 'ja', 'ko']) {
      expect(engine.supports(code), isTrue, reason: code);
    }
    for (final code in ['ru', 'uk', 'el', 'ar']) {
      expect(engine.supports(code), isFalse, reason: code);
    }
  });
}
