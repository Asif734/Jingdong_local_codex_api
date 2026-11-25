/// The automatic worker must distinguish an actual queued reply from work
/// which still needs content. Neither waiting nor repair completes a message.
enum AutomaticDraftSaveOutcome {
  ready,
  transferOnly,
  awaitingDependency,
  needsAnswer,
  stale,
}

class AutomaticDraftSaveResult {
  const AutomaticDraftSaveResult(this.outcome,
      {this.requiresOperator = false, this.repairContext});

  final AutomaticDraftSaveOutcome outcome;
  final bool requiresOperator;
  final Map<String, Object?>? repairContext;

  bool get queued =>
      outcome == AutomaticDraftSaveOutcome.ready ||
      outcome == AutomaticDraftSaveOutcome.transferOnly;

  /// Compatibility for callers of the original persistence API. Automatic
  /// workers use [outcome], rather than interpreting this as a queued draft.
  int get legacyCount => outcome == AutomaticDraftSaveOutcome.stale ? 0 : 1;
}
