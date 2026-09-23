import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transreade/utils/xlsx_decode.dart';

/// The reader's job is to survive whatever a spreadsheet program actually
/// wrote, so the fixtures here are the ways real writers differ from the
/// spec's most obvious reading: where a sheet's XML lives, whether a cell
/// says which column it is in, and what a number format id means.
void main() {
  group('workbook layout', () {
    test('follows an absolute relationship target (SheetJS, openpyxl)', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c t="inlineStr"><is><t>ok</t></is></c></row>',
            ),
          ],
          absoluteTargets: true,
        ),
      );
      expect(sheets.single.rows, [
        ['ok'],
      ]);
    });

    test('follows a relationship target that walks out of xl/', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c t="inlineStr"><is><t>ok</t></is></c></row>',
            ),
          ],
          relativeDotDot: true,
        ),
      );
      expect(sheets.single.name, 'S1');
      expect(sheets.single.rows.single.single, 'ok');
    });

    test('keeps sheets in workbook order and skips the empty ones', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c t="inlineStr"><is><t>second</t></is></c></row>',
            ),
            _sheetXml('<row r="1"/>'),
            _sheetXml(
              '<row r="1"><c t="inlineStr"><is><t>first</t></is></c></row>',
            ),
          ],
          sheetNames: ['Second', 'Blank', 'First'],
        ),
      );
      expect(sheets.map((sheet) => sheet.name), ['Second', 'First']);
    });

    test('decodes a workbook with no styles part at all', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [_sheetXml('<row r="1"><c><v>12.5</v></c></row>')],
          omitStyles: true,
        ),
      );
      expect(sheets.single.rows.single.single, '12.5');
    });
  });

  group('cell values', () {
    test('reads shared strings, including rich-text runs', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1">'
              '<c r="A1" t="s"><v>0</v></c>'
              '<c r="B1" t="s"><v>1</v></c>'
              '</row>',
            ),
          ],
          sharedStringsXml:
              '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">'
              '<si><r><t>Dear </t></r><r><rPr><b/></rPr><t>Tony</t></r></si>'
              '<si><t>plain</t></si>'
              '</sst>',
        ),
      );
      expect(sheets.single.rows.single, ['Dear Tony', 'plain']);
    });

    test('drops the phonetic runs a Japanese workbook repeats its text in', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [_sheetXml('<row r="1"><c t="s"><v>0</v></c></row>')],
          sharedStringsXml:
              '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<si><t>漢字</t><rPh sb="0" eb="2"><t>かんじ</t></rPh></si>'
              '</sst>',
        ),
      );
      expect(sheets.single.rows.single.single, '漢字');
    });

    test('keeps a cell type other than a number readable', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1">'
              '<c r="A1" t="b"><v>1</v></c>'
              '<c r="B1" t="e"><v>#DIV/0!</v></c>'
              '<c r="C1" t="str"><v>cached formula text</v></c>'
              '<c r="D1" t="s"><v>99</v></c>'
              '</row>',
            ),
          ],
        ),
      );
      // TRUE, the error as written, the formula's cached result — and an out
      // of range shared-string index that must not throw, which leaves the
      // cell blank and so trims off the end of the row.
      expect(sheets.single.rows.single, [
        'TRUE',
        '#DIV/0!',
        'cached formula text',
      ]);
    });

    test('lines cells up by reference when rows and columns have gaps', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c>'
              '<c r="D1" t="inlineStr"><is><t>d</t></is></c></row>'
              '<row r="4"><c r="B4" t="inlineStr"><is><t>b4</t></is></c></row>',
            ),
          ],
        ),
      );
      expect(sheets.single.rows, [
        ['a', '', '', 'd'],
        ['', '', '', ''],
        ['', '', '', ''],
        ['', 'b4', '', ''],
      ]);
    });

    test(
      'counts columns from the previous cell when there are no references',
      () {
        final sheets = decodeXlsx(
          buildXlsx(
            sheetXmls: [
              _sheetXml(
                '<row>'
                '<c t="inlineStr"><is><t>one</t></is></c>'
                '<c t="inlineStr"><is><t>two</t></is></c>'
                '</row>',
              ),
            ],
          ),
        );
        expect(sheets.single.rows.single, ['one', 'two']);
      },
    );
  });

  group('number formats', () {
    test('renders built-in date and time formats', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c r="A1" s="1"><v>45366</v></c>'
              '<c r="B1" s="2"><v>0.6041666666666666</v></c></row>',
            ),
          ],
          stylesXml: _styles(cellXfs: ['0', '14', '21']),
        ),
      );
      expect(sheets.single.rows.single, ['15.03.2024', '14:30']);
    });

    test('renders a date and time together when the value carries both', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c s="1"><v>45366.604166666664</v></c></row>',
            ),
          ],
          stylesXml: _styles(cellXfs: ['0', '14']),
        ),
      );
      expect(sheets.single.rows.single.single, '15.03.2024 14:30');
    });

    test('uses a custom format code even where the spec put a built-in', () {
      // SheetJS files its own formats in 56-63, the range Excel reserves for
      // East-Asian calendars; the code in the file still wins.
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c r="A1" s="1"><v>45366</v></c>'
              '<c r="B1" s="2"><v>0.6041666666666666</v></c>'
              '<c r="C1" s="3"><v>1299.5</v></c></row>',
            ),
          ],
          stylesXml: _styles(
            numFmts: {
              '56': 'dd.mm.yyyy',
              '57': 'hh:mm',
              '164': '#,##0.00 &quot;₽&quot;',
            },
            cellXfs: ['0', '56', '57', '164'],
          ),
        ),
      );
      expect(sheets.single.rows.single, ['15.03.2024', '14:30', '1299.5']);
    });

    test('leaves a plain number exactly as the file wrote it', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [
            _sheetXml(
              '<row r="1"><c r="A1"><v>45000</v></c>'
              '<c r="B1"><v>85.900000000000006</v></c>'
              '<c r="C1"><v>1E+7</v></c></row>',
            ),
          ],
          stylesXml: _styles(cellXfs: ['0']),
        ),
      );
      // The integer keeps the clean literal, the float loses the rounding
      // noise a binary double adds, and scientific notation is left alone.
      expect(sheets.single.rows.single, ['45000', '85.9', '1E+7']);
    });

    test('counts days from 1904 when the workbook says so', () {
      final sheets = decodeXlsx(
        buildXlsx(
          sheetXmls: [_sheetXml('<row r="1"><c s="1"><v>45366</v></c></row>')],
          stylesXml: _styles(cellXfs: ['0', '14']),
          workbookPr: '<workbookPr date1904="1"/>',
        ),
      );
      expect(sheets.single.rows.single.single, '16.03.2028');
    });
  });
}

String _sheetXml(String rows) =>
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<sheetData>$rows</sheetData></worksheet>';

/// A styles part with the given cell styles (`cellXfs`, by numFmtId) and any
/// user-defined format codes.
String _styles({
  List<String> cellXfs = const ['0'],
  Map<String, String> numFmts = const {},
}) {
  return [
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    if (numFmts.isNotEmpty)
      '<numFmts count="${numFmts.length}">${[for (final entry in numFmts.entries) '<numFmt numFmtId="${entry.key}" formatCode="${entry.value}"/>'].join()}</numFmts>',
    '<cellXfs count="${cellXfs.length}">${[for (final id in cellXfs) '<xf numFmtId="$id"/>'].join()}</cellXfs>',
    '</styleSheet>',
  ].join();
}

/// Assembles an .xlsx in memory the way a spreadsheet program would: the
/// parts are real, the relationships are real, and every argument is one of
/// the choices writers actually make differently.
Uint8List buildXlsx({
  required List<String> sheetXmls,
  List<String>? sheetNames,
  String? stylesXml,
  String? sharedStringsXml,
  String workbookPr = '',
  bool absoluteTargets = false,
  bool relativeDotDot = false,
  bool omitStyles = false,
}) {
  const worksheetType =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet';
  String target(int index) {
    final name = 'worksheets/sheet$index.xml';
    if (absoluteTargets) return '/xl/$name';
    return relativeDotDot ? '../xl/$name' : name;
  }

  final parts = <String, String>{
    'xl/workbook.xml':
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '$workbookPr<sheets>${[for (var i = 0; i < sheetXmls.length; i++) '<sheet name="${sheetNames?[i] ?? 'S${i + 1}'}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${[for (var i = 0; i < sheetXmls.length; i++) '<Relationship Id="rId${i + 1}" Type="$worksheetType" Target="${target(i + 1)}"/>'].join()}</Relationships>',
    for (var i = 0; i < sheetXmls.length; i++)
      'xl/worksheets/sheet${i + 1}.xml': sheetXmls[i],
    if (stylesXml != null && !omitStyles) 'xl/styles.xml': stylesXml,
    if (sharedStringsXml != null) 'xl/sharedStrings.xml': sharedStringsXml,
  };

  final archive = Archive();
  for (final entry in parts.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
