import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/fixed_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'image-timeout-buyer';
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime start;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v60_image_policy_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 300000,
        isUtc: true);
    session = await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
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

  Future<String> text(String body, int second) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(capture(CapturedMessage(
        stableId: 'incoming-$second',
        direction: 'incoming',
        sender: buyer,
        sentAt: at,
        body: body,
        axPath: 'exact-customer-original',
        captureEvidenceId: 'text-frame-$second')));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<({String id, String receipt, DateTime at})> image(
      {int second = 0,
      bool partial = true,
      String kind = 'image',
      String? source,
      bool pendingType = false}) async {
    final at = start.add(Duration(seconds: second));
    final evidence = 'image-frame-$second';
    const region = [.27, .55, .08, .2];
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: evidence,
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: region,
        current: true);
    final admission = await db.admitMediaMessage(buyer,
        receiptId: receipt,
        evidenceId: evidence,
        occurrenceKey: 'image-$second',
        receivedAt: at,
        senderAt: at);
    await inventory.classify(receipt, kind,
        fingerprint: 'ffffc0c1fffffefe', evidenceId: evidence, region: region);
    await File('${root.path}/$second.png').writeAsBytes([1, 2, 3]);
    final original = CapturedMessage(
        stableId: admission.messageId,
        direction: 'incoming',
        sender: buyer,
        sentAt: at,
        body: '[Customer sent an $kind; acquisition pending.]',
        axPath: 'real-clock-image-card',
        captureEvidenceId: evidence,
        mediaReceiptId: receipt,
        media: [
          CapturedMedia(
              type: kind,
              path: '${root.path}/$second.png',
              captureSource: source ??
                  (partial
                      ? 'verified_chat_viewport_fallback'
                      : 'jd-image-cache'),
              isPartial: partial)
        ]);
    await db.saveCapture(capture(original));
    await inventory.persist(capture(original));
    if (pendingType) {
      await (await db.database).update(
          'customer_media_items',
          {
            'media_json': jsonEncode([
              {
                'type': 'image',
                'type_verification': 'pending',
                'is_partial': true
              }
            ]),
          },
          where: 'item_id=?',
          whereArgs: [receipt]);
    }
    return (id: admission.messageId, receipt: receipt, at: at);
  }

  Future<Map> work(String id) async =>
      (await (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, buyer, id]))
          .single;

  Future<void> confirmCurrent() async {
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: delivery.draft.reply, taskId: delivery.taskId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'timeMs': now,
      'sendClickedAtMs': now,
    }));
    expect(
        await db.markReplySent(
            userId: buyer,
            reply: delivery.draft.reply,
            expectedTaskId: delivery.taskId),
        isTrue);
  }

  test('a pending image remains eligible after three minutes and newer text',
      () async {
    final item = await image();
    await text('另一个问题', 60);
    expect(
        await db.isIncompleteImageAcquisitionAllowed(buyer, item.id,
            now: start.add(const Duration(minutes: 10))),
        isTrue);
    expect((await work(item.id))['response_state'], 'pending');
  });

  test(
      'three-minute original clock queues one confirmed resend, never a fake answer',
      () async {
    final item = await image();
    expect(
        (await db.processIncompleteImagePolicy(buyer,
                now: start.add(const Duration(seconds: 179))))
            .queuedResponse,
        isFalse);
    final due = await db.processIncompleteImagePolicy(buyer,
        now: start.add(const Duration(minutes: 3)));
    expect(due.queuedResponse, isTrue);
    expect(due.retiredMessageIds, {item.id});
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    expect(delivery.draft.reply, FixedReplies.incompleteImageResend);
    expect((jsonDecode(delivery.draft.rawJson) as Map)['service_message_ids'],
        [item.id]);
    expect(await db.isMessageFormallyAnswered(buyer, item.id), isFalse);
    expect((await db.customerMessageRecords(buyer)).single.status,
        'image_resend_pending');
    final task = delivery.taskId;
    await db.processIncompleteImagePolicy(buyer);
    expect((await db.nextReadyDelivery(userId: buyer))!.taskId, task);
    await confirmCurrent();
    expect((await work(item.id))['response_state'], 'resend_requested');
    expect(await db.isMessageFormallyAnswered(buyer, item.id), isFalse);
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect((await db.customerMessageRecords(buyer)).single.status,
        'resend_requested');
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    expect(
        await db.isIncompleteImageAcquisitionAllowed(buyer, item.id), isFalse);
  });

  test(
      'continued original chat skips only old image and stops future acquisition',
      () async {
    final item = await image();
    final question = await text('How long is the warranty?', 60);
    final result = await db.processIncompleteImagePolicy(buyer);
    expect(result.queuedResponse, isFalse);
    expect((await work(item.id))['response_state'], 'skipped_image');
    expect((await work(question))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect(
        (await db.customerMessageRecords(buyer)).first.status, 'skipped_image');
    expect(
        await db.isIncompleteImageAcquisitionAllowed(buyer, item.id), isFalse);
    expect(await inventory.pendingMediaForTask(buyer), isEmpty);
    expect(await db.generationAnchorMessageId(buyer), question);
  });

  test(
      'new input before insertion cancels queued unsolicited resend and preserves question',
      () async {
    final item = await image();
    await db.processIncompleteImagePolicy(buyer);
    final old = (await db.nextReadyDelivery(userId: buyer))!;
    final question = await text('What is the price?', 220);
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: buyer, reply: old.draft.reply, taskId: old.taskId),
        isFalse);
    await db.processIncompleteImagePolicy(buyer);
    expect((await work(item.id))['response_state'], 'skipped_image');
    expect((await work(question))['response_state'], 'pending');
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    expect(await db.generationAnchorMessageId(buyer), question);
  });

  test('later simple reference gets one resend and covers only that text',
      () async {
    final item = await image();
    final other = await text('How long is the warranty?', 60);
    await db.processIncompleteImagePolicy(buyer);
    final reference = await text('Please check the photo I sent earlier.', 230);
    final result = await db.processIncompleteImagePolicy(buyer);
    expect(result.queuedResponse, isTrue);
    final draft = (await db.nextReadyDelivery(userId: buyer))!;
    expect((jsonDecode(draft.draft.rawJson) as Map)['service_message_ids'],
        [reference]);
    expect(draft.draft.reply, contains('network'));
    await confirmCurrent();
    expect((await work(item.id))['response_state'], 'resend_requested');
    expect((await work(reference))['response_state'], 'answered');
    expect((await work(other))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    final record = (await db.customerMessageRecords(buyer))
        .singleWhere((record) => record.stableId == item.id);
    expect(record.status, 'resend_requested');
    expect(record.repliedAt, isNotNull);
  });

  test('mixed reference stays a real question with durable resend instruction',
      () async {
    final item = await image();
    await text('hello', 60);
    await db.processIncompleteImagePolicy(buyer);
    final question = await text(
        'Please check the photo I sent earlier. Also, how long is the warranty?',
        230);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    final messages = await db.processingMessages(buyer);
    final row = messages.singleWhere((m) => m['id'] == question);
    expect(row['incomplete_image_resend_required'],
        containsPair('expired_image_message_ids', [item.id]));
    final pending = (await db.conversation(buyer))!;
    final token = await db.beginGeneration(
        customer: buyer, pendingId: pending.id, batchEndMessageId: question);
    expect(token, isNotNull);
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token!),
        isTrue);
    expect(
        (await db.generationMessages(buyer)).singleWhere(
            (m) => m['id'] == question)['incomplete_image_resend_required'],
        isNotNull);
    expect((await work(item.id))['response_state'], 'skipped_image');
  });

  test(
      'late material/reread cannot revive skipped image and a new image stays independent',
      () async {
    final old = await image();
    await text('hello', 60);
    await db.processIncompleteImagePolicy(buyer);
    await db.reopenMessageForNewEvidence(buyer, old.id,
        evidenceKey: 'late-new-frame');
    await db.repairSessionPendingWork(buyer);
    expect((await work(old.id))['response_state'], 'skipped_image');
    final newImage = await image(second: 230, partial: false);
    final reference = await text('Please check this picture.', 240);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect(
        (await db.processingMessages(buyer)).singleWhere(
            (m) => m['id'] == reference)['incomplete_image_resend_required'],
        isNull);
    expect((await work(newImage.id))['response_state'], 'pending');
    expect(
        await inventory.analysisReadyMessageIds(buyer), contains(newImage.id));
    expect((await work(old.id))['response_state'], 'skipped_image');
  });

  test(
      'two original images stay separate; only latest unanswered image asks resend',
      () async {
    final first = await image();
    final second = await image(second: 2);
    final result = await db.processIncompleteImagePolicy(buyer);
    expect(result.queuedResponse, isTrue);
    expect((await work(first.id))['response_state'], 'skipped_image');
    final raw =
        jsonDecode((await db.nextReadyDelivery(userId: buyer))!.draft.rawJson)
            as Map;
    expect(raw['service_message_ids'], [second.id]);
    expect((await (await db.history).read(buyer))!['messages'], hasLength(2));
  });

  for (final mode in ['video', 'video_cover']) {
    test('$mode never receives the image-only timeout disposition', () async {
      final item = await image(
          kind: mode == 'video' ? 'video' : 'image',
          pendingType: mode == 'pending_type',
          source: mode == 'video_cover' ? 'jd_video_cover' : null);
      expect((await db.processIncompleteImagePolicy(buyer)).queuedResponse,
          isFalse);
      expect((await work(item.id))['response_state'], 'pending');
      expect(
          await db.isIncompleteImageAcquisitionAllowed(buyer, item.id), isTrue);
    });
  }

  test('restart does not resume prior session expired image business',
      () async {
    final item = await image();
    await db.processIncompleteImagePolicy(buyer);
    session =
        await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect((await db.processIncompleteImagePolicy(buyer)).changed, isFalse);
    expect(await db.incompleteImagePolicyCustomers(), isEmpty);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    expect((await (await db.history).read(buyer))!['messages'], isNotEmpty);
    expect(await db.isMessageFormallyAnswered(buyer, item.id), isFalse);
  });

  for (final disposition in ['skipped_image', 'resend_requested']) {
    test('exact v56 proof corrects expired $disposition without reviving media',
        () async {
      final item = await image();
      await (await db.database).insert('media_capture_audit', {
        'observation_id': 'weak-audit',
        'evidence_id': 'image-frame-0',
        'customer': buyer,
        'state': 'image_partial',
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        'details': jsonEncode({
          'automationSessionId': session,
          'parentMessageId': item.id,
          'mediaReceiptId': item.receipt,
          'kind': 'image',
          'source': 'frozen-window-crop',
          'isPartial': true,
          'reason': 'visible_crop_only',
          'playbackOverlayDetected': false,
        }),
      });
      if (disposition == 'skipped_image') await text('hello', 60);
      await db.processIncompleteImagePolicy(buyer);
      if (disposition == 'resend_requested') await confirmCurrent();
      expect((await work(item.id))['response_state'], disposition);
      final corrected = await db.clarifyWeakImageMessageAsText(buyer,
          parentMessageId: item.id,
          receiptId: item.receipt,
          text: CapturedMessage(
              stableId: item.id,
              direction: 'incoming',
              sender: buyer,
              sentAt: item.at,
              body: 'ok',
              captureEvidenceId: 'exact-text-reading',
              axPath: 'confirmed original customer text'),
          evidenceId: 'exact-text-reading',
          expectedSessionId: session);
      expect(corrected, item.id);
      expect((await work(item.id))['input_kind'], 'text');
      expect((await work(item.id))['response_state'], 'pending');
      expect((await db.retiredIncompleteImageMessageIds(buyer)),
          isNot(contains(item.id)));
      expect(await inventory.pendingMediaForTask(buyer), isEmpty);
      final original =
          ((await (await db.history).read(buyer))!['messages'] as List)
              .cast<Map>()
              .singleWhere((m) => m['id'] == item.id);
      expect(original['body'], 'ok');
      expect(original['media'], isEmpty);
      expect(await db.isMessageFormallyAnswered(buyer, item.id), isFalse);
    });
  }

  test('expired real cache image cannot use weak screenshot correction',
      () async {
    final item = await image(source: 'jd-image-cache');
    await text('hello', 60);
    await db.processIncompleteImagePolicy(buyer);
    expect(
        await db.clarifyWeakImageMessageAsText(buyer,
            parentMessageId: item.id,
            receiptId: item.receipt,
            text: CapturedMessage(
                stableId: item.id,
                direction: 'incoming',
                sender: buyer,
                sentAt: item.at,
                body: 'ok',
                captureEvidenceId: 'unrelated-text',
                axPath: 'text'),
            evidenceId: 'unrelated-text',
            expectedSessionId: session),
        isNull);
    expect((await work(item.id))['response_state'], 'skipped_image');
  });

  test(
      'late model waiting result cannot overwrite the durable expired-image decision',
      () async {
    final item = await image();
    final sql = await db.database;
    const oldToken = 'already-submitted-legacy-request';
    await sql.update('pending_customers', {'generation_token': oldToken},
        where: 'user_id=?', whereArgs: [buyer]);
    final original =
        ((await (await db.history).read(buyer))!['messages'] as List)
            .cast<Map>()
            .singleWhere((m) => m['id'] == item.id);
    final originalWork = await work(item.id);
    await sql.insert('automation_reply_inputs', {
      'session_id': session,
      'user_id': buyer,
      'owner_id': oldToken,
      'message_id': item.id,
      'message_revision': originalWork['work_revision'],
      'message_json': jsonEncode(original),
    });
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    final before =
        (await sql.query('automation_message_waits')).single['content_key'];
    final pending = (await db.conversation(buyer))!;
    final old = AiDraft.fromJson({
      'reply': 'I am still checking this image.',
      'model': 'old-running-model',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'reply_purpose': 'review_status',
      'media_dependent': true,
      'reply_media_dependency_keys': <String, String>{},
    }, mediaBaseUrl: Uri());
    final saved = await db.saveAutomaticDraft(pending.id, old,
        expectedMessageId: item.id,
        expectedUserId: buyer,
        generationToken: oldToken);
    expect(saved.legacyCount, 0);
    expect((await sql.query('automation_message_waits')).single['content_key'],
        before);
    expect(
        await db.isIncompleteImageAcquisitionAllowed(buyer, item.id), isFalse);
    await db.abandonGeneration(buyer, oldToken);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isTrue);
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isFalse);
    expect(await sql.query('generated_drafts'), hasLength(1));
  });

  test('durable pending image can recover a missing customer scheduling row',
      () async {
    final item = await image();
    await (await db.database)
        .delete('pending_customers', where: 'user_id=?', whereArgs: [buyer]);
    expect(await db.incompleteImagePolicyCustomers(), contains(buyer));
    expect(
        (await db.processIncompleteImagePolicy(buyer)).queuedResponse, isTrue);
    expect((await db.nextReadyDelivery(userId: buyer))!.draft.reply,
        FixedReplies.incompleteImageResend);
    expect((await work(item.id))['response_state'], 'pending');
  });

  test(
      'uncertain native notice never retypes; later chat can continue separately',
      () async {
    final item = await image();
    await db.processIncompleteImagePolicy(buyer);
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: delivery.draft.reply, taskId: delivery.taskId);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.markGeneratedDraftDeliveryFailure(
        userId: buyer, error: 'send_unconfirmed', taskId: delivery.taskId);
    await db.processIncompleteImagePolicy(buyer);
    expect(await db.nextReadyDelivery(userId: buyer), isNull);
    final attempts = await (await db.database).query('delivery_attempts');
    expect(attempts, hasLength(1));
    expect((await work(item.id))['response_state'], 'pending');
    final question = await text('What is the price?', 240);
    await db.processIncompleteImagePolicy(buyer);
    expect((await work(item.id))['response_state'], 'skipped_image');
    expect((await work(question))['response_state'], 'pending');
    expect(await db.detachUnknownForNewInput(buyer), isTrue);
    expect(await db.generationAnchorMessageId(buyer), question);
    final pending = (await db.conversation(buyer))!;
    expect(
        await db.beginGeneration(
            customer: buyer,
            pendingId: pending.id,
            batchEndMessageId: question),
        isNotNull);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'timeMs': now,
      'sendClickedAtMs': now,
    }));
    await db.recoverDeliveryReceipts();
    expect((await work(question))['response_state'], 'pending');
    expect(await db.isMessageFormallyAnswered(buyer, item.id), isFalse);
    expect(
        (await (await db.database).query('delivery_attempts')), hasLength(1));
  });
}
