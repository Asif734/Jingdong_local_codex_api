import 'unread_capture_recovery.dart';

/// A processed message is not a processed customer. New badge edges are
/// independent evidence, even when the badge's timer cannot be read by OCR.
class UnreadSignalTracker {
  UnreadSignalTracker({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  static const probeInterval = Duration(seconds: 4);
  final _signals = <String, _Signal>{};
  final _probedAt = <String, DateTime>{};

  UnreadSignalDecision observe(String customer,
      {required bool unread, int? badgeAgeSeconds, DateTime? handledAt}) {
    final at = now();
    final previous = _signals[customer];
    final rising = unread && previous?.unread == false;
    final freshClock = unread &&
        UnreadCaptureRecovery.badgeStartedAfterHandled(
            at, badgeAgeSeconds, handledAt);
    var first = previous?.firstUnreadAt;
    if (!unread) {
      first = null;
    } else if (first == null || rising || freshClock) {
      first = UnreadCaptureRecovery.detectedFromBadge(at, badgeAgeSeconds);
    }
    _signals[customer] = _Signal(unread, first);
    return UnreadSignalDecision(
      clearHandled: !unread || rising || freshClock,
      reason: !unread
          ? 'badge_clear'
          : rising
              ? 'unread_rising_edge'
              : freshClock
                  ? 'new_badge_clock'
                  : handledAt == null
                      ? 'unread_observed'
                      : 'handled_requires_probe',
      detectedAt: first,
      previousUnread: previous?.unread,
    );
  }

  DateTime detectedAt(String customer, int? badgeAgeSeconds) {
    final at = now();
    final first = _signals[customer]?.firstUnreadAt;
    final badge = UnreadCaptureRecovery.detectedFromBadge(at, badgeAgeSeconds);
    return first != null && first.isBefore(badge) ? first : badge;
  }

  /// Persistent unread is never suppressed indefinitely by an old handled
  /// mark. A bounded read-only content probe does not itself send a reply.
  bool needsProbe(String customer, DateTime? handledAt) {
    if (_signals[customer]?.unread != true || handledAt == null) return false;
    final probe = _probedAt[customer];
    final last = probe != null && probe.isAfter(handledAt) ? probe : handledAt;
    return now().difference(last) >= probeInterval;
  }

  void markProbe(String customer) {
    _probedAt[customer] = now();
  }
}

class UnreadSignalDecision {
  const UnreadSignalDecision(
      {required this.clearHandled,
      required this.reason,
      required this.detectedAt,
      required this.previousUnread});
  final bool clearHandled;
  final String reason;
  final DateTime? detectedAt;
  final bool? previousUnread;
}

class _Signal {
  _Signal(this.unread, this.firstUnreadAt);
  final bool unread;
  final DateTime? firstUnreadAt;
}
