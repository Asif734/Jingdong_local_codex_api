import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime received;
  late DateTime sender;
  late String session;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v39_text_correction_');
    db = CaptureDatabase(storageRoot: root);
    received = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 5000,
        isUtc: true);
    sender = received.subtract(const Duration(seconds: 1));
    session = await db.beginAutomationSession(
        startedAt: received.subtract(const Duration(seconds: 20)));
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<({String parent, String receipt})> unknown(String key,
      {String? parent}) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'clipped-$key',
        occurrenceKey: key,
        observedAt: received,
        senderAt: sender,
        slot: 0,
        region: [.24, .70, .42, .08],
        current: true);
    final admission = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'clipped-$key',
        occurrenceKey: key,
        receivedAt: received,
        senderAt: sender,
        messageId: parent);
    return (parent: admission.messageId, receipt: admission.receiptId);
  }

  CapturedMessage text(String id,
          {String body = 'can you share me a video?'}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          body: body,
          sender: 'buyer',
          sentAt: sender,
          axPath: 'verified AX customer',
          observationTurnKey: 'ocr-bubble:full-frame:$id',
          captureEvidenceId: 'full-frame');
  Future<void> saveTextObservation(CapturedMessage observation) async {
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: session,
            capturedAt: DateTime.now().toUtc(),
            messages: [observation]),
        activateReplies: false,
        isCurrentViewport: false);
  }

  Future<String?> clarify(
          ({String parent, String receipt}) item, CapturedMessage observation,
          {String? expectedSession}) =>
      db.clarifyUnknownMessageAsText('buyer',
          parentMessageId: item.parent,
          receiptId: item.receipt,
          text: observation,
          evidenceId: 'full-frame',
          expectedSessionId: expectedSession ?? session);
  Future<List<Map>> incomingHistory() async =>
      ((await (await db.history).read('buyer'))!['messages'] as List)
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();
  Future<void> complete(String parent) async {
    final conversation = (await db.conversation('buyer'))!;
    final token = (await db.beginGeneration(
        customer: 'buyer',
        pendingId: conversation.id,
        batchEndMessageId: parent))!;
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: token),
        isTrue);
    final draft = AiDraft.fromJson({
      'reply': 'Here is the documented tutorial video for this model.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-native-fixture',
      'formal_response_message_ids': [parent],
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(conversation.id, draft,
            generationToken: token, expectedMessageId: parent),
        1);
    await db.abandonGeneration('buyer', token);
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: draft.reply);
    final clicked = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': clicked,
      'timeMs': clicked + 100,
    }));
    await db.recoverDeliveryReceipts();
  }

  test(
      'clipped placeholder and readable text remain one sendable legacy-prefix input',
      () async {
    final item = await unknown('tutorial');
    final observation = text('ocr:clear-tutorial');
    await saveTextObservation(observation);
    expect(await incomingHistory(), hasLength(2));
    final before =
        (await (await db.database).query('automation_session_messages')).single;
    expect(await clarify(item, observation), item.parent);
    final history = (await incomingHistory()).single;
    expect(history['id'], item.parent);
    expect(history['body'], observation.body);
    expect(history['captured_at'], received.toIso8601String());
    expect(history['observed_ids'], contains(observation.stableId));
    expect(history['media_receipt_id'], isNull);
    expect(history['clarified_media_receipt_id'], item.receipt);
    expect(isClarifiedTextMessage(history), isTrue);
    expect(isMediaWorkMessage(history), isFalse);
    final work =
        (await (await db.database).query('automation_session_messages')).single;
    expect(work['message_id'], item.parent);
    expect(work['activated_at_ms'], before['activated_at_ms']);
    expect(work['input_kind'], 'text');
    expect(work['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(await db.awaitingMediaMessageIds('buyer'), isEmpty);
    expect(
        await inventory.context('buyer',
            history: await db.processingMessages('buyer'),
            before: DateTime.now()),
        isEmpty,
        reason: 'A corrected text is not a detected incoming attachment.');
    expect((await db.customerMessageRecords('buyer')).single.kind, 'text');
    await complete(item.parent);
    expect(await db.isMessageFormallyAnswered('buyer', item.parent), isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test('repeat clarification is idempotent and does not restart AX red clock',
      () async {
    final item = await unknown('idempotent', parent: 'incoming-media:unknown');
    await db.observePlatformResponse('buyer',
        red: true, observedAt: received, identityVerified: true);
    final originalCycle = await db.platformResponseCycle('buyer');
    final observation = text('ocr:repeat');
    expect(await clarify(item, observation), item.parent);
    final first = (await incomingHistory()).single;
    final revision = first['service_evidence_revision'];
    expect(
        await Future.wait(
            [clarify(item, observation), clarify(item, observation)]),
        [item.parent, item.parent]);
    final after = (await incomingHistory()).single;
    expect(after['service_evidence_revision'], revision);
    expect(after['captured_at'], first['captured_at']);
    expect(await db.platformResponseCycle('buyer'), originalCycle);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('two actual same-second bubbles cannot be joined through correction',
      () async {
    final a = await unknown('actual-a', parent: 'incoming-media:A');
    final b = await unknown('actual-b', parent: 'incoming-media:B');
    final observation = text('ocr:only-A');
    expect(await clarify(a, observation), a.parent);
    expect((await incomingHistory()).map((m) => m['id']).toSet(),
        {a.parent, b.parent});
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    final bRecord =
        (await incomingHistory()).singleWhere((m) => m['id'] == b.parent);
    expect(bRecord['body'], contains('acquisition pending'));
    expect(
        bRecord['observed_ids'] ?? [], isNot(contains(observation.stableId)));
    expect(await clarify(b, observation), isNull,
        reason:
            'The OCR alias already belongs to A, not another same-second bubble.');
  });

  test(
      'real image/video, another customer and another run cannot be downgraded',
      () async {
    for (final kind in ['image', 'video']) {
      final item =
          await unknown('actual-$kind', parent: 'incoming-media:$kind');
      await inventory.classify(item.receipt, kind);
      expect(await clarify(item, text('ocr:$kind')), isNull);
    }
    final item = await unknown('guarded', parent: 'incoming-media:guarded');
    expect(
        await clarify(item, text('ocr:wrong-run'), expectedSession: 'old-run'),
        isNull);
    expect(
        await db.clarifyUnknownMessageAsText('another-buyer',
            parentMessageId: item.parent,
            receiptId: item.receipt,
            text: text('ocr:wrong-customer'),
            evidenceId: 'full-frame',
            expectedSessionId: session),
        isNull);
    final row = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [item.receipt]))
        .single;
    expect(row['kind'], 'unknown');
  });

  test('late old native crops cannot turn corrected text back into media',
      () async {
    final item = await unknown('late-crop', parent: 'incoming-media:late');
    expect(await clarify(item, text('ocr:late')), item.parent);
    expect(
        await inventory.observe(
            customer: 'buyer',
            evidenceId: 'late-frame',
            observedAt: DateTime.now(),
            senderAt: sender,
            slot: 0,
            region: [.24, .70, .42, .08],
            current: true,
            parentReceiptId: item.receipt),
        item.receipt);
    await inventory.classify(item.receipt, 'image');
    final late = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: session,
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: 'stale-derived-image',
              direction: 'incoming',
              body: '[Customer sent an image]',
              axPath: 'late native result',
              mediaReceiptId: item.receipt,
              media: [
                CapturedMedia(
                    type: 'image',
                    path: '${root.path}/retained-original.png',
                    captureSource: 'verified_window_crop')
              ])
        ]);
    await db.saveCapture(late);
    await inventory.persist(late);
    final message = (await incomingHistory()).single;
    expect(isClarifiedTextMessage(message), isTrue);
    expect(message['body'], 'can you share me a video?');
    expect(message['media'], isEmpty);
    final row = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [item.receipt]))
        .single;
    expect(row['kind'], 'text');
    expect(await db.awaitingMediaMessageIds('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test(
      'persisted correction repairs a missing DB commit without another business',
      () async {
    final item =
        await unknown('interrupted', parent: 'incoming-media:interrupted');
    final observation = text('ocr:interrupted');
    await saveTextObservation(observation);
    final stored = await (await db.history).clarifyUnknownMessageAsText('buyer',
        parentMessageId: item.parent,
        receiptId: item.receipt,
        text: observation,
        sessionId: session,
        evidenceId: 'full-frame',
        minimumRevision: 1);
    expect(stored, isNotNull);
    expect(await db.repairSessionPendingWork('buyer'), isTrue);
    final row =
        (await (await db.database).query('automation_session_messages')).single;
    expect(row['message_id'], item.parent);
    expect(row['input_kind'], 'text');
    expect(row['activated_at_ms'], received.millisecondsSinceEpoch);
    expect(await db.awaitingMediaMessageIds('buyer'), isEmpty);
    expect(await clarify(item, observation), item.parent);
    expect((await incomingHistory()).single['service_evidence_revision'], 1);
  });

  test(
      'holding does not complete the placeholder and clarification still sends formal',
      () async {
    final item = await unknown('held', parent: 'incoming-media:held');
    await db.observePlatformResponse('buyer',
        red: true, observedAt: received, identityVerified: true);
    final job = (await db.slaFallbackJob('buyer'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    final hold = await db.beginSlaAttempt(job, 'Please wait while I check.');
    final at = DateTime.now().millisecondsSinceEpoch;
    await File(hold['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': hold['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': at,
      'timeMs': at + 100,
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered('buyer', item.parent), isFalse);
    final cycle = await db.platformResponseCycle('buyer');
    final observation = text('ocr:after-holding');
    expect(await clarify(item, observation), item.parent);
    expect(await db.platformResponseCycle('buyer'), cycle);
    expect(await db.isMessageFormallyAnswered('buyer', item.parent), isFalse);
    await complete(item.parent);
    expect(await db.isMessageFormallyAnswered('buyer', item.parent), isTrue);
    expect(await clarify(item, observation), isNull,
        reason: 'A late callback cannot reopen a formally completed input.');
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test(
      'a failed history write rolls back acquisition claim and retains pending work',
      () async {
    final item =
        await unknown('failed-write', parent: 'incoming-media:failed-write');
    final blocker = await Directory('${root.path}/buyer.json.tmp').create();
    await expectLater(clarify(item, text('ocr:failed-write')),
        throwsA(isA<FileSystemException>()));
    final receipt = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [item.receipt]))
        .single;
    expect(receipt['kind'], 'unknown');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect((await incomingHistory()).single['body'],
        contains('acquisition pending'));
    await blocker.delete();
    expect(await clarify(item, text('ocr:failed-write')), item.parent);
    expect((await incomingHistory()).single['id'], item.parent);
  });

  test('invalid text declarations cannot bypass genuine media readiness', () {
    final forged = {
      'id': 'media-pending:actual',
      'message_kind': 'text',
      'text_origin': 'customer_text',
      'media': <Object>[]
    };
    expect(isMediaWorkMessage(forged), isTrue);
    expect(isClarifiedTextMessage(forged), isFalse);
  });
}
