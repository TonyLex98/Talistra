import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/utils/page_rotation.dart';
import 'package:transreade/utils/sentence_finder.dart';

Future<PdfDocument> _rotated(PdfPageRotateAngle angle) async {
  final doc = PdfDocument();
  doc.pageSettings.size = const Size(600, 800);
  doc.pageSettings.margins.all = 0;
  doc.pages.add().graphics.drawString(
    'TOPLEFT',
    PdfStandardFont(PdfFontFamily.helvetica, 20),
    bounds: const Rect.fromLTWH(10, 10, 200, 30),
  );
  final loaded = PdfDocument(inputBytes: await doc.save());
  doc.dispose();
  loaded.pages[0].rotation = angle;
  final bytes = await loaded.save();
  loaded.dispose();
  return PdfDocument(inputBytes: bytes);
}

void main() {
  test('an unrotated page is left as it is', () async {
    final doc = await _rotated(PdfPageRotateAngle.rotateAngle0);
    expect(displayPageSize(doc.pages[0]), const Size(600, 800));
    final line = extractPageLines(doc, 0).single;
    expect(line.bounds.left, closeTo(10, 0.5));
    doc.dispose();
  });

  test(
    'a page shown turned a quarter is measured the way it is shown',
    () async {
      final doc = await _rotated(PdfPageRotateAngle.rotateAngle90);
      expect(displayPageSize(doc.pages[0]), const Size(800, 600));
      final line = extractPageLines(doc, 0).single;
      // The content's top-left corner is the shown page's top-right.
      expect(line.bounds.right, closeTo(800 - 13.6, 0.5));
      expect(line.bounds.top, closeTo(10, 0.5));
      expect(line.bounds.height, closeTo(90, 0.5));
      for (final word in line.wordCollection) {
        expect(line.bounds.inflate(0.5).contains(word.bounds.center), isTrue);
      }
      doc.dispose();
    },
  );

  test('every turn keeps a rectangle inside the shown page', () {
    const size = Size(600, 800);
    const rect = Rect.fromLTRB(10, 20, 110, 60);
    expect(
      rotateToDisplay(rect, size, 2),
      const Rect.fromLTRB(490, 740, 590, 780),
    );
    expect(
      rotateToDisplay(rect, size, 3),
      const Rect.fromLTRB(20, 490, 60, 590),
    );
    for (var turns = 0; turns < 4; turns++) {
      final shown = turns.isOdd ? const Size(800, 600) : size;
      final r = rotateToDisplay(rect, size, turns);
      expect((Offset.zero & shown).contains(r.topLeft), isTrue);
      expect(r.width * r.height, closeTo(rect.width * rect.height, 1e-6));
    }
  });
}
