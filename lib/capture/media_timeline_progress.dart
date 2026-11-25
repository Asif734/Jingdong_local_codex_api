import 'dart:async';
import 'viewport_evidence.dart';

/// Advances one admitted media message without making its preview a completed
/// answer. The sender-time owner is checked by [isCurrent]; native image pixels
/// can establish type even when the original cache lookup did not match.
class MediaTimelineProgress {
  static Future<bool> savedFrameIsUsable(ViewportEvidence? evidence,
          {required String customer, required String sessionId}) async =>
      evidence != null &&
      evidence.customer == customer &&
      evidence.metadata['automationSessionId'] == sessionId &&
      await evidence.filesExist();

  static ({String kind, bool knownImage}) inventoryType(
      String recordedKind, Iterable<Map> media) {
    final video = recordedKind == 'video' ||
        media.any((item) =>
            item['type'] == 'video' ||
            item['type_verification'] == 'video_confirmed' ||
            (item['capture_source']?.toString().contains('video') ?? false) ||
            (item['role']?.toString().contains('video') ?? false));
    // A pending hint requests native classification; it is not a verdict
    // that removes an image/unknown timeline task from acquisition.
    final kind = video ? 'video' : recordedKind;
    return (kind: kind, knownImage: kind == 'image');
  }

  static bool isVerifiedImageOriginal({
    required String nativeKind,
    required String? captureSource,
    required bool hasImageBytes,
    required bool playbackOverlayDetected,
    required bool hasVideoPayload,
    bool verifiedOriginal = false,
  }) =>
      nativeKind == 'image' &&
      hasImageBytes &&
      !playbackOverlayDetected &&
      !hasVideoPayload &&
      (const {'jd-image-cache', 'jd_image_cache'}.contains(captureSource) ||
          verifiedOriginal &&
              const {
                'jd-image-viewer-download',
                'jd-image-viewer-copy',
                'jd-message-context-copy',
                'jd-message-context-copy-cache',
              }.contains(captureSource));

  static Future<T?> advanceValidatedImage<T>({
    required String timelineKind,
    required String inventoryKind,
    required bool hasValidatedRectangle,
    required String nativeKind,
    required bool hasImageBytes,
    required bool playbackOverlayDetected,
    required bool hasVideoPayload,
    required FutureOr<bool> Function() isCurrent,
    required Future<bool> Function() confirmImageType,
    required Future<T?> Function() acquireOriginal,
  }) async {
    if (timelineKind != 'media' ||
        (inventoryKind != 'unknown' && inventoryKind != 'image') ||
        !hasValidatedRectangle ||
        nativeKind != 'image' ||
        !hasImageBytes ||
        playbackOverlayDetected ||
        hasVideoPayload ||
        !await isCurrent()) {
      return null;
    }
    // Classification is durable type progress only. Content still has to
    // pass the original acquisition and analysis completion checks.
    if (inventoryKind == 'unknown' && !await confirmImageType()) return null;
    if (!await isCurrent()) return null;
    return acquireOriginal();
  }

  /// A positive native video verdict hands this same timeline record back to
  /// the established frozen-frame video pipeline. A type-pending hint alone
  /// is deliberately insufficient.
  static Future<bool> delegateValidatedVideo({
    required String timelineKind,
    required String nativeKind,
    required bool hasVideoPayload,
    required bool playbackOverlayDetected,
    required FutureOr<bool> Function() isCurrent,
    required Future<bool> Function() confirmVideoType,
    required Future<void> Function() handOff,
  }) async {
    if (timelineKind != 'media' ||
        nativeKind != 'video' ||
        (!hasVideoPayload && !playbackOverlayDetected) ||
        !await isCurrent()) {
      return false;
    }
    if (!await confirmVideoType() || !await isCurrent()) return false;
    await handOff();
    return true;
  }
}
