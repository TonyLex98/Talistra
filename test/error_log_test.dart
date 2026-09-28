import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:transreade/services/error_log.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('talistra_error_log');
    ErrorLog.useFile(File('${dir.path}/error_log.txt'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('nothing went wrong, nothing to send', () async {
    expect(await ErrorLog.read(), isNull);
  });

  test('an error is kept with its type, message and frames', () async {
    try {
      throw StateError('broken page');
    } catch (error, stack) {
      ErrorLog.record(error, stack, context: 'while turning a page');
    }
    final log = (await ErrorLog.read())!;
    expect(log, contains('StateError'));
    expect(log, contains('broken page'));
    expect(log, contains('while turning a page'));
    expect(log, contains('error_log_test.dart'));
  });

  test('only the newest whole entries fit the room given', () async {
    for (var i = 0; i < 200; i++) {
      ErrorLog.record(Exception('error number $i'), null);
    }
    final log = (await ErrorLog.read(maxChars: 600))!;
    expect(log.length, lessThanOrEqualTo(600));
    expect(log, contains('error number 199'));
    expect(log, isNot(contains('error number 0\n')));
    // Starts at an entry, not halfway through one.
    expect(log.split('\n')[1], startsWith('['));
  });
}
