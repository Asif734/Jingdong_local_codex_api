import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'controlled-transfer-back-buyer';
  const other = 'controlled-independent-buyer';
  const target = '格志打印机小雨';
  late Directory root;
  late CaptureDatabase db;
  late DateTime at;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v65_transfer_back_');
    db = CaptureDatabase(storageRoot: root);
    at = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 30000,
        isUtc: true);
    await db.beginAutomationSession(startedAt: at);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> incoming(String body, int second,
      [String user = customer]) async {
    final sent = at.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
        stableKey: user,
        customerName: user,
        customerExternalId: user,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: sent.add(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'controlled-$user-$second',
              direction: 'incoming',
              sender: user,
              body: body,
              sentAt: sent,
              axPath: 'controlled current customer text')
        ]));
    return (await db.incomingMessageIdAtTime(user, sent))!;
  }

  Future<HumanReviewTicket> ticket(String requestId, String summary) =>
      db.createHumanReviewTicket(
          userId: customer,
          customerRequest: summary,
          reason: 'Customer explicitly requested human assistance.',
          requestMessageId: requestId);

  Future<void> transferDraft(String end) async {
    final pending = (await db.conversation(customer))!;
    final draft = AiDraft.fromJson({
      'reply': '正在转接，请稍等。',
      'decision': 'human_review_required',
      'human_review_required': true,
      'risk_level': 'high',
      'risk_triggers': ['explicit_human_request'],
      'confidence': 1,
      'model': 'controlled-transfer-decision',
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(pending.id, draft,
            expectedMessageId: end, deliverable: false),
        1);
  }

  Future<Map<String, String>> start(int logId) async {
    final attempt = await db.beginTransferAttempt(
        logId: logId, customer: customer, targetAccount: target);
    await db.markTransferNativeInvoked(logId, attempt['attemptId']!);
    return attempt;
  }

  Future<void> journal(Map<String, String> attempt, String state) =>
      File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': customer,
        'targetAccount': target,
        'state': state,
        'transferClicked': true,
        'timeMs':
            at.add(const Duration(milliseconds: 2500)).millisecondsSinceEpoch,
      }));

  Future<Map<String, Object?>> row(String table, int id) async =>
      (await (await db.database).query(table, where: 'id=?', whereArgs: [id]))
          .single;

  Future<Map<String, Object?>> states() async => {
        for (final work in (await (await db.database).query(
            'automation_session_messages',
            where: 'session_id=? AND user_id=?',
            whereArgs: [db.currentAutomationSessionId, customer])))
          work['message_id']! as String: work['response_state']
      };

  test('confirmed attempt closes a rewritten ticket inside the frozen scope',
      () async {
    final initial = await incoming('请转客服小雨', 1);
    final current = await ticket(initial, 'Original request');
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    final rewritten = await incoming('请转小雨继续处理', 2);
    await transferDraft(rewritten);
    expect((await ticket(rewritten, 'Rewritten before physical click')).id,
        current.id);
    // Match the real incident: the original ticket request was no longer
    // pending when the attempt froze only the later message.
    await (await db.database).update(
        'automation_session_messages', {'response_state': 'answered'},
        where: 'user_id=? AND message_id=?', whereArgs: [customer, initial]);
    final attempt = await start(log.id);
    final returned = await incoming('转回来后，纸张应该怎么装？', 3);
    await incoming('这台打印机可以用 A4 吗？', 4, other);
    await journal(attempt, 'confirmed');

    expect(
        await db.recoverChatTransferAttempts(activeCustomers: {}), {customer});

    expect(
        (await row('human_review_tickets', current.id))['status'], 'contacted');
    expect(await db.humanReviewTickets(), isEmpty);
    expect(await states(),
        {initial: 'answered', rewritten: 'delegated', returned: 'pending'});
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.generationDue(other), isTrue);
    final pending = (await db.conversation(customer))!;
    final token = await db.beginGeneration(
        customer: customer, pendingId: pending.id, batchEndMessageId: returned);
    expect(token, isNotNull);
    final settled = await row('human_review_tickets', current.id);
    expect(await db.recoverChatTransferAttempts(activeCustomers: {}), isEmpty);
    expect(await row('human_review_tickets', current.id), settled);
    expect((await row('pending_customers', pending.id))['generation_token'],
        token);
    expect((await row('chat_transfer_logs', log.id))['phase'], 'confirmed');
    expect(await db.answeredMessageId(customer), isNull);
  });

  test('request after freeze is its own todo, and its red cycle survives',
      () async {
    final initial = await incoming('请转客服小雨', 1);
    final current = await ticket(initial, 'Original request');
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    await transferDraft(initial);
    await db.observePlatformResponse(customer,
        red: true, observedAt: at.add(const Duration(seconds: 2)));
    final oldCycle = await db.platformResponseCycle(customer);
    final attempt = await start(log.id);
    final latest = await incoming('转回来后，我还是要人工改地址', 3);
    expect((await ticket(latest, 'Independent request after freeze')).id,
        current.id);
    await db.observePlatformResponse(customer,
        red: false, observedAt: at.add(const Duration(seconds: 4)));
    await db.observePlatformResponse(customer,
        red: true, observedAt: at.add(const Duration(seconds: 5)));
    final newCycle = await db.platformResponseCycle(customer);
    expect(newCycle!['cycle_id'], isNot(oldCycle!['cycle_id']));
    await journal(attempt, 'confirmed');

    await db.recoverChatTransferAttempts(activeCustomers: {});

    expect(
        (await row('human_review_tickets', current.id))['status'], 'contacted');
    final todo = (await db.humanReviewTickets()).single;
    expect(todo.id, isNot(current.id));
    expect((await row('human_review_tickets', todo.id))['request_message_id'],
        latest);
    expect(await states(), {initial: 'delegated', latest: 'pending'});
    expect(await db.platformResponseCycle(customer), newCycle);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.generationDue(customer), isTrue);
    expect(await db.isHandoffSuppressed(customer, latest), isTrue);
    expect(
        (await db.handoffServiceStatus(customer))!['requiresOperator'], isTrue);
    expect(await db.reserveChatTransferLog(ticket: todo), isNull);
    expect(await db.duePreclickHandoffs(), isEmpty);
  });

  test('return after committed transfer can reopen with a new text question',
      () async {
    final initial = await incoming('请转客服小雨', 1);
    final current = await ticket(initial, 'Original request');
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    final attempt = await start(log.id);
    final key = attempt['attemptId']!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        transferClicked: true,
        expectedAttemptId: 'stale-attempt');
    expect(
        (await row('chat_transfer_logs', log.id))['phase'], 'invoking_native');
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        transferClicked: true,
        expectedAttemptId: key);
    expect(
        await db.settleConfirmedTransfer(
            logId: log.id,
            attemptId: key,
            confirmedAt: at.add(const Duration(milliseconds: 1500))),
        isTrue);
    expect(
        await db.settleConfirmedTransfer(
            logId: log.id,
            attemptId: key,
            confirmedAt: at.add(const Duration(milliseconds: 1500))),
        isFalse);
    expect(await db.conversation(customer), isNull);

    final returned = await incoming('转回来后，还能用 A4 纸打印吗？', 2);
    final pending = (await db.conversation(customer))!;
    expect(await db.generationDue(customer), isTrue);
    expect(
        await db.beginGeneration(
            customer: customer,
            pendingId: pending.id,
            batchEndMessageId: returned),
        isNotNull);
    expect(await states(), {initial: 'delegated', returned: 'pending'});
  });

  test('confirmed journal recovery does not release explicit operator pause',
      () async {
    final initial = await incoming('请转客服小雨', 1);
    final current = await ticket(initial, 'Original request');
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    final attempt = await start(log.id);
    await db.markTicketContacting(current.id);
    await journal(attempt, 'confirmed');

    await db.recoverChatTransferAttempts(activeCustomers: {});

    expect(await db.isHumanContacting(customer), isTrue);
    expect((await row('human_review_tickets', current.id))['status'],
        'contacting');
    expect(await db.generationDue(customer), isFalse);
  });

  test('unknown physical click never delegates or retries the attempt',
      () async {
    final initial = await incoming('请转客服小雨', 1);
    final current = await ticket(initial, 'Original request');
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    final attempt = await start(log.id);
    await journal(attempt, 'unknown');

    await db.recoverChatTransferAttempts(activeCustomers: {});

    expect(await states(), {initial: 'pending'});
    expect((await row('human_review_tickets', current.id))['status'], 'open');
    expect((await row('chat_transfer_logs', log.id))['status'], 'unconfirmed');
    expect(await db.duePreclickHandoffs(), isEmpty);
  });
}
