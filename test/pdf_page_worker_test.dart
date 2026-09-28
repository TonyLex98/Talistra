import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/services/pdf_page_worker.dart';

late Directory _dir;
late String _path;

/// The first block with words in it: a page's top margin can read as a
/// figure block ahead of them.
String _firstText(PdfPageData data) =>
    data.blocks.firstWhere((block) => block.text.isNotEmpty).text;

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('pdf_worker');
    final document = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.timesRoman, 11);
    for (var p = 0; p < 6; p++) {
      final page = document.pages.add();
      final text = StringBuffer();
      for (var n = 0; n < 4; n++) {
        text
          ..writeln(
            'Page $p paragraph $n. ${'Some words to fill the line. ' * 8}',
          )
          ..writeln();
      }
      page.graphics.drawString(
        text.toString(),
        font,
        bounds: ui.Rect.fromLTWH(
          40,
          40,
          page.getClientSize().width - 80,
          page.getClientSize().height - 80,
        ),
      );
    }
    // A page with nothing on it.
    document.pages.add();
    _path = '${_dir.path}/book.pdf';
    File(_path).writeAsBytesSync(document.saveSync());
    document.dispose();
  });

  tearDownAll(() => _dir.deleteSync(recursive: true));

  test('a worker reads a page the way the calling isolate would', () async {
    final worker = await PdfPageWorker.spawn(_path);
    expect(worker, isNotNull);
    final document = PdfDocument(inputBytes: File(_path).readAsBytesSync());
    try {
      for (final page in [3, 0, 5]) {
        final remote = await worker!.read(page);
        final local = readPdfPage(document, page);
        expect(remote, isNotNull);
        expect(remote!.hasText, local.hasText);
        expect(remote.columnWidth, local.columnWidth);
        expect(
          remote.blocks.map((b) => b.text).toList(),
          local.blocks.map((b) => b.text).toList(),
        );
        expect(
          remote.blocks.map((b) => (b.sourceTop, b.sourceBottom)).toList(),
          local.blocks.map((b) => (b.sourceTop, b.sourceBottom)).toList(),
        );
        expect(_firstText(remote), startsWith('Page $page paragraph 0'));
      }
    } finally {
      document.dispose();
      worker!.close();
    }
  });

  test('a blank page has no text but still comes back', () async {
    final worker = (await PdfPageWorker.spawn(_path))!;
    final blank = await worker.read(6);
    expect(blank, isNotNull);
    expect(blank!.hasText, isFalse);
    worker.close();
  });

  test(
    'several requests at once are each answered with their own page',
    () async {
      final worker = (await PdfPageWorker.spawn(_path))!;
      final answers = await Future.wait([
        for (var p = 0; p < 6; p++) worker.read(p),
      ]);
      for (var p = 0; p < 6; p++) {
        expect(_firstText(answers[p]!), startsWith('Page $p '));
      }
      worker.close();
    },
  );

  test(
    'a page that does not exist is answered with null, not a hang',
    () async {
      final worker = (await PdfPageWorker.spawn(_path))!;
      expect(await worker.read(99), isNull);
      // ...and the worker carries on.
      expect((await worker.read(1))!.blocks, isNotEmpty);
      worker.close();
    },
  );

  test('a closed worker answers null', () async {
    final worker = (await PdfPageWorker.spawn(_path))!;
    worker.close();
    expect(worker.isClosed, isTrue);
    expect(await worker.read(0), isNull);
  });

  test('a file that is not a PDF gives no worker', () async {
    final bad = File('${_dir.path}/bad.pdf')..writeAsStringSync('not a pdf');
    expect(await PdfPageWorker.spawn(bad.path), isNull);
    expect(await PdfPageWorker.spawn('${_dir.path}/missing.pdf'), isNull);
  });
}
