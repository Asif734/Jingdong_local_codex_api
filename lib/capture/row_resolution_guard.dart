/// Failed row discovery is separate from reply delivery. The same unread
/// observation gets a bounded number of UI attempts across every caller.
class RowResolutionGuard {
  RowResolutionGuard({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final _states = <String, _RowFailure>{};
  final _clearSince = <String, DateTime>{};
  static const stableClear = Duration(seconds: 4);
  static const delays = [
    Duration(seconds: 2),
    Duration(seconds: 8),
    Duration(seconds: 30)
  ];

  void observe(String row, bool unread) {
    if (!unread) {
      _clearSince.putIfAbsent(row, now);
      return;
    }
    final clearSince = _clearSince.remove(row);
    // Selection, capture and list repaint can briefly clear a badge. A single
    // false->true sample is not enough to grant another UI attempt budget.
    if (clearSince != null && now().difference(clearSince) >= stableClear) {
      _states.remove(row);
    }
  }

  bool due(String row) {
    final state = _states[row];
    return state == null ||
        (!state.suspended && !now().isBefore(state.retryAt));
  }

  DateTime? retryAt(String row) => _states[row]?.retryAt;
  bool suspended(String row) => _states[row]?.suspended ?? false;
  int failures(String row) => _states[row]?.failures ?? 0;

  void failed(String row) {
    final count = (_states[row]?.failures ?? 0) + 1;
    _states[row] = _RowFailure(
        count,
        now().add(delays[(count - 1).clamp(0, delays.length - 1)]),
        count > delays.length);
  }

  void resolved(String row) => _states.remove(row);
  void reset() {
    _states.clear();
    _clearSince.clear();
  }
}

class _RowFailure {
  _RowFailure(this.failures, this.retryAt, this.suspended);
  final int failures;
  final DateTime retryAt;
  final bool suspended;
}
