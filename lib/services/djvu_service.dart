import 'package:flutter/services.dart';

class DjvuPageInfo {
  const DjvuPageInfo({
    required this.width,
    required this.height,
    required this.dpi,
  });

  final int width;
  final int height;
  final int dpi;

  double get aspectRatio => width <= 0 || height <= 0 ? 1 : width / height;
}

class DjvuWord {
  const DjvuWord({required this.text, required this.bounds});

  final String text;
  final Rect bounds;
}

/// Thin asynchronous client for Litra's native MIT DjVu codec.
///
/// The Android side performs parsing and rendering on worker threads. Keeping
/// that contract here is important: a damaged or unusually complex scan must
/// never block Flutter's UI isolate.
class DjvuDocument {
  DjvuDocument._(this._handle, this.pageCount);

  static const _channel = MethodChannel('litra/djvu');

  final int _handle;
  final int pageCount;
  bool _closed = false;

  static Future<DjvuDocument> open(String path) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('open', {
      'path': path,
    });
    final handle = raw?['handle'];
    final count = raw?['pageCount'];
    if (handle is! num || count is! num || count.toInt() <= 0) {
      throw const FormatException('Invalid DjVu document');
    }
    return DjvuDocument._(handle.toInt(), count.toInt());
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DjVu document is closed');
  }

  Future<DjvuPageInfo> pageInfo(int pageIndex) async {
    _ensureOpen();
    final raw = await _channel.invokeMapMethod<Object?, Object?>('pageInfo', {
      'handle': _handle,
      'page': pageIndex,
    });
    final width = raw?['width'];
    final height = raw?['height'];
    final dpi = raw?['dpi'];
    if (width is! num || height is! num || dpi is! num) {
      throw const FormatException('Invalid DjVu page information');
    }
    return DjvuPageInfo(
      width: width.toInt(),
      height: height.toInt(),
      dpi: dpi.toInt(),
    );
  }

  Future<Uint8List> renderPage(
    int pageIndex, {
    required int width,
    required int height,
  }) async {
    _ensureOpen();
    final bytes = await _channel.invokeMethod<Uint8List>('renderPage', {
      'handle': _handle,
      'page': pageIndex,
      'width': width,
      'height': height,
    });
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('DjVu page rendered without image data');
    }
    return bytes;
  }

  Future<String?> pageText(int pageIndex) async {
    _ensureOpen();
    return _channel.invokeMethod<String>('pageText', {
      'handle': _handle,
      'page': pageIndex,
    });
  }

  Future<List<DjvuWord>> pageWords(int pageIndex) async {
    _ensureOpen();
    final encoded =
        await _channel.invokeMethod<String>('pageWords', {
          'handle': _handle,
          'page': pageIndex,
        }) ??
        '';
    if (encoded.isEmpty) return const [];
    return [
      for (final record in encoded.split('\u001e'))
        if (record.split('\u001f') case final fields when fields.length >= 5)
          if (double.tryParse(fields[0]) case final x?)
            if (double.tryParse(fields[1]) case final y?)
              if (double.tryParse(fields[2]) case final width?)
                if (double.tryParse(fields[3]) case final height?)
                  DjvuWord(
                    text: fields.sublist(4).join('\u001f'),
                    bounds: Rect.fromLTWH(x, y, width, height),
                  ),
    ];
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('close', {'handle': _handle});
  }
}
