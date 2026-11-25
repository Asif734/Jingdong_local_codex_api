import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/response_timing_policy.dart';

void main() {
  test('unattributed OCR and holding cannot suppress the real SLA reply', () {
    for (final state in [
      'ownership_unverified',
      'unverified_observation',
      'delivery_unknown',
      'rejected',
      'not_sent'
    ]) {
      expect(
          ResponseTimingPolicy.isConfirmedReplyForSla({
            'direction': 'outgoing',
            'body': 'OCR seen text',
            'delivery_status': state,
          }, isHolding: false),
          isFalse);
    }
    expect(
        ResponseTimingPolicy.isConfirmedReplyForSla({
          'direction': 'outgoing',
          'delivery_status': 'submitted',
          'source': 'generated_reply',
        }, isHolding: false),
        isTrue);
    expect(
        ResponseTimingPolicy.isConfirmedReplyForSla({
          'direction': 'outgoing',
          'delivery_status': 'accepted_receipt',
          'source': 'generated_reply',
        }, isHolding: true),
        isFalse);
  });

  test('historical transfer notices in a read chat cannot send another welcome',
      () {
    expect(
        ResponseTimingPolicy.shouldWelcomeTransfer(
            unread: false,
            transferNoticeVisible: true,
            latestSenderIsIncoming: true),
        isFalse);
    expect(
        ResponseTimingPolicy.shouldWelcomeTransfer(
            unread: true,
            transferNoticeVisible: true,
            latestSenderIsIncoming: false),
        isFalse);
    expect(
        ResponseTimingPolicy.shouldWelcomeTransfer(
            unread: true,
            transferNoticeVisible: true,
            latestSenderIsIncoming: true),
        isTrue);
  });

  test(
      'red clock starts holding preflight before the 50-second default click target',
      () {
    final incoming = DateTime(2026);
    final due = incoming.add(ResponseTimingPolicy.responseTarget);
    expect(ResponseTimingPolicy.dispatchAt(due),
        incoming.add(const Duration(seconds: 48)));
    expect(
        ResponseTimingPolicy.delayUntilDispatch(
            due, incoming.add(const Duration(seconds: 46))),
        const Duration(seconds: 2));
    expect(
        ResponseTimingPolicy.delayUntilDispatch(
            due, incoming.add(const Duration(seconds: 60)),
            minimumDelay: const Duration(seconds: 1)),
        const Duration(seconds: 1));
  });

  test('only first proven pre-send row failure requests immediate reopening',
      () {
    for (final code in [
      'conversation_changed',
      'conversation_not_found',
      'row_open_timeout',
      'conversation_open_timeout',
    ]) {
      expect(
          ResponseTimingPolicy.shouldRecoverHoldingOpen(code,
              nativeAttemptStarted: false, alreadyRetried: false),
          isTrue);
      expect(
          ResponseTimingPolicy.shouldRecoverHoldingOpen(code,
              nativeAttemptStarted: true, alreadyRetried: false),
          isFalse);
      expect(
          ResponseTimingPolicy.shouldRecoverHoldingOpen(code,
              nativeAttemptStarted: false, alreadyRetried: true),
          isFalse);
    }
    for (final code in [
      'operator_offline',
      'send_unconfirmed',
      'red_clock_cleared'
    ]) {
      expect(
          ResponseTimingPolicy.shouldRecoverHoldingOpen(code,
              nativeAttemptStarted: false, alreadyRetried: false),
          isFalse);
    }
  });

  test('read rows never get clicked even when a stale recovery timer is due',
      () {
    expect(
        ResponseTimingPolicy.shouldOpenForCapture(
            unread: false,
            handled: false,
            processing: false,
            retryDue: true,
            hasRecovery: true),
        isFalse);
    expect(
        ResponseTimingPolicy.shouldOpenForCapture(
            unread: true,
            handled: false,
            processing: false,
            retryDue: true,
            hasRecovery: true),
        isTrue);
    expect(
        ResponseTimingPolicy.shouldOpenForCapture(
            unread: true,
            handled: true,
            processing: false,
            retryDue: true,
            hasRecovery: true),
        isFalse);
  });

  test(
      'already captured unread rows do not trigger an eight-second reopen loop',
      () {
    expect(
        ResponseTimingPolicy.shouldOpenForCapture(
            unread: true,
            handled: false,
            processing: true,
            retryDue: false,
            hasRecovery: false),
        isFalse);
    expect(
        ResponseTimingPolicy.shouldOpenForCapture(
            unread: true,
            handled: false,
            processing: false,
            retryDue: false,
            hasRecovery: false),
        isTrue);
  });
}
