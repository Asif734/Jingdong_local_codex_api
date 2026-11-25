import '../domain/customer_message_time.dart';
import '../domain/capture_models.dart';
import '../codex/holding_replies.dart';
import '../platform/macos_capture_adapter.dart';
import 'ocr_capture_extractor.dart';
import 'viewport_evidence.dart';
import 'unknown_message_clarifier.dart';
import 'incoming_message_ownership.dart';
import 'ocr_chat_layout.dart';

/// A historical viewport must show a known message, not merely a later OCR
/// clock. Match its whole typed body within its own sender block. The frozen
/// list can include an already confirmed outgoing reply below a video whose
/// incoming sender header has scrolled offscreen.
double? _visibleTextAnchorBottom(
    OcrInspection view, String customer, Map? frontier) {
  if (frontier == null) return null;
  String compact(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final clock = RegExp(r'\d{1,2}[:：]\d{2}[:：]\d{2}');
  bool customerHeader(OcrObservation line) =>
      compact(line.text).startsWith(compact(customer));
  bool sellerHeader(OcrObservation line) =>
      !customerHeader(line) && RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(line.text);
  bool inside(OcrObservation line) =>
      line.x >= (view.chatLeft ?? .24) &&
      line.x < (view.chatRight ?? .75) &&
      line.y >= (view.chatTop ?? .2) &&
      line.y < (view.chatBottom ?? .81);
  final headers = view.observations
      .where((line) =>
          inside(line) &&
          line.confidence >= .45 &&
          clock.hasMatch(line.text) &&
          (customerHeader(line) || sellerHeader(line)))
      .toList()
    ..sort((a, b) => a.y.compareTo(b.y));
  final anchors = <Map>[
    frontier,
    ...(frontier['visibleTextAnchors'] as List? ?? const []).whereType<Map>(),
  ];
  double? bottom;
  for (final anchor in anchors) {
    final body = compact(anchor['body']?.toString() ?? '');
    final at = DateTime.tryParse(anchor['sent_at']?.toString() ?? '');
    if (body.isEmpty ||
        at == null ||
        !const {'incoming', 'outgoing'}.contains(anchor['direction'])) {
      continue;
    }
    final jd = at.toUtc().add(const Duration(hours: 8));
    final matches = <double>[];
    for (var i = 0; i < headers.length; i++) {
      final header = headers[i];
      if ((anchor['direction'] == 'incoming') != customerHeader(header)) {
        continue;
      }
      final parts = clock
          .firstMatch(header.text)!
          .group(0)!
          .replaceAll('：', ':')
          .split(':')
          .map(int.parse)
          .toList();
      if (parts[0] != jd.hour ||
          parts[1] != jd.minute ||
          parts[2] != jd.second) {
        continue;
      }
      final end =
          i + 1 < headers.length ? headers[i + 1].y : view.chatBottom ?? .81;
      final lines = view.observations
          .where((line) =>
              inside(line) &&
              line.confidence >= .45 &&
              line.y >= header.y + header.height - .002 &&
              line.y + line.height / 2 < end &&
              compact(line.text).isNotEmpty &&
              body.contains(compact(line.text)))
          .toList()
        ..sort((a, b) => a.y.compareTo(b.y));
      if (lines.isNotEmpty &&
          compact(lines.map((line) => line.text).join()) == body) {
        matches.add(lines.last.y + lines.last.height);
      }
    }
    if (matches.length == 1 && (bottom == null || matches.single > bottom)) {
      bottom = matches.single;
    }
  }
  return bottom;
}

/// Complete sender seconds in this run identify new duties independently of
/// OCR completion order. Physical frontier proof is only for unreadable clocks.
class LiveMediaArrival {
  static DateTime? _sessionBoundary(ViewportEvidence evidence,
      [DateTime? sessionStartedAt]) {
    final frozen = evidence.metadata['automationSessionStartedAtMs'];
    return frozen is num
        ? DateTime.fromMillisecondsSinceEpoch(frozen.toInt(), isUtc: true)
        : sessionStartedAt;
  }

  /// A saved frame's fixed run boundary authorizes its complete sender time.
  /// The latest registered message is not a cutoff: older OCR can finish later.
  static bool admitsCurrentTimestamp({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required DateTime senderAt,
    DateTime? sessionStartedAt,
  }) {
    final boundary = _sessionBoundary(evidence, sessionStartedAt);
    final session = evidence.metadata['automationSessionId'];
    if (inspection.activeCustomerId != evidence.customer ||
        evidence.metadata['replyActivationAllowed'] != true ||
        session is! String ||
        session.isEmpty ||
        boundary == null ||
        evidence.capturedAt.isBefore(boundary) ||
        evidence.metadata['acquisitionOnly'] == true ||
        const {'discovery_baseline', 'history_only', 'arrival_observation'}
            .contains(evidence.metadata['capturePurpose'])) {
      return false;
    }
    final second = CustomerMessageTime.second(senderAt);
    return !second.isBefore(CustomerMessageTime.second(boundary)) &&
        !second.isAfter(evidence.capturedAt.add(const Duration(seconds: 1)));
  }

  /// Only a complete clock before Start is evidence of pre-existing history.
  /// An unreadable clock is observational, never an "old message" flag.
  static bool isBeforeSessionStart(
      ViewportEvidence evidence, DateTime? senderAt) {
    final boundary = _sessionBoundary(evidence);
    return senderAt != null &&
        boundary != null &&
        CustomerMessageTime.second(senderAt)
            .isBefore(CustomerMessageTime.second(boundary));
  }

  static bool _firstVerifiedLiveFrame(
          ViewportEvidence evidence, Map? frontier) =>
      evidence.metadata['verifiedLiveBottom'] == true &&
      evidence.metadata['discoveryAnchorId'] == evidence.id &&
      evidence.metadata['capturePurpose'] == 'live_signal' &&
      evidence.metadata['navigationCutoffSource'] == 'current_viewport' &&
      evidence.metadata['historyCutoffMs'] == null &&
      evidence.metadata['captureRequestedBackfill'] != true &&
      evidence.metadata['acquisitionOnly'] != true &&
      (frontier == null || frontier['empty'] == true);

  static bool _historyDivider(OcrInspection inspection,
          {double? after, double? before}) =>
      inspection.observations.any((line) =>
          !line.isWatermark &&
          line.confidence >= .25 &&
          OcrChatLayout(inspection).inTranscript(line) &&
          (after == null || line.y > after) &&
          (before == null || line.y < before) &&
          RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(line.text));

  /// A card can be physically new before its sender label or media type is
  /// readable. This is only deferred provenance, never admission permission.
  /// Audit must prove a later representation is this very card before using
  /// the original source frame to claim one business owner.
  static Map<OcrVisualRegion, Map<String, Object?>> deferredCandidates({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required Iterable<OcrVisualRegion> cards,
    required Map<OcrVisualRegion, String> knownParents,
    required String sessionId,
    required DateTime sessionStartedAt,
    Map? frontier,
  }) {
    final arrival = evidence.metadata['unreadArrivalKey'];
    if (inspection.activeCustomerId != evidence.customer ||
        evidence.metadata['automationSessionId'] != sessionId ||
        evidence.metadata['replyActivationAllowed'] != true ||
        evidence.capturedAt.isBefore(sessionStartedAt) ||
        arrival is! String ||
        arrival.isEmpty ||
        evidence.metadata['historyCutoffMs'] != null ||
        evidence.metadata['captureRequestedBackfill'] == true ||
        evidence.metadata['acquisitionOnly'] == true ||
        const {'history_only', 'history_backfill', 'discovery_baseline'}
            .contains(evidence.metadata['capturePurpose'])) {
      return {};
    }
    final layout = OcrChatLayout(inspection);
    final physical = cards
        .where((card) =>
            layout.allowedMedia(card) &&
            card.width >= .025 &&
            card.height >= .04)
        .toList(growable: false);
    final first = _firstVerifiedLiveFrame(evidence, frontier) &&
        physical.length == 1 &&
        !_historyDivider(inspection) &&
        !const OcrCaptureExtractor()
            .incomingMessageBlocks(inspection, excludedMediaRegions: physical)
            .any((block) => block.header.y > physical.single.y + .01);
    if (!first && (frontier == null || frontier['id'] is! String)) return {};
    final frontierIds = <String>{
      if (frontier?['id'] is String) frontier!['id']! as String,
      ...(frontier?['observed_ids'] as List? ?? const []).whereType<String>()
    };
    double? bottom;
    for (final entry in knownParents.entries) {
      if (frontierIds.contains(entry.value)) {
        final value = entry.key.y + entry.key.height;
        if (bottom == null || value > bottom) bottom = value;
      }
    }
    // Only the actual frozen frontier qualifies here. An older visible text
    // anchor cannot authorize a card whose true frontier is already offscreen.
    if (frontier != null) {
      bottom ??= _visibleTextAnchorBottom(inspection, evidence.customer, {
        for (final key in ['id', 'body', 'direction', 'sent_at'])
          if (frontier.containsKey(key)) key: frontier[key]
      });
    }
    if (bottom == null && !first) return {};
    final frontierBottom = bottom;
    return {
      for (final card in physical)
        if (!knownParents.containsKey(card) &&
            (first || card.y > frontierBottom! + .002) &&
            !inspection.observations.any((line) =>
                !line.isWatermark &&
                line.confidence >= .25 &&
                layout.inTranscript(line) &&
                line.y > (frontierBottom ?? layout.top) &&
                line.y < card.y &&
                RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(line.text)))
          card: {
            'version': 1,
            'kind': 'deferred_current_card',
            'sessionId': sessionId,
            'customer': evidence.customer,
            'evidenceId': evidence.id,
            'capturedAt': evidence.capturedAt.toUtc().toIso8601String(),
            'region': [card.x, card.y, card.width, card.height],
            'unreadArrivalKey': arrival,
            'frontier': frontier == null
                ? null
                : {
                    for (final key in [
                      'id',
                      'observed_ids',
                      'sent_at',
                      'body',
                      'direction'
                    ])
                      if (frontier.containsKey(key)) key: frontier[key]
                  },
            'frontierBottom': frontierBottom,
            'firstVerifiedLiveFrame': first,
            'admissionGranted': false,
          }
    };
  }

  static Set<String> textInputs({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required Iterable<CapturedMessage> messages,
    required Set<String> existingIds,
    Map<OcrVisualRegion, String> knownMediaParents = const {},
    Map? frontier,
  }) {
    if (inspection.activeCustomerId != evidence.customer) return {};
    final incoming = messages.where((m) =>
        m.direction == 'incoming' &&
        m.media.isEmpty &&
        m.mediaReceiptId == null);
    final result = <String>{
      for (final message in incoming)
        if (existingIds.contains(message.stableId)) message.stableId,
    };
    if (evidence.metadata['replyActivationAllowed'] != true) {
      return result;
    }
    final history = evidence.metadata['historyCutoffMs'] != null;
    String compact(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final blocks = {
      for (final block
          in IncomingTextBlock.locate(inspection, evidence.customer, messages))
        block.message.stableId: block.lines,
    };
    List<OcrObservation> bodyLines(CapturedMessage message) {
      if (blocks[message.stableId] case final lines?) return lines;
      if (history) return [];
      final body = compact(message.body);
      return inspection.observations
          .where((line) =>
              line.x >= (inspection.chatLeft ?? .24) &&
              line.x < (inspection.chatRight ?? .75) &&
              compact(line.text).isNotEmpty &&
              body.contains(compact(line.text)))
          .toList();
    }

    // OCR of T2 may commit before T1. Every complete, current-run sender
    // second is registered on its own; T2's frontier cannot veto T1 above it.
    for (final message in incoming) {
      if (message.sentAt != null &&
          admitsCurrentTimestamp(
              evidence: evidence,
              inspection: inspection,
              senderAt: message.sentAt!) &&
          bodyLines(message).isNotEmpty) {
        result.add(message.stableId);
      }
    }
    return result;
  }

  static Map<OcrVisualRegion, String> infer({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required Iterable<OcrVisualRegion> cards,
    required Map<OcrVisualRegion, OcrMediaClockEvidence> headers,
    required Map<OcrVisualRegion, String> knownParents,
    required Iterable<CapturedMessage> visibleText,
    Map? frontier,
    DateTime? sessionStartedAt,
  }) {
    if (evidence.metadata['replyActivationAllowed'] != true ||
        inspection.activeCustomerId != evidence.customer) {
      return {};
    }
    final arrival = evidence.metadata['unreadArrivalKey'] as String?;
    final boundary = _sessionBoundary(evidence, sessionStartedAt);
    final timedArrivals = <OcrVisualRegion, String>{
      if (boundary != null)
        for (final card in cards)
          if (!knownParents.containsKey(card) &&
              headers[card]?.source == 'ocr_media_sender_header' &&
              (headers[card]?.confidence ?? 0) >= .45 &&
              headers[card]?.sentAt != null &&
              admitsCurrentTimestamp(
                  evidence: evidence,
                  inspection: inspection,
                  senderAt: headers[card]!.sentAt!,
                  sessionStartedAt: sessionStartedAt))
            card: CustomerMessageTime.occurrenceKey(
                evidence.customer, headers[card]!.sentAt!),
    };
    final history = evidence.metadata['historyCutoffMs'] != null;
    if (history &&
        (arrival == null || frontier == null || frontier['empty'] == true)) {
      return timedArrivals;
    }
    final frontierId = frontier?['id'] as String?;
    final emptyBaseline = frontier?['empty'] == true;
    final frontierAt =
        DateTime.tryParse(frontier?['sent_at']?.toString() ?? '');
    double? frontierBottom;
    if (frontierId != null) {
      final keys = <String>{
        frontierId,
        ...(frontier?['observed_ids'] as List? ?? const []).whereType<String>(),
      };
      for (final entry in knownParents.entries) {
        if (keys.contains(entry.value)) {
          frontierBottom = entry.key.y + entry.key.height;
        }
      }
      String compact(String value) =>
          value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      for (final text
          in visibleText.where((m) => !history && keys.contains(m.stableId))) {
        final body = compact(text.body);
        for (final line in inspection.observations) {
          final part = compact(line.text);
          if (part.length >= 3 &&
              body.contains(part) &&
              line.x >= (inspection.chatLeft ?? .24) &&
              line.x < (inspection.chatRight ?? .75)) {
            final bottom = line.y + line.height;
            if (frontierBottom == null || bottom > frontierBottom) {
              frontierBottom = bottom;
            }
          }
        }
      }
    }
    if (history) {
      final anchor =
          _visibleTextAnchorBottom(inspection, evidence.customer, frontier);
      if (anchor != null &&
          (frontierBottom == null || anchor > frontierBottom)) {
        frontierBottom = anchor;
      }
      if (frontierBottom == null) return timedArrivals;
    }
    // A verified AX arrival can establish a first current sender block when
    // the previous frontier is offscreen. Initial live ownership is admitted
    // once, after exact customer selection and a guarded restore to bottom.
    if (frontierBottom == null && arrival == null && !emptyBaseline) {
      return timedArrivals;
    }
    final clock = RegExp(r'\d{1,2}[:：]\d{2}[:：]\d{2}');
    var lastSeller = inspection.chatTop ?? .2;
    for (final line in inspection.observations) {
      final holdingHeader = visibleText.any((message) =>
          message.direction == 'outgoing' &&
          isHoldingReply(message.body) &&
          message.sender?.replaceAll(RegExp(r'\s+'), '') ==
              line.text.replaceAll(RegExp(r'\s+'), ''));
      if (line.x >= (inspection.chatLeft ?? .24) &&
          line.x < (inspection.chatRight ?? .75) &&
          line.y >= lastSeller &&
          line.y < (inspection.chatBottom ?? .81) &&
          clock.hasMatch(line.text) &&
          !line.text.contains(evidence.customer) &&
          !holdingHeader &&
          RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(line.text)) {
        lastSeller = line.y + line.height;
      }
    }
    final physicalCards = cards.toList(growable: false);
    final incoming = physicalCards.where((card) {
      final header = headers[card];
      // A complete clock has already been decided by the fixed run boundary.
      // Old geometry/ordinal admission must not override that decision.
      if (header?.source == 'ocr_media_sender_header' &&
          header?.sentAt != null) {
        return false;
      }
      final ownership = IncomingMessageOwnership.inspect(
          inspection, evidence.customer, card,
          physicalCards: physicalCards);
      final contentTop = ownership?.uniquePhysicalCard == true
          ? ownership!.mediaContentRegion.y
          : card.y;
      final weakCurrentBlock =
          header?.source == 'visual_incoming_sender_block' &&
              ownership?.uniquePhysicalCard == true &&
              ownership?.exactCustomerHeader == false &&
              !history &&
              sessionStartedAt != null &&
              !evidence.capturedAt.isBefore(sessionStartedAt) &&
              evidence.metadata['automationSessionId'] is String;
      final firstWeakPhysicalBlock = weakCurrentBlock &&
          arrival != null &&
          arrival.isNotEmpty &&
          _firstVerifiedLiveFrame(evidence, frontier) &&
          ownership!.latestIncomingBlock &&
          !_historyDivider(inspection);
      final physicalBlockAfterFrontier = weakCurrentBlock &&
          frontierBottom != null &&
          ownership!.bodyRegion.y > frontierBottom + .002 &&
          !_historyDivider(inspection,
              after: frontierBottom, before: ownership.header.y);
      final orderedAfterOffscreenFrontier = frontier == null ||
          emptyBaseline ||
          (arrival != null &&
              frontierAt != null &&
              header?.sentAt?.isAfter(frontierAt) == true);
      // Existing AX/frontier admission can include an unanswered red-marked
      // message already present at Start. Only the new recovery above a later
      // seller greeting needs proof that this duty arrived in the current run.
      final beforeLaterSellerInThisRun = !history &&
          arrival != null &&
          sessionStartedAt != null &&
          !evidence.capturedAt.isBefore(sessionStartedAt) &&
          header?.sentAt?.isBefore(sessionStartedAt) == false;
      return !knownParents.containsKey(card) &&
          (header?.source == 'ocr_media_sender_header' ||
              physicalBlockAfterFrontier ||
              firstWeakPhysicalBlock) &&
          header?.headerBottom != null &&
          header!.headerBottom! <= contentTop + .01 &&
          (frontierBottom != null ||
              card.y > lastSeller ||
              beforeLaterSellerInThisRun ||
              firstWeakPhysicalBlock) &&
          (frontierBottom == null
              ? orderedAfterOffscreenFrontier
              : contentTop > frontierBottom + .002);
    }).toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final anchor = frontierBottom != null || emptyBaseline
        ? 'frontier:$frontierId'
        : arrival!;
    return {
      ...timedArrivals,
      for (var ordinal = 0; ordinal < incoming.length; ordinal++)
        incoming[ordinal]: headers[incoming[ordinal]]?.sentAt == null
            ? '$anchor:incoming-media:$ordinal'
            : CustomerMessageTime.occurrenceKey(
                evidence.customer, headers[incoming[ordinal]]!.sentAt!),
    };
  }
}
