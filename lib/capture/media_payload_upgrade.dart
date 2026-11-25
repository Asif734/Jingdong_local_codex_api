import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Content of one already-owned image representation. Identity and bytes are
/// separate: reusing a customer message ID does not prove a duplicate payload.
/// [sha256] must describe the actual file bytes, never a perceptual fingerprint.
class MediaPayloadVersion {
  const MediaPayloadVersion({
    required this.sha256,
    required this.isPartial,
    this.isLoadingPreview = false,
    this.verifiedOriginal = false,
    this.available = true,
    this.containsVideoMaterial = false,
    this.captureSource,
    this.captureQuality = const {},
  });

  final String? sha256;
  final bool isPartial;
  final bool isLoadingPreview;

  /// Existing native cache/download/clipboard proof, not visual clarity alone.
  final bool verifiedOriginal;
  final bool available;
  final bool containsVideoMaterial;
  final String? captureSource;
  final Map<String, Object?> captureQuality;

  bool get usable =>
      available &&
      captureQuality['decoded'] != false &&
      sha256 != null &&
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256!);

  bool get completeOriginal =>
      usable &&
      verifiedOriginal &&
      !isPartial &&
      !isLoadingPreview &&
      !containsVideoMaterial;

  int get _quality => completeOriginal ? 2 : (isLoadingPreview ? 0 : 1);

  bool? get _clipped {
    final value = captureQuality['touchesViewportEdge'];
    return value is bool ? value : null;
  }

  double? _metric(String key) {
    final value = captureQuality[key];
    return value is num && value.isFinite && value >= 0
        ? value.toDouble()
        : null;
  }

  bool get _informative =>
      (_metric('foregroundFraction') ?? 0) >= .06 &&
      (_metric('textureFraction') ?? 0) >= .025 &&
      (_metric('occupiedCellFraction') ?? 0) >= .5;
  bool get _emptyLike =>
      (_metric('foregroundFraction') ?? 1) <= .025 ||
      (_metric('occupiedCellFraction') ?? 1) <= .125 &&
          (_metric('textureFraction') ?? 1) <= .035;

  bool _wouldDowngrade(MediaPayloadVersion old) {
    if (isLoadingPreview && !old.isLoadingPreview ||
        _clipped == true && old._clipped == false ||
        old._informative && !_informative) {
      return true;
    }
    final w = _metric('width'), h = _metric('height');
    final oldW = old._metric('width'), oldH = old._metric('height');
    return old._informative &&
        w != null &&
        h != null &&
        oldW != null &&
        oldH != null &&
        (w < oldW * .85 || h < oldH * .85);
  }

  bool _improves(MediaPayloadVersion old) {
    if (completeOriginal) return true;
    if (_wouldDowngrade(old)) return false;
    if (_informative && (old.isLoadingPreview || old._emptyLike)) return true;
    if (_clipped == false && old._clipped == true && _informative) return true;
    if (_clipped == false &&
        _informative &&
        captureSource == 'verified_window_crop' &&
        old.captureSource == 'verified_chat_viewport_fallback') {
      return true;
    }
    final foreground = _metric('foregroundFraction');
    final oldForeground = old._metric('foregroundFraction');
    final occupied = _metric('occupiedCellFraction');
    final oldOccupied = old._metric('occupiedCellFraction');
    if (_informative &&
        foreground != null &&
        oldForeground != null &&
        occupied != null &&
        oldOccupied != null &&
        foreground >= oldForeground + .12 &&
        occupied >= oldOccupied + .25) {
      return true;
    }
    final w = _metric('width'), h = _metric('height');
    final oldW = old._metric('width'), oldH = old._metric('height');
    return _clipped == false &&
        old._clipped == false &&
        _informative &&
        captureSource == old.captureSource &&
        w != null &&
        h != null &&
        oldW != null &&
        oldH != null &&
        w >= oldW &&
        h >= oldH &&
        w * h >= oldW * oldH * 1.5;
  }
}

enum MediaPayloadUpgradeKind {
  initial,
  exactDuplicate,
  upgradePendingRepresentation,
  preserveAuthoritative,
  alreadyAnswered,
}

class MediaPayloadUpgradeDecision {
  const MediaPayloadUpgradeDecision(this.kind, this.reason,
      {this.completeOriginal = false});

  final MediaPayloadUpgradeKind kind;
  final String reason;
  final bool completeOriginal;

  bool get shouldStore =>
      kind == MediaPayloadUpgradeKind.initial ||
      kind == MediaPayloadUpgradeKind.upgradePendingRepresentation;
  bool get replaceExisting =>
      kind == MediaPayloadUpgradeKind.upgradePendingRepresentation;
  bool get wakePending => shouldStore;
}

/// A bounded decision inside an exact customer/message/receipt ownership scope.
/// This never chooses an ID, admits a message or confirms an answer. A clearer
/// partial image may replace a bad partial, but still needs its complete
/// original before the existing analysis-ready gate can release the reply.
class MediaPayloadUpgrade {
  static MediaPayloadUpgradeDecision decide({
    required bool sameMessageVerified,
    required bool formallyAnswered,
    required MediaPayloadVersion candidate,
    Iterable<MediaPayloadVersion> previous = const [],
  }) {
    if (!sameMessageVerified) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'message_ownership_unverified');
    }
    if (formallyAnswered) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.alreadyAnswered, 'formal_reply_already_sent');
    }
    if (!candidate.usable) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'candidate_bytes_unavailable');
    }
    final existing = previous.toList();
    if (existing.any((item) => item.containsVideoMaterial) ||
        candidate.containsVideoMaterial) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'video_material_uses_existing_video_flow');
    }
    final usable = existing.where((item) => item.usable).toList();
    final sameBytes = usable.where((item) =>
        item.sha256!.toLowerCase() == candidate.sha256!.toLowerCase());
    if (sameBytes.any((item) => item._quality >= candidate._quality)) {
      return MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.exactDuplicate, 'same_bytes_and_proof',
          completeOriginal: candidate.completeOriginal);
    }
    if (usable.any((item) => item.completeOriginal)) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'verified_original_is_already_retained',
          completeOriginal: true);
    }
    if (usable.any((item) => item._quality > candidate._quality)) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'candidate_would_downgrade_content');
    }
    if (existing.isEmpty) {
      return MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.initial, 'first_owned_representation',
          completeOriginal: candidate.completeOriginal);
    }
    if (!candidate.completeOriginal &&
        usable.isNotEmpty &&
        (usable.any(candidate._wouldDowngrade) ||
            !usable.any(candidate._improves))) {
      return const MediaPayloadUpgradeDecision(
          MediaPayloadUpgradeKind.preserveAuthoritative,
          'no_verified_capture_quality_gain');
    }
    return MediaPayloadUpgradeDecision(
        MediaPayloadUpgradeKind.upgradePendingRepresentation,
        usable.isEmpty
            ? 'replace_unavailable_payload'
            : sameBytes.isNotEmpty
                ? 'stronger_completion_proof'
                : 'pending_payload_bytes_changed',
        completeOriginal: candidate.completeOriginal);
  }
}

/// Decode only a bounded sample for pending-representation comparison. These
/// statistics neither identify a customer message nor prove a complete image.
Future<Map<String, Object?>> computeImageCaptureQuality(Uint8List bytes,
    {bool? touchesViewportEdge,
    double? foregroundFraction,
    int? width,
    int? height}) async {
  final quality = <String, Object?>{
    'version': 1,
    if (touchesViewportEdge != null) 'touchesViewportEdge': touchesViewportEdge,
    if (foregroundFraction != null && foregroundFraction.isFinite)
      'nativeForegroundFraction': foregroundFraction,
    if (width != null && width > 0) 'width': width,
    if (height != null && height > 0) 'height': height,
  };
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? sample;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    quality['width'] = descriptor.width;
    quality['height'] = descriptor.height;
    codec = await descriptor.instantiateCodec(
        targetWidth: math.min(64, descriptor.width),
        targetHeight: math.min(64, descriptor.height));
    sample = (await codec.getNextFrame()).image;
    final data = await sample.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('image_pixels_unavailable');
    final pixels =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final colors = <int, int>{};
    final rgb = <(int, int, int)>[];
    for (var at = 0; at < pixels.length; at += 4) {
      final alpha = pixels[at + 3] / 255;
      int channel(int offset) =>
          (pixels[at + offset] * alpha + 255 * (1 - alpha)).round();
      final r = channel(0), g = channel(1), b = channel(2);
      rgb.add((r, g, b));
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      colors[key] = (colors[key] ?? 0) + 1;
    }
    final background =
        colors.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final red = ((background >> 8) & 15) * 16 + 8;
    final green = ((background >> 4) & 15) * 16 + 8;
    final blue = (background & 15) * 16 + 8;
    final cellForeground = List<int>.filled(16, 0);
    final cellPixels = List<int>.filled(16, 0);
    var foreground = 0, texture = 0, pairs = 0;
    var left = sample.width, top = sample.height, right = 0, bottom = 0;
    double distance((int, int, int) a, (int, int, int) b) =>
        ((a.$1 - b.$1).abs() + (a.$2 - b.$2).abs() + (a.$3 - b.$3).abs()) / 3;
    for (var y = 0; y < sample.height; y++) {
      for (var x = 0; x < sample.width; x++) {
        final at = y * sample.width + x;
        final pixel = rgb[at];
        final cell = (y * 4 ~/ sample.height) * 4 + x * 4 ~/ sample.width;
        cellPixels[cell]++;
        if (distance(pixel, (red, green, blue)) > 24) {
          foreground++;
          cellForeground[cell]++;
          left = math.min(left, x);
          top = math.min(top, y);
          right = math.max(right, x + 1);
          bottom = math.max(bottom, y + 1);
        }
        if (x > 0) {
          pairs++;
          if (distance(pixel, rgb[at - 1]) > 18) texture++;
        }
        if (y > 0) {
          pairs++;
          if (distance(pixel, rgb[at - sample.width]) > 18) texture++;
        }
      }
    }
    final nonemptyCells = cellPixels.where((count) => count > 0).length;
    quality.addAll({
      'decoded': true,
      'samplePixels': rgb.length,
      'foregroundFraction': foreground / rgb.length,
      'textureFraction': pairs == 0 ? 0.0 : texture / pairs,
      if (foreground > 0) ...{
        'contentLeft': left / sample.width,
        'contentTop': top / sample.height,
        'contentRight': right / sample.width,
        'contentBottom': bottom / sample.height,
      },
      'occupiedCellFraction': nonemptyCells == 0
          ? 0.0
          : [
                for (var i = 0; i < 16; i++)
                  if (cellPixels[i] > 0 &&
                      cellForeground[i] / cellPixels[i] >= .08)
                    i
              ].length /
              nonemptyCells,
    });
  } catch (_) {
    quality['decoded'] = false;
  } finally {
    sample?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
  return quality;
}
