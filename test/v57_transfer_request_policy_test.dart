import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'v57-buyer';
  late Directory root;
  late CaptureDatabase db;
  late CodexReplyService service;
  late DateTime at;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v57_transfer_policy_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: Directory('${root.path}/data'));
    at = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    session = await db.beginAutomationSession(startedAt: at);
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/controlled_printer_kb.md').writeAsString(
        'Controlled fixture: USB printing connects the printer and computer '
        'with a USB cable, installs the matching model driver, and selects '
        'the USB printer port.');
    service = CodexReplyService(
        executable: '/controlled-test-must-not-launch-a-model',
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'));
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Map<String, dynamic> original(String id, String body, int second) => {
        'id': id,
        'direction': 'incoming',
        'sender': customer,
        'body': body,
        'text_origin': 'customer_text',
        'sent_at': at.add(Duration(seconds: second)).toIso8601String(),
        'captured_at': at.add(Duration(seconds: second)).toIso8601String(),
        'media': <Object?>[],
      };

  AiDraft modelDraft({List<String>? ids, List<Object?>? slots}) =>
      AiDraft.fromJson({
        'reply': 'Please provide the order number and model before I can help.',
        'decision': 'ask_clarification',
        'required_slots': slots ?? ['order number', 'model', 'customer issue'],
        'confidence': .9,
        'risk_level': 'low',
        'risk_triggers': <String>[],
        'human_review_required': false,
        'human_transfer_request_message_ids': ids ?? <String>[],
        'model': 'controlled-v57',
        'actions': <Object?>[],
        'attachments': <Object?>[],
        'used_record_ids': <String>[],
        'image_descriptions': <Object?>[],
        'auto_send_allowed': false,
      }, mediaBaseUrl: Uri());

  Map<String, dynamic> raw(AiDraft draft) =>
      jsonDecode(draft.rawJson) as Map<String, dynamic>;

  Future<void> persistHistory(List<Map<String, dynamic>> history) async {
    final first =
        history.firstWhere((message) => message['direction'] == 'incoming');
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: first['id']! as String,
              direction: 'incoming',
              sender: customer,
              sentAt: DateTime.parse(first['sent_at']! as String),
              body: first['body']! as String,
              axPath: 'controlled persisted history')
        ]));
    final store = await db.history;
    final document = (await store.read(customer))!;
    // This isolated history fixture includes positive application send metadata;
    // an unsent model response is deliberately insufficient for the yes gate.
    document['messages'] = history;
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
        .writeAsString(jsonEncode(document), flush: true);
  }

  Future<FrozenHumanTransferResult> record(List<Map<String, dynamic>> inputs,
      {List<Map<String, dynamic>>? history}) async {
    if (history != null) await persistHistory(history);
    final ids = deterministicEscalationRequestIds(inputs, history ?? inputs,
        sessionId: session);
    return recordFrozenHumanTransferRequests(
        draft: withReplyProgress(
            modelDraft(), {'human_transfer_request_message_ids': ids.toList()}),
        frozenInputs: inputs,
        database: db,
        customer: customer);
  }

  AiDraft enforce(FrozenHumanTransferResult transfer, String body,
          {bool afterSales = false}) =>
      service.enforceHumanReviewPolicy(transfer.draft, body,
          humanTransferRequested: transfer.hasRequest,
          repeatedHumanTransferRequest: transfer.repeatedRequest,
          afterSalesRequested: afterSales,
          language: CustomerLanguage.english);

  void expectTransfer(AiDraft draft) {
    expect(draft.decision, 'human_review_required');
    expect(draftRequiresHumanReview(draft), isTrue);
    expect(isExplicitHumanTransfer(draft), isTrue);
    expect(raw(draft)['risk_triggers'], contains('explicit_human_request'));
    expect(raw(draft)['required_slots'], isEmpty);
    expect(draft.reply.toLowerCase(), isNot(contains('provide the order')));
    expect(draft.reply, isNot(contains('订单号')));
  }

  Future<CodexReplyService> answeringService(String answer) async {
    final response = File('${root.path}/answer-response.json');
    await response.writeAsString(jsonEncode({
      ...raw(modelDraft(slots: [])),
      'reply': answer,
      'decision': 'draft',
      'reply_purpose': 'substantive',
    }));
    final cli = File('${root.path}/answer-cli.py');
    await cli.writeAsString('''#!/usr/bin/python3
import sys,pathlib
args=sys.argv[1:]
sys.stdin.read()
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(pathlib.Path(${jsonEncode(response.path)}).read_text())
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    return CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'),
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
  }

  test('mixed first intent cannot turn a status-only result into an answer',
      () {
    for (final notice in ['我已记录您的问题，相关信息已保留。', '']) {
      final pending = AiDraft.fromJson({
        ...raw(modelDraft(ids: ['return-intent'])),
        'reply': notice,
      }, mediaBaseUrl: Uri());
      final guarded = service.enforceHumanReviewPolicy(pending, '我要退货',
          language: CustomerLanguage.chinese,
          humanTransferRequested: true,
          afterSalesRequested: true,
          preserveAnswerOnFirstRequest: true);
      expect(isOnlyReplyProgressNotice(guarded.reply), isTrue,
          reason: 'notice=$notice; actual=${guarded.reply}');
      expect(replyPurpose(guarded), ReplyPurpose.reviewStatus);
      expect(raw(guarded)['review_acknowledgement_only'], isTrue);
      expect(raw(guarded)['formal_response_message_ids'], isEmpty);
      expect(raw(guarded)['handoff_intent_confirmation'], isFalse);
      expect(raw(guarded)['after_sales_intent_confirmation'], isFalse);
      expect(guarded.reply, isNot(contains('请确认')));
      expect(isExplicitHumanTransfer(guarded), isFalse);
      expect(draftRequiresHumanReview(guarded), isFalse);
    }
  });

  test('two distinct transfer requests need no order or model information',
      () async {
    final first = original('first', 'Please transfer me to a colleague.', 1);
    final second = original('second', 'No, please transfer me to a human.', 20);
    final firstResult = await record([first]);
    final firstDraft = enforce(firstResult, first['body']! as String);
    expect(firstResult.repeatedRequest, isFalse);
    expect(firstDraft.decision, 'ask_clarification');
    expect(raw(firstDraft)['required_slots'], ['intent_confirmation']);
    expect(raw(firstDraft)['handoff_intent_confirmation'], isTrue);
    expect(raw(firstDraft)['handoff_confirmation_kind'], 'transfer');
    expect(isExplicitHumanTransfer(firstDraft), isFalse);
    final secondResult = await record([second]);
    expect(secondResult.repeatedRequest, isTrue);
    expectTransfer(enforce(secondResult, second['body']! as String));
  });

  for (final body in ['Please transfer me to a human.', 'I need a refund.']) {
    test('configured three-request gate applies to $body', () async {
      db.configureAutomationSettings(
          const AutomationSettings(transferRequestCount: 3));
      final afterSales = body.contains('refund');
      for (var count = 1; count <= 3; count++) {
        final result =
            await record([original('configured-$count', body, count)]);
        expect(result.repeatedRequest, count == 3);
        final decision = enforce(result, body, afterSales: afterSales);
        if (count < 3) {
          expect(decision.decision, 'ask_clarification');
          expect(draftRequiresHumanReview(decision), isFalse);
        } else {
          expectTransfer(decision);
        }
      }
    });
  }

  test('the same request or its alias is not a second request', () async {
    final first = original('first', '请转人工客服', 1);
    final once = await record([first]);
    final retried = await record([first]);
    final alias = {
      ...first,
      'id': 'first-alias',
      'observed_ids': ['first']
    };
    final aliasRetry = await record([alias]);
    expect(once.repeatedRequest, isFalse);
    expect(retried.repeatedRequest, isFalse);
    expect(aliasRetry.repeatedRequest, isFalse);
    final counter = await (await db.database).query('human_transfer_requests');
    expect(counter.single['request_count'], 1);
  });

  test('plain transfer requests need no named colleague or extra qualifier',
      () async {
    final first = original('first', 'Please transfer me.', 1);
    final second = original('second', 'Please transfer.', 20);
    expect((await record([first])).repeatedRequest, isFalse);
    final repeated = await record([second]);
    expect(repeated.hasRequest, isTrue);
    expect(repeated.repeatedRequest, isTrue);
    expectTransfer(enforce(repeated, second['body']! as String));
  });

  test('an explicit request beyond ten minutes starts a new first request',
      () async {
    await record([original('first', '请转人工客服', 1)]);
    final later = original('later', '请转人工客服', 602);
    final result = await record([later]);
    expect(result.repeatedRequest, isFalse);
    expect(enforce(result, later['body']! as String).decision,
        'ask_clarification');
  });

  for (final body in [
    '我要退货',
    '我要换货',
    '我要退款',
    'I want to return this printer.',
    'I want to exchange this printer.',
    'I need a refund.',
  ]) {
    test(
        'first after-sales intent confirms and repeated intent transfers: $body',
        () async {
      final first = original('first', body, 1);
      final second = original('second', body, 20);
      final initial = await record([first]);
      expect(initial.hasRequest, isTrue);
      final confirmation = enforce(initial, body, afterSales: true);
      expect(confirmation.decision, 'ask_clarification');
      expect(isExplicitHumanTransfer(confirmation), isFalse);
      expect(raw(confirmation)['after_sales_intent_confirmation'], isTrue);
      expect(
          raw(confirmation)['required_slots'], isNot(contains('order number')));
      final repeated = await record([second]);
      expect(repeated.repeatedRequest, isTrue);
      expectTransfer(enforce(repeated, body, afterSales: true));
    });
  }

  Map<String, dynamic> sentConfirmation(String requestId,
          {String? state,
          String? owner,
          int second = 10,
          bool marker = true}) =>
      {
        'id': 'confirmation',
        'direction': 'outgoing',
        'source': 'generated_reply',
        'body': 'Do you want to request a return or exchange?',
        'delivery_status': state ?? 'sent',
        'sent_at': at.add(Duration(seconds: second)).toIso8601String(),
        'reply_metadata': {
          'raw_response': {
            'after_sales_intent_confirmation': marker,
            'model': 'jd-two-request-handoff-v1',
            'after_sales_request_message_ids': [requestId],
            'service_session_id': owner ?? session,
          }
        },
      };

  Map<String, dynamic> sentTransferConfirmation(String requestId,
          {bool applicationModel = true}) =>
      {
        ...sentConfirmation(requestId),
        'body':
            'Please confirm: would you like me to connect you with a customer service colleague?',
        'reply_metadata': {
          'raw_response': {
            'handoff_intent_confirmation': true,
            'handoff_confirmation_kind': 'transfer',
            'handoff_request_message_ids': [requestId],
            'model': applicationModel
                ? 'jd-two-request-handoff-v1'
                : 'ordinary-model-output',
            'service_session_id': session,
          }
        },
      };

  for (final affirmative in ['确认', 'yes', 'ok']) {
    test(
        'sent original transfer-intent confirmation makes $affirmative the second confirmation',
        () async {
      final first = original('first', 'Please transfer me to a colleague.', 1);
      await record([first]);
      final answer = original('answer', affirmative, 20);
      final history = [first, sentTransferConfirmation('first'), answer];
      expect(
          deterministicEscalationRequestIds([answer], history,
              sessionId: session),
          {'answer'});
      final result = await record([answer], history: history);
      expect(result.repeatedRequest, isTrue);
      expectTransfer(enforce(result, affirmative));
    });
  }

  test(
      'a model-authored generic transfer confirmation cannot authorize bare yes',
      () async {
    final first = original('first', 'Please transfer me to a colleague.', 1);
    await record([first]);
    final answer = original('answer', 'yes', 20);
    final history = [
      first,
      sentTransferConfirmation('first', applicationModel: false),
      answer
    ];
    expect(
        deterministicEscalationRequestIds([answer], history,
            sessionId: session),
        isEmpty);
    await persistHistory(history);
    final result = await recordFrozenHumanTransferRequests(
        draft: modelDraft(ids: ['answer']),
        frozenInputs: [answer],
        database: db,
        customer: customer);
    expect(result.hasRequest, isFalse);
    expect(result.repeatedRequest, isFalse);
  });

  for (final affirmative in ['确认', '是的', 'yes', 'yes please', 'yes, please']) {
    test('sent original after-sales confirmation authorizes $affirmative',
        () async {
      final first = original('first', '我要退货', 1);
      await record([first]);
      final answer = original('confirmation-answer', affirmative, 20);
      final history = [first, sentConfirmation('first'), answer];
      expect(
          deterministicEscalationRequestIds([answer], history,
              sessionId: session),
          {'confirmation-answer'});
      final result = await record([answer], history: history);
      expect(result.repeatedRequest, isTrue);
      expectTransfer(enforce(result, affirmative, afterSales: true));
    });
  }

  test('generic ok never counts without a matching sent intent confirmation',
      () {
    final first = original('first', '我要退货', 1);
    final answer = original('answer', 'yes', 20);
    final histories = <List<Map<String, dynamic>>>[
      [first, answer],
      [
        first,
        sentConfirmation('first', state: 'unverified_observation'),
        answer
      ],
      [first, sentConfirmation('first', owner: 'old-session'), answer],
      [first, sentConfirmation('different-original'), answer],
      [first, sentConfirmation('first', marker: false), answer],
      [
        first,
        {...sentConfirmation('first'), 'source': 'jd_automation'},
        answer
      ],
      [
        first,
        {
          ...sentConfirmation('first'),
          'reply_metadata': {
            'raw_response': {
              'model': 'ordinary-model-output',
              'after_sales_intent_confirmation': true,
              'after_sales_request_message_ids': ['first'],
              'service_session_id': session,
            }
          }
        },
        answer
      ],
      [first, sentConfirmation('first', second: 30), answer],
      [first, sentConfirmation('first', second: -700), answer],
    ];
    for (final history in histories) {
      expect(
          deterministicEscalationRequestIds([answer], history,
              sessionId: session),
          isEmpty,
          reason: jsonEncode(history));
    }
    final ordinaryTransfer =
        original('first', 'Please transfer me to a colleague.', 1);
    expect(
        deterministicEscalationRequestIds(
            [answer], [ordinaryTransfer, sentConfirmation('first'), answer],
            sessionId: session),
        isEmpty,
        reason:
            'A generic transfer request is not an after-sales intent confirmation.');
  });

  for (final body in ['yes', 'ok', '确认', 'yes, please']) {
    test(
        'model intent IDs cannot promote a bare $body without a sent confirmation',
        () async {
      final first = original('first', '我要退货', 1);
      await record([first]);
      final answer = original('answer', body, 20);
      await persistHistory([first, answer]);
      final result = await recordFrozenHumanTransferRequests(
          draft: modelDraft(ids: ['answer']),
          frozenInputs: [answer],
          database: db,
          customer: customer);
      expect(result.hasRequest, isFalse);
      expect(result.repeatedRequest, isFalse);
      expect(codexHumanTransferRequestIds(result.draft), isEmpty);
      expect((await (await db.database).query('human_transfer_request_events')),
          hasLength(1));
    });
  }

  test(
      'negative requests, policy questions, media text and current account do not escalate',
      () {
    final inputs = [
      original('no-transfer', '不要转人工，我自己处理', 1),
      original('no-return', '我不想退货', 2),
      original('policy', 'What is your return policy?', 3),
      original('policy-cn', '退货政策是什么？', 4),
      {...original('ocr', '我要退款', 5), 'text_origin': 'image_ocr'},
      {
        ...original('subtitle', 'Please transfer me to a human', 6),
        'source': 'video_transcript'
      },
      {
        ...original('seller', 'Please transfer me to a human', 7),
        'direction': 'outgoing'
      },
      original('self', '请转小耿', 8),
    ];
    expect(
        deterministicEscalationRequestIds(inputs, inputs,
            currentServiceAccount: '格志打印机小耿', sessionId: session),
        isEmpty);
  });

  test(
      'an already current named account does not erase an independent after-sales request',
      () {
    final input = original('mixed', '请转小耿，另外我要退货', 1);
    expect(
        deterministicEscalationRequestIds([input], [input],
            currentServiceAccount: '格志打印机小耿', sessionId: session),
        {'mixed'});
  });

  test(
      'suppression applies to its exact request while a different new request remains eligible',
      () async {
    final first = original('first', 'Please transfer me to a colleague.', 1);
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: at.add(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'first',
              direction: 'incoming',
              sender: customer,
              sentAt: at.add(const Duration(seconds: 1)),
              body: first['body']! as String,
              axPath: 'controlled original')
        ]));
    final boundId = (await db.incomingMessageIdAtTime(
        customer, at.add(const Duration(seconds: 1))))!;
    first['id'] = boundId;
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: first['body']! as String,
        reason: 'Explicit customer transfer request',
        requestMessageId: boundId);
    await (await db.database).insert('handoff_ai_fallbacks', {
      'session_id': session,
      'user_id': customer,
      'request_message_id': boundId,
      'ticket_id': ticket.id,
      'reason': 'no_online_agent',
      'created_at_ms': at.millisecondsSinceEpoch,
    });
    final suppressed = await record([first]);
    expect(suppressed.hasRequest, isFalse);
    expect(await (await db.database).query('human_transfer_request_events'),
        isEmpty);
    final next = await record(
        [original('second', 'Please transfer me to another colleague.', 20)]);
    expect(next.hasRequest, isTrue);
    expect(next.repeatedRequest, isFalse);
  });

  test(
      'handoff unavailability still wins over a repeated request with missing order slots',
      () {
    final guarded = service.enforceHumanReviewPolicy(
        modelDraft(ids: ['second']), 'Please transfer me to a colleague',
        humanTransferRequested: true,
        repeatedHumanTransferRequest: true,
        handoffUnavailable: true,
        language: CustomerLanguage.english);
    expect(raw(guarded)['auto_handoff_suppressed'], isTrue);
    expect(isExplicitHumanTransfer(guarded), isFalse);
  });

  for (final body in ['我要退货', '我要换货', 'I need a refund.']) {
    test(
        'generate confirms the first after-sales intent before order authority: $body',
        () async {
      final sent = at.add(const Duration(seconds: 1));
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: session,
          capturedAt: sent,
          messages: [
            CapturedMessage(
                stableId: 'first',
                direction: 'incoming',
                sender: customer,
                sentAt: sent,
                body: body,
                axPath: 'controlled original after-sales request')
          ]));
      final id = (await db.incomingMessageIdAtTime(customer, sent))!;
      final pending = (await db.conversation(customer))!;
      expect(
          await db.beginGeneration(
              customer: customer, pendingId: pending.id, batchEndMessageId: id),
          isNotNull);
      // The deterministic intent gate must precede both order-authority
      // routing and CLI generation. The executable here intentionally cannot run.
      final draft = await service.generate(
          conversation: pending, database: db, batchEndMessageId: id);
      expect(draft.decision, 'ask_clarification');
      expect(isExplicitHumanTransfer(draft), isFalse);
      expect(raw(draft)['after_sales_intent_confirmation'], isTrue);
      expect(raw(draft)['required_slots'], isNot(contains('order number')));
    });
  }

  test(
      'generate produces application-owned confirmation for the first plain transfer request',
      () async {
    final sent = at.add(const Duration(seconds: 1));
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: sent,
        messages: [
          CapturedMessage(
              stableId: 'first',
              direction: 'incoming',
              sender: customer,
              sentAt: sent,
              body: 'Please transfer me.',
              axPath: 'controlled original')
        ]));
    final id = (await db.incomingMessageIdAtTime(customer, sent))!;
    final pending = (await db.conversation(customer))!;
    expect(
        await db.beginGeneration(
            customer: customer, pendingId: pending.id, batchEndMessageId: id),
        isNotNull);
    final draft = await service.generate(
        conversation: pending, database: db, batchEndMessageId: id);
    expect(draft.decision, 'ask_clarification');
    expect(raw(draft)['model'], 'jd-two-request-handoff-v1');
    expect(raw(draft)['handoff_intent_confirmation'], isTrue);
    expect(raw(draft)['handoff_confirmation_kind'], 'transfer');
    expect(raw(draft)['handoff_request_message_ids'], [id]);
    expect(raw(draft)['required_slots'], ['intent_confirmation']);
    expect(isExplicitHumanTransfer(draft), isFalse);
  });

  for (final sameBubble in [false, true]) {
    test(
        'first after-sales confirmation preserves the technical answer (${sameBubble ? 'same bubble' : 'separate inputs'})',
        () async {
      const answer = '先将USB线连接打印机和电脑，再安装对应型号的驱动程序，然后选择USB打印端口。';
      final bodies =
          sameBubble ? ['我要退货，还有USB怎么连接电脑？'] : ['USB怎么连接电脑？', '我要退货'];
      final messages = <CapturedMessage>[];
      for (var i = 0; i < bodies.length; i++) {
        messages.add(CapturedMessage(
            stableId: 'mixed-$i',
            direction: 'incoming',
            sender: customer,
            body: bodies[i],
            sentAt: at.add(Duration(seconds: i + 1)),
            axPath: 'controlled original mixed customer questions'));
      }
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: session,
          capturedAt: at.add(const Duration(seconds: 3)),
          messages: messages));
      final anchor =
          (await db.incomingMessageIdAtTime(customer, messages.last.sentAt!))!;
      final pending = (await db.conversation(customer))!;
      expect(
          await db.beginGeneration(
              customer: customer,
              pendingId: pending.id,
              batchEndMessageId: anchor),
          isNotNull);
      final actual = await answeringService(answer);
      final draft = await actual.generate(
          conversation: pending, database: db, batchEndMessageId: anchor);
      expect(draft.reply, contains(answer));
      expect(raw(draft)['after_sales_intent_confirmation'], isTrue);
      expect(draft.decision, 'ask_clarification');
      expect(isExplicitHumanTransfer(draft), isFalse);
      expect(raw(draft)['required_slots'], isNot(contains('order number')));
    });
  }

  test(
      'confirmed repeated transfer survives product photo policy and omitted model intent IDs',
      () async {
    final first = original('first', 'Please transfer me to a colleague.', 1);
    await record([first]);
    final second = original(
        'second',
        'Please transfer me to a colleague and send photos of this printer.',
        20);
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: at.add(const Duration(seconds: 20)),
        messages: [
          CapturedMessage(
              stableId: 'second',
              direction: 'incoming',
              sender: customer,
              sentAt: at.add(const Duration(seconds: 20)),
              body: second['body']! as String,
              axPath: 'controlled original')
        ]));
    final id = (await db.incomingMessageIdAtTime(
        customer, at.add(const Duration(seconds: 20))))!;
    final pending = (await db.conversation(customer))!;
    expect(
        await db.beginGeneration(
            customer: customer, pendingId: pending.id, batchEndMessageId: id),
        isNotNull);
    final response = File('${root.path}/response.json');
    await response.writeAsString(modelDraft().rawJson);
    final cli = File('${root.path}/controlled-cli.py');
    await cli.writeAsString('''#!/usr/bin/python3
import sys,pathlib
args=sys.argv[1:]
sys.stdin.read()
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(pathlib.Path(${jsonEncode(response.path)}).read_text())
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    final actual = CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'),
        enforceProductPhotoReviewPolicy: true,
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
    final result = await actual.generate(
        conversation: pending, database: db, batchEndMessageId: id);
    expectTransfer(result);
    expect(codexHumanTransferRequestIds(result), contains(id));
  });
}
