import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/runtime/diagnostic_work_tracker.dart';
void main() {
  test('export drain includes children launched while parent settles', () async {
    final tracker = DiagnosticWorkTracker();
    final parent = tracker.acquire();
    var idle = false;
    final waiting = tracker.whenIdle.then((_) => idle = true);
    final child = tracker.acquire();
    parent();
    await Future<void>.delayed(Duration.zero);
    expect(idle, false);
    child();
    await waiting;
    expect(idle, true);
  });
  test('failed background task releases drain and propagates error', () async {
    final tracker = DiagnosticWorkTracker();
    final completer = Completer<void>();
    final work = tracker.track(completer.future);
    final expected = expectLater(work, throwsStateError);
    completer.completeError(StateError('failed crop'));
    await expected;
    await tracker.whenIdle;
  });
}
