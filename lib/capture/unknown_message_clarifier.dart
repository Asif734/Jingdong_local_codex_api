import '../domain/capture_models.dart';
import '../platform/macos_capture_adapter.dart';
import 'ocr_capture_extractor.dart';
import 'incoming_message_ownership.dart';
import 'ocr_image_candidate_selector.dart';

String _compact(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), '');

bool _sameFrozenPixels(OcrInspection a, OcrInspection b) {
  if (a.image.isEmpty || a.image.length != b.image.length) return false;
  for (var i = 0; i < a.image.length; i++) {
    if (a.image[i] != b.image[i]) return false;
  }
  return true;
}

bool _clock(String text) => RegExp(r'\d{1,2}[:：]\d{2}[:：]\d{2}').hasMatch(text);

bool _onlyClock(String text) =>
    RegExp(r'^\d{1,2}[:：]\d{2}[:：]\d{2}$').hasMatch(text.trim());

bool _customerHeader(OcrObservation line, String customer) {
  final text = _compact(line.text);
  return line.confidence >= .45 &&
      text.startsWith(_compact(customer)) &&
      _clock(line.text);
}

bool _sellerHeader(OcrObservation line) =>
    line.confidence >= .45 &&
    _clock(line.text) &&
    RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(line.text);

bool _inside(OcrInspection view, OcrObservation line) =>
    line.x >= (view.chatLeft ?? .24) &&
    line.x < (view.chatRight ?? .75) &&
    line.y >= (view.chatTop ?? .2) &&
    line.y < (view.chatBottom ?? .81);

bool _masked(OcrObservation line, Iterable<OcrVisualRegion> regions) =>
    regions.any((r) =>
        line.x + line.width / 2 >= r.x &&
        line.x + line.width / 2 <= r.x + r.width &&
        line.y + line.height / 2 >= r.y &&
        line.y + line.height / 2 <= r.y + r.height);

List<OcrObservation> _headers(OcrInspection view, String customer,
        {Iterable<OcrVisualRegion> excludedRegions = const []}) =>
    view.observations
        .where((o) =>
            !o.isWatermark &&
            _inside(view, o) &&
            !_masked(o, excludedRegions) &&
            (_customerHeader(o, customer) || _sellerHeader(o)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));

/// The position of one actual text bubble, bounded by its own sender header.
/// Identical messages in one second are assigned in visible occurrence order.
class IncomingTextBlock {
  const IncomingTextBlock(this.message, this.header, this.lines);
  final CapturedMessage message;
  final OcrObservation header;
  final List<OcrObservation> lines;

  double get top => lines.first.y;
  double get bottom => lines.last.y + lines.last.height;

  static List<IncomingTextBlock> locate(
      OcrInspection view, String customer, Iterable<CapturedMessage> messages,
      {Iterable<OcrVisualRegion> excludedRegions = const []}) {
    // Media acquisition and OCR run independently. A caller's older mask can
    // omit a card already proved by this frame. Its printed text is never a
    // customer text bubble, even while the original/cache match is pending.
    final masks = [
      ...excludedRegions,
      ...view.physicalMediaRegions ?? const <OcrVisualRegion>[],
      ...view.unboundMediaRegions,
    ];
    final headers = _headers(view, customer, excludedRegions: masks);
    final incoming = messages
        .where((m) =>
            m.direction == 'incoming' &&
            m.media.isEmpty &&
            m.mediaReceiptId == null &&
            m.body.trim().isNotEmpty)
        .toList();
    final result = <IncomingTextBlock>[];
    final occurrences = <String, int>{};
    for (final message in incoming) {
      final key =
          '${message.sentAt?.toUtc().toIso8601String()}:${_compact(message.body)}';
      final occurrence =
          occurrences.update(key, (n) => n + 1, ifAbsent: () => 0);
      final possible = <IncomingTextBlock>[];
      for (var i = 0; i < headers.length; i++) {
        final header = headers[i];
        if (!_customerHeader(header, customer)) continue;
        if (message.sender != null &&
            _compact(message.sender!) != _compact(customer) &&
            _compact(message.sender!) != _compact(header.text)) {
          continue;
        }
        if (message.sentAt == null ||
            const OcrCaptureExtractor()
                    .incomingClockAbove(view, header.y + header.height) !=
                message.sentAt) {
          continue;
        }
        final end =
            i + 1 < headers.length ? headers[i + 1].y : view.chatBottom ?? .81;
        final body = _compact(message.body);
        final lines = view.observations
            .where((line) =>
                line.confidence >= .45 &&
                _inside(view, line) &&
                line.y >= header.y + header.height - .002 &&
                line.y + line.height / 2 < end &&
                // Tiny labels inside a loading/clipped screenshot can have
                // confidence 1.0. Confidence alone does not prove chat prose.
                line.height >= header.height * .45 &&
                line.rotationDegrees.abs() <= 7 &&
                !_masked(line, masks) &&
                !_onlyClock(line.text) &&
                _compact(line.text).isNotEmpty &&
                body.contains(_compact(line.text)))
            .toList()
          ..sort((a, b) => a.y.compareTo(b.y));
        if (lines.isNotEmpty &&
            _compact(lines.map((line) => line.text).join()) == body) {
          possible.add(IncomingTextBlock(message, header, lines));
        }
      }
      final duplicates = incoming
          .where((other) =>
              other.sentAt == message.sentAt &&
              _compact(other.body) == _compact(message.body))
          .length;
      if (possible.length == duplicates && occurrence < possible.length) {
        result.add(possible[occurrence]);
      }
    }
    return result;
  }
}

/// Reclassifies an unresolved header-only placeholder, never an image/video.
/// The shared preceding sender block proves scroll displacement and bubble
/// ancestry. A clock match alone, or a new frame ID, grants no identity.
class UnknownMessageClarifier {
  /// Correct only a legacy synthetic screenshot which already contains the
  /// same short, uncertain chat text. This is not permission to reinterpret
  /// text printed in an actual image: the caller must also prove that the
  /// receipt contains only a fallback preview, never original/card evidence.
  static CapturedMessage? matchWeakScreenshotText({
    required String customer,
    required OcrInspection original,
    required OcrVisualRegion originalRegion,
    required OcrInspection current,
    required Iterable<CapturedMessage> messages,
    Iterable<OcrVisualRegion> excludedRegions = const [],
  }) {
    if (original.activeCustomerId != customer ||
        current.activeCustomerId != customer ||
        current.capturedAt.isBefore(original.capturedAt)) {
      return null;
    }
    bool sameRegion(OcrVisualRegion candidate) =>
        (candidate.x - originalRegion.x).abs() <= .002 &&
        (candidate.y - originalRegion.y).abs() <= .002 &&
        (candidate.width - originalRegion.width).abs() <= .002 &&
        (candidate.height - originalRegion.height).abs() <= .002;
    final owners = const OcrCaptureExtractor()
        .incomingMessageBlocks(original)
        .where((block) => sameRegion(block.region))
        .toList();
    if (owners.length != 1) return null;
    final owner = owners.single;
    // Repeated/ambiguous sender headers do not establish one bubble.
    if (const OcrCaptureExtractor()
            .incomingMessageBlocks(original)
            .where((block) => block.sentAt == owner.sentAt)
            .length !=
        1) {
      return null;
    }
    bool overlaps(OcrVisualRegion a, OcrVisualRegion b) =>
        a.x < b.x + b.width &&
        a.x + a.width > b.x &&
        a.y < b.y + b.height &&
        a.y + a.height > b.y;
    if ([
      ...original.visualRegions,
      ...original.physicalMediaRegions ?? const <OcrVisualRegion>[],
      ...original.unboundMediaRegions,
    ].any((card) => overlaps(card, originalRegion))) {
      return null;
    }
    final hints = owner.bodyHints
        .where((line) =>
            line.height <= .035 &&
            line.height >= owner.header.height * .45 &&
            line.rotationDegrees.abs() <= 7 &&
            line.y < owner.region.y + .07 &&
            !_onlyClock(line.text) &&
            RegExp(r'[A-Za-z0-9\u3400-\u9fff]').hasMatch(line.text))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final oldBody = _compact(hints.map((line) => line.text).join());
    if (oldBody.isEmpty || oldBody.length > 12) return null;
    final candidates =
        IncomingTextBlock.locate(current, customer, messages, excludedRegions: [
      ...excludedRegions,
      ...current.visualRegions,
      ...current.unboundMediaRegions,
    ])
            .where((block) =>
                block.message.sentAt == owner.sentAt &&
                _compact(block.message.body) == oldBody)
            .toList();
    return candidates.length == 1 ? candidates.single.message : null;
  }

  static CapturedMessage? match({
    required String customer,
    required OcrInspection original,
    required OcrVisualRegion originalRegion,
    required OcrInspection current,
    required Iterable<CapturedMessage> messages,
    Iterable<OcrVisualRegion> excludedRegions = const [],
  }) {
    if (original.activeCustomerId != customer ||
        current.activeCustomerId != customer ||
        current.capturedAt.isBefore(original.capturedAt)) {
      return null;
    }
    if (IncomingMessageOwnership.inspect(original, customer, originalRegion)
            ?.ownsMedia ==
        true) {
      // A prior unknown holder may now prove to contain a real play card.
      // Its printed pixels are not a newly decoded customer text message.
      return null;
    }
    // A full image card may still be inventory-kind unknown until matching
    // finishes. Preserve the original frame's positive pixel evidence too.
    if ((original.physicalMediaRegions ?? const <OcrVisualRegion>[]).any(
        (card) =>
            card.x < originalRegion.x + originalRegion.width &&
            card.x + card.width > originalRegion.x &&
            card.y < originalRegion.y + originalRegion.height &&
            card.y + card.height > originalRegion.y)) {
      return null;
    }
    final reconstructions = [
      ...const OcrCaptureExtractor()
          .incomingMessageBlocks(original)
          .map((block) => block.region),
      if (const OcrImageCandidateSelector()
              .fallbackLatestCustomerBlock(original, customer)
          case final legacy?)
        legacy,
    ];
    bool sameRegion(OcrVisualRegion candidate) =>
        (candidate.x - originalRegion.x).abs() <= .002 &&
        (candidate.y - originalRegion.y).abs() <= .002 &&
        (candidate.width - originalRegion.width).abs() <= .002 &&
        (candidate.height - originalRegion.height).abs() <= .002;
    if (!reconstructions.any(sameRegion)) return null;
    final bound = const OcrCaptureExtractor()
        .mediaClockForRegion(original, originalRegion);
    if (bound.source != 'ocr_media_sender_header' || bound.sentAt == null) {
      return null;
    }
    final oldHeaders = _headers(original, customer);
    final targets = oldHeaders.where((header) =>
        _customerHeader(header, customer) &&
        (header.y + header.height - bound.headerBottom!).abs() < .004);
    if (targets.length != 1) return null;
    final oldTarget = targets.single;
    final sameFrame = original.capturedAt == current.capturedAt &&
        original.imageWidth == current.imageWidth &&
        original.imageHeight == current.imageHeight &&
        _sameFrozenPixels(original, current);
    if (sameFrame) {
      final oldHeaderKey = _headers(original, customer)
          .map((h) =>
              '${_compact(h.text)}:${h.y.toStringAsFixed(5)}:${h.x.toStringAsFixed(5)}')
          .toList();
      final nowHeaderKey = _headers(current, customer)
          .map((h) =>
              '${_compact(h.text)}:${h.y.toStringAsFixed(5)}:${h.x.toStringAsFixed(5)}')
          .toList();
      if (oldHeaderKey.length == nowHeaderKey.length &&
          List.generate(oldHeaderKey.length,
              (i) => oldHeaderKey[i] == nowHeaderKey[i]).every((v) => v)) {
        final candidates = IncomingTextBlock.locate(current, customer, messages,
                excludedRegions: excludedRegions)
            .where((block) =>
                block.message.sentAt == bound.sentAt &&
                (block.header.y - oldTarget.y).abs() < .002 &&
                block.top >= originalRegion.y - .004 &&
                block.bottom <= originalRegion.y + originalRegion.height + .004)
            .toList();
        if (candidates.length == 1) return candidates.single.message;
      }
    }
    final oldAnchors = oldHeaders
        .where((header) => header.y < oldTarget.y && _sellerHeader(header))
        .toList();
    if (oldAnchors.isEmpty) return null;
    final anchor = oldAnchors.last;
    final nowHeaders = _headers(current, customer);
    final anchors = nowHeaders.where((header) =>
        _sellerHeader(header) &&
        _compact(header.text) == _compact(anchor.text));
    if (anchors.length != 1) return null;
    final nowAnchor = anchors.single;
    final delta = nowAnchor.y - anchor.y;
    final anchorLines = original.observations.where((line) =>
        _inside(original, line) &&
        line.confidence >= .45 &&
        line.y > anchor.y + anchor.height &&
        line.y + line.height < oldTarget.y &&
        !_onlyClock(line.text) &&
        _compact(line.text).length >= 8);
    // A sender label plus unchanged prose in its own block proves ancestry;
    // neither the header clock nor unchanged toolbar chrome suffices alone.
    final proseMatches = anchorLines.where((old) =>
        current.observations
            .where((line) =>
                _inside(current, line) &&
                line.confidence >= .45 &&
                _compact(line.text) == _compact(old.text) &&
                (line.x - old.x).abs() < .035 &&
                ((line.y - old.y) - delta).abs() < .018)
            .length ==
        1);
    if (proseMatches.isEmpty) return null;
    final oldPrefix = oldHeaders
        .where((header) => header.y > anchor.y && header.y <= oldTarget.y)
        .map((header) => _compact(header.text))
        .toList();
    final matches = <CapturedMessage>[];
    for (final block in IncomingTextBlock.locate(current, customer, messages,
        excludedRegions: excludedRegions)) {
      if (block.message.sentAt != bound.sentAt ||
          _compact(block.header.text) != _compact(oldTarget.text) ||
          ((block.header.y - oldTarget.y) - delta).abs() > .025) {
        continue;
      }
      final prefix = nowHeaders
          .where(
              (header) => header.y > nowAnchor.y && header.y <= block.header.y)
          .map((header) => _compact(header.text))
          .toList();
      if (prefix.length != oldPrefix.length ||
          List.generate(prefix.length, (i) => prefix[i] == oldPrefix[i])
              .contains(false)) {
        continue;
      }
      final projectedTop = originalRegion.y + delta;
      final projectedEnd = projectedTop + originalRegion.height;
      final center = (block.top + block.bottom) / 2;
      if (center < projectedTop - .02 || center > projectedEnd + .02) continue;
      matches.add(block.message);
    }
    return matches.length == 1 ? matches.single : null;
  }
}
