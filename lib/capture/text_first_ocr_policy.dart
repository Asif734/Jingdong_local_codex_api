/// Avoid speculative double OCR while a customer's recent screenshots
/// consistently need a full pass. The cooldown changes which OCR to start;
/// it does not delay capture, admission, generation, or delivery.
class TextFirstOcrPolicy {
  static const _cooldown = Duration(seconds: 15);
  final _misses = <String, int>{};
  final _bypassUntil = <String, DateTime>{};
  final _lastEvidence = <String, String>{};

  bool shouldTry(String customer, DateTime now) {
    final until = _bypassUntil[customer];
    if (until == null) return true;
    if (now.isBefore(until)) return false;
    _bypassUntil.remove(customer);
    _misses.remove(customer);
    return true;
  }

  void record(String customer, String evidenceId, DateTime now,
      {required bool useful}) {
    if (_lastEvidence[customer] == evidenceId) return;
    _lastEvidence[customer] = evidenceId;
    if (useful) {
      _misses.remove(customer);
      _bypassUntil.remove(customer);
    } else if ((_misses.update(customer, (n) => n + 1, ifAbsent: () => 1)) >=
        2) {
      _bypassUntil.putIfAbsent(customer, () => now.add(_cooldown));
    }
  }

  void clear() {
    _misses.clear();
    _bypassUntil.clear();
    _lastEvidence.clear();
  }
}
