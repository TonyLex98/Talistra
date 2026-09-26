import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/spreadsheet_pages.dart';

ReflowBlock _block(String text) => ReflowBlock.paragraph(text);

SpreadsheetPage _page({
  required int firstRow,
  required List<List<String>> rows,
  bool repeatsHeader = false,
}) => SpreadsheetPage(
  sheetIndex: 0,
  sheetName: 'Sheet1',
  firstRow: firstRow,
  firstColumn: 0,
  rows: rows,
  headerRowCount: repeatsHeader ? 1 : 0,
  repeatsHeader: repeatsHeader,
);

void main() {
  group('reflowed text', () {
    test('a page joins its blocks with a blank line between them', () {
      expect(
        reflowBlocksText([_block('First paragraph.'), _block('Second.')]),
        'First paragraph.\n\nSecond.',
      );
    });

    test('images, rules and blank blocks contribute nothing', () {
      expect(
        reflowBlocksText([
          _block('Real text.'),
          ReflowBlock.image(const Rect.fromLTWH(0, 0, 10, 10)),
          _block('   '),
        ]),
        'Real text.',
      );
    });

    test('a book keeps its pages apart', () {
      expect(
        reflowPagesText([
          [_block('one')],
          [],
          [_block('two')],
        ]),
        'one\n\ntwo',
      );
    });

    test('the same holds for pages cached as plain text', () {
      expect(
        reflowPageTexts([
          ['a', '', 'b'],
          ['c'],
        ]),
        'a\n\nb\n\nc',
      );
    });
  });

  group('spreadsheet text', () {
    test('a page keeps its grid: a row per line, a cell per tab', () {
      expect(
        _page(
          firstRow: 0,
          rows: [
            ['Name', 'Qty'],
            ['Salt', ''],
          ],
        ).text,
        'Name\tQty\nSalt\t',
      );
    });

    test(
      'a whole book reads the repeated header once, where it is first shown',
      () {
        final pages = [
          _page(
            firstRow: 0,
            rows: [
              ['Name', 'Qty'],
              ['Salt', '1'],
            ],
          ),
          _page(
            firstRow: 2,
            repeatsHeader: true,
            rows: [
              ['Name', 'Qty'],
              ['Pepper', '2'],
            ],
          ),
        ];
        expect(pages.first.text, 'Name\tQty\nSalt\t1');
        expect(spreadsheetPagesText(pages), 'Name\tQty\nSalt\t1\n\nPepper\t2');
      },
    );

    test('a column group that starts again shows its own header', () {
      expect(
        spreadsheetPagesText([
          _page(
            firstRow: 0,
            repeatsHeader: true,
            rows: [
              ['Price'],
              ['10'],
            ],
          ),
        ]),
        'Price\n10',
      );
    });

    test('empty pages are left out', () {
      expect(
        spreadsheetPagesText([
          _page(
            firstRow: 0,
            rows: [
              ['', ''],
            ],
          ),
          _page(
            firstRow: 1,
            rows: [
              ['x'],
            ],
          ),
        ]),
        'x',
      );
    });
  });
}
