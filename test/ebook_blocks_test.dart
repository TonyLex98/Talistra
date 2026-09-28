import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/ebook_text.dart';
import 'package:transreade/utils/image_size.dart';
import 'package:transreade/utils/reflow_builder.dart';

/// A PNG header that says 20×30 pixels — all a book's picture needs for the
/// paginator to give it its room.
Uint8List _png(int width, int height) {
  final bytes = Uint8List(33);
  bytes.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(8, 13);
  bytes.setAll(12, 'IHDR'.codeUnits);
  data.setUint32(16, width);
  data.setUint32(20, height);
  return bytes;
}

const _fb2 = '''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <book-title>Sample FB2</book-title>
      <coverpage><image l:href="#cover.png"/></coverpage>
    </title-info>
  </description>
  <body>
    <title><p>Книга</p></title>
    <epigraph>
      <p>Всё проходит.</p>
      <text-author>Соломон</text-author>
    </epigraph>
    <section>
      <title><p>Глава 1</p><p>Начало</p></title>
      <p>Он сказал <emphasis>тихо</emphasis> и <strong>твёрдо</strong>.<a l:href="#n1" type="note">[1]</a></p>
      <subtitle>* * *</subtitle>
      <poem>
        <stanza>
          <v>Мороз и солнце;</v>
          <v>день чудесный!</v>
        </stanza>
      </poem>
      <empty-line/>
      <image l:href="#pic.png"/>
      <cite><p>Цитата из письма.</p></cite>
    </section>
  </body>
  <body name="notes">
    <section id="n1"><title><p>1</p></title><p>Текст сноски.</p></section>
  </body>
  <binary id="cover.png" content-type="image/png">COVER</binary>
  <binary id="pic.png" content-type="image/png">PIC</binary>
</FictionBook>''';

Uint8List _fb2Bytes() => Uint8List.fromList(
  utf8.encode(
    _fb2
        .replaceFirst('COVER', base64.encode(_png(600, 900)))
        .replaceFirst('PIC', base64.encode(_png(20, 30))),
  ),
);

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _epub() => _zip({
  'mimetype': utf8.encode('application/epub+zip'),
  'META-INF/container.xml': utf8.encode(
    '<?xml version="1.0"?><container><rootfiles>'
    '<rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
  ),
  'OEBPS/content.opf': utf8.encode(
    '<?xml version="1.0"?><package><manifest>'
    '<item id="c2" href="text/two.xhtml"/>'
    '<item id="c1" href="text/one.xhtml"/>'
    '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine>'
    '</package>',
  ),
  'OEBPS/text/one.xhtml': utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>ignored</title>
<style>p { color: red }</style></head>
<body>
  <h1>Первая&nbsp;глава</h1>
  <p>Очень <em>важный</em> и <b>жирный</b> текст &laquo;в&nbsp;кавычках&raquo;.</p>
  <ul><li>один</li><li>два</li></ul>
  <ol start="3"><li>три</li></ol>
  <blockquote><p>Цитата</p></blockquote>
  <p>Строка<br/>вторая строка</p>
  <div><img src="../images/fig.png" alt=""/></div>
  <p>Ссылка на <a href="#x">сноску</a>, &#99999999; не падает.</p>
</body></html>'''),
  'OEBPS/text/two.xhtml': utf8.encode(
    '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
    '<h2>Вторая глава</h2><p>Конец.</p></body></html>',
  ),
  'OEBPS/images/fig.png': _png(40, 20),
});

Uint8List _docx() => _zip({
  'word/document.xml': utf8.encode(
    '<?xml version="1.0"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Глава первая</w:t></w:r></w:p>'
    '<w:p><w:r><w:t xml:space="preserve">Разбитый на </w:t></w:r>'
    '<w:r><w:rPr><w:b/></w:rPr><w:t>прогоны</w:t></w:r>'
    '<w:r><w:rPr><w:i w:val="0"/></w:rPr><w:t xml:space="preserve"> абзац.</w:t></w:r></w:p>'
    '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/></w:numPr></w:pPr><w:r><w:t>пункт</w:t></w:r></w:p>'
    '</w:body></w:document>',
  ),
});

String _runText(ReflowBlock block, FormatRun run) =>
    block.text.substring(run.start, run.end);

void main() {
  group('FB2', () {
    late List<ReflowBlock> blocks;
    setUp(() => blocks = extractEbookBlocks(_fb2Bytes(), EbookFormat.fb2));

    ReflowBlock withText(String text) =>
        blocks.firstWhere((b) => b.text.contains(text));

    test('the cover comes first, and the metadata is not read', () {
      expect(blocks.first.isImage, isTrue);
      expect(blocks.first.imageBounds!.size, const Size(600, 900));
      expect(blocks.any((b) => b.text.contains('Sample FB2')), isFalse);
    });

    test('titles are headings, one per title, at their depth', () {
      expect(withText('Книга').headingLevel, 1);
      final chapter = withText('Глава 1');
      expect(chapter.text, 'Глава 1\nНачало');
      expect(chapter.headingLevel, 2);
    });

    test('verse keeps its lines instead of vanishing', () {
      final stanza = withText('Мороз');
      expect(stanza.text, 'Мороз и солнце;\nдень чудесный!');
      expect(stanza.indent, 1);
    });

    test('emphasis and strong become italic and bold runs', () {
      final paragraph = withText('Он сказал');
      expect(paragraph.text, 'Он сказал тихо и твёрдо.[1]');
      final italic = paragraph.formatRuns.firstWhere((r) => r.italic);
      final bold = paragraph.formatRuns.firstWhere((r) => r.bold);
      expect(_runText(paragraph, italic), 'тихо');
      expect(_runText(paragraph, bold), 'твёрдо');
      final link = paragraph.formatRuns.firstWhere((r) => r.link);
      expect(_runText(paragraph, link), '[1]');
    });

    test('an epigraph and a citation are set in as quotes', () {
      expect(withText('Всё проходит').quoteDepth, 1);
      expect(withText('Соломон').quoteDepth, 1);
      expect(withText('Соломон').formatRuns.single.italic, isTrue);
      expect(withText('Цитата из письма').quoteDepth, 1);
    });

    test('a picture in the text is a picture block', () {
      final pictures = blocks.where((b) => b.isImage).toList();
      expect(pictures.length, 2);
      expect(pictures.last.imageBounds!.size, const Size(20, 30));
    });

    test('the notes follow the story after a rule', () {
      final note = blocks.indexWhere((b) => b.text == 'Текст сноски.');
      final rule = blocks.indexWhere((b) => b.isDivider);
      expect(rule, greaterThan(0));
      expect(note, greaterThan(rule));
    });

    test('a zipped FB2 reads the same', () {
      final zipped = _zip({'book.fb2': _fb2Bytes()});
      expect(
        extractEbookParagraphs(zipped, EbookFormat.fb2),
        extractEbookParagraphs(_fb2Bytes(), EbookFormat.fb2),
      );
    });
  });

  group('EPUB', () {
    late List<ReflowBlock> blocks;
    setUp(() => blocks = extractEbookBlocks(_epub(), EbookFormat.epub));

    ReflowBlock withText(String text) =>
        blocks.firstWhere((b) => b.text.contains(text));

    test('the spine sets the order and headings keep their level', () {
      expect(blocks.first.text, 'Первая глава');
      expect(blocks.first.headingLevel, 1);
      expect(withText('Вторая глава').headingLevel, 2);
      expect(blocks.last.text, 'Конец.');
    });

    test('nothing of the head or the markup is read', () {
      expect(blocks.any((b) => b.text.contains('ignored')), isFalse);
      expect(blocks.any((b) => b.text.contains('color')), isFalse);
      expect(blocks.any((b) => b.text.contains('<')), isFalse);
    });

    test('entities, emphasis and line breaks survive', () {
      final paragraph = withText('Очень');
      expect(paragraph.text, 'Очень важный и жирный текст «в кавычках».');
      expect(
        _runText(paragraph, paragraph.formatRuns.firstWhere((r) => r.italic)),
        'важный',
      );
      expect(
        _runText(paragraph, paragraph.formatRuns.firstWhere((r) => r.bold)),
        'жирный',
      );
      expect(withText('Строка').text, 'Строка\nвторая строка');
    });

    test('lists keep their markers and quotes their depth', () {
      expect(withText('один').text, '• один');
      expect(withText('один').indent, 1);
      expect(withText('три').text, '3. три');
      expect(withText('Цитата').quoteDepth, 1);
    });

    test('a picture is found relative to its chapter', () {
      final picture = blocks.singleWhere((b) => b.isImage);
      expect(picture.imageBounds!.size, const Size(40, 20));
    });

    test('a reference to no character is left as it was written', () {
      expect(withText('Ссылка').text, contains('&#99999999;'));
    });
  });

  group('DOCX', () {
    test('heading styles, runs and list levels come through', () {
      final blocks = extractEbookBlocks(_docx(), EbookFormat.docx);
      expect(blocks[0].text, 'Глава первая');
      expect(blocks[0].headingLevel, 1);
      expect(blocks[1].text, 'Разбитый на прогоны абзац.');
      final bold = blocks[1].formatRuns.single;
      expect(_runText(blocks[1], bold), 'прогоны');
      expect(bold.italic, isFalse);
      expect(blocks[2].text, '• пункт');
      expect(blocks[2].indent, 2);
    });
  });

  group('image sizes', () {
    test('are read off PNG, GIF and JPEG headers', () {
      expect(imageSizeOf(_png(7, 9)), const Size(7, 9));
      final gif = Uint8List.fromList([
        ...'GIF89a'.codeUnits,
        12, 0, 34, 0, //
      ]);
      expect(imageSizeOf(gif), const Size(12, 34));
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, //
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x00, 0xC8, 0x03, //
        0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(imageSizeOf(jpeg), const Size(200, 300));
    });

    test('are null for anything that is not a picture', () {
      expect(imageSizeOf(Uint8List.fromList(utf8.encode('hello'))), isNull);
      expect(imageSizeOf(Uint8List(0)), isNull);
    });
  });
}
