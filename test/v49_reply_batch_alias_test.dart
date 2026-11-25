import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';

void main() {
  final messages = <Map<String, dynamic>>[
    {
      'id': 'incoming-time:buyer:2026-11-10T04:00:01Z',
      'observed_ids': ['old-question'],
      'direction': 'incoming',
      'body': 'First question',
    },
    {
      'id': 'incoming-time:buyer:2026-11-10T04:00:02Z',
      'observed_ids': ['old-next-question'],
      'direction': 'incoming',
      'body': 'Second question',
    },
    {
      'id': 'seller-reply-to-first',
      'direction': 'outgoing',
      'body': 'First answer',
    },
  ];

  test('old frozen IDs resolve to the same time-keyed reply batch', () {
    final pending = customerBatchThroughMessage(messages,
        endMessageId: 'old-next-question',
        answeredMessageId: 'old-question',
        useOutgoingFallback: false);
    expect(pending.map((message) => message['body']), ['Second question']);
  });

  test('an old answered alias cannot reopen its canonical time record', () {
    expect(
        customerBatchThroughMessage(messages,
            endMessageId: messages.first['id'],
            answeredMessageId: 'old-question',
            useOutgoingFallback: false),
        isEmpty);
  });
}
