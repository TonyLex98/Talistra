import 'dart:convert';
import 'dart:typed_data';

/// Decodes a plain-text file's bytes as UTF-8, falling back to
/// Windows-1251 — still a common encoding for older Russian .txt
/// e-books — when the bytes aren't valid UTF-8, instead of throwing and
/// failing to open the file at all.
///
/// UTF-16 — what Windows tools write XML and "Unicode" text in — is read by
/// its byte-order mark, or recognised by the zero byte beside every Latin
/// letter when it has none.
String decodeTextFile(Uint8List bytes) {
  final utf16 = utf16EndianOf(bytes);
  if (utf16 != null) return _decodeUtf16(bytes, utf16);
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  final body = start == 0 ? bytes : Uint8List.sublistView(bytes, start);
  try {
    return utf8.decode(body);
  } on FormatException {
    return _decodeWindows1251(body);
  }
}

/// The byte order [bytes] are UTF-16 in, or null when they aren't UTF-16.
Endian? utf16EndianOf(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return Endian.little;
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return Endian.big;
  }
  // No mark: text in a Latin-script language has a zero in every other byte,
  // and always the same one of the pair.
  final sample = bytes.length < 2048 ? bytes.length & ~1 : 2048;
  if (sample < 8) return null;
  var evenZeros = 0;
  var oddZeros = 0;
  for (var i = 0; i < sample; i += 2) {
    if (bytes[i] == 0) evenZeros++;
    if (bytes[i + 1] == 0) oddZeros++;
  }
  final pairs = sample ~/ 2;
  if (oddZeros > pairs * 0.4 && evenZeros < pairs * 0.05) return Endian.little;
  if (evenZeros > pairs * 0.4 && oddZeros < pairs * 0.05) return Endian.big;
  return null;
}

String _decodeUtf16(Uint8List bytes, Endian endian) {
  var start = 0;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    start = 2;
  }
  final data = ByteData.sublistView(bytes);
  final units = <int>[];
  for (var i = start; i + 1 < bytes.length; i += 2) {
    units.add(data.getUint16(i, endian));
  }
  return String.fromCharCodes(units);
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
