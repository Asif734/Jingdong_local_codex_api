import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _draft = AiDraft(
  reply: 'The answer',
  decision: 'draft',
  confidence: 1,
  riskLevel: 'low',
  model: 'test',
  usedRecordIds: [],
  actions: [],
  attachments: [],
  rawJson:
      '{"reply":"The answer","decision":"draft","confidence":1,"risk_level":"low","model":"test"}',
);

void main() {
  late Directory root;
  late CaptureDatabase database;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_delivery_regression_');
    database = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  CapturedConversation capture(List<CapturedMessage> messages) =>
      CapturedConversation(
        stableKey: 'customer:buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: DateTime.now(),
        messages: messages,
      );
  CapturedMessage question(String id) => CapturedMessage(
        stableId: id,
        direction: 'incoming',
        body: 'Question $id',
        sentAt: DateTime.now(),
        axPath: 'test',
      );
  const uncertain = CapturedMessage(
      stableId: 'uncertain',
      direction: 'outgoing',
      body: '之前不是这样的，',
      axPath: 'ocr:sender');

  test('reread incoming plus uncertain outgoing preserves queue and SLA',
      () async {
    final incoming = question('question');
    await database.saveCapture(capture([incoming]));
    final queue = (await database.conversations()).single;
    await database.saveCapture(capture([incoming, uncertain]));
    expect(await database.pendingMessageId('buyer'), 'question');
    expect(await database.answeredMessageId('buyer'), isNull);
    expect((await database.slaFallbackJob('buyer'))?.messageId, 'question');
    expect(
        await database.saveDraft(queue.id, _draft,
            expectedMessageId: 'question'),
        1,
        reason: 'A reply generated during OCR must still be saved.');
    expect(await database.hasUndeliveredDraft('buyer'), isTrue);
  });

  test('uncertain outgoing alone cannot delete an already generated draft',
      () async {
    final incoming = question('question');
    await database.saveCapture(capture([incoming]));
    final queue = (await database.conversations()).single;
    await database.saveDraft(queue.id, _draft, expectedMessageId: 'question');
    await database.saveCapture(capture([uncertain]));
    expect(await database.hasUndeliveredDraft('buyer'), isTrue);
    expect(await database.answeredMessageId('buyer'), isNull);
    final doc = await (await database.history).read('buyer');
    expect((doc!['messages'] as List).last['delivery_status'],
        'unverified_observation');
  });

  for (final fixture in [
    'jd_corrupt_sender_ocr.json',
    'jd_transfer_toast_ocr.json'
  ]) {
    test('production OCR replay keeps customer follow-up: $fixture', () {
      final map = jsonDecode(File('test/fixtures/$fixture').readAsStringSync())
          as Map<String, dynamic>;
      final attempt =
          const OcrCaptureExtractor().analyze(OcrInspection.fromMap(map));
      final result = attempt.capture!;
      expect(result.customerExternalId, 'jd_regression',
          reason: 'Identity remains the exact AX value.');
      final followup =
          result.messages.singleWhere((m) => m.body.contains('之前不是这样的'));
      expect(followup.direction, 'incoming');
      expect(followup.sentAt, DateTime.utc(2026, 11, 2, 2, 38, 11));
      expect(followup.body, '之前不是这样的，');
      expect(result.messages.where((m) => m.body.contains('其他同事')), isEmpty);
    });
  }

  test('quoted transfer text in a real customer question is retained', () {
    final map = jsonDecode(
            File('test/fixtures/jd_transfer_toast_ocr.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final o in (map['observations'] as List).cast<Map>()) {
      if (o['text'] == '之前不是这样的，') o['text'] = '为什么显示“你已将客户成功转给其他同事！”？';
    }
    final result = const OcrCaptureExtractor()
        .analyze(OcrInspection.fromMap(map))
        .capture!;
    expect(result.messages.last.body, '为什么显示“你已将客户成功转给其他同事！”？');
    expect(result.messages.last.direction, 'incoming');
  });

  test('native SLA receipt survives timer deletion, restart and recreation',
      () async {
    final incoming = question('question');
    await database.saveCapture(capture([incoming]));
    final job = (await database.slaFallbackJob('buyer'))!;
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await (await database.database)
        .delete('sla_fallbacks', where: 'user_id=?', whereArgs: ['buyer']);
    expect(
        await database.markSlaFallbackSent(
            userId: 'buyer',
            messageId: job.messageId,
            batchStartMessageId: job.batchStartMessageId,
            reply: '请稍等。',
            nativeConfirmed: true),
        isTrue);
    await database.close();
    database = CaptureDatabase(storageRoot: root);
    await database.ensurePendingForUnanswered('buyer');
    final recreated = (await database.slaFallbackJob('buyer'))!;
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer',
            messageId: recreated.messageId,
            dueAt: recreated.dueAt),
        isFalse);
    expect(await database.slaFallbackJob('buyer'), isNull);
    final receipts =
        await (await database.database).query('sla_delivery_receipts');
    expect(receipts, hasLength(1));
  });

  test('new batch may get one holding; historical reply never reopens it',
      () async {
    await database.saveCapture(capture([question('old')]));
    var job = (await database.slaFallbackJob('buyer'))!;
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await database.markSlaFallbackSent(
        userId: 'buyer', messageId: job.messageId, reply: '请稍等。');
    await (await database.history).appendSentReply(
        userId: 'buyer',
        displayName: 'buyer',
        stableKey: 'customer:buyer',
        draft: _draft);
    await database.saveCapture(capture([question('new')]));
    job = (await database.slaFallbackJob('buyer'))!;
    expect(job.batchStartMessageId, 'new');
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await database.markSlaFallbackSent(
        userId: 'buyer', messageId: job.messageId, reply: '请稍等。');
    await database.saveCapture(capture([question('followup')]));
    await database.ensurePendingForUnanswered('buyer');
    expect(await database.slaFallbackJob('buyer'), isNull,
        reason: 'Same unanswered batch already got its holding.');
    expect(await (await database.database).query('sla_delivery_receipts'),
        hasLength(2));
  });

  test('v19 migration carries confirmed sent timer receipt into v20', () async {
    await database.saveCapture(capture([question('question')]));
    final job = (await database.slaFallbackJob('buyer'))!;
    final db = await database.database;
    await db.update('sla_fallbacks', {
      'state': 'completed',
      'sent_at_ms': DateTime.now().millisecondsSinceEpoch
    });
    await database.close();
    final legacy = await databaseFactoryFfi
        .openDatabase('${root.path}/jd_automation.sqlite3');
    await legacy.execute('DROP TABLE sla_delivery_receipts');
    await legacy.execute('PRAGMA user_version=19');
    await legacy.close();
    database = CaptureDatabase(storageRoot: root);
    final upgraded = await database.database;
    expect(await upgraded.getVersion(), CaptureDatabase.databaseSchemaVersion);
    expect(await upgraded.query('sla_delivery_receipts'), hasLength(1));
    await upgraded.update('sla_fallbacks', {'state': 'pending'});
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isFalse);
  });
}
