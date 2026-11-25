/// Only an authorized response may interrupt transfer inspection: an answer
/// ready inside the red-clock window, or the actual SLA fallback. A later
/// formal answer keeps its queue entry until the current transfer finishes.
class OptionalUiWorkYield {
  static Future<void> notify({
    required bool mayInterruptTransfer,
    required bool transferActive,
    required bool imageAcquisitionActive,
    required Future<void> Function() yieldTransfer,
    required Future<void> Function() yieldImage,
  }) async {
    await Future.wait([
      if (mayInterruptTransfer && transferActive) Future.sync(yieldTransfer),
      if (imageAcquisitionActive) Future.sync(yieldImage),
    ]);
  }
}
