import '../domain/customer_message_time.dart';
import '../platform/macos_capture_adapter.dart';
import 'live_media_admission.dart';
import 'ocr_capture_extractor.dart';
import 'ocr_image_candidate_selector.dart';
import 'viewport_evidence.dart';

typedef ExactTimedCard = ({OcrVisualRegion region, DateTime sentAt});

/// Fast-path eligibility: immutable, AX-owned pixels, a complete native card,
/// and an exact sender second authorized by the original capture.
class ExactTimedMedia {
  static List<ExactTimedCard> select(
      ViewportEvidence frame, OcrInspection inspection,
      {required DateTime? sessionStartedAt}) {
    if (inspection.activeCustomerId != frame.customer ||
        inspection.physicalMediaRegions?.isNotEmpty != true) return [];
    const extractor = OcrCaptureExtractor();
    final text = extractor.analyze(inspection).capture?.messages;
    final groups = <String, List<ExactTimedCard>>{};
    for (final card in const OcrImageCandidateSelector().select(
      inspection,
      frame.customer,
      includeTextDense: true,
      customerText: (text ?? const [])
          .where((m) => m.direction == 'incoming' && m.media.isEmpty)
          .map((m) => m.body),
    )) {
      if (!inspection.physicalMediaRegions!.contains(card)) continue;
      final clock = extractor.mediaClockForRegion(inspection, card);
      final at = clock.sentAt;
      if (at == null || clock.source != 'ocr_media_sender_header') continue;
      final key = CustomerMessageTime.incomingId(frame.customer, at);
      final recoveryOnly = frame.metadata['acquisitionOnly'] == true;
      if (recoveryOnly
          ? frame.metadata['replyActivationAllowed'] != true ||
              !(frame.metadata['acquisitionInputKeys'] as List? ?? const [])
                  .contains(key)
          : !LiveMediaArrival.admitsCurrentTimestamp(
              evidence: frame,
              inspection: inspection,
              senderAt: at,
              sessionStartedAt: sessionStartedAt)) continue;
      groups.putIfAbsent(key, () => []).add((region: card, sentAt: at));
    }
    final result = groups.values
        .where((representations) => representations.length == 1)
        .map((representations) => representations.single)
        .toList()
      ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    return result;
  }

  /// Registration already established the owner. The frozen pixels must
  /// still independently prove a complete card and the same sender second.
  static List<ExactTimedCard> registered(ViewportEvidence frame,
      OcrInspection inspection, Map<OcrVisualRegion, DateTime> registered) {
    if (inspection.activeCustomerId != frame.customer) return [];
    final groups = <DateTime, List<ExactTimedCard>>{};
    for (final entry in registered.entries) {
      if (inspection.physicalMediaRegions?.contains(entry.key) != true)
        continue;
      final clock = const OcrCaptureExtractor()
          .mediaClockForRegion(inspection, entry.key);
      final at = clock.sentAt;
      if (clock.source != 'ocr_media_sender_header' ||
          at == null ||
          !CustomerMessageTime.sameSecond(at, entry.value)) continue;
      groups
          .putIfAbsent(CustomerMessageTime.second(at), () => [])
          .add((region: entry.key, sentAt: at));
    }
    return [
      for (final group in groups.values)
        if (group.length == 1) group.single,
    ];
  }

  /// A page is evidence for every already-admitted pending sender time.
  /// It never grants permission to introduce a new incoming message.
  static List<ExactTimedCard> forPending(ViewportEvidence frame,
      OcrInspection inspection, Iterable<DateTime> pendingTimes) {
    final times = pendingTimes
        .map((at) => CustomerMessageTime.second(at).toUtc())
        .toSet();
    final registered = <OcrVisualRegion, DateTime>{};
    for (final region
        in inspection.physicalMediaRegions ?? const <OcrVisualRegion>[]) {
      final clock =
          const OcrCaptureExtractor().mediaClockForRegion(inspection, region);
      if (clock.sentAt case final at?) {
        if (times.contains(CustomerMessageTime.second(at).toUtc()))
          registered[region] = at;
      }
    }
    return ExactTimedMedia.registered(frame, inspection, registered);
  }

  static Future<void> run(Iterable<ExactTimedCard> cards,
          Future<void> Function(ExactTimedCard) match) =>
      Future.wait<void>(cards.map(match));
}
