import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';

void main() {
  final messages = <Map<String, dynamic>>[
    {'id': 'old-question', 'direction': 'incoming', 'body': 'Old business'},
    {
      'id': 'old-answer',
      'direction': 'outgoing',
      'source': 'generated_reply',
      'body': 'Old answer'
    },
    {
      'id': 'current-question',
      'direction': 'incoming',
      'body': 'i have issue with m880'
    },
    {
      'id': 'transfer-ack',
      'direction': 'outgoing',
      'source': 'automated_notice',
      'body': 'I will transfer you'
    },
    {
      'id': 'holding',
      'direction': 'outgoing',
      'source': 'sla_fallback',
      'body': 'Please wait'
    },
    {
      'id': 'follow-up',
      'direction': 'incoming',
      'body': 'Can you help with printing?'
    }
  ];
  test(
      'explicit processing boundary keeps the real question despite later handoff ACK and holding',
      () {
    final batch = customerBatchThroughMessage(messages,
        endMessageId: 'follow-up',
        answeredMessageId: 'missing-old-boundary',
        useOutgoingFallback: false);
    expect(batch.map((m) => m['id']),
        ['old-question', 'current-question', 'follow-up']);
    expect(batch.any((m) => m['id'] == 'transfer-ack' || m['id'] == 'holding'),
        isFalse);
  });
  test(
      'a durable answered cursor still limits the batch when outgoing fallback is disabled',
      () {
    final batch = customerBatchThroughMessage(messages,
        endMessageId: 'follow-up',
        answeredMessageId: 'old-question',
        useOutgoingFallback: false);
    expect(batch.map((m) => m['id']), ['current-question', 'follow-up']);
  });
  test('a frozen end cannot absorb a later follow-up', () {
    final batch = customerBatchThroughMessage(messages,
        endMessageId: 'current-question',
        answeredMessageId: 'old-question',
        useOutgoingFallback: false);
    expect(batch.map((m) => m['id']), ['current-question']);
  });
  test('legacy no-session callers keep their outgoing fallback behavior', () {
    final batch = customerBatchThroughMessage(messages,
        endMessageId: 'follow-up', answeredMessageId: 'missing-old-boundary');
    expect(batch.map((m) => m['id']), ['follow-up']);
  });
}
