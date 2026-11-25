import 'transcript_text.dart';

/// Target a physical reply click by the configured response window of the sidebar red clock.
/// Native identity/composer checks start early enough to finish by that target.
class ResponseTimingPolicy {
  static const responseTarget = Duration(seconds: 50);
  // Begin the shared UI transaction before the target. Native may prepare
  // the composer but cannot click a holding reply before the original dueAt.
  static const dispatchLead = Duration(seconds: 2);
  static const preparationLead = Duration(seconds: 6);
  static Duration preparationDelay(Duration remaining) =>
      remaining > preparationLead ? remaining - preparationLead : Duration.zero;
  static const holdingDispatchAfter = Duration(seconds: 50);

  /// An unattributed OCR bubble is not proof that this customer's SLA was met.
  static bool isConfirmedReplyForSla(Map<String, dynamic> message,
          {required bool isHolding}) =>
      message['direction'] == 'outgoing' &&
      message['source'] != 'sla_fallback' &&
      !TranscriptText.hasDeliveryRejection(message['body']?.toString() ?? '') &&
      !const {
        'ownership_unverified',
        'unverified_observation',
        'delivery_unknown',
        'rejected',
        'not_sent'
      }.contains(message['delivery_status']) &&
      !isHolding;

  /// Wall-clock order is not proof: an older batch may finish after a new
  /// customer message. Only the delivery's bound batch can satisfy this job.
  static bool isReplyForBatch(Map<String, dynamic> message,
          {required String batchEndMessageId, required bool isHolding}) =>
      isConfirmedReplyForSla(message, isHolding: isHolding) &&
      message['answered_batch_end_id'] == batchEndMessageId;

  static bool isSocialAcknowledgement(String text) => RegExp(
          r'^(?:好|好的|行|明白|嗯|谢谢|可以了谢谢|好了谢谢|hi|hello|ok|okay|thanks|thank you)[\s,.，。!！]*$',
          caseSensitive: false)
      .hasMatch(text.trim());

  static bool isTrivialAcknowledgement(String reply) {
    if (reply.length > 140 ||
        RegExp(r'[?？0-9]|自检|按住|断电|排查|清理|关机|型号|USB|Bluetooth',
                caseSensitive: false)
            .hasMatch(reply)) {
      return false;
    }
    return RegExp(r'^(?:好的|收到|明白|不客气|okay|ok[,! .]|you.re welcome)',
                caseSensitive: false)
            .hasMatch(reply) &&
        RegExp(r'先试|先忙|再回复|告诉我|方便时|正常使用|let me know|try it|welcome',
                caseSensitive: false)
            .hasMatch(reply);
  }

  static DateTime dispatchAt(DateTime deadline) =>
      deadline.subtract(dispatchLead);

  /// A stale row is not evidence that a native send may have clicked.
  /// Give it one fresh AX open in a new UI lease before using normal backoff.
  static bool shouldRecoverHoldingOpen(String code,
          {required bool nativeAttemptStarted, required bool alreadyRetried}) =>
      !nativeAttemptStarted &&
      !alreadyRetried &&
      const {
        'conversation_changed',
        'conversation_not_found',
        'conversation_verification_failed',
        'row_open_timeout',
        'conversation_open_timeout',
        'row_reference_expired',
        'row_layout_changed',
      }.contains(code);

  /// A failed older round should not repeatedly jump ahead of imminent
  /// first attempts. Keep the real deadline for safety and metrics; only
  /// use the fair deadline when ordering queued UI work.
  static DateTime holdingQueueDeadline(DateTime deadline, DateTime now,
      {required bool retry}) {
    if (!retry) return deadline;
    final nextSlot = now.add(preparationLead);
    return deadline.isAfter(nextSlot) ? deadline : nextSlot;
  }

  /// Keep scans out of a first response's immediate runway. Time already
  /// spent queueing/retrying must not reserve the UI for another 30 seconds.
  static bool reservesUiForFirstAttempt(DateTime deadline, DateTime now) {
    final remaining = deadline.difference(now);
    return remaining <= preparationLead && remaining >= -dispatchLead;
  }

  static Duration delayUntilDispatch(DateTime deadline, DateTime now,
      {Duration minimumDelay = Duration.zero}) {
    final remaining = dispatchAt(deadline).difference(now);
    return remaining < minimumDelay ? minimumDelay : remaining;
  }

  static bool shouldWelcomeTransfer({
    required bool unread,
    required bool transferNoticeVisible,
    required bool latestSenderIsIncoming,
  }) =>
      unread && transferNoticeVisible && latestSenderIsIncoming;

  static bool shouldOpenForCapture({
    required bool unread,
    required bool handled,
    required bool processing,
    required bool retryDue,
    required bool hasRecovery,
    bool verifiedMediaRecapture = false,
  }) =>
      verifiedMediaRecapture ||
      (unread && !handled && (hasRecovery ? retryDue : !processing));
}
