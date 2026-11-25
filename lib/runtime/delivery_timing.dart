/// OCR sender headers can be shared by several bubbles or corrected later.
/// Keep them as estimates alongside independently measured capture/click times.
Map<String, Object?> formalReplyTiming(Map<String, Object?> saved,
    {required DateTime confirmedAt, DateTime? clickedAt}) {
  final click = clickedAt ?? confirmedAt;
  final observed =
      DateTime.tryParse(saved['firstObservedAt']?.toString() ?? '');
  final sender =
      DateTime.tryParse(saved['customerMessageAt']?.toString() ?? '');
  int? elapsed(DateTime? start) => start == null || start.isAfter(click)
      ? null
      : click.difference(start).inMilliseconds;
  return {
    ...saved,
    'metricsSchema': 2,
    'replyKind': 'formal',
    'businessResponseSent': true,
    'caseResolved': null,
    'sendClickedAt': clickedAt?.toUtc().toIso8601String(),
    'confirmedAt': confirmedAt.toUtc().toIso8601String(),
    'clickTimeSource':
        clickedAt == null ? 'confirmation_fallback' : 'native_click',
    'firstObservedToClickMs': elapsed(observed),
    'senderToClickEstimateMs': elapsed(sender),
    'senderClockSource': 'ocr_header_or_group_estimate',
    'senderClockVerified': false,
    'platformSlaVerified': false,
  };
}
