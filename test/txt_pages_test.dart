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
}
