import 'dart:convert';
import 'dart:typed_data';

/// Decodes a plain-text file's bytes as UTF-8, falling back to
/// Windows-1251 — still a common encoding for older Russian .txt
/// e-books — when the bytes aren't valid UTF-8, instead of throwing and
/// failing to open the file at all.
String decodeTextFile(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeWindows1251(bytes);
  }
}

// Windows-1251 0x80..0xFF -> Unicode. 0x00..0x7F map straight to ASCII.
// Position 0x98 (index 24) has no assigned character in this code page.
const _cp1251HighBytes =
    'ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏ'
    'ђ‘’“”•–—�™љ›њќћџ'
    ' ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї'
    '°±Ііґµ¶·ё№є»јЅѕї'
    'АБВГДЕЖЗИЙКЛМНОП'
    'РСТУФХЦЧШЩЪЫЬЭЮЯ'
    'абвгдежзийклмноп'
    'рстуфхцчшщъыьэюя';

String _decodeWindows1251(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(
      byte < 0x80 ? String.fromCharCode(byte) : _cp1251HighBytes[byte - 0x80],
    );
  }
  return buffer.toString();
}
