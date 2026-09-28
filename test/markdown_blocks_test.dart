import 'package:flutter_test/flutter_test.dart';
import 'package:transreade/utils/markdown_blocks.dart';
import 'package:transreade/utils/reflow_builder.dart';

/// The blocks a document turned into, as `[kind, text]` pairs that read well
/// in a failing expectation.
List<String> _shape(List<ReflowBlock> blocks) => [
  for (final b in blocks)
    [
      if (b.headingLevel > 0) 'h${b.headingLevel}',
      if (b.isCode) 'code',
      if (b.isDivider) 'rule',
      if (b.quoteDepth > 0) 'q${b.quoteDepth}',
      if (b.indent > 0) 'i${b.indent}',
      b.text,
    ].join(' ').trim(),
];

void main() {
  group('markdown structure', () {
    test('headings keep their level, and so does the space above them', () {
      final blocks = parseMarkdownBlocks('''
# Title

## Section

Body text goes here.
''');
      expect(_shape(blocks), [
        'h1 Title',
        'h2 Section',
        'Body text goes here.',
      ]);
      // A section title needs more room above it than the next line of a
      // list does, and the view can only know that from the block itself.
      expect(blocks.first.gapAbove, isNull);
      expect(blocks[1].gapAbove, greaterThan(blocks[2].gapAbove ?? 0));
    });

    test('a line of === under text is a heading, not a rule', () {
      expect(
        _shape(parseMarkdownBlocks('Chapter one\n============\n\nText.')),
        ['h1 Chapter one', 'Text.'],
      );
    });

    test('a --- on its own line is a rule', () {
      final blocks = parseMarkdownBlocks('Before\n\n---\n\nAfter');
      expect(_shape(blocks), ['Before', 'rule', 'After']);
      expect(blocks[1].text, isEmpty);
    });

    test('lists nest by indentation and keep their markers', () {
      final blocks = parseMarkdownBlocks('''
Fruits:

- apple
- citrus
  - lemon
    - meyer
- plum

1. one
2. two
''');
      expect(_shape(blocks), [
        'Fruits:',
        '• apple',
        '• citrus',
        'i1 • lemon',
        'i2 • meyer',
        '• plum',
        '1. one',
        '2. two',
      ]);
      expect(blocks[3].indent, 1);
      expect(blocks[4].indent, 2);
    });

    test('a blank line inside a list keeps its nesting', () {
      final blocks = parseMarkdownBlocks('''
- citrus

  - lemon

  - lime

- plum
''');
      expect(_shape(blocks), ['• citrus', 'i1 • lemon', 'i1 • lime', '• plum']);
    });

    test('an indented paragraph after a blank line stays with its item', () {
      final blocks = parseMarkdownBlocks('''
- first item

  more about the first item

- second item

Back to prose.
''');
      expect(_shape(blocks), [
        '• first item',
        'i1 more about the first item',
        '• second item',
        'Back to prose.',
      ]);
    });

    test('an item continues over its own wrapped lines', () {
      final blocks = parseMarkdownBlocks('- first part\n  second part');
      expect(blocks.single.text, '• first part second part');
    });

    test('a task list reads as checkboxes', () {
      expect(
        parseMarkdownBlocks('- [ ] tidy\n- [x] shipped').map((b) => b.text),
        ['• ☐ tidy', '• ☑ shipped'],
      );
    });

    test('blockquotes gain a depth, and their own structure survives', () {
      final blocks = parseMarkdownBlocks('''
> Quoted words
> still words.
>
> ### Inside the quote
>
> - item

Plain afterwards.
''');
      expect(_shape(blocks), [
        'q1 Quoted words still words.',
        'h3 q1 Inside the quote',
        // A list directly inside the quote is at its top level; only a list
        // nested in another list gains an indent of its own.
        'q1 • item',
        'Plain afterwards.',
      ]);
    });

    test('a nested quote is one level deeper', () {
      expect(_shape(parseMarkdownBlocks('> outer\n>\n> > inner')), [
        'q1 outer',
        'q2 inner',
      ]);
    });

    test('fenced code keeps its lines, indentation and literal stars', () {
      final blocks = parseMarkdownBlocks('''
Before

```dart
void main() {
  // **not bold**
}
```

After
''');
      expect(_shape(blocks), [
        'Before',
        'code void main() {\n  // **not bold**\n}',
        'After',
      ]);
      expect(blocks[1].isCode, isTrue);
      // A panel that emphasised anything inside itself would be lying about
      // what the author typed.
      expect(blocks[1].formatRuns, isEmpty);
    });

    test('an unterminated fence runs to the end of the file', () {
      final blocks = parseMarkdownBlocks('Text\n\n```\ncode here');
      expect(_shape(blocks), ['Text', 'code code here']);
    });

    test('front matter is metadata, not reading', () {
      expect(_shape(parseMarkdownBlocks('---\ntitle: Notes\n---\n\n# Notes')), [
        'h1 Notes',
      ]);
    });
  });

  group('markdown inline styling', () {
    test(
      'emphasis, code, strike and links become runs over the plain text',
      () {
        final blocks = parseMarkdownBlocks(
          'A **bold** word, *an italic* one, `code`, ~~removed~~ '
          'and [a link](https://example.com).',
        );
        final block = blocks.single;
        expect(
          block.text,
          'A bold word, an italic one, code, removed and a link.',
        );
        ReflowBlock b() => block;
        FormatRun of(String needle) {
          final start = b().text.indexOf(needle);
          return b().formatRuns.firstWhere(
            (r) => r.start == start && r.end == start + needle.length,
          );
        }

        expect(of('bold').bold, isTrue);
        expect(of('bold').italic, isFalse);
        expect(of('an italic').italic, isTrue);
        expect(of('code').code, isTrue);
        expect(of('removed').strike, isTrue);
        expect(of('a link').link, isTrue);
      },
    );

    test('emphasis nests', () {
      final block = parseMarkdownBlocks('**bold and *italic* too**').single;
      expect(block.text, 'bold and italic too');
      // The outer bold is written in the stretches the nested italic didn't
      // claim, so what matters for the reader is that together they set the
      // whole span and nothing outside it.
      expect(
        block.formatRuns
            .where((r) => r.bold)
            .map((r) => block.text.substring(r.start, r.end))
            .join(),
        'bold and italic too',
      );
      expect(
        block.formatRuns
            .where((r) => !r.bold)
            .map((r) => block.text.substring(r.start, r.end))
            .toList(),
        isEmpty,
      );
      expect(
        block.formatRuns
            .where((r) => r.bold && r.italic)
            .map((r) => block.text.substring(r.start, r.end))
            .toList(),
        ['italic'],
      );
    });

    test('triple markers set bold and italic at once', () {
      final block = parseMarkdownBlocks('***Both*** here').single;
      expect(block.text, 'Both here');
      final run = block.formatRuns.single;
      expect((run.bold, run.italic), (true, true));
    });

    test('underscores inside a word are spelling, not emphasis', () {
      final block = parseMarkdownBlocks('use snake_case_names here').single;
      expect(block.text, 'use snake_case_names here');
      expect(block.formatRuns, isEmpty);
    });

    test('a backslash escape prints the character itself', () {
      expect(
        parseMarkdownBlocks(r'5 \* 3 \| 2 and \#1').single.text,
        '5 * 3 | 2 and #1',
      );
    });

    test('character references are read out', () {
      expect(
        parseMarkdownBlocks('AT&amp;B &laquo;ok&raquo; &#8470;').single.text,
        'AT&B «ok» №',
      );
    });

    test('an autolink shows its address', () {
      final block = parseMarkdownBlocks(
        'See <https://example.com/a> now',
      ).single;
      expect(block.text, 'See https://example.com/a now');
      expect(block.formatRuns.single.link, isTrue);
    });

    test('a picture degrades to the words written for it', () {
      final block = parseMarkdownBlocks(
        'As shown in ![the flow](a.png).',
      ).single;
      expect(block.text, 'As shown in the flow.');
      final run = block.formatRuns.single;
      expect((run.link, run.italic), (true, true));
    });

    test('raw HTML tags go, their text stays, and <br> breaks the line', () {
      expect(
        parseMarkdownBlocks('Text <b>rich</b> and <br> plain').single.text,
        'Text rich and\nplain',
      );
    });

    test('a comparison is prose, not a tag', () {
      // Only something shaped like a tag is dropped as one — text between a
      // "less than" and a "greater than" is still the sentence.
      expect(
        parseMarkdownBlocks('if a < b and c > d then').single.text,
        'if a < b and c > d then',
      );
      expect(parseMarkdownBlocks('x <- y -> z').single.text, 'x <- y -> z');
      expect(
        parseMarkdownBlocks(
          'keep <span class="x">this</span> text',
        ).single.text,
        'keep this text',
      );
    });

    test('a reference to no character is left as written', () {
      // Past U+10FFFF there is no character to turn it into, and asking for
      // one would throw — and take the whole file down with it.
      expect(
        parseMarkdownBlocks('bad &#99999999; and &#x110000; ok').single.text,
        'bad &#99999999; and &#x110000; ok',
      );
    });

    test('two trailing spaces are a line break, one newline is not', () {
      expect(
        parseMarkdownBlocks('line one  \nline two\nline three').single.text,
        'line one\nline two line three',
      );
    });
  });

  group('markdown tables', () {
    test('columns are padded and aligned, and the header is bold', () {
      final blocks = parseMarkdownBlocks('''
| Item | Qty |
|:-----|----:|
| Pen  | 12  |
| Eraser | 5 |
''');
      expect(_shape(blocks), ['code Item   | Qty\nPen    |  12\nEraser |   5']);
      final block = blocks.single;
      expect(block.isCode, isTrue);
      expect(block.formatRuns.single.bold, isTrue);
      expect(block.formatRuns.single.end, 'Item   | Qty'.length);
    });

    test('a table too wide to line up is printed with single spaces', () {
      final blocks = parseMarkdownBlocks('''
| column one | column two | column three |
|---|---|---|
| a very long value | another long value | third long value |
''');
      expect(
        blocks.single.text.split('\n').last,
        'a very long value | another long value | third long value',
      );
    });

    test('an escaped bar stays inside its cell', () {
      final text = parseMarkdownBlocks(
        '| a | b |\n|---|---|\n| x \\| y | z |',
      ).single.text;
      // Two columns, not three: the escaped bar is content. That makes the
      // first column as wide as `x | y`, so the header pads out to meet it.
      expect(text.split('\n'), ['a     | b', 'x | y | z']);
    });
  });

  group('layout shared with the paginator', () {
    ReflowBlock block({int quote = 0, int indent = 0, bool code = false}) =>
        ReflowBlock.paragraph(
          'text',
          quoteDepth: quote,
          indent: indent,
          isCode: code,
        );

    test('a plain paragraph is inset by nothing', () {
      expect(markdownBlockInsets(block()), (left: 0.0, right: 0.0));
    });

    test('quoting, nesting and a code panel each move the text in', () {
      expect(markdownBlockInsets(block(quote: 2)), (
        left: 2 * markdownQuoteIndent,
        right: 0.0,
      ));
      expect(markdownBlockInsets(block(indent: 3)), (
        left: 3 * markdownListIndent,
        right: 0.0,
      ));
      expect(markdownBlockInsets(block(code: true)), (
        left: markdownCodePadding,
        right: markdownCodePadding,
      ));
      expect(
        markdownBlockInsets(block(quote: 1, code: true)).left,
        markdownQuoteIndent + markdownCodePadding,
      );
    });

    test('each heading level is bigger and tighter than body text', () {
      final sizes = [
        for (var level = 1; level <= 6; level++)
          markdownStyle(
            ReflowBlock.paragraph('h', headingLevel: level),
          )!.sizeFactor,
      ];
      expect(sizes, orderedEquals([...sizes]..sort((a, b) => b.compareTo(a))));
      expect(sizes.first, greaterThan(1.4));
      expect(markdownStyle(block())!.sizeFactor, 1.0);
      expect(markdownStyle(block())!.bold, isFalse);
      expect(markdownStyle(block(code: true))!.monospace, isTrue);
    });
  });
}
