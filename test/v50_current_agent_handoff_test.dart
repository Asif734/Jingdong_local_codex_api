import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/named_agent_request.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'controlled-named-agent-buyer';
  const account = '格志打印机小耿';
  final at = DateTime.utc(2026, 11, 10, 4);
  late Directory root;
  late CaptureDatabase db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v50_current_agent_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<String> incoming(String body, int second) async {
    final sent = at.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: sent.add(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'controlled-$second',
              direction: 'incoming',
              sender: customer,
              body: body,
              sentAt: sent,
              axPath: 'controlled current customer text')
        ]));
    return (await db.incomingMessageIdAtTime(customer, sent))!;
  }

  Future<HumanReviewTicket> ticket(String requestId,
          {String reason = 'Customer explicitly requested human assistance.',
          String summary = 'Old summary: 转小华'}) =>
      db.createHumanReviewTicket(
          userId: customer,
          customerRequest: summary,
          reason: reason,
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

  Future<Map<String, Object?>> ticketRow(int id) async =>
      (await (await db.database)
              .query('human_review_tickets', where: 'id=?', whereArgs: [id]))
          .single;

  test('bound request text wins over old names in a ticket summary', () async {
    final request = await incoming('请转小耿', 1);
    final current = await ticket(request, summary: 'incoming: 以前转小华');
    expect(await db.handoffRequestText(current.id), '请转小耿');
    expect(
        await db.satisfyCurrentAgentHandoff(current.id,
            currentServiceAccount: account, requestedTarget: '小耿'),
        isTrue);
    expect((await ticketRow(current.id))['status'], 'current_agent');
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.answeredMessageId(customer), isNull);
  });

  test(
      'a literal account containing order letters is not an order authority task',
      () async {
    final requestId = await incoming('Please transfer me to Border', 1);
    final current = await ticket(requestId,
        reason: 'Customer explicitly requested human agent Border.');
    final named = NamedAgentRequest.parse('Please transfer me to Border')!;
    expect(
        await db.satisfyCurrentAgentHandoff(current.id,
            currentServiceAccount: 'Shop:Border',
            requestedTarget: named.target),
        isTrue);
  });

  test('service answers a pure self request without CLI or transfer counting',
      () async {
    final requestId = await incoming('请转小耿', 1);
    final pending = (await db.conversation(customer))!;
    final token = await db.beginGeneration(
        customer: customer,
        pendingId: pending.id,
        batchEndMessageId: requestId);
    expect(token, isNotNull);
    final service = CodexReplyService(
        executable: '/must-not-run-for-current-agent',
        workspace: root,
        knowledgeDirectory: await Directory('${root.path}/knowledge').create(),
        outputSchema: File('${root.path}/reply.schema.json'));
    final draft = await service.generate(
        conversation: pending,
        database: db,
        batchEndMessageId: requestId,
        currentServiceAccount: account);
    expect(draft.model, 'jd-current-service-agent-v1');
    expect(draft.reply, contains(account));
    expect(codexHumanTransferRequestIds(draft), isEmpty);
    expect(await (await db.database).query('human_transfer_requests'), isEmpty);
    expect(await db.hasPendingUnanswered(customer), isTrue,
        reason: 'Generation alone cannot mark any customer question answered.');
  });

  test('self target retires only the transfer decision and keeps all questions',
      () async {
    final request = await incoming('转小耿', 1);
    final problem = await incoming('打印不出来，需要怎么检查？', 2);
    await transferDraft(problem);
    final current = await ticket(request);
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    expect(
        await db.satisfyCurrentAgentHandoff(current.id,
            currentServiceAccount: account, requestedTarget: '小耿'),
        isTrue);
    final sql = await db.database;
    expect(await sql.query('generated_drafts'), isEmpty);
    expect(
        (await sql.query('automation_session_messages',
                where: 'session_id=? AND user_id=?',
                whereArgs: [db.currentAutomationSessionId, customer]))
            .where((row) => row['response_state'] == 'pending'),
        hasLength(2));
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.answeredMessageId(customer), isNull);
    final saved = (await sql
            .query('chat_transfer_logs', where: 'id=?', whereArgs: [log.id]))
        .single;
    expect(saved['status'], 'cancelled');
    expect(saved['phase'], 'already_current_agent');
    expect(saved['transfer_clicked'], 0);
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(await sql.query('automation_work_archive'), isNotEmpty);
  });

  test('another named account and independent order authority stay unchanged',
      () async {
    final request = await incoming('转小关', 1);
    final other = await ticket(request, summary: 'incoming: 转小耿');
    expect(
        await db.satisfyCurrentAgentHandoff(other.id,
            currentServiceAccount: account, requestedTarget: '小关'),
        isFalse);
    expect((await ticketRow(other.id))['status'], 'open');
    final orderId = await incoming('转小耿，订单退款怎么处理？', 2);
    final order = await ticket(orderId, reason: 'order_service_handoff');
    expect(
        await db.satisfyCurrentAgentHandoff(order.id,
            currentServiceAccount: account, requestedTarget: '小耿'),
        isFalse);
    expect((await ticketRow(order.id))['status'], 'open');
    expect(await db.hasPendingUnanswered(customer), isTrue);
  });

  test(
      'a named self order request retains review without redirecting elsewhere',
      () async {
    final request = await incoming('转小耿，我要取消订单', 1);
    final problem = await incoming('同时打印不出来，应该怎么检查？', 2);
    await transferDraft(problem);
    final current = await ticket(request, reason: 'order_service_handoff');
    expect(
        await db.satisfyCurrentAgentHandoff(current.id,
            currentServiceAccount: account,
            requestedTarget: '小耿',
            preserveAuthorityReview: true),
        isTrue);
    final saved = await ticketRow(current.id);
    expect(saved['status'], 'open');
    expect(saved['assigned_to'], account);
    expect(saved['reason'], 'order_service_handoff');
    expect(await (await db.database).query('generated_drafts'), isEmpty);
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.answeredMessageId(customer), isNull);
    expect((await db.unansweredWorkCounts())[customer], 2);
    final status = (await db.handoffServiceStatus(customer))!;
    expect(status['state'], 'current_agent_review_required');
    expect(status['requiresOperator'], isTrue);
    expect(status['transferClicked'], 0);
    expect(status['handoffCompleted'], isFalse);
    expect(await db.isHandoffSuppressed(customer, request), isTrue);
    expect((await db.handoffFallbackContext(customer))!['reason'],
        'current_agent_review_required');
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(await db.reserveChatTransferLog(ticket: current), isNull,
        reason:
            'Review is open, but its named automatic transfer is finished.');
  });

  for (final clicked in [true, false]) {
    test('clicked or unknown transfer outcome is retained; clicked=$clicked',
        () async {
      final request = await incoming('转小耿', 1);
      await transferDraft(request);
      final current = await ticket(request);
      final log = (await db.reserveChatTransferLog(ticket: current))!;
      final sql = await db.database;
      await sql.update(
          'chat_transfer_logs',
          {
            'status': clicked ? 'transferred' : 'unconfirmed',
            'phase': clicked ? 'confirmed' : 'native_invoked',
            'transfer_clicked': clicked ? 1 : 0,
          },
          where: 'id=?',
          whereArgs: [log.id]);
      expect(
          await db.satisfyCurrentAgentHandoff(current.id,
              currentServiceAccount: account,
              requestedTarget: NamedAgentRequest.parse('转小耿')!.target),
          isFalse);
      expect((await ticketRow(current.id))['status'], 'open');
      expect(await sql.query('generated_drafts'), hasLength(1));
      final saved = (await sql
              .query('chat_transfer_logs', where: 'id=?', whereArgs: [log.id]))
          .single;
      expect(saved['status'], clicked ? 'transferred' : 'unconfirmed');
    });
  }

  test('positive native journal cannot be hidden by a stale preclick row',
      () async {
    final request = await incoming('转小耿', 1);
    final current = await ticket(request);
    final log = (await db.reserveChatTransferLog(ticket: current))!;
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: customer, targetAccount: '格志打印机小关');
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'targetAccount': '格志打印机小关',
      'state': 'confirmed',
      'transferClicked': true,
    }));
    expect(
        await db.satisfyCurrentAgentHandoff(current.id,
            currentServiceAccount: account, requestedTarget: '小耿'),
        isFalse);
    expect((await ticketRow(current.id))['status'], 'open');
    expect(await File(attempt['receiptPath']!).exists(), isTrue);
  });
}
