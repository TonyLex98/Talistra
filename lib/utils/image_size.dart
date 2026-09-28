import 'dart:typed_data';
import 'dart:ui';

/// The pixel size of an encoded image, read from its header alone — PNG, JPEG,
/// GIF, WebP or BMP — or null for anything else, or a header too broken to
/// say.
///
/// A book's pictures have to be given their room on a page while the book is
/// being laid out, long before (and on a different isolate from where) any of
/// them is decoded; the header is all that takes.
Size? imageSizeOf(Uint8List bytes) {
  try {
    return _png(bytes) ??
        _gif(bytes) ??
        _jpeg(bytes) ??
        _webp(bytes) ??
        _bmp(bytes);
  } on RangeError {
    return null;
  }
}

Size? _sized(num width, num height) =>
    width > 0 && height > 0 ? Size(width.toDouble(), height.toDouble()) : null;

Size? _png(Uint8List b) {
  if (b.length < 24 ||
      b[0] != 0x89 ||
      b[1] != 0x50 ||
      b[2] != 0x4E ||
      b[3] != 0x47) {
    return null;
  }
  final data = ByteData.sublistView(b);
  return _sized(data.getUint32(16), data.getUint32(20));
}

Size? _gif(Uint8List b) {
  if (b.length < 10 || b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) {
    return null;
  }
  final data = ByteData.sublistView(b);
  return _sized(
    data.getUint16(6, Endian.little),
    data.getUint16(8, Endian.little),
  );
}

Size? _jpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  final data = ByteData.sublistView(b);
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // Fill bytes and markers that carry no length.
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final length = data.getUint16(i + 2);
    // Every start-of-frame marker except the three that aren't (DHT, JPG,
    // DAC) carries the frame's height and then its width.
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      return _sized(data.getUint16(i + 7), data.getUint16(i + 5));
    }
    i += 2 + length;
  }
  return null;
}

Size? _webp(Uint8List b) {
  if (b.length < 30 ||
      String.fromCharCodes(b.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(b.sublist(8, 12)) != 'WEBP') {
    return null;
  }
  final data = ByteData.sublistView(b);
  final chunk = String.fromCharCodes(b.sublist(12, 16));
  switch (chunk) {
    case 'VP8 ':
      return _sized(
        data.getUint16(26, Endian.little) & 0x3FFF,
        data.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      final bits = data.getUint32(21, Endian.little);
      return _sized((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      int int24(int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);
      return _sized(int24(24) + 1, int24(27) + 1);
  }
  return null;
}

Size? _bmp(Uint8List b) {
  if (b.length < 26 || b[0] != 0x42 || b[1] != 0x4D) return null;
  final data = ByteData.sublistView(b);
  return _sized(
    data.getInt32(18, Endian.little),
    data.getInt32(22, Endian.little).abs(),
  );
}
