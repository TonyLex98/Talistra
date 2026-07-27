import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// How far a pixel has to be from paper white (per channel, 0..255) before
/// it counts as ink. Loose enough to ignore JPEG-ish noise and the faint
/// grey of a scanned background, tight enough to catch a light grey rule
/// or a pale chart fill.
const _inkThreshold = 26;

/// How many ink samples a region needs before it's considered to hold real
/// content. A handful of stray dark pixels is dust on a scan, or the tip
/// of a descender bleeding in from the line above — not a figure.
const _minInkSamples = 24;

/// The tight bounding box of everything drawn inside [pngBytes], expressed
/// as fractions (0..1) of the image's own size, or null if the image is
/// blank paper.
///
/// This is what lets the reflowed view treat "a big vertical gap between
/// two text lines" as a *candidate* for a figure rather than a certainty:
/// the gap may just as easily be a section break, generous leading, or the
/// page's bottom margin, and rendering those produced empty white slabs
/// sitting in the middle of the text. Measuring the actual pixels answers
/// both questions at once — whether there's anything there, and exactly
/// where it is, so the figure can be cropped to itself instead of to the
/// full width of the page.
Future<ui.Rect?> findInkBounds(Uint8List pngBytes) async {
  final ui.Image image;
  final codec = await ui.instantiateImageCodec(pngBytes);
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }

  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final pixels = data.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;

    // Sampling every pixel of a full page is needless work — a stride that
    // caps each axis at ~400 samples keeps this in the low milliseconds
    // while still being far finer than any real figure's smallest feature.
    final step = math.max(1, math.max(width, height) ~/ 400);

    var minX = width, minY = height, maxX = -1, maxY = -1, samples = 0;
    for (var y = 0; y < height; y += step) {
      final rowStart = y * width * 4;
      for (var x = 0; x < width; x += step) {
        final i = rowStart + x * 4;
        // Fully transparent pixels are paper too (a region rendered
        // without an opaque background), not content.
        if (pixels[i + 3] < 8) continue;
        final darkest = math.min(
          pixels[i],
          math.min(pixels[i + 1], pixels[i + 2]),
        );
        if (255 - darkest <= _inkThreshold) continue;
        samples++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (samples < _minInkSamples || maxX < 0) return null;

    // Grow by one stride so the box can't cut off content that fell
    // between two samples.
    return ui.Rect.fromLTRB(
      math.max(0, minX - step) / width,
      math.max(0, minY - step) / height,
      math.min(width, maxX + step + 1) / width,
      math.min(height, maxY + step + 1) / height,
    );
  } finally {
    image.dispose();
  }
}
