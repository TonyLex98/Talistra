import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:transreade/utils/priority_queue.dart';

/// Lets a queue start the job it has been given (it does so a microtask
/// later, so that the caller has its hands on the job's future by then).
Future<void> _started() => Future<void>.delayed(Duration.zero);

void main() {
  test('the most urgent job goes first, the latest among equals', () async {
    final queue = PriorityJobQueue();
    final order = <String>[];
    final gate = Completer<void>();
    // Occupies the queue while the rest pile up behind it.
    final first = queue.add(() async {
      await gate.future;
      order.add('first');
    });
    await _started();
    final jobs = [
      queue.add(() async => order.add('near-a'), priority: 10),
      queue.add(() async => order.add('background'), priority: 100),
      queue.add(() async => order.add('near-b'), priority: 10),
      queue.add(() async => order.add('visible'), priority: 0),
    ];
    gate.complete();
    await first;
    await Future.wait(jobs);
    expect(order, ['first', 'visible', 'near-b', 'near-a', 'background']);
  });

  test('a job nobody wants any more is never run', () async {
    final queue = PriorityJobQueue();
    final gate = Completer<void>();
    final ran = <String>[];
    final first = queue.add(() => gate.future);
    await _started();
    var wanted = true;
    final stale = queue.add(() async {
      ran.add('stale');
      return 1;
    }, isStale: () => !wanted);
    final kept = queue.add(() async {
      ran.add('kept');
      return 2;
    });
    wanted = false;
    gate.complete();
    await first;
    expect(await stale, isNull);
    expect(await kept, 2);
    expect(ran, ['kept']);
  });

  test('one failing job does not stop the others', () async {
    final queue = PriorityJobQueue();
    final failing = queue.add<int>(() async => throw StateError('nope'));
    final fine = queue.add(() async => 3);
    await expectLater(failing, throwsStateError);
    expect(await fine, 3);
  });

  test(
    'cancelling drops what has not started, and idle waits for the rest',
    () async {
      final queue = PriorityJobQueue();
      final gate = Completer<void>();
      final running = queue.add(() async {
        await gate.future;
        return 'done';
      });
      await _started();
      final dropped = queue.add(() async => 'never');
      queue.cancelAll();
      expect(await dropped, isNull);
      var idle = false;
      unawaited(queue.idle.then((_) => idle = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(idle, isFalse);
      gate.complete();
      expect(await running, 'done');
      await queue.idle;
      expect(queue.waiting, 0);
    },
  );

  test('what a waiting job is worth is asked when its turn comes', () async {
    final queue = PriorityJobQueue();
    final gate = Completer<void>();
    final order = <String>[];
    final first = queue.add(() => gate.future);
    await _started();
    // The reader is on page 1 when both are queued, and on page 9 by the
    // time the queue gets to them.
    var page = 1;
    int worth(int of) => (of - page).abs();
    final two = queue.add(
      () async => order.add('page 2'),
      livePriority: () => worth(2),
    );
    final nine = queue.add(
      () async => order.add('page 9'),
      livePriority: () => worth(9),
    );
    page = 9;
    gate.complete();
    await first;
    await Future.wait([two, nine]);
    expect(order, ['page 9', 'page 2']);
  });
}
