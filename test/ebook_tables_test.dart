import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/ebook_blocks.dart';
import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/reflow_table.dart';

List<List<String>> _cells(ReflowBlock table) => [
  for (final row in table.tableCells!)
    [for (final cell in row) table.text.substring(cell.start, cell.end)],
];

void main() {
  test('an HTML table is a grid, its <th> row the header', () {
    final blocks = htmlBlocks('''
<html><body>
<p>Before</p>
<table>
  <caption>Prices</caption>
  <thead><tr><th>Item</th><th>Price</th></tr></thead>
  <tbody>
    <tr><td><p>Pen</p><p>blue</p></td><td><b>12</b></td></tr>
    <tr><td>Nested <table><tr><td>inner</td></tr></table></td><td>3</td></tr>
  </tbody>
</table>
<p>After</p>
</body></html>''', (_) => null)!;
    expect(blocks.map((b) => b.text).first, 'Before');
    expect(blocks.map((b) => b.text).last, 'After');
    expect(blocks[1].text, 'Prices');
    final table = blocks[2];
    expect(table.isTable, isTrue);
    expect(table.tableHeader, isTrue);
    expect(_cells(table), [
      ['Item', 'Price'],
      ['Pen blue', '12'],
      ['Nested inner', '3'],
    ]);
    final bold = table.formatRuns
        .where((run) => run.bold)
        .map((run) => table.text.substring(run.start, run.end));
    expect(bold, containsAll(['Item', 'Price', '12']));
  });

  test('an FB2 table is a grid too', () {
    const fb2 = '''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <body><section>
    <table>
      <tr><th>a</th><th>b</th></tr>
      <tr><td>1</td><td>2</td></tr>
    </table>
  </section></body>
</FictionBook>''';
    final blocks = fb2Blocks(
      Uint8List.fromList(utf8.encode(fb2)),
      (bytes) => utf8.decode(bytes),
    );
    final table = blocks.singleWhere((b) => b.isTable);
    expect(table.tableHeader, isTrue);
    expect(_cells(table), [
      ['a', 'b'],
      ['1', '2'],
    ]);
  });

  test('a Word table is a grid, in its place among the paragraphs', () {
    const docx = '''<w:document xmlns:w="w"><w:body>
<w:p><w:r><w:t>Before</w:t></w:r></w:p>
<w:tbl>
  <w:tblPr/>
  <w:tr><w:trPr><w:tblHeader/></w:trPr>
    <w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>Age</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:p><w:r><w:t>Ann</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>30</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
<w:p><w:r><w:t>After</w:t></w:r></w:p>
</w:body></w:document>''';
    final blocks = docxBlocks(docx);
    expect(blocks.map((b) => b.isTable), [false, true, false]);
    expect(blocks.first.text, 'Before');
    expect(blocks.last.text, 'After');
    expect(blocks[1].tableHeader, isTrue);
    expect(_cells(blocks[1]), [
      ['Name', 'Age'],
      ['Ann', '30'],
    ]);
  });

  test('a long table is cut into pieces, each with its header', () {
    final table = reflowTable([
      [
        (text: 'Name', runs: const <FormatRun>[]),
        (text: 'Value', runs: const <FormatRun>[]),
      ],
      for (var i = 0; i < 100; i++)
        [
          (text: 'row $i', runs: const <FormatRun>[]),
          (text: 'value $i', runs: const <FormatRun>[]),
        ],
    ]);
    final pieces = splitReflowTable(table, 300);
    expect(pieces.length, greaterThan(1));
    final rows = <String>[];
    for (final piece in pieces) {
      final cells = _cells(piece);
      expect(cells.first, ['Name', 'Value']);
      expect(piece.tableHeader, isTrue);
      final headerBold = piece.formatRuns.where((run) => run.bold).length;
      expect(headerBold, 2);
      rows.addAll(cells.skip(1).map((row) => row.first));
    }
    expect(rows, [for (var i = 0; i < 100; i++) 'row $i']);
    expect(pieces.skip(1).every((piece) => piece.gapAbove == 0), isTrue);
  });
}
