import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:transreade/utils/text_search.dart';

void main() {
  test('a PDF search index is built and finds every hit', () async {
    final dir = await Directory.systemTemp.createTemp('idx');
    final doc = PdfDocument();
    for (var i = 0; i < 3; i++) {
      doc.pages.add().graphics.drawString(
        'Page $i has duplicatewordxyz here.',
        PdfStandardFont(PdfFontFamily.helvetica, 12),
        bounds: const Rect.fromLTWH(20, 20, 400, 30),
      );
    }
    final file = File('${dir.path}/a.pdf')..writeAsBytesSync(await doc.save());
    doc.dispose();
    final index = PdfSearchIndex();
    await index.build(file.path);
    final found = <SearchMatch>[];
    var done = false;
    await index.search('duplicatewordxyz',
        onBatch: found.addAll, onDone: () => done = true);
    await index.done.timeout(const Duration(seconds: 30));
    expect(found.length, 3);
    expect(done, isTrue);
    await dir.delete(recursive: true);
  });
}
