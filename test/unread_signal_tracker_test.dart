import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/unread_signal_tracker.dart';

void main() {
  test('new unread edge clears processed state even with unreadable clock', () {
    var now = DateTime.utc(2026, 11, 1, 10, 43, 25);
    final tracker = UnreadSignalTracker(now: () => now);
    tracker.observe('buyer', unread: false);
    final replied = now.add(const Duration(seconds: 9));
    now = now.add(const Duration(seconds: 17));
    final result = tracker.observe('buyer', unread: true, handledAt: replied);
    expect(result.clearHandled, isTrue);
    expect(result.reason, 'unread_rising_edge');
    final original = result.detectedAt;
    now = now.add(const Duration(seconds: 30));
    tracker.observe('buyer', unread: true);
    expect(tracker.detectedAt('buyer', null), original);
  });
  test(
      'continuous unread gets bounded content probe despite old processed mark',
      () {
    var now = DateTime.utc(2026, 11, 1);
    final tracker = UnreadSignalTracker(now: () => now);
    tracker.observe('buyer', unread: true);
    final replied = now;
    now = now.add(const Duration(seconds: 4));
    expect(tracker.needsProbe('buyer', replied), isTrue);
    tracker.markProbe('buyer');
    expect(tracker.needsProbe('buyer', replied), isFalse);
    now = now.add(const Duration(seconds: 4));
    expect(tracker.needsProbe('buyer', replied), isTrue);
    expect(tracker.needsProbe('other', replied), isFalse);
  });
  test('verified new badge clock can split a continuous red episode', () {
    var now = DateTime.utc(2026, 11, 1);
    final tracker = UnreadSignalTracker(now: () => now);
    tracker.observe('buyer', unread: true);
    final handled = now.add(const Duration(seconds: 10));
    now = now.add(const Duration(seconds: 20));
    final result = tracker.observe('buyer',
        unread: true, badgeAgeSeconds: 5, handledAt: handled);
    expect(result.clearHandled, isTrue);
    expect(result.reason, 'new_badge_clock');
    expect(result.detectedAt, now.subtract(const Duration(seconds: 5)));
  });
}
