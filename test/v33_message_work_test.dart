import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

const _answer = AiDraft(
  reply: 'The printer supports USB and Wi-Fi.',
  decision: 'draft',
  confidence: 1,
  riskLevel: 'low',
  model: 'fixture',
  usedRecordIds: [],
  actions: [],
  attachments: [],
  rawJson:
      '{"reply":"The printer supports USB and Wi-Fi.","decision":"draft","confidence":1,"risk_level":"low","model":"fixture"}',
);

void main() {
  late Directory root;
  late CaptureDatabase db;
  late DateTime started;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v33_message_work_');
    db = CaptureDatabase(storageRoot: root);
    started = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
    await db.beginAutomationSession(startedAt: started);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedMessage question(String id, {DateTime? sentAt}) => CapturedMessage(
      stableId: id,
      direction: 'incoming',
      body: 'Question $id needs a specific answer.',
      sentAt: sentAt ?? DateTime.now().toUtc(),
      axPath: 'fixture');
  CapturedConversation frame(List<CapturedMessage> messages) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now().toUtc(),
          messages: messages);
  Future<void> receive(String id,
      {DateTime? sentAt, Set<String>? allowed}) async {
    await db.saveCapture(frame([question(id, sentAt: sentAt)]),
        activeIncomingIds: allowed);
  }

  Future<List<String>> pendingIds() async =>
      (await db.processingMessages('buyer'))
          .where((m) => m['direction'] == 'incoming')
          .map((m) => m['id']! as String)
          .toList();
  Future<String> freeze(String end) async {
    final queued = (await db.conversation('buyer'))!;
    return (await db.beginGeneration(
        customer: 'buyer', pendingId: queued.id, batchEndMessageId: end))!;
  }

  Future<void> draft(String end, {String? token}) async {
    final queued = (await db.conversation('buyer'))!;
    expect(
        await db.saveDraft(queued.id, _answer,
            expectedMessageId: end, generationToken: token),
        1);
  }

  Future<void> submitted(Map<String, String> attempt) async {
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<bool> confirmNativeDraft() async {
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    await submitted(attempt);
    return !await db.hasUndeliveredDraft('buyer');
  }

  test('same live bubble can activate after it was saved but excluded',
      () async {
    await receive('saved-first', allowed: {});
    expect(await pendingIds(), isEmpty);
    await receive('saved-first', allowed: {'saved-first'});
    expect(await pendingIds(), ['saved-first']);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
  test('repair consumes durable current live stamp without a visible frame',
      () async {
    await (await db.history).appendCapture(frame([question('offscreen')]));
    expect(await db.repairSessionPendingWork('buyer'), isTrue);
    expect(await pendingIds(), ['offscreen']);
    expect(await db.pendingMessageId('buyer'), 'offscreen');
  });
  test(
      'history-only stamp cannot create business and Start baseline remains excluded',
      () async {
    await (await db.history)
        .appendCapture(frame([question('history')]), historyOnly: true);
    expect(await db.repairSessionPendingWork('buyer'), isFalse);
    await receive('previous-run');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await receive('previous-run');
    expect(await db.repairSessionPendingWork('buyer'), isFalse);
    expect(await pendingIds(), isEmpty);
  });
  test('old sender clock and outgoing cursor do not expire a late question',
      () async {
    await receive('first');
    await draft('first');
    expect(await confirmNativeDraft(), isTrue);
    await receive('late-earlier',
        sentAt: started.subtract(const Duration(hours: 2)));
    expect(await pendingIds(), ['late-earlier']);
    expect(await db.isMessageFormallyAnswered('buyer', 'first'), isTrue);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'late-earlier'), isFalse);
    expect(await db.pendingMessageId('buyer'), 'late-earlier');
  });
  test(
      'generation freezes only known input despite a later earlier-position question',
      () async {
    await receive('known');
    final token = await freeze('known');
    await receive('late-earlier',
        sentAt: started.subtract(const Duration(minutes: 3)));
    final input =
        await db.generationMessages('buyer', batchEndMessageId: 'known');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['known']);
    await draft('known', token: token);
    final stored = (await (await db.database).query('generated_drafts')).single;
    expect(
        (jsonDecode(stored['raw_json']! as String)
            as Map)['service_message_ids'],
        ['known']);
    expect(await confirmNativeDraft(), isTrue);
    expect(await pendingIds(), ['late-earlier']);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    final context = await db.processingMessages('buyer', includeAnswered: true);
    expect(context.singleWhere((m) => m['id'] == 'known')['reply_work_state'],
        'answered');
    expect(
        context
            .singleWhere((m) => m['id'] == 'late-earlier')['reply_work_state'],
        'pending');
  });
  test(
      'repeated captions never cancel or retire a frozen current-session media answer',
      () async {
    final image = File('${root.path}/original.png');
    await image.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII='));
    final at = DateTime.now().toUtc();
    final receipt = await CustomerMediaInventory(db).observe(
        customer: 'buyer',
        evidenceId: 'caption-media',
        occurrenceKey: 'caption-media',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await CustomerMediaInventory(db).classify(receipt, 'image');
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: 'media', receivedAt: at, senderAt: at);
    final original = frame([
      CapturedMessage(
          stableId: 'media',
          direction: 'incoming',
          body: 'Photo question',
          sentAt: at,
          axPath: 'fixture',
          mediaReceiptId: receipt,
          media: [
            CapturedMedia(
                type: 'image',
                path: image.path,
                captureSource: 'jd_image_cache')
          ])
    ]);
    await db.saveCapture(original);
    // The production capture commits its verified original to inventory
    // before a media generation can begin. Caption ownership below remains
    // the subject of this test, not the no-content waiting gate.
    await CustomerMediaInventory(db).persist(original, verifiedAnchor: true);
    expect(await db.generationDue('buyer'), isTrue);
    final token = await freeze('media');
    for (var i = 0; i < 4; i++) {
      final caption = frame(
          [question('caption-$i', sentAt: at.add(Duration(seconds: i + 1)))]);
      await db.saveCapture(caption);
      expect(await db.mergeMediaCaptionBatch('buyer', caption), isEmpty);
    }
    await draft('media', token: token);
    final reread = frame(
        [question('caption-0', sentAt: at.add(const Duration(seconds: 1)))]);
    expect(await db.mergeMediaCaptionBatch('buyer', reread), isEmpty);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    final saved = (await (await db.database).query('generated_drafts')).single;
    expect(saved['task_id'], token);
    expect(saved['delivery_state'], 'ready');
    await confirmNativeDraft();
    expect(await pendingIds(),
        containsAll(['caption-0', 'caption-1', 'caption-2', 'caption-3']));
  });
  test(
      'new tail cannot starve an older pending generation and cannot replace its active lease',
      () async {
    await receive('known');
    final queued = (await db.conversation('buyer'))!;
    final snapshotEnd = (await db.pendingMessageId('buyer'))!;
    await receive('later');
    final token = await db.beginGeneration(
        customer: 'buyer',
        pendingId: queued.id,
        batchEndMessageId: snapshotEnd);
    expect(token, isNotNull);
    expect(
        await db.beginGeneration(
            customer: 'buyer',
            pendingId: queued.id,
            batchEndMessageId: 'later'),
        isNull);
    final input =
        await db.generationMessages('buyer', batchEndMessageId: snapshotEnd);
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['known']);
    await draft(snapshotEnd, token: token);
    await confirmNativeDraft();
    expect(await pendingIds(), ['later']);
    await db.abandonGeneration('buyer', token!);
    expect(await freeze('later'), isNotEmpty);
  });
  test('generation scope mismatch returns no input rather than another batch',
      () async {
    await receive('known');
    await freeze('known');
    await receive('later');
    expect(await db.generationMessages('buyer', batchEndMessageId: 'later'),
        isEmpty);
  });
  test(
      'no-lease generation snapshot excludes questions discovered after the service read',
      () async {
    await receive('known');
    final input =
        await db.generationMessages('buyer', batchEndMessageId: 'known');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['known']);
    await receive('late-earlier',
        sentAt: started.subtract(const Duration(minutes: 1)));
    await draft('known');
    await confirmNativeDraft();
    expect(await pendingIds(), ['late-earlier']);
  });
  test(
      'positive receipt completes exact frozen input and retains later-discovered work',
      () async {
    await receive('known');
    final token = await freeze('known');
    await draft('known', token: token);
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    await receive('late-earlier',
        sentAt: started.subtract(const Duration(minutes: 4)));
    await submitted(attempt);
    expect(await db.isMessageFormallyAnswered('buyer', 'known'), isTrue);
    expect(await pendingIds(), ['late-earlier']);
  });
  test('unknown physical click retains work and cannot become a ready resend',
      () async {
    await receive('known');
    await draft('known');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
    expect(await pendingIds(), ['known']);
    expect(await db.isMessageFormallyAnswered('buyer', 'known'), isFalse);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
  });
  test('holding and transfer acknowledgement never complete a question',
      () async {
    await receive('known');
    await db.appendAutomatedNoticeSent(
        userId: 'buyer',
        reply: 'I am connecting a colleague.',
        model: 'jd-transfer-acknowledgement-v1');
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait while I check.');
    expect(await pendingIds(), ['known']);
    expect(await db.isMessageFormallyAnswered('buyer', 'known'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'missing'), isFalse);
  });
  test(
      'new evidence retires an unclicked draft but never reopens a formally answered input',
      () async {
    await receive('media');
    await draft('media');
    expect(
        await db.reopenMessageForNewEvidence('buyer', 'media',
            evidenceKey: 'original-video'),
        isTrue);
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(
        await db.reopenMessageForNewEvidence('buyer', 'media',
            evidenceKey: 'original-video'),
        isFalse);
    expect(await pendingIds(), ['media']);
    await draft('media');
    await confirmNativeDraft();
    expect(await db.isMessageFormallyAnswered('buyer', 'media'), isTrue);
    expect(
        await db.reopenMessageForNewEvidence('buyer', 'media',
            evidenceKey: 'more-video-frames'),
        isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'media'), isTrue);
    expect(
        await db.reopenMessageForNewEvidence('buyer', 'media',
            evidenceKey: 'original-video'),
        isFalse);
  });
  test('old successful native attempt cannot answer a new evidence revision',
      () async {
    await receive('media');
    await draft('media');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    await db.reopenMessageForNewEvidence('buyer', 'media',
        evidenceKey: 'verified-original');
    expect(await db.hasUndeliveredDraft('buyer'), isTrue,
        reason: 'A possibly clicked answer is preserved');
    await submitted(attempt);
    expect(await pendingIds(), ['media']);
    expect(await db.isMessageFormallyAnswered('buyer', 'media'), isFalse);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
  test(
      'manual outgoing confirms only messages already known before its capture',
      () async {
    await receive('previously-known');
    final now = DateTime.now().toUtc();
    await db.saveCapture(frame([
      question('first-seen-in-same-frame', sentAt: now),
      CapturedMessage(
          stableId: 'manual-seller',
          direction: 'outgoing',
          body: 'A specific manual answer.',
          sentAt: now.add(const Duration(seconds: 1)),
          deliveryConfirmed: true,
          axPath: 'fixture'),
    ]));
    expect(await db.isMessageFormallyAnswered('buyer', 'previously-known'),
        isFalse);
    expect(
        await db.confirmManualReplyCoverage('buyer',
            messageIds: ['previously-known'],
            sentAt: DateTime.now(),
            reply: 'Explicitly confirmed manual answer.'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'previously-known'),
        isTrue);
    expect(await pendingIds(), ['first-seen-in-same-frame']);
  });
  test(
      'early persisted same-frame question is excluded from manual outgoing coverage',
      () async {
    await receive('previously-known');
    final at = DateTime.now().toUtc();
    final early = question('early-same-frame', sentAt: at);
    await db.saveCapture(frame([early]));
    await db.saveCapture(
        frame([
          early,
          CapturedMessage(
              stableId: 'first-seen-manual-outgoing',
              direction: 'outgoing',
              body: 'A manually provided answer to the older issue.',
              sentAt: at.add(const Duration(seconds: 1)),
              deliveryConfirmed: true,
              axPath: 'fixture')
        ]),
        manualCoverageExcludedIds: {'early-same-frame'});
    expect(await db.isMessageFormallyAnswered('buyer', 'previously-known'),
        isFalse);
    expect(
        await db.confirmManualReplyCoverage('buyer',
            messageIds: ['previously-known'],
            sentAt: DateTime.now(),
            reply: 'Explicitly confirmed manual answer.'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'previously-known'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'early-same-frame'),
        isFalse);
    expect(await pendingIds(), ['early-same-frame']);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
  test(
      'same-frame manual exclusion preserves an already ready independent answer',
      () async {
    await receive('early-answer');
    final token = await freeze('early-answer');
    await draft('early-answer', token: token);
    await receive('older-known-work');
    final at = DateTime.now().toUtc();
    await db.saveCapture(
        frame([
          CapturedMessage(
              stableId: 'manual-old-work',
              direction: 'outgoing',
              body: 'Manually answered the older known issue.',
              sentAt: at.add(const Duration(seconds: 1)),
              deliveryConfirmed: true,
              axPath: 'fixture')
        ]),
        manualCoverageExcludedIds: {'early-answer'});
    expect(await db.isMessageFormallyAnswered('buyer', 'older-known-work'),
        isFalse);
    expect(
        await db.confirmManualReplyCoverage('buyer',
            messageIds: ['older-known-work'],
            sentAt: DateTime.now(),
            reply: 'Explicitly confirmed manual answer.'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'older-known-work'),
        isTrue);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'early-answer'), isFalse);
    final stored = (await (await db.database).query('generated_drafts')).single;
    expect(stored['task_id'], token);
    expect(stored['delivery_state'], 'ready');
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: 'buyer', reply: _answer.reply, taskId: token),
        isTrue);
  });
  test(
      'empty manual coverage keeps same-frame pending and other customers independent',
      () async {
    await receive('early-only');
    await db.saveCapture(CapturedConversation(
        stableKey: 'other',
        customerName: 'other',
        customerExternalId: 'other',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [question('other-question')]));
    final at = DateTime.now().toUtc();
    await db.saveCapture(
        frame([
          CapturedMessage(
              stableId: 'manual-no-prior-input',
              direction: 'outgoing',
              body: 'A seller answer from this same frame.',
              sentAt: at.add(const Duration(seconds: 1)),
              deliveryConfirmed: true,
              axPath: 'fixture')
        ]),
        manualCoverageExcludedIds: {'early-only'});
    expect(await pendingIds(), ['early-only']);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.hasPendingUnanswered('other'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'early-only'), isFalse);
    expect(
        await db.isMessageFormallyAnswered('other', 'other-question'), isFalse);
  });
  test(
      'late discovery of this apps old reply cannot masquerade as a manual answer',
      () async {
    await receive('known');
    await draft('known');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    await submitted(attempt);
    await receive('new-pending');
    final sql = await db.database;
    final old = (await sql.query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    final late =
        DateTime.fromMillisecondsSinceEpoch(old['created_at_ms']! as int)
            .add(const Duration(minutes: 2));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: late,
        automationSessionId: db.currentAutomationSessionId,
        messages: [
          CapturedMessage(
              stableId: 'late-old-seller-bubble',
              direction: 'outgoing',
              body: _answer.reply,
              sentAt: late,
              deliveryConfirmed: true,
              axPath: 'fixture')
        ]));
    expect(await pendingIds(), ['new-pending']);
    expect(await db.isMessageFormallyAnswered('buyer', 'new-pending'), isFalse);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
  test(
      'confirmed handoff delegates its frozen input without answering a newer question',
      () async {
    await receive('handoff-question');
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'handoff-question',
        reason: 'order',
        requestMessageId: 'handoff-question');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.markTicketHandoffPending(ticket.id);
    await db.updateChatTransferLog(
        id: log.id, status: 'ready', targetAccount: 'real agent');
    await db.setTransferAcknowledgement(log.id, 1);
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: 'buyer', targetAccount: 'real agent');
    await receive('newer-question');
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        phase: 'confirmed',
        transferClicked: true);
    await db.markTicketContacted(ticket.id, assignedTo: 'real agent');
    final context = await db.processingMessages('buyer', includeAnswered: true);
    expect(
        context.singleWhere(
            (m) => m['id'] == 'handoff-question')['reply_work_state'],
        'delegated');
    expect(await db.isMessageFormallyAnswered('buyer', 'handoff-question'),
        isFalse);
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(await pendingIds(), ['newer-question']);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(attempt['attemptId'], isNotEmpty);
    expect(
        await db.reopenMessageForNewEvidence('buyer', 'handoff-question',
            evidenceKey: 'late-original'),
        isFalse);
    final image = File('${root.path}/late-image.jpg');
    final video = File('${root.path}/late-video.mp4');
    await image.writeAsBytes([1, 2, 3]);
    await video.writeAsBytes([4, 5, 6]);
    await db.saveCapture(frame([
      CapturedMessage(
          stableId: 'handoff-question',
          direction: 'incoming',
          body: 'Photo acquired',
          axPath: 'fixture',
          media: [CapturedMedia(type: 'image', path: image.path)])
    ]));
    await (await db.history).appendCapture(frame([
      CapturedMessage(
          stableId: 'handoff-question',
          direction: 'incoming',
          body: 'Video acquired',
          axPath: 'fixture',
          media: [CapturedMedia(type: 'video', path: video.path)])
    ]));
    await db.repairSessionPendingWork('buyer');
    expect(
        (await db.processingMessages('buyer', includeAnswered: true))
            .singleWhere(
                (m) => m['id'] == 'handoff-question')['reply_work_state'],
        'delegated');
    expect(await pendingIds(), ['newer-question']);
  });
  test('schema migration keeps durable work and existing receipts', () async {
    await receive('known');
    await draft('known');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: _answer.reply);
    final sql = await db.database;
    await sql.execute('PRAGMA user_version=30');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    final upgraded = await db.database;
    expect(
        (await upgraded.rawQuery('PRAGMA user_version')).single['user_version'],
        CaptureDatabase.databaseSchemaVersion);
    expect((await upgraded.query('delivery_attempts')).single['attempt_id'],
        attempt['attemptId']);
    expect((await upgraded.query('generated_drafts')).single['delivery_state'],
        'delivery_unknown');
    expect(
        (await upgraded.query('automation_session_messages'))
            .single['message_id'],
        'known');
  });
}
