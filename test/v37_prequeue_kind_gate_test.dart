import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v37_kind_gate_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> text(String id) => db
      .saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'What paper sizes are supported?',
                sentAt: DateTime.now(),
                axPath: 'independent text $id')
          ]))
      .then((_) {});
  Future<String> image() async {
    final now = DateTime.now();
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'immutable-image',
        observedAt: now,
        senderAt: now,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'immutable-image',
        occurrenceKey: 'live-image-after-empty-baseline',
        receivedAt: now,
        senderAt: now);
    await inventory.classify(receipt, 'image');
    final original = await File('test/fixtures/v35_media/paper-image-1.png')
        .copy('${root.path}/original.png');
    final capture = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: 'media-pending:$receipt',
              direction: 'incoming',
              body: '[Customer sent image]',
              mediaReceiptId: receipt,
              sentAt: now,
              axPath: 'one owned card',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: original.path,
                    captureSource: 'jd_image_cache')
              ])
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    return receipt;
  }

  test(
      'prequeue type uncertainty blocks only frozen owned media and resumes without a new key',
      () async {
    final receipt = await image();
    final id = 'media-pending:$receipt';
    final received =
        (await db.customerMessageRecords('buyer')).single.receivedAt;
    final conversation = (await db.conversation('buyer'))!;
    final token = (await db.beginGeneration(
        customer: 'buyer', pendingId: conversation.id, batchEndMessageId: id))!;
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: token),
        isTrue);
    final key = (await inventory.analyzableEvidenceKeys('buyer'))[id];
    await (await db.database).update(
        'customer_media_items', {'state': 'awaiting_kind'},
        where: 'item_id=? AND customer=?', whereArgs: [receipt, 'buyer']);
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: token),
        isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.nextReadyDelivery(), isNull);
    await db.abandonGeneration('buyer', token);
    expect(await db.generationDue('buyer'), isFalse);
    // Native confirmation can establish that the content really was a still
    // image. No new asset/key, incoming message or receive clock is needed.
    await (await db.database).update('customer_media_items', {'state': 'ready'},
        where: 'item_id=? AND customer=?', whereArgs: [receipt, 'buyer']);
    expect((await inventory.analyzableEvidenceKeys('buyer'))[id], key);
    expect(await db.generationDue('buyer'), isTrue);
    final again = (await db.beginGeneration(
        customer: 'buyer', pendingId: conversation.id, batchEndMessageId: id))!;
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: again),
        isTrue);
    final record = (await db.customerMessageRecords('buyer')).single;
    expect(record.stableId, id);
    expect(record.receivedAt, received);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    await db.abandonGeneration('buyer', again);
  });

  test('a later type-pending card cannot invalidate an independent text lease',
      () async {
    await text('paper-size');
    final token = (await db.beginGeneration(
        customer: 'buyer',
        pendingId: (await db.conversation('buyer'))!.id,
        batchEndMessageId: 'paper-size'))!;
    final receipt = await image();
    await (await db.database).update(
        'customer_media_items', {'state': 'awaiting_kind'},
        where: 'item_id=? AND customer=?', whereArgs: [receipt, 'buyer']);
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: token),
        isTrue);
    final frozen = (await db.generationMessages('buyer'))
        .where((m) => m['direction'] == 'incoming')
        .map((m) => m['id'])
        .toList();
    expect(frozen, ['paper-size']);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    await db.abandonGeneration('buyer', token);
  });
}
