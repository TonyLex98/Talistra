import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A small log of the errors the app ran into, kept on the phone, so a reader
/// who writes in about a crash can send what actually happened with it —
/// there is no crash reporting service, and there won't be one.
///
/// Only what went wrong and where in the code: never the text of a book.
class ErrorLog {
  ErrorLog._();

  /// How much of the log is kept: the newest part, which is the part that
  /// matters.
  static const int _maxBytes = 48 * 1024;

  static File? _file;

  /// Starts recording errors — framework errors and uncaught async ones —
  /// alongside whatever handling they already had.
  static Future<void> install() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, 'error_log.txt'));
    } catch (_) {
      return;
    }
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack, context: '${details.context}');
      previous?.call(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Uses [file] for the log instead of the app's own — for tests.
  @visibleForTesting
  static void useFile(File file) => _file = file;

  static void record(Object error, StackTrace? stack, {String? context}) {
    final file = _file;
    if (file == null) return;
    final frames = (stack?.toString() ?? '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(12)
        .join('\n');
    final entry = StringBuffer()
      ..writeln('[${DateTime.now().toIso8601String()}] ${error.runtimeType}')
      ..writeln(error.toString());
    if (context != null) entry.writeln(context);
    entry
      ..writeln(frames)
      ..writeln();
    try {
      file.writeAsStringSync(entry.toString(), mode: FileMode.append);
      if (file.lengthSync() > _maxBytes * 2) _trim(file);
    } catch (_) {
      // The log is a courtesy; failing to write it must not add a crash.
    }
  }

  static void _trim(File file) {
    final text = file.readAsStringSync();
    final keep = text.substring(text.length - _maxBytes);
    // Start at an entry, not halfway through one.
    final start = keep.indexOf('\n[');
    file.writeAsStringSync(start < 0 ? keep : keep.substring(start + 1));
  }

  /// The log's newest [maxChars] characters, whole entries only, with the
  /// device it was written on — or null when nothing went wrong.
  static Future<String?> read({int maxChars = 3000}) async {
    final file = _file;
    if (file == null || !await file.exists()) return null;
    var text = (await file.readAsString()).trim();
    if (text.isEmpty) return null;
    final header =
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n';
    final room = maxChars - header.length;
    if (room <= 0) return null;
    if (text.length > room) {
      text = text.substring(text.length - room);
      final start = text.indexOf('\n[');
      if (start >= 0) text = text.substring(start + 1);
    }
    return '$header$text';
  }

  static Future<void> clear() async {
    final file = _file;
    if (file != null && await file.exists()) await file.delete();
  }
}
