import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';

void main() {
  late int ms;
  late DateTime wall;
  late RedClockTracker clock;
  setUp(() {
    ms = 0;
    wall = DateTime.utc(2026, 11, 3);
    clock = RedClockTracker(
        responseTarget: const Duration(seconds: 20),
        monotonicMs: () => ms,
        wallNow: () => wall);
  });
  test('visible red pill starts a local timer with no AX value', () {
    final first = clock.observe('a', present: true)!;
    expect(first.startedAt, wall);
    ms = 19000;
    expect(clock.remaining('a'), const Duration(seconds: 1));
    ms = 20000;
    expect(clock.remaining('a'), Duration.zero);
  });
  test('new messages and absent AX values never reset a running timer', () {
    clock.observe('a', present: true);
    ms = 18000;
    clock.observe('a', present: true);
    expect(clock.remaining('a'), const Duration(seconds: 2));
  });
  test('21/51/71 jumps cannot prematurely backdate a known timer', () {
    clock.observe('a', present: true, ageSeconds: 1);
    for (final age in [21, 51, 71]) {
      ms += 1000;
      expect(clock.observe('a', present: true, ageSeconds: age)!.reason,
          'ax_jump_ignored');
    }
    expect(clock.remaining('a'), const Duration(seconds: 16));
  });
  test('accurate AX elapsed value backdates the first observation', () {
    clock.observe('a', present: true, ageSeconds: 18);
    expect(clock.remaining('a'), const Duration(seconds: 2));
    ms = 1000;
    clock.observe('a', present: true, ageSeconds: 19);
    expect(clock.remaining('a'), const Duration(seconds: 1));
  });
  test('wall clock changes cannot change an in-process deadline', () {
    clock.observe('a', present: true);
    ms = 5000;
    wall = wall.add(const Duration(hours: 1));
    clock.observe('a', present: true);
    expect(clock.remaining('a'), const Duration(seconds: 15));
  });
  test('AX identity rebinding preserves elapsed local time', () {
    clock.observe('row:1', present: true);
    ms = 18000;
    clock.rebind('row:1', 'a');
    expect(clock.remaining('a'), const Duration(seconds: 2));
    expect(clock.remaining('row:1'), isNull);
  });
  test('cleared then reappearing red pill starts a fresh local clock', () {
    clock.observe('a', present: true);
    ms = 19000;
    clock.observe('a', present: false);
    clock.observe('a', present: true);
    expect(clock.remaining('a'), const Duration(seconds: 20));
  });
  test('a new run cannot inherit unobserved local elapsed time', () {
    clock.observe('a', present: true);
    ms = 65000;
    clock.beginSession();
    final reading = clock.observe('a', present: true)!;
    expect(reading.elapsed, Duration.zero);
    expect(clock.remaining('a'), const Duration(seconds: 20));
  });
  test(
      'positive current-frame proof restores age without later bursts resetting it',
      () {
    clock.restartFromEvidence('a', wall.subtract(const Duration(seconds: 18)));
    expect(clock.remaining('a'), const Duration(seconds: 2));
    ms = 1000;
    clock.observe('a', present: true);
    expect(clock.remaining('a'), const Duration(seconds: 1));
  });
  test('counter reset after native confirmation is a new period', () {
    clock.observe('a', present: true, ageSeconds: 19);
    ms = 3000;
    final next = clock.observe('a',
        present: true, ageSeconds: 1, allowCounterReset: true)!;
    expect(next.counterReset, isTrue);
    expect(clock.remaining('a'), const Duration(seconds: 19));
  });
}
