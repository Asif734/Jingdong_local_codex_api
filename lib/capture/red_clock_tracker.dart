import 'dart:math';
import 'response_timing_policy.dart';

/// A red pill starts a timer even when AX is unavailable. Wall-clock changes
/// and later messages do not change its elapsed time.
class RedClockTracker {
  RedClockTracker(
      {this.monotonicMs,
      DateTime Function()? wallNow,
      this.responseTarget = ResponseTimingPolicy.responseTarget})
      : wallNow = wallNow ?? DateTime.now;
  Duration responseTarget;
  final int Function()? monotonicMs;
  final DateTime Function() wallNow;
  final _watch = Stopwatch()..start();
  final _clocks = <String, _Clock>{};
  int get _now => monotonicMs?.call() ?? _watch.elapsedMilliseconds;

  /// A paused interval has no observations. Persisted DB work is retained,
  /// while local elapsed time must be proved again by current AX/evidence.
  void beginSession() => _clocks.clear();

  void restartFromEvidence(String customer, DateTime startedAt) {
    final wall = wallNow();
    final clock = _Clock(_now, wall);
    clock.offsetMs = max(0, wall.difference(startedAt).inMilliseconds);
    _clocks[customer] = clock;
  }

  RedClockReading? observe(String customer,
      {required bool present,
      int? ageSeconds,
      bool allowCounterReset = false}) {
    if (!present) {
      _clocks.remove(customer);
      return null;
    }
    final now = _now;
    var clock = _clocks[customer];
    var reset = false;
    if (clock != null &&
        allowCounterReset &&
        ageSeconds != null &&
        clock.lastAge != null &&
        ageSeconds + 2 < clock.lastAge! &&
        ageSeconds * 1000 + 2000 < clock.elapsed(now)) {
      _clocks.remove(customer);
      clock = null;
      reset = true;
    }
    final first = clock == null;
    clock ??= _clocks.putIfAbsent(customer, () => _Clock(now, wallNow()));
    var reason = 'local_monotonic';
    var calibrated = false;
    if (ageSeconds != null && ageSeconds >= 0 && ageSeconds <= 600) {
      final age = ageSeconds * 1000;
      final elapsed = clock.elapsed(now);
      final previous = clock.lastAge;
      final previousAt = clock.lastAgeAt;
      final consistent = previous != null &&
          previousAt != null &&
          (age - previous * 1000 - (now - previousAt)).abs() <= 2000;
      if (first || (consistent && age >= elapsed - 2000)) {
        clock.offsetMs = max(clock.offsetMs, age - (now - clock.monoStart));
        clock.lastAge = ageSeconds;
        clock.lastAgeAt = now;
        reason = 'verified_ax_calibration';
        calibrated = true;
      } else if (previous == null) {
        // A first late reading requires a second consistent observation before
        // it is allowed to backdate an already running local clock.
        clock.lastAge = ageSeconds;
        clock.lastAgeAt = now;
        reason = 'await_consistent_ax';
      } else {
        reason = 'ax_jump_ignored';
      }
    }
    return RedClockReading(
        clock.wallStart.subtract(Duration(milliseconds: clock.offsetMs)),
        Duration(milliseconds: clock.elapsed(now)),
        reason,
        calibrated,
        reset);
  }

  Duration? remaining(String customer) {
    final clock = _clocks[customer];
    return clock == null
        ? null
        : Duration(
            milliseconds:
                max(0, responseTarget.inMilliseconds - clock.elapsed(_now)));
  }

  void rebind(String observed, String actual) {
    if (observed == actual) return;
    final old = _clocks.remove(observed);
    if (old == null) return;
    final other = _clocks[actual];
    if (other == null || old.elapsed(_now) > other.elapsed(_now)) {
      _clocks[actual] = old;
    }
  }
}

class _Clock {
  _Clock(this.monoStart, this.wallStart);
  final int monoStart;
  final DateTime wallStart;
  int offsetMs = 0;
  int? lastAge, lastAgeAt;
  int elapsed(int now) => max(0, now - monoStart + offsetMs);
}

class RedClockReading {
  const RedClockReading(this.startedAt, this.elapsed, this.reason,
      this.calibrated, this.counterReset);
  final DateTime startedAt;
  final Duration elapsed;
  final String reason;
  final bool calibrated, counterReset;
}
