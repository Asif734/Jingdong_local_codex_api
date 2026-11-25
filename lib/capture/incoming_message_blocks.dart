import '../domain/capture_models.dart';
import '../platform/macos_capture_adapter.dart';
import 'live_media_admission.dart';
import 'incoming_message_ownership.dart';
import 'ocr_capture_extractor.dart';
import 'unknown_message_clarifier.dart';
import 'viewport_evidence.dart';

/// A current sender block is a durable duty before its body is decoded. It is
/// intentionally untyped: these proposals are registered, never cropped and
/// completed as if an image had already been established.
class UnknownIncomingBlocks {
  static List<OcrIncomingMessageBlock> locate({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required Iterable<CapturedMessage> messages,
    required String sessionId,
    required DateTime sessionStartedAt,
    Iterable<OcrVisualRegion> mediaRegions = const [],
    Map<OcrVisualRegion, String> knownMediaParents = const {},
    Map? frontier,
  }) {
    if (evidence.metadata['automationSessionId'] != sessionId ||
        evidence.capturedAt.isBefore(sessionStartedAt) ||
        evidence.metadata['replyActivationAllowed'] != true ||
        inspection.activeCustomerId != evidence.customer) {
      return [];
    }
    final media = mediaRegions.toList(growable: false);
    final text = IncomingTextBlock.locate(
        inspection, evidence.customer, messages,
        excludedRegions: media);
    final blocks = const OcrCaptureExtractor()
        .incomingMessageBlocks(inspection, excludedMediaRegions: media);
    final candidates = blocks.where((block) {
      if (text.any((decoded) =>
          (decoded.header.y - block.header.y).abs() < .006 &&
          decoded.message.sentAt == block.sentAt)) {
        return false;
      }
      // A media candidate beginning in this sender block already has one
      // owner. A preceding image extending toward a later header is not that
      // later message's owner and must not suppress its unknown obligation.
      return !IncomingMessageOwnership.occupiesBlock(
          inspection, evidence.customer,
          header: block.header, bodyRegion: block.region, mediaRegions: media);
    }).toList(growable: false);
    final allowed = LiveMediaArrival.infer(
        evidence: evidence,
        inspection: inspection,
        cards: candidates.map((b) => b.region),
        headers: {
          for (final block in candidates)
            block.region: OcrMediaClockEvidence(
                source: 'ocr_media_sender_header',
                sentAt: block.sentAt,
                headerTop: block.header.y,
                headerBottom: block.header.y + block.header.height,
                confidence: block.header.confidence)
        },
        knownParents: knownMediaParents,
        visibleText: messages,
        frontier: frontier,
        sessionStartedAt: sessionStartedAt);
    // These blocks already have complete sender clocks. A second geometry
    // rescue rule could override the fixed run boundary decided by infer.
    return candidates
        .where((block) => allowed.containsKey(block.region))
        .toList();
  }
}
