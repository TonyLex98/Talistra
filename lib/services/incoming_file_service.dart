import 'package:flutter/services.dart';

/// Documents handed to the app from outside it — a file manager's "Open
/// with", or the system share sheet.
///
/// The Android side (see `MainActivity.kt`) copies the incoming document
/// into the app's cache and sends over a plain file path; this listens for
/// that, and also asks once at startup for anything that arrived before
/// Dart was running (which is the usual case for a cold start, since the
/// intent is what launched the app in the first place).
class IncomingFileService {
  IncomingFileService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'openFile') return null;
      final path = call.arguments as String?;
      if (path != null && path.isNotEmpty) _deliver(path);
      return null;
    });
  }

  static final IncomingFileService instance = IncomingFileService._();

  static const _channel = MethodChannel('transread/incoming_file');

  void Function(String path)? _listener;
  String? _pending;

  /// Registers the (single) handler that imports and opens the document,
  /// and hands over anything that was already waiting.
  ///
  /// Returns whether a document was actually delivered — the caller uses
  /// that to decide *not* to reopen the last-read book, which would
  /// otherwise land on top of the document the reader just asked to open.
  Future<bool> listen(void Function(String path) onFile) async {
    _listener = onFile;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      onFile(pending);
      return true;
    }
    try {
      final path = await _channel.invokeMethod<String>('consumePending');
      if (path != null && path.isNotEmpty) {
        onFile(path);
        return true;
      }
    } on MissingPluginException {
      // Not Android (or the channel isn't wired up): nothing to receive.
    }
    return false;
  }

  void _deliver(String path) {
    final listener = _listener;
    if (listener == null) {
      // The library screen isn't up yet; it will collect this on [listen].
      _pending = path;
      return;
    }
    listener(path);
  }
}
