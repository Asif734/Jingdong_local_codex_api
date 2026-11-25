import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/named_agent_request.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('after-sales actions are not literal staff names', () {
    for (final request in [
      '请联系售后办理换货',
      '转售后申请退货',
      '找客服办理退换货',
      '请转退货客服',
    ]) {
      expect(NamedAgentRequest.parse(request), isNull, reason: request);
    }
    expect(NamedAgentRequest.parse('请联系小关办理换货')?.target, '小关');
  });
  const buyer = 'no-order-customer';
  late Directory root;
  late CaptureDatabase db;
  late CodexReplyService service;
  late DateTime start;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v57_transfer_no_order_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
        isUtc: true);
    session = await db.beginAutomationSession(startedAt: start);
    service = CodexReplyService(
        executable: '/unused-policy-only',
        workspace: root,
        knowledgeDirectory: root,
        outputSchema: File('${root.path}/unused-schema'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> receive(String body, int second) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        automationSessionId: session,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'controlled-$second',
              direction: 'incoming',
              sender: buyer,
              body: body,
              sentAt: at,
              captureEvidenceId: 'frame-$second',
              axPath: 'controlled original customer text')
        ]));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  for (final requests in [
    ['请帮我转人工', '我没有订单号，请再次帮我转人工'],
    ['我要退货，请转客服', '没有订单号也要退货，帮我转客服'],
    ['我要换货，请转客服', '不提供订单号，仍然要求换货并转客服'],
    ['Please transfer me.', 'I have no order number. Transfer me anyway.'],
  ]) {
    test(
        'two requests can reserve transfer without order details: ${requests[0]}',
        () async {
      final first = await receive(requests[0], 1);
      expect(
          await db.recordHumanTransferRequest(
              userId: buyer,
              messageId: first,
              requestedAt: start.add(const Duration(seconds: 1))),
          isFalse);
      final second = await receive(requests[1], 4);
      final pending = (await db.conversation(buyer))!;
      final token = (await db.beginGeneration(
          customer: buyer, pendingId: pending.id, batchEndMessageId: second))!;
      final model = AiDraft.fromJson({
        'reply': 'Please provide an order number and the return reason first.',
        'decision': 'ask_clarification',
        'confidence': 1,
        'risk_level': 'low',
        'required_slots': ['order number', 'return reason', 'product model'],
        'human_transfer_request_message_ids': [second],
        'model': 'controlled-v57',
      }, mediaBaseUrl: Uri());
      final recorded = await recordFrozenHumanTransferRequests(
          draft: model,
          frozenInputs: await db.generationMessages(buyer),
          database: db,
          customer: buyer);
      expect(recorded.repeatedRequest, isTrue);
      final decision = service.enforceHumanReviewPolicy(
          recorded.draft, requests[1],
          language: CustomerLanguage.chinese,
          humanTransferRequested: recorded.hasRequest,
          repeatedHumanTransferRequest: recorded.repeatedRequest);
      expect(isExplicitHumanTransfer(decision), isTrue);
      expect((jsonDecode(decision.rawJson) as Map)['required_slots'], isEmpty);
      final prepared = await db.prepareAutomaticDraft(buyer, decision);
      final saved = await db.saveAutomaticDraft(pending.id, prepared,
          expectedMessageId: second,
          expectedUserId: buyer,
          generationToken: token,
          deliverable: false);
      expect(saved.outcome, AutomaticDraftSaveOutcome.transferOnly);
      expect(await db.nextReadyDelivery(), isNull,
          reason: 'An internal transfer decision is not a formal answer.');
      expect(await db.unansweredWorkCounts(), {buyer: 2});
      final ticket = await db.createHumanReviewTicket(
          userId: buyer,
          customerRequest: requests.join('\n'),
          reason: 'Customer confirmed the transfer twice without an order ID.',
          requestMessageId: second);
      await db.markTicketHandoffPending(ticket.id);
      expect(await db.isHandoffExecutionCurrent(ticket.id), isTrue);
      final reservation = await db.reserveChatTransferLog(ticket: ticket);
      expect(reservation, isNotNull);
      expect(reservation!.status, 'pending');
      expect(await db.isMessageFormallyAnswered(buyer, second), isFalse);
    });
  }

  for (final scenario in [
    (status: 'sent', kind: 'transfer'),
    (status: 'draft', kind: 'transfer'),
    (status: 'sent', kind: 'after_sales'),
    (status: 'draft', kind: 'after_sales'),
  ]) {
    final status = scenario.status;
    test('named colleague confirmation preserves sent provenance: $scenario',
        () async {
      final original = scenario.kind == 'after_sales' ? '我要退货，请转小关' : '请转小关';
      final first = await receive(original, 1);
      final store = await db.history;
      final document = (await store.read(buyer))!;
      (document['messages'] as List).add({
        'id': 'controlled-intent-confirmation',
        'direction': 'outgoing',
        'source': 'generated_reply',
        'delivery_status': status,
        'sent_at': start.add(const Duration(seconds: 2)).toIso8601String(),
        'body': '请确认，您是希望转接客服同事吗？',
        'reply_metadata': {
          'raw_response': {
            'model': 'jd-two-request-handoff-v1',
            'service_session_id': session,
            'handoff_intent_confirmation': true,
            'handoff_confirmation_kind': scenario.kind,
            'handoff_request_message_ids': [first],
          },
        },
      });
      await File(
              '${store.conversationsDirectory.path}/${store.safeUserId(buyer)}.json')
          .writeAsString(jsonEncode(document), flush: true);
      final confirmation = await receive('确认', 4);
      final ticket = await db.createHumanReviewTicket(
          userId: buyer,
          customerRequest: 'Unrelated summary may mention another colleague.',
          reason: 'Customer confirmation',
          requestMessageId: confirmation);
      expect(await db.handoffRequestText(ticket.id),
          status == 'sent' ? original : '确认');
    });
  }
}
