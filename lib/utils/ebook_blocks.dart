import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'image_size.dart';
import 'reflow_builder.dart';

/// Turns the markup of an e-book — FB2's XML, an EPUB chapter's XHTML — into
/// the [ReflowBlock]s the paginated reader lays out, keeping what the book
/// says about its own structure: chapter titles as headings at their depth,
/// emphasis as bold and italic runs, a poem's lines on their own lines, an
/// epigraph or a quotation set in as a quote, lists with their markers, and
/// the pictures the book carries.
///
/// Flattening all of that to plain paragraphs is what made a novel's chapter
/// titles read as one more line of prose — and a poem's verses vanish, since
/// they are not paragraphs at all.

/// How a piece of text is set, as the walk carries it down the tree.
class _Flags {
  const _Flags({
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.link = false,
  });

  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;
  final bool link;

  bool get any => bold || italic || code || strike || link;

  _Flags add({
    bool bold = false,
    bool italic = false,
    bool code = false,
    bool strike = false,
    bool link = false,
  }) => _Flags(
    bold: this.bold || bold,
    italic: this.italic || italic,
    code: this.code || code,
    strike: this.strike || strike,
    link: this.link || link,
  );

  bool sameAs(_Flags other) =>
      bold == other.bold &&
      italic == other.italic &&
      code == other.code &&
      strike == other.strike &&
      link == other.link;
}

/// Everything about the block being read that its ancestors decided.
class _Context {
  const _Context({
    this.headingLevel = 0,
    this.quoteDepth = 0,
    this.indent = 0,
    this.sectionDepth = 0,
    this.preformatted = false,
    this.linesJoin = false,
    this.flags = const _Flags(),
  });

  final int headingLevel;
  final int quoteDepth;
  final int indent;

  /// How deeply the current FB2 `<section>` is nested — what a `<title>`'s
  /// heading level is worked out from.
  final int sectionDepth;

  /// Inside `<pre>`: whitespace is the author's layout, not typing.
  final bool preformatted;

  /// Inside a title or a stanza: each paragraph (or verse) is a line of one
  /// block rather than a block of its own, so a two-line chapter title stays
  /// one heading and a stanza stays one piece of verse.
  final bool linesJoin;

  final _Flags flags;

  _Context copyWith({
    int? headingLevel,
    int? quoteDepth,
    int? indent,
    int? sectionDepth,
    bool? preformatted,
    bool? linesJoin,
    _Flags? flags,
  }) => _Context(
    headingLevel: headingLevel ?? this.headingLevel,
    quoteDepth: quoteDepth ?? this.quoteDepth,
    indent: indent ?? this.indent,
    sectionDepth: sectionDepth ?? this.sectionDepth,
    preformatted: preformatted ?? this.preformatted,
    linesJoin: linesJoin ?? this.linesJoin,
    flags: flags ?? this.flags,
  );
}

/// Collects running text and its runs, and cuts it into blocks.
class _BlockSink {
  final List<ReflowBlock> blocks = [];
  final StringBuffer _text = StringBuffer();
  final List<({int start, int end, _Flags flags})> _runs = [];

  bool get _endsWithSpace {
    if (_text.isEmpty) return true;
    final s = _text.toString();
    final last = s.codeUnitAt(s.length - 1);
    return last == 0x20 || last == 0x0A;
  }

  void text(String raw, _Context context) {
    var value = raw;
    if (!context.preformatted) {
      value = value.replaceAll(_whitespace, ' ');
      if (_endsWithSpace && value.startsWith(' ')) value = value.substring(1);
    }
    if (value.isEmpty) return;
    final start = _text.length;
    _text.write(value);
    final flags = context.flags;
    if (!flags.any) return;
    if (_runs.isNotEmpty &&
        _runs.last.end == start &&
        _runs.last.flags.sameAs(flags)) {
      final last = _runs.removeLast();
      _runs.add((start: last.start, end: _text.length, flags: flags));
    } else {
      _runs.add((start: start, end: _text.length, flags: flags));
    }
  }

  /// An explicit break inside the block being read: `<br>`, the end of a
  /// verse, the end of one line of a two-line title.
  void lineBreak() {
    if (_text.isEmpty) return;
    final s = _text.toString();
    final trimmed = s.trimRight();
    if (trimmed.isEmpty || trimmed.endsWith('\n')) return;
    _text
      ..clear()
      ..write(trimmed)
      ..write('\n');
  }

  /// Closes the block being read, if anything was written into it.
  void flush(_Context context) {
    final raw = _text.toString();
    _text.clear();
    final runs = [..._runs];
    _runs.clear();
    final lead = raw.length - raw.trimLeft().length;
    final text = context.preformatted
        ? raw.replaceFirst(RegExp(r'^\n+'), '').trimRight()
        : raw.trim();
    if (text.isEmpty) return;
    final shift = context.preformatted ? raw.indexOf(text) : lead;
    blocks.add(
      ReflowBlock.paragraph(
        text,
        formatRuns: [
          for (final run in runs)
            if (run.end - shift > 0 && run.start - shift < text.length)
              FormatRun(
                start: math.max(0, run.start - shift),
                end: math.min(text.length, run.end - shift),
                bold: run.flags.bold,
                italic: run.flags.italic,
                code: run.flags.code,
                strike: run.flags.strike,
                link: run.flags.link,
              ),
        ],
        headingLevel: context.headingLevel,
        quoteDepth: context.quoteDepth,
        indent: context.indent,
        isCode: context.preformatted,
      ),
    );
  }

  void picture(Uint8List? bytes, _Context context) {
    if (bytes == null) return;
    final size = imageSizeOf(bytes);
    if (size == null) return;
    flush(context);
    blocks.add(ReflowBlock.picture(bytes, size));
  }

  void divider(_Context context) {
    flush(context);
    if (blocks.isEmpty || blocks.last.isDivider) return;
    blocks.add(ReflowBlock.paragraph('', isDivider: true));
  }
}

final _whitespace = RegExp(r'\s+');

/// The value of an attribute by its local name, whatever namespace prefix a
/// book gave it — FB2 writes `l:href`, `xlink:href` or a bare `href`.
String? _attribute(XmlElement element, String localName) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }
  return null;
}

// ---------------------------------------------------------------- FB2

/// The blocks of an FB2 book (or a zipped one), cover first.
List<ReflowBlock> fb2Blocks(
  Uint8List bytes,
  String Function(Uint8List) decode,
) {
  final xml = XmlDocument.parse(decode(_unzipFb2(bytes)));
  final root = xml.rootElement;

  final binaries = <String, Uint8List>{};
  for (final binary in root.childElements) {
    if (binary.localName != 'binary') continue;
    final id = _attribute(binary, 'id');
    if (id == null) continue;
    try {
      binaries[id] = base64.decode(
        binary.innerText.replaceAll(_whitespace, ''),
      );
    } on FormatException {
      // A picture that doesn't decode is one the book goes without.
    }
  }
  Uint8List? imageOf(XmlElement element) {
    final href = _attribute(element, 'href');
    if (href == null) return null;
    return binaries[href.startsWith('#') ? href.substring(1) : href];
  }

  final sink = _BlockSink();
  const top = _Context();

  // The cover the book names for itself, before its first page.
  for (final description in root.childElements) {
    if (description.localName != 'description') continue;
    for (final coverpage in description.findAllElements(
      'coverpage',
      namespace: '*',
    )) {
      for (final image in coverpage.childElements) {
        if (image.localName == 'image') sink.picture(imageOf(image), top);
      }
    }
  }

  void walk(XmlNode node, _Context context) {
    if (node is XmlText || node is XmlCDATA) {
      sink.text(node.value ?? '', context);
      return;
    }
    if (node is! XmlElement) return;
    final name = node.localName;
    void children(_Context inner) {
      for (final child in node.children) {
        walk(child, inner);
      }
    }

    void block(_Context inner) {
      sink.flush(context);
      children(inner);
      sink.flush(inner);
    }

    switch (name) {
      case 'section':
        block(context.copyWith(sectionDepth: context.sectionDepth + 1));
      case 'title':
        // The book's own title is the page's biggest heading; a chapter is a
        // step down from it, and a subsection a step further.
        block(
          context.copyWith(
            headingLevel: math.min(6, context.sectionDepth + 1),
            linesJoin: true,
            flags: const _Flags(),
          ),
        );
      case 'subtitle':
        block(context.copyWith(headingLevel: 5, linesJoin: false));
      case 'p' || 'v':
        if (context.linesJoin) {
          children(context);
          sink.lineBreak();
        } else {
          block(context);
        }
      case 'stanza':
        block(context.copyWith(linesJoin: true));
      case 'poem':
        block(context.copyWith(indent: context.indent + 1));
      case 'epigraph' || 'cite' || 'annotation':
        block(context.copyWith(quoteDepth: context.quoteDepth + 1));
      case 'text-author' || 'date':
        block(
          context.copyWith(
            linesJoin: false,
            flags: context.flags.add(italic: true),
          ),
        );
      case 'empty-line':
        sink.flush(context);
      case 'image':
        sink.picture(imageOf(node), context);
      case 'table':
        block(context);
      case 'tr':
        sink.flush(context);
        var first = true;
        for (final cell in node.childElements) {
          if (!first) sink.text(' | ', context);
          first = false;
          for (final child in cell.children) {
            walk(child, context);
          }
        }
        sink.flush(context);
      case 'emphasis':
        children(context.copyWith(flags: context.flags.add(italic: true)));
      case 'strong':
        children(context.copyWith(flags: context.flags.add(bold: true)));
      case 'strikethrough':
        children(context.copyWith(flags: context.flags.add(strike: true)));
      case 'code':
        children(context.copyWith(flags: context.flags.add(code: true)));
      case 'a':
        children(context.copyWith(flags: context.flags.add(link: true)));
      default:
        children(context);
    }
  }

  for (final body in root.childElements) {
    if (body.localName != 'body') continue;
    // The notes and comments bodies come after the story: set off by a rule
    // so the end of the book is not read straight into its footnotes.
    if (_attribute(body, 'name') != null && sink.blocks.isNotEmpty) {
      sink.divider(top);
    }
    walk(body, top);
    sink.flush(top);
  }
  return sink.blocks;
}

/// A `.fb2.zip` is a zip with one FB2 inside; anything else is the book.
Uint8List _unzipFb2(Uint8List bytes) {
  final isZip =
      bytes.length > 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
  if (!isZip) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive.files) {
    if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
      return _bytesOf(file);
    }
  }
  throw const FormatException('No .fb2 inside the archive');
}

Uint8List _bytesOf(ArchiveFile file) {
  final content = file.content;
  return content is Uint8List
      ? content
      : Uint8List.fromList(content as List<int>);
}

// ---------------------------------------------------------------- HTML

const _headingTags = {'h1': 1, 'h2': 2, 'h3': 3, 'h4': 4, 'h5': 5, 'h6': 6};

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'aside',
  'main',
  'nav',
  'figure',
  'figcaption',
  'dl',
  'dt',
  'dd',
  'address',
  'center',
  'caption',
  'table',
  'tbody',
  'thead',
  'tfoot',
  'body',
};

const _skippedTags = {'head', 'script', 'style', 'title', 'noscript'};

/// The blocks of one (X)HTML document of an EPUB. [resolve] finds the bytes
/// of a picture the document refers to by its `src`, relative to the
/// document.
///
/// Returns null when the document isn't well-formed enough to read as XML —
/// the caller then falls back to taking its text alone.
List<ReflowBlock>? htmlBlocks(
  String html,
  Uint8List? Function(String src) resolve,
) {
  final XmlDocument xml;
  try {
    xml = XmlDocument.parse(
      html,
      entityMapping: const XmlDefaultEntityMapping.html5(),
    );
  } on XmlException {
    return null;
  }
  final sink = _BlockSink();
  const top = _Context();

  void walk(XmlNode node, _Context context) {
    if (node is XmlText || node is XmlCDATA) {
      sink.text(node.value ?? '', context);
      return;
    }
    if (node is! XmlElement) return;
    final name = node.localName.toLowerCase();
    if (_skippedTags.contains(name)) return;

    void children(_Context inner) {
      for (final child in node.children) {
        walk(child, inner);
      }
    }

    void block(_Context inner) {
      sink.flush(context);
      children(inner);
      sink.flush(inner);
    }

    final heading = _headingTags[name];
    if (heading != null) {
      block(context.copyWith(headingLevel: heading));
      return;
    }
    switch (name) {
      case 'br':
        if (context.preformatted) {
          sink.text('\n', context);
        } else {
          sink.lineBreak();
        }
      case 'hr':
        sink.divider(context);
      case 'img' || 'image':
        final src = _attribute(node, 'src') ?? _attribute(node, 'href');
        if (src != null) sink.picture(resolve(src), context);
      case 'blockquote':
        block(context.copyWith(quoteDepth: context.quoteDepth + 1));
      case 'pre':
        block(context.copyWith(preformatted: true));
      case 'ul' || 'ol':
        sink.flush(context);
        final inner = context.copyWith(indent: context.indent + 1);
        var number = int.tryParse(_attribute(node, 'start') ?? '') ?? 1;
        for (final child in node.children) {
          if (child is XmlElement && child.localName.toLowerCase() == 'li') {
            sink.flush(inner);
            sink.text(name == 'ol' ? '${number++}. ' : '• ', inner);
            for (final part in child.children) {
              walk(part, inner);
            }
            sink.flush(inner);
          } else {
            walk(child, inner);
          }
        }
        sink.flush(inner);
      case 'li':
        sink.flush(context);
        sink.text('• ', context);
        children(context);
        sink.flush(context);
      case 'tr':
        sink.flush(context);
        var first = true;
        for (final cell in node.childElements) {
          if (!first) sink.text(' | ', context);
          first = false;
          for (final child in cell.children) {
            walk(child, context);
          }
        }
        sink.flush(context);
      case 'em' || 'i' || 'cite' || 'dfn' || 'var':
        children(context.copyWith(flags: context.flags.add(italic: true)));
      case 'strong' || 'b':
        children(context.copyWith(flags: context.flags.add(bold: true)));
      case 's' || 'strike' || 'del':
        children(context.copyWith(flags: context.flags.add(strike: true)));
      case 'code' || 'kbd' || 'samp' || 'tt':
        children(context.copyWith(flags: context.flags.add(code: true)));
      case 'a':
        final isLink = _attribute(node, 'href') != null;
        children(
          isLink
              ? context.copyWith(flags: context.flags.add(link: true))
              : context,
        );
      default:
        if (_blockTags.contains(name)) {
          block(context);
        } else {
          children(context);
        }
    }
  }

  XmlElement? body;
  for (final element in xml.descendantElements) {
    if (element.localName.toLowerCase() == 'body') {
      body = element;
      break;
    }
  }
  walk(body ?? xml.rootElement, top);
  sink.flush(top);
  return sink.blocks;
}

// ---------------------------------------------------------------- DOCX

/// The blocks of a Word document's `word/document.xml`: its heading styles as
/// heading levels, bold, italic and struck-through runs as runs, list items
/// with a bullet at their level, explicit breaks as line breaks.
List<ReflowBlock> docxBlocks(String documentXml) {
  final xml = XmlDocument.parse(documentXml);
  final sink = _BlockSink();
  for (final paragraph in xml.findAllElements('p', namespace: '*')) {
    var context = const _Context();
    final properties = paragraph.childElements
        .where((e) => e.localName == 'pPr')
        .firstOrNull;
    if (properties != null) {
      for (final property in properties.childElements) {
        if (property.localName == 'pStyle') {
          final style = (_attribute(property, 'val') ?? '').toLowerCase();
          final level = _docxHeadingLevel(style);
          if (level > 0) context = context.copyWith(headingLevel: level);
          if (style.contains('quote')) {
            context = context.copyWith(quoteDepth: 1);
          }
        } else if (property.localName == 'numPr') {
          final level = property.childElements
              .where((e) => e.localName == 'ilvl')
              .map((e) => int.tryParse(_attribute(e, 'val') ?? '') ?? 0)
              .firstOrNull;
          context = context.copyWith(indent: (level ?? 0) + 1);
        } else if (property.localName == 'outlineLvl') {
          final level = int.tryParse(_attribute(property, 'val') ?? '');
          if (level != null && context.headingLevel == 0) {
            context = context.copyWith(headingLevel: math.min(6, level + 1));
          }
        }
      }
    }
    if (context.indent > 0) sink.text('• ', context);
    for (final run in paragraph.findAllElements('r', namespace: '*')) {
      var flags = const _Flags();
      final runProperties = run.childElements
          .where((e) => e.localName == 'rPr')
          .firstOrNull;
      if (runProperties != null) {
        for (final property in runProperties.childElements) {
          final on = !const {
            '0',
            'false',
            'none',
          }.contains(_attribute(property, 'val')?.toLowerCase());
          if (!on) continue;
          switch (property.localName) {
            case 'b':
              flags = flags.add(bold: true);
            case 'i':
              flags = flags.add(italic: true);
            case 'strike' || 'dstrike':
              flags = flags.add(strike: true);
          }
        }
      }
      final runContext = context.copyWith(flags: flags);
      for (final part in run.childElements) {
        switch (part.localName) {
          case 't':
            sink.text(part.innerText, runContext);
          case 'tab':
            sink.text(' ', runContext);
          case 'br' || 'cr':
            sink.lineBreak();
        }
      }
    }
    sink.flush(context);
  }
  return sink.blocks;
}

int _docxHeadingLevel(String style) {
  if (style == 'title') return 1;
  final match = RegExp(r'^(?:heading|заголовок)\s*([1-6])$').firstMatch(style);
  if (match == null) return 0;
  return int.parse(match.group(1)!);
}
