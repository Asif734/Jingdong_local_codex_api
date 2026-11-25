import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_slots_');
    db = CaptureDatabase(storageRoot: root);
    now = DateTime.now();
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  const draft = AiDraft(
      reply: 'A valid prepared answer',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"A valid prepared answer","decision":"draft","confidence":1,"risk_level":"low","auto_send_allowed":false}');
  Future<void> ready(String c, int age, {bool media = false}) async {
    await db.saveCapture(CapturedConversation(
        stableKey: c,
        customerName: c,
        customerExternalId: c,
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: '$c-message',
              direction: 'incoming',
              body: 'question',
              sentAt: now.subtract(Duration(seconds: age)),
              axPath: 'fixture',
              media: media
                  ? const [
                      CapturedMedia(
                          type: 'image',
                          path: '/fixture',
                          captureSource: 'jd_image_cache')
                    ]
                  : const [])
        ]));
    final conversation = (await db.conversation(c))!;
    await db.saveDraft(conversation.id, draft,
        expectedMessageId: '$c-message', expectedUserId: c);
  }

  test('unresolved red client overtakes old ready answer after holding',
      () async {
    await ready('old', 60);
    await ready('urgent', 17);
    await db.observePlatformResponse('old',
        red: true, observedAt: now.subtract(const Duration(seconds: 60)));
    await db.confirmPlatformResponse('old', now);
    await db.observePlatformResponse('urgent',
        red: true, observedAt: now.subtract(const Duration(seconds: 17)));
    expect(await db.platformDeliveryDeadline('old'), isNull);
    expect((await db.nextReadyDelivery())!.userId, 'urgent');
    expect((await db.responseSlotOwner('old', now: now))!.userId, 'urgent');
    expect(await (await db.database).query('generated_drafts'), hasLength(2));
  });
  test('reservation allows ordinary work outside six-second response window',
      () async {
    await db.observePlatformResponse('other', red: true, observedAt: now);
    expect(await db.responseSlotOwner('a', now: now), isNull);
  });
  test('a failed earlier holding never reserves another ready reply slot',
      () async {
    await ready('a', 30);
    await db.observePlatformResponse('blocked',
        red: true, observedAt: now.subtract(const Duration(seconds: 31)));
    final job = (await db.slaFallbackJob('blocked'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'blocked', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await db.releaseSlaFallback(userId: 'blocked', messageId: job.messageId);
    expect(await db.responseSlotOwner('a', now: now), isNull);
    expect(
        await db.responseSlotOwner('a',
            now: now.add(const Duration(minutes: 1))),
        isNull);
    expect(await db.slaFallbackJob('blocked'), isNotNull);
    expect((await db.nextReadyDelivery())!.userId, 'a');
  });
  test(
      'physical-dispatch reservation cannot run before the current red deadline',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: now);
    final job = (await db.slaFallbackJob('a'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'a',
            messageId: job.messageId,
            dueAt: job.dueAt,
            requireDue: true),
        isFalse);
    expect((await (await db.database).query('sla_fallbacks')).single['state'],
        'pending');
  });
  test(
      'a submitted attempt can recover an interrupted local commit without restarting',
      () async {
    await ready('a', 5);
    final delivery = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'a', reply: draft.reply, taskId: delivery.taskId);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await (await db.database)
        .update('generated_drafts', {'delivery_state': 'committing'});
    await db.recoverDeliveryReceipts();
    expect(await db.answeredMessageId('a'), 'a-message');
    expect(await (await db.database).query('generated_drafts'), isEmpty);
    await db.recoverDeliveryReceipts();
    final outgoing = ((await (await db.history).read('a'))!['messages'] as List)
        .where((m) => m['direction'] == 'outgoing');
    expect(outgoing, hasLength(1));
  });
  test('a committing task without a positive receipt cannot be resumed as sent',
      () async {
    await ready('a', 5);
    final delivery = (await db.nextReadyDelivery())!;
    await db.beginDeliveryAttempt(
        userId: 'a', reply: draft.reply, taskId: delivery.taskId);
    await (await db.database)
        .update('generated_drafts', {'delivery_state': 'committing'});
    expect(
        await db.markReplySent(
            userId: 'a', reply: draft.reply, expectedTaskId: delivery.taskId),
        isFalse);
    expect(await db.answeredMessageId('a'), isNull);
  });
  test(
      'receipt recovery freezes actual click time, not earlier attempt creation',
      () async {
    await ready('a', 5);
    await db.observePlatformResponse('a',
        red: true, observedAt: now.subtract(const Duration(seconds: 5)));
    final delivery = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'a', reply: draft.reply, taskId: delivery.taskId);
    final row = (await (await db.database).query('delivery_attempts')).single;
    final click =
        DateTime.fromMillisecondsSinceEpoch(row['created_at_ms']! as int)
            .add(const Duration(seconds: 4));
    Future<void> incoming(String id, DateTime sent) async {
      await db.saveCapture(CapturedConversation(
          stableKey: 'a',
          customerName: 'a',
          customerExternalId: 'a',
          capturedAt: sent,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'distinct question $id',
                sentAt: sent,
                axPath: 'test')
          ]));
    }

    await incoming('before-click', click.subtract(const Duration(seconds: 1)));
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'submitted',
      'sendClickedAtMs': click.millisecondsSinceEpoch,
      'timeMs': click.add(const Duration(seconds: 2)).millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    expect((await db.platformResponseCycle('a'))!['response_started_ms'],
        click.millisecondsSinceEpoch);
    await db.observePlatformResponse('a',
        red: true, observedAt: click.add(const Duration(seconds: 3)));
    expect((await db.platformResponseCycle('a'))!['state'], 'sent',
        reason: 'Messages preceding the real click are not another red round');
    await incoming('after-click', click.add(const Duration(seconds: 4)));
    await db.observePlatformResponse('a',
        red: true, observedAt: click.add(const Duration(seconds: 5)));
    expect((await db.platformResponseCycle('a'))!['state'], 'waiting');
  });
  test('ready reply with an earlier unmet deadline retains priority', () async {
    await db.observePlatformResponse('other',
        red: true, observedAt: now.subtract(const Duration(seconds: 18)));
    expect(
        await db.responseSlotOwner('a',
            ownDeadline: now.add(const Duration(seconds: 1)), now: now),
        isNull);
  });
  test(
      'caption following image retires only an unclicked draft and keeps all inputs',
      () async {
    await ready('a', 5, media: true);
    final capture = CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: 'caption',
              direction: 'incoming',
              body: 'What is next?',
              sentAt: now,
              axPath: 'fixture')
        ]);
    await db.saveCapture(capture);
    expect(
        await db.mergeMediaCaptionBatch('a', capture), contains('a-message'));
    expect(await (await db.database).query('generated_drafts'), isEmpty);
    expect(await db.pendingMessageId('a'), 'caption');
    expect(await db.hasPendingUnanswered('a'), isTrue);
    expect(((await (await db.history).read('a'))!['messages'] as List),
        hasLength(2));
  });
  test('caption cannot retire an already clicked or uncertain send', () async {
    await ready('a', 5, media: true);
    await (await db.database)
        .update('generated_drafts', {'delivery_state': 'delivery_unknown'});
    final capture = CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: 'caption',
              direction: 'incoming',
              body: 'What is next?',
              sentAt: now,
              axPath: 'fixture')
        ]);
    await db.saveCapture(capture);
    await db.mergeMediaCaptionBatch('a', capture);
    expect(
        (await (await db.database).query('generated_drafts'))
            .single['delivery_state'],
        'delivery_unknown');
  });
}
