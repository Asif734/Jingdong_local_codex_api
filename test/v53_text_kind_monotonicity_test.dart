import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'buyer';
  const body = 'ok';
  const reply = 'Select the correct paper source before printing.';
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime sender;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v53_text_kind_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    sender = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    session = await db.beginAutomationSession(
        startedAt: sender.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> receive({String buyer = customer, DateTime? at}) async {
    final stamp = at ?? sender;
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        automationSessionId: session,
        capturedAt: stamp,
        messages: [
          CapturedMessage(
            stableId: 'original-$buyer',
            direction: 'incoming',
            body: body,
            sender: buyer,
            sentAt: stamp,
            captureEvidenceId: 'original-text-frame',
            observationTurnKey: 'ocr-bubble:original-text-frame:exact',
            axPath: 'controlled exact customer text',
          )
        ]));
    return (await db.incomingMessageIdAtTime(buyer, stamp))!;
  }

  AiDraft answer() => AiDraft.fromJson({
        'reply': reply,
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-v53',
        'reply_media_dependency_keys': <String, String>{},
      }, mediaBaseUrl: Uri());

  Future<String> begin(String id) async => (await db.beginGeneration(
      customer: customer,
      pendingId: (await db.conversation(customer))!.id,
      batchEndMessageId: id))!;

  Future<String> ready(String id) async {
    final pending = (await db.conversation(customer))!;
    final token = await begin(id);
    final prepared = await db.prepareAutomaticDraft(customer, answer());
    expect(
        (await db.saveAutomaticDraft(pending.id, prepared,
                expectedMessageId: id,
                expectedUserId: customer,
                generationToken: token))
            .outcome,
        AutomaticDraftSaveOutcome.ready);
    await db.abandonGeneration(customer, token);
    return token;
  }

  Future<String> unknown({DateTime? at}) => inventory.observe(
      customer: customer,
      evidenceId: 'late-empty-unknown',
      observedAt: DateTime.now().toUtc(),
      senderAt: at ?? sender,
      slot: 0,
      region: [.28, .4, .3, .04],
      current: true);

  Future<Map<String, Object?>> work(String id) async =>
      (await (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, customer, id]))
          .single;

  Future<List<Map>> messages() async =>
      ((await (await db.history).read(customer))!['messages'] as List)
          .cast<Map>();

  /// Simulate the exact old-version damage: metadata/type changed, while the
  /// frozen text content and its material key did not change.
  Future<String> contaminate(String id) async {
    final receipt = await unknown();
    final sql = await db.database;
    await sql.update(
        'customer_media_items',
        {
          'message_id': id,
          'admission_key': id,
          'admission_session_id': session,
          'admitted_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'item_id=?',
        whereArgs: [receipt]);
    final store = await db.history;
    final document = (await store.read(customer))!;
    final message = (document['messages'] as List)
        .cast<Map>()
        .singleWhere((m) => m['id'] == id);
    message['media_receipt_id'] = receipt;
    message['media_receipt_aliases'] = [receipt];
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
        .writeAsString(jsonEncode(document), flush: true);
    await sql.update('automation_session_messages', {'input_kind': 'media'},
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, customer, id]);
    return receipt;
  }

  test('a late empty observation cannot attach media to confirmed text',
      () async {
    final id = await receive();
    final token = await ready(id);
    final before = await work(id);
    final receipt = await unknown();
    final at = DateTime.now().toUtc();
    final admission = await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'late-empty-unknown',
        occurrenceKey: id,
        receivedAt: at,
        senderAt: sender);
    expect(admission.messageId, id);
    expect(admission.created, isFalse);
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              sender: customer,
              sentAt: sender,
              mediaReceiptId: receipt,
              axPath: 'unknown visual body')
        ]));
    expect((await messages()).single['media_receipt_id'], isNull);
    expect((await messages()).single['body'], body);
    expect((await work(id))['input_kind'], 'text');
    expect((await work(id))['work_revision'], before['work_revision']);
    expect((await db.nextReadyDelivery())!.taskId, token);
    expect(await db.unansweredWorkCounts(), {customer: 1});
  });

  test('frozen exact text repairs old contamination without losing its draft',
      () async {
    final id = await receive();
    await db.observePlatformResponse(customer,
        red: true, observedAt: sender, startedAt: sender);
    final token = await ready(id);
    final cycle = await db.platformResponseCycle(customer);
    final receipt = await contaminate(id);
    final delivery = await db.nextReadyDelivery();
    expect(delivery, isNotNull);
    expect(delivery!.taskId, token);
    expect(delivery.draft.reply, reply);
    final record = (await messages()).single;
    expect(record['id'], id);
    expect(record['body'], body);
    expect(record['media_receipt_id'], isNull);
    expect(record['clarified_media_receipt_id'], receipt);
    expect((await work(id))['input_kind'], 'text');
    expect(await db.platformResponseCycle(customer), cycle);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
    final sql = await db.database;
    expect(await sql.query('generated_drafts'), hasLength(1));
    expect(await sql.query('delivery_attempts'), isEmpty);
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: customer, reply: reply, taskId: token),
        isTrue);
  });

  test(
      'restoring unchanged frozen text preserves its in-flight generation lease',
      () async {
    final id = await receive();
    final token = await begin(id);
    await contaminate(id);
    await db.repairSessionPendingWork(customer);
    expect(
        await db.generationInputVersionsCurrent(customer,
            generationToken: token),
        isTrue);
    final pending =
        (await (await db.database).query('pending_customers')).single;
    expect(pending['generation_token'], token);
    expect((await messages()).single['id'], id);
    expect((await work(id))['input_kind'], 'text');
  });

  test(
      'a fuller reading saved before kind repair keeps its body and retires the old answer',
      () async {
    final id = await receive();
    final token = await ready(id);
    final receipt = await contaminate(id);
    const completeBody = 'ok, how can I select the correct paper source?';
    final store = await db.history;
    final document = (await store.read(customer))!;
    final latest = (document['messages'] as List)
        .cast<Map>()
        .singleWhere((message) => message['id'] == id);
    // Model a complete OCR result durably written before queue registration
    // finished. Recovery must use these current pixels, not the old snapshot.
    latest['body'] = completeBody;
    latest['text_source_evidence_id'] = 'complete-text-frame';
    latest['text_source_observation_turn_key'] =
        'ocr-bubble:complete-text-frame:exact';
    latest['service_evidence_revision'] =
        (latest['service_evidence_revision'] as num? ?? 0).toInt() + 1;
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
        .writeAsString(jsonEncode(document), flush: true);

    await db.repairSessionPendingWork(customer);

    final restored = (await messages()).single;
    expect(restored['id'], id);
    expect(restored['body'], completeBody);
    expect(restored['text_source_evidence_id'], 'complete-text-frame');
    expect(restored['media_receipt_id'], isNull);
    expect(restored['clarified_media_receipt_id'], receipt);
    expect((await work(id))['input_kind'], 'text');
    expect((await work(id))['response_state'], 'pending');
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(await db.nextReadyDelivery(), isNull);
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: customer, reply: reply, taskId: token),
        isFalse);
    final sql = await db.database;
    expect(await sql.query('generated_drafts'), isEmpty);
    expect(await sql.query('delivery_attempts'), isEmpty);
    expect(await db.generationDue(customer), isTrue);
  });

  test(
      'an unknown clicked attempt is retained and never reopened by kind repair',
      () async {
    final id = await receive();
    final token = await ready(id);
    final receipt = await contaminate(id);
    final sql = await db.database;
    final draft = (await sql.query('generated_drafts')).single;
    await sql.insert('delivery_attempts', {
      'attempt_id': 'clicked-unknown',
      'task_id': token,
      'user_id': customer,
      'pending_id': draft['pending_id'],
      'reply': reply,
      'raw_json': draft['raw_json'],
      'batch_end_message_id': id,
      'state': 'unknown',
      'created_at_ms': draft['created_at_ms'],
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    await sql.update(
        'generated_drafts',
        {
          'delivery_state': 'delivery_unknown',
          'attempt_id': 'clicked-unknown',
        },
        where: 'user_id=?',
        whereArgs: [customer]);
    expect(
        await db.preserveConfirmedTextAtTime(customer,
            senderAt: sender,
            evidenceId: 'late-empty',
            expectedSessionId: session,
            receiptId: receipt),
        isNull);
    expect((await sql.query('delivery_attempts')).single['state'], 'unknown');
    expect((await sql.query('generated_drafts')).single['attempt_id'],
        'clicked-unknown');
    expect((await messages()).single['media_receipt_id'], receipt);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test('already answered work is not reactivated by legacy kind correction',
      () async {
    final id = await receive();
    await ready(id);
    final sql = await db.database;
    await sql.delete('generated_drafts');
    await sql.delete('pending_customers');
    await sql.update(
        'automation_session_messages',
        {
          'response_state': 'answered',
          'responded_at_ms': DateTime.now().millisecondsSinceEpoch
        },
        where: 'message_id=?',
        whereArgs: [id]);
    final receipt = await contaminate(id);
    expect(
        await db.preserveConfirmedTextAtTime(customer,
            senderAt: sender,
            evidenceId: 'late-empty',
            expectedSessionId: session,
            receiptId: receipt),
        isNull);
    expect((await work(id))['response_state'], 'answered');
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test('detached unknown native proof also blocks reopening the old message',
      () async {
    final id = await receive();
    final token = await ready(id);
    final receipt = await contaminate(id);
    final sql = await db.database;
    final draft = (await sql.query('generated_drafts')).single;
    await sql.insert('delivery_attempts', {
      'attempt_id': 'detached-unknown',
      'task_id': token,
      'user_id': customer,
      'pending_id': draft['pending_id'],
      'reply': reply,
      'raw_json': draft['raw_json'],
      'batch_end_message_id': id,
      'state': 'superseded_unknown',
      'created_at_ms': draft['created_at_ms'],
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    await sql.delete('generated_drafts');
    expect(
        await db.preserveConfirmedTextAtTime(customer,
            senderAt: sender,
            evidenceId: 'late-empty',
            expectedSessionId: session,
            receiptId: receipt),
        isNull);
    await db.repairSessionPendingWork(customer);
    expect(await db.generationDue(customer), isFalse);
    expect((await sql.query('delivery_attempts')).single['state'],
        'superseded_unknown');
    expect((await messages()).single['media_receipt_id'], receipt);
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
  });

  test(
      'real classified media is not downgraded; material upgrade retires old text',
      () async {
    final id = await receive();
    final token = await ready(id);
    final receipt = await unknown();
    await inventory.classify(receipt, 'image');
    await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'real-image-proof',
        occurrenceKey: id,
        receivedAt: DateTime.now().toUtc(),
        senderAt: sender);
    expect(
        await db.preserveConfirmedTextAtTime(customer,
            senderAt: sender,
            evidenceId: 'late-empty',
            expectedSessionId: session,
            receiptId: receipt),
        isNull);
    expect(await db.nextReadyDelivery(), isNull,
        reason: 'A real new type cannot bypass the original-material gate');
    final image = File('${root.path}/original.png');
    await image.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='));
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[Customer sent an image; original copied from JD cache]',
              sender: customer,
              sentAt: sender,
              mediaReceiptId: receipt,
              axPath: 'verified original image',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: image.path,
                    captureSource: 'jd_image_cache',
                    isPartial: false)
              ])
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    await db.repairSessionPendingWork(customer);
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: customer, reply: reply, taskId: token),
        isFalse);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect((await work(id))['input_kind'], 'media');
    expect((await messages()).where((m) => m['direction'] == 'incoming'),
        hasLength(1));
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
    expect(await db.generationDue(customer), isTrue);
  });

  test('unknown observations at a different second remain a different original',
      () async {
    final first = await receive();
    final later = sender.add(const Duration(seconds: 1));
    final receipt = await unknown(at: later);
    final admission = await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'another-message',
        occurrenceKey: 'new-second',
        receivedAt: DateTime.now().toUtc(),
        senderAt: later);
    expect(admission.messageId, isNot(first));
    expect(await db.unansweredWorkCounts(), {customer: 2});
  });

  test('a body alone cannot repair an unknown without its frozen text proof',
      () async {
    final id = await receive();
    final receipt = await contaminate(id);
    expect(
        await db.preserveConfirmedTextAtTime(customer,
            senderAt: sender,
            evidenceId: 'arbitrary-capture',
            expectedSessionId: session,
            receiptId: receipt),
        isNull);
    expect((await messages()).single['media_receipt_id'], receipt);
  });
}
