import 'dart:math' as math;

import '../domain/customer_message_time.dart';
import '../platform/macos_capture_adapter.dart';
import 'ocr_capture_extractor.dart';
import 'ocr_chat_layout.dart';
import 'ocr_image_candidate_selector.dart';

/// A context-menu hit anchored to an already admitted incoming attachment.
/// The vertical bounds describe ownership, never a crop or image comparison.
class ImageContextCopyTarget {
  const ImageContextCopyTarget({
    required this.x,
    required this.y,
    required this.header,
    required this.bodyTop,
    required this.bodyBottom,
    required this.chatLeft,
    required this.chatRight,
    required this.chatTop,
    required this.chatBottom,
    this.confirmedRegion,
  });

  final double x, y;
  final OcrObservation header;
  final double bodyTop, bodyBottom;
  final double chatLeft, chatRight, chatTop, chatBottom;
  final OcrVisualRegion? confirmedRegion;

  Map<String, Object?> toMap() => {
        'pointX': x,
        'pointY': y,
        'header': {
          'text': header.text,
          'confidence': header.confidence,
          'x': header.x,
          'y': header.y,
          'width': header.width,
          'height': header.height,
        },
        if (confirmedRegion case final region?)
          'confirmedRegion': {
            'x': region.x,
            'y': region.y,
            'width': region.width,
            'height': region.height,
          },
        'bodyTop': bodyTop,
        'bodyBottom': bodyBottom,
        'chat': {
          'left': chatLeft,
          'right': chatRight,
          'top': chatTop,
          'bottom': chatBottom,
        },
      };
}

/// Locate an already admitted image by its customer's complete sender second.
/// Only detector rectangles can supply pixels for cache comparison. A missing
/// rectangle can instead authorize a narrowly anchored context-menu probe;
/// only a fresh image copied by that menu can establish its actual contents.
class ImageOriginalLocator {
  static bool _validChat(OcrInspection inspection, String customer) {
    if (inspection.activeCustomerId != customer || customer.isEmpty) {
      return false;
    }
    final edges = [
      inspection.chatLeft,
      inspection.chatRight,
      inspection.chatTop,
      inspection.chatBottom
    ];
    return edges.every((edge) => edge != null && edge.isFinite) &&
        inspection.chatLeft! >= 0 &&
        inspection.chatRight! <= 1 &&
        inspection.chatTop! >= 0 &&
        inspection.chatBottom! <= 1 &&
        inspection.chatLeft! < inspection.chatRight! &&
        inspection.chatTop! < inspection.chatBottom!;
  }

  static List<OcrVisualRegion> locate(
      OcrInspection inspection, String customer, DateTime senderAt) {
    if (!_validChat(inspection, customer)) return [];
    final left = inspection.chatLeft!, right = inspection.chatRight!;
    final top = inspection.chatTop!, bottom = inspection.chatBottom!;
    OcrVisualRegion? bound(OcrVisualRegion region) {
      if ([region.x, region.y, region.width, region.height]
              .any((value) => !value.isFinite) ||
          region.width <= 0 ||
          region.height <= 0) {
        return null;
      }
      final x = region.x.clamp(left, right).toDouble();
      final y = region.y.clamp(top, bottom).toDouble();
      final endX = (region.x + region.width).clamp(left, right).toDouble();
      final endY = (region.y + region.height).clamp(top, bottom).toDouble();
      if (endX <= x || endY <= y) return null;
      return OcrVisualRegion(
          x: x,
          y: y,
          width: endX - x,
          height: endY - y,
          confidence: region.confidence);
    }

    const extractor = OcrCaptureExtractor();
    final rectangles = const OcrImageCandidateSelector()
        .select(inspection, customer,
            includeTextDense: true, allowUnlabeledLatestImage: true)
        .where((region) {
          if (!region.confidence.isFinite ||
              region.confidence <= 0 ||
              (inspection.physicalMediaRegions != null &&
                  !inspection.physicalMediaRegions!.contains(region))) {
            return false;
          }
          final clockEvidence =
              extractor.mediaClockForRegion(inspection, region);
          if (inspection.physicalMediaRegions != null &&
              clockEvidence.source != 'ocr_media_sender_header') return false;
          final clock = clockEvidence.sentAt;
          return clock != null &&
              CustomerMessageTime.sameSecond(clock, senderAt);
        })
        .map(bound)
        .whereType<OcrVisualRegion>()
        .toList();
    rectangles
        .sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    return rectangles;
  }

  /// The exact sender block anchors the hit. A native-confirmed image
  /// rectangle can supply its own bounded hit after the cache misses.
  static ImageContextCopyTarget? contextCopyTarget(
      OcrInspection inspection, String customer, DateTime senderAt,
      {OcrVisualRegion? confirmedRegion}) {
    if (!_validChat(inspection, customer) ||
        inspection.imageWidth <= 0 ||
        inspection.imageHeight <= 0) {
      return null;
    }
    final candidates = locate(inspection, customer, senderAt);
    if (confirmedRegion == null
        ? candidates.isNotEmpty
        : !candidates.any((r) =>
            r.x == confirmedRegion.x &&
            r.y == confirmedRegion.y &&
            r.width == confirmedRegion.width &&
            r.height == confirmedRegion.height)) {
      return null;
    }
    final blocks = const OcrCaptureExtractor()
        .incomingMessageBlocks(inspection)
        .where(
            (block) => CustomerMessageTime.sameSecond(block.sentAt, senderAt))
        .toList();
    if (blocks.length != 1) return null;
    final block = blocks.single;
    final header = block.header;
    final bodyTop = header.y + header.height + .004;
    final bodyBottom = block.region.y + block.region.height;
    final right = inspection.chatRight!;
    final left = inspection.chatLeft!;
    final boundedRegion = confirmedRegion == null
        ? null
        : OcrVisualRegion(
            x: math.max(header.x, confirmedRegion.x),
            y: math.max(bodyTop, confirmedRegion.y),
            width: math.min(right, confirmedRegion.x + confirmedRegion.width) -
                math.max(header.x, confirmedRegion.x),
            height: math.min(
                    bodyBottom, confirmedRegion.y + confirmedRegion.height) -
                math.max(bodyTop, confirmedRegion.y),
            confidence: confirmedRegion.confidence);
    if (boundedRegion != null &&
        (boundedRegion.width * inspection.imageWidth < 16 ||
            boundedRegion.height * inspection.imageHeight < 16)) {
      return null;
    }
    final x = (boundedRegion?.x ?? header.x) + 8 / inspection.imageWidth;
    final y = (boundedRegion?.y ?? bodyTop) + 8 / inspection.imageHeight;
    final marginX = 3 / inspection.imageWidth;
    final marginY = 3 / inspection.imageHeight;
    if (![
          header.x,
          header.y,
          header.width,
          header.height,
          bodyTop,
          bodyBottom,
          x,
          y
        ].every((value) => value.isFinite) ||
        header.width <= 0 ||
        header.height <= 0 ||
        header.x < inspection.chatLeft! ||
        header.x + header.width > inspection.chatRight! ||
        header.y < inspection.chatTop! ||
        header.y + header.height >= inspection.chatBottom! ||
        x - marginX < left ||
        x + marginX >= inspection.chatRight! ||
        y - marginY < bodyTop ||
        y + marginY >= bodyBottom) {
      return null;
    }
    final layout = OcrChatLayout(inspection);
    final hit = OcrVisualRegion(
        // allowedMedia checks a card's left edge, not its inset click point.
        x: header.x,
        y: y - marginY,
        width: x + marginX - header.x,
        height: marginY * 2,
        confidence: 1);
    if (!layout.allowedMedia(hit)) return null;
    // An admitted placeholder can later prove to be ordinary text. Do not
    // open a context menu on an already readable first text line. Tiny OCR
    // printed inside screenshots is not a normal chat-font body line.
    if (confirmedRegion == null &&
        inspection.observations.any((line) =>
            !line.isWatermark &&
            !layout.isInterface(line) &&
            line.confidence >= .45 &&
            line.rotationDegrees.abs() <= 7 &&
            line.text.trim().isNotEmpty &&
            line.height >= header.height * .45 &&
            line.x >= header.x - marginX &&
            line.x < inspection.chatRight! &&
            line.y >= bodyTop - marginY &&
            line.y < y + header.height &&
            line.y + line.height / 2 < bodyBottom)) {
      return null;
    }
    // Play detections remain under the unchanged video acquisition path.
    if (inspection.unboundMediaRegions.any((play) =>
        play.y >= header.y &&
        play.y + play.height / 2 < bodyBottom &&
        play.x >= inspection.chatLeft! &&
        play.x + play.width <= inspection.chatRight!)) {
      return null;
    }
    return ImageContextCopyTarget(
        x: x,
        y: y,
        header: header,
        bodyTop: bodyTop,
        bodyBottom: bodyBottom,
        chatLeft: inspection.chatLeft!,
        chatRight: inspection.chatRight!,
        chatTop: inspection.chatTop!,
        chatBottom: inspection.chatBottom!,
        confirmedRegion: boundedRegion);
  }
}
