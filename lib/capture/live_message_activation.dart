import '../domain/capture_models.dart';

/// A live capture reports received inputs; the database owns Start baselines
/// and the per-message unanswered ledger. Observation time and nearby seller
/// messages cannot prove that an individual customer question was answered.
Set<String> activeLiveIncomingIds(
  CapturedConversation? capture, {
  required bool replyActivationAllowed,
  DateTime? historyCutoff,
  required DateTime signalAt,
  Set<String> knownIncomingIds = const {},
}) {
  if (capture == null || !replyActivationAllowed) return {};
  return {
    for (final message in capture.messages)
      if (message.direction == 'incoming') message.stableId,
  };
}
