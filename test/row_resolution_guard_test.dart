import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/row_resolution_guard.dart';

void main() {
  test(
      'all callers share a bounded row attempt budget without polling resetting it',
      () {
    var now = DateTime.utc(2026, 11, 1);
    final guard = RowResolutionGuard(now: () => now);
    guard.observe('row', true);
    for (final seconds in [2, 8, 30]) {
      expect(guard.due('row'), isTrue);
      guard.failed('row');
      guard.observe('row', true);
      expect(guard.due('row'), isFalse);
      now = now.add(Duration(seconds: seconds));
    }
    expect(guard.due('row'), isTrue);
    guard.failed('row');
    now = now.add(const Duration(hours: 1));
    guard.observe('row', true);
    expect(guard.suspended('row'), isTrue);
    expect(guard.due('row'), isFalse);
    expect(guard.due('another-row'), isTrue);
  });
  test('a new actual unread turn or explicit restart reopens the circuit', () {
    var now = DateTime.utc(2026, 11, 1);
    final guard = RowResolutionGuard(now: () => now);
    for (var i = 0; i < 4; i++) {
      guard.failed('row');
    }
    guard.observe('row', false);
    now = now.add(RowResolutionGuard.stableClear);
    guard.observe('row', true);
    expect(guard.due('row'), isTrue);
    guard.failed('row');
    guard.reset();
    expect(guard.due('row'), isTrue);
  });
  test('brief badge clear cannot reset failure budget', () {
    var now = DateTime.utc(2026, 11, 1);
    final guard = RowResolutionGuard(now: () => now);
    guard.failed('row');
    guard.failed('row');
    guard.observe('row', false);
    now = now.add(const Duration(seconds: 2));
    guard.observe('row', true);
    expect(guard.failures('row'), 2);
    guard.failed('row');
    expect(guard.failures('row'), 3);
  });
  test('successful identity resolution clears row failures', () {
    final guard = RowResolutionGuard();
    guard.failed('row');
    guard.resolved('row');
    expect(guard.due('row'), isTrue);
    expect(guard.failures('row'), 0);
  });
}
