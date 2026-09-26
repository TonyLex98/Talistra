import 'dart:math' as math;

import 'reflow_builder.dart';

/// Reads Markdown source into [ReflowBlock]s the paginated reader can lay
/// out — headings at their real levels, lists and blockquotes indented,
/// fenced code and tables set in monospace on their own panel, rules drawn
/// as rules — instead of flattening it to paragraphs the way a .txt file is.
///
/// The output is the same shape every other text format produces, so page
/// turning, tap-to-translate, search and the reading themes all keep working
/// over it untouched. Structure that can't survive reflow — a picture the
/// file only points at, a raw HTML tag — degrades to its text rather than
/// quietly disappearing.

/// How far one level of list nesting moves a block to the right.
const double markdownListIndent = 18;

/// How far one level of blockquote moves a block to the right; the bar is
/// drawn inside that space, hugging the text it marks.
const double markdownQuoteIndent = 15;

/// How wide a blockquote's bar is.
const double markdownQuoteBarWidth = 3;

/// The padding inside a code panel, which is also how far its text sits in
/// from the panel's painted edges.
const double markdownCodePadding = 11;

/// Where a table stops being narrow enough for its padded columns to stay
/// lined up across a phone's column and is printed with single spaces
/// instead, wrapping however it has to.
///
/// The column is about 30 monospace characters wide at a normal reading size,
/// so a wider row would break in the middle of a cell — which reads worse
/// than the alignment it was meant to keep.
const int _maxAlignedTableWidth = 30;

/// The visual kind of a block, used to decide the space above it: a list
/// item after another list item wants far less room than a paragraph after a
/// list.
enum _Kind { paragraph, heading, listItem, code, divider }

/// How much bigger than the reading font each heading level is set, and how
/// much tighter its leading. Level 1 is a page's title; by level 6 a heading
/// is barely larger than prose, just bolder. Indexed by level, so slot 0 is
/// unused.
const List<double> _headingSize = [0, 1.62, 1.38, 1.2, 1.08, 1.0, 0.94];
const List<double> _headingHeight = [0, 0.8, 0.84, 0.86, 0.9, 0.95, 1.0];

/// How far a block's text sits in from the reading column's edges, given its
/// quoting, nesting and the panel it is drawn inside. The reader paints with
/// these and the paginator measures with the same ones — see
/// `paginateReflowBlocks`'s `insetsFor`.
({double left, double right}) markdownBlockInsets(ReflowBlock block) {
  var left =
      block.quoteDepth * markdownQuoteIndent +
      block.indent * markdownListIndent;
  var right = 0.0;
  if (block.isCode) {
    left += markdownCodePadding;
    right += markdownCodePadding;
  }
  return (left: left.toDouble(), right: right.toDouble());
}

/// How a block of this file's making is set, on top of the reader's own
/// font, size and ink: headings at their level's size in the reader's bold
/// weight, code and tables in monospace.
class MarkdownStyle {
  const MarkdownStyle(
    this.sizeFactor,
    this.heightFactor, {
    this.bold = false,
    this.monospace = false,
  });

  final double sizeFactor;
  final double heightFactor;
  final bool bold;

  /// Set in the platform's monospace face, whose fixed advance is what keeps
  /// a code block's indentation and a table's columns lined up.
  final bool monospace;
}

final MarkdownStyle _bodyStyle = MarkdownStyle(1.0, 1.0);

/// The typography one of this file's blocks asks for, or null for a block
/// that came from anywhere else and wants the reader's plain body style.
MarkdownStyle? markdownStyle(ReflowBlock block) {
  if (block.isCode) {
    // Tighter than prose and a little smaller: the panel has to hold lines
    // as their author indented them, and the extra leading is the only
    // vertical air the panel gets (see [_Markdown]'s note on why a panel is
    // never taller than its text).
    return MarkdownStyle(0.9, 1.3, monospace: true);
  }
  final level = block.headingLevel;
  if (level == 0) return block.isDivider ? null : _bodyStyle;
  final depth = level > 6 ? 6 : level;
  return MarkdownStyle(_headingSize[depth], _headingHeight[depth], bold: true);
}

/// Parses [source] into blocks, ready for `buildTxtPagesFromBlocks`.
List<ReflowBlock> parseMarkdownBlocks(String source) {
  return _Markdown(_normalize(source), topLevel: true).parse();
}

String _normalize(String source) {
  final text = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Tabs are indentation, and a reader that nests by counting spaces has to
  // see the same depths whether the file was written with tabs or spaces.
  return text.split('\n').map(_expandTabs).join('\n');
}

String _expandTabs(String line) {
  if (!line.contains('\t')) return line;
  final buffer = StringBuffer();
  var column = 0;
  for (final ch in line.split('')) {
    if (ch != '\t') {
      buffer.write(ch);
      column++;
      continue;
    }
    final width = 4 - (column % 4);
    buffer.write(' ' * width);
    column += width;
  }
  return buffer.toString();
}

class _Markdown {
  _Markdown(this.source, {this.topLevel = false, this.quoteDepth = 0});

  final String source;

  /// Only the document's own first line can open a block of YAML front
  /// matter, and only a top-level parse is looking at that line.
  final bool topLevel;

  /// How deeply the text being parsed sits inside blockquotes.
  final int quoteDepth;

  final List<ReflowBlock> _blocks = [];
  late final List<String> _lines = source.split('\n');

  _Kind? _previousKind;
  int _previousIndent = 0;

  /// The indents of the list levels currently open, outermost first, so both
  /// two- and four-space nesting land on consecutive depths.
  final List<int> _levels = [];

  List<ReflowBlock> parse() {
    var index = 0;
    if (topLevel) index = _skipFrontMatter(index);
    while (index < _lines.length) {
      index = _parseLine(index);
    }
    return _blocks;
  }

  /// A file that opens with `---` and closes it before its first heading is
  /// front matter — metadata for whatever generated it, not what the reader
  /// came for.
  int _skipFrontMatter(int index) {
    if (index >= _lines.length || _lines[index].trim() != '---') return index;
    for (var i = index + 1; i < _lines.length; i++) {
      final trimmed = _lines[i].trim();
      if (trimmed == '---' || trimmed == '...') return i + 1;
      if (trimmed.isEmpty) break;
    }
    return index;
  }

  /// Handles the line at [index] and returns the index to continue from —
  /// always further along than it came in, so the scan makes progress.
  int _parseLine(int index) {
    final line = _lines[index];
    if (line.trim().isEmpty) {
      _levels.clear();
      return index + 1;
    }

    if (_fence.matchAsPrefix(line) != null) return _parseCode(index);

    if (_thematicBreak.hasMatch(line)) {
      _emit(
        () => ReflowBlock.paragraph(
          '',
          isDivider: true,
          quoteDepth: quoteDepth,
          gapAbove: _gapAbove(_Kind.divider, 0),
        ),
        _Kind.divider,
        indent: 0,
      );
      return index + 1;
    }

    if (_quotePrefix.matchAsPrefix(line) != null) return _parseQuote(index);

    final heading = _atxHeading.matchAsPrefix(line);
    if (heading != null) {
      _levels.clear();
      final text = _cleanHeading(heading.group(2) ?? '');
      if (text.isEmpty) return index + 1;
      final level = heading.group(1)!.length;
      _emit(
        () => _paragraph(
          text,
          headingLevel: level,
          gap: _gapAbove(_Kind.heading, 0, level),
        ),
        _Kind.heading,
        indent: 0,
      );
      return index + 1;
    }

    if (_listMarker.matchAsPrefix(line) != null) return _parseListItem(index);

    if (_isTableStart(index)) return _parseTable(index);

    return _parseParagraph(index);
  }

  // ----------------------------------------------------------- structures

  /// A blockquote: the run of quoted lines, one `>` marker stripped from
  /// each, parsed again one level deeper — so `> >` nests by itself, and a
  /// list or a heading inside a quote keeps its own shape.
  int _parseQuote(int index) {
    var end = index;
    final content = <String>[];
    while (end < _lines.length) {
      final line = _lines[end];
      final prefix = _quotePrefix.matchAsPrefix(line);
      if (prefix != null) {
        content.add(line.substring(prefix.end));
        end++;
        continue;
      }
      // A blank line, or a line that starts something on its own, ends the
      // quote; anything else is a lazy continuation of the quoted paragraph.
      if (line.trim().isEmpty || _startsBlock(line)) break;
      content.add(line.trimLeft());
      end++;
    }

    final inner = _Markdown(
      content.join('\n').trimRight(),
      quoteDepth: quoteDepth + 1,
    ).parse();
    _levels.clear();
    _blocks.addAll(inner);
    if (inner.isNotEmpty) {
      _previousKind = _kindOf(inner.last);
      _previousIndent = inner.last.indent;
    }
    return end;
  }

  /// A fenced code block, unterminated ones running to the end of the file
  /// the way an author with a missing fence meant it. Its lines keep their
  /// own breaks and get no inline parsing — that is the point of a fence.
  int _parseCode(int index) {
    final opener = _fence.matchAsPrefix(_lines[index])!;
    final marker = opener.group(1)!;
    var end = index + 1;
    final body = <String>[];
    while (end < _lines.length) {
      final closer = _fence.matchAsPrefix(_lines[end]);
      if (closer != null && closer.group(1)!.startsWith(marker)) {
        end++;
        break;
      }
      body.add(_lines[end]);
      end++;
    }
    while (body.isNotEmpty && body.last.trim().isEmpty) {
      body.removeLast();
    }
    _levels.clear();
    // The language after the opening fence names a syntax highlighter this
    // reader doesn't have, so it is dropped rather than printed.
    if (body.isEmpty) return end;
    _emit(
      () => ReflowBlock.paragraph(
        body.join('\n'),
        isCode: true,
        quoteDepth: quoteDepth,
        gapAbove: _gapAbove(_Kind.code, 0),
      ),
      _Kind.code,
      indent: 0,
    );
    return end;
  }

  /// One bullet or numbered item, at the depth its own indentation says.
  /// Continuation lines — the wrapped rest of the item, and the deeper
  /// items inside it — are picked up by the passes that follow.
  int _parseListItem(int index) {
    final line = _lines[index];
    final marker = _listMarker.matchAsPrefix(line)!;
    final indent = _leadingWidth(line);
    _openLevel(indent);
    final level = _levels.length - 1;
    final bullet = _bulletText(marker.group(0)!);
    var rest = line.substring(marker.end);
    // A task list's checkbox is part of the item, not of its text.
    final task = _taskMarker(rest) ?? '';
    if (task.isNotEmpty) rest = rest.substring(3);
    final content = <String>['$bullet$task${rest.trim()}'];
    var end = index + 1;
    while (end < _lines.length) {
      final next = _lines[end];
      if (next.trim().isEmpty || _startsBlock(next)) break;
      // A plain indented line under an item is the item's own text
      // continuing; a shallower one belongs to something above it, and
      // rejoining it here would fold a sibling's paragraph into this item.
      if (_leadingWidth(next) < indent) break;
      content.add(next.trimLeft());
      end++;
    }
    _emit(
      () => _paragraph(
        content.join(' '),
        indent: level,
        gap: _gapAbove(_Kind.listItem, level),
      ),
      _Kind.listItem,
      indent: level,
    );
    return end;
  }

  void _openLevel(int indent) {
    while (_levels.isNotEmpty && indent < _levels.last) {
      _levels.removeLast();
    }
    if (_levels.isEmpty || indent > _levels.last) _levels.add(indent);
  }

  int _parseParagraph(int index) {
    final lines = <String>[_lines[index]];
    var end = index + 1;
    var headingLevel = 0;
    while (end < _lines.length) {
      final next = _lines[end];
      if (next.trim().isEmpty) break;
      final setext = _setextLevel(next);
      if (setext != null) {
        headingLevel = setext;
        end++;
        break;
      }
      if (_startsBlock(next)) break;
      lines.add(next);
      end++;
    }

    final text = _joinLines(lines);
    if (text.isEmpty) return end;
    _levels.clear();
    if (headingLevel > 0) {
      _emit(
        () => _paragraph(
          text,
          headingLevel: headingLevel,
          gap: _gapAbove(_Kind.heading, 0, headingLevel),
        ),
        _Kind.heading,
        indent: 0,
      );
    } else {
      _emit(
        () => _paragraph(text, gap: _gapAbove(_Kind.paragraph, 0)),
        _Kind.paragraph,
        indent: 0,
      );
    }
    return end;
  }

  /// A row of `===` or `---` under a line of text is a level 1 or level 2
  /// heading in the oldest convention still written by hand, mostly in
  /// files meant for tools that render to HTML.
  int? _setextLevel(String line) {
    final match = _setextUnderline.matchAsPrefix(line);
    if (match == null) return null;
    // `---` under text is a heading; on its own line it is a rule, and
    // `_parseLine` has already taken that case.
    return match.group(1)!.startsWith('=') ? 1 : 2;
  }

  /// A GitHub-flavoured pipe table, printed the way its author drew it: rows
  /// of cells padded to their column's width and separated by a bar, on the
  /// code panel's monospace face. That is the only way columns can survive a
  /// page that reflows, and the header row goes bold in place of the
  /// separator row that said which it was.
  int _parseTable(int index) {
    final header = _cells(_lines[index]);
    final separators = _cells(_lines[index + 1]);
    final aligns = [
      for (var i = 0; i < header.length; i++)
        _alignmentOf(i < separators.length ? separators[i] : '-'),
    ];
    final rows = <List<String>>[header.map(_plainCell).toList()];
    var end = index + 2;
    while (end < _lines.length &&
        _lines[end].trim().isNotEmpty &&
        _lines[end].contains('|')) {
      final cells = _cells(_lines[end]);
      if (cells.isEmpty) break;
      for (var i = cells.length; i < header.length; i++) {
        cells.add('');
      }
      rows.add(cells.take(header.length).map(_plainCell).toList());
      end++;
    }

    final widths = List<int>.filled(header.length, 0);
    for (final row in rows) {
      for (var i = 0; i < widths.length; i++) {
        widths[i] = math.max(widths[i], row[i].length);
      }
    }
    final total =
        widths.fold<int>(0, (a, b) => a + b) +
        3 * math.max(0, widths.length - 1);
    final pad = total <= _maxAlignedTableWidth;

    final lines = [
      for (final row in rows)
        [
          for (var i = 0; i < row.length; i++)
            pad ? _pad(row[i], widths[i], aligns[i]) : row[i],
        ].join(' | '),
    ];

    _levels.clear();
    _emit(
      () => ReflowBlock.paragraph(
        lines.join('\n'),
        formatRuns: [FormatRun(start: 0, end: lines.first.length, bold: true)],
        isCode: true,
        quoteDepth: quoteDepth,
        gapAbove: _gapAbove(_Kind.code, 0),
      ),
      _Kind.code,
      indent: 0,
    );
    return end;
  }

  bool _isTableStart(int index) {
    if (index + 1 >= _lines.length) return false;
    final line = _lines[index];
    if (!line.contains('|') || _isSeparatorRow(line)) return false;
    return _isSeparatorRow(_lines[index + 1]);
  }

  bool _isSeparatorRow(String line) {
    if (!line.contains('|') && !line.contains('-')) return false;
    final cells = _cells(line);
    return cells.length > 1 &&
        cells.every((cell) => RegExp(r'^:?-+:?$').hasMatch(cell));
  }

  /// Whether [line] opens a block of its own, rather than continuing the one
  /// being read.
  bool _startsBlock(String line) {
    if (line.trim().isEmpty) return true;
    return _fence.hasMatch(line) ||
        _thematicBreak.hasMatch(line) ||
        _quotePrefix.hasMatch(line) ||
        _atxHeading.hasMatch(line) ||
        _listMarker.matchAsPrefix(line) != null;
  }

  // ------------------------------------------------------------ emitting

  /// Runs [build] and records the space this block wants above the one
  /// before it, which is what makes a list read as a list.
  void _emit(ReflowBlock Function() build, _Kind kind, {required int indent}) {
    final block = build();
    _blocks.add(block);
    _previousKind = kind;
    _previousIndent = indent;
  }

  ReflowBlock _paragraph(
    String text, {
    int headingLevel = 0,
    int indent = 0,
    double? gap,
  }) {
    final inline = _Inline(text).parse();
    return ReflowBlock.paragraph(
      inline.text,
      formatRuns: inline.runs,
      headingLevel: headingLevel,
      quoteDepth: quoteDepth,
      indent: indent,
      gapAbove: gap,
    );
  }

  /// The gap above a block of [kind] that follows the block emitted before
  /// it, or null for the reading view's usual gap between blocks.
  double? _gapAbove(_Kind kind, int indent, [int headingLevel = 0]) {
    final previous = _previousKind;
    if (previous == null) return null;
    if (kind == _Kind.listItem && previous == _Kind.listItem) {
      return indent > _previousIndent ? 8 : 3;
    }
    switch (kind) {
      case _Kind.heading:
        return headingLevel <= 1
            ? 34.0
            : headingLevel == 2
            ? 27.0
            : 21.0;
      case _Kind.divider:
        return 14.0;
      case _Kind.code:
        return 20.0;
      case _Kind.listItem:
        return 12.0;
      case _Kind.paragraph:
        return previous == _Kind.code || previous == _Kind.divider
            ? 18.0
            : null;
    }
  }
}

/// The kind an already-built block reads as, for carrying the running
/// "what came before this" state across a nested parse.
_Kind _kindOf(ReflowBlock block) {
  if (block.isDivider) return _Kind.divider;
  if (block.isCode) return _Kind.code;
  if (block.headingLevel > 0) return _Kind.heading;
  return _Kind.paragraph;
}

// ----------------------------------------------------------- line helpers

final _quotePrefix = RegExp(r'^\s{0,3}>\s?');

final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})(.*)$');

/// Three or more of one punctuation character, alone on a line. Checked
/// before the setext rules, so the `---` under a paragraph stays a heading
/// underline and a `---` on its own stays a rule.
final _thematicBreak = RegExp(r'^\s{0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$');

final _atxHeading = RegExp(r'^\s{0,3}(#{1,6})(?:[ \t]+(.*))?$');

/// A bullet or a number opening a list item, at whatever depth it is
/// indented. A nested item is written two or four spaces in from its parent
/// — an author can't know how wide the reader's column is — so indentation
/// alone can never mean a code block here, and only fenced code is read as
/// one.
final _listMarker = RegExp(r'^[ \t]*(?:[*+-]|\(?[0-9]{1,9}[.)])(?:[ \t]+|$)');

final _setextUnderline = RegExp(r'^\s{0,3}(=+|-+)\s*$');

/// The bullet or number a list item is drawn with.
///
/// Asterisks, plus signs and hyphens all read as the same round bullet, the
/// way every rendered Markdown does — three dash shapes down one list only
/// looks like a mistake. A numbered item keeps its number, in one style:
/// `1)`, `(1)` and `1.` all come out as `1.`
String _bulletText(String marker) {
  final text = marker.trim();
  if (text == '-' || text == '*' || text == '+') return '• ';
  final number = RegExp(r'^\(?([0-9]+)').firstMatch(text)?.group(1);
  return number == null ? '$text ' : '$number. ';
}

String? _taskMarker(String rest) {
  if (rest.startsWith('[ ]')) return '☐ ';
  if (rest.startsWith('[x]') || rest.startsWith('[X]')) return '☑ ';
  return null;
}

int _leadingWidth(String line) {
  var width = 0;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == ' ') {
      width++;
    } else if (ch == '\t') {
      width += 4 - (width % 4);
    } else {
      break;
    }
  }
  return width;
}

String _cleanHeading(String text) {
  var result = text.trim();
  while (result.endsWith('#')) {
    result = result.substring(0, result.length - 1).trimRight();
  }
  return result;
}

/// Joins a paragraph's source lines. A single newline in Markdown is
/// insignificant and part of the same sentence; two trailing spaces (or a
/// trailing backslash) are an explicit line break the author meant, and the
/// reader has to tell the two apart or every wrapped line becomes one.
String _joinLines(List<String> lines) {
  final buffer = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final hard = RegExp(r'( {2,}|\\)$').hasMatch(raw);
    buffer.write(raw.trim());
    if (i == lines.length - 1) break;
    buffer.write(hard ? '\n' : ' ');
  }
  return buffer.toString().trim();
}

/// Splits a table row on the bars that separate cells, ignoring escaped ones
/// and the optional bars at either end.
List<String> _cells(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|') && !text.endsWith(r'\|')) {
    text = text.substring(0, text.length - 1);
  }
  final cells = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == r'\' && i + 1 < text.length && text[i + 1] == '|') {
      current.write('|');
      i++;
      continue;
    }
    if (ch == '|') {
      cells.add(current.toString().trim());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  cells.add(current.toString().trim());
  return cells;
}

/// 0 left, 1 centred, 2 right, read off the `:---`, `:---:` / `---:` of a
/// table's separator row.
int _alignmentOf(String separator) {
  final left = separator.startsWith(':');
  final right = separator.endsWith(':');
  if (left && right) return 1;
  if (right) return 2;
  return 0;
}

String _plainCell(String cell) => _Inline(cell).parse().text;

String _pad(String cell, int width, int alignment) {
  if (cell.length >= width) return cell;
  final gap = ' ' * (width - cell.length);
  switch (alignment) {
    case 1:
      final left = gap.length ~/ 2;
      return '${gap.substring(0, left)}$cell${gap.substring(left)}';
    case 2:
      return '$gap$cell';
    default:
      return '$cell$gap';
  }
}

// ---------------------------------------------------------------- inline

/// The styling a span of inline text carries down through the scanner.
class _Flags {
  const _Flags({this.bold, this.italic, this.code, this.strike, this.link});

  static const _Flags plain = _Flags();

  final bool? bold;
  final bool? italic;
  final bool? code;
  final bool? strike;
  final bool? link;

  bool get any =>
      bold == true ||
      italic == true ||
      code == true ||
      strike == true ||
      link == true;

  _Flags add({
    bool? bold,
    bool? italic,
    bool? code,
    bool? strike,
    bool? link,
  }) => _Flags(
    bold: this.bold == true || bold == true,
    italic: this.italic == true || italic == true,
    code: this.code == true || code == true,
    strike: this.strike == true || strike == true,
    link: this.link == true || link == true,
  );

  FormatRun run(int start, int end) => FormatRun(
    start: start,
    end: end,
    bold: bold == true,
    italic: italic == true,
    code: code == true,
    strike: strike == true,
    link: link == true,
  );
}

/// Turns one span of inline Markdown into plain text plus the [FormatRun]s
/// saying how each part of it was set.
///
/// Offsets are recorded against the *output*, because that is what the
/// reader indexes for taps, search hits and the emphasis itself — and the
/// markup characters dropped along the way make source and output disagree by
/// a varying amount, so the two can only be built together.
class _Inline {
  _Inline(this.source);

  final String source;
  // Reassigned rather than mutated in place at one point: a `<br>` tag has to
  // erase the spaces that came before it, and they are already written.
  StringBuffer _out = StringBuffer();
  final List<FormatRun> _runs = [];

  ({String text, List<FormatRun> runs}) parse() {
    _scan(0, source.length, _Flags.plain);
    final full = _out.toString();
    final lead = full.length - full.trimLeft().length;
    final text = full.trim();
    return (
      text: text,
      runs: [
        // A run that started past where the trimmed text ends was made of
        // nothing but markup (an empty `** **`, say) and paints nothing.
        // The ends are clamped for the same reason: markup-only tail padding
        // can leave a run reaching past the characters that survived.
        for (final run in _runs)
          if (run.start >= lead &&
              run.start - lead < text.length &&
              math.min(run.end - lead, text.length) > run.start - lead)
            FormatRun(
              start: run.start - lead,
              end: math.min(run.end - lead, text.length),
              bold: run.bold,
              italic: run.italic,
              code: run.code,
              strike: run.strike,
              link: run.link,
            ),
      ],
    );
  }

  void _scan(int from, int to, _Flags flags) {
    final plain = StringBuffer();
    var i = from;

    void flush() {
      if (plain.isEmpty) return;
      _write(
        flags.code == true
            ? plain.toString()
            : unescapeMarkdownText(plain.toString()),
        flags,
      );
      plain.clear();
    }

    while (i < to) {
      final ch = source[i];
      if (ch == r'\' && i + 1 < to && _isPunctuation(source[i + 1])) {
        plain.write(source[i + 1]);
        i += 2;
        continue;
      }
      // Inside a code span nothing is markup, backticks and all — which is
      // how a document about Markdown writes about Markdown.
      if (flags.code == true) {
        plain.write(ch);
        i++;
        continue;
      }
      if (ch == '`') {
        final span = _backtickSpan(i, to);
        if (span != null) {
          flush();
          var body = source.substring(span.body, span.end - span.marker);
          if (body.length > 2 && body.startsWith(' ') && body.endsWith(' ')) {
            body = body.substring(1, body.length - 1);
          }
          _write(body, flags.add(code: true));
          i = span.end;
          continue;
        }
      }
      if (ch == '~' && source.startsWith('~~', i)) {
        final close = source.indexOf('~~', i + 2);
        if (close > i + 2 && close < to) {
          flush();
          _scan(i + 2, close, flags.add(strike: true));
          i = close + 2;
          continue;
        }
      }
      if ((ch == '*' || ch == '_') && _opensEmphasis(i, to, ch)) {
        final span = _emphasisSpan(i, to, ch);
        if (span != null) {
          flush();
          _scan(
            span.body,
            span.close,
            flags.add(bold: span.marker >= 2, italic: span.marker != 2),
          );
          i = span.next;
          continue;
        }
      }
      if (ch == '!' && source.startsWith('![', i)) {
        // A picture the file only points at can't be shown here, but the
        // words the author wrote for it can, and they describe it.
        final link = _linkAt(i + 1, to);
        if (link != null) {
          flush();
          _scan(
            link.labelStart,
            link.labelEnd,
            flags.add(italic: true, link: true),
          );
          i = link.end;
          continue;
        }
      }
      if (ch == '[') {
        final link = _linkAt(i, to);
        if (link != null) {
          flush();
          _scan(link.labelStart, link.labelEnd, flags.add(link: true));
          i = link.end;
          continue;
        }
      }
      if (ch == '<') {
        final close = source.indexOf('>', i + 1);
        if (close > i + 1 && close <= to) {
          final inner = source.substring(i + 1, close);
          flush();
          if (_autoLink.hasMatch(inner)) {
            _write(_urlOf(inner), flags.add(link: true));
          } else if (_lineBreakTag.hasMatch(inner)) {
            // The one tag that means something to a reader rather than to a
            // browser: an explicit break in the line. The spaces around it
            // are part of the author's typing, not of the new line, so the
            // ones before the tag are dropped and the ones after it skipped.
            _out = StringBuffer(_out.toString().trimRight());
            _write('\n', _Flags.plain);
            i = close + 1;
            while (i < to && _isSpace(source[i])) {
              i++;
            }
            continue;
          }
          // Any other tag is raw HTML this reader can't honour; the text
          // inside it still belongs to the sentence, the tag doesn't.
          i = close + 1;
          continue;
        }
      }
      plain.write(ch);
      i++;
    }
    flush();
  }

  void _write(String text, _Flags flags) {
    if (text.isEmpty) return;
    final start = _out.length;
    _out.write(text);
    if (flags.any) _runs.add(flags.run(start, _out.length));
  }

  bool _opensEmphasis(int i, int to, String ch) {
    // `_` separates the parts of a `snake_case` name as often as it sets
    // emphasis, so it only opens when the word before it has ended.
    if (ch == '_' && i > 0 && _isWordChar(source[i - 1])) return false;
    if (i + 1 >= to) return false;
    return !_isSpace(source[i + 1]);
  }

  ({int marker, int body, int close, int next})? _emphasisSpan(
    int i,
    int to,
    String ch,
  ) {
    var marker = 1;
    while (marker < 3 && i + marker < to && source[i + marker] == ch) {
      marker++;
    }
    for (var j = i + marker + 1; j < to; j++) {
      if (source[j] != ch) continue;
      if (_isSpace(source[j - 1])) continue;
      if (ch == '_' && _isWordChar(source[j + 1 < to ? j + 1 : to - 1])) {
        continue;
      }
      var run = 1;
      while (j + run < to && source[j + run] == ch) {
        run++;
      }
      if (run < marker) {
        j += run - 1;
        continue;
      }
      return (marker: marker, body: i + marker, close: j, next: j + marker);
    }
    return null;
  }

  /// The backtick code span opened at [i]: how long its marker is and where
  /// the span ends, or null when it is never closed.
  ({int marker, int body, int end})? _backtickSpan(int i, int to) {
    var marker = 0;
    while (i + marker < to && source[i + marker] == '`') {
      marker++;
    }
    var j = i + marker;
    while (j < to) {
      if (source[j] != '`') {
        j++;
        continue;
      }
      var run = 0;
      while (j + run < to && source[j + run] == '`') {
        run++;
      }
      if (run == marker) {
        return (marker: marker, body: i + marker, end: j + run);
      }
      j += run;
    }
    return null;
  }

  /// The `[label](target)` or `[label][reference]` link opened at [i]. The
  /// target is dropped: the label is what the author wrote to be read, and
  /// in this app a tap on text asks for a translation rather than opening a
  /// address.
  ({int labelStart, int labelEnd, int end})? _linkAt(int i, int to) {
    final close = _pairOf(i, to, '[', ']');
    if (close == null) return null;
    var j = close + 1;
    if (j < to && source[j] == ':') j++;
    if (j >= to) return null;
    if (source[j] == '(') {
      final end = _pairOf(j, to, '(', ')');
      if (end == null) return null;
      return (labelStart: i + 1, labelEnd: close, end: end + 1);
    }
    if (source[j] == '[') {
      final end = source.indexOf(']', j + 1);
      if (end < 0 || end >= to) return null;
      return (labelStart: i + 1, labelEnd: close, end: end + 1);
    }
    return null;
  }

  int? _pairOf(int i, int to, String open, String close) {
    var depth = 0;
    for (var j = i; j < to; j++) {
      final ch = source[j];
      if (ch == r'\') {
        j++;
        continue;
      }
      if (ch == open) {
        depth++;
      } else if (ch == close) {
        depth--;
        if (depth == 0) return j;
      }
    }
    return null;
  }
}

final _autoLink = RegExp(r'^(https?://\S+|mailto:\S+|\S+@\S+\.\S+)$');

final _lineBreakTag = RegExp(r'^/?br\s*/?$', caseSensitive: false);

String _urlOf(String inner) {
  final text = inner.trim();
  return text.startsWith('mailto:') ? text.substring(7) : text;
}

bool _isWordChar(String ch) =>
    RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch);

bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n';

bool _isPunctuation(String ch) =>
    RegExp(r'''[\\`*_{}\[\]()#+\-.!>~|:&;"']''', unicode: true).hasMatch(ch);

/// Replaces the character references Markdown files are full of.
String unescapeMarkdownText(String text) {
  if (!text.contains('&')) return text;
  var result = text;
  _entities.forEach((from, to) => result = result.replaceAll(from, to));
  return result.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (match) {
    final radix = match.group(1)!.isEmpty ? 10 : 16;
    final code = int.tryParse(match.group(2)!, radix: radix);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  });
}

const Map<String, String> _entities = {
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
  '&times;': '×',
  '&deg;': '°',
};
