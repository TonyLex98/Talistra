import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/reflow_builder.dart';
import 'package:transreade/utils/txt_paragraphs.dart';

/// A paragraph of repeated words [chars] long — one block, the shape a single
/// huge line of a real file makes.
String _prose(int chars) {
  final buffer = StringBuffer();
  while (buffer.length < chars) {
    buffer.write('alpha bravo charlie delta echo foxtrot golf hotel ');
  }
  return buffer.toString();
}

void main() {
  test('a block bigger than a page is cut into page-sized pieces', () {
    final text = _prose(20000);
    final blocks = buildTxtPagesFromBlocks([ReflowBlock.paragraph(text)]);
    final pieces = blocks.expand((page) => page).toList();

    expect(pieces.length, greaterThan(1));
    for (final piece in pieces) {
      expect(piece.text.length, lessThanOrEqualTo(2400));
    }
    // Nothing is lost or reordered by the cut.
    expect(pieces.map((piece) => piece.text).join(), text);
  });

  test('a cut lands on a word boundary, not inside a word', () {
    final text = _prose(9000);
    final pieces = buildTxtPagesFromBlocks([
      ReflowBlock.paragraph(text),
    ]).expand((page) => page).toList();

    for (var i = 1; i < pieces.length; i++) {
      final previous = pieces[i - 1].text;
      expect(
        previous.endsWith(' '),
        isTrue,
        reason: 'piece $i starts mid-word',
      );
      expect(pieces[i].text.startsWith(' '), isFalse);
    }
  });

  test('format runs follow their words into the right piece', () {
    final filler = _prose(5000);
    const marked = 'IMPORTANT SPAN';
    final start = filler.indexOf('charlie delta echo');
    final text =
        '${filler.substring(0, start)}$marked${filler.substring(start + marked.length)}';
    final run = FormatRun(start: start, end: start + marked.length, bold: true);
    final pieces = buildTxtPagesFromBlocks([
      ReflowBlock.paragraph(text, formatRuns: [run]),
    ]).expand((page) => page).toList();

    final held = [
      for (final piece in pieces)
        for (final r in piece.formatRuns) piece.text.substring(r.start, r.end),
    ];
    expect(held.join(), marked);
    for (final piece in pieces) {
      for (final r in piece.formatRuns) {
        expect(r.end, lessThanOrEqualTo(piece.text.length));
        expect(r.bold, isTrue);
      }
    }
  });

  test('preformatted text is cut between lines', () {
    final text = List.generate(
      400,
      (i) => 'line $i of a code panel that goes on for a while',
    ).join('\n');
    final pieces = buildTxtPagesFromBlocks([
      ReflowBlock.paragraph(text, isCode: true),
    ]).expand((page) => page).toList();

    for (final piece in pieces.take(pieces.length - 1)) {
      expect(piece.isCode, isTrue);
      expect(
        piece.text.endsWith('\n'),
        isTrue,
        reason: 'a code piece was cut mid-line',
      );
    }
    expect(pieces.map((piece) => piece.text).join(), text);
  });

  test('a continuation piece asks for no paragraph gap', () {
    final pieces = buildTxtPagesFromBlocks([
      ReflowBlock.paragraph(_prose(6000), gapAbove: 40),
    ]).expand((page) => page).toList();

    expect(pieces.first.gapAbove, 40);
    for (final piece in pieces.skip(1)) {
      expect(piece.gapAbove, 0);
    }
  });

  group('line breaks in a plain text file', () {
    List<String> paragraphsOf(String text) => [
      for (final page in buildTxtPages(text))
        for (final block in page) block.text,
    ];

    test('a book cut into 70-column lines is joined back into prose', () {
      const line =
          'The quick brown fox jumps over the lazy dog and keeps on running';
      final text = [
        '$line\n$line\n$line\nends here.',
        '$line\n$line\nlast words.',
      ].join('\n\n');
      final paragraphs = paragraphsOf(text);
      expect(paragraphs.length, 2);
      expect(paragraphs.first.contains('\n'), isFalse);
      expect(paragraphs.first.startsWith(line), isTrue);
      expect(paragraphs.first.endsWith('ends here.'), isTrue);
    });

    test('verse keeps its line breaks', () {
      const poem =
          'Roses are red\nViolets are blue\nSugar is sweet\nAnd so are you';
      final paragraphs = paragraphsOf('$poem\n\nSecond verse\nis here');
      expect(paragraphs, [poem, 'Second verse\nis here']);
    });

    test('a file with one paragraph per line is not poured into one block', () {
      final lines = [
        for (var i = 0; i < 6; i++)
          'Paragraph $i ${'with a fair amount of words in it ' * (2 + i)}',
      ];
      final paragraphs = paragraphsOf(lines.join('\n'));
      expect(paragraphs.length, 6);
      for (var i = 0; i < 6; i++) {
        expect(paragraphs[i], lines[i].trim());
      }
    });

    test('a list keeps one entry to a line', () {
      final paragraphs = paragraphsOf('Shopping:\n- milk\n- bread\n- eggs');
      expect(paragraphs, ['Shopping:\n- milk\n- bread\n- eggs']);
    });

    test('blank lines still separate paragraphs and Windows breaks work', () {
      final paragraphs = paragraphsOf('One\r\n\r\nTwo\r\n\r\n\r\nThree');
      expect(paragraphs, ['One', 'Two', 'Three']);
    });
  });
}
