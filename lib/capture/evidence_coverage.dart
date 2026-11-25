/// A timestamp gap is a recovery hint, never proof that a frame is complete.
class EvidenceCoverage {
  static const overlap = Duration(seconds: 3);
  // JD clocks denote [second, second+1s), unlike microsecond observer clocks.
  static bool mediaOverlapsWindow(DateTime? senderAt, DateTime floor) =>
      senderAt == null ||
      senderAt.add(const Duration(seconds: 1)).isAfter(floor);

  static bool needsBackfill(
      {required DateTime firstObserved,
      required DateTime capturedAt,
      required Iterable<DateTime> visibleIncoming}) {
    if (capturedAt.isBefore(firstObserved)) return false;
    final current = visibleIncoming
        .where((at) => !at.isBefore(firstObserved.subtract(overlap)))
        .toList()
      ..sort();
    return current.isNotEmpty &&
        current.first.isAfter(firstObserved.add(overlap));
  }

  /// An on-screen image touching the transcript boundary may be only part of
  /// its bubble. Cache originals are handled separately and remain complete.
  static bool mediaTouchesViewport(
          {required double top,
          required double bottom,
          double? viewportTop,
          double? viewportBottom}) =>
      (viewportTop != null && top <= viewportTop + .008) ||
      (viewportBottom != null && bottom >= viewportBottom - .008);

  static const maxPages = 3;
  static int scrollPixels(int page, {int stepPixels = 400}) =>
      (page + 1) * stepPixels;
}
