import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'buyer';
  const source = 'source-agent';
  const target = 'target-agent';
  late Directory root;
  late CaptureDatabase db;
  late String session;
  late String messageId;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v55_transfer_open_');
    db = CaptureDatabase(storageRoot: root);
    session =
        await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  AiDraft answer(
          [String text = 'Select the paper source in printer settings.']) =>
      AiDraft.fromJson({
        'reply': text,
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-v55',
        'reply_media_dependency_keys': <String, String>{},
      }, mediaBaseUrl: Uri());

  Future<String> receive(String buyer) async {
    final at = DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        capturedAt: at,
        automationSessionId: session,
        messages: [
          CapturedMessage(
              stableId: '$buyer-request',
              direction: 'incoming',
              body: 'Please transfer me and help select the paper source.',
              sender: buyer,
              sentAt: at,
              captureEvidenceId: '$buyer-frame',
              axPath: 'controlled customer input'),
        ]));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<(HumanReviewTicket, ChatTransferLog)> prepare(
      {bool transferDecision = false}) async {
    messageId = await receive(customer);
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'Controlled authorized transfer request',
        reason: 'Authorized order service',
        requestMessageId: messageId);
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'ready',
        sourceAccount: source,
        targetAccount: target);
    await db.setTransferAcknowledgement(log.id, 1);
    if (transferDecision) {
      final pending = (await db.conversation(customer))!;
      expect(
          await db.saveDraft(pending.id, answer('Internal transfer decision'),
              expectedMessageId: messageId, deliverable: false),
          1);
    }
    return (ticket, log);
  }

  Future<Map<String, Object?>> row(int id) async => (await (await db.database)
          .query('chat_transfer_logs', where: 'id=?', whereArgs: [id]))
      .single;

  Future<void> setRow(int id, Map<String, Object?> values) async {
    await (await db.database)
        .update('chat_transfer_logs', values, where: 'id=?', whereArgs: [id]);
  }

  Future<void> makeDue(int id) => setRow(
      id, {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1});

  Future<bool> defer(HumanReviewTicket ticket, ChatTransferLog log,
          {String resume = 'revalidate_target'}) =>
      db.deferHandoffForOpenRecovery(
          logId: log.id,
          ticketId: ticket.id,
          resumePhase: resume,
          reason: 'conversation_open_pending:header_not_settled');

  test('twelve open recoveries keep target and ACK without consuming attempts',
      () async {
    final (ticket, log) = await prepare();
    final sql = await db.database;
    final work = await sql.query('automation_session_messages');
    for (var pending = 0; pending < 12; pending++) {
      expect(await defer(ticket, log), isTrue);
      final saved = await row(log.id);
      expect(saved['status'], 'deferred');
      expect(saved['phase'], 'open_deferred:revalidate_target');
      expect(saved['source_account'], source);
      expect(saved['target_account'], target);
      expect(saved['acknowledged'], 1);
      expect(saved['preclick_retry_count'], 0);
      expect(await db.hasResumableHandoffCheckpoint(), isFalse,
          reason: 'AX waiting cannot reserve the formal-reply UI slot');
      expect((await db.handoffServiceStatus(customer))!['state'],
          'conversation_open_pending');
      expect((await db.handoffServiceStatus(customer))!['requiresOperator'],
          isFalse);
      expect((await db.handoffReplyContinuation(ticket.id))!['resumePhase'],
          'revalidate_target');
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
      await makeDue(log.id);
      expect((await db.duePreclickHandoffs()).single.id, ticket.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
      expect((await row(log.id))['phase'], 'open_resuming:revalidate_target');
      expect(await db.hasResumableHandoffCheckpoint(), isFalse);
    }
    expect(await sql.query('automation_session_messages'), work);
    expect(await sql.query('delivery_attempts'), isEmpty);
    expect(await db.answeredMessageId(customer), isNull);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(
        await db.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: 'revalidate_target'),
        isTrue);
    expect(await db.hasResumableHandoffCheckpoint(), isTrue,
        reason: 'A real response deadline still retains its reply checkpoint');
    await makeDue(log.id);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: 'actual_native_failure');
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'actual_native_failure', countPreclickFailure: true),
        isTrue);
    expect((await row(log.id))['preclick_retry_count'], 1);
    expect(await db.hasResumableHandoffCheckpoint(), isFalse);
  });

  test('only the transfer decision is retired so an actual answer can generate',
      () async {
    final (ticket, log) = await prepare(transferDecision: true);
    final sql = await db.database;
    final decision = (await sql.query('generated_drafts')).single;
    expect(decision['delivery_state'], 'transfer_only');
    expect(await defer(ticket, log), isTrue);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    final archived = (await sql.query('automation_work_archive',
            where: "table_name='generated_drafts'"))
        .single;
    expect(jsonDecode(archived['row_json']! as String), decision);
    final fallback = (await sql.query('handoff_ai_fallbacks')).single;
    expect(fallback['reason'], 'conversation_open_pending');
    expect(fallback['unknown_click'], 0);
    expect(fallback['yield_count'], 0);
    expect(await db.isHandoffSuppressed(customer, messageId), isTrue);
    expect(await db.generationDue(customer), isTrue);
    final pending = (await db.conversation(customer))!;
    final token = (await db.beginGeneration(
        customer: customer,
        pendingId: pending.id,
        batchEndMessageId: messageId))!;
    final draft = await db.prepareAutomaticDraft(customer, answer());
    expect(
        (await db.saveAutomaticDraft(pending.id, draft,
                expectedUserId: customer,
                expectedMessageId: messageId,
                generationToken: token))
            .outcome,
        AutomaticDraftSaveOutcome.ready);
    await db.abandonGeneration(customer, token);
    final ready = (await db.nextReadyDelivery(userId: customer))!;
    expect(ready.draft.reply, answer().reply);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(
        (await sql.query('automation_session_messages')).single['message_id'],
        messageId);
    expect(await db.answeredMessageId(customer), isNull);
    expect((await row(log.id))['phase'], 'open_deferred:revalidate_target');
  });

  test('already-ready answers and both customers clocks survive open recovery',
      () async {
    final (ticket, log) = await prepare();
    await receive('other');
    for (final conversation in await db.conversations()) {
      await db.saveDraft(
          conversation.id, answer('Answer for ${conversation.userId}'),
          expectedMessageId: await db.pendingMessageId(conversation.userId));
    }
    await db.observePlatformResponse('other', red: true, ageSeconds: 18);
    final sql = await db.database;
    final drafts = await sql.query('generated_drafts', orderBy: 'user_id');
    final cycle = await db.platformResponseCycle('other');
    expect(await defer(ticket, log), isTrue);
    expect(await sql.query('generated_drafts', orderBy: 'user_id'), drafts);
    expect(await db.platformResponseCycle('other'), cycle);
    expect(
        await sql.query('automation_work_archive',
            where: "table_name='generated_drafts'"),
        isEmpty);
    expect((await db.nextReadyDelivery(userId: customer))!.userId, customer);
    expect(await db.unansweredWorkCounts(), {customer: 1, 'other': 1});
  });

  for (final unsafe in <Map<String, Object?>>[
    {'transfer_clicked': 1},
    {'acknowledged': 2, 'phase': 'acknowledging'},
    {'status': 'unconfirmed', 'phase': 'unknown'},
    {'phase': 'invoking_native', 'attempt_id': 'invoked'},
    {'status': 'cancelled'},
    {'owner_pid': 999999},
    {'preclick_retry_count': CaptureDatabase.handoffMaxAttempts},
  ]) {
    test('unsafe transfer boundary cannot become open recovery: $unsafe',
        () async {
      final (ticket, log) = await prepare();
      await setRow(log.id, unsafe);
      final before = await row(log.id);
      expect(await defer(ticket, log), isFalse);
      expect(await row(log.id), before);
      expect(await (await db.database).query('handoff_ai_fallbacks'), isEmpty);
      expect(await db.unansweredWorkCounts(), {customer: 1});
    });
  }

  test(
      'operator ownership, a different request and a new session reject recovery',
      () async {
    final (ticket, log) = await prepare();
    final sql = await db.database;
    await db.markTicketHandoffPending(ticket.id);
    await sql.update('conversation_control', {'state': 'human_contacting'},
        where: 'user_id=?', whereArgs: [customer]);
    expect(await defer(ticket, log), isFalse);
    await sql.update('conversation_control', {'state': 'ai_active'},
        where: 'user_id=?', whereArgs: [customer]);
    await sql.update(
        'human_review_tickets', {'request_message_id': 'another-request'},
        where: 'id=?', whereArgs: [ticket.id]);
    expect(await defer(ticket, log), isFalse);
    await sql.update('human_review_tickets', {'request_message_id': messageId},
        where: 'id=?', whereArgs: [ticket.id]);
    await sql.update('human_review_tickets', {'status': 'closed'},
        where: 'id=?', whereArgs: [ticket.id]);
    expect(await defer(ticket, log), isFalse);
    await sql.update('human_review_tickets', {'status': 'open'},
        where: 'id=?', whereArgs: [ticket.id]);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await defer(ticket, log), isFalse);
  });

  test('prepared but never invoked journal is retained while its lease clears',
      () async {
    final (ticket, log) = await prepare();
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: customer, targetAccount: target);
    final file = File(attempt['receiptPath']!);
    final bytes = await file.readAsString();
    final sql = await db.database;
    final scope = await sql.query('automation_reply_inputs',
        where: 'owner_id=?', whereArgs: ['transfer:${attempt['attemptId']}']);
    expect(scope, isNotEmpty);
    expect(await defer(ticket, log), isTrue);
    expect((await row(log.id))['attempt_id'], isNull);
    expect((await row(log.id))['acknowledged'], 1);
    expect(await file.readAsString(), bytes);
    expect(
        await sql.query('automation_reply_inputs',
            where: 'owner_id=?',
            whereArgs: ['transfer:${attempt['attemptId']}']),
        scope);
  });

  for (final journalState in ['invoked', 'unknown', 'missing']) {
    test('an invoked or uncertain journal is never cleared: $journalState',
        () async {
      final (ticket, log) = await prepare();
      final attempt = await db.beginTransferAttempt(
          logId: log.id, customer: customer, targetAccount: target);
      final file = File(attempt['receiptPath']!);
      if (journalState == 'invoked') {
        await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
      } else if (journalState == 'missing') {
        await file.delete();
      } else {
        final receipt = jsonDecode(await file.readAsString()) as Map;
        receipt['state'] = 'unknown';
        receipt['transferClicked'] = true;
        await file.writeAsString(jsonEncode(receipt), flush: true);
      }
      final before = await row(log.id);
      final receipt = await file.exists() ? await file.readAsString() : null;
      expect(await defer(ticket, log), isFalse);
      expect(await row(log.id), before);
      if (receipt != null) expect(await file.readAsString(), receipt);
    });
  }
}
