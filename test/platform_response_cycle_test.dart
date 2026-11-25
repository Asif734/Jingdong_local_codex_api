import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_red_cycle_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> message(String id, int second) async {
    await db.saveCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: start.add(Duration(seconds: second)),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'real problem $id',
              sentAt: start.add(Duration(seconds: second)),
              axPath: 'fixture')
        ]));
  }

  test('restart requires a current sidebar observation before holding can send',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final job = (await db.slaFallbackJob('a'))!;
    await db.requireFreshPlatformClock();
    expect(await db.isPlatformResponsePending(job), isFalse);
    await db.observePlatformResponse('a',
        red: true,
        observedAt: start.add(const Duration(seconds: 10)),
        ageSeconds: 10);
    expect(await db.isPlatformResponsePending(job), isTrue);
    expect((await db.slaFallbackJob('a'))!.dueAt, job.dueAt);
  });

  test(
      'explicit rejection rearms only its own confirmation, never a newer send',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final job = (await db.slaFallbackJob('a'))!;
    await db.confirmPlatformResponse('a', start, attemptId: 'failed');
    await db.rejectPlatformResponse('a', 'failed');
    expect(await db.isPlatformResponsePending(job), isTrue);
    expect(await db.slaFallbackJob('a'), isNotNull);
    await db.confirmPlatformResponse('a', start, attemptId: 'successful');
    await db.rejectPlatformResponse('a', 'failed');
    expect(await db.isPlatformResponsePending(job), isFalse);
  });
  test('fresh AX timer after a pause proves a new round without OCR input',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final old = (await db.slaFallbackJob('a'))!;
    await db.confirmPlatformResponse(
        'a', start.add(const Duration(seconds: 20)));
    await db.requireFreshPlatformClock();
    await db.observePlatformResponse('a',
        red: true,
        observedAt: start.add(const Duration(seconds: 60)),
        ageSeconds: 2);
    final next = (await db.slaFallbackJob('a'))!;
    expect(next.batchStartMessageId, isNot(old.batchStartMessageId));
    expect(next.dueAt.toUtc(), start.add(const Duration(seconds: 78)));
    expect(await db.isPlatformResponsePending(next), isTrue);
  });
  test('old AX counter after a pause cannot manufacture a new round', () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    await db.confirmPlatformResponse(
        'a', start.add(const Duration(seconds: 20)));
    await db.requireFreshPlatformClock();
    await db.observePlatformResponse('a',
        red: true,
        observedAt: start.add(const Duration(seconds: 60)),
        ageSeconds: 60);
    expect((await db.platformResponseCycle('a'))!['state'], 'sent');
  });

  test(
      'legacy media deadline caps and temporal receipts cannot mutate a new red cycle',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final job = (await db.slaFallbackJob('a'))!;
    await db.capSlaFallbackDue(
        userId: 'a', dueAt: start.subtract(const Duration(minutes: 2)));
    expect((await db.slaFallbackJob('a'))!.dueAt, job.dueAt);
    await (await db.history).appendSlaFallbackSent(
        userId: 'a', messageId: 'old-cycle', reply: '请稍等，我正在核对您刚发来的消息。');
    await db.acknowledgeUncapturedHolding(
        userId: 'a', sentAt: DateTime.now().add(const Duration(seconds: 1)));
    expect(
        await db.reserveSlaFallback(
            userId: 'a', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
  });

  test(
      'an authoritative red observation repairs a previously corrupted legacy deadline',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final first = (await db.slaFallbackJob('a'))!;
    await (await db.database)
        .update('sla_fallbacks', {'due_at_ms': 0, 'batch_started_at_ms': 0});
    await db.observePlatformResponse('a',
        red: true,
        observedAt: start.add(const Duration(seconds: 4)),
        ageSeconds: 4);
    expect((await db.slaFallbackJob('a'))!.dueAt, first.dueAt);
  });

  test('an older clear snapshot cannot erase a newly observed red period',
      () async {
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 10)));
    final job = (await db.slaFallbackJob('a'))!;
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 9)));
    expect(await db.isPlatformResponsePending(job), isTrue);
  });

  test('new messages without a red clock cannot authorize timeout holding',
      () async {
    await message('one', 0);
    final legacy = (await db.slaFallbackJob('a'))!;
    expect(await db.isPlatformResponsePending(legacy), isFalse);
    expect(await db.hasPendingUnanswered('a'), isTrue);
  });
  test(
      'red clock precedes OCR, continuous burst and media delay keep one deadline',
      () async {
    await db.observePlatformResponse('a',
        red: true,
        ageSeconds: 8,
        observedAt: start.add(const Duration(seconds: 8)));
    final first = (await db.slaFallbackJob('a'))!;
    expect(first.dueAt.toUtc(), start.add(const Duration(seconds: 20)));
    await message('one', 9);
    await message('two', 15);
    await db.observePlatformResponse('a',
        red: true,
        ageSeconds: 18,
        observedAt: start.add(const Duration(seconds: 18)));
    final later = (await db.slaFallbackJob('a'))!;
    expect(later.batchStartMessageId, first.batchStartMessageId);
    expect(later.dueAt, first.dueAt);
    expect(await db.isPlatformResponsePending(later), isTrue);
  });
  test(
      'holding satisfies only platform deadline, the actual question stays queued',
      () async {
    await db.observePlatformResponse('a',
        red: true,
        ageSeconds: 2,
        observedAt: start.add(const Duration(seconds: 2)));
    await message('question', 3);
    final job = (await db.slaFallbackJob('a'))!;
    await db.confirmPlatformResponse(
        'a', start.add(const Duration(seconds: 20)));
    expect(await db.isPlatformResponsePending(job), isFalse);
    await message('additional-detail', 21);
    expect(await db.slaFallbackJob('a'), isNull);
    expect(await db.hasPendingUnanswered('a'), isTrue);
  });
  test('badge gone cancels holding even without final answer', () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final job = (await db.slaFallbackJob('a'))!;
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 10)));
    expect(await db.isPlatformResponsePending(job), isFalse);
    expect(await db.slaFallbackJob('a'), isNull);
  });
  test('confirmed old clock cannot rearm, a genuinely new red clock can',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final old = (await db.slaFallbackJob('a'))!;
    await db.confirmPlatformResponse('a', start);
    await db.observePlatformResponse('a',
        red: true,
        ageSeconds: 21,
        observedAt: start.add(const Duration(seconds: 21)));
    expect(await db.slaFallbackJob('a'), isNull);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 22)));
    await db.observePlatformResponse('a',
        red: true,
        ageSeconds: 1,
        observedAt: start.add(const Duration(seconds: 40)));
    final next = (await db.slaFallbackJob('a'))!;
    expect(next.batchStartMessageId, isNot(old.batchStartMessageId));
    expect(await db.isPlatformResponsePending(old), isFalse);
    expect(await db.isPlatformResponsePending(next), isTrue);
  });
  test('unverified row cannot send; canonical AX binding preserves deadline',
      () async {
    await db.observePlatformResponse('row:opaque',
        red: true, ageSeconds: 18, identityVerified: false);
    final observed = (await db.slaFallbackJob('row:opaque'))!;
    expect(await db.isPlatformResponsePending(observed), isFalse);
    await db.rebindPlatformResponse('row:opaque', 'a');
    final bound = (await db.slaFallbackJob('a'))!;
    expect(await db.isPlatformResponsePending(bound), isTrue);
    expect(bound.dueAt.difference(observed.dueAt).abs(),
        lessThan(const Duration(seconds: 1)));
  });
  test('new cycle cannot inherit old attempt and pre-send open failure retries',
      () async {
    await db.observePlatformResponse('a', red: true, observedAt: start);
    final old = (await db.slaFallbackJob('a'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'a', messageId: old.messageId, dueAt: old.dueAt),
        isTrue);
    final attempt = await db.beginSlaAttempt(old, 'holding');
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'submitted'
    }));
    await db.markSlaFallbackSent(
        userId: 'a',
        messageId: old.messageId,
        reply: 'holding',
        batchStartMessageId: old.batchStartMessageId,
        nativeConfirmed: true);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 22)));
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 40)));
    final next = (await db.slaFallbackJob('a'))!;
    final row = (await (await db.database).query('sla_fallbacks')).single;
    expect(row['attempt_id'], isNull);
    await db.reserveSlaFallback(
        userId: 'a', messageId: next.messageId, dueAt: next.dueAt);
    // Simulate legacy stale pointer to prove the release checks batch ownership.
    await (await db.database)
        .update('sla_fallbacks', {'attempt_id': attempt['attemptId']});
    await db.releaseSlaFallback(
        userId: 'a', messageId: next.messageId, retryDelay: Duration.zero);
    expect((await (await db.database).query('sla_fallbacks')).single['state'],
        'pending');
    expect(
        (await (await db.database).query('delivery_attempts')).single['state'],
        'sending');
  });
  test('native success from an older attempt cannot clear a newer red cycle',
      () async {
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 30)));
    final job = (await db.slaFallbackJob('a'))!;
    await db.confirmPlatformResponse('a', start);
    expect(await db.isPlatformResponsePending(job), isTrue);
  });
}
