import 'dart:convert';
import 'dart:io';
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

    test('recognises Markdown by every extension it ships under', () {
      for (final name in [
        'notes.md',
        'NOTES.MD',
        'read.markdown',
        'old.mdown',
      ]) {
        expect(
          detectDocumentFormatBytes(
            Uint8List.fromList(utf8.encode('# Notes\n\n- one\n- two')),
            fileName: name,
          ),
          'md',
          reason: name,
        );
      }
      // A Markdown file that is really a picture is still not a book.
      expect(
        detectDocumentFormatBytes(
          Uint8List.fromList([...utf8.encode('# Notes'), 0, 0, 1, 2]),
          fileName: 'notes.md',
        ),
        isNull,
      );
    });
  });

  group('offering an unrecognised file as plain text', () {
    test('accepts prose and CSV whatever extension it carries', () async {
      expect(
        await _looksLikeText('First paragraph.\n\nSecond paragraph.'),
        isTrue,
      );
      expect(await _looksLikeText('name,price\napple,2\npear,5'), isTrue);
    });

    test('accepts a Windows-1251 file that is not valid UTF-8', () async {
      // "Проверка" in CP-1251: no NULs, and the reader decodes it fine.
      final bytes = Uint8List.fromList(const [
        0xcf,
        0xf0,
        0xe5,
        0xe2,
        0xe5,
        0xf0,
        0xea,
        0xe0,
        0x0a,
      ]);
      expect(await fileLooksLikeText(await _write(bytes)), isTrue);
    });

    test('accepts UTF-16, which Windows writes text and XML in', () async {
      final path = await _write(
        Uint8List.fromList([
          0xFF,
          0xFE,
          for (final unit in 'Привет, world!'.codeUnits) ...[
            unit & 0xFF,
            unit >> 8,
          ],
        ]),
      );
      expect(await fileLooksLikeText(path), isTrue);
    });

    test('rejects an empty file', () async {
      expect(await _looksLikeText(''), isFalse);
    });

    test('rejects binary data that happens to contain no NUL bytes', () async {
      // One control byte every 16 bytes: a compressed stream, not a book.
      final bytes = Uint8List.fromList(
        List<int>.generate(
          512,
          (index) => index % 16 == 0 ? 0x01 : 0x41 + index % 26,
        ),
      );
      expect(await fileLooksLikeText(await _write(bytes)), isFalse);
    });
  });
}

Future<bool> _looksLikeText(String content) async =>
    fileLooksLikeText(await _write(utf8.encode(content)));

Directory? _scratchDir;
int _written = 0;

Future<String> _write(List<int> bytes) async {
  final dir = _scratchDir ??= Directory.systemTemp.createTempSync('formats');
  final path = '${dir.path}${Platform.pathSeparator}book-${_written++}.bin';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
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
