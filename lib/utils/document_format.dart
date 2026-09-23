import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

// The two spreadsheet formats are read by the app's own decoders:
// .xlsx (ZIP/OOXML) by xlsx_decode.dart, legacy .xls (OLE2/BIFF8,
// Excel 97-2003) by xls_decode.dart on top of the excel2003 record parser.
const supportedBookFormats = {
  'pdf',
  'txt',
  'epub',
  'fb2',
  'rtf',
  'docx',
  'djvu',
  'xlsx',
  'xls',
};

const supportedArchiveFormats = {'zip'};

Future<String?> detectDocumentFormat(
  String path, {
  required String fileName,
}) async {
  final file = File(path);
  final length = await file.length();
  if (length <= 0) return null;
  if (length > 700 * 1024 * 1024) {
    throw const FormatException('The document is larger than 700 MB');
  }
  final probeLength = length < 8192 ? length : 8192;
  final probe = await file
      .openRead(0, probeLength)
      .fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
  final probeBytes = probe.takeBytes();

  // Fixed-page and plain-text signatures live at the beginning of the file,
  // so large books do not need to be copied wholesale merely to identify
  // them. ZIP containers need their central directory and are read below.
  if (!_looksLikeZip(probeBytes)) {
    return detectDocumentFormatBytes(probeBytes, fileName: fileName);
  }
  if (length > 300 * 1024 * 1024) {
    throw const FormatException('ZIP-based books are limited to 300 MB');
  }
  return detectDocumentFormatBytes(
    await file.readAsBytes(),
    fileName: fileName,
  );
}

/// Identifies a document by its signature and container structure.
///
/// Extensions are only a fallback for deliberately headerless plain text.
/// Fixed-page and ZIP-container formats must pass their magic-byte checks,
/// preventing arbitrary binary data from reaching a PDF or text renderer.
String? detectDocumentFormatBytes(Uint8List bytes, {required String fileName}) {
  if (bytes.isEmpty) return null;
  final extension = p.extension(fileName).toLowerCase().replaceFirst('.', '');

  final probeLength = bytes.length.clamp(0, 8192);
  final probe = bytes.sublist(0, probeLength);
  final ascii = latin1.decode(probe, allowInvalid: true);

  // A PDF header may legally appear within the first 1024 bytes.
  if (ascii.indexOf('%PDF-') case final index when index >= 0 && index < 1024) {
    return 'pdf';
  }
  if (bytes.length >= 16 &&
      ascii.startsWith('AT&TFORM') &&
      (ascii.substring(12, 16) == 'DJVU' ||
          ascii.substring(12, 16) == 'DJVM' ||
          ascii.substring(12, 16) == 'DJVI')) {
    return 'djvu';
  }
  if (ascii.startsWith(r'{\rtf')) return 'rtf';

  // Legacy .xls is an OLE2/Compound File Binary container, not a ZIP —
  // its signature is this fixed 8-byte header regardless of content.
  if (bytes.length >= 8 &&
      bytes[0] == 0xD0 &&
      bytes[1] == 0xCF &&
      bytes[2] == 0x11 &&
      bytes[3] == 0xE0 &&
      bytes[4] == 0xA1 &&
      bytes[5] == 0xB1 &&
      bytes[6] == 0x1A &&
      bytes[7] == 0xE1) {
    return 'xls';
  }

  if (_looksLikeZip(bytes)) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final names = archive.files
          .where((entry) => entry.isFile)
          .map((entry) => entry.name.replaceAll('\\', '/').toLowerCase())
          .toSet();
      if (names.contains('word/document.xml')) return 'docx';
      if (names.contains('xl/workbook.xml')) return 'xlsx';
      if (names.contains('meta-inf/container.xml') ||
          names.any((name) => name.endsWith('.opf'))) {
        return 'epub';
      }
      final mimetype = archive.files
          .where(
            (entry) =>
                entry.isFile &&
                entry.name.replaceAll('\\', '/').toLowerCase() == 'mimetype',
          )
          .firstOrNull;
      if (mimetype != null) {
        final content = _archiveBytes(mimetype);
        if (utf8.decode(content, allowMalformed: true).trim() ==
            'application/epub+zip') {
          return 'epub';
        }
      }
      return 'zip';
    } catch (_) {
      return null;
    }
  }

  final textProbe = utf8.decode(probe, allowMalformed: true).toLowerCase();
  if (textProbe.contains('<fictionbook') ||
      (textProbe.contains('<?xml') && extension == 'fb2')) {
    return 'fb2';
  }

  // Plain text has no reliable magic number. Only accept it when the caller
  // actually named it as text and the probe contains no binary NUL bytes.
  if (extension == 'txt' && !probe.contains(0)) return 'txt';
  return null;
}

bool _looksLikeZip(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4b &&
    ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
        (bytes[2] == 0x05 && bytes[3] == 0x06) ||
        (bytes[2] == 0x07 && bytes[3] == 0x08));

Uint8List archiveFileBytes(ArchiveFile file) => _archiveBytes(file);

Uint8List _archiveBytes(ArchiveFile file) {
  final content = file.content;
  return content is Uint8List
      ? content
      : Uint8List.fromList(content as List<int>);
}
