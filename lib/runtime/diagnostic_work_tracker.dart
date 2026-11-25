import 'dart:async';

/// Observes existing local work without changing scheduling or concurrency.
/// Only stopped-run exports wait for this barrier; API network polling is not
/// registered here. Children keep the barrier live until their own completion.
class DiagnosticWorkTracker {
  int _active = 0;
  int _generation = 0;
  Completer<void>? _idle;

  void Function() acquire() {
    if (_active++ == 0) _idle = Completer<void>();
    final generation = _generation;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (generation != _generation) return;
      if (--_active == 0) _idle!.complete();
    };
  }

  /// Stop retires cancelled run leases; this is cancellation, not proof that
  /// an uncooperative OS call physically finished. Report the returned count.
  int cancelPending() {
    final cancelled = _active;
    _generation++;
    _active = 0;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
    return cancelled;
  }

  Future<T> track<T>(Future<T> work) {
    final release = acquire();
    return work.whenComplete(release);
  }

  Future<void> get whenIdle async {
    while (_active > 0) {
      await _idle!.future;
    }
  }
}
