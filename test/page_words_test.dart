import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/page_words.dart';

/// One word of a fake page: [x] is where it sits on the line, [line] which
/// line of the page it is on, and [page] which page the list it belongs to
/// was built for ([buildPageWords] only ever sees one page and leaves it 0).
PageWord _word(String text, double x, int line, {int page = 0}) {
  return PageWord(
    text: text,
    bounds: Rect.fromLTWH(x, line * 12.0, 20, 10),
    lineIndex: line,
    pageIndex: page,
  );
}

void main() {
  // "under-" and "signed" are one word torn in half — by the line break on
  // page 0, and by the page break between pages 0 and 1.
  final pages = <int, List<PageWord>>{
    0: [_word('the', 0, 0), _word('quick', 30, 0), _word('under-', 0, 1)],
    1: [_word('signed', 0, 0, page: 1), _word('down', 80, 0, page: 1)],
    2: [_word('and', 0, 0, page: 2), _word('slept', 30, 0, page: 2)],
  };
  List<PageWord> wordsForPage(int page) => pages[page] ?? const [];

  group('flattenWordRange', () {
    test('numbers lines continuously across the pages a mark runs over', () {
      final flat = flattenWordRange(
        start: (pageIndex: 0, wordIndex: 1),
        end: (pageIndex: 1, wordIndex: 1),
        wordsForPage: wordsForPage,
      );

      expect(flat.map((w) => w.text), ['quick', 'under-', 'signed', 'down']);
      // Page 0 has two lines, so page 1's first line becomes line 2 — one
      // list the caller can build a mark from, with no second code path for
      // the multi-page case.
      expect(flat.map((w) => w.lineIndex), [0, 1, 2, 2]);
      expect(flat.map((w) => w.pageIndex), [0, 0, 1, 1]);
    });

    test('skips a page with nothing extractable on it', () {
      final realMiddlePage = pages[1]!;
      pages[1] = const [];
      addTearDown(() => pages[1] = realMiddlePage);

      final flat = flattenWordRange(
        start: (pageIndex: 0, wordIndex: 2),
        end: (pageIndex: 2, wordIndex: 0),
        wordsForPage: wordsForPage,
      );
      expect(flat.map((w) => w.text), ['under-', 'and']);
      expect(flat.map((w) => w.lineIndex), [1, 2]);
      expect(flat.map((w) => w.pageIndex), [0, 2]);
    });

    test('is empty when the mark ends before it starts', () {
      expect(
        flattenWordRange(
          start: (pageIndex: 1, wordIndex: 0),
          end: (pageIndex: 0, wordIndex: 2),
          wordsForPage: wordsForPage,
        ),
        isEmpty,
      );
    });
  });

  group('buildWordRangeSelection', () {
    test('says which page each marked line is on', () {
      final flat = flattenWordRange(
        start: (pageIndex: 0, wordIndex: 0),
        end: (pageIndex: 1, wordIndex: 0),
        wordsForPage: wordsForPage,
      );
      final selection = buildWordRangeSelection(flat, 0, flat.length - 1);

      expect(selection.text, 'the quick undersigned');
      // The highlight is drawn page by page, in each page's own PDF points,
      // so a marked line has to remember where it came from.
      expect(selection.rects.map((r) => (r.pageIndex, r.bounds.top)).toList(), [
        (0, 0.0),
        (0, 12.0),
        (1, 0.0),
      ]);
    });

    test('mends a word torn by the page break, not by a line break alone', () {
      final flat = flattenWordRange(
        start: (pageIndex: 0, wordIndex: 2),
        end: (pageIndex: 1, wordIndex: 0),
        wordsForPage: wordsForPage,
      );
      expect(
        buildWordRangeSelection(flat, 0, flat.length - 1).text,
        'undersigned',
      );
    });

    test('keeps a space where the page really has one', () {
      final flat = flattenWordRange(
        start: (pageIndex: 2, wordIndex: 0),
        end: (pageIndex: 2, wordIndex: 1),
        wordsForPage: wordsForPage,
      );
      final selection = buildWordRangeSelection(flat, 0, flat.length - 1);
      expect(selection.text, 'and slept');
      expect(selection.rects.single.pageIndex, 2);
    });
  });

  test('compareWordPositions goes through a book page first', () {
    expect(
      compareWordPositions(
        (pageIndex: 0, wordIndex: 99),
        (pageIndex: 1, wordIndex: 0),
      ),
      lessThan(0),
    );
    expect(
      compareWordPositions(
        (pageIndex: 3, wordIndex: 7),
        (pageIndex: 3, wordIndex: 2),
      ),
      greaterThan(0),
    );
    expect(
      compareWordPositions(
        (pageIndex: 3, wordIndex: 3),
        (pageIndex: 3, wordIndex: 3),
      ),
      isZero,
    );
  });

  group('wordIndexAt', () {
    test('lands on the nearest word on the line, not on nothing', () {
      // Past the end of a line still has to answer, or a drag visibly
      // freezes every time the finger leaves a glyph.
      expect(wordIndexAt(wordsForPage(0), const Offset(900, 6)), 1);
    });

    test('falls back to the nearest word of the nearest line', () {
      // Well below the last line of the page there is no line to be on.
      expect(wordIndexAt(wordsForPage(0), const Offset(35, 40)), 2);
    });
  });
}
