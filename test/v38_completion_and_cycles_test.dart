import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

AiDraft formal({List<String>? covered}) => AiDraft.fromJson({
      'reply': 'Use the documented paper guide position.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-fixture',
      'auto_send_allowed': false,
      if (covered != null) 'formal_response_message_ids': covered,
    }, mediaBaseUrl: Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  final day = DateTime.utc(2026, 11, 8);
  DateTime clock(int hour, int minute, [int second = 0, int millisecond = 0]) =>
      day.add(Duration(
          hours: hour,
          minutes: minute,
          seconds: second,
          milliseconds: millisecond));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v38_completion_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: clock(3, 0));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> text(String id,
          {String? body, DateTime? received, DateTime? sent}) =>
      db
          .saveCapture(CapturedConversation(
              stableKey: 'buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              automationSessionId: db.currentAutomationSessionId,
              capturedAt: received ?? DateTime.now(),
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: body ?? 'Question $id',
                    sentAt: sent,
                    observationTurnKey: id,
                    axPath: 'actual incoming $id')
              ]))
          .then((_) {});
  Future<String> media(String key, {DateTime? received}) async {
    final at = received ?? DateTime.now().toUtc();
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame-$key',
        occurrenceKey: key,
        observedAt: at,
        senderAt: null,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    final admission = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'frame-$key',
        occurrenceKey: key,
        receivedAt: at);
    return admission.messageId;
  }

  Future<String> draft(String end, {AiDraft? value}) async {
    final conversation = (await db.conversation('buyer'))!;
    final token = (await db.beginGeneration(
        customer: 'buyer',
        pendingId: conversation.id,
        batchEndMessageId: end))!;
    expect(
        await db.saveDraft(conversation.id, value ?? formal(),
            expectedMessageId: end, generationToken: token),
        1);
    await db.abandonGeneration('buyer', token);
    return (value ?? formal()).reply;
  }

  Future<String> submit(String reply, {DateTime? click}) async {
    final result = await db.beginDeliveryAttempt(userId: 'buyer', reply: reply);
    final at = click ?? DateTime.now().toUtc();
    if (click != null) {
      await (await db.database).update('delivery_attempts',
          {'created_at_ms': at.millisecondsSinceEpoch - 100},
          where: 'attempt_id=?', whereArgs: [result['attemptId']]);
    }
    await File(result['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': result['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': at.millisecondsSinceEpoch,
      'timeMs': at.millisecondsSinceEpoch + 500
    }));
    await db.recoverDeliveryReceipts();
    return result['attemptId']!;
  }

  test('Nov8 old04:02 Hi OCR reread04:46 cannot clear unknown-clock04:21 media',
      () async {
    await text('first-hi',
        body: 'hi', received: clock(4, 1, 37), sent: clock(4, 1, 37));
    await draft('first-hi',
        value: AiDraft.fromJson({
          'reply': 'Hi! How can I help you today?',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'fixture',
          'auto_send_allowed': false
        }, mediaBaseUrl: Uri()));
    await submit('Hi! How can I help you today?', click: clock(4, 2, 3, 17));
    final pending =
        await media('actual-attendance-video', received: clock(4, 21, 16, 994));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: clock(4, 46, 7, 455),
        messages: [
          CapturedMessage(
              stableId: 'ocr-old-hi-typo',
              direction: 'outgoing',
              body: 'Hi! How can I help vou todav?',
              sentAt: clock(4, 2, 3),
              deliveryConfirmed: true,
              axPath: 'old visible outgoing')
        ]));
    expect(await db.isMessageFormallyAnswered('buyer', pending), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(
        (await db.customerMessageRecords('buyer'))
            .singleWhere((r) => r.stableId == pending)
            .status,
        'pending');
    expect(
        await (await db.database).query('automation_reply_inputs',
            where: "owner_id LIKE 'manual:%'"),
        isEmpty);
  });

  test(
      'dated manual OCR is only a candidate; explicit confirmation selects exact prior inputs',
      () async {
    await text('old', received: clock(4, 3, 40));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: clock(4, 4, 2),
        messages: [
          CapturedMessage(
              stableId: 'manual-candidate',
              direction: 'outgoing',
              body: '您好老板',
              sentAt: clock(4, 3, 4),
              deliveryConfirmed: true,
              axPath: 'OCR outgoing')
        ]));
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isFalse);
    expect(
        await db.confirmManualReplyCoverage('buyer',
            messageIds: ['old'], sentAt: clock(4, 3, 4), reply: '您好老板'),
        isFalse);
    await text('new', received: clock(4, 4, 3));
    expect(
        await db.confirmManualReplyCoverage('buyer',
            messageIds: ['old'],
            sentAt: clock(4, 4, 2),
            reply: 'A real confirmed answer.'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'new'), isFalse);
  });

  test('automatic mark sent requires owned positive native proof', () async {
    await text('question');
    final reply = await draft('question');
    expect(await db.markReplySent(userId: 'buyer', reply: reply), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: reply);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'someone-else',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    expect(await db.markReplySent(userId: 'buyer', reply: reply), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'question'), isFalse);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    expect(await db.markReplySent(userId: 'buyer', reply: reply), isFalse);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
      'timeMs': DateTime.now().millisecondsSinceEpoch + 500
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered('buyer', 'question'), isTrue);
  });

  test(
      'one native reply completes two real inputs and aliases do not inflate coverage',
      () async {
    await text('a', body: 'Which paper width is supported?');
    await text('b', body: 'How long is the warranty?');
    await draft('b');
    await text('later', body: 'Does this also work on a Mac?');
    final attempt = await submit(formal().reply);
    final records = await db.customerMessageRecords('buyer');
    final done =
        records.where((r) => r.stableId == 'a' || r.stableId == 'b').toList();
    expect(done.map((r) => r.status), ['answered', 'answered']);
    expect(done.map((r) => r.replyAttemptId).toSet(), {attempt});
    expect(done.map((r) => r.repliedAt).toSet(), hasLength(1));
    expect(done.map((r) => r.coveredMessageCount), [2, 2]);
    final later = records.singleWhere((r) => r.stableId == 'later');
    expect(later.status, 'pending');
    expect(later.replyAttemptId, isNull);
    expect(later.coveredMessageCount, isNull);
    // A strictly proved OCR representation is not a third customer message.
    final store = await db.history;
    final doc = (await store.read('buyer'))!;
    final path = File('${root.path}/buyer.json');
    final messages = (doc['messages'] as List).cast<Map>();
    messages.singleWhere((m) => m['id'] == 'a')['observed_ids'] = [
      'a-observation-alias'
    ];
    await path.writeAsString(jsonEncode(doc));
    final same = await db.customerMessageRecords('buyer');
    expect(same.where((r) => r.replyAttemptId == attempt), hasLength(2));
    expect(
        same
            .where((r) => r.replyAttemptId == attempt)
            .map((r) => r.coveredMessageCount),
        [2, 2]);
  });

  test('partial formal scope leaves the other frozen question pending',
      () async {
    await text('first', body: 'What is the supported paper width?');
    await text('second', body: 'How do I connect Bluetooth?');
    await draft('second', value: formal(covered: ['first']));
    final attempt = await submit(formal().reply);
    final records = await db.customerMessageRecords('buyer');
    expect(records.singleWhere((r) => r.stableId == 'first').replyAttemptId,
        attempt);
    expect(
        records.singleWhere((r) => r.stableId == 'first').coveredMessageCount,
        1);
    expect(
        records.singleWhere((r) => r.stableId == 'second').status, 'pending');
    expect(records.singleWhere((r) => r.stableId == 'second').replyAttemptId,
        isNull);
  });

  test('Nov8 old pending04:21 cannot backdate a fresh04:39 red cycle',
      () async {
    await db.observePlatformResponse('buyer',
        red: true, observedAt: clock(4, 20, 54));
    await db.confirmPlatformResponse('buyer', clock(4, 21, 15));
    await media('old-pending-card', received: clock(4, 21, 16, 994));
    await db.observePlatformResponse('buyer',
        red: false, observedAt: clock(4, 21, 17));
    await db.observePlatformResponse('buyer',
        red: true, observedAt: clock(4, 39));
    final cycle = (await db.platformResponseCycle('buyer'))!;
    expect(cycle['started_at_ms'], clock(4, 39).millisecondsSinceEpoch);
    final job = (await db.slaFallbackJob('buyer'))!;
    expect(job.dueAt.millisecondsSinceEpoch,
        clock(4, 39, 20).millisecondsSinceEpoch);
    expect(
        await db.reserveSlaFallback(
            userId: 'buyer',
            messageId: job.messageId,
            dueAt: job.dueAt,
            requireDue: true,
            monotonicDueProof: clock(4, 39, 8)),
        isFalse);
    await text('same-round-new-text', received: clock(4, 39, 10));
    await db.observePlatformResponse('buyer',
        red: true, observedAt: clock(4, 39, 10));
    expect((await db.platformResponseCycle('buyer'))!['cycle_id'],
        cycle['cycle_id']);
    expect((await db.platformResponseCycle('buyer'))!['started_at_ms'],
        cycle['started_at_ms']);
    await db.refineResumedResponseClock('buyer',
        visibleIncomingIds: ['same-round-new-text'],
        capturedAt: clock(4, 39, 11));
    expect((await db.platformResponseCycle('buyer'))!['started_at_ms'],
        cycle['started_at_ms']);
  });

  test(
      'observation is not admission and duplicate live admission keeps one root and receive time',
      () async {
    final inventory = CustomerMediaInventory(db);
    final at = clock(4, 21);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'one-observation',
        observedAt: at,
        senderAt: null,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'media-pending:$receipt',
              direction: 'incoming',
              body: '[Customer sent media]',
              axPath: 'one observed region',
              mediaReceiptId: receipt)
        ]));
    await db.repairSessionPendingWork('buyer');
    expect(await db.customerMessageRecords('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    final admitted = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'one-observation',
        occurrenceKey: 'frontier-A/bubble-1',
        receivedAt: at);
    final duplicate = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'reread',
        occurrenceKey: 'frontier-A/bubble-1',
        receivedAt: at.add(const Duration(minutes: 1)));
    expect(duplicate.created, isFalse);
    expect(duplicate.messageId, admitted.messageId);
    expect(duplicate.admittedAt, admitted.admittedAt);
    final record = (await db.customerMessageRecords('buyer')).single;
    expect(record.receivedAt, at);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });
  test(
      'same occurrence cannot steal an observation from another admitted parent',
      () async {
    final a = await media('real-A');
    final b = await media('real-B');
    final sql = await db.database;
    final aRow = (await sql.query('customer_media_items',
            where: 'customer=? AND message_id=?', whereArgs: ['buyer', a]))
        .single;
    final bRow = (await sql.query('customer_media_items',
            where: 'customer=? AND message_id=?', whereArgs: ['buyer', b]))
        .single;
    await sql.insert('customer_media_items', {
      'item_id': 'derived-of-B',
      'customer': 'buyer',
      'slot': 0,
      'kind': 'unknown',
      'state': 'superseded',
      'first_seen_ms': DateTime.now().millisecondsSinceEpoch,
      'last_seen_ms': DateTime.now().millisecondsSinceEpoch,
      'media_json': '[]',
      'aliases_json': '[]',
      'canonical_id': bRow['item_id'],
    });
    await expectLater(
        db.admitMediaMessage('buyer',
            receiptId: 'derived-of-B',
            evidenceId: 'new-observation',
            occurrenceKey: 'real-A',
            receivedAt: DateTime.now()),
        throwsStateError);
    final alias = (await sql.query('customer_media_items',
            where: 'item_id=?', whereArgs: ['derived-of-B']))
        .single;
    expect(alias['canonical_id'], bRow['item_id']);
    expect(alias['canonical_id'], isNot(aRow['item_id']));
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    expect(
        (await db.customerMessageRecords('buyer'))
            .map((r) => r.stableId)
            .toSet(),
        {a, b});
  });

  test(
      'one physical confirmed reply marks three real messages with one coverage group',
      () async {
    await text('width', body: 'What paper width is supported?');
    await text('usb', body: 'How do I connect the USB cable?');
    await text('warranty', body: 'What is the warranty period?');
    final reply = await draft('warranty');
    final attempt = await submit(reply);
    final records = await db.customerMessageRecords('buyer');
    expect(records, hasLength(3));
    expect(records.every((r) => r.status == 'answered'), isTrue);
    expect(records.map((r) => r.replyAttemptId).toSet(), {attempt});
    expect(records.map((r) => r.repliedAt).toSet(), hasLength(1));
    expect(records.map((r) => r.coveredMessageCount).toSet(), {3});
  });

  test(
      'mixed capture preserves old OCR as context and queues only authorized new input',
      () async {
    final session = db.currentAutomationSessionId;
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: session,
            capturedAt: clock(4, 46),
            messages: [
              CapturedMessage(
                  stableId: 'old-ocr-context',
                  direction: 'incoming',
                  body: 'Old context discovered by scrolling.',
                  sentAt: clock(4, 2),
                  axPath: 'old frozen bubble'),
              CapturedMessage(
                  stableId: 'new-live',
                  direction: 'incoming',
                  body: 'How do I replace the ribbon?',
                  sentAt: clock(4, 46),
                  axPath: 'new actual incoming')
            ]),
        activeIncomingIds: {'new-live'});
    final document = (await (await db.history).read('buyer'))!;
    final messages = (document['messages'] as List).cast<Map>();
    expect(messages, hasLength(2));
    final old = messages.singleWhere((m) => m['id'] == 'old-ocr-context');
    expect(old['capture_purpose'], 'history_only');
    expect(old['live_observed_session_ids'] as List? ?? [],
        isNot(contains(session)));
    expect(
        messages.singleWhere(
            (m) => m['id'] == 'new-live')['live_observed_session_ids'],
        contains(session));
    await db.repairSessionPendingWork('buyer');
    expect((await db.customerMessageRecords('buyer')).map((m) => m.stableId),
        ['new-live']);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(
        await db.isCurrentSessionMessage('buyer', 'old-ocr-context'), isFalse);
  });

  test('baseline OCR alias in a mixed frame never gains a live frontier stamp',
      () async {
    final oldAt = clock(3, 50);
    final old = CapturedMessage(
        stableId: 'old-baseline',
        direction: 'incoming',
        body: 'Previously observed product question.',
        sentAt: oldAt,
        axPath: 'same old bubble');
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: oldAt,
            messages: [old]),
        activateReplies: false);
    final session = await db.beginAutomationSession(startedAt: clock(4, 0));
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: session,
            capturedAt: clock(4, 46),
            messages: [
              CapturedMessage(
                  stableId: 'old-ocr-alias',
                  direction: 'incoming',
                  body: old.body,
                  sentAt: oldAt,
                  axPath: 'same old bubble'),
              CapturedMessage(
                  stableId: 'new-live',
                  direction: 'incoming',
                  body: 'How do I replace the ribbon?',
                  sentAt: clock(4, 46),
                  axPath: 'new actual incoming')
            ]),
        activeIncomingIds: {'new-live'});
    final doc = (await (await db.history).read('buyer'))!;
    final oldRecord = (doc['messages'] as List)
        .cast<Map>()
        .singleWhere((m) => m['id'] == 'old-baseline');
    expect(oldRecord['observed_ids'], contains('old-ocr-alias'));
    expect(oldRecord['live_observed_session_ids'] as List? ?? [],
        isNot(contains(session)));
    expect(await db.isSessionBaselineMessage('buyer', 'old-ocr-alias'), isTrue);
    await db.repairSessionPendingWork('buyer');
    expect(await db.isCurrentSessionMessage('buyer', 'old-ocr-alias'), isFalse);
    expect((await db.customerMessageRecords('buyer')).map((r) => r.stableId),
        ['new-live']);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });
}
