import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  const source = 'source-agent';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_reception_session_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String id) async {
    final at = DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
      stableKey: 'buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: at,
      automationSessionId: db.currentAutomationSessionId,
      messages: [
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: 'Arrange service for request $id',
            sentAt: at,
            axPath: 'AX fixture')
      ],
    ));
  }

  Future<(HumanReviewTicket, ChatTransferLog)> unknown() async {
    await incoming('old-request');
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'Arrange service',
        reason: 'Authorized service required',
        requestMessageId: 'old-request');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id, status: 'unconfirmed', sourceAccount: source);
    return (ticket, log);
  }

  Map<String, Object?> proof() => {
        'ready': true,
        'ownershipConfirmed': true,
        'ownershipProof': 'current_enabled_empty_reception_ax',
        'currentCustomer': 'buyer',
        'activeCustomerId': 'buyer',
        'sourceAccount': source,
        'observedAtMs': DateTime.now().millisecondsSinceEpoch,
      };

  test('fresh AX ownership registers the new task in its current session',
      () async {
    final (old, oldLog) = await unknown();
    await incoming('new-request');
    final request = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'Arrange service for the new question',
        reason: 'Authorized service required',
        requestMessageId: 'new-request');
    final next = await db.startNewHandoffAfterReceptionProof(
        ticketId: request.id, proof: proof(), sourceAccount: source);
    expect(next, isNotNull);
    expect(next!.id, isNot(old.id));
    expect(await db.isCurrentSessionTicket(next.id), isTrue);
    expect(await db.isHandoffExecutionCurrent(next.id), isTrue);
    final nextLog = await db.reserveChatTransferLog(ticket: next);
    expect(nextLog, isNotNull);
    expect(nextLog!.id, isNot(oldLog.id));
    final sql = await db.database;
    expect(
        (await sql.query('chat_transfer_logs',
                where: 'id=?', whereArgs: [oldLog.id]))
            .single['status'],
        'unconfirmed');
    expect(await db.pendingMessageId('buyer'), 'new-request');
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(await db.isHumanContacting('buyer'), isFalse);
  });
  test('a previous-session ticket cannot gain new-session transfer authority',
      () async {
    final (old, _) = await unknown();
    await incoming('later-old-request');
    await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'Old run follow-up',
        reason: 'Service',
        requestMessageId: 'later-old-request');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await incoming('current-question');
    expect(
        await db.startNewHandoffAfterReceptionProof(
            ticketId: old.id, proof: proof(), sourceAccount: source),
        isNull);
    expect(await db.pendingMessageId('buyer'), 'current-question');
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(await db.humanReviewTickets(), isEmpty);
  });
  test('a current ticket cannot authorize a request absent from current input',
      () async {
    final (old, _) = await unknown();
    await expectLater(
        db.createHumanReviewTicket(
            userId: 'buyer',
            customerRequest: 'An unobserved stale request',
            reason: 'Service',
            requestMessageId: 'unobserved-request'),
        throwsStateError);
    // Keep the real current ticket's membership, but simulate a stale stored
    // request reference so the later reception-proof guard is checked too.
    await (await db.database).update(
        'human_review_tickets', {'request_message_id': 'unobserved-request'},
        where: 'id=?', whereArgs: [old.id]);
    expect(
        await db.startNewHandoffAfterReceptionProof(
            ticketId: old.id, proof: proof(), sourceAccount: source),
        isNull);
    expect((await db.humanReviewTickets()).single.id, old.id);
    expect(await db.pendingMessageId('buyer'), 'old-request');
  });
}
