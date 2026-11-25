import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  const buyer = 'buyer';
  const source = 'source-agent';
  const target = 'target-agent';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v32_handoff_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> incoming(String id,
      {String customer = buyer, DateTime? senderAt}) async {
    final at = senderAt ?? DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
      stableKey: customer,
      customerName: customer,
      customerExternalId: customer,
      automationSessionId: db.currentAutomationSessionId,
      capturedAt: at,
      messages: [
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: 'Controlled request $id',
            sentAt: at,
            axPath: 'AX fixture'),
      ],
    ));
  }

  Future<(HumanReviewTicket, ChatTransferLog)> prepared() async {
    await incoming('request');
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'Controlled service request',
        reason: 'Authorized order service',
        requestMessageId: 'request');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'ready',
        sourceAccount: source,
        targetAccount: target);
    return (ticket, log);
  }

  Future<Map<String, Object?>> row(int id) async => (await (await db.database)
          .query('chat_transfer_logs', where: 'id=?', whereArgs: [id]))
      .single;
  Future<void> makeDue(int id) async {
    await (await db.database).update('chat_transfer_logs',
        {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1},
        where: 'id=?', whereArgs: [id]);
  }

  Future<Map<String, String>> invoked(ChatTransferLog log) async {
    await db.setTransferAcknowledgement(log.id, 1);
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: buyer, targetAccount: target);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    return attempt;
  }

  Future<String> notClickedReceipt(Map<String, String> attempt,
      [Map<String, Object?> overrides = const {}]) async {
    final text = jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'targetAccount': target,
      'state': 'not_clicked',
      'transferClicked': false,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
      ...overrides,
    });
    await File(attempt['receiptPath']!).writeAsString(text, flush: true);
    return text;
  }

  AiDraft answer(String reply) => AiDraft.fromJson({
        'reply': reply,
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-test',
        'used_record_ids': [],
        'actions': [],
        'attachments': [],
      }, mediaBaseUrl: Uri());

  test('six ordinary response yields retain the selected target and no failure',
      () async {
    final (ticket, log) = await prepared();
    // This test starts after the API has authorized this exact request. Keep
    // that fixture independent of the native yield/checkpoint state below.
    await (await db.database).insert('automation_work_archive', {
      'session_id': db.currentAutomationSessionId,
      'table_name': 'api_transfer_authority',
      'record_key': '${ticket.id}',
      'row_json': jsonEncode({
        'user_id': buyer,
        'request_message_id': 'request',
        'task_id': 'api-checkpoint',
        'raw_json': jsonEncode({
          'reply': '交由同事处理。',
          'decision': 'human_review_required',
          'model': 'jd-hosted-v2',
          'confidence': 1,
          'risk_level': 'low',
          'service_session_id': db.currentAutomationSessionId,
          'service_message_ids': ['request'],
          'jd_v2': {
            'reply': {'action': 'reply_then_transfer'}
          }
        })
      }),
      'archived_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    for (var i = 0; i < 6; i++) {
      final before = DateTime.now().millisecondsSinceEpoch;
      expect(
          await db.deferHandoffForReply(
              logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
          isTrue);
      final deferred = await row(log.id);
      expect(deferred['status'], 'deferred');
      expect(deferred['error'], isNull);
      expect(deferred['preclick_retry_count'], 0);
      expect(
          deferred['preclick_retry_at_ms'],
          inInclusiveRange(
              before + 1000, DateTime.now().millisecondsSinceEpoch + 1000));
      expect(deferred['target_account'], target);
      expect(deferred['source_account'], source);
      expect(deferred['acknowledged'], 0);
      expect(deferred['attempt_id'], isNull);
      expect(deferred['transfer_clicked'], 0);
      final checkpoint = await db.handoffReplyContinuation(ticket.id);
      expect(checkpoint, {
        'logId': log.id,
        'requestMessageId': 'request',
        'sourceAccount': source,
        'targetAccount': target,
        'resumePhase': 'acknowledge',
      });
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull,
          reason:
              'A yielded transfer waits for the short timer, not a busy loop');
      await makeDue(log.id);
      expect((await db.duePreclickHandoffs()).single.id, ticket.id);
      final reserved = await db.reserveChatTransferLog(ticket: ticket);
      expect(reserved!.targetAccount, target);
      expect((await row(log.id))['preclick_retry_count'], 0);
      expect((await row(log.id))['phase'], 'reply_resuming:acknowledge');
      expect(await db.handoffReplyContinuation(ticket.id), checkpoint);
      expect(await db.isHumanContacting(buyer), isFalse);
      expect(await db.hasPendingUnanswered(buyer), isTrue);
      expect(await db.answeredMessageId(buyer), isNull);
    }
    final fallback = await db.handoffFallbackContext(buyer);
    expect(fallback!['continueAi'], isTrue);
    expect(
        (await db.handoffServiceStatus(buyer))!['requiresOperator'], isFalse);
  });

  test('ACK confirmation survives yielding before fresh final validation',
      () async {
    final (ticket, log) = await prepared();
    await db.setTransferAcknowledgement(log.id, 1);
    expect(
        await db.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: 'revalidate_target'),
        isTrue);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await row(log.id))['phase'], 'reply_deferred:revalidate_target');
    await makeDue(log.id);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    expect(await db.transferAcknowledgement(log.id), 1);
    expect((await db.handoffReplyContinuation(ticket.id))!['resumePhase'],
        'revalidate_target');
    expect((await row(log.id))['preclick_retry_count'], 0);
  });

  test(
      'durable exact not-clicked receipt releases only its finished invocation',
      () async {
    final (ticket, log) = await prepared();
    final attempt = await invoked(log);
    final proof = await notClickedReceipt(attempt);
    expect(
        await db.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: 'revalidate_target',
            provenNotClickedAttemptId: attempt['attemptId']),
        isTrue);
    final deferred = await row(log.id);
    expect(deferred['attempt_id'], isNull);
    expect(deferred['attempt_started_at_ms'], isNull);
    expect(deferred['transfer_clicked'], 0);
    expect(deferred['acknowledged'], 1);
    expect(deferred['preclick_retry_count'], 0);
    expect(deferred['target_account'], target);
    expect(deferred['phase'], 'reply_deferred:revalidate_target');
    expect(await File(attempt['receiptPath']!).readAsString(), proof);
    await makeDue(log.id);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    final next = await db.beginTransferAttempt(
        logId: log.id, customer: buyer, targetAccount: target);
    expect(next['attemptId'], isNot(attempt['attemptId']));
    expect(await File(attempt['receiptPath']!).readAsString(), proof,
        reason: 'An authoritative old journal remains available for auditing');
    expect(await db.answeredMessageId(buyer), isNull);
    expect(await db.isHumanContacting(buyer), isFalse);
  });

  for (final invalidReceipt in [
    {'state': 'prepared'},
    {'state': 'click_intent'},
    {'state': 'unknown'},
    {'state': 'confirmed', 'transferClicked': true},
    {'customer': 'another-buyer'},
    {'targetAccount': 'another-agent'},
    {'attemptId': 'another-attempt'},
    {'transferClicked': true},
    {'timeMs': 1},
  ]) {
    test(
        'an interrupted call cannot resume with invalid journal $invalidReceipt',
        () async {
      final (ticket, log) = await prepared();
      final attempt = await invoked(log);
      await notClickedReceipt(attempt, invalidReceipt);
      final before = await row(log.id);
      expect(
          await db.deferHandoffForReply(
              logId: log.id,
              ticketId: ticket.id,
              resumePhase: 'revalidate_target',
              provenNotClickedAttemptId: attempt['attemptId']),
          isFalse);
      expect(await row(log.id), before);
      expect(await db.handoffReplyContinuation(ticket.id), isNull);
    });
  }

  for (final uncertain in [
    {'status': 'unconfirmed', 'phase': 'unknown'},
    {'acknowledged': 2},
    {'transfer_clicked': 1},
  ]) {
    test('a positive file cannot override an uncertain log $uncertain',
        () async {
      final (ticket, log) = await prepared();
      final attempt = await invoked(log);
      await notClickedReceipt(attempt);
      await (await db.database).update('chat_transfer_logs', uncertain,
          where: 'id=?', whereArgs: [log.id]);
      final before = await row(log.id);
      expect(
          await db.deferHandoffForReply(
              logId: log.id,
              ticketId: ticket.id,
              resumePhase: 'revalidate_target',
              provenNotClickedAttemptId: attempt['attemptId']),
          isFalse);
      expect(await row(log.id), before);
    });
  }

  test('an error description without a durable journal cannot authorize retry',
      () async {
    final (ticket, log) = await prepared();
    final attempt = await invoked(log);
    await File(attempt['receiptPath']!).delete();
    final before = await row(log.id);
    expect(
        await db.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: 'revalidate_target',
            provenNotClickedAttemptId: attempt['attemptId']),
        isFalse);
    expect(await row(log.id), before);
  });

  for (final unsafe in [
    {'status': 'unconfirmed', 'phase': 'unknown'},
    {'acknowledged': 2, 'phase': 'acknowledging'},
    {'transfer_clicked': 1, 'phase': 'unknown'},
    {'attempt_id': 'not-authorized-to-resume', 'phase': 'native_prepared'},
  ]) {
    test('an uncertain physical boundary cannot gain a continuation: $unsafe',
        () async {
      final (ticket, log) = await prepared();
      await (await db.database).update('chat_transfer_logs', unsafe,
          where: 'id=?', whereArgs: [log.id]);
      final before = await row(log.id);
      expect(
          await db.deferHandoffForReply(
              logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
          isFalse);
      expect(await db.handoffReplyContinuation(ticket.id), isNull);
      expect(await row(log.id), before);
      expect(await db.answeredMessageId(buyer), isNull);
    });
  }

  test('a changed exact request invalidates the saved continuation', () async {
    final (ticket, log) = await prepared();
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isTrue);
    await (await db.database).update(
        'human_review_tickets', {'request_message_id': 'another-request'},
        where: 'id=?', whereArgs: [ticket.id]);
    expect(await db.handoffReplyContinuation(ticket.id), isNull);
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isFalse);
    expect((await row(log.id))['target_account'], target);
  });

  test('Start archives the old continuation and preserves a fresh reply queue',
      () async {
    final (ticket, log) = await prepared();
    await db.deferHandoffForReply(
        logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await incoming('new-question',
        senderAt: DateTime.now().toUtc().add(const Duration(seconds: 1)));
    final conversation = (await db.conversations()).single;
    await db.saveDraft(conversation.id, answer('Current business answer'),
        expectedMessageId: 'new-question');
    final fresh = (await (await db.database).query('generated_drafts')).single;
    expect(await db.handoffReplyContinuation(ticket.id), isNull);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isFalse);
    expect((await (await db.database).query('generated_drafts')).single, fresh);
    expect(await db.answeredMessageId(buyer), isNull);
  });

  test('only actual failures consume the bounded transfer count', () async {
    final (ticket, log) = await prepared();
    for (var failure = 1;
        failure <= CaptureDatabase.handoffMaxAttempts;
        failure++) {
      await db.updateChatTransferLog(
          id: log.id,
          status: 'failed',
          phase: 'retryable_preclick',
          error: 'controlled_native_failure');
      await db.releaseHandoffForAi(ticket.id,
          reason: 'controlled_native_failure', countPreclickFailure: true);
      expect((await row(log.id))['preclick_retry_count'], failure);
      if (failure == CaptureDatabase.handoffMaxAttempts) {
        expect((await row(log.id))['preclick_retry_at_ms'], 0);
        expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
        expect(await db.duePreclickHandoffs(), isEmpty);
        break;
      }
      await makeDue(log.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
      expect((await row(log.id))['preclick_retry_count'], failure);
      // An urgent response during this retry must not count as another failure.
      await db.deferHandoffForReply(
          logId: log.id, ticketId: ticket.id, resumePhase: 'inspect_accounts');
      expect((await row(log.id))['preclick_retry_count'], failure);
      await makeDue(log.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    }
    expect(await db.isHumanContacting(buyer), isFalse);
    expect(await db.hasPendingUnanswered(buyer), isTrue);
    expect(await db.answeredMessageId(buyer), isNull);
  });

  test(
      'yielding preserves both customers formal drafts and the other SLA clock',
      () async {
    final (ticket, log) = await prepared();
    await incoming('other-question', customer: 'other');
    for (final conversation in await db.conversations()) {
      final customer = conversation.userId;
      await db.saveDraft(
          conversation.id, answer('Business answer for $customer'),
          expectedMessageId: customer == buyer ? 'request' : 'other-question');
    }
    await db.observePlatformResponse('other', red: true, ageSeconds: 18);
    final drafts =
        await (await db.database).query('generated_drafts', orderBy: 'user_id');
    final clock = await db.platformResponseCycle('other');
    expect(drafts, hasLength(2));
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isTrue);
    expect(
        await (await db.database).query('generated_drafts', orderBy: 'user_id'),
        drafts);
    expect(await db.platformResponseCycle('other'), clock);
    expect(await db.isHumanContacting(buyer), isFalse);
    expect(await db.isHumanContacting('other'), isFalse);
    expect(await db.answeredMessageId(buyer), isNull);
    expect(await db.answeredMessageId('other'), isNull);
  });
}
