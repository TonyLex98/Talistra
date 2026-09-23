import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:intl/intl.dart';
import 'package:xml/xml.dart';

import 'text_decode.dart';

/// Ceiling on the number of cells a single sheet is turned into a grid of.
const int maxGridCells = 2000000;

/// One decoded worksheet: its tab name and a dense grid of display text.
class SpreadsheetSheet {
  const SpreadsheetSheet({required this.name, required this.rows});

  final String name;
  final List<List<String>> rows;
}

/// What a numeric cell's number format says the value represents.
enum SerialKind { none, date, timeOnly }

/// Decodes an .xlsx (ECMA-376) workbook into its sheets.
///
/// Written by hand rather than left to a spreadsheet package, because the
/// readers available on pub.dev abort on documents that real-world writers
/// produce: a relationship target written as an absolute part name
/// (`Target="/xl/worksheets/sheet1.xml"`, which SheetJS and openpyxl emit)
/// or a number format in the East-Asian built-in range is enough to lose
/// the whole file. Only the reading subset of the container is handled.
List<SpreadsheetSheet> decodeXlsx(Uint8List bytes) {
  // Keys are lower-cased: the package layout is fixed by the spec, but
  // writers do occasionally differ on the case of a part name.
  final parts = <String, ArchiveFile>{
    for (final file in ZipDecoder().decodeBytes(bytes).files)
      if (file.isFile) file.name.toLowerCase(): file,
  };
  ArchiveFile? part(String name) => parts[name.toLowerCase()];
  final workbook = part('xl/workbook.xml');
  if (workbook == null) {
    throw const FormatException('This .xlsx has no xl/workbook.xml part');
  }
  final workbookXml = XmlDocument.parse(_text(workbook));
  final targets = _relationshipTargets(part('xl/_rels/workbook.xml.rels'));
  final styles = part('xl/styles.xml');
  final formatCodes = _customFormatCodes(styles);
  final styleFormats = _cellFormatIds(styles);
  final strings = _sharedStrings(part('xl/sharedStrings.xml'));
  final date1904 = _uses1904Dates(workbookXml);

  final sheets = <SpreadsheetSheet>[];
  for (final sheet in workbookXml.findAllElements('sheet')) {
    final name = _attribute(sheet, 'name') ?? '';
    final relationship =
        _attribute(sheet, 'id', namespace: 'r') ?? _attribute(sheet, 'id');
    final path = relationship == null ? null : targets[relationship];
    final file = path == null ? null : parts[path];
    if (file == null) continue;
    final rows = _sheetRows(
      xml: XmlDocument.parse(_text(file)),
      styleFormats: styleFormats,
      formatCodes: formatCodes,
      strings: strings,
      date1904: date1904,
    );
    // A tab with nothing on it — a helper sheet, or one the workbook
    // declares but never wrote to — gets no tab, since there is nothing to
    // switch to.
    if (rows.any((row) => row.any((cell) => cell.isNotEmpty))) {
      sheets.add(SpreadsheetSheet(name: name, rows: rows));
    }
  }
  return sheets;
}

// ---------------------------------------------------------------- structure

/// Relationship id → the package path it points at.
Map<String, String> _relationshipTargets(ArchiveFile? file) {
  if (file == null) return const {};
  return {
    for (final rel in XmlDocument.parse(
      _text(file),
    ).findAllElements('Relationship'))
      if (_attribute(rel, 'Id') case final id?)
        id: _resolvePartPath(_attribute(rel, 'Target') ?? ''),
  };
}

/// Turns a relationship target into a package path.
///
/// Targets are either absolute part names (`/xl/worksheets/sheet1.xml`) or
/// relative to the folder holding the `.rels` file
/// (`worksheets/sheet1.xml`, or even `../xl/...`); which of the two a
/// writer emits is the single most common thing real-world spreadsheets
/// disagree on.
String _resolvePartPath(String target) {
  final raw = target.startsWith('/') ? target.substring(1) : 'xl/$target';
  final segments = <String>[];
  for (final segment in raw.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/').toLowerCase();
}

bool _uses1904Dates(XmlDocument workbook) {
  for (final pr in workbook.findAllElements('workbookPr')) {
    final flag = _attribute(pr, 'date1904');
    if (flag != null) return flag == '1' || flag.toLowerCase() == 'true';
  }
  return false;
}

/// Format code of each user-defined number format, by its id.
Map<int, String> _customFormatCodes(ArchiveFile? styles) {
  if (styles == null) return const {};
  final codes = <int, String>{};
  for (final format in XmlDocument.parse(
    _text(styles),
  ).findAllElements('numFmt')) {
    final id = int.tryParse(_attribute(format, 'numFmtId') ?? '');
    final code = _attribute(format, 'formatCode');
    if (id != null && code != null) codes[id] = code;
  }
  return codes;
}

/// Number-format id of each cell style (`cellXfs`), indexed by the `s`
/// attribute a cell carries.
List<int> _cellFormatIds(ArchiveFile? styles) {
  if (styles == null) return const [];
  final root = XmlDocument.parse(_text(styles)).rootElement;
  final cellXfs = root.findElements('cellXfs');
  if (cellXfs.isEmpty) return const [];
  return [
    for (final xf in cellXfs.first.findElements('xf'))
      int.tryParse(_attribute(xf, 'numFmtId') ?? '') ?? 0,
  ];
}

List<String> _sharedStrings(ArchiveFile? file) {
  if (file == null) return const [];
  return [
    for (final item in XmlDocument.parse(_text(file)).findAllElements('si'))
      _stringOf(item),
  ];
}

/// Text of a shared-string entry: a plain `<t>`, or several rich-text `<r>`
/// runs. Phonetic runs (`rPh`, furigana in Japanese workbooks) repeat part
/// of the text and are left out.
String _stringOf(XmlElement item) {
  final parts = <String>[];
  for (final child in item.children.whereType<XmlElement>()) {
    switch (child.localName) {
      case 't':
        parts.add(child.innerText);
      case 'r':
        parts.addAll(
          child.children
              .whereType<XmlElement>()
              .where((run) => run.localName == 't')
              .map((run) => run.innerText),
        );
      default:
        break;
    }
  }
  return parts.join();
}

// -------------------------------------------------------------------- cells

List<List<String>> _sheetRows({
  required XmlDocument xml,
  required List<int> styleFormats,
  required Map<int, String> formatCodes,
  required List<String> strings,
  required bool date1904,
}) {
  final cells = <int, Map<int, String>>{};
  var lastRow = -1;
  var lastColumn = -1;
  var nextRowIndex = 0;
  for (final row in xml.findAllElements('row')) {
    // A row that carries no number follows the one before it, the same way
    // a cell that carries no reference follows the one before it.
    final label = _attribute(row, 'r');
    final number = label == null ? null : int.tryParse(label);
    final rowIndex = number == null ? nextRowIndex : number - 1;
    if (rowIndex < 0) continue;
    nextRowIndex = rowIndex + 1;
    var column = -1;
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.localName != 'c') continue;
      column = _columnIndex(_attribute(cell, 'r'), column + 1);
      final text = _cellText(
        cell,
        styleFormats: styleFormats,
        formatCodes: formatCodes,
        strings: strings,
        date1904: date1904,
      );
      if (text.isEmpty) continue;
      (cells[rowIndex] ??= {})[column] = text;
      if (rowIndex > lastRow) lastRow = rowIndex;
      if (column > lastColumn) lastColumn = column;
    }
  }
  if (lastRow < 0) return const [];
  return denseGrid(
    cells: cells,
    firstRow: 0,
    firstColumn: 0,
    lastRow: lastRow,
    lastColumn: lastColumn,
  );
}

/// Turns a sheet's sparse cells into the dense grid the reader shows.
///
/// Cells are stored sparsely and rendered densely because a table with a gap
/// keeps its columns aligned. One stray formatted cell far down an otherwise
/// empty sheet would otherwise blow the grid up into hundreds of thousands of
/// blank rows, so past that size the empty ones are dropped — and when even
/// the blanks themselves are more than a phone can hold, the tail is cut off,
/// since the rows that carry data come first in every real file.
List<List<String>> denseGrid({
  required Map<int, Map<int, String>> cells,
  required int firstRow,
  required int firstColumn,
  required int lastRow,
  required int lastColumn,
}) {
  final width = lastColumn - firstColumn + 1;
  final height = lastRow - firstRow + 1;
  if (width <= 0 || height <= 0) return const [];
  final keepBlankRows = height * width <= 200000;
  final rowsToKeep = height * width > maxGridCells
      ? (maxGridCells / width).ceil()
      : height;
  final rows = <List<String>>[];
  for (var r = 0; r < rowsToKeep; r++) {
    final byColumn = cells[firstRow + r];
    if (byColumn == null && !keepBlankRows) continue;
    rows.add([
      for (var c = 0; c < width; c++) byColumn?[firstColumn + c] ?? '',
    ]);
  }
  return rows;
}

String _cellText(
  XmlElement cell, {
  required List<int> styleFormats,
  required Map<int, String> formatCodes,
  required List<String> strings,
  required bool date1904,
}) {
  final type = _attribute(cell, 't');
  if (type == 'inlineStr') {
    final inline = _child(cell, 'is');
    return inline == null ? '' : _stringOf(inline);
  }
  final raw = _child(cell, 'v')?.innerText ?? '';
  switch (type) {
    case 's':
      final index = int.tryParse(raw);
      return index == null || index < 0 || index >= strings.length
          ? ''
          : strings[index];
    case 'str': // A formula's cached result, already text.
    case 'e': // An error value, e.g. #DIV/0!.
    case 'd': // An ISO 8601 date, already text.
      return raw;
    case 'b':
      return raw == '1' ? 'TRUE' : 'FALSE';
    default:
      break;
  }
  if (raw.isEmpty) return '';
  final number = double.tryParse(raw);
  if (number == null) return raw;
  final kind = _serialKindOf(
    cell,
    styleFormats: styleFormats,
    formatCodes: formatCodes,
  );
  return formatSerial(
        number,
        hasDate: kind == SerialKind.date,
        hasTimeOnly: kind == SerialKind.timeOnly,
        date1904: date1904,
      ) ??
      _plainNumber(raw, number);
}

/// The literal the file wrote, unless the value parses to something shorter:
/// a writer that rounds through a binary double stores "85.90000000000001",
/// and the shortest representation that reads back as the same double is the
/// number the author meant. An integer keeps its clean "45000" either way.
String _plainNumber(String literal, double number) {
  final shortest = number.toString();
  return shortest.length < literal.length ? shortest : literal;
}

SerialKind _serialKindOf(
  XmlElement cell, {
  required List<int> styleFormats,
  required Map<int, String> formatCodes,
}) {
  // A cell with no style attribute at all is style 0, the default format.
  final style = int.tryParse(_attribute(cell, 's') ?? '0') ?? 0;
  if (style >= styleFormats.length) return SerialKind.none;
  final formatId = styleFormats[style];
  // A format defined in the file describes the value better than the
  // built-in table: ids 56-63 are reserved for East-Asian calendars, yet
  // non-Excel writers put their own codes there.
  final code = formatCodes[formatId];
  if (code != null) {
    if (looksLikeDateFormat(code)) return SerialKind.date;
    if (looksLikeTimeFormat(code)) return SerialKind.timeOnly;
    return SerialKind.none;
  }
  // Built-in ids 14-17 and 22 are the standard date formats, 18-21 the time
  // ones, 27-36 and 50-59 their East-Asian siblings, 45-47 elapsed time.
  return switch (formatId) {
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

/// Column index of a cell reference (`AB12`), or [fallback] when the cell
/// carries no reference — which writers do when every cell of the row
/// follows the last.
int _columnIndex(String? reference, int fallback) {
  if (reference == null) return fallback;
  var column = 0;
  var letters = 0;
  for (final unit in reference.codeUnits) {
    if (unit < 65 || unit > 122) break;
    final letter = (unit & 0x1f) - 1; // 'A' and 'a' both give 0.
    if (letter < 0 || letter > 25) break;
    column = column * 26 + letter + 1;
    letters++;
  }
  if (letters == 0 || letters >= reference.length) return fallback;
  return column - 1;
}

// -------------------------------------------------------------- formatting

/// Renders a serial value as a date/time when the cell's format says it is
/// one, or null when it is a plain number and the caller should fall back to
/// the raw text.
String? formatSerial(
  double serial, {
  required bool hasDate,
  required bool hasTimeOnly,
  bool date1904 = false,
}) {
  if (hasDate) {
    final dateTime = _serialToDateTime(serial, date1904: date1904);
    final hasTimeOfDay = (serial - serial.floorToDouble()).abs() > 1 / 86400000;
    return DateFormat(
      hasTimeOfDay ? 'dd.MM.yyyy HH:mm' : 'dd.MM.yyyy',
    ).format(dateTime);
  }
  if (hasTimeOnly) {
    return DateFormat(
      'HH:mm',
    ).format(_serialToDateTime(serial, date1904: date1904));
  }
  return null;
}

/// Format-code text with any quoted literal (e.g. `"₽"`, `"руб."`) removed,
/// so a currency symbol can never be mistaken for a date/time token.
String _withoutQuotedLiterals(String code) =>
    code.replaceAll(RegExp(r'"[^"]*"'), '');

bool looksLikeDateFormat(String formatCode) {
  final lower = _withoutQuotedLiterals(formatCode).toLowerCase();
  return lower.contains('yy') || lower.contains('dd') || lower.contains('mmm');
}

bool looksLikeTimeFormat(String formatCode) {
  final lower = _withoutQuotedLiterals(formatCode).toLowerCase();
  return lower.contains('hh') || lower.contains('ss') || lower.contains(':');
}

/// Serial numbers count days from the epoch, with the time of day as the
/// fraction. 1899-12-30 already absorbs Excel's fictitious 1900 leap day;
/// workbooks saved with the 1904 option count from 1904-01-01 instead.
DateTime _serialToDateTime(double serial, {required bool date1904}) {
  final epoch = date1904
      ? DateTime.utc(1904, 1, 1)
      : DateTime.utc(1899, 12, 30);
  final days = serial.truncate();
  final fraction = (serial - days) * Duration.millisecondsPerDay;
  return epoch.add(Duration(days: days, milliseconds: fraction.round()));
}

// -------------------------------------------------------------------- misc

/// First child element with this local name, whatever namespace it is in.
XmlElement? _child(XmlElement parent, String name) {
  for (final child in parent.children.whereType<XmlElement>()) {
    if (child.localName == name) return child;
  }
  return null;
}

/// Attribute by local name, with an optional namespace prefix.
///
/// The `r:` in `r:id` is a convention, not a requirement: a writer may bind
/// the relationships namespace to any prefix, so the local name is what the
/// lookup falls back on.
String? _attribute(XmlElement element, String name, {String? namespace}) {
  for (final attribute in element.attributes) {
    if (attribute.name.local != name) continue;
    if (namespace != null && attribute.name.prefix != namespace) continue;
    return attribute.value;
  }
  return null;
}

String _text(ArchiveFile file) {
  final content = file.content;
  return decodeTextFile(
    content is Uint8List ? content : Uint8List.fromList(content as List<int>),
  );
}
