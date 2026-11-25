import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/jd_v2_payload.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'api-authority-buyer';
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_api_transfer_authority_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> incoming(String body, int second) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
      stableKey: buyer,
      customerName: buyer,
      customerExternalId: buyer,
      automationSessionId: db.currentAutomationSessionId,
      capturedAt: at,
      messages: [
        CapturedMessage(
          stableId: 'authority-$second',
          direction: 'incoming',
          sender: buyer,
          body: body,
          sentAt: at,
          captureEvidenceId: 'authority-frame-$second',
          axPath: 'controlled current customer message',
        )
      ],
    ));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  AiDraft draft(String action) => JdV2Payload.toDraft({
        'action': action,
        'reply_text':
            'I can transfer you to another colleague for invoice help.',
        'transfer_reason': 'troubleshooting_exhausted',
      }, receiptMetadata: {
        'jobId': 'authority-job'
      });

  Future<AutomaticDraftSaveResult> save(String id, AiDraft answer,
      {bool deliverable = false}) async {
    final source = (await db.freezeReadyApiMessage(buyer, id))!;
    final pendingId = (await db.conversation(buyer))!.id;
    final claim = (await db.beginCompletedApiDelivery(
      customer: buyer,
      pendingId: pendingId,
      source: source,
      expectedSessionId: db.currentAutomationSessionId,
    ))!;
    return db.saveCompletedApiDraft(
      pendingId: pendingId,
      customer: buyer,
      draft: answer,
      source: source,
      generationToken: claim.token,
      deliverable: deliverable,
    );
  }

  test(
      'first ordinary message API transfer enters native queue with frozen scope',
      () async {
    final first = await incoming('The paper size is wrong.', 1);
    expect((await save(first, draft('reply_then_transfer'))).outcome,
        AutomaticDraftSaveOutcome.transferOnly);
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'The paper size is wrong.',
        reason: 'API action',
        requestMessageId: first);
    expect((await db.duePreclickHandoffs()).map((t) => t.id), [ticket.id]);
    final row = (await (await db.database).query('generated_drafts')).single;
    final raw = jsonDecode(row['raw_json']! as String) as Map;
    expect(raw['service_message_ids'], [first]);
    expect(raw['action'], 'reply_then_transfer');
    expect(await db.isMessageFormallyAnswered(buyer, first), isFalse);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test('legacy inferred transfer-only draft never authorizes native autoqueue',
      () async {
    final id = await incoming('Please transfer me for invoice help.', 1);
    await save(id, draft('reply'));
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'Please transfer me for invoice help.',
        reason: 'Old local invoice inference',
        requestMessageId: id);
    expect((await db.duePreclickHandoffs()).map((t) => t.id),
        isNot(contains(ticket.id)));
  });

  test('API ticket keeps exact request authority after draft retirement',
      () async {
    final id = await incoming('The paper size is wrong.', 1);
    await save(id, draft('reply_then_transfer'));
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'The paper size is wrong.',
        reason: 'API action',
        requestMessageId: id);
    await db.discardGeneratedDraft(buyer);
    expect(await db.isApiTransferTicket(ticket.id), isTrue);
    final later = await incoming('A new question.', 2);
    await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'A new question.',
        reason: 'Old inference',
        requestMessageId: later);
    expect(await db.isApiTransferTicket(ticket.id), isFalse);
  });

  test('existing API ticket captures proof before its first native attempt',
      () async {
    final id = await incoming('The paper size is wrong.', 1);
    await save(id, draft('reply_then_transfer'));
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'The paper size is wrong.',
        reason: 'API action',
        requestMessageId: id);
    await (await db.database).delete('automation_work_archive',
        where: 'table_name=?', whereArgs: ['api_transfer_authority']);
    expect(await db.isApiTransferTicket(ticket.id), isTrue);
    await db.discardGeneratedDraft(buyer);
    expect(await db.isApiTransferTicket(ticket.id), isTrue);
  });

  test('reverified reception replacement retains API authority through retry',
      () async {
    final oldId = await incoming('Earlier service question.', 1);
    final oldTicket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'Earlier service question.',
        reason: 'API action',
        requestMessageId: oldId);
    final oldLog = (await db.reserveChatTransferLog(ticket: oldTicket))!;
    await db.updateChatTransferLog(
        id: oldLog.id, status: 'unconfirmed', sourceAccount: 'source-agent');
    final id = await incoming('The paper size is wrong.', 2);
    await save(id, draft('reply_then_transfer'));
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'The paper size is wrong.',
        reason: 'API action',
        requestMessageId: id);
    final replacement = (await db.startNewHandoffAfterReceptionProof(
        ticketId: ticket.id,
        sourceAccount: 'source-agent',
        proof: {
          'ready': true,
          'ownershipConfirmed': true,
          'ownershipProof': 'current_enabled_empty_reception_ax',
          'currentCustomer': buyer,
          'activeCustomerId': buyer,
          'sourceAccount': 'source-agent',
          'observedAtMs': DateTime.now().millisecondsSinceEpoch,
        }))!;
    expect(replacement.id, isNot(ticket.id));
    final log = (await db.reserveChatTransferLog(ticket: replacement))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: 'controlled_preclick_failure');
    expect(
        await db.releaseHandoffForAi(replacement.id,
            reason: 'controlled_preclick_failure', countPreclickFailure: true),
        isTrue);
    expect(await db.hasUndeliveredDraft(buyer), isFalse);
    await (await db.database).update('chat_transfer_logs',
        {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1},
        where: 'id=?', whereArgs: [log.id]);
    expect(await db.isApiTransferTicket(replacement.id), isTrue);
    expect((await db.duePreclickHandoffs()).map((t) => t.id), [replacement.id]);
    expect(await db.reserveChatTransferLog(ticket: replacement), isNotNull);
    expect(
        (await (await db.database).query('chat_transfer_logs',
                where: 'id=?', whereArgs: [oldLog.id]))
            .single['status'],
        'unconfirmed');
  });

  test('API pre-click retry stays queued after fallback retires its draft',
      () async {
    final id = await incoming('The paper size is wrong.', 1);
    await save(id, draft('reply_then_transfer'));
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'The paper size is wrong.',
        reason: 'API action',
        requestMessageId: id);
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: 'controlled_preclick_failure');
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'controlled_preclick_failure', countPreclickFailure: true),
        isTrue);
    expect(await db.hasUndeliveredDraft(buyer), isFalse);
    await (await db.database).update('chat_transfer_logs',
        {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1},
        where: 'id=?', whereArgs: [log.id]);
    expect((await db.duePreclickHandoffs()).map((t) => t.id), [ticket.id]);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
  });

  test('reply action with transfer words remains a deliverable reply',
      () async {
    final id = await incoming('Please transfer me for invoice help.', 1);
    expect((await save(id, draft('reply'), deliverable: true)).outcome,
        AutomaticDraftSaveOutcome.ready);
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    expect(delivery.draft.reply,
        'I can transfer you to another colleague for invoice help.');
    expect(await db.duePreclickHandoffs(), isEmpty);
  });

  test('legacy request audit never grants transfer after repeated inputs',
      () async {
    for (var i = 0; i < 5; i++) {
      expect(
          await db.recordHumanTransferRequest(
              userId: buyer,
              messageId: 'request-$i',
              requestedAt: start.add(Duration(seconds: i))),
          isFalse);
    }
    expect(
        await db.recordHumanTransferRequest(
            userId: buyer,
            messageId: 'request-0',
            messageAliases: ['alias-0'],
            requestedAt: start),
        isFalse);
    final events =
        await (await db.database).query('human_transfer_request_events');
    expect(events.length, 6);
    expect(events.map((e) => e['was_repeat']), everyElement(0));
    expect(await (await db.database).query('human_transfer_requests'), isEmpty);
  });
}
