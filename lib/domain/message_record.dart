/// One incoming message in the current service run. Its customer and JD sender
/// second identify the message; observation time records when we captured it.
class CustomerMessageRecord {
  const CustomerMessageRecord({
    required this.stableId,
    required this.customerId,
    required this.receivedAt,
    required this.kind,
    required this.body,
    required this.status,
    this.messageAt,
    this.repliedAt,
    this.replyTimeSource,
    this.holdingAt,
    this.replyAttemptId,
    this.coveredMessageCount,
  });

  final String stableId;
  final String customerId;
  final DateTime receivedAt;
  final DateTime? messageAt;

  /// Most recent substantive native send, retained if new evidence is pending.
  final DateTime? repliedAt;

  /// native_click, native_confirmation, or ledger_confirmation.
  final String? replyTimeSource;

  /// text, image, video, unknown.
  final String kind;
  final String body;

  /// pending, analyzing, ready, sending, answered, delegated, awaiting_review,
  /// needs_answer.
  final String status;
  final DateTime? holdingAt;

  /// Actual confirmed coverage, never inferred from equal display times.
  final String? replyAttemptId;

  /// Real canonical incoming messages completed by this one reply.
  final int? coveredMessageCount;
}

class MediaMessageAdmission {
  const MediaMessageAdmission(
      {required this.messageId,
      required this.receiptId,
      required this.admittedAt,
      required this.created});
  final String messageId;
  final String receiptId;
  final DateTime admittedAt;
  final bool created;
}
