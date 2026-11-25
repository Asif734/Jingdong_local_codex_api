import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

const answer = AiDraft(
    reply: 'A real answer',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'test',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"A real answer","decision":"draft","confidence":1,"risk_level":"low","model":"test"}');
void main() {
  late Directory root;
  late CaptureDatabase db;
  late DateTime started;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_session_');
    db = CaptureDatabase(storageRoot: root);
    started = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<int> capture(String id,
          {DateTime? at,
          DateTime? sender,
          bool active = true,
          Set<String>? allowed}) =>
      db.saveCapture(
          CapturedConversation(
              stableKey: 'buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              capturedAt: at ?? DateTime.now().toUtc(),
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: 'Question $id',
                    sentAt: sender ?? at ?? DateTime.now().toUtc(),
                    axPath: 'test')
              ]),
          activateReplies: active,
          activeIncomingIds: allowed);
  Future<void> draft({bool deliverable = true}) async {
    final c = (await db.conversation('buyer'))!;
    await db.saveDraft(c.id, answer,
        expectedUserId: 'buyer',
        expectedMessageId: await db.pendingMessageId('buyer'),
        deliverable: deliverable);
  }

  Future<void> oldInput() =>
      capture('old', at: started.subtract(const Duration(minutes: 1)))
          .then((_) {});
  test(
      'Start archives old execution state without pretending the question was answered',
      () async {
    await oldInput();
    await draft(deliverable: false);
    final old = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'old issue',
        reason: 'order',
        requestMessageId: 'old');
    await db.markTicketHandoffBlocked(
        old.id, 'preclick_failure_requires_operator');
    final oldHistory = jsonEncode(await (await db.history).read('buyer'));
    await db.beginAutomationSession(startedAt: started);
    final sql = await db.database;
    expect(await sql.query('pending_customers'), isEmpty);
    expect(await sql.query('generated_drafts'), isEmpty);
    expect(await db.isHandoffPending('buyer'), isFalse);
    expect(await db.isCurrentSessionTicket(old.id), isFalse);
    expect((await sql.query('human_review_tickets')).single['status'],
        'session_archived');
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(jsonEncode(await (await db.history).read('buyer')), oldHistory);
    expect(await sql.query('automation_work_archive'), isNotEmpty);
    expect(await db.ensurePendingForUnanswered('buyer'), isFalse);
    expect(await db.processingMessages('buyer'), isEmpty);
  });
  test('new shared-clock message is not held by an archived order handoff',
      () async {
    await oldInput();
    final t = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'old order',
        reason: 'old',
        requestMessageId: 'old');
    await db.markTicketHandoffPending(t.id);
    await db.beginAutomationSession(startedAt: started);
    await capture('new', sender: started.subtract(const Duration(minutes: 1)));
    expect(await db.pendingMessageId('buyer'), 'new');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.isBatchUnanswered('buyer', 'old'), isFalse);
    expect(await db.isBatchUnanswered('buyer', 'new'), isTrue);
    expect(
        (await db.processingMessages('buyer'))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        ['new']);
    final c = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer', pendingId: c.id, batchEndMessageId: 'new'),
        isNotNull);
  });
  test('restarting again cannot reactivate old known IDs or late frozen frames',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('one');
    final next = DateTime.now().toUtc();
    await db.beginAutomationSession(startedAt: next);
    await capture('one', at: next.add(const Duration(milliseconds: 2)));
    await capture('stale-new-id',
        at: next.subtract(const Duration(seconds: 1)));
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    expect(await db.isCurrentSessionMessage('buyer', 'one'), isFalse);
    expect(await db.isCurrentSessionMessage('buyer', 'stale-new-id'), isFalse);
    await capture('two', at: next.add(const Duration(milliseconds: 3)));
    expect(await db.pendingMessageId('buyer'), 'two');
  });
  test(
      'activation allowlist never promotes every historical bubble in a live frame',
      () async {
    await db.beginAutomationSession(startedAt: started);
    final at = DateTime.now().toUtc();
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            capturedAt: at,
            messages: [
              CapturedMessage(
                  stableId: 'visible-old',
                  direction: 'incoming',
                  body: 'old bubble',
                  sentAt: started.subtract(const Duration(hours: 2)),
                  axPath: 'test'),
              CapturedMessage(
                  stableId: 'live-new',
                  direction: 'incoming',
                  body: 'new question',
                  sentAt: at,
                  axPath: 'test')
            ]),
        activeIncomingIds: {'live-new'});
    expect((await db.processingMessages('buyer')).map((m) => m['id']),
        ['live-new']);
    expect(await db.pendingMessageId('buyer'), 'live-new');
  });
  for (final phase in ['submitted', 'rejected', 'unknown']) {
    test(
        'archived $phase receipt cannot consume or recreate work in a new session',
        () async {
      await oldInput();
      await draft();
      final old =
          await db.beginDeliveryAttempt(userId: 'buyer', reply: answer.reply);
      await db.beginAutomationSession(startedAt: started);
      await capture('new');
      await draft();
      final latest = (await (await db.database).query('generated_drafts'))
          .single['task_id'];
      await db.observePlatformResponse('buyer',
          red: true, observedAt: DateTime.now().toUtc());
      final cycle = (await db.platformResponseCycle('buyer'))!['cycle_id'];
      await File(old['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': old['attemptId'],
        'customer': 'buyer',
        'state': phase,
        'timeMs': DateTime.now().millisecondsSinceEpoch
      }));
      await db.recoverDeliveryReceipts();
      await db.confirmPlatformResponse('buyer', DateTime.now(),
          attemptId: old['attemptId']);
      expect(
          (await (await db.database).query('generated_drafts'))
              .single['task_id'],
          latest);
      expect(await db.answeredMessageId('buyer'), isNull);
      expect((await db.platformResponseCycle('buyer'))!['cycle_id'], cycle);
      expect((await db.platformResponseCycle('buyer'))!['state'], 'waiting');
    });
  }
  test(
      'late old handoff completion cannot delete the current ready answer or seize control',
      () async {
    await oldInput();
    final t = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'old order',
        reason: 'old',
        requestMessageId: 'old');
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    await draft();
    await db.markTicketContacted(t.id, assignedTo: 'old agent');
    await db.markTicketContacting(t.id);
    await db.markTicketHandoffBlocked(t.id, 'old failure');
    expect(await db.isHumanContacting('buyer'), isFalse);
    expect(
        (await (await db.database).query('generated_drafts'))
            .single['delivery_state'],
        'ready');
    expect(await db.answeredMessageId('buyer'), isNull);
  });
  test(
      'failed handoff becomes independent todo and AI can answer the same unresolved batch',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    await draft(deliverable: false);
    final t = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'new issue',
        reason: 'staff',
        requestMessageId: 'new');
    await db.markTicketHandoffPending(t.id);
    expect(await db.isHandoffExecutionCurrent(t.id), isTrue);
    await db.releaseHandoffForAi(t.id, reason: 'conversation_not_found');
    expect(await db.pendingMessageId('buyer'), 'new');
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.isHandoffSuppressed('buyer', 'new'), isTrue);
    expect((await db.handoffFallbackContext('buyer'))!['continue_ai'], isTrue);
    expect((await db.humanReviewTickets()).single.status, 'open');
    final c = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer', pendingId: c.id, batchEndMessageId: 'new'),
        isNotNull);
    await capture('later');
    expect(await db.isHandoffSuppressed('buyer', 'later'), isTrue);
  });
  test('pending background handoff does not block ordinary generation',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    final t = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'request',
        reason: 'staff',
        requestMessageId: 'new');
    await db.markTicketHandoffPending(t.id);
    final c = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer', pendingId: c.id, batchEndMessageId: 'new'),
        isNotNull);
    expect(
        (await (await db.database).query('conversation_control'))
            .single['state'],
        'ai_active');
  });
  test(
      'independent current-session todo can prepare native transfer while AI control stays active',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'request',
        reason: 'staff',
        requestMessageId: 'new');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.markTicketHandoffPending(ticket.id);
    await db.updateChatTransferLog(
        id: log.id, status: 'ready', targetAccount: 'real agent');
    await db.setTransferAcknowledgement(log.id, 1);
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: 'buyer', targetAccount: 'real agent');
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    expect(
        (await (await db.database).query('chat_transfer_logs',
                where: 'id=?', whereArgs: [log.id]))
            .single['phase'],
        'invoking_native');
    expect(
        (await (await db.database).query('conversation_control'))
            .single['state'],
        'ai_active');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await expectLater(
        db.markTransferNativeInvoked(log.id, attempt['attemptId']!),
        throwsStateError);
  });
  test(
      'transfer ACK and holding never turn an unresolved current question into answered',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    await db.appendAutomatedNoticeSent(
        userId: 'buyer',
        reply: 'I am connecting a colleague.',
        model: 'jd-transfer-acknowledgement-v1');
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait while I check.');
    expect(await db.isBatchUnanswered('buyer', 'new'), isTrue);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.answeredMessageId('buyer'), isNull);
    final c = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer', pendingId: c.id, batchEndMessageId: 'new'),
        isNotNull);
  });
  test(
      'late archived positive bubble cannot act as a manual answer to the new problem',
      () async {
    await oldInput();
    await draft();
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: answer.reply);
    final old = (await (await db.database).query('delivery_attempts')).single;
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    final sent =
        DateTime.fromMillisecondsSinceEpoch(old['created_at_ms']! as int)
            .add(const Duration(seconds: 1));
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            capturedAt: sent,
            messages: [
              CapturedMessage(
                  stableId: 'old-native-bubble',
                  direction: 'outgoing',
                  body: answer.reply,
                  sentAt: sent,
                  deliveryConfirmed: true,
                  axPath: 'test')
            ]),
        activeIncomingIds: {});
    expect(await db.pendingMessageId('buyer'), 'new');
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(
        (await (await db.database).query('automation_archived_attempts'))
            .single['attempt_id'],
        attempt['attemptId']);
  });
  test(
      'failed background transfer has bounded retry and AX identity wake without freezing AI',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'new',
        reason: 'staff',
        requestMessageId: 'new');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: 'conversation_not_found');
    await db.releaseHandoffForAi(ticket.id, reason: 'conversation_not_found');
    final sql = await db.database;
    final row = (await sql
            .query('chat_transfer_logs', where: 'id=?', whereArgs: [log.id]))
        .single;
    expect(row['preclick_retry_at_ms']! as int,
        greaterThan(DateTime.now().millisecondsSinceEpoch));
    expect(await db.wakeCurrentHandoffAfterIdentity('buyer'), isTrue);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(
        (await sql.query('conversation_control')).single['state'], 'ai_active');
  });
  test(
      'ordinary response yielding keeps an independent transfer without consuming failures',
      () async {
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'new',
        reason: 'staff',
        requestMessageId: 'new');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: 'handoff_yielded_for_reply');
    for (var i = 0; i < 5; i++) {
      expect(
          await db.deferHandoffForReply(
              logId: log.id,
              ticketId: ticket.id,
              resumePhase: 'inspect_accounts'),
          isTrue);
    }
    final row = (await (await db.database)
            .query('chat_transfer_logs', where: 'id=?', whereArgs: [log.id]))
        .single;
    expect(row['preclick_retry_count'], 0);
    expect(row['status'], 'deferred');
    expect(row['preclick_retry_at_ms']! as int,
        greaterThan(DateTime.now().millisecondsSinceEpoch));
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect((await db.humanReviewTickets()).single.status, 'open');
    expect(await db.isHumanContacting('buyer'), isFalse);
  });
  test('old native holding confirmation cannot satisfy a fresh red cycle',
      () async {
    await oldInput();
    await db.observePlatformResponse('buyer', red: true);
    final old = (await db.slaFallbackJob('buyer'))!;
    await db.reserveSlaFallback(
        userId: 'buyer', messageId: old.messageId, dueAt: old.dueAt);
    await db.beginSlaAttempt(old, 'Please wait while I check.');
    await db.beginAutomationSession(startedAt: started);
    await capture('new');
    await db.observePlatformResponse('buyer',
        red: true, observedAt: DateTime.now().add(const Duration(seconds: 1)));
    final fresh = (await db.platformResponseCycle('buyer'))!['cycle_id'];
    expect(
        await db.markSlaFallbackSent(
            userId: 'buyer',
            messageId: old.messageId,
            batchStartMessageId: old.batchStartMessageId,
            reply: 'Please wait while I check.',
            nativeConfirmed: true),
        isFalse);
    expect((await db.platformResponseCycle('buyer'))!['cycle_id'], fresh);
    expect((await db.platformResponseCycle('buyer'))!['state'], 'waiting');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
}
