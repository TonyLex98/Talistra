import 'dart:async';

/// Runs jobs one at a time, the most urgent first.
///
/// Built for work that can't be interrupted once started — a native page
/// rasterizer — and that piles up faster than it drains when the reader
/// turns pages quickly. What gets done then is decided when a job's turn
/// comes, not when it was asked for: the lowest priority value goes first,
/// and among equals the most recently asked for (the reader has moved on,
/// and wants where they are now); a job whose result is no longer wanted is
/// dropped without being run.
class PriorityJobQueue {
  /// [concurrency] jobs may run at once — more than one for work the other
  /// side can do on several threads (the DjVu decoder); the order in which
  /// jobs are picked is the same either way.
  PriorityJobQueue({this.concurrency = 1});

  final int concurrency;
  final List<_Job<Object?>> _waiting = [];
  int _active = 0;
  bool _pumpScheduled = false;

  /// How many jobs are waiting to start.
  int get waiting => _waiting.length;

  /// Queues [run]. The future completes with its result, or with null when
  /// [isStale] said (at its turn) that nobody wants it any more, or when the
  /// queue was [cancelAll]ed first.
  ///
  /// [livePriority], when given, is asked each time a job is picked, in place
  /// of the fixed [priority]: what a job is worth changes while it waits (the
  /// page that was a neighbour is now the one being read).
  Future<T?> add<T>(
    Future<T> Function() run, {
    int priority = 0,
    int Function()? livePriority,
    bool Function()? isStale,
  }) {
    final job = _Job<T>(priority, livePriority, isStale, run);
    _waiting.add(job as _Job<Object?>);
    if (!_pumpScheduled && _active < concurrency) {
      _pumpScheduled = true;
      // Not now: the caller is still holding the job's future, and may need
      // it to answer [isStale].
      scheduleMicrotask(_pump);
    }
    return job.completer.future;
  }

  /// Drops everything that has not started, each completing with null.
  void cancelAll() {
    final dropped = [..._waiting];
    _waiting.clear();
    for (final job in dropped) {
      job.drop();
    }
  }

  /// Completes once the jobs running now (if any) have finished.
  Future<void> get idle async {
    while (_active > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void _pump() {
    _pumpScheduled = false;
    while (_active < concurrency && _waiting.isNotEmpty) {
      final priorities = [for (final job in _waiting) job.currentPriority()];
      var best = _waiting.length - 1;
      for (var i = _waiting.length - 1; i >= 0; i--) {
        if (priorities[i] < priorities[best]) best = i;
      }
      final job = _waiting.removeAt(best);
      if (job.isStale?.call() ?? false) {
        job.drop();
        continue;
      }
      _active++;
      unawaited(
        job.start().whenComplete(() {
          _active--;
          _pump();
        }),
      );
    }
  }
}

class _Job<T> {
  _Job(this.priority, this.livePriority, this.isStale, this.run);

  final int priority;
  final int Function()? livePriority;
  int currentPriority() => livePriority?.call() ?? priority;
  final bool Function()? isStale;
  final Future<T> Function() run;
  final Completer<T?> completer = Completer<T?>();

  void drop() => completer.complete(null);

  Future<void> start() async {
    try {
      completer.complete(await run());
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  }
}
