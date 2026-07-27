import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transreade/utils/document_format.dart';

void main() {
  group('document signature detection', () {
    test('recognises DjVu even when the file manager calls it .bin', () {
      final bytes = Uint8List.fromList([
        ...ascii.encode('AT&TFORM'),
        0,
        0,
        0,
        4,
        ...ascii.encode('DJVU'),
      ]);
      expect(
        detectDocumentFormatBytes(bytes, fileName: 'download.bin'),
        'djvu',
      );
    });

    test('does not send arbitrary binary data to a reader', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(128, (index) => index),
      );
      expect(detectDocumentFormatBytes(bytes, fileName: 'broken.pdf'), isNull);
      expect(detectDocumentFormatBytes(bytes, fileName: 'broken.txt'), isNull);
    });

    test('distinguishes EPUB, DOCX and ordinary ZIP by their contents', () {
      expect(_detectZip({'META-INF/container.xml': '<container/>'}), 'epub');
      expect(_detectZip({'word/document.xml': '<w:document/>'}), 'docx');
      expect(_detectZip({'book.txt': 'hello'}), 'zip');
    });

    test('recognises FB2, RTF, PDF and plain text', () {
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList(utf8.encode('<FictionBook><body/></FictionBook>')),
          fileName: 'book.xml',
        ),
        'fb2',
      );
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList(ascii.encode(r'{\rtf1 hello}')),
          fileName: 'book.bin',
        ),
        'rtf',
      );
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList(ascii.encode('%PDF-1.7')),
          fileName: 'book.bin',
        ),
        'pdf',
      );
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList(utf8.encode('A plain UTF-8 book')),
          fileName: 'book.txt',
        ),
        'txt',
      );
    });
  });
}

String? _detectZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return detectDocumentFormatBytes(
    Uint8List.fromList(ZipEncoder().encode(archive)!),
    fileName: 'mystery.bin',
  );
}
