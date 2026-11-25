import 'package:flutter/services.dart';

import '../platform/macos_capture_adapter.dart';
import '../runtime/runtime_trace.dart';

/// The send transaction deliberately has no screenshot or OCR dependency.
/// Caller holds the JD UI lease; native code verifies AX identity and composer.
class DirectReplyDelivery {
  DirectReplyDelivery(this.adapter,
      {this.record = RuntimeTrace.record,
      this.onConfirmed,
      this.onRedClockCleared,
      this.now = DateTime.now});
  final MacOSCaptureAdapter adapter;
  final Future<void> Function(String, DateTime, String?)? onRedClockCleared;
  final Future<void> Function(String, DateTime, String?, String?)? onConfirmed;
  final void Function(String, Map<String, Object?>) record;
  final DateTime Function() now;

  DateTime _deadline(DateTime? requested) =>
      requested ?? now().add(const Duration(seconds: 6));

  void _requireBudget(DateTime deadline, String stage) {
    if (now().isBefore(deadline)) return;
    throw PlatformException(
        code: 'send_preclick_budget_exceeded',
        message: 'The shared send deadline expired before the native click; '
            'the unsent draft remains queued.',
        details: {
          'sendStage': stage,
          'clickDispatched': false,
          'nativeInvoked': false,
          'preClickDeadlineMs': deadline.millisecondsSinceEpoch,
          'preClickBudgetRemainingMs': 0,
        });
  }

  Future<void> open(String customer,
      {DateTime? preClickDeadline, Duration? maxOpenDuration}) async {
    final clock = Stopwatch()..start();
    final deadline = _deadline(preClickDeadline);
    try {
      _requireBudget(deadline, 'before_open');
      await adapter.openConversation(customer,
          allowActivation: true, maxOpenDuration: maxOpenDuration);
      record('delivery.conversation_opened', {
        'customer': customer,
        'elapsedMs': clock.elapsedMilliseconds,
        'preClickDeadlineMs': deadline.millisecondsSinceEpoch,
        'preClickBudgetRemainingMs': deadline.difference(now()).inMilliseconds,
      });
      _requireBudget(deadline, 'after_open');
    } catch (error) {
      _failure('open_conversation', customer, clock, error);
      rethrow;
    }
  }

  Future<void> sendConfirmed(
      {required String customer,
      required String reply,
      List<String> mediaPaths = const [],
      String? attemptId,
      String? receiptPath,
      int? mediaRevision,
      String? mediaGuardPath,
      bool requireRedClock = false,
      DateTime? holdingClickNotBefore,
      String? responseCycleId,
      DateTime? preClickDeadline}) async {
    final clock = Stopwatch()..start();
    final sendStarted = now();
    final deadline = _deadline(preClickDeadline);
    try {
      _requireBudget(deadline, 'before_native_send');
      final result = await adapter.sendDraftOnce(
          expectedCustomer: customer,
          reply: reply,
          mediaPaths: mediaPaths,
          attemptId: attemptId,
          receiptPath: receiptPath,
          mediaRevision: mediaRevision,
          mediaGuardPath: mediaGuardPath,
          requireRedClock: requireRedClock,
          holdingClickNotBefore: holdingClickNotBefore,
          preClickDeadline: deadline);
      if (result['sent'] != true) {
        throw PlatformException(
            code: 'send_not_confirmed',
            message: 'Native send did not confirm the empty composer.',
            details: result);
      }
      // A physical click may confirm after the pre-click deadline. Keep its
      // receipt and success; a Dart timeout must never authorize another send.
      try {
        await onConfirmed?.call(customer, _clickedAt(result, sendStarted),
            attemptId, responseCycleId);
        if (result['redClockPresentAfterSend'] == false &&
            result['redClockObservedAtMs'] is num) {
          await onRedClockCleared?.call(
              customer,
              DateTime.fromMillisecondsSinceEpoch(
                  (result['redClockObservedAtMs']! as num).toInt()),
              responseCycleId);
        }
      } catch (error) {
        // Physical success must not become a retry because bookkeeping failed.
        record('sla.confirmation_persist_failed',
            {'customer': customer, 'errorCode': error.runtimeType.toString()});
      }
      record('delivery.direct_send_confirmed', {
        'customer': customer,
        'elapsedMs': clock.elapsedMilliseconds,
        'sendStartedAtMs': result['sendStartedAtMs'],
        'sendClickedAtMs': result['sendClickedAtMs'],
        'stageElapsedMs': result['stageElapsedMs'],
        'sent': true,
        'redClockPresentAfterSend': result['redClockPresentAfterSend'],
        'activationAttempts': result['activationAttempts'],
        'axRefreshAttempts': result['axRefreshAttempts'],
        'reusedOwnInsertion': result['reusedOwnInsertion'],
        for (final key in [
          'queueWaitMs',
          'preClickDeadlineMs',
          'preClickBudgetRemainingMs',
          'fullSnapshotReads',
          'lightSnapshotReads',
          'confirmationAXValueFailures',
          'postClickComposerPreserved',
        ])
          if (result[key] != null) key: result[key],
        'sendStage': result['sendStage'],
        'confirmation':
            result['confirmation'] ?? 'native_composer_confirmation',
      });
    } catch (error) {
      _failure('native_send', customer, clock, error, attemptId: attemptId);
      rethrow;
    }
  }

  Future<bool> deliver(
      {required String customer,
      required String reply,
      List<String> mediaPaths = const [],
      required Future<bool> Function() canSend,
      Future<Map<String, String>> Function()? beforeSend,
      String? responseCycleId,
      DateTime? preClickDeadline}) async {
    final deadline = _deadline(preClickDeadline);
    await open(customer, preClickDeadline: deadline);
    final clock = Stopwatch()..start();
    late final bool valid;
    try {
      _requireBudget(deadline, 'before_state_validation');
      valid = await canSend();
      if (valid) _requireBudget(deadline, 'after_state_validation');
    } catch (error) {
      _failure('state_validation', customer, clock, error);
      rethrow;
    }
    if (!valid) {
      record('delivery.skipped',
          {'customer': customer, 'reason': 'state_changed_after_open'});
      return false;
    }
    Map<String, String>? attempt;
    try {
      _requireBudget(deadline, 'before_attempt_preparation');
      attempt = await beforeSend?.call();
      _requireBudget(deadline, 'after_attempt_preparation');
    } catch (error) {
      _failure('attempt_preparation', customer, clock, error);
      rethrow;
    }
    await sendConfirmed(
        customer: customer,
        reply: reply,
        mediaPaths: mediaPaths,
        attemptId: attempt?['attemptId'],
        receiptPath: attempt?['receiptPath'],
        mediaRevision: int.tryParse(attempt?['mediaRevision'] ?? ''),
        mediaGuardPath: attempt?['mediaGuardPath'],
        responseCycleId: responseCycleId,
        preClickDeadline: deadline);
    return true;
  }

  DateTime _clickedAt(Map<String, Object?> result, DateTime fallback) {
    final value = result['sendClickedAtMs'];
    if (value is num && value.isFinite && value > 0) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      } on ArgumentError {
        // An invalid diagnostic timestamp cannot undo a confirmed send.
      }
    }
    return fallback;
  }

  void _failure(String stage, String customer, Stopwatch clock, Object error,
      {String? attemptId}) {
    record('delivery.failed', {
      'customer': customer,
      if (attemptId != null) 'attemptId': attemptId,
      'stage': stage,
      if (error is PlatformException && error.details is Map)
        for (final key in [
          'openStage',
          'queueWaitMs',
          'rejectedFingerprint',
          'expectedCustomer',
          'activeCustomerId',
          'identitySource',
          'sendStage',
          'sendStartedAtMs',
          'sendClickedAtMs',
          'stageElapsedMs',
          'composerRecovery',
          'clickDispatched',
          'foregroundPid',
          'foregroundBundleId',
          'activationAttempts',
          'axRefreshAttempts',
          'reusedOwnInsertion',
          'nativeInvoked',
          'preClickDeadlineMs',
          'preClickBudgetRemainingMs',
          'fullSnapshotReads',
          'lightSnapshotReads',
          'confirmationAXValueFailures',
          'postClickComposerPreserved',
          'composerStillMatchesReply',
        ])
          if ((error.details as Map)[key] != null)
            key: (error.details as Map)[key],
      'elapsedMs': clock.elapsedMilliseconds,
      'errorCode': error is PlatformException
          ? error.code
          : error.runtimeType.toString(),
      'sent': false,
    });
  }
}
