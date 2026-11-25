import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

AiDraft answer(String reply,
        {String purpose = 'substantive',
        Map<String, String>? dependencies = const {},
        bool review = false}) =>
    AiDraft.fromJson({
      'reply': reply,
      'reply_purpose': purpose,
      'decision': review ? 'human_review_required' : 'draft',
      'human_review_required': review,
      'confidence': 1,
      'risk_level': review ? 'high' : 'low',
      'risk_triggers': review ? ['explicit_human_request'] : <String>[],
      'model': 'controlled-v51-result',
      if (dependencies != null) 'reply_media_dependency_keys': dependencies,
    }, mediaBaseUrl: Uri());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'buyer';
  const notice = '请稍等。正在核对您的问题。';
  final start = DateTime.utc(2026, 11, 10, 7);
  late Directory root;
  late CaptureDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v51_save_result_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> receive(String body, int second,
      {String buyer = customer}) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at.add(const Duration(milliseconds: 100)),
        messages: [
          CapturedMessage(
              stableId: 'controlled-$buyer-$second',
              direction: 'incoming',
              sender: buyer,
              body: body,
              sentAt: at,
              axPath: 'controlled original message')
        ]));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<String> begin(String id, {String buyer = customer}) async =>
      (await db.beginGeneration(
          customer: buyer,
          pendingId: (await db.conversation(buyer))!.id,
          batchEndMessageId: id))!;

  Future<AutomaticDraftSaveResult> save(String id, String token, AiDraft draft,
          {String buyer = customer,
          bool deliverable = true,
          bool prepare = true}) async =>
      db.saveAutomaticDraft((await db.conversation(buyer))!.id,
          prepare ? await db.prepareAutomaticDraft(buyer, draft) : draft,
          expectedUserId: buyer,
          expectedMessageId: id,
          generationToken: token,
          deliverable: deliverable);

  Future<String> park() async {
    final id = await receive('Why does the printer stop after one sheet?', 1);
    final first = await begin(id);
    expect((await save(id, first, answer(notice))).outcome,
        AutomaticDraftSaveOutcome.needsAnswer);
    await db.abandonGeneration(customer, first);
    final correction = await begin(id);
    expect(
        (await save(id, correction, answer(notice))).requiresOperator, isTrue);
    await db.abandonGeneration(customer, correction);
    return id;
  }

  Future<String> unreadyMedia(int second) async {
    final inventory = CustomerMediaInventory(db);
    final at = start.add(Duration(seconds: second));
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'controlled-media-$second',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final id = CustomerMessageTime.incomingId(customer, at);
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: at, senderAt: at);
    return id;
  }

  test('a real answer survives a wrong review label and stays uncompleted',
      () async {
    final id = await receive('Which paper width should I select?', 1);
    final token = await begin(id);
    final result = await save(
        id,
        token,
        answer('Select the 58 mm paper width in the printer settings.',
            purpose: 'review_status'));
    expect(result.outcome, AutomaticDraftSaveOutcome.ready);
    final delivery = await db.nextReadyDelivery();
    expect(delivery, isNotNull);
    expect(jsonDecode(delivery!.draft.rawJson)['formal_response_message_ids'],
        contains(id));
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
  });

  for (final dependencies in [const <String, String>{}, null]) {
    test(
        'status with ${dependencies == null ? 'missing' : 'empty'} dependency '
        'keys schedules explicit correction, then a visible answer task',
        () async {
      final request = await receive('Please transfer me to Xiao Geng.', 1);
      final greeting = await receive('hello', 2);
      final first = await begin(greeting);
      final result = await save(
          greeting, first, answer(notice, dependencies: dependencies));
      expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
      expect(result.queued, isFalse);
      expect(result.requiresOperator, isFalse);
      expect(result.repairContext!['message_ids'],
          unorderedEquals([request, greeting]));
      expect(await db.hasUndeliveredDraft(customer), isFalse);
      await db.abandonGeneration(customer, first);
      expect(await db.generationDue(customer), isTrue,
          reason: 'A corrective step waits for a process event, not a timer');
      final correction = await begin(greeting);
      final context = await db.automaticReplyRepairContext(customer);
      expect(context!['previous_reply'], notice);
      expect(context['failure_count'], 1);
      expect(context['message_ids'], unorderedEquals([request, greeting]));
      final corrected = await save(
          greeting, correction, answer(notice, dependencies: dependencies));
      expect(corrected.outcome, AutomaticDraftSaveOutcome.needsAnswer);
      expect(corrected.requiresOperator, isTrue);
      await db.abandonGeneration(customer, correction);
      expect(await db.generationDue(customer), isFalse);
      expect(await db.unansweredWorkCounts(), {customer: 2});
      expect((await db.customerMessageRecords(customer)).map((r) => r.status),
          everyElement('needs_answer'));
      expect(await db.hasUndeliveredDraft(customer), isFalse);
      await receive('hello', 2);
      await db.repairSessionPendingWork(customer);
      expect(await db.generationDue(customer), isFalse,
          reason: 'A reread cannot turn operator work into blind generation');
      expect(await db.answeredMessageId(customer), isNull);
      expect(await (await db.database).query('human_review_tickets'), isEmpty);
    });
  }

  test('another input arriving during correction cannot erase its feedback',
      () async {
    final id = await receive('Why does the paper stop?', 1);
    final first = await begin(id);
    await save(id, first, answer(notice));
    await db.abandonGeneration(customer, first);
    final correction = await begin(id);
    final newer = await receive('Which setting should I choose?', 2);
    await db.generationDue(customer);
    final context = await db.automaticReplyRepairContext(customer);
    expect(context!['failure_count'], 1);
    expect(context['message_ids'], [id]);
    final failed = await save(id, correction, answer(notice));
    expect(failed.requiresOperator, isTrue,
        reason: 'The unchanged submitted scope still owns its correction');
    expect(await db.isMessageFormallyAnswered(customer, newer), isFalse);
    await db.abandonGeneration(customer, correction);
    expect(await db.generationDue(customer), isTrue);
    final next = await begin(newer);
    expect(
        (await db.generationMessages(customer))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        [newer]);
    expect(
        (await db.customerMessageRecords(customer))
            .singleWhere((row) => row.stableId == id)
            .status,
        'needs_answer');
    await db.abandonGeneration(customer, next);
  });

  test('pre-submit expansion preserves A correction and gives B its own step',
      () async {
    final old = await receive('Why does the paper stop?', 1);
    final first = await begin(old);
    await save(old, first, answer(notice));
    await db.abandonGeneration(customer, first);
    final correction = await begin(old);
    final newer = await receive('Which setting should I use?', 2);
    final expanded = (await db.refreezeGenerationBeforeSubmit(
        customer: customer,
        pendingId: (await db.conversation(customer))!.id,
        generationToken: correction,
        batchEndMessageId: old,
        expectedSessionId: db.currentAutomationSessionId!))!;
    expect(expanded.expanded, isTrue);
    final result =
        await save(expanded.batchEndMessageId, expanded.token, answer(notice));
    expect(result.repairContext!['message_failure_counts'], {old: 2, newer: 1});
    expect(result.requiresOperator, isTrue);
    await db.abandonGeneration(customer, expanded.token);
    expect(await db.generationDue(customer), isTrue,
        reason: 'B still owns its first corrective attempt');
    final next = await begin(newer);
    final input = (await db.generationMessages(customer))
        .where((m) => m['direction'] == 'incoming')
        .map((m) => m['id']);
    expect(input, [newer]);
    final context = (await db.automaticReplyRepairContext(customer))!;
    expect(context['message_ids'], [newer]);
    expect(context['message_failure_counts'], {newer: 1});
    expect(
        (await db.customerMessageRecords(customer))
            .singleWhere((record) => record.stableId == old)
            .status,
        'needs_answer');
    final failedB = await save(newer, next, answer(notice));
    expect(failedB.requiresOperator, isTrue);
    await db.abandonGeneration(customer, next);
    expect(await db.generationDue(customer), isFalse,
        reason: 'A and B cannot indefinitely wake each other as new inputs');
    expect((await db.customerMessageRecords(customer)).map((row) => row.status),
        everyElement('needs_answer'));
    expect(await db.unansweredWorkCounts(), {customer: 2});
  });

  test('new real input reopens answer repair, while other buyers continue',
      () async {
    final old = await park();
    final other = await receive('Which cable should I use?', 1, buyer: 'other');
    final otherToken = await begin(other, buyer: 'other');
    expect(
        (await save(other, otherToken,
                answer('Use the USB cable supplied with the printer.'),
                buyer: 'other'))
            .outcome,
        AutomaticDraftSaveOutcome.ready);
    expect(await db.generationDue(customer), isFalse);
    final newer = await receive('The error code is 22.', 2);
    expect(await db.generationDue(customer), isTrue);
    final token = await begin(newer);
    expect(
        (await db.generationMessages(customer))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        unorderedEquals([old, newer]));
    expect(
        (await db.automaticReplyRepairContext(customer))!['failure_count'], 2,
        reason: 'New input reopens work without erasing its earlier feedback');
    await db.abandonGeneration(customer, token);
  });

  test('a material correction reopens the same original time-keyed message',
      () async {
    final id = await park();
    await receive(
        'Why does the printer stop after one sheet? Error code 22.', 1);
    expect(await db.generationDue(customer), isTrue);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    final token = await begin(id);
    expect(await db.automaticReplyRepairContext(customer), isNull);
    await db.abandonGeneration(customer, token);
  });

  test(
      'explicit retry reopens only repair and never marks its question answered',
      () async {
    final id = await park();
    expect(await db.retryAutomaticReplyRepair(customer), isTrue);
    expect(await db.generationDue(customer), isTrue);
    final token = await begin(id);
    expect(await db.automaticReplyRepairContext(customer), isNull);
    final result = await save(
        id, token, answer('Select the correct paper source before printing.'));
    expect(result.outcome, AutomaticDraftSaveOutcome.ready);
    expect(await db.retryAutomaticReplyRepair(customer), isFalse,
        reason: 'An existing physical delivery task cannot be reopened');
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
  });

  test('a transfer-only decision is persisted even when its text is a notice',
      () async {
    final request =
        await receive('Please transfer me to another colleague.', 1);
    final greeting = await receive('hello', 2);
    final token = await begin(greeting);
    final result = await save(
        greeting, token, answer(notice, purpose: 'review_status', review: true),
        deliverable: false);
    expect(result.outcome, AutomaticDraftSaveOutcome.transferOnly);
    final row = (await (await db.database).query('generated_drafts')).single;
    expect(row['delivery_state'], 'transfer_only');
    expect(jsonDecode(row['raw_json']! as String)['service_message_ids'],
        unorderedEquals([request, greeting]));
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.isMessageFormallyAnswered(customer, request), isFalse);
  });

  for (final mode in ['provided', 'empty', 'missing']) {
    test(
        'unfinished actual media ($mode) stays pending while its text can proceed',
        () async {
      final inventory = CustomerMediaInventory(db);
      final at = start.add(const Duration(seconds: 1));
      final receipt = await inventory.observe(
          customer: customer,
          evidenceId: 'controlled-v51-media',
          observedAt: at,
          senderAt: at,
          slot: 0,
          region: [.3, .4, .2, .2],
          current: true);
      await inventory.classify(receipt, 'video');
      final mediaId = CustomerMessageTime.incomingId(customer, at);
      await admitFixtureMedia(db,
          receiptId: receipt, messageId: mediaId, receivedAt: at, senderAt: at);
      final question = await receive('Please explain this video.', 2);
      final pending = (await db.conversation(customer))!;
      final sql = await db.database;
      final document = (await (await db.history).read(customer))!;
      const token = 'controlled-legacy-media-in-flight';
      await sql.update('pending_customers', {'generation_token': token},
          where: 'id=?', whereArgs: [pending.id]);
      for (final row in await sql.query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, customer])) {
        final message = (document['messages'] as List).cast<Map>().firstWhere(
            (m) => ConversationFileStore.messageAliases(m)
                .contains(row['message_id']));
        await sql.insert('automation_reply_inputs', {
          'session_id': db.currentAutomationSessionId,
          'user_id': customer,
          'owner_id': token,
          'message_id': row['message_id'],
          'message_revision': row['work_revision'],
          'message_json': jsonEncode({
            ...message,
            'reply_material_input_key':
                ConversationFileStore.materialInputKey(message)
          }),
        });
      }
      final result = await save(
          question,
          token,
          answer('Select the 58 mm width in the paper settings.',
              dependencies: mode == 'provided'
                  ? {mediaId: ''}
                  : mode == 'empty'
                      ? const {}
                      : null),
          prepare: false);
      expect(result.outcome, AutomaticDraftSaveOutcome.awaitingDependency);
      expect(await db.hasUndeliveredDraft(customer), isFalse);
      await db.abandonGeneration(customer, token);
      expect(await db.retryAutomaticReplyRepair(customer), isFalse);
      expect(await db.generationDue(customer), isTrue,
          reason:
              'Only the actual media waits; its text question remains eligible.');
      final textToken = await begin(question);
      expect(
          (await db.generationMessages(customer))
              .where((message) => message['direction'] == 'incoming')
              .map((message) => message['id']),
          [question]);
      expect(
          await db.generationInputsAnalysisReady(customer,
              generationToken: textToken),
          isTrue);
      expect(await db.isMessageFormallyAnswered(customer, mediaId), isFalse);
    });
  }

  test('a factual receipt answers its question without completing the video',
      () async {
    final media = await unreadyMedia(1);
    final question = await receive('Did you receive my video?', 2);
    final token = await begin(question);
    final result = await save(question, token,
        answer('I have received your video.', purpose: 'review_status'));
    expect(result.outcome, AutomaticDraftSaveOutcome.ready);
    final raw =
        jsonDecode((await db.nextReadyDelivery())!.draft.rawJson) as Map;
    expect(raw['reply_purpose'], 'receipt');
    expect(raw['formal_response_message_ids'], contains(question));
    expect(raw['formal_response_message_ids'], isNot(contains(media)));
    expect(await db.isMessageFormallyAnswered(customer, media), isFalse);
  });

  test('a receipt label cannot turn Please wait into a receipt answer',
      () async {
    final id = await receive('Did you receive my image?', 1);
    final token = await begin(id);
    final result = await save(
        id, token, answer('Please wait a moment.', purpose: 'receipt'));
    expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
  });

  test('a receipt fact alone does not answer a printer fault', () async {
    final id = await receive('Why does my printer stop after one sheet?', 1);
    final token = await begin(id);
    final result =
        await save(id, token, answer('已收到您的图片。', purpose: 'receipt'));
    expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
  });

  test('a social-only reply cannot cover another unresolved real question',
      () async {
    final question = await receive('Why does the printer stop?', 1);
    final first = await begin(question);
    await save(question, first, answer(notice));
    await db.abandonGeneration(customer, first);
    final greeting = await receive('hello', 2);
    final token = await begin(greeting);
    final result =
        await save(greeting, token, answer('Hello.', purpose: 'review_status'));
    expect(result.outcome, AutomaticDraftSaveOutcome.ready);
    final raw =
        jsonDecode((await db.nextReadyDelivery())!.draft.rawJson) as Map;
    expect(raw['formal_response_message_ids'], contains(greeting));
    expect(raw['formal_response_message_ids'], isNot(contains(question)));
    expect(raw['formal_response_message_ids'],
        isNot(contains('controlled-$customer-1')));
    final feedback = (await db.automaticReplyRepairContext(customer))!;
    expect(feedback['message_ids'], [question]);
    expect(feedback['message_failure_counts'], {question: 1});
    expect(await db.isMessageFormallyAnswered(customer, question), isFalse);
  });

  test('a social-only reply to a real problem needs an answer', () async {
    final question = await receive('Why does the printer stop?', 1);
    final token = await begin(question);
    final result = await save(question, token, answer('Hello.'));
    expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test('failed transfer retires a decision whose request precedes its boundary',
      () async {
    final request =
        await receive('Please transfer me to another colleague.', 1);
    final problem = await receive('Why does the printer stop?', 2);
    final token = await begin(problem);
    await save(problem, token, answer(notice, review: true),
        deliverable: false);
    await db.abandonGeneration(customer, token);
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'Please transfer me to another colleague.',
        reason: 'Customer explicitly requested human assistance.',
        requestMessageId: request);
    await db.reserveChatTransferLog(ticket: ticket);
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'controlled-no-online-agent'),
        isTrue);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.generationDue(customer), isTrue);
    expect(await db.unansweredWorkCounts(), {customer: 2});
    expect(await db.answeredMessageId(customer), isNull);
    expect(
        await (await db.database).query('automation_work_archive',
            where: 'table_name=?', whereArgs: ['generated_drafts']),
        hasLength(1));
  });

  test('an unrelated later transfer request cannot retire an older decision',
      () async {
    await receive('Please transfer me to another colleague.', 1);
    final problem = await receive('Why does the printer stop?', 2);
    final token = await begin(problem);
    await save(problem, token, answer(notice, review: true),
        deliverable: false);
    await db.abandonGeneration(customer, token);
    final later = await receive('Now transfer me to Xiao Hua.', 3);
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'Now transfer me to Xiao Hua.',
        reason: 'Customer explicitly requested human assistance.',
        requestMessageId: later);
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'controlled-no-online-agent'),
        isTrue);
    final row = (await (await db.database).query('generated_drafts')).single;
    expect(row['task_id'], token);
    expect(row['delivery_state'], 'transfer_only');
    expect(await db.answeredMessageId(customer), isNull);
  });

  test('handoff suppression matches only the same request and its aliases',
      () async {
    final old = await receive('Please transfer me to a colleague.', 1);
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'Please transfer me to a colleague.',
        reason: 'Customer explicitly requested human assistance.',
        requestMessageId: old);
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'controlled-transfer-unavailable'),
        isTrue);
    final newer = await receive('Please transfer me to another colleague.', 2);
    expect(await db.isHandoffSuppressed(customer, old), isTrue);
    expect(await db.isHandoffSuppressed(customer, 'controlled-$customer-1'),
        isTrue);
    expect(await db.isHandoffSuppressed(customer, newer), isFalse);
  });

  test('a canonical transfer request cannot increment a legacy alias twice',
      () async {
    final first = await receive('Please transfer me.', 1);
    final at = start.add(const Duration(seconds: 1));
    expect(
        await db.recordHumanTransferRequest(
            userId: customer, messageId: 'old-transfer-id', requestedAt: at),
        isFalse);
    expect(
        await db.recordHumanTransferRequest(
            userId: customer,
            messageId: first,
            messageAliases: ['old-transfer-id'],
            requestedAt: at),
        isFalse);
    final newer = await receive('No, please transfer me.', 2);
    expect(
        await db.recordHumanTransferRequest(
            userId: customer,
            messageId: newer,
            requestedAt: at.add(const Duration(seconds: 1))),
        isTrue);
    expect(await (await db.database).query('human_transfer_request_events'),
        hasLength(2));
  });
}
