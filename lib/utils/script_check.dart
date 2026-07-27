import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Whether [text] looks like it isn't written in [source] at all.
///
/// Feeding an on-device model text in the wrong language doesn't fail — it
/// cheerfully returns nonsense (a Russian page "translated" from English
/// comes back as mangled Russian with random capitals), which reads as the
/// translator being broken. Writing system is a cheap, offline signal that
/// catches the common case: reading a Cyrillic book with the source
/// language left on English, or the reverse.
bool looksLikeWrongSourceLanguage(String text, TranslateLanguage source) {
  final expected = _scriptOf(source);
  if (expected == _Script.other) return false;
  final actual = _dominantScript(text);
  if (actual == _Script.other) return false;
  return actual != expected;
}

enum _Script { latin, cyrillic, other }

_Script _dominantScript(String text) {
  var latin = 0;
  var cyrillic = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      latin++;
    } else if (rune >= 0x0400 && rune <= 0x04FF) {
      cyrillic++;
    }
  }
  final total = latin + cyrillic;
  // Too little to judge (a number, a formula, one short word).
  if (total < 8) return _Script.other;
  if (cyrillic > latin * 3) return _Script.cyrillic;
  if (latin > cyrillic * 3) return _Script.latin;
  return _Script.other;
}

_Script _scriptOf(TranslateLanguage language) => switch (language) {
  TranslateLanguage.russian ||
  TranslateLanguage.ukrainian ||
  TranslateLanguage.bulgarian ||
  TranslateLanguage.belarusian ||
  TranslateLanguage.macedonian => _Script.cyrillic,
  TranslateLanguage.english ||
  TranslateLanguage.german ||
  TranslateLanguage.french ||
  TranslateLanguage.spanish ||
  TranslateLanguage.italian ||
  TranslateLanguage.portuguese ||
  TranslateLanguage.dutch ||
  TranslateLanguage.polish ||
  TranslateLanguage.czech ||
  TranslateLanguage.swedish ||
  TranslateLanguage.norwegian ||
  TranslateLanguage.danish ||
  TranslateLanguage.finnish ||
  TranslateLanguage.turkish ||
  TranslateLanguage.romanian ||
  TranslateLanguage.hungarian ||
  TranslateLanguage.croatian ||
  TranslateLanguage.slovak ||
  TranslateLanguage.slovenian ||
  TranslateLanguage.lithuanian ||
  TranslateLanguage.latvian ||
  TranslateLanguage.estonian ||
  TranslateLanguage.indonesian ||
  TranslateLanguage.malay ||
  TranslateLanguage.vietnamese ||
  TranslateLanguage.catalan ||
  TranslateLanguage.galician ||
  TranslateLanguage.afrikaans ||
  TranslateLanguage.albanian ||
  TranslateLanguage.esperanto ||
  TranslateLanguage.irish ||
  TranslateLanguage.icelandic ||
  TranslateLanguage.maltese ||
  TranslateLanguage.welsh ||
  TranslateLanguage.swahili ||
  TranslateLanguage.tagalog => _Script.latin,
  _ => _Script.other,
};
