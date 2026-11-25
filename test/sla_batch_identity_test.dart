import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  final at = DateTime.utc(2026, 11, 1, 4, 20);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_sla_batch_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String id, int second) => db
      .saveCapture(CapturedConversation(
          stableKey: 'a',
          customerName: 'a',
          customerExternalId: 'a',
          capturedAt: at.add(Duration(seconds: second)),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'question $id',
                sentAt: at.add(Duration(seconds: second)),
                axPath: 'fixture')
          ]))
      .then((_) {});
  test(
      'observed final reply terminates one SLA and a stale job cannot terminate a new turn',
      () async {
    await incoming('old', 0);
    final old = (await db.slaFallbackJob('a'))!;
    expect(await db.completeSlaForObservedReply(old), isTrue);
    expect(await db.slaFallbackJob('a'), isNull);
    expect(await db.pendingSlaFallbackJobs(), isEmpty);
    await incoming('new', 30);
    final next = (await db.slaFallbackJob('a'))!;
    expect(await db.completeSlaForObservedReply(old), isFalse);
    expect((await db.slaFallbackJob('a'))!.messageId, next.messageId);
  });
  test('new answered-turn boundary cannot inherit an old pending deadline',
      () async {
    await incoming('old', 0);
    final draft = AiDraft.fromJson({
      'reply': 'The paper width is 80 mm.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'native-receipt-fixture',
    }, mediaBaseUrl: Uri());
    await db.saveDraft((await db.conversations()).single.id, draft,
        expectedMessageId: 'old');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'a', reply: draft.reply);
    final clickedAt = at.add(const Duration(seconds: 10));
    await (await db.database).update('delivery_attempts',
        {'created_at_ms': clickedAt.millisecondsSinceEpoch - 100},
        where: 'attempt_id=?', whereArgs: [attempt['attemptId']]);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'submitted',
      'sendClickedAtMs': clickedAt.millisecondsSinceEpoch,
      'timeMs': clickedAt.millisecondsSinceEpoch + 100,
    }));
    await db.recoverDeliveryReceipts();
    // A stale timer/reservation can leave a pending row after final delivery.
    await (await db.database).update('sla_fallbacks', {'state': 'pending'});
    await incoming('new', 30);
    final job = (await db.slaFallbackJob('a'))!;
    expect(job.batchStartMessageId, 'incoming-time:a:2026-11-01T04:20:30Z');
    expect(job.startedAt?.toUtc(), at.add(const Duration(seconds: 30)));
    expect(job.dueAt.toUtc(), at.add(const Duration(seconds: 50)));
    await db.capSlaFallbackDue(
        userId: 'a', dueAt: at.add(const Duration(seconds: 20)));
    expect((await db.slaFallbackJob('a'))!.dueAt.toUtc(),
        at.add(const Duration(seconds: 50)));
  });
  test('same unanswered batch preserves first deadline and sent holding state',
      () async {
    await incoming('first', 0);
    await (await db.database).update('sla_fallbacks', {
      'state': 'sent',
      'sent_at_ms': at.add(const Duration(seconds: 10)).millisecondsSinceEpoch
    });
    await incoming('later', 15);
    final row = (await (await db.database).query('sla_fallbacks')).single;
    expect(
        row['batch_start_message_id'], 'incoming-time:a:2026-11-01T04:20:00Z');
    expect(row['state'], 'sent');
    expect(row['due_at_ms'],
        at.add(const Duration(seconds: 20)).millisecondsSinceEpoch);
  });
  test('v17 migration preserves existing jobs and adds batch metadata',
      () async {
    await incoming('legacy', 0);
    final conn = await db.database;
    for (final column in [
      'batch_start_message_id',
      'batch_started_at_ms',
      'batch_clock_verified'
    ]) {
      await conn.execute('ALTER TABLE sla_fallbacks DROP COLUMN $column');
    }
    await conn.execute('PRAGMA user_version=17');
    await db.close();
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    expect((await db.slaFallbackJob('a'))!.messageId,
        'incoming-time:a:2026-11-01T04:20:00Z');
    await incoming('later', 5);
    expect((await db.slaFallbackJob('a'))!.batchStartMessageId,
        'incoming-time:a:2026-11-01T04:20:00Z');
  });
}
