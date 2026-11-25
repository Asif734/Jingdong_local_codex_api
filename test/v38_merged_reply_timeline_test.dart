import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/message_record.dart';
import 'package:jd_automation/ui/customer_message_timeline.dart';

void main() {
  testWidgets('one confirmed answer is shown on every covered real message',
      (tester) async {
    final received = DateTime.utc(2026, 11, 8, 4, 5);
    final replied = received.add(const Duration(seconds: 15));
    final records = [
      for (final id in ['text-question', 'actual-video'])
        CustomerMessageRecord(
          stableId: id,
          customerId: 'buyer',
          receivedAt: received,
          repliedAt: replied,
          kind: id == 'actual-video' ? 'video' : 'text',
          body: id == 'actual-video' ? '' : 'Please check this problem.',
          status: 'answered',
          replyAttemptId: 'same-confirmed-native-send',
          coveredMessageCount: 2,
        ),
      CustomerMessageRecord(
          stableId: 'later-question',
          customerId: 'buyer',
          receivedAt: received.add(const Duration(seconds: 16)),
          kind: 'text',
          body: 'How long is the warranty?',
          status: 'pending'),
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: CustomerMessageTimeline(
                    customer: 'buyer', records: records)))));
    expect(find.text('合并回复 · 同次覆盖2条消息'), findsNWidgets(2));
    for (final id in ['text-question', 'actual-video']) {
      final card = find.byKey(ValueKey('message-record:$id'));
      expect(find.descendant(of: card, matching: find.text('已回复')),
          findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(ValueKey('message-replied:$id'))).data,
          '回复 ${CustomerMessageTimeline.formatTime(replied)}');
    }
    expect(find.byKey(const ValueKey('message-merged-reply:later-question')),
        findsNothing);
    expect(find.text('回复 —'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
