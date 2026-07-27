import 'dart:io';

import 'package:transreade/utils/document_format.dart';
import 'package:transreade/utils/ebook_text.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/format_smoke.dart <fixture-directory>',
    );
    exitCode = 64;
    return;
  }

  final directory = Directory(arguments.single);
  final fixtures = <String, String>{
    'sample.pdf': 'pdf',
    'sample.txt': 'txt',
    'alice.epub': 'epub',
    'sample.fb2': 'fb2',
    'sample.rtf': 'rtf',
    'sample.docx': 'docx',
    'djvu-spec.djvu': 'djvu',
    'colorbook.djvu': 'djvu',
    'mixed-books.zip': 'zip',
  };

  for (final fixture in fixtures.entries) {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${fixture.key}',
    );
    if (!await file.exists()) {
      throw StateError('Missing fixture: ${file.path}');
    }
    final bytes = await file.readAsBytes();
    final detected = detectDocumentFormatBytes(bytes, fileName: fixture.key);
    if (detected != fixture.value) {
      throw StateError(
        '${fixture.key}: expected ${fixture.value}, detected $detected',
      );
    }

    final ebookFormat = ebookFormatFromPath(fixture.key);
    if (ebookFormat != null &&
        const {'txt', 'epub', 'fb2', 'rtf', 'docx'}.contains(detected)) {
      final paragraphs = extractEbookParagraphs(bytes, ebookFormat);
      if (paragraphs.isEmpty ||
          paragraphs.every((paragraph) => paragraph.trim().isEmpty)) {
        throw StateError('${fixture.key}: no readable paragraphs extracted');
      }
      stdout.writeln(
        '${fixture.key}: $detected, ${paragraphs.length} paragraphs',
      );
    } else {
      stdout.writeln('${fixture.key}: $detected');
    }
  }
}
