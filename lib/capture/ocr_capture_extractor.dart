import 'transcript_text.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import '../codex/holding_replies.dart';
import '../platform/macos_capture_adapter.dart';
import '../runtime/runtime_trace.dart';
import 'ocr_image_candidate_selector.dart';
import 'ocr_chat_layout.dart';
import 'incoming_message_ownership.dart';

/// Converts one OCR diagnostic scan of an *open* Qianniu conversation into a
/// conservative capture candidate. All visible incoming and seller-authored
/// bubbles with a clear sender/body relationship are returned; durable IDs
/// remove older duplicates.
class OcrCaptureExtractor {
  const OcrCaptureExtractor({this.bodyConfidenceThreshold = 0.45});

  /// Recovery may relax body recognition, but sender labels and customer
  /// identity must continue to meet the normal confidence threshold.
  final double bodyConfidenceThreshold;
  static const double senderConfidenceThreshold = 0.45;

  // JD indents wrapped bubble lines independently. In particular, a short
  // final line can start to the left of the longer line above it. Treat the
  // whole center conversation column as message content; sender labels, not
  // per-line x alignment, define where a message starts and ends.
  static const double _chatBodyLeft = 0.15;
  static const double _chatBodyRight = 0.66;

  CapturedConversation? extract(OcrInspection inspection) =>
      analyze(inspection).capture;

  /// Use only individually proven incoming bubbles from the same AX-owned
  /// viewport. Unresolved geometry, media or clocks do not veto other text.
  TextFirstRegistrationPlan planTextFirst(OcrInspection view, String customer) {
    if (view.ocrEngine != 'apple_vision_text_first' ||
        !customerIdentitiesMatch(view.activeCustomerId, customer)) {
      return const TextFirstRegistrationPlan(null, {'unverified_frame'});
    }
    const selector = OcrImageCandidateSelector();
    final media = [
      ...view.unboundMediaRegions,
      ...selector.select(view, customer,
          includeTextDense: true, allowUnlabeledLatestImage: true),
    ];
    final result = analyze(view, excludedMediaRegions: media);
    final capture = result.capture;
    final incoming =
        capture?.messages.where((m) => m.direction == 'incoming').toList() ??
            [];
    final blocks = incomingMessageBlocks(view, excludedMediaRegions: media);
    final byClock = <DateTime, List<OcrIncomingMessageBlock>>{};
    for (final block in blocks) {
      (byClock[block.sentAt] ??= []).add(block);
    }
    bool overlapsMedia(OcrIncomingMessageBlock block) => media.any((r) =>
        r.y + r.height > block.region.y + .004 &&
        r.y < block.region.y + block.region.height - .004);
    // When a media card is visible, avoid submitting a deictic caption
    // before the media registrar can bind its exact dependencies.
    final mediaReference = RegExp(
        r'这个|那个|上面|刚发|发的|这张|那张|图[片里中]|视频|画面|你看|能看到|what about|in (this|the) (photo|image|video)|\b(this|that)\b',
        caseSensitive: false);
    final ready = <CapturedMessage>[];
    for (final m in incoming) {
      final matches = byClock[m.sentAt];
      if (matches == null ||
          matches.length != 1 ||
          incoming.where((other) => other.sentAt == m.sentAt).length != 1) {
        continue;
      }
      final block = matches.single;
      if (block.header.confidence < .72 ||
          block.bodyHints.isNotEmpty ||
          overlapsMedia(block) ||
          m.media.isNotEmpty ||
          m.body.trim().runes.length < 2 ||
          (media.isNotEmpty && mediaReference.hasMatch(m.body))) {
        continue;
      }
      ready.add(m);
    }
    final readyClocks = ready.map((m) => m.sentAt).toSet();
    final timedMediaClocks = {
      for (final region in media)
        if (mediaClockForRegion(view, region).sentAt case final at?) at,
    };
    final coveredClocks = {...readyClocks, ...timedMediaClocks};
    final unlocatedMedia =
        media.any((region) => mediaClockForRegion(view, region).sentAt == null);
    final needsReview = <String>{
      if (unlocatedMedia) 'unlocated_media',
      if (result.transferNoticeVisible) 'transfer_notice',
      if (shortCustomerTextRegions(view).isNotEmpty) 'weak_text',
      if (incoming.any((message) => !readyClocks.contains(message.sentAt)) ||
          blocks.any((block) => !coveredClocks.contains(block.sentAt)))
        'unresolved_message',
      if (result.latestVisibleSenderIsIncoming &&
          (result.latestIncomingSentAt == null ||
              !coveredClocks.contains(result.latestIncomingSentAt)))
        'unresolved_latest_customer_bubble',
      if (_damagedIncomingHeaders(view, OcrChatLayout(view)).isNotEmpty)
        'unresolved_header',
      if (blocks.isEmpty &&
          timedMediaClocks.isEmpty &&
          (capture == null ||
              !capture.messages.any((m) => m.direction == 'outgoing')))
        'no_timed_visible_message',
    };
    return TextFirstRegistrationPlan(
        capture == null || ready.isEmpty
            ? null
            : CapturedConversation(
                stableKey: capture.stableKey,
                customerName: capture.customerName,
                customerExternalId: capture.customerExternalId,
                capturedAt: capture.capturedAt,
                messages: ready),
        needsReview);
  }

  bool acceptsTextFirst(OcrInspection inspection, String customer) =>
      !planTextFirst(inspection, customer).needsFullRecognition;

  /// All independently bounded incoming blocks, including unread bodies.
  /// AX supplies customer identity; OCR supplies only this block's position.
  /// This is not a media classifier or permission to activate history.
  List<OcrIncomingMessageBlock> incomingMessageBlocks(OcrInspection view,
      {Iterable<OcrVisualRegion> excludedMediaRegions = const []}) {
    final customer = view.activeCustomerId;
    if (customer == null ||
        customer.trim().isEmpty ||
        MacOSCaptureAdapter.isProvisionalIdentity(customer) ||
        customer.contains('…') ||
        customer.contains('...')) {
      return [];
    }
    final layout = OcrChatLayout(view);
    final left = view.chatLeft ?? .24, right = view.chatRight ?? .75;
    final top = view.chatTop ?? .2, bottom = view.chatBottom ?? .81;
    bool masked(OcrObservation line) => excludedMediaRegions.any((r) =>
        line.x + line.width / 2 >= r.x &&
        line.x + line.width / 2 < r.x + r.width &&
        line.y + line.height / 2 > r.y + .012 &&
        line.y + line.height / 2 < r.y + r.height);
    String? clock(OcrObservation line) =>
        _timestamp.firstMatch(line.text)?.group(0) ??
        view.observations
            .where((other) =>
                other.confidence >= senderConfidenceThreshold &&
                !other.isWatermark &&
                (other.y + other.height / 2 - line.y - line.height / 2).abs() <
                    .009 &&
                other.x > line.x &&
                RegExp(r'^\d{1,2}[:：]\d{2}[:：]\d{2}$')
                    .hasMatch(other.text.trim()))
            .map((other) => other.text.trim())
            .firstOrNull;
    final boundaries = view.observations
        .where((line) =>
            !line.isWatermark &&
            line.rotationDegrees.abs() < 12 &&
            line.confidence >= senderConfidenceThreshold &&
            line.height <= .045 &&
            line.y >= top &&
            line.y < bottom &&
            line.x + line.width / 2 >= left &&
            line.x + line.width / 2 < right &&
            !masked(line) &&
            !layout.isInterface(line) &&
            ((_sameIdentity(line.text, customer) &&
                    line.x < left + (right - left) * .4 &&
                    clock(line) != null) ||
                (_isSellerIdentity(line.text) && clock(line) != null) ||
                RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(line.text)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final result = <OcrIncomingMessageBlock>[];
    final counts = <String, int>{};
    for (var index = 0; index < boundaries.length; index++) {
      final header = boundaries[index];
      if (!_sameIdentity(header.text, customer)) continue;
      final at =
          _parseTimestamp(clock(header), view.capturedAt, requireSeconds: true);
      if (at == null) continue;
      final start = header.y + header.height + .004;
      final end = (index + 1 < boundaries.length
              ? boundaries[index + 1].y - .004
              : bottom) -
          .000001;
      if (end - start < .016) continue;
      final key = at.toUtc().toIso8601String();
      final ordinal = counts.update(key, (n) => n + 1, ifAbsent: () => 0);
      result.add(OcrIncomingMessageBlock(
          header: header,
          sentAt: at,
          ordinal: ordinal,
          bodyHints: view.observations
              .where((line) =>
                  !line.isWatermark &&
                  line.rotationDegrees.abs() <= 7 &&
                  line.confidence >= .2 &&
                  line.confidence < bodyConfidenceThreshold &&
                  line.text.trim().isNotEmpty &&
                  line.text.trim().length <= 12 &&
                  line.y >= start &&
                  line.y + line.height / 2 < end &&
                  line.x >= left &&
                  line.x < left + (right - left) * .25 &&
                  !masked(line) &&
                  !layout.isInterface(line))
              .toList(),
          region: OcrVisualRegion(
              x: left,
              y: start,
              width: (right - left).clamp(.12, .42).toDouble(),
              height: (end - start).clamp(.016, .60).toDouble(),
              confidence: 0)));
    }
    return result;
  }

  /// Resolve a region's sender clock from the pixels above that region.
  /// Text printed inside the photo cannot replace the chat sender timestamp.
  DateTime? incomingClockAbove(OcrInspection inspection, double top) {
    final result = _analyzeAboveMedia(inspection, top);
    return result.latestVisibleSenderIsIncoming
        ? result.latestIncomingSentAt
        : null;
  }

  /// A media clock belongs to the nearby sender header above that card, never
  /// to the newest text elsewhere in the viewport. Vision's media rectangle
  /// can overlap the last pixels of its own header; compare header TOPs when
  /// building the prefix, then bound the association by the real header box.
  OcrMediaClockEvidence mediaClockForRegion(
      OcrInspection inspection, OcrVisualRegion region) {
    if (!OcrChatLayout(inspection).allowedMedia(region)) {
      return const OcrMediaClockEvidence(source: 'region_not_incoming_media');
    }
    final ownership = IncomingMessageOwnership.inspect(
        inspection, inspection.activeCustomerId ?? '', region);
    if (ownership?.uniquePhysicalCard == true) {
      return OcrMediaClockEvidence(
          source: ownership!.exactCustomerHeader
              ? 'ocr_media_sender_header'
              : 'visual_incoming_sender_block',
          sentAt: ownership.sentAt,
          headerTop: ownership.header.y,
          headerBottom: math.min(ownership.header.y + ownership.header.height,
              ownership.mediaContentRegion.y),
          confidence: ownership.header.confidence);
    }
    final result = _analyzeAboveMedia(inspection, region.y);
    final header = result.latestIncomingHeader;
    if (!result.latestVisibleSenderIsIncoming) {
      return const OcrMediaClockEvidence(
          source: 'no_incoming_header_above_card');
    }
    if (header == null || result.latestIncomingSentAt == null) {
      return const OcrMediaClockEvidence(
          source: 'media_header_clock_unreadable');
    }
    if (result.latestIncomingHasText) {
      // A missing media header cannot borrow the preceding text bubble's
      // clock merely because that text is close to the card.
      return OcrMediaClockEvidence(
          source: 'media_header_already_owns_text',
          headerTop: header.y,
          headerBottom: header.y + header.height,
          confidence: header.confidence);
    }
    final gap = region.y - (header.y + header.height);
    if (gap > .08 || gap < -math.min(.025, header.height * .8)) {
      return OcrMediaClockEvidence(
          source: 'media_header_not_adjacent',
          headerTop: header.y,
          headerBottom: header.y + header.height,
          confidence: header.confidence);
    }
    return OcrMediaClockEvidence(
        sentAt: result.latestIncomingSentAt,
        source: 'ocr_media_sender_header',
        headerTop: header.y,
        headerBottom: header.y + header.height,
        confidence: header.confidence);
  }

  OcrExtractionAttempt _analyzeAboveMedia(
          OcrInspection inspection, double top) =>
      analyze(
          OcrInspection(
              image: inspection.image,
              imageWidth: inspection.imageWidth,
              imageHeight: inspection.imageHeight,
              windowTitle: inspection.windowTitle,
              recognizedText: '',
              capturedAt: inspection.capturedAt,
              activeCustomerId: inspection.activeCustomerId,
              windowId: inspection.windowId,
              chatTop: inspection.chatTop,
              chatLeft: inspection.chatLeft,
              chatRight: inspection.chatRight,
              chatBottom: inspection.chatBottom,
              observations: inspection.observations
                  .where((line) => line.y <= top + .002)
                  .toList()),
          preserveCustomerPunctuation: false);

  /// Start generation from clear text on the independent signal scan. Any
  /// customer media or uncertain body still goes through the full capture.
  CapturedConversation? verifiedFastTextCapture(OcrInspection inspection) {
    final result = const OcrCaptureExtractor(bodyConfidenceThreshold: .8)
        .analyze(inspection);
    final capture = result.capture;
    if (capture == null ||
        !result.latestVisibleSenderIsIncoming ||
        !result.latestIncomingHasText ||
        result.transferNoticeVisible ||
        result.latestIncomingSentAt == null ||
        const OcrImageCandidateSelector()
            .select(inspection, capture.customerName,
                includeTextDense: true, onlyLatestCustomerBlock: true)
            .isNotEmpty) {
      return null;
    }
    final latest = capture.messages.lastOrNull;
    if (latest?.direction != 'incoming' ||
        latest?.sentAt != result.latestIncomingSentAt) {
      return null;
    }
    // Do not send a partial sentence when only some wrapped lines meet the
    // fast-path threshold. The accurate scan owns mixed-confidence bodies.
    final ordinary = analyze(inspection).capture?.messages.lastOrNull;
    if (ordinary?.stableId != latest?.stableId) return null;
    final messages = capture.messages.reversed
        .takeWhile((message) => message.direction == 'incoming')
        .toList()
        .reversed
        .toList(growable: false);
    return CapturedConversation(
      stableKey: capture.stableKey,
      customerName: capture.customerName,
      customerExternalId: capture.customerExternalId,
      messages: messages,
      capturedAt: capture.capturedAt,
    );
  }

  List<OcrVisualRegion> shortCustomerTextRegions(OcrInspection inspection) {
    final layout = OcrChatLayout(inspection);
    final result = <OcrVisualRegion>[];
    for (final line in inspection.observations) {
      if (line.confidence < .25 ||
          line.confidence >= .45 ||
          line.text.trim().isEmpty ||
          line.text.trim().length > 12 ||
          line.isWatermark ||
          line.rotationDegrees.abs() > 7 ||
          !layout.inTranscript(line) ||
          layout.isInterface(line) ||
          TranscriptText.clean(line.text).isEmpty ||
          line.x > layout.left + (layout.right - layout.left) * .25) {
        continue;
      }
      final headers = inspection.observations.where((o) =>
          _sameIdentity(o.text, inspection.activeCustomerId ?? '') &&
          layout.hasSenderClock(o) &&
          o.y < line.y &&
          line.y - o.y < .12);
      if (headers.isEmpty) continue;
      if (inspection.visualRegions.any((r) =>
          r.width > .025 &&
          r.height > .065 &&
          line.x >= r.x &&
          line.x < r.x + r.width &&
          line.y >= r.y &&
          line.y < r.y + r.height)) {
        continue;
      }
      final x = (line.x - .008).clamp(layout.left, layout.right - .01);
      final y = (line.y - .008).clamp(layout.top, layout.bottom - .01);
      result.add(OcrVisualRegion(
          x: x,
          y: y,
          width: (line.width + .04).clamp(.01, math.min(.2, layout.right - x)),
          height:
              (line.height + .025).clamp(.01, math.min(.1, layout.bottom - y)),
          confidence: line.confidence));
      if (result.length >= 2) break;
    }
    return result;
  }

  /// Re-read at most one unresolved header from the already saved frame.
  /// The crop supplies only a clock; the active AX customer still owns it.
  Future<OcrInspection> refineIncomingClockHeaders(OcrInspection inspection,
      {required Future<List<OcrObservation>> Function(OcrVisualRegion region)
          refine}) async {
    final layout = OcrChatLayout(inspection);
    final headers = _damagedIncomingHeaders(inspection, layout)
        .where(
            (header) => _damagedSenderClock(header, inspection, layout) == null)
        .toList()
      ..sort((a, b) => b.y.compareTo(a.y));
    if (headers.isEmpty) return inspection;
    final header = headers.first;
    final x = math.max(layout.left, header.x - .006);
    final y = math.max(layout.top, header.y - .005);
    final region = OcrVisualRegion(
        x: x,
        y: y,
        width: math.min(layout.right - x, header.x + header.width + .016 - x),
        height: math.min(layout.bottom - y, header.y + header.height - y),
        confidence: header.confidence);
    final List<OcrObservation> lines;
    try {
      lines = await refine(region);
    } catch (_) {
      // Optional saved-pixel OCR must not discard the rest of this frame.
      return inspection;
    }
    final clocks = <String, DateTime>{};
    for (final line in lines) {
      final centerX = line.x + line.width / 2;
      final centerY = _verticalCenter(line);
      if (line.confidence < .65 ||
          line.rotationDegrees.abs() > 7 ||
          line.isWatermark ||
          centerX < region.x ||
          centerX > region.x + region.width ||
          centerY < region.y ||
          centerY > region.y + region.height) {
        continue;
      }
      final clock = _fullClockAtEnd(line.text);
      if (clock == null) continue;
      final sellerOrOtherName = line.text
          .trim()
          .substring(0, line.text.trim().length - clock.length)
          .trim();
      final customer = inspection.activeCustomerId!;
      if (sellerOrOtherName.isNotEmpty &&
          !_sameIdentity(sellerOrOtherName, customer) &&
          !_looksLikeDamagedJdSender(sellerOrOtherName, customer)) {
        continue;
      }
      final at =
          _parseTimestamp(clock, inspection.capturedAt, requireSeconds: true);
      if (at != null) clocks[clock] = at;
    }
    if (clocks.values.toSet().length != 1) return inspection;
    final previousClock = _timestamp.firstMatch(header.text)?.group(0);
    final confirmed = clocks.entries.first;
    if (previousClock != null && _fullClockAtEnd(header.text) == null) {
      final priorMinute = _parseTimestamp(previousClock, inspection.capturedAt);
      if (priorMinute == null ||
          priorMinute.millisecondsSinceEpoch ~/ 60000 !=
              confirmed.value.millisecondsSinceEpoch ~/ 60000) {
        return inspection;
      }
    }
    final recovered = OcrObservation(
        text:
            '${header.text.replaceAll(_timestamp, '').trim()} ${confirmed.key}',
        confidence: header.confidence,
        x: header.x,
        y: header.y,
        width: header.width,
        height: header.height,
        rotationDegrees: header.rotationDegrees);
    if (_damagedSenderClock(recovered, inspection, layout) == null) {
      return inspection;
    }
    RuntimeTrace.record('capture.incoming_header_clock_recovered', {
      'customer': inspection.activeCustomerId,
      'capturedAt': inspection.capturedAt.toUtc().toIso8601String(),
      'senderAt': confirmed.value.toUtc().toIso8601String(),
      'identitySource': 'accessibility_active_customer',
    });
    return inspection.withObservations([
      for (final line in inspection.observations)
        identical(line, header) ? recovered : line
    ]);
  }

  static final _jdSender =
      RegExp(r'^jd_([a-z0-9]{10,32})$', caseSensitive: false);

  bool _looksLikeDamagedJdSender(String value, String customer) {
    final expected = _jdSender.firstMatch(customer)?.group(1)?.toLowerCase();
    if (expected == null) return false;
    final raw = value.trim();
    final suffix = RegExp(r'[A-Za-z0-9]{9,33}$').firstMatch(raw);
    if (suffix == null ||
        !RegExp(r'^(?:[\u3400-\u9fff]\s+)?[jdiol01]{1,3}[_\s-]+$',
                caseSensitive: false)
            .hasMatch(raw.substring(0, suffix.start))) {
      return false;
    }
    // At most one OCR substitution/insertion/deletion in the opaque suffix.
    // This is merely a boundary hint inside the already verified AX chat.
    final observed = suffix.group(0)!.toLowerCase();
    if ((observed.length - expected.length).abs() > 1) return false;
    if (observed.length == expected.length) {
      return Iterable<int>.generate(expected.length)
              .where((i) => observed[i] != expected[i])
              .length <=
          1;
    }
    final longer = observed.length > expected.length ? observed : expected;
    final shorter = observed.length > expected.length ? expected : observed;
    return Iterable<int>.generate(longer.length).any(
        (i) => longer.substring(0, i) + longer.substring(i + 1) == shorter);
  }

  String? _fullClockAtEnd(String text) {
    final trimmed = text.trim();
    final clocks = _timestamp.allMatches(trimmed).toList();
    if (clocks.length != 1 || clocks.single.end != trimmed.length) return null;
    final clock = clocks.single.group(0)!;
    return _clockTimestamp.firstMatch(clock)?.group(3) != null ||
            _datedTimestamp.firstMatch(clock)?.group(6) != null
        ? clock
        : null;
  }

  String? _damagedSenderClock(
      OcrObservation line, OcrInspection view, OcrChatLayout layout) {
    final clock = _fullClockAtEnd(line.text);
    final at = _parseTimestamp(clock, view.capturedAt, requireSeconds: true);
    if (at == null) return null;
    // A weak clock must agree with the neighboring normal sender rows. In
    // particular an impossible future hour may otherwise roll back one date.
    final middle = (layout.left + layout.right) / 2;
    final customer = view.activeCustomerId!;
    double beforeGap = double.infinity, afterGap = double.infinity;
    DateTime? before, after;
    for (final other in view.observations) {
      final gap = other.y - line.y;
      if (other.confidence < senderConfidenceThreshold ||
          other.isWatermark ||
          other.rotationDegrees.abs() > 7 ||
          other.height > .04 ||
          gap.abs() < .025 ||
          !layout.inTranscript(other) ||
          layout.isInterface(other) ||
          !(other.x < middle && _sameIdentity(other.text, customer) ||
              other.x >= middle && _isSellerIdentity(other.text))) {
        continue;
      }
      final anchor =
          _parseTimestamp(other.text, view.capturedAt, requireSeconds: true);
      if (anchor == null) continue;
      if (gap < 0 && -gap < beforeGap) {
        beforeGap = -gap;
        before = anchor;
      } else if (gap > 0 && gap < afterGap) {
        afterGap = gap;
        after = anchor;
      }
    }
    if (before?.isAfter(at) == true || after?.isBefore(at) == true) return null;
    return clock;
  }

  bool _clearlyIncomingBody(OcrObservation item, OcrChatLayout layout) =>
      item.x >= layout.left &&
      item.x <= layout.left + (layout.right - layout.left) * .18 &&
      item.x + item.width < (layout.left + layout.right) / 2;

  Set<OcrObservation> _damagedIncomingHeaders(
      OcrInspection view, OcrChatLayout layout,
      {Iterable<OcrVisualRegion> excludedMediaRegions = const []}) {
    final customer = view.activeCustomerId?.trim();
    if (customer == null ||
        !_jdSender.hasMatch(customer) ||
        view.chatTop == null ||
        view.chatLeft == null ||
        view.chatRight == null ||
        view.chatBottom == null ||
        layout.left < 0 ||
        layout.right > 1 ||
        layout.right - layout.left < .10) {
      return {};
    }
    final media = [
      ...view.visualRegions.where((r) => r.width > .025 && r.height > .065),
      ...view.unboundMediaRegions,
      ...excludedMediaRegions,
    ];
    bool outsideMedia(OcrObservation line) => !media.any((r) =>
        line.x + line.width / 2 >= r.x &&
        line.x + line.width / 2 <= r.x + r.width &&
        _verticalCenter(line) >= r.y &&
        _verticalCenter(line) <= r.y + r.height);
    final lines = view.observations
        .where((line) =>
            !line.isWatermark &&
            layout.inTranscript(line) &&
            !layout.isInterface(line) &&
            outsideMedia(line))
        .toList();
    final span = layout.right - layout.left;
    return lines.where((header) {
      // Do not replace an ordinary sender line, including a clean name whose
      // clock is a separate OCR observation next to it.
      if (_sameIdentity(header.text, customer) &&
          header.confidence >= senderConfidenceThreshold &&
          header.rotationDegrees.abs() <= 7 &&
          header.height <= .04 &&
          layout.hasSenderClock(header)) {
        return false;
      }
      if (header.confidence < .25 ||
          header.rotationDegrees.abs() > 10 ||
          header.height <= 0 ||
          header.height > .065 ||
          header.x < layout.left ||
          header.x > layout.left + span * .06 ||
          header.x + header.width > (layout.left + layout.right) / 2 ||
          !_looksLikeDamagedJdSender(
              header.text.replaceAll(_timestamp, ''), customer)) {
        return false;
      }
      final adjacent = lines.where((line) =>
          line.y >= header.y + math.max(.014, header.height - .010) &&
          line.y < header.y + header.height + .035 &&
          line.x >= header.x + .012 &&
          _clearlyIncomingBody(line, layout) &&
          line.confidence >= .60 &&
          line.rotationDegrees.abs() <= 7 &&
          !_isMetadata(line.text, customer) &&
          !_timestamp.hasMatch(line.text) &&
          RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(line.text));
      return adjacent.isNotEmpty;
    }).toSet();
  }

  OcrExtractionAttempt analyze(OcrInspection inspection,
      {List<OcrVisualRegion> excludedMediaRegions = const [],
      bool preserveCustomerPunctuation = true}) {
    final allObservations = inspection.observations
        .where((item) =>
            !item.isWatermark &&
            item.rotationDegrees.abs() <= 7 &&
            item.confidence >= .20 &&
            item.text.trim().isNotEmpty)
        .toList(growable: false);
    final suppliedCustomer = inspection.activeCustomerId?.trim();
    final customerId = suppliedCustomer != null &&
            suppliedCustomer.isNotEmpty &&
            !MacOSCaptureAdapter.isProvisionalIdentity(suppliedCustomer) &&
            !suppliedCustomer.contains('…') &&
            !suppliedCustomer.contains('...')
        ? suppliedCustomer
        : null;
    final layout = OcrChatLayout(inspection);
    final observations = allObservations
        .where((o) => layout.inTranscript(o) && !layout.isInterface(o))
        .toList(growable: false);
    final transferNoticeKey = _transferNoticeKey(allObservations, customerId);
    final transferNoticeVisible = transferNoticeKey != null;
    if (customerId == null) {
      return const OcrExtractionAttempt(
          reason:
              'AX customer identity unavailable; OCR cannot establish a customer ID.');
    }
    final verifiedChatLeft = inspection.chatLeft;
    final verifiedChatRight = inspection.chatRight;
    final hasVerifiedChatRegion = verifiedChatLeft != null &&
        verifiedChatRight != null &&
        verifiedChatLeft >= 0 &&
        verifiedChatRight <= 1 &&
        verifiedChatRight - verifiedChatLeft >= 0.10;
    final chatLeft = hasVerifiedChatRegion ? verifiedChatLeft : _chatBodyLeft;
    final chatRight =
        hasVerifiedChatRegion ? verifiedChatRight : _chatBodyRight;
    final chatBottom = inspection.chatBottom != null &&
            inspection.chatBottom! > 0.25 &&
            inspection.chatBottom! <= 0.95
        ? inspection.chatBottom!
        : 0.82;

    bool incomingHeader(OcrObservation item) {
      if (_sameIdentity(item.text, customerId)) {
        return !hasVerifiedChatRegion ||
            OcrChatLayout(inspection).hasSenderClock(item);
      }
      // Direction only: an AX-confirmed chat may have OCR-corrupted sender
      // glyphs (jd -> id, j -> i). Never use this to select a customer ID.
      final withoutClock = item.text.replaceAll(_timestamp, '').trim();
      return suppliedCustomer != null &&
          hasVerifiedChatRegion &&
          layout.hasSenderClock(item) &&
          item.height <= .04 &&
          item.x >= chatLeft &&
          item.x <= chatLeft + (chatRight - chatLeft) * .15 &&
          (RegExp(r'^[A-Za-z]{1,3}_[A-Za-z0-9_]{4,64}$')
                  .hasMatch(withoutClock) ||
              RegExp(r'^[\u3400-\u9fff]{2,24}$').hasMatch(withoutClock));
    }

    bool sellerHeader(OcrObservation item) {
      final known = _isSellerIdentity(item.text);
      // A clipped seller clock/name may lose both its valid clock and the
      // first name glyphs. Only another intact seller header in these exact
      // pixels, on the same header rail, can establish this role boundary.
      // This does not establish any customer identity or discard arbitrary
      // right-hand prose mentioning the shop.
      final damagedBoundary = hasVerifiedChatRegion &&
          item.height <= .04 &&
          item.x >= chatLeft + (chatRight - chatLeft) * .5 &&
          RegExp(r'^\s*\d').hasMatch(item.text) &&
          item.text.contains(RegExp(r'[:：]')) &&
          observations.any((anchor) {
            if (identical(anchor, item) ||
                anchor.confidence < senderConfidenceThreshold ||
                anchor.height > .04 ||
                !_isSellerIdentity(anchor.text) ||
                !layout.hasSenderClock(anchor) ||
                (anchor.x - item.x).abs() > .008 ||
                ((anchor.x + anchor.width) - (item.x + item.width)).abs() >
                    .012) {
              return false;
            }
            final name = anchor.text.replaceAll(_timestamp, '').trim();
            final candidate = item.text.trim();
            var shared = 0;
            while (shared < name.length &&
                shared < candidate.length &&
                name[name.length - shared - 1] ==
                    candidate[candidate.length - shared - 1]) {
              shared++;
            }
            return shared >= 4 &&
                RegExp(r'^[\u3400-\u9fff]+$')
                    .hasMatch(name.substring(name.length - shared));
          });
      final name = item.text.replaceAll(_timestamp, '').trim();
      final rightHeader = hasVerifiedChatRegion &&
          item.x >= chatLeft + (chatRight - chatLeft) * .5 &&
          item.height <= .04 &&
          name.isNotEmpty &&
          name.length <= 40 &&
          RegExp(r'^[\u3400-\u9fffA-Za-z0-9_\-\s\[\]［］「」·]+$').hasMatch(name);
      return (known || rightHeader || damagedBoundary) &&
          (!hasVerifiedChatRegion ||
              layout.hasSenderClock(item) ||
              damagedBoundary) &&
          (!hasVerifiedChatRegion ||
              (item.height <= .04 &&
                  item.x + item.width >=
                      chatLeft + (chatRight - chatLeft) * .5));
    }

    final damagedHeaders = _damagedIncomingHeaders(inspection, layout,
        excludedMediaRegions: excludedMediaRegions);
    final messageLabels = observations
        .where((item) =>
            !damagedHeaders.contains(item) &&
            // AX establishes identity. A low-confidence exact customer header
            // with a clock and left-bubble geometry is a direction boundary,
            // never a new identity or a reason to inherit the seller's role.
            (item.confidence >= senderConfidenceThreshold ||
                (item.confidence >= .20 &&
                    suppliedCustomer != null &&
                    hasVerifiedChatRegion &&
                    layout.hasSenderClock(item) &&
                    item.height <= .04 &&
                    ((incomingHeader(item) &&
                            item.x <=
                                chatLeft + (chatRight - chatLeft) * .22) ||
                        (sellerHeader(item) &&
                            item.x >=
                                chatLeft + (chatRight - chatLeft) * .50)))) &&
            (incomingHeader(item) || sellerHeader(item)) &&
            item.x + item.width / 2 >= chatLeft &&
            item.x + item.width / 2 < chatRight &&
            item.y >= (inspection.chatTop ?? .18) &&
            item.y < chatBottom)
        .map((item) => _MessageLabel(
              observation: item,
              direction: incomingHeader(item) ? 'incoming' : 'outgoing',
            ))
        .toList()
      ..addAll(damagedHeaders.map((header) => _MessageLabel(
          observation: header, direction: 'incoming', damaged: true)))
      ..sort(
          (left, right) => left.observation.y.compareTo(right.observation.y));
    if (messageLabels.isEmpty) {
      return OcrExtractionAttempt(
          reason: 'Customer $customerId was identified, but no matching '
              'message sender label was visible in the chat area.',
          customerId: customerId,
          transferNoticeVisible: transferNoticeVisible,
          transferNoticeKey: transferNoticeKey);
    }
    for (final label in messageLabels) {
      if (label.direction == 'incoming' &&
          (label.damaged ||
              label.observation.confidence < senderConfidenceThreshold ||
              !_sameIdentity(label.observation.text, customerId))) {
        RuntimeTrace.record('capture.sender_role_inferred', {
          'customer': customerId,
          'direction': 'incoming',
          'source': label.damaged
              ? 'ax_verified_adjacent_left_damaged_header'
              : 'ax_verified_chat_left_clock_header',
          'headerText': label.observation.text,
          'headerConfidence': label.observation.confidence,
          'bodyConfidenceThreshold': bodyConfidenceThreshold,
          'identitySource': 'accessibility_active_customer',
        });
      }
    }
    final incomingLabels = messageLabels
        .where((label) => label.direction == 'incoming')
        .toList(growable: false);
    final latestVisibleSenderIsIncoming =
        messageLabels.last.direction == 'incoming';
    final latestIncoming = incomingLabels.lastOrNull;
    final latestIncomingLabel = latestIncoming?.observation;
    final latestIncomingClock = latestIncomingLabel == null
        ? null
        : latestIncoming?.damaged == true
            ? _damagedSenderClock(latestIncomingLabel, inspection, layout)
            : _timestamp.firstMatch(latestIncomingLabel.text)?.group(0) ??
                observations
                    .where((item) =>
                        (item.y - latestIncomingLabel.y).abs() < 0.018 &&
                        item.x > latestIncomingLabel.x &&
                        _timestamp.hasMatch(item.text))
                    .map((item) => _timestamp.firstMatch(item.text)!.group(0))
                    .firstOrNull;
    final latestIncomingSenderKey = latestIncomingClock == null
        ? null
        : '$customerId\u001f$latestIncomingClock';
    final latestIncomingSentAt = _parseTimestamp(
        latestIncomingClock, inspection.capturedAt,
        requireSeconds: true);
    final sender = incomingLabels.isEmpty
        ? messageLabels.last.observation
        : incomingLabels.last.observation;
    final fallbackCopyTarget = OcrCopyTarget(
      x: (sender.x + 0.045).clamp(0.20, 0.63),
      y: (sender.y + 0.040).clamp(0.18, 0.81),
    );

    final capturedMessages = <CapturedMessage>[];
    final identityOccurrences = <String, int>{};
    OcrObservation? latestBodyObservation;
    var latestIncomingHasText = false;
    for (var index = 0; index < messageLabels.length; index++) {
      final label = messageLabels[index];
      final currentSender = label.observation;
      final bottom = index + 1 < messageLabels.length
          ? messageLabels[index + 1].observation.y
          // JD can leave a larger vertical gap before the newest bottom
          // bubble. The next sender safely bounds older messages; the final
          // sender may use the remaining verified chat area above composer.
          : chatBottom;
      final bodies = observations.where((item) {
        if (item.confidence < bodyConfidenceThreshold) return false;
        final text = item.text.trim();
        if (item.y <= currentSender.y + 0.006 || item.y >= bottom) {
          return false;
        }
        final centerX = item.x + item.width / 2;
        final centerY = item.y + item.height / 2;
        if (centerX < chatLeft || centerX >= chatRight) return false;
        // A missing customer clock cannot make a left-side customer bubble
        // part of a right-aligned seller reply. Wide seller text can span
        // the centre; only compact text clearly on the left is excluded.
        if (hasVerifiedChatRegion &&
            label.direction == 'outgoing' &&
            currentSender.x >= (chatLeft + chatRight) / 2 &&
            _clearlyIncomingBody(item, layout)) {
          return false;
        }
        if (label.damaged && item.x >= (chatLeft + chatRight) / 2) return false;
        if (excludedMediaRegions.any((region) =>
            centerX >= region.x &&
            centerX <= region.x + region.width &&
            centerY >= region.y &&
            centerY <= region.y + region.height)) {
          return false;
        }
        final clock = _timestamp.firstMatch(text);
        if (clock != null &&
            clock.start == 0 &&
            clock.end == text.length &&
            (item.y - currentSender.y).abs() < .018) {
          return false;
        }
        return !_isMetadata(text, customerId);
      }).toList()
        ..sort((left, right) {
          final byY = _verticalCenter(left).compareTo(_verticalCenter(right));
          return byY != 0 ? byY : left.x.compareTo(right.x);
        });
      if (bodies.isEmpty) continue;
      final punctuationOutsideMedia = preserveCustomerPunctuation &&
          label.direction == 'incoming' &&
          ![...inspection.visualRegions, ...inspection.unboundMediaRegions].any(
              (r) =>
                  r.width > .025 &&
                  r.height > .065 &&
                  bodies.any((line) =>
                      line.x + line.width / 2 >= r.x &&
                      line.x + line.width / 2 < r.x + r.width &&
                      line.y + line.height / 2 >= r.y &&
                      line.y + line.height / 2 < r.y + r.height));
      final assembled = TranscriptText.clean(_assembleBubbleText(bodies,
          preservePunctuation: punctuationOutsideMedia));
      final body = label.direction == 'incoming'
          ? stripAppendedHoldingReply(assembled)
          : assembled;
      if (body.isEmpty) continue;
      // Only a receipt on this seller bubble proves a formerly uncertain send.
      // It is not required for ordinary reply generation or normal sending.
      final bodyTop =
          bodies.map((item) => item.y).reduce((a, b) => a < b ? a : b);
      final bodyBottom = bodies
          .map((item) => item.y + item.height)
          .reduce((a, b) => a > b ? a : b);
      final bodyLeft =
          bodies.map((item) => item.x).reduce((a, b) => a < b ? a : b);
      final deliveryConfirmed = label.direction == 'outgoing' &&
          observations.any((item) =>
              item.confidence >= 0.8 &&
              (item.text.trim() == '已读' || item.text.trim() == '未读') &&
              item.x + item.width / 2 >= chatLeft &&
              item.x + item.width / 2 < chatRight &&
              item.x + item.width <= bodyLeft + 0.015 &&
              item.y + item.height / 2 >= bodyTop - 0.012 &&
              item.y + item.height / 2 <= bodyBottom + 0.012);
      // The JD transfer summary can be visually merged into the last customer
      // bubble by OCR. It is interface metadata, not a new customer request.
      // The caller handles the transfer separately by sending one welcome.
      if (transferNoticeVisible && _isTransferContextBody(body)) continue;
      var clockDeferred = false;
      var timestamp = label.damaged
          ? _damagedSenderClock(currentSender, inspection, layout)
          : _timestamp.firstMatch(currentSender.text)?.group(0) ??
              observations
                  .where((item) =>
                      (item.y - currentSender.y).abs() < 0.018 &&
                      item.x > currentSender.x &&
                      _timestamp.hasMatch(item.text))
                  .map((item) => item.text.trim())
                  .firstOrNull;
      if (label.direction == 'incoming' &&
          inspection.visualRegions.any((r) =>
              r.y > currentSender.y &&
              r.y + r.height < bodies.first.y &&
              r.height > .08 &&
              r.width > .025 &&
              r.x < chatLeft + (chatRight - chatLeft) * .25)) {
        RuntimeTrace.record('capture.bubble_clock_deferred', {
          'customer': customerId,
          'reason': 'text_after_media_without_distinct_sender_header',
          'borrowedClock': timestamp
        });
        timestamp = null;
        clockDeferred = true;
      }
      final identity = '$customerId\u001f${label.direction}\u001f'
          '${_fingerprintTimestamp(timestamp)}\u001f${_fingerprintText(body)}';
      final occurrence = identityOccurrences
          .update(identity, (value) => value + 1, ifAbsent: () => 0);
      final senderAt = _parseTimestamp(timestamp, inspection.capturedAt,
          requireSeconds: label.direction == 'incoming');
      capturedMessages.add(CapturedMessage(
        stableId: label.direction == 'incoming' && senderAt != null
            ? CustomerMessageTime.incomingId(customerId, senderAt)
            : 'ocr:${sha256.convert(utf8.encode(identity))}'
                '${occurrence == 0 ? '' : ':occurrence:$occurrence'}',
        direction: label.direction,
        body: body,
        deliveryConfirmed: deliveryConfirmed,
        sender: label.direction == 'incoming'
            ? customerId
            : currentSender.text.trim(),
        sentAt: senderAt,
        axPath: 'ocr:active-conversation',
        observationTurnKey:
            'ocr-bubble:${inspection.capturedAt.millisecondsSinceEpoch}:'
            '${sha256.convert(utf8.encode(_fingerprintText(body)))}:'
            '${capturedMessages.where((m) => m.direction == label.direction && _fingerprintText(m.body) == _fingerprintText(body)).length}'
            '${clockDeferred ? ':clock-unresolved-after-media' : ''}',
      ));
      if (label.direction == 'incoming') latestBodyObservation = bodies.first;
      if (label.direction == 'incoming' &&
          identical(currentSender, incomingLabels.last.observation)) {
        latestIncomingHasText = true;
      }
    }
    if (capturedMessages.isEmpty) {
      return OcrExtractionAttempt(
          reason: 'Customer $customerId was identified, but no message '
              'body was recognized beneath the visible sender labels.',
          customerId: customerId,
          copyTarget: fallbackCopyTarget,
          transferNoticeVisible: transferNoticeVisible,
          transferNoticeKey: transferNoticeKey,
          latestVisibleSenderIsIncoming: latestVisibleSenderIsIncoming,
          latestIncomingSenderKey: latestIncomingSenderKey,
          latestIncomingHeader: latestIncomingLabel,
          latestIncomingSentAt: latestIncomingSentAt);
    }
    final latestBody = latestBodyObservation;
    final latestIncomingSender =
        incomingLabels.isEmpty ? null : incomingLabels.last.observation;
    // An image-only customer turn has a sender label but no OCR body. Aim the
    // clipboard classification just below that newest label instead of at an
    // older text body, so JD can confirm that the new bubble is an image.
    final latestIncomingHasNoBody = latestIncomingSender != null &&
        (latestBody == null ||
            latestIncomingSender.y > latestBody.y + latestBody.height + 0.006);
    return OcrExtractionAttempt(
      reason:
          'Extracted ${capturedMessages.length} visible message(s) for $customerId.',
      customerId: customerId,
      copyTarget: latestIncomingHasNoBody
          ? fallbackCopyTarget
          : latestBody == null
              ? null
              : OcrCopyTarget(
                  x: (latestBody.x + latestBody.width / 2).clamp(0.20, 0.63),
                  y: (latestBody.y + latestBody.height / 2).clamp(0.18, 0.81),
                ),
      capture: CapturedConversation(
        stableKey: 'customer:${sha256.convert(utf8.encode(customerId))}',
        customerName: customerId,
        customerExternalId: customerId,
        capturedAt: inspection.capturedAt,
        messages: capturedMessages,
      ),
      transferNoticeVisible: transferNoticeVisible,
      transferNoticeKey: transferNoticeKey,
      latestIncomingHasText: latestIncomingHasText,
      latestVisibleSenderIsIncoming: latestVisibleSenderIsIncoming,
      latestIncomingSenderKey: latestIncomingSenderKey,
      latestIncomingHeader: latestIncomingLabel,
      latestIncomingSentAt: latestIncomingSentAt,
    );
  }

  String _assembleBubbleText(List<OcrObservation> observations,
      {bool preservePunctuation = false}) {
    final lines = <List<OcrObservation>>[];
    for (final observation in observations) {
      final center = _verticalCenter(observation);
      List<OcrObservation>? matchingLine;
      for (final line in lines.reversed) {
        final lineCenter =
            line.map(_verticalCenter).reduce((left, right) => left + right) /
                line.length;
        final tolerance = <double>[
          0.010,
          observation.height * 0.55,
          ...line.map((item) => item.height * 0.55),
        ].reduce((left, right) => left > right ? left : right);
        if ((center - lineCenter).abs() <= tolerance) {
          matchingLine = line;
          break;
        }
        if (center > lineCenter + 0.035) break;
      }
      (matchingLine ?? (lines..add(<OcrObservation>[])).last).add(observation);
    }

    lines.sort((left, right) =>
        _verticalCenter(left.first).compareTo(_verticalCenter(right.first)));
    final textLines = <String>[];
    for (final line in lines) {
      line.sort((left, right) => left.x.compareTo(right.x));
      // The sender labels and verified chat-area cutoff already bound this
      // message. Never stop on vertical gaps: OCR may return words or
      // wrapped fragments with unexpectedly separated boxes, and every box
      // inside the sender-bounded region belongs to the same visible turn.
      final text = line.map((item) => item.text.trim()).join(' ').trim();
      if (text.isNotEmpty) textLines.add(text);
    }
    final combined = textLines.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    // Apple Vision occasionally emits a standalone uppercase `D` at the end
    // of a JD bubble, sometimes followed by a misread image/control glyph such
    // as `回`. Keep model suffixes such as `M880D`: only a whitespace-bounded
    // standalone D at the end is an artifact.
    final cleaned = combined
        // Qianniu renders this fixed composer shortcut below the conversation.
        // Vision can merge it into the newest bubble when both share one
        // sender-bounded region. Remove the complete UI hint after OCR while
        // preserving any customer text that precedes it.
        .replaceAll(
            RegExp(
                r'(?:[◎◉○口回□▣]\s*)?(?:按住\s*)?Shift\s*[+＋]\s*Space\s*可\s*快速\s*选中\s*输入框',
                caseSensitive: false),
            '')
        .replaceFirstMapped(
            RegExp(r'(^|[\s，。！？；：,.!?;:])D(?:\s*[◎◉○口回□▣])*\s*$'),
            (match) => match.group(1)?.trim() ?? '')
        // `C30` is a recurring JD/Apple Vision control artifact. It is never
        // customer content in this integration, so remove every occurrence,
        // including a control glyph Vision may append to it.
        .replaceAll(RegExp(r'C30(?:\s*[◎◉○口回□▣])?', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(RegExp(r'([\u3400-\u9fff])\s+([\u3400-\u9fff])'),
            (match) => '${match.group(1)}${match.group(2)}')
        .trim();
    if (preservePunctuation &&
        RegExp(r'^[?？!！。.,，…、:：;；]+$').hasMatch(cleaned)) {
      return cleaned;
    }
    // JD image thumbnails and adjacent status controls are sometimes read as
    // tiny strings such as `◎ 回`, `g 回`, or `•`. These contain no customer
    // language and must leave the newest turn image-only.
    if (RegExp(r'^(?:[gG]\s*)?[◎◉○口回□▣•·.\s]+$').hasMatch(cleaned)) {
      return '';
    }
    // A video play overlay is sometimes recognized as a tiny mixture of
    // Japanese kana, punctuation, and one JD control glyph (for example
    // `の ¿ 回`). It is not a customer text message. Do not let it close the
    // unread recovery before the video itself has been captured.
    final readableCharacters =
        RegExp(r'[A-Za-z0-9\u3400-\u9fff]').allMatches(cleaned).length;
    if (readableCharacters <= 1 &&
        RegExp(r'[◎◉○口回□▣•·¿の]').hasMatch(cleaned) &&
        RegExp(r'[¿の◎◉○□▣•·]').hasMatch(cleaned)) {
      return '';
    }
    return TranscriptText.clean(cleaned);
  }

  double _verticalCenter(OcrObservation observation) =>
      observation.y + observation.height / 2;

  String? _transferNoticeKey(
      List<OcrObservation> observations, String? customerId) {
    final customerPrefix = customerId?.substring(
        0, customerId.length < 10 ? customerId.length : 10);
    for (final observation in observations) {
      final nearby = observations
          .where((item) =>
              (item.y - observation.y).abs() <= 0.10 &&
              item.x + item.width / 2 >= 0.15 &&
              item.x + item.width / 2 <= 0.85)
          .toList()
        ..sort((left, right) {
          final vertical = left.y.compareTo(right.y);
          return vertical != 0 ? vertical : left.x.compareTo(right.x);
        });
      final compact =
          nearby.map((item) => item.text.replaceAll(RegExp(r'\s+'), '')).join();
      final colleagueTransfer = RegExp(r'(您的)?同事.+将客户').hasMatch(compact);
      final jdTransferSummary = RegExp(r'用户诉求[:：]?(?:要求|催促)?转接')
          .hasMatch(observation.text.replaceAll(RegExp(r'\s+'), ''));
      if (!colleagueTransfer && !jdTransferSummary) continue;
      if (!jdTransferSummary &&
          customerPrefix != null &&
          !compact.contains(customerPrefix)) {
        continue;
      }
      final verticalBucket = (observation.y * 1000).round();
      final identity = '$customerId\u001f$verticalBucket\u001f$compact';
      return sha256.convert(utf8.encode(identity)).toString();
    }
    return null;
  }

  bool _sameIdentity(String value, String customerId) {
    final full = customerId.trim().toLowerCase();
    final raw = value.trim().toLowerCase();
    if (raw == full) return true;
    // Vision sometimes merges the sender and timestamp into one observation,
    // for example "stoneshishininger 2026-08-26 11:03:13".
    if (raw.startsWith(full)) {
      final suffix = raw.substring(full.length).trim();
      if (suffix.isEmpty || _timestamp.hasMatch(suffix)) return true;
    }
    final visiblePrefix = raw
        .replaceAll('...', '')
        .replaceAll('…', '')
        .replaceAll(RegExp(r'\s+'), '');
    // Qianniu truncates sender labels. A long visible prefix is accepted only
    // after AX has supplied the exact active customer identity.
    return visiblePrefix.length >= 6 && full.startsWith(visiblePrefix);
  }

  bool _isMetadata(String value, String customerId) {
    final lower = value.toLowerCase();
    return TranscriptText.clean(value).isEmpty ||
        _isSellerIdentity(value) ||
        RegExp(r'^(?:你|您)已将客户成功转(?:接)?给其他同事[！!。.]?$')
            .hasMatch(value.replaceAll(RegExp(r'\s+'), '')) ||
        _sameIdentity(value, customerId) ||
        // Sidebar previews are excluded geometrically. Ellipses in a real
        // bubble are customer punctuation, not a reason to delete its text.
        RegExp(r'(您的)?同事.*将客户')
            .hasMatch(value.replaceAll(RegExp(r'\s+'), '')) ||
        value.contains('转接给您') ||
        value.contains('上次会话小结') ||
        RegExp(r'用户诉求[:：]?.*转接').hasMatch(value) ||
        RegExp(r'^(商品sku|咨询轨迹|客服方案|承诺项)[:：]').hasMatch(value.trim()) ||
        _sidebarRecency.hasMatch(value.trim()) ||
        lower == '已读' ||
        lower == '未读' ||
        lower == '新消息' ||
        lower == '加普威旗舰店' ||
        lower == '客服' ||
        lower == '营销';
  }

  bool _isTransferContextBody(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'(?:请你)?转给子账号|转接给您|上次会话小结|用户诉求[:：]?.*转接').hasMatch(compact);
  }

  bool _isSellerIdentity(String value) {
    final text = value.trim();
    if (text.contains('旗舰店') && (text.contains(':') || text.contains('：'))) {
      return true;
    }
    // Current JD builds display the signed-in support identity as names such
    // as "格志打印机小甘", often with the timestamp merged into the same Vision
    // observation. These are seller labels, not customer message bodies.
    final withoutTimestamp = text
        .replaceAll(_timestamp, '')
        .replaceAll('其他客服', '')
        .replaceAll(RegExp(r'Groz+ii?e', caseSensitive: false), '')
        .trim();
    return RegExp(r'^格志打印机小[\u3400-\u9fffA-Za-z0-9_-]{0,8}$')
        .hasMatch(withoutTimestamp);
  }

  String _fingerprintText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'''[.,!?;:'"`~，。！？；：“”‘’（）()\[\]{}、]'''), '');

  String _fingerprintTimestamp(String? value) {
    if (value == null) return '-';
    return RegExp(r'\d+')
        .allMatches(value)
        .map((match) => int.parse(match.group(0)!))
        .join(':');
  }

  DateTime? _parseTimestamp(String? value, DateTime capturedAt,
      {bool requireSeconds = false}) {
    if (value == null) return null;
    if (requireSeconds &&
        !RegExp(r'\d{1,2}[:：]\d{2}[:：]\d{2}').hasMatch(value)) {
      return null;
    }
    final text = _timestamp.firstMatch(value)?.group(0);
    if (text == null) return null;
    // JD displays chat clocks in China Standard Time, regardless of the
    // operator Mac's timezone. A clock-only label must be interpreted against
    // the JD calendar day, not DateTime.toLocal() on this machine.
    const jdOffset = Duration(hours: 8);
    final capturedUtc = capturedAt.toUtc();
    final jdCapture = capturedUtc.add(jdOffset);
    final dated = _datedTimestamp.firstMatch(text);
    final clock = _clockTimestamp.firstMatch(text);
    if (dated == null && clock == null) return null;
    if (requireSeconds && (dated?.group(6) ?? clock?.group(3)) == null) {
      return null;
    }
    var year =
        dated?.group(1) == null ? jdCapture.year : int.parse(dated!.group(1)!);
    final month = dated == null ? jdCapture.month : int.parse(dated.group(2)!);
    final day = dated == null ? jdCapture.day : int.parse(dated.group(3)!);
    final hour = int.parse(dated?.group(4) ?? clock!.group(1)!);
    final minute = int.parse(dated?.group(5) ?? clock!.group(2)!);
    final second = int.parse(dated?.group(6) ?? clock?.group(3) ?? '0');
    DateTime? onDate(int y) {
      final result = DateTime.utc(y, month, day, hour, minute, second);
      // DateTime normalizes invalid dates; invalid OCR is unknown evidence.
      if (result.year != y ||
          result.month != month ||
          result.day != day ||
          result.hour != hour ||
          result.minute != minute ||
          result.second != second) {
        return null;
      }
      return result.subtract(jdOffset);
    }

    var result = onDate(year);
    if (result == null) return null;
    if (dated == null) {
      // A scan just after midnight can still show a message from yesterday.
      if (result.difference(capturedUtc) > const Duration(minutes: 1)) {
        result = result.subtract(const Duration(days: 1));
      }
    } else if (result.difference(capturedUtc) > const Duration(minutes: 1)) {
      // A yearless December label on a January page belongs to last year.
      // A nearby future date is ambiguous; never relabel it as yesterday or
      // silently roll it back an entire year.
      if (dated.group(1) != null ||
          result.difference(capturedUtc) <= const Duration(days: 180)) {
        return null;
      }
      year -= 1;
      result = onDate(year);
      if (result == null ||
          result.difference(capturedUtc) > const Duration(minutes: 1)) {
        return null;
      }
    }
    return result;
  }

  static final _timestamp = RegExp(
      r'(?<![0-9])(?:(?:20\d{2}[-/.])?\d{1,2}[-/.]\d{1,2}\s+)?(?:[01]?\d|2[0-3])[:：][0-5]\d(?:[:：][0-5]\d)?(?![0-9])');
  static final _datedTimestamp = RegExp(
      r'^(?:(20\d{2})[-/.])?(\d{1,2})[-/.](\d{1,2})\s+(\d{1,2})[:：](\d{2})(?:[:：](\d{2}))?$');
  static final _clockTimestamp =
      RegExp(r'^(\d{1,2})[:：](\d{2})(?:[:：](\d{2}))?$');
  static final _sidebarRecency = RegExp(
      r'^\d+\s*(?:秒|分钟|分|小时|天|second|seconds|min|mins)$',
      caseSensitive: false);
}

class _MessageLabel {
  const _MessageLabel(
      {required this.observation,
      required this.direction,
      this.damaged = false});

  final OcrObservation observation;
  final String direction;
  final bool damaged;
}

class TextFirstRegistrationPlan {
  const TextFirstRegistrationPlan(this.independentText, this.reasons);
  final CapturedConversation? independentText;
  final Set<String> reasons;
  bool get needsFullRecognition => reasons.isNotEmpty;
}

class OcrExtractionAttempt {
  const OcrExtractionAttempt({
    required this.reason,
    this.capture,
    this.customerId,
    this.copyTarget,
    this.transferNoticeVisible = false,
    this.transferNoticeKey,
    this.latestIncomingHasText = false,
    this.latestVisibleSenderIsIncoming = false,
    this.latestIncomingSenderKey,
    this.latestIncomingSentAt,
    this.latestIncomingHeader,
  });

  final String reason;
  final CapturedConversation? capture;
  final String? customerId;
  final OcrCopyTarget? copyTarget;
  final bool transferNoticeVisible;
  final String? transferNoticeKey;
  final bool latestIncomingHasText;
  final bool latestVisibleSenderIsIncoming;

  /// Stable across scans even when a media-only bubble has no OCR body.
  final String? latestIncomingSenderKey;
  final DateTime? latestIncomingSentAt;
  final OcrObservation? latestIncomingHeader;
}

class OcrIncomingMessageBlock {
  const OcrIncomingMessageBlock(
      {required this.header,
      required this.region,
      required this.sentAt,
      required this.ordinal,
      this.bodyHints = const []});
  final OcrObservation header;
  final OcrVisualRegion region;
  final DateTime sentAt;
  final int ordinal;
  final List<OcrObservation> bodyHints;

  /// Native short-text OCR limits each immutable tile to .2 by .1.
  /// Tiles are decoding attempts for this one block, never new messages.
  List<OcrVisualRegion> get textRecoveryRegions {
    OcrVisualRegion hintRegion(OcrObservation hint, {required bool stable}) {
      double coordinate(double value) =>
          stable ? (value * 1000).round() / 1000 : value;
      final x = math.max(region.x, coordinate(hint.x - .004));
      final y = math.max(region.y, coordinate(hint.y - .004));
      final width = math.min(math.min(.2, coordinate(hint.width + .012)),
          region.x + region.width - x);
      final height = math.min(math.min(.1, coordinate(hint.height + .012)),
          region.y + region.height - y);
      return OcrVisualRegion(
          x: x,
          y: y,
          width: math.max(.001, width),
          height: math.max(.001, height),
          confidence: hint.confidence);
    }

    final result = <OcrVisualRegion>[
      // Native pixel crops must not jitter when OCR boxes vary below a pixel.
      // The stable crop stays inside the same immutable block and retains the
      // original exact hint as a later fallback, with unchanged OCR budgets.
      for (final hint in bodyHints) hintRegion(hint, stable: true),
      for (final hint in bodyHints) hintRegion(hint, stable: false),
      OcrVisualRegion(
          x: math.max(region.x, header.x),
          y: region.y,
          width: math.min(.06, region.width),
          height: math.min(.065, region.height),
          confidence: 0),
    ];
    for (var y = region.y; y < region.y + region.height - .002; y += .09) {
      for (var x = region.x; x < region.x + region.width - .002; x += .19) {
        result.add(OcrVisualRegion(
            x: x,
            y: y,
            width: math.min(.2, region.x + region.width - x),
            height: math.min(.1, region.y + region.height - y),
            confidence: 0));
      }
    }
    return result;
  }
}

class OcrMediaClockEvidence {
  const OcrMediaClockEvidence({
    required this.source,
    this.sentAt,
    this.headerTop,
    this.headerBottom,
    this.confidence = 0,
  });
  final DateTime? sentAt;
  final String source;
  final double? headerTop, headerBottom;
  final double confidence;
}

class OcrCopyTarget {
  const OcrCopyTarget({required this.x, required this.y});
  final double x;
  final double y;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
