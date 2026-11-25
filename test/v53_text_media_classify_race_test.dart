import 'dart:async';
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
  const frame = 'late-empty-observation';
  const region = [.28, .4, .3, .08];
  late Directory root;
  late CaptureDatabase db;
  late DateTime sender;
  late String session;
  late String id;
  late String receipt;
  late String task;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v53_classify_race_');
    db = CaptureDatabase(storageRoot: root);
    sender = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    session = await db.beginAutomationSession(
        startedAt: sender.subtract(const Duration(seconds: 1)));
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: sender,
        messages: [
          CapturedMessage(
              stableId: 'original-text',
              direction: 'incoming',
              sender: customer,
              body: 'ok',
              sentAt: sender,
              captureEvidenceId: 'confirmed-text-frame',
              axPath: 'exact customer text')
        ]));
    id = (await db.incomingMessageIdAtTime(customer, sender))!;
    final pending = (await db.conversation(customer))!;
    task = (await db.beginGeneration(
        customer: customer, pendingId: pending.id, batchEndMessageId: id))!;
    final answer = await db.prepareAutomaticDraft(
        customer,
        AiDraft.fromJson({
          'reply': 'Select the correct paper source before printing.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v53',
          'reply_media_dependency_keys': <String, String>{},
        }, mediaBaseUrl: Uri()));
    expect(
        (await db.saveAutomaticDraft(pending.id, answer,
                expectedMessageId: id,
                expectedUserId: customer,
                generationToken: task))
            .outcome,
        AutomaticDraftSaveOutcome.ready);
    await db.abandonGeneration(customer, task);
    receipt = await CustomerMediaInventory(db).observe(
        customer: customer,
        evidenceId: frame,
        observedAt: DateTime.now().toUtc(),
        senderAt: sender,
        slot: 0,
        region: region,
        current: true);

    // Restore only the old-version damage under test: an empty observation
    // attached to a proven, frozen text without changing its real material.
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
    final message = (document['messages'] as List).cast<Map>().single;
    message['media_receipt_id'] = receipt;
    message['media_receipt_aliases'] = [receipt];
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
        .writeAsString(jsonEncode(document), flush: true);
    await sql.update('automation_session_messages', {'input_kind': 'media'},
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, customer, id]);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String?> repair() => db.preserveConfirmedTextAtTime(customer,
      senderAt: sender,
      evidenceId: frame,
      expectedSessionId: session,
      receiptId: receipt);

  Future<Map> message() async =>
      ((await (await db.history).read(customer))!['messages'] as List)
          .cast<Map>()
          .single;

  for (final kind in ['image', 'video']) {
    test('text claim wins after $kind classifier reads the unknown receipt',
        () async {
      final readUnknown = Completer<void>();
      final allowCommit = Completer<void>();
      final inventory = CustomerMediaInventory(db,
          beforeClassificationCommitForTesting: (item) async {
        expect(item, receipt);
        readUnknown.complete();
        await allowCommit.future;
      });
      final classification = inventory.classify(receipt, kind,
          fingerprint: 'abcdef0123456789', evidenceId: frame, region: region);
      await readUnknown.future;
      try {
        expect(await repair(), id);
      } finally {
        allowCommit.complete();
      }
      expect(await classification, receipt);
      final sql = await db.database;
      final item = (await sql.query('customer_media_items',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
      final observation = (await sql.query('media_card_observations',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
      expect(item['kind'], 'text');
      expect(item['state'], 'superseded');
      expect(observation['classified_kind'], isNull);
      expect(observation['classified_ms'], isNull);
      final current = await message();
      expect(current['id'], id);
      expect(current['body'], 'ok');
      expect(current['media_receipt_id'], isNull);
      expect((await db.nextReadyDelivery())?.taskId, task);
      expect(await db.unansweredWorkCounts(), {customer: 1});
      expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
    });

    test('$kind classification commits before text claim as one proof',
        () async {
      final inventory = CustomerMediaInventory(db);
      expect(
          await inventory.classify(receipt, kind,
              fingerprint: 'abcdef0123456789',
              evidenceId: frame,
              region: region),
          receipt);
      expect(await repair(), isNull);
      final sql = await db.database;
      final item = (await sql.query('customer_media_items',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
      final observation = (await sql.query('media_card_observations',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
      expect(item['kind'], kind);
      expect(observation['classified_kind'], kind);
      expect(observation['classified_ms'], isNotNull);
      expect(observation['canonical_id'], receipt);
      final current = await message();
      expect(current['id'], id);
      expect(current['media_receipt_id'], receipt);
      expect(await db.nextReadyDelivery(), isNull,
          reason: 'A real media proof still needs its complete material.');
      expect(await db.unansweredWorkCounts(), {customer: 1});
      expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
    });
  }
}
