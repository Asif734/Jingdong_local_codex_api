import 'dart:async';

/// A validated rectangle always takes the cache-first path. That callback
/// may dispatch a separately proved image copy after a cache miss; a missing
/// rectangle can only enter the independently anchored context-menu path.
enum ImageAcquisitionPath { vision, contextCopy, wait }

class ImageAcquisitionRoute {
  static ImageAcquisitionPath select({
    required String kind,
    required bool hasValidatedRectangle,
    required bool hasContextTarget,
  }) {
    if (kind != 'image' && kind != 'unknown') {
      return ImageAcquisitionPath.wait;
    }
    if (hasValidatedRectangle) return ImageAcquisitionPath.vision;
    return hasContextTarget
        ? ImageAcquisitionPath.contextCopy
        : ImageAcquisitionPath.wait;
  }

  /// [copyUnderUiLease] must return only after its owned menu, pasteboard and
  /// UI lease have been released. Reading/matching the copied bytes then runs
  /// outside that UI transaction. The caller commits the returned result;
  /// neither a stale clipboard read nor a late comparison can commit here.
  ///
  /// An unknown media card may use a rectangle to classify its content, or a
  /// context-menu copy to prove it is an image. Its vision callback must not
  /// open a viewer until the image type has independently been established.
  static Future<R?> run<T, R>({
    required String kind,
    required bool hasValidatedRectangle,
    required bool hasContextTarget,
    required FutureOr<bool> Function() isCurrent,
    required Future<R?> Function() viaVision,
    required Future<T?> Function() copyUnderUiLease,
    required Future<R?> Function(T copied) compareInBackground,
  }) async {
    final path = select(
        kind: kind,
        hasValidatedRectangle: hasValidatedRectangle,
        hasContextTarget: hasContextTarget);
    if (path == ImageAcquisitionPath.wait || !await isCurrent()) return null;
    if (path == ImageAcquisitionPath.vision) {
      final result = await viaVision();
      return await isCurrent() ? result : null;
    }
    final copied = await copyUnderUiLease();
    if (copied == null || !await isCurrent()) return null;
    final result = await compareInBackground(copied);
    return await isCurrent() ? result : null;
  }
}
