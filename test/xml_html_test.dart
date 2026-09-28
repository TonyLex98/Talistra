import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/document_format.dart';
import 'package:transreade/utils/ebook_text.dart';
import 'package:transreade/utils/text_decode.dart';

Uint8List _utf16le(String text, {bool bom = true}) {
  final bytes = <int>[
    if (bom) ...[0xFF, 0xFE],
  ];
  for (final unit in text.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return Uint8List.fromList(bytes);
}

const _xml = '''<?xml version="1.0" encoding="utf-8"?>
<library>
  <book id="1" lang="en">
    <title>The Hobbit</title>
    <author>J. R. R. Tolkien</author>
    <summary><![CDATA[A hobbit goes <there> and back again.]]></summary>
  </book>
</library>''';

void main() {
  test('an XML file is recognised by its name or by its header', () {
    final bytes = Uint8List.fromList(utf8.encode(_xml));
    expect(detectDocumentFormatBytes(bytes, fileName: 'catalog.xml'), 'xml');
    expect(detectDocumentFormatBytes(bytes, fileName: 'catalog'), 'xml');
  });

  test('UTF-16 XML — what Windows writes — is text, not binary', () {
    for (final bom in [true, false]) {
      final bytes = _utf16le(_xml, bom: bom);
      expect(
        detectDocumentFormatBytes(bytes, fileName: 'export.xml'),
        'xml',
        reason: 'bom: $bom',
      );
      expect(decodeTextFile(bytes), _xml);
    }
  });

  test('an FB2 saved as .xml is still read as a book', () {
    final bytes = Uint8List.fromList(
      utf8.encode('<?xml version="1.0"?><FictionBook><body/></FictionBook>'),
    );
    expect(detectDocumentFormatBytes(bytes, fileName: 'book.xml'), 'fb2');
  });

  test('XML reads as its tree: names bold, text readable', () {
    final blocks = extractEbookBlocks(
      Uint8List.fromList(utf8.encode(_xml)),
      EbookFormat.xml,
    );
    expect(blocks.map((b) => (b.indent, b.text)), [
      (0, 'library'),
      (1, 'book (id="1", lang="en")'),
      (2, 'title: The Hobbit'),
      (2, 'author: J. R. R. Tolkien'),
      (2, 'summary: A hobbit goes <there> and back again.'),
    ]);
    final title = blocks[2];
    final bold = title.formatRuns.single;
    expect(title.text.substring(bold.start, bold.end), 'title');
  });

  test('broken XML is shown as it is rather than refused', () {
    final blocks = extractEbookBlocks(
      Uint8List.fromList(utf8.encode('<a><b>unclosed</a>')),
      EbookFormat.xml,
    );
    expect(blocks.single.isCode, isTrue);
    expect(blocks.single.text, '<a><b>unclosed</a>');
  });

  test('an HTML page reads like a book chapter', () {
    const html =
        '<!DOCTYPE html><html><head><title>t</title></head><body>'
        '<h1>Заголовок</h1><p>Текст <em>важный</em>.</p></body></html>';
    final bytes = Uint8List.fromList(utf8.encode(html));
    expect(detectDocumentFormatBytes(bytes, fileName: 'page.htm'), 'html');
    expect(detectDocumentFormatBytes(bytes, fileName: 'saved'), 'html');
    final blocks = extractEbookBlocks(bytes, EbookFormat.html);
    expect(blocks.first.headingLevel, 1);
    expect(blocks.last.text, 'Текст важный.');
    expect(blocks.last.formatRuns.single.italic, isTrue);
  });
}
