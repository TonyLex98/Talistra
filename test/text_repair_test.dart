import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/utils/text_repair.dart';

/// Russian as an old 8-bit PDF font hands it out: each letter the Latin-1
/// character with its Windows-1251 byte.
String _mojibake(String russian) => String.fromCharCodes(
  russian.runes.map((c) {
    if (c >= 0x410 && c <= 0x44F) return 0xC0 + (c - 0x410);
    if (c == 0x401) return 0xA8;
    if (c == 0x451) return 0xB8;
    return c;
  }),
);

void main() {
  const russian = 'Съешь же ещё этих мягких французских булок, да выпей чаю.';

  test('Russian read as Latin-1 is recognised and turned back', () {
    final garbled = _mojibake(russian);
    expect(garbled, startsWith('Ñúåøü'));
    expect(looksLikeCp1251AsLatin1(garbled), isTrue);
    expect(cp1251FromLatin1(garbled), russian);
  });

  test('real accented Latin is left alone', () {
    for (final text in [
      "L'été dernier, nous sommes allés à la mer près de Nice.",
      'Über die Brücke gehen die Mädchen früh am Morgen.',
      'El niño comió jamón en la montaña, ¿verdad?',
    ]) {
      expect(looksLikeCp1251AsLatin1(text), isFalse, reason: text);
      expect(looksLikeGarbage(text), isFalse, reason: text);
    }
    expect(looksLikeCp1251AsLatin1(russian), isFalse);
  });

  test('glyph codes with no letters behind them are refused', () {
    final privateUse = String.fromCharCodes(
      List.generate(60, (i) => 0xE000 + i),
    );
    expect(looksLikeGarbage(privateUse), isTrue);
    expect(
      looksLikeGarbage(r'!"#$%&()*+,-./:;<=>?@[\]^_`{|}~!"#$%&()*+'),
      isTrue,
    );
  });

  test('a table of numbers is still text', () {
    expect(
      looksLikeGarbage('2019 2020 2021 2022\n12,5 13,1 14,0 15,8\nИтого 55,4'),
      isFalse,
    );
  });
}
