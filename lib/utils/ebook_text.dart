import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'ebook_blocks.dart';
import 'reflow_builder.dart';
import 'text_decode.dart';

/// The document formats the app can read as flowing text.
///
/// A PDF is a page image with a text layer and gets its own reader; these
/// are all *text* formats, so they end up in the same paginated reading
/// view as a plain .txt file, in the reader's own font and colours.
enum EbookFormat { txt, epub, fb2, rtf, docx }

/// The format a library entry was stored as (its `format` field), or null
/// for one that isn't read as text.
EbookFormat? ebookFormatFromName(String format) => switch (format) {
  'txt' => EbookFormat.txt,
  'epub' => EbookFormat.epub,
  'fb2' => EbookFormat.fb2,
  'rtf' => EbookFormat.rtf,
  'docx' => EbookFormat.docx,
  _ => null,
};

/// Recognizes a format from a file name. Returns null for anything the app
/// doesn't read as text (a PDF, or something unsupported).
EbookFormat? ebookFormatFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.txt')) return EbookFormat.txt;
  if (lower.endsWith('.epub')) return EbookFormat.epub;
  if (lower.endsWith('.fb2') || lower.endsWith('.fb2.zip')) {
    return EbookFormat.fb2;
  }
  if (lower.endsWith('.rtf')) return EbookFormat.rtf;
  if (lower.endsWith('.docx')) return EbookFormat.docx;
  return null;
}

/// Extracts a document as the blocks the paginated reader lays out, in
/// reading order: paragraphs with the emphasis the book gave them, chapter
/// titles as headings, verse with its line breaks, quotations, lists and the
/// pictures the book carries (see `ebook_blocks.dart`).
///
/// Plain text and RTF have no structure to keep beyond their paragraphs.
List<ReflowBlock> extractEbookBlocks(Uint8List bytes, EbookFormat format) {
  switch (format) {
    case EbookFormat.txt:
      return _plainBlocks(_splitPlainText(decodeTextFile(bytes)));
    case EbookFormat.epub:
      return _epubBlocks(bytes);
    case EbookFormat.fb2:
      return fb2Blocks(bytes, decodeTextFile);
    case EbookFormat.rtf:
      return _plainBlocks(_rtfParagraphs(bytes));
    case EbookFormat.docx:
      return _docxBlocks(bytes);
  }
}

/// The text of [extractEbookBlocks] alone, one string per block that has
/// any.
List<String> extractEbookParagraphs(Uint8List bytes, EbookFormat format) => [
  for (final block in extractEbookBlocks(bytes, format))
    if (block.text.isNotEmpty) block.text,
];

List<ReflowBlock> _plainBlocks(List<String> paragraphs) => [
  for (final text in paragraphs) ReflowBlock.paragraph(text),
];

List<String> _splitPlainText(String text) {
  return [
    for (final block in text.split(RegExp(r'\n[ \t]*\n')))
      if (block.trim().isNotEmpty)
        block.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim(),
  ];
}

// ---------------------------------------------------------------- EPUB

/// EPUB is a zip of XHTML documents plus an OPF manifest listing them in
/// reading order. The spine is followed rather than the zip's own order,
/// which is arbitrary, and each document is read into blocks — or, when it is
/// too broken to parse, into its bare paragraphs.
List<ReflowBlock> _epubBlocks(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = {
    for (final file in archive.files)
      if (file.isFile) file.name: file,
  };

  final opfName = _epubOpfPath(files);
  final order = <String>[];
  if (opfName != null) {
    final opf = XmlDocument.parse(_utf8OfFile(files[opfName]!));
    final base = opfName.contains('/')
        ? opfName.substring(0, opfName.lastIndexOf('/') + 1)
        : '';
    final hrefById = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        hrefById[id] = _normalizeZipPath('$base$href');
      }
    }
    for (final ref in opf.findAllElements('itemref')) {
      final href = hrefById[ref.getAttribute('idref')];
      if (href != null && files.containsKey(href)) order.add(href);
    }
  }
  if (order.isEmpty) {
    order.addAll(
      files.keys.where((name) {
        final lower = name.toLowerCase();
        return lower.endsWith('.xhtml') ||
            lower.endsWith('.html') ||
            lower.endsWith('.htm');
      }).toList()..sort(),
    );
  }

  final blocks = <ReflowBlock>[];
  for (final name in order) {
    final html = _utf8OfFile(files[name]!);
    final folder = name.contains('/')
        ? name.substring(0, name.lastIndexOf('/') + 1)
        : '';
    Uint8List? resolve(String src) {
      final path = Uri.decodeFull(src.split('#').first.split('?').first);
      final file = files[_normalizeZipPath('$folder$path')];
      if (file == null) return null;
      final content = file.content;
      return content is Uint8List
          ? content
          : Uint8List.fromList(content as List<int>);
    }

    blocks.addAll(
      htmlBlocks(html, resolve) ?? _plainBlocks(_htmlParagraphs(html)),
    );
  }
  return blocks;
}

String? _epubOpfPath(Map<String, ArchiveFile> files) {
  final container = files['META-INF/container.xml'];
  if (container != null) {
    try {
      final xml = XmlDocument.parse(_utf8OfFile(container));
      final path = xml
          .findAllElements('rootfile')
          .first
          .getAttribute('full-path');
      if (path != null && files.containsKey(path)) return path;
    } catch (_) {
      // Fall through to the search below.
    }
  }
  for (final name in files.keys) {
    if (name.toLowerCase().endsWith('.opf')) return name;
  }
  return null;
}

String _normalizeZipPath(String path) {
  final parts = <String>[];
  for (final segment in path.split('/')) {
    if (segment == '.' || segment.isEmpty) continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

// ---------------------------------------------------------------- DOCX

/// A .docx is a zip whose `word/document.xml` holds the text.
List<ReflowBlock> _docxBlocks(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final document = archive.files.firstWhere(
    (f) => f.isFile && f.name == 'word/document.xml',
    orElse: () => throw const FormatException('word/document.xml not found'),
  );
  return docxBlocks(_utf8OfFile(document));
}

// ---------------------------------------------------------------- RTF

/// A small RTF-to-text pass: enough for documents that are prose.
///
/// RTF is groups in braces with backslash control words; `\par` ends a
/// paragraph, `\'xx` is a byte in the current code page and `\uN` a
/// Unicode codepoint. Groups that are known to hold no body text (fonts,
/// colours, stylesheets, embedded pictures) are skipped whole.
/// A control word (`\par`, `\u1055`, `\fs24`) or a control symbol (`\'d0`,
/// `\\`, `\~`).
final _rtfControl = RegExp(r"\\([a-zA-Z]+)(-?\d+)?[ ]?|\\(.)");

List<String> _rtfParagraphs(Uint8List bytes) {
  final source = latin1.decode(bytes, allowInvalid: true);
  final paragraphs = <String>[];
  final current = StringBuffer();
  var skipDepth = -1;
  var depth = 0;
  var i = 0;
  var unicodeFallbackCount = 1;
  // Bytes of \'xx escapes are collected and decoded together, so
  // multi-byte code pages (and Cyrillic in particular) survive.
  final pending = <int>[];

  void flushPending() {
    if (pending.isEmpty) return;
    current.write(decodeTextFile(Uint8List.fromList(pending)));
    pending.clear();
  }

  void endParagraph() {
    flushPending();
    final text = _collapse(current.toString());
    if (text.isNotEmpty) paragraphs.add(text);
    current.clear();
  }

  while (i < source.length) {
    final ch = source[i];
    if (ch == '{') {
      depth++;
      i++;
      continue;
    }
    if (ch == '}') {
      if (skipDepth >= 0 && depth <= skipDepth) skipDepth = -1;
      depth--;
      i++;
      continue;
    }
    if (ch == r'\') {
      // No leading ^: matchAsPrefix already anchors the match at [i], while
      // ^ anchors at the start of the whole string and so never matched
      // past the first character — which quietly left every control word in
      // the output as plain letters.
      final match = _rtfControl.matchAsPrefix(source, i);
      if (match == null) {
        i++;
        continue;
      }
      i = match.end;
      final word = match.group(1);
      final symbol = match.group(3);
      if (word == null) {
        if (skipDepth >= 0) continue;
        switch (symbol) {
          case "'":
            // \'xx — one byte, hex encoded.
            final hex = source.substring(i, (i + 2).clamp(0, source.length));
            final value = int.tryParse(hex, radix: 16);
            if (value != null) {
              pending.add(value);
              i += 2;
            }
          case '~':
            flushPending();
            current.write(' ');
          case r'\':
          case '{':
          case '}':
            flushPending();
            current.write(symbol);
        }
        continue;
      }
      switch (word) {
        case 'par':
        case 'pard':
        case 'line':
          if (skipDepth < 0) endParagraph();
        case 'uc':
          unicodeFallbackCount = int.tryParse(match.group(2) ?? '') ?? 1;
        case 'u':
          if (skipDepth < 0) {
            flushPending();
            final code = int.tryParse(match.group(2) ?? '');
            if (code != null) {
              current.writeCharCode(code < 0 ? code + 65536 : code);
            }
          }
          // RTF repeats the character after a \u escape for readers that
          // don't do Unicode ("ၕ?"), and \ucN says how many of those
          // follow. Not skipping them turned every Cyrillic letter into
          // "П?".
          i = _skipUnicodeFallback(source, i, unicodeFallbackCount);
        case 'fonttbl':
        case 'colortbl':
        case 'stylesheet':
        case 'info':
        case 'pict':
        case 'object':
        case 'header':
        case 'footer':
        case 'listtable':
        case 'generator':
          if (skipDepth < 0) skipDepth = depth;
        case 'tab':
          if (skipDepth < 0) {
            flushPending();
            current.write(' ');
          }
      }
      continue;
    }
    if (skipDepth < 0) {
      // Plain characters are bytes in the document's code page.
      pending.add(source.codeUnitAt(i) & 0xFF);
    }
    i++;
  }
  endParagraph();
  return paragraphs;
}

// ---------------------------------------------------------------- shared

/// Strips tags from an (X)HTML document and returns its paragraphs, keeping
/// the breaks that block-level elements imply.
List<String> _htmlParagraphs(String html) {
  var text = html
      // Anything that isn't prose goes first, contents and all.
      .replaceAll(
        RegExp(
          r'<(script|style|head)[^>]*>.*?</\1>',
          dotAll: true,
          caseSensitive: false,
        ),
        '',
      )
      // Block boundaries become paragraph breaks before tags are removed.
      .replaceAll(
        RegExp(
          r'</(p|div|h[1-6]|li|tr|blockquote|section|article)\s*>',
          caseSensitive: false,
        ),
        '\n\n',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  text = _unescapeHtml(text);
  return [
    for (final block in text.split(RegExp(r'\n\s*\n')))
      if (_collapse(block).isNotEmpty) _collapse(block),
  ];
}

const _htmlEntities = {
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&mdash;': '—',
  '&ndash;': '–',
  '&hellip;': '…',
  '&laquo;': '«',
  '&raquo;': '»',
  '&ldquo;': '“',
  '&rdquo;': '”',
  '&rsquo;': '’',
  '&lsquo;': '‘',
  '&shy;': '',
};

String _unescapeHtml(String text) {
  var result = text;
  _htmlEntities.forEach((from, to) => result = result.replaceAll(from, to));
  return result.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (match) {
    final radix = match.group(1)!.isEmpty ? 10 : 16;
    final code = int.tryParse(match.group(2)!, radix: radix);
    // Past U+10FFFF, a lone surrogate or NUL is no character to print, and
    // asking for one would throw and lose the whole chapter.
    final valid =
        code != null &&
        code > 0 &&
        code <= 0x10FFFF &&
        (code < 0xD800 || code > 0xDFFF);
    return valid ? String.fromCharCode(code) : match.group(0)!;
  });
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Steps over the [count] fallback characters that follow a `\uN` escape;
/// each may be a plain character or a `\'xx` byte escape.
int _skipUnicodeFallback(String source, int start, int count) {
  var i = start;
  for (var skipped = 0; skipped < count && i < source.length; skipped++) {
    if (source.startsWith(r"\'", i)) {
      i += 4;
    } else {
      i += 1;
    }
  }
  return i;
}

String _utf8OfFile(ArchiveFile file) {
  final content = file.content;
  final bytes = content is Uint8List
      ? content
      : Uint8List.fromList(content as List<int>);
  return decodeTextFile(bytes);
}
