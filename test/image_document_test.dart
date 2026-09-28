import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:transreade/services/image_document.dart';
import 'package:transreade/utils/document_format.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A JPEG header carrying nothing but an EXIF block with [orientation].
Uint8List _jpegWithOrientation(int orientation, {bool littleEndian = true}) {
  final tiff = BytesBuilder();
  final endian = littleEndian ? Endian.little : Endian.big;
  final header = ByteData(8)
    ..setUint16(0, littleEndian ? 0x4949 : 0x4D4D)
    ..setUint16(2, 42, endian)
    ..setUint32(4, 8, endian);
  tiff.add(header.buffer.asUint8List());
  final directory = ByteData(2 + 12 + 4)
    ..setUint16(0, 1, endian)
    ..setUint16(2, 0x0112, endian)
    ..setUint16(4, 3, endian)
    ..setUint32(6, 1, endian)
    ..setUint16(10, orientation, endian);
  tiff.add(directory.buffer.asUint8List());
  final exif = [...'Exif'.codeUnits, 0, 0, ...tiff.takeBytes()];
  final length = exif.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8, //
    0xFF, 0xE1, length >> 8, length & 0xFF, ...exif,
    0xFF, 0xDA, 0, 2,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pictures are recognised by their signatures, not their names',
    () async {
      final png = await _png(4, 4);
      expect(detectDocumentFormatBytes(png, fileName: 'scan.txt'), 'png');
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]),
          fileName: 'photo',
        ),
        'jpg',
      );
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList([
            ...'RIFF'.codeUnits,
            0,
            0,
            0,
            0,
            ...'WEBPVP8 '.codeUnits,
          ]),
          fileName: 'a.webp',
        ),
        'webp',
      );
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList('GIF89a......'.codeUnits),
          fileName: 'a.gif',
        ),
        'gif',
      );
      // "BM" at the start of a text file is not a bitmap.
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList('BMW owners manual, chapter one.'.codeUnits),
          fileName: 'bmw.txt',
        ),
        'txt',
      );
    },
  );

  test("a JPEG's EXIF orientation is read in either byte order", () {
    expect(jpegOrientation(_jpegWithOrientation(6)), 6);
    expect(jpegOrientation(_jpegWithOrientation(3, littleEndian: false)), 3);
    expect(
      jpegOrientation(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])),
      1,
    );
  });

  test('a picture becomes a PDF of one page its own shape', () async {
    final pdf = await imageToPdf(await _png(400, 200));
    final document = PdfDocument(inputBytes: pdf);
    try {
      expect(document.pages.count, 1);
      final size = document.pages[0].size;
      expect(size.width, closeTo(300, 1));
      expect(size.height, closeTo(150, 1));
      expect(document.pages[0].rotation, PdfPageRotateAngle.rotateAngle0);
    } finally {
      document.dispose();
    }
  });

  test('a tall picture keeps its shape too', () async {
    final document = PdfDocument(
      inputBytes: await imageToPdf(await _png(200, 400)),
    );
    try {
      expect(document.pages[0].size.width, closeTo(150, 1));
      expect(document.pages[0].size.height, closeTo(300, 1));
    } finally {
      document.dispose();
    }
  });

  test('several pictures are a page each, each its own shape', () async {
    final document = PdfDocument(
      inputBytes: await imagesToPdf([
        await _png(400, 200),
        await _png(100, 300),
      ]),
    );
    try {
      expect(document.pages.count, 2);
      expect(document.pages[0].size.width, closeTo(300, 1));
      expect(document.pages[0].size.height, closeTo(150, 1));
      expect(document.pages[1].size.width, closeTo(75, 1));
      expect(document.pages[1].size.height, closeTo(225, 1));
    } finally {
      document.dispose();
    }
  });

  test('names are ordered the way pages are counted', () {
    final names = ['p10.jpg', 'p2.jpg', 'P1.jpg', 'cover.jpg'];
    names.sort(compareNaturally);
    expect(names, ['cover.jpg', 'P1.jpg', 'p2.jpg', 'p10.jpg']);
  });

  test('something that is not a picture is refused', () async {
    await expectLater(
      imageToPdf(Uint8List.fromList('hello'.codeUnits)),
      throwsFormatException,
    );
  });
}
