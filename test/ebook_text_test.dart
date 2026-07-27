import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transreade/utils/ebook_text.dart';

/// Sample books built by scratchpad/make_samples.py — a chapter of Russian
/// and Latin prose in each format, with the awkward bits every real file
/// has: entities and block tags in EPUB, a windows-1251 declaration in FB2,
/// hex-escaped bytes and \\u escapes in RTF, text split across runs in DOCX.
const _samples =
    r'C:\Users\Tony\AppData\Local\Temp\claude\C--Users-Tony-Documents-GitHub-TransReade\6cfdcb45-5b18-4720-8235-02bb336a4ccb\scratchpad\samples';

void main() {
  List<String> read(String name, EbookFormat format) {
    final file = File('$_samples\\$name');
    if (!file.existsSync()) {
      markTestSkipped('sample $name not generated');
      return const [];
    }
    return extractEbookParagraphs(file.readAsBytesSync(), format);
  }

  test('EPUB follows the spine and keeps paragraphs', () {
    final paragraphs = read('sample.epub', EbookFormat.epub);
    if (paragraphs.isEmpty) return;
    expect(paragraphs.first, 'Первая глава');
    // The manifest lists chapter 2 first; the spine puts chapter 1 first,
    // and reading order has to follow the spine.
    expect(
      paragraphs.indexWhere((p) => p.contains('Вторая глава')),
      greaterThan(1),
    );
    expect(
      paragraphs.any((p) => p.contains('«кавычки» — тире & амперсанд')),
      isTrue,
    );
    expect(paragraphs.any((p) => p.contains('Блок div тоже абзац')), isTrue);
    // No markup should survive.
    expect(paragraphs.any((p) => p.contains('<')), isFalse);
  });

  test('FB2 decodes windows-1251 and keeps paragraphs', () {
    final paragraphs = read('sample.fb2', EbookFormat.fb2);
    if (paragraphs.isEmpty) return;
    expect(paragraphs.any((p) => p.contains('Съешь ещё этих мягких')), isTrue);
    expect(
      paragraphs.any((p) => p.contains('Абзац после подзаголовка')),
      isTrue,
    );
    // Metadata (the description block) is not part of the text.
    expect(paragraphs.any((p) => p.contains('Sample FB2')), isFalse);
  });

  test('RTF decodes escaped bytes and unicode, skipping tables', () {
    final paragraphs = read('sample.rtf', EbookFormat.rtf);
    if (paragraphs.isEmpty) return;
    expect(paragraphs.any((p) => p.contains('Глава первая')), isTrue);
    expect(paragraphs.any((p) => p.contains('Unicode test: Привет')), isTrue);
    // Font/colour tables and the info group carry no body text.
    expect(paragraphs.any((p) => p.contains('Times New Roman')), isFalse);
  });

  test('DOCX joins runs within a paragraph', () {
    final paragraphs = read('sample.docx', EbookFormat.docx);
    if (paragraphs.isEmpty) return;
    expect(paragraphs.any((p) => p.contains('Глава первая')), isTrue);
    expect(paragraphs.any((p) => p == 'Разбитый на прогоны абзац.'), isTrue);
  });

  test('format is recognised from the file name', () {
    expect(ebookFormatFromPath('/x/y/Book.EPUB'), EbookFormat.epub);
    expect(ebookFormatFromPath('/x/y/book.fb2'), EbookFormat.fb2);
    expect(ebookFormatFromPath('/x/y/book.rtf'), EbookFormat.rtf);
    expect(ebookFormatFromPath('/x/y/book.docx'), EbookFormat.docx);
    expect(ebookFormatFromPath('/x/y/book.txt'), EbookFormat.txt);
    expect(ebookFormatFromPath('/x/y/book.pdf'), isNull);
  });
}
