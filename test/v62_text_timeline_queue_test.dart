import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/fixed_replies.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'junxi112233';
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime start;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v62_text_timeline_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 60000,
        isUtc: true);
    session = await db.beginAutomationSession(startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedConversation capture(CapturedMessage message) => CapturedConversation(
      stableKey: buyer,
      customerName: buyer,
      customerExternalId: buyer,
      automationSessionId: session,
      capturedAt: DateTime.now().toUtc(),
      messages: [message]);

  Future<String> text(String body, int second, {String? dependency}) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(
        capture(CapturedMessage(
            stableId: 'text-$second',
            direction: 'incoming',
            sender: buyer,
            sentAt: at,
            body: body,
            axPath: 'exact-current-customer',
            captureEvidenceId: 'text-frame-$second')),
        mediaInputDependencies: dependency == null
            ? const {}
            : {
                'text-$second': {dependency}
              },
        dependencyEvidenceId: dependency == null ? null : 'text-frame-$second');
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<({String id, String receipt})> media(
      {int second = 1, String kind = 'unknown'}) async {
    final at = start.add(Duration(seconds: second));
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: 'media-frame-$second',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    final admission = await db.admitMediaMessage(buyer,
        receiptId: receipt,
        evidenceId: 'media-frame-$second',
        occurrenceKey: 'media-$second',
        receivedAt: at,
        senderAt: at);
    if (kind != 'unknown') await inventory.classify(receipt, kind);
    return (id: admission.messageId, receipt: receipt);
  }

  Future<Map> work(String id) async =>
      (await (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, buyer, id]))
          .single;

  Future<String?> begin(String id) async => db.beginGeneration(
      customer: buyer,
      pendingId: (await db.conversation(buyer))!.id,
      batchEndMessageId: id);

  AiDraft answer(String reply, {Map<String, String> dependencies = const {}}) =>
      AiDraft.fromJson({
        'reply': reply,
        'decision': 'draft',
        'reply_purpose': 'substantive',
        'confidence': 1,
        'risk_level': 'low',
        'auto_send_allowed': true,
        'model': 'controlled-v62-text-timeline',
        'reply_media_dependency_keys': dependencies,
      }, mediaBaseUrl: Uri());

  Future<AutomaticDraftSaveResult> save(
          String id, String token, AiDraft draft) async =>
      db.saveAutomaticDraft((await db.conversation(buyer))!.id,
          await db.prepareAutomaticDraft(buyer, draft),
          expectedMessageId: id, expectedUserId: buyer, generationToken: token);

  Future<void> submit() async {
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: delivery.draft.reply, taskId: delivery.taskId!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'timeMs': now,
      'sendClickedAtMs': now,
    }));
    await db.recoverDeliveryReceipts();
    await db.abandonGeneration(buyer, delivery.taskId!);
  }

  test('reported signed-parcel text escapes old dependency-preflight wait',
      () async {
    final unknown = await media();
    final question = await text('这是你们已签收了的，上一个客服给我说没有查到这个单子', 2);
    final sql = await db.database;
    await sql.insert('automation_message_waits', {
      'session_id': session,
      'user_id': buyer,
      'message_id': question,
      'is_media': 0,
      'content_key': jsonEncode({unknown.receipt: ''}),
      'message_revision': (await work(question))['work_revision'],
      'task_id': 'dependency-preflight:$question',
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final token = (await begin(question))!;
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
    final input = (await db.generationMessages(buyer))
        .where((m) => m['direction'] == 'incoming')
        .toList();
    expect(input.map((m) => m['id']), [question]);
    expect(input.single['reply_input_kind'], 'text');
    expect(input.single['reply_media_input_dependencies'], isEmpty);
    expect(await sql.query('automation_message_waits'), isEmpty);
    final result = await save(
        question,
        token,
        answer('请提供这个快递的单号，我帮您核实签收记录。', dependencies: {
          unknown.receipt: 'old-unready-context',
        }));
    expect(result.queued, isTrue);
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    expect((jsonDecode(delivery.draft.rawJson) as Map)['service_message_ids'],
        [question]);
    expect(
        (jsonDecode(delivery.draft.rawJson)
            as Map)['reply_media_dependency_keys'],
        isEmpty);
    await submit();
    expect(await db.isMessageFormallyAnswered(buyer, question), isTrue);
    expect((await work(unknown.id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
  });

  test('explicit image reference with capture adjacency is still text work',
      () async {
    final photo = await media(kind: 'image');
    final question = await text('Please inspect the image I sent.', 2,
        dependency: photo.receipt);
    final token = (await begin(question))!;
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
    expect(
        (await db.generationMessages(buyer)).last['reply_input_kind'], 'text');
    expect(
        (await save(question, token,
                answer('Which part of the printer is failing?')))
            .queued,
        isTrue);
    await submit();
    expect(await db.isMessageFormallyAnswered(buyer, question), isTrue);
    expect(await db.isMessageFormallyAnswered(buyer, photo.id), isFalse);
    expect(await db.unansweredWorkCounts(), {buyer: 1});
  });

  test('stale frozen text dependency metadata cannot reinstate a media wait',
      () async {
    final photo = await media(kind: 'image');
    final question = await text('What does this photo mean?', 2);
    final token = (await begin(question))!;
    final sql = await db.database;
    final frozen = (await sql.query('automation_reply_inputs',
            where: 'owner_id=? AND message_id=?', whereArgs: [token, question]))
        .single;
    final message = jsonDecode(frozen['message_json']! as String) as Map;
    await sql.update(
        'automation_reply_inputs',
        {
          'message_json': jsonEncode({
            ...message,
            'reply_media_input_dependencies': [photo.receipt],
          })
        },
        where: 'owner_id=? AND message_id=?',
        whereArgs: [token, question]);
    await db.registerMediaInputDependency(buyer,
        textMessageId: question,
        receiptId: photo.receipt,
        evidenceId: 'capture-after-generation');
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
    expect(
        (await db.generationMessages(buyer))
            .last['reply_media_input_dependencies'],
        isEmpty);
    expect(
        (await save(question, token,
                answer('Please tell me the model and describe the problem.')))
            .queued,
        isTrue);
    expect(await db.nextReadyDelivery(userId: buyer), isNotNull);
    expect((await work(photo.id))['response_state'], 'pending');
  });

  test('old text media-status wait is cleared but a status-only answer repairs',
      () async {
    await media(kind: 'image');
    final question = await text('How long is the warranty?', 2);
    final sql = await db.database;
    await sql.insert('automation_message_waits', {
      'session_id': session,
      'user_id': buyer,
      'message_id': question,
      'is_media': 0,
      'content_key': 'unchanged-media-key',
      'message_revision': (await work(question))['work_revision'],
      'task_id': 'old-media-status-task',
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final token = (await begin(question))!;
    final result = await save(
        question, token, answer('Please wait while I check the issue.'));
    expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    final waits = await sql.query('automation_message_waits',
        where: 'message_id=?', whereArgs: [question]);
    expect(waits.single['content_key'], startsWith('answer-repair:'));
    expect((await work(question))['response_state'], 'pending');
  });

  test(
      'unready media cannot generate alone or be answered by a later text reply',
      () async {
    final photo = await media(kind: 'image');
    expect(await begin(photo.id), isNull);
    final first = await text('What is the warranty?', 2);
    final token = (await begin(first))!;
    expect(
        (await save(first, token, answer('The warranty is one year.'))).queued,
        isTrue);
    final second = await text('Does it include the print head?', 3);
    await submit();
    expect((await work(first))['response_state'], 'answered');
    expect((await work(photo.id))['response_state'], 'pending');
    expect((await work(second))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 2});
    final next = (await begin(second))!;
    expect(
        (await db.generationMessages(buyer))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        [second]);
    expect(await db.generationInputsAnalysisReady(buyer, generationToken: next),
        isTrue);
  });

  Future<void> oldSessionClock() async {
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 240000,
        isUtc: true);
    session = await db.beginAutomationSession(startedAt: start);
  }

  test('expired unverified media remains pending and eligible for acquisition',
      () async {
    await oldSessionClock();
    final unknown = await media();
    final policy = await db.processIncompleteImagePolicy(buyer);
    expect(policy.queuedResponse, isFalse);
    expect(policy.retiredMessageIds, isEmpty);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    expect((await work(unknown.id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect(await db.isIncompleteImageAcquisitionAllowed(buyer, unknown.id),
        isTrue);
    expect(await inventory.pendingMediaForTask(buyer), isNotEmpty);

    await inventory.classify(unknown.receipt, 'image');
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isTrue);
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    final raw = jsonDecode(delivery.draft.rawJson) as Map;
    expect(raw['service_message_ids'], [unknown.id]);
    expect((raw['image_resend_policy'] as Map)['source_kind'], 'image');
    expect(delivery.draft.reply, FixedReplies.incompleteImageResend);
  });

  test('continued chat keeps expired unknown media and answers the text',
      () async {
    await oldSessionClock();
    final unknown = await media();
    final question = await text('How can I request an invoice?', 200);
    final result = await db.processIncompleteImagePolicy(buyer);
    expect(result.queuedResponse, isFalse);
    expect(result.retiredMessageIds, isEmpty);
    expect((await work(unknown.id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 2});
    final token = (await begin(question))!;
    expect(
        (await save(question, token,
                answer('Please send the invoice title and tax number.')))
            .queued,
        isTrue);
    await submit();
    expect((await work(question))['response_state'], 'answered');
    await inventory.classify(unknown.receipt, 'video');
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect((await work(unknown.id))['response_state'], 'pending');
    expect(await inventory.pendingMediaForTask(buyer), isNotEmpty);
    expect(await db.unansweredWorkCounts(), {buyer: 1});
  });

  for (final state in ['detected', 'awaiting_kind']) {
    test('unproved image flag in $state remains available for classification',
        () async {
      await oldSessionClock();
      final unknown = await media(kind: 'image');
      await (await db.database).update(
          'customer_media_items',
          {
            'state': state,
            'media_json': jsonEncode([
              {
                'type': 'image',
                'type_verification': 'pending',
                'is_partial': true
              }
            ]),
          },
          where: 'item_id=?',
          whereArgs: [unknown.receipt]);
      final result = await db.processIncompleteImagePolicy(buyer);
      expect(result.queuedResponse, isFalse);
      expect(result.retiredMessageIds, isEmpty);
      expect(await db.nextReadyDelivery(userId: buyer), isNull);
      expect(await db.isIncompleteImageAcquisitionAllowed(buyer, unknown.id),
          isTrue);
      expect((await work(unknown.id))['input_kind'], 'media');
      expect((await work(unknown.id))['response_state'], 'pending');
      expect(await db.isMessageFormallyAnswered(buyer, unknown.id), isFalse);
    });
  }

  test('positive video material never receives the generic image timeout',
      () async {
    await oldSessionClock();
    final video = await media(kind: 'video');
    final uncertain = await media(second: 2);
    await (await db.database).update(
        'customer_media_items',
        {
          'media_json': jsonEncode([
            {'type': 'video', 'path': '/owned-customer-original.mp4'}
          ]),
        },
        where: 'item_id=?',
        whereArgs: [uncertain.receipt]);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect((await work(video.id))['response_state'], 'pending');
    expect((await work(uncertain.id))['response_state'], 'pending');
    expect(
        await db.isIncompleteImageAcquisitionAllowed(buyer, video.id), isTrue);
    expect(await db.isIncompleteImageAcquisitionAllowed(buyer, uncertain.id),
        isTrue);
  });

  test('restart cannot resume old unknown dispositions or old text waits',
      () async {
    await oldSessionClock();
    final unknown = await media();
    await db.processIncompleteImagePolicy(buyer);
    session =
        await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.incompleteImagePolicyCustomers(), isEmpty);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await db.isMessageFormallyAnswered(buyer, unknown.id), isFalse);
  });

  test('missing inventory restores only the original live observation receipt',
      () async {
    final item = await media();
    final sql = await db.database;
    await sql.delete('customer_media_items',
        where: 'item_id=?', whereArgs: [item.receipt]);
    expect(await inventory.pendingMediaForTask(buyer), isEmpty);
    await db.repairSessionPendingWork(buyer);
    final roots = await sql.query('customer_media_items');
    expect(roots, hasLength(1));
    expect(roots.single['item_id'], item.receipt);
    expect(roots.single['message_id'], item.id);
    expect(roots.single['admission_session_id'], session);
    expect(roots.single['kind'], 'unknown');
    expect(roots.single['state'], 'detected');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect(await inventory.pendingMediaForTask(buyer), hasLength(1));
    expect((await (await db.history).read(buyer))!['messages'], hasLength(1));
    expect(
        await db.generationInputsAnalysisReady(buyer,
            generationToken: 'not-a-real-generation'),
        isFalse);
  });

  test('missing inventory without original provenance never invents a receipt',
      () async {
    final item = await media();
    final sql = await db.database;
    await sql.delete('customer_media_items',
        where: 'item_id=?', whereArgs: [item.receipt]);
    await sql.delete('media_card_observations',
        where: 'item_id=?', whereArgs: [item.receipt]);
    await db.repairSessionPendingWork(buyer);
    expect(await sql.query('customer_media_items'), isEmpty);
    expect((await work(item.id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect((await (await db.history).read(buyer))!['messages'], hasLength(1));
  });

  Future<({String id, String receipt, File file})> fullPhoto() async {
    final item = await media(kind: 'image');
    final file = await File('${root.path}/original.png').writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB1kAAAAASUVORK5CYII='));
    final message = CapturedMessage(
        stableId: item.id,
        direction: 'incoming',
        sender: buyer,
        sentAt: start.add(const Duration(seconds: 1)),
        body: '[Customer sent an image.]',
        mediaReceiptId: item.receipt,
        captureEvidenceId: 'media-frame-1',
        axPath: 'exact-current-customer',
        media: [
          CapturedMedia(
              type: 'image', path: file.path, captureSource: 'jd-image-cache')
        ]);
    await db.saveCapture(capture(message));
    await inventory.persist(capture(message));
    expect(await inventory.analysisReadyMessageIds(buyer), contains(item.id));
    return (id: item.id, receipt: item.receipt, file: file);
  }

  test('missing photo files release only unclicked draft for later text',
      () async {
    final photo = await fullPhoto();
    final old = (await begin(photo.id))!;
    expect(
        (await save(photo.id, old,
                answer('Please reseat the paper roll shown in your photo.')))
            .queued,
        isTrue);
    await db.abandonGeneration(buyer, old);
    await photo.file.delete();
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    final question = await text('How can I get an invoice?', 2);
    final next = (await begin(question))!;
    expect(next, isNot(old));
    expect(
        (await db.generationMessages(buyer))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        [question]);
    expect((await work(photo.id))['response_state'], 'pending');
    expect(await db.isMessageFormallyAnswered(buyer, photo.id), isFalse);
    expect(
        (await save(question, next,
                answer('Please send the invoice title and tax number.')))
            .queued,
        isTrue);
    await submit();
    expect((await work(question))['response_state'], 'answered');
    expect((await work(photo.id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect(await inventory.pendingMediaForTask(buyer), hasLength(1));
  });

  test('missing media cannot retire possibly-clicked native ownership',
      () async {
    final photo = await fullPhoto();
    final token = (await begin(photo.id))!;
    const reply = 'Please reseat the paper roll shown in your photo.';
    expect((await save(photo.id, token, answer(reply))).queued, isTrue);
    await db.abandonGeneration(buyer, token);
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: reply, taskId: token);
    await db.markGeneratedDraftDeliveryFailure(
        userId: buyer,
        taskId: token,
        error: 'send_unconfirmed after native attempt');
    await photo.file.delete();
    await text('Can I also get an invoice?', 2);
    await db.repairSessionPendingWork(buyer);
    final sql = await db.database;
    final draft = (await sql.query('generated_drafts')).single;
    expect(draft['delivery_state'], 'delivery_unknown');
    expect(draft['task_id'], token);
    expect(draft['attempt_id'], attempt['attemptId']);
    expect(
        (await sql.query('delivery_attempts',
                where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
            .single['state'],
        'unknown');
    expect((await work(photo.id))['response_state'], 'pending');
    expect(await db.isMessageFormallyAnswered(buyer, photo.id), isFalse);
    expect(await db.reconciliationWork(), isNotEmpty);
  });

  for (final continued in [false, true]) {
    test(
        'metadata-ready missing photo follows existing expiry; continued=$continued',
        () async {
      await oldSessionClock();
      final photo = await fullPhoto();
      expect(
          (await (await db.database).query('customer_media_items',
                  where: 'item_id=?', whereArgs: [photo.receipt]))
              .single['state'],
          'ready');
      await photo.file.delete();
      final question =
          continued ? await text('How long is the warranty?', 200) : null;
      final result = await db.processIncompleteImagePolicy(buyer);
      if (continued) {
        expect(result.queuedResponse, isFalse);
        expect((await work(photo.id))['response_state'], 'skipped_image');
        expect((await work(question!))['response_state'], 'pending');
        expect(await begin(question), isNotNull);
      } else {
        expect(result.queuedResponse, isTrue);
        expect((await db.nextReadyDelivery(userId: buyer))!.draft.reply,
            FixedReplies.incompleteImageResend);
        await submit();
        expect((await work(photo.id))['response_state'], 'resend_requested');
      }
      expect(await db.isMessageFormallyAnswered(buyer, photo.id), isFalse);
      expect(await db.isIncompleteImageAcquisitionAllowed(buyer, photo.id),
          isFalse);
    });
  }
}
