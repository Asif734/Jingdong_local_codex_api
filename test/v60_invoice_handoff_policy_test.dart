import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/invoice_request_policy.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
  Map<String, dynamic> incoming(String id, String text, int second) => {
        'id': id,
        'direction': 'incoming',
        'sender': 'buyer',
        'body': text,
        'sent_at': at.add(Duration(seconds: second)).toIso8601String(),
        'captured_at': at.add(Duration(seconds: second)).toIso8601String(),
        'text_origin': 'customer_text',
        'media': <Object?>[],
      };
  Map<String, dynamic> sent(InvoiceCollection value, int second,
          {String session = 'run', String state = 'submitted'}) =>
      {
        'id': 'out-$second',
        'direction': 'outgoing',
        'source': 'generated_reply',
        'delivery_status': state,
        'sent_at': at.add(Duration(seconds: second)).toIso8601String(),
        'body': value.clarification(CustomerLanguage.chinese),
        'reply_metadata': {
          'raw_response': jsonDecode(
              value.draft(CustomerLanguage.chinese, sessionId: session).rawJson)
        }
      };
  InvoiceCollection? resolve(List<Map<String, dynamic>> history,
          List<Map<String, dynamic>> current) =>
      InvoiceRequestPolicy.resolve(
          history: history,
          currentInputs: current,
          customer: 'buyer',
          sessionId: 'run');
  Map<String, dynamic> raw(AiDraft draft) => jsonDecode(draft.rawJson);

  test('explicit request collects details without transferring immediately',
      () {
    final request = incoming('request', '我要开票', 0);
    final value = resolve([request], [request])!;
    expect(value.complete, isFalse);
    expect(value.missingSlots,
        containsAll(['invoice_order', 'invoice_type', 'invoice_title']));
    expect(value.missingSlots, isNot(contains('invoice_bank_account')));
    expect(isExplicitHumanTransfer(value.draft(CustomerLanguage.chinese)),
        isFalse);
  });

  for (final text in [
    '我要发票',
    '帮我开个发票',
    '麻烦开一张发票',
    'Can you issue an invoice for me?',
    'Invoice please',
    '帮我开专票',
    '我要开普票',
    '我要专票',
    '开票资料如下：'
  ]) {
    test('ordinary explicit invoice wording starts collection: $text', () {
      final request = incoming('request', text, 0);
      expect(resolve([request], [request]), isNotNull);
    });
  }

  test('ordinary personal invoice needs no tax or bank details', () {
    final request =
        incoming('request', '我要开票\n订单号：123456789012\n个人普票\n抬头：张三', 0);
    final value = resolve([request], [request])!;
    expect(value.complete, isTrue);
    final draft = value.draft(CustomerLanguage.chinese, sessionId: 'run');
    expect(isExplicitHumanTransfer(draft), isTrue);
    expect(raw(draft)['human_transfer_request_message_ids'], isEmpty);
    expect(raw(draft)['required_slots'], isEmpty);
    expect(draft.reply, isNot(contains('已开具')));
  });

  test('ordinary company invoice asks only its missing tax ID', () {
    final request =
        incoming('request', '请帮我开发票\n订单号：123456789012\n普通发票\n公司名称：格志科技有限公司', 0);
    final value = resolve([request], [request])!;
    expect(value.missingSlots, ['invoice_tax_id']);
    expect(value.clarification(CustomerLanguage.chinese), contains('税号'));
    expect(
        value.clarification(CustomerLanguage.chinese), isNot(contains('开户行')));
  });

  test('special VAT invoice collects existing knowledge requirements', () {
    final request = incoming(
        'request',
        '我要开票\n订单号：123456789012\n增值税专用发票\n公司名称：格志科技有限公司\n税号：91330100123456789A',
        0);
    final value = resolve([request], [request])!;
    expect(value.missingSlots, [
      'invoice_general_taxpayer',
      'invoice_bank_name',
      'invoice_bank_account',
      'invoice_company_address',
      'invoice_contact_phone'
    ]);
    final reply = sent(value, 1);
    final details = incoming(
        'details',
        '一般纳税人资格：是\n开户行：中国银行杭州支行\n银行账号：1234567890123456\n公司地址：杭州市西湖区测试路1号\n联系电话：057112345678',
        2);
    final complete = resolve([request, reply, details], [details])!;
    expect(complete.complete, isTrue);
    expect(isExplicitHumanTransfer(complete.draft(CustomerLanguage.chinese)),
        isTrue);
  });

  test(
      'incremental detail-only message continues the genuinely sent collection',
      () {
    final request = incoming('request', '我要开票\n订单号：123456789012\n个人普票', 0);
    final first = resolve([request], [request])!;
    expect(first.missingSlots, ['invoice_title']);
    final reply = sent(first, 1);
    final details = incoming('details', '张三', 2);
    final complete = resolve([request, reply, details], [details])!;
    expect(complete.complete, isTrue);
    expect(complete.currentTurnInvoiceOnly, isTrue);
  });

  test('ordinary company tax ID can arrive on its own', () {
    final request =
        incoming('request', '我要开票\n订单号：123456789012\n普票\n公司名称：格志科技有限公司', 0);
    final first = resolve([request], [request])!;
    final details = incoming('details', '91330100123456789A', 2);
    final complete = resolve([request, sent(first, 1), details], [details])!;
    expect(complete.complete, isTrue);
    expect(complete.facts['invoice_tax_id'], '91330100123456789A');
  });

  test('unconfirmed or old-run outgoing text cannot authorize a continuation',
      () {
    final request = incoming('request', '我要开票', 0);
    final first = resolve([request], [request])!;
    final details = incoming('details', '抬头：张三', 2);
    expect(
        resolve([request, sent(first, 1, state: 'ready'), details], [details]),
        isNull);
    expect(
        resolve(
            [request, sent(first, 1, session: 'old-run'), details], [details]),
        isNull);
  });

  for (final text in ['ok', '打印机坏了', '怎么连接蓝牙？']) {
    test('a pending title question does not consume unrelated text: $text', () {
      final request = incoming('request', '我要开票\n订单号：123456789012\n个人普票', 0);
      final first = resolve([request], [request])!;
      final next = incoming('next', text, 2);
      expect(resolve([request, sent(first, 1), next], [next]), isNull);
    });
  }

  test('an older invoice and its details cannot populate a new invoice request',
      () {
    final old = incoming('old', '我要开票\n订单号：111111111111\n个人普票\n抬头：旧客户', 0);
    final next = incoming('next', '我要开票', 5);
    final value = resolve([old, next], [next])!;
    expect(value.facts, isEmpty);
    expect(value.requestMessageId, 'next');
  });

  test('a changed order does not inherit the old order invoice fields', () {
    final request =
        incoming('request', '我要开票\n订单号：111111111111\n普通发票\n公司名称：旧公司', 0);
    final first = resolve([request], [request])!;
    final change = incoming('change', '订单号：222222222222', 2);
    final value = resolve([request, sent(first, 1), change], [change])!;
    expect(value.facts, {'invoice_order': '222222222222'});
    expect(value.complete, isFalse);
  });

  test('latest cancellation ends collection', () {
    final request = incoming('request', '我要开票', 0);
    final cancellation = incoming('cancel', '不用开票了', 2);
    expect(resolve([request, cancellation], [cancellation]), isNull);
  });

  test('media-derived text and other customers cannot supply invoice facts',
      () {
    final request = incoming('request', '我要开票', 0);
    final media = {
      ...incoming('media', '订单号：123456789012\n个人普票\n抬头：张三', 1),
      'text_origin': 'media'
    };
    final other = {
      ...incoming('other', '订单号：123456789012\n个人普票\n抬头：张三', 2),
      'sender': 'another-buyer'
    };
    final value = resolve([request, media, other], [request])!;
    expect(value.facts, isEmpty);
  });

  for (final text in [
    '怎么申请发票？',
    '发票打印怎么设置？',
    '支持发票打印吗？',
    'How do I request an invoice?',
    'Can this printer print invoices?',
    '为什么选不了专票？'
  ]) {
    test('invoice information or printing remains normal support: $text', () {
      final question = incoming('question', text, 0);
      expect(resolve([question], [question]), isNull);
      expect(requiresOrderServiceHandoff(text, [question]), isFalse);
    });
  }

  test('a later same-bubble correction wins over earlier cancellation', () {
    final request = incoming('request', '不要专票，帮我开普票', 0);
    final value = resolve([request], [request])!;
    expect(value.facts['invoice_type'], 'ordinary');
    expect(InvoiceRequestPolicy.isRequest('我要开票，但不用开票了'), isFalse);
    expect(InvoiceRequestPolicy.isCancellation('我要开票，但不用开票了'), isTrue);
  });

  test('English collection and completed handoff follow customer language', () {
    final request = incoming('request', 'I need an invoice', 0);
    final first = resolve([request], [request])!;
    expect(first.clarification(CustomerLanguage.english),
        contains('order number'));
    final details = incoming(
        'details',
        'Order number: 123456789012\nPersonal ordinary invoice\nInvoice title: Jane Doe',
        2);
    final value = resolve([request, sent(first, 1), details], [details])!;
    expect(value.complete, isTrue);
    expect(value.draft(CustomerLanguage.english).reply,
        contains('customer service colleague'));
    expect(
        RegExp(r'[\u4e00-\u9fff]')
            .hasMatch(value.draft(CustomerLanguage.english).reply),
        isFalse);
  });

  test('mixed support question retains its answer and missing invoice fields',
      () {
    final request = incoming('request', '我要开票，打印机怎么连接电脑？', 0);
    final invoice = resolve([request], [request])!;
    expect(invoice.currentTurnInvoiceOnly, isFalse);
    final model = AiDraft.fromJson({
      'reply': '请用 USB 线连接打印机和电脑，并安装对应型号驱动。',
      'decision': 'draft',
      'risk_level': 'low',
      'confidence': 1,
      'model': 'fixture'
    }, mediaBaseUrl: Uri());
    final result = enforceInvoiceCollectionPolicy(model, invoice,
        language: CustomerLanguage.chinese, sessionId: 'run');
    expect(result.reply, startsWith(model.reply));
    expect(result.reply, contains('订单号'));
    expect(isExplicitHumanTransfer(result), isFalse);
  });

  test('invoice clarification cannot disguise a mixed waiting-only result', () {
    final request = incoming('request', '我要开票，打印机怎么连接电脑？', 0);
    final invoice = resolve([request], [request])!;
    final model = AiDraft.fromJson({
      'reply': '请稍等，我们正在核对您的问题。',
      'decision': 'draft',
      'risk_level': 'low',
      'confidence': 1,
      'model': 'fixture'
    }, mediaBaseUrl: Uri());
    final result = enforceInvoiceCollectionPolicy(model, invoice,
        language: CustomerLanguage.chinese);
    expect(raw(result)['formal_response_message_ids'], isEmpty);
    expect(raw(result)['reply_purpose'], 'review_status');
    expect(result.reply, isNot(contains('资料齐全后')));
  });

  test('an independent order change still keeps its authority route', () {
    expect(requiresOrderServiceHandoff('帮我开具发票，然后修改订单地址', []), isTrue);
    expect(requiresOrderServiceHandoff('我要开具发票', []), isFalse);
    expect(
        requiresOrderServiceHandoff('transfer me to human agent', []), isFalse);
  });

  test('actual service returns invoice collection without launching a model',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v60_invoice_');
    final db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/controlled_kb.md')
        .writeAsString('Controlled invoice knowledge fixture.');
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'request',
              direction: 'incoming',
              sender: 'buyer',
              body: '我要开票',
              sentAt: at,
              axPath: 'fixture')
        ]));
    final service = CodexReplyService(
        executable: '/must-not-launch-model',
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/schema.json'));
    final draft = await service.generate(
        conversation: (await db.conversations()).single, database: db);
    expect(draft.model, InvoiceRequestPolicy.model);
    expect(draft.decision, 'ask_clarification');
    expect(isExplicitHumanTransfer(draft), isFalse);
  });

  for (final complete in [false, true]) {
    test(
        'invoice detail completeness controls the actual saved queue: $complete',
        () async {
      final root =
          await Directory.systemTemp.createTemp('jd_v60_invoice_queue_');
      final db = CaptureDatabase(
          automationSettings: const AutomationSettings(
              holdingResponseSeconds: 20, transferRequestCount: 2),
          storageRoot: Directory('${root.path}/data'));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      await Directory('${root.path}/workspace').create();
      await Directory('${root.path}/knowledge').create();
      await File('${root.path}/knowledge/controlled_kb.md')
          .writeAsString('Controlled invoice fixture.');
      final now = DateTime.now().toUtc();
      final session = await db.beginAutomationSession(
          startedAt: now.subtract(const Duration(seconds: 1)));
      final body = complete ? '我要开票\n订单号：123456789012\n个人普票\n抬头：张三' : '我要开票';
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: session,
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: 'invoice',
                direction: 'incoming',
                sender: 'buyer',
                body: body,
                sentAt: now,
                axPath: 'controlled actual invoice input')
          ]));
      final id = (await db.incomingMessageIdAtTime('buyer', now))!;
      final pending = (await db.conversation('buyer'))!;
      final token = await db.beginGeneration(
          customer: 'buyer', pendingId: pending.id, batchEndMessageId: id);
      expect(token, isNotNull);
      final service = CodexReplyService(
          executable: '/must-not-launch-invoice-model',
          workspace: Directory('${root.path}/workspace'),
          knowledgeDirectory: Directory('${root.path}/knowledge'),
          outputSchema: File('${root.path}/schema.json'));
      final draft = await service.generate(
          conversation: pending, database: db, batchEndMessageId: id);
      expect(isExplicitHumanTransfer(draft), complete);
      final prepared = await db.prepareAutomaticDraft('buyer', draft);
      final saved = await db.saveAutomaticDraft(pending.id, prepared,
          expectedMessageId: id,
          expectedUserId: 'buyer',
          generationToken: token!,
          deliverable: !complete);
      if (complete) {
        expect(saved.outcome, AutomaticDraftSaveOutcome.transferOnly);
        expect(await db.nextReadyDelivery(), isNull);
        final ticket = await db.createHumanReviewTicket(
            userId: 'buyer',
            customerRequest: body,
            reason: 'Invoice details collected for colleague verification.',
            requestMessageId: id);
        expect((await db.duePreclickHandoffs()).map((t) => t.id),
            contains(ticket.id));
        await db.markTicketHandoffPending(ticket.id);
        expect(await db.isHandoffExecutionCurrent(ticket.id), isTrue);
        expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
        expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
      } else {
        expect(saved.outcome, AutomaticDraftSaveOutcome.ready);
        expect(await db.nextReadyDelivery(), isNotNull);
        expect(await db.humanReviewTickets(), isEmpty);
      }
    });
  }
}
