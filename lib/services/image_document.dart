import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../utils/document_format.dart';

/// A picture — a photo of a page, a screenshot, a scan — opened as a book of
/// one page.
///
/// It is kept as a one-page PDF with the picture as its page, which is all
/// the PDF reader needs to give it everything a PDF gets: zoom, the compact
/// view (its text read off it by OCR, then tapped and translated),
/// bookmarks, notes and sharing.

/// The EXIF orientation a JPEG asks to be shown in (1 is as stored), or 1
/// when it says nothing.
int jpegOrientation(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return 1;
    final marker = bytes[offset + 1];
    // The picture itself starts here; nothing after it is metadata.
    if (marker == 0xDA || marker == 0xD9) return 1;
    final length = data.getUint16(offset + 2);
    if (marker == 0xE1 &&
        offset + 10 <= bytes.length &&
        String.fromCharCodes(bytes, offset + 4, offset + 8) == 'Exif') {
      return _exifOrientation(data, offset + 10, offset + 2 + length) ?? 1;
    }
    offset += 2 + length;
  }
  return 1;
}

int? _exifOrientation(ByteData data, int tiff, int end) {
  if (tiff + 8 > end || end > data.lengthInBytes) return null;
  final Endian endian;
  switch (data.getUint16(tiff)) {
    case 0x4949:
      endian = Endian.little;
    case 0x4D4D:
      endian = Endian.big;
    default:
      return null;
  }
  final directory = tiff + data.getUint32(tiff + 4, endian);
  if (directory + 2 > end) return null;
  final entries = data.getUint16(directory, endian);
  for (var i = 0; i < entries; i++) {
    final entry = directory + 2 + i * 12;
    if (entry + 12 > end) return null;
    if (data.getUint16(entry, endian) == 0x0112) {
      final value = data.getUint16(entry + 8, endian);
      return value >= 1 && value <= 8 ? value : null;
    }
  }
  return null;
}

/// The longest side a picture is kept at. A phone photo is well under it;
/// past it, the page would be slower to show without being any sharper on a
/// phone's screen.
const int _maxSide = 6000;

/// [bytes] (a picture in one of [supportedImageFormats]) as a one-page PDF
/// whose page is the picture, the right way up.
Future<Uint8List> imageToPdf(Uint8List bytes) => imagesToPdf([bytes]);

/// [pictures] as a PDF of one page each, in order — a ZIP of scans or of a
/// comic's pages read as the one book it is.
Future<Uint8List> imagesToPdf(List<Uint8List> pictures) async {
  final document = PdfDocument();
  try {
    for (final bytes in pictures) {
      final page = await _pageOf(bytes);
      final size = ui.Size(page.width * 0.75, page.height * 0.75);
      // Each page its picture's own size, in a section of its own. A wide
      // page has to be said to be landscape: given a wide size alone, the
      // writer turns it into a tall one.
      final section = document.sections!.add();
      section.pageSettings
        ..orientation = size.width > size.height
            ? PdfPageOrientation.landscape
            : PdfPageOrientation.portrait
        ..size = size
        ..margins.all = 0;
      section.pages.add().graphics.drawImage(
        page.bitmap,
        ui.Rect.fromLTWH(0, 0, size.width, size.height),
      );
    }
    return Uint8List.fromList(await document.save());
  } finally {
    document.dispose();
  }
}

/// One picture ready to be a page: its image as the PDF writer takes it, and
/// its size in pixels.
Future<({PdfBitmap bitmap, int width, int height})> _pageOf(
  Uint8List bytes,
) async {
  final format = detectImageFormat(bytes);
  if (format == null) {
    throw const FormatException('Not a picture this reader can open');
  }
  // Its size from its header: a photo is not decoded just to be measured.
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final ui.ImageDescriptor descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } catch (_) {
    throw const FormatException('The picture could not be read');
  } finally {
    buffer.dispose();
  }
  final width = descriptor.width;
  final height = descriptor.height;
  final longest = math.max(width, height);

  try {
    // A JPEG that is stored the right way up goes in as it is: the PDF holds
    // JPEG data natively, so it is neither re-encoded (and blurred) nor made
    // any bigger.
    if (format == 'jpg' && longest <= _maxSide && jpegOrientation(bytes) == 1) {
      final bitmap = _bitmapOf(bytes);
      if (bitmap != null) return (bitmap: bitmap, width: width, height: height);
    }
    // Anything else — and a photo the camera stored on its side, which the
    // decoder turns the right way up — goes in as the decoder draws it.
    final scale = math.min(1.0, _maxSide / math.max(1, longest));
    final codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? (width * scale).round() : null,
    );
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bitmap = data == null
          ? null
          : _bitmapOf(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
      if (bitmap == null) {
        throw const FormatException('The picture could not be read');
      }
      return (bitmap: bitmap, width: image.width, height: image.height);
    } finally {
      image.dispose();
    }
  } finally {
    descriptor.dispose();
  }
}

PdfBitmap? _bitmapOf(Uint8List picture) {
  try {
    return PdfBitmap(picture);
  } catch (_) {
    return null;
  }
}

/// Orders file names the way a person counts them: `page2` before `page10`.
int compareNaturally(String a, String b) {
  final digits = RegExp(r'\d+|\D+');
  final left = digits.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = digits.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}
