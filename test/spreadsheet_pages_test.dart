import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/spreadsheet_pages.dart';
import 'package:transreade/utils/xlsx_decode.dart';

SpreadsheetSheet sheet(String name, List<List<String>> rows) =>
    SpreadsheetSheet(name: name, rows: rows);

const _threeColumns = [
  ['Товар', 'Цена', 'Дата'],
  ['Ручка', '12', '01.01.2024'],
  ['Тетрадь', '34', '02.01.2024'],
  ['Ластик', '56', '03.01.2024'],
];

void main() {
  group('paging a sheet', () {
    test('cuts a long sheet into pages of the rows that fit', () {
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Лист1', _threeColumns)],
        columnWidths: [
          [60, 40, 70],
        ],
        pageWidth: 1000,
        rowsPerPage: 2,
      );

      expect(pages.map((p) => p.firstRow), [0, 2, 3]);
      expect(pages.map((p) => p.rows.length), [2, 2, 2]);
    });

    test('repeats the header line, inside the page\'s row budget', () {
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Лист1', _threeColumns)],
        columnWidths: [
          [60, 40, 70],
        ],
        pageWidth: 1000,
        rowsPerPage: 2,
      );

      // The later pages spend one of their two rows saying what the columns
      // are, so each carries a single data row.
      expect(pages[0].headerRowCount, 1);
      expect(pages[1].headerRowCount, 1);
      expect(pages[1].rows.first, ['Товар', 'Цена', 'Дата']);
      expect(pages[1].rows.last, ['Тетрадь', '34', '02.01.2024']);
      expect(pages[2].rows.last, ['Ластик', '56', '03.01.2024']);
    });

    test('leaves a short sheet as one page with no repeated header', () {
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Лист1', _threeColumns)],
        columnWidths: [
          [60, 40, 70],
        ],
        pageWidth: 1000,
        rowsPerPage: 10,
      );

      expect(pages, hasLength(1));
      expect(pages.single.headerRowCount, 1);
      expect(pages.single.rows, _threeColumns);
    });

    test('cuts a wide sheet into column groups that fit the page', () {
      final rows = [
        ['A', 'B', 'C', 'D'],
        ['1', '2', '3', '4'],
      ];
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Широкий', rows)],
        columnWidths: [
          [100, 100, 100, 100],
        ],
        pageWidth: 250,
        rowsPerPage: 10,
      );

      expect(pages.map((p) => p.firstColumn), [0, 2]);
      expect(pages[0].rows, [
        ['A', 'B'],
        ['1', '2'],
      ]);
      expect(pages[1].rows, [
        ['C', 'D'],
        ['3', '4'],
      ]);
    });

    test('gives an oversized column a page of its own', () {
      final pages = buildSpreadsheetPages(
        sheets: [
          sheet('Широкий', [
            ['заметка', 'B'],
            ['очень длинный текст', '2'],
          ]),
        ],
        columnWidths: [
          [900, 40],
        ],
        pageWidth: 300,
        rowsPerPage: 10,
      );

      expect(pages.map((p) => p.firstColumn), [0, 1]);
      expect(pages[0].columnCount, 1);
      expect(pages[1].columnCount, 1);
    });

    test('pads a ragged row out to the page\'s columns', () {
      final pages = buildSpreadsheetPages(
        sheets: [
          sheet('Лист1', [
            ['A', 'B', 'C'],
            ['1'],
          ]),
        ],
        columnWidths: [
          [50, 50, 50],
        ],
        pageWidth: 1000,
        rowsPerPage: 10,
      );

      expect(pages.single.rows.last, ['1', '', '']);
    });

    test('reads sheets one after another as a single book', () {
      final pages = buildSpreadsheetPages(
        sheets: [
          sheet('Первый', _threeColumns),
          sheet('Второй', [
            ['x'],
          ]),
        ],
        columnWidths: [
          [60, 40, 70],
          [20],
        ],
        pageWidth: 1000,
        rowsPerPage: 2,
      );

      expect(pages.map((p) => p.sheetName), [
        'Первый',
        'Первый',
        'Первый',
        'Второй',
      ]);
      expect(pages[3].sheetIndex, 1);
    });
  });

  group('a page as search blocks', () {
    test('lists its cells left to right, top to bottom', () {
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Лист1', _threeColumns)],
        columnWidths: [
          [60, 40, 70],
        ],
        pageWidth: 1000,
        rowsPerPage: 2,
      );

      expect(pages[0].blocks, [
        'Товар',
        'Цена',
        'Дата',
        'Ручка',
        '12',
        '01.01.2024',
      ]);
      // The block index of a cell is its position in reading order, which is
      // how the reader turns a search hit back into the cell to wash over.
      expect(pages[1].blocks[1 * pages[1].columnCount + 2], '02.01.2024');
    });

    test('a repeated header is searchable on every page of the group', () {
      final pages = buildSpreadsheetPages(
        sheets: [sheet('Лист1', _threeColumns)],
        columnWidths: [
          [60, 40, 70],
        ],
        pageWidth: 1000,
        rowsPerPage: 2,
      );

      expect(pages[1].blocks.first, 'Товар');
    });
  });

  group('back to the sheet a page came from', () {
    List<SpreadsheetPage> pages() => buildSpreadsheetPages(
      sheets: [sheet('Лист1', _threeColumns)],
      columnWidths: const [
        [60, 40, 70],
      ],
      pageWidth: 1000,
      rowsPerPage: 2,
    );

    test('a block index names the sheet cell behind it', () {
      final all = pages();
      // The second page repeats the header line above its own rows, so its
      // first block is the sheet's first row and its fourth is row 2.
      expect(all[1].cellOf(0), (sheetIndex: 0, row: 0, column: 0));
      expect(all[1].cellOf(3), (sheetIndex: 0, row: 2, column: 0));
      expect(all[1].cellOf(5), (sheetIndex: 0, row: 2, column: 2));
      expect(all[2].cellOf(4), (sheetIndex: 0, row: 3, column: 1));
    });

    test('a cell names the page that shows it', () {
      final all = pages();
      expect(findPageForCell(all, sheetIndex: 0, row: 0, column: 1), 0);
      expect(findPageForCell(all, sheetIndex: 0, row: 2, column: 0), 1);
      expect(findPageForCell(all, sheetIndex: 0, row: 3, column: 2), 2);
      expect(findPageForCell(all, sheetIndex: 1, row: 0, column: 0), isNull);
    });

    test('every cell comes back to a page showing the same text', () {
      final all = pages();
      for (final page in all) {
        for (var block = 0; block < page.blocks.length; block++) {
          // A repeated header stands for the sheet's first row, which the
          // group's own first page shows; that one cell is not this page's.
          if (page.repeatsHeader && block < page.columnCount) continue;
          final cell = page.cellOf(block);
          final index = findPageForCell(
            all,
            sheetIndex: cell.sheetIndex,
            row: cell.row,
            column: cell.column,
          );
          expect(index, isNotNull, reason: '${page.blocks[block]} is lost');
          final back = all[index!];
          final backBlock =
              (cell.row - back.firstRow + (back.repeatsHeader ? 1 : 0)) *
                  back.columnCount +
              (cell.column - back.firstColumn);
          expect(back.blocks[backBlock], page.blocks[block]);
        }
      }
    });
  });

  group('measuring columns', () {
    const style = TextStyle(fontSize: 10);
    const boldStyle = TextStyle(fontSize: 10, fontWeight: FontWeight.w700);

    test('sizes a column to its widest sampled cell', () {
      final widths = measureColumnWidths(
        sheet('Лист1', [
          ['a', 'длинный заголовок'],
          ['bb', 'x'],
        ]),
        style: style,
        boldStyle: boldStyle,
      );

      expect(widths[0], greaterThan(0));
      expect(widths[1], greaterThan(widths[0]));
    });

    test('keeps a narrow column readable and a wide one on the page', () {
      final widths = measureColumnWidths(
        sheet('Лист1', [
          ['', 'a' * 500],
          ['x', ''],
        ]),
        style: style,
        boldStyle: boldStyle,
        minColumnWidth: 44,
        maxColumnWidth: 300,
      );

      expect(widths[0], 44);
      expect(widths[1], 300);
    });

    test('samples a long sheet instead of measuring every row', () {
      final rows = [
        ['header'],
        for (var i = 0; i < 5000; i++) ['${i * i}'],
      ];
      final watch = Stopwatch()..start();
      final widths = measureColumnWidths(
        sheet('Лист1', rows),
        style: style,
        boldStyle: boldStyle,
      );
      watch.stop();

      expect(widths.single, greaterThan(0));
      expect(watch.elapsedMilliseconds, lessThan(500));
    });

    test(
      'sizes a column for its header in the bold style it is painted in',
      () {
        // The header line is the one row a sheet paints heavier than the rest.
        // Measuring it in the body style instead sizes the column for text that
        // is not the text shown, and the header is the first cell to truncate.
        final widths = measureColumnWidths(
          sheet('Лист1', [
            ['Заголовок'],
            ['x'],
          ]),
          style: style,
          boldStyle: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
          maxColumnWidth: 10000,
        );

        expect(widths.single, greaterThan(150));
      },
    );
  });
}
