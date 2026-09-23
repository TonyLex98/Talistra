import 'dart:typed_data';

import 'package:excel2003/excel2003.dart' as xls;
// ignore: implementation_imports
import 'package:excel2003/src/biff/biff_records.dart' as biff;
// ignore: implementation_imports
import 'package:excel2003/src/biff/sst_parser.dart' as sst;
// ignore: implementation_imports
import 'package:excel2003/src/ole2/ole2_reader.dart' as ole2;

import 'xlsx_decode.dart';

/// Decodes a legacy .xls (BIFF8 in an OLE2 compound file, Excel 97-2003).
///
/// The `excel2003` package keeps values and formats apart and never reads
/// the workbook's style records, so a numeric cell comes back as a bare
/// double with no hint that it is a date. [XlsStyles] scans those records
/// itself to answer that question per cell.
List<SpreadsheetSheet> decodeXls(Uint8List bytes) {
  final reader = xls.XlsReader.fromBytes(bytes);
  final styles = XlsStyles.read(bytes);
  final sheets = <SpreadsheetSheet>[];
  for (var i = 0; i < reader.sheetCount; i++) {
    final sheet = reader.sheet(i);
    // The used extent comes from the cells that actually hold something, not
    // from the sheet's DIMENSIONS record: that one counts the furthest cell
    // ever touched in the editor, so a stale record can claim a million
    // empty rows and walking them takes longer than reading the file.
    final cells = <int, Map<int, String>>{};
    var firstRow = 1 << 30;
    var firstColumn = 1 << 30;
    var lastRow = -1;
    var lastColumn = -1;
    for (final cell in sheet.cells) {
      final text = xlsCellText(cell, styles);
      if (text.isEmpty) continue;
      (cells[cell.row] ??= {})[cell.col] = text;
      if (cell.row < firstRow) firstRow = cell.row;
      if (cell.row > lastRow) lastRow = cell.row;
      if (cell.col < firstColumn) firstColumn = cell.col;
      if (cell.col > lastColumn) lastColumn = cell.col;
    }
    if (lastRow < 0) continue;
    final rows = denseGrid(
      cells: cells,
      firstRow: firstRow,
      firstColumn: firstColumn,
      lastRow: lastRow,
      lastColumn: lastColumn,
    );
    sheets.add(SpreadsheetSheet(name: sheet.name, rows: rows));
  }
  return sheets;
}

/// Renders one legacy cell: a number whose format says date is a date, and
/// anything else as written.
String xlsCellText(xls.XlsCell cell, XlsStyles styles) {
  final value = cell.value;
  if (value == null) return '';
  if (value is num) {
    final dateText = switch (styles.serialKindForXf(cell.xfIndex)) {
      SerialKind.date => formatSerial(
        value.toDouble(),
        hasDate: true,
        hasTimeOnly: false,
        date1904: styles.date1904,
      ),
      SerialKind.timeOnly => formatSerial(
        value.toDouble(),
        hasDate: false,
        hasTimeOnly: true,
        date1904: styles.date1904,
      ),
      SerialKind.none => null,
    };
    if (dateText != null) return dateText;
    // NUMBER/RK records decode to double even for integers; print those
    // without the trailing ".0", the way Excel itself shows them.
    final asDouble = value.toDouble();
    if (asDouble == asDouble.roundToDouble() && asDouble.abs() < 1e15) {
      return asDouble.round().toString();
    }
  }
  return value.toString();
}

/// Legacy .xls cells (via the excel2003 package) carry no format
/// information, so the workbook's own XF/FORMAT records are scanned to map
/// each cell format to a kind. The package's public API stops at cell
/// values and does not export its OLE2/BIFF parsers, so they are imported
/// from src — reusing them beats re-implementing OLE2 compound-file parsing
/// for a handful of records (the package is pinned for exactly this, see
/// pubspec).
class XlsStyles {
  XlsStyles._(this._xfFormats, this._customFormats, this.date1904);

  /// FORMAT-record index of each XF record, in record order — a cell's XF
  /// index (stored in its BIFF record) maps through this list.
  final List<int> _xfFormats;
  final Map<int, String> _customFormats;
  final bool date1904;

  factory XlsStyles.read(Uint8List bytes) {
    final container = ole2.Ole2Reader()..openBytes(bytes);
    final entry =
        container.findEntry('Workbook') ?? container.findEntry('Book');
    if (entry == null) {
      throw const FormatException('No Workbook stream found in the file');
    }
    final parser = biff.BiffParser(container.readEntry(entry));
    final xfFormats = <int>[];
    final customFormats = <int, String>{};
    var date1904 = false;
    while (parser.hasMore) {
      final record = parser.nextRecord();
      if (record == null) break;
      switch (record.type) {
        case biff.BiffRecordType.xf:
          // XF layout: font index (2B), then this format's index (2B).
          xfFormats.add(record.readUint16(2));
        case biff.BiffRecordType.format:
          // FORMAT: format index (2B), then the format-code string.
          final index = record.readUint16(0);
          customFormats[index] = sst.BiffStringReader.readString(
            record.data,
            2,
          ).value;
        case biff.BiffRecordType.dateMode:
          date1904 = record.data.isNotEmpty && record.data[0] == 1;
        case biff.BiffRecordType.eof:
          // End of the globals substream; cell XF records live only in it,
          // so nothing relevant follows.
          return XlsStyles._(xfFormats, customFormats, date1904);
      }
    }
    return XlsStyles._(xfFormats, customFormats, date1904);
  }

  SerialKind serialKindForXf(int xfIndex) {
    if (xfIndex < 0 || xfIndex >= _xfFormats.length) {
      return SerialKind.none;
    }
    final formatIndex = _xfFormats[xfIndex];
    // A FORMAT record in the file wins over the built-in table below:
    // writers other than Excel define their custom codes in the 56-63
    // range, which the spec reserves for East-Asian calendar formats.
    final code = _customFormats[formatIndex];
    if (code != null) {
      if (looksLikeDateFormat(code)) return SerialKind.date;
      if (looksLikeTimeFormat(code)) return SerialKind.timeOnly;
      return SerialKind.none;
    }
    // Built-in indices 14-22 are the standard date/time formats, 27-36 and
    // 50-59 their East-Asian calendar siblings, 45-47 elapsed-time formats.
    return switch (formatIndex) {
      14 ||
      15 ||
      16 ||
      17 ||
      22 ||
      (>= 27 && <= 36) ||
      (>= 50 && <= 59) => SerialKind.date,
      18 || 19 || 20 || 21 || (>= 45 && <= 47) => SerialKind.timeOnly,
      _ => SerialKind.none,
    };
  }
}
