import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/library_document.dart';

/// Hands a book or a passage to Android's share sheet — Telegram, WhatsApp,
/// mail, a cloud drive, whatever the phone has.

const _mimeTypes = {
  'pdf': 'application/pdf',
  'djvu': 'image/vnd.djvu',
  'djv': 'image/vnd.djvu',
  'epub': 'application/epub+zip',
  'fb2': 'application/x-fictionbook+xml',
  'rtf': 'application/rtf',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xls': 'application/vnd.ms-excel',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'xml': 'text/xml',
  'html': 'text/html',
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'bmp': 'image/bmp',
};

/// The name a shared book goes out under: its title, not the id it is
/// stored as — the person it is sent to should see what it is.
String sharedFileName(LibraryDocument document) {
  final safe = document.title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final name = safe.isEmpty ? 'book' : safe;
  final clipped = name.length > 100 ? name.substring(0, 100).trim() : name;
  return '$clipped.${document.format}';
}

/// Sends the book's file.
Future<void> shareDocumentFile(LibraryDocument document) async {
  final folder = Directory(
    p.join((await getTemporaryDirectory()).path, 'share'),
  );
  if (await folder.exists()) await folder.delete(recursive: true);
  await folder.create(recursive: true);
  final copy = await File(
    document.filePath,
  ).copy(p.join(folder.path, sharedFileName(document)));
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile(
          copy.path,
          mimeType: _mimeTypes[document.format] ?? 'application/octet-stream',
        ),
      ],
      subject: document.title,
    ),
  );
}

/// Sends [text] — a marked passage, a page.
Future<void> shareText(String text, {String? subject}) =>
    SharePlus.instance.share(ShareParams(text: text, subject: subject));
