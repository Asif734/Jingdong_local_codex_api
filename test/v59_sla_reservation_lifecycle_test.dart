import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  final start = DateTime.utc(2026, 11, 11, 10, 20);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v59_sla_lifecycle_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<SlaFallbackJob> openCycle(int second) async {
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(Duration(seconds: second)));
    return (await db.slaFallbackJob('a'))!;
  }

  Future<void> reserve(SlaFallbackJob job) async {
    expect(
        await db.reserveSlaFallback(
            userId: job.userId, messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
  }

  Future<Map<String, Object?>> timerRow() async => (await (await db.database)
          .query('sla_fallbacks', where: 'user_id=?', whereArgs: ['a']))
      .single;

  test('cleared red retires an unstarted reservation and next cycle can send',
      () async {
    final old = await openCycle(0);
    await reserve(old);
    expect((await timerRow())['state'], 'sending');
    expect((await timerRow())['attempt_id'], isNull);

    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    expect((await timerRow())['state'], 'completed');
    expect(await db.isPlatformResponsePending(old), isFalse);

    final next = await openCycle(40);
    expect(next.messageId, isNot(old.messageId));
    expect(next.startedAt?.toUtc(), start.add(const Duration(seconds: 40)));
    expect(next.dueAt.toUtc(), start.add(const Duration(seconds: 60)));
    expect(await db.isPlatformResponsePending(next), isTrue);
    await reserve(next);
    final attempt =
        await db.beginSlaAttempt(next, 'I am checking this for you.');
    expect(attempt['attemptId'], isNotEmpty);
  });

  test('new cycle repairs a legacy poisoned unstarted sending row', () async {
    final old = await openCycle(0);
    await reserve(old);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    // A v58 after-open return left this exact no-attempt reservation behind.
    await (await db.database).update(
        'sla_fallbacks',
        {
          'state': 'sending',
          'attempt_id': null,
          'retry_at_ms': 0,
        },
        where: 'user_id=?',
        whereArgs: ['a']);

    final next = await openCycle(40);
    expect(next.messageId, isNot(old.messageId));
    expect(next.dueAt.toUtc(), start.add(const Duration(seconds: 60)));
    expect((await timerRow())['attempt_id'], isNull);
    expect(await db.isPlatformResponsePending(next), isTrue);
    await reserve(next);
  });

  test('a repeated red observation keeps the current unstarted reservation',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    await db.observePlatformResponse('a',
        red: true,
        observedAt: start.add(const Duration(seconds: 4)),
        ageSeconds: 4);
    final row = await timerRow();
    expect(row['state'], 'sending');
    expect(row['message_id'], job.messageId);
    expect(row['due_at_ms'], job.dueAt.millisecondsSinceEpoch);
    expect(await db.slaFallbackJob('a'), isNull);
  });

  test('pre-native cleanup releases only the exact current reservation',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    final staleDeadline = SlaFallbackJob(
      userId: job.userId,
      messageId: job.messageId,
      batchStartMessageId: job.batchStartMessageId,
      dueAt: job.dueAt.subtract(const Duration(milliseconds: 1)),
      startedAt: job.startedAt,
    );
    expect(await db.releaseUnstartedSlaFallback(staleDeadline), isFalse);
    expect((await timerRow())['state'], 'sending');

    expect(await db.releaseUnstartedSlaFallback(job, retryDelay: Duration.zero),
        isTrue);
    final retried = (await db.slaFallbackJob('a'))!;
    expect(retried.messageId, job.messageId);
    expect(retried.dueAt, job.dueAt);
    expect(retried.startedAt, job.startedAt);
    expect(retried.retryAt, isNotNull,
        reason: 'a fast reopen still queues as a retry behind first attempts');
    expect(retried.retryAt!.isAfter(DateTime.now()), isFalse);
    expect(await db.releaseUnstartedSlaFallback(job), isFalse);
    expect((await db.slaFallbackJob('a'))!.dueAt, job.dueAt);
    await reserve(retried);
  });

  test('old cleanup and completion cannot erase a newer reservation', () async {
    final old = await openCycle(0);
    await reserve(old);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    final next = await openCycle(40);

    expect(await db.releaseUnstartedSlaFallback(old), isFalse);
    expect(await db.completeSlaForObservedReply(old), isFalse);
    await db.releaseSlaFallback(userId: 'a', messageId: old.messageId);
    expect((await db.slaFallbackJob('a'))!.messageId, next.messageId);

    await reserve(next);
    expect(await db.releaseUnstartedSlaFallback(old), isFalse);
    expect(await db.completeSlaForObservedReply(old), isFalse);
    await db.releaseSlaFallback(userId: 'a', messageId: old.messageId);
    expect((await timerRow())['message_id'], next.messageId);
    expect((await timerRow())['state'], 'sending');
  });

  test('delayed native clear is bound to its original response cycle',
      () async {
    final old = await openCycle(0);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    final next = await openCycle(40);

    await db.observePlatformResponse('a',
        red: false,
        observedAt: start.add(const Duration(seconds: 45)),
        expectedCycleId: old.batchStartMessageId);
    expect(await db.isPlatformResponsePending(next), isTrue);
    expect((await db.slaFallbackJob('a'))!.messageId, next.messageId);
    expect((await db.slaFallbackJob('a'))!.dueAt, next.dueAt);
    await reserve(next);

    await db.observePlatformResponse('a',
        red: false,
        observedAt: start.add(const Duration(seconds: 46)),
        expectedCycleId: next.batchStartMessageId);
    expect(await db.isPlatformResponsePending(next), isFalse);
    expect((await timerRow())['state'], 'completed');
  });

  test('an orphaned attempt journal prevents null-pointer cleanup', () async {
    final old = await openCycle(0);
    await reserve(old);
    final attempt =
        await db.beginSlaAttempt(old, 'I am checking this for you.');
    await (await db.database).update('sla_fallbacks', {'attempt_id': null},
        where: 'user_id=?', whereArgs: ['a']);

    expect(await db.releaseUnstartedSlaFallback(old), isFalse);
    await db.releaseSlaFallback(userId: 'a', messageId: old.messageId);
    expect((await timerRow())['state'], 'sending');
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 40)));
    expect((await timerRow())['message_id'], old.messageId);
    expect((await timerRow())['state'], 'sending');
    expect(await db.slaFallbackJob('a'), isNull);
    final durableAttempt = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    expect(durableAttempt['state'], 'sending');
  });

  for (final phase in ['not_sent', 'rejected']) {
    test('retry clears the owned $phase attempt before a new reservation',
        () async {
      final old = await openCycle(0);
      await reserve(old);
      final attempt =
          await db.beginSlaAttempt(old, 'I am checking this for you.');
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'a',
        'state': phase,
      }));
      await db.releaseSlaFallback(
          userId: 'a', messageId: old.messageId, retryDelay: Duration.zero);
      final retry = (await db.slaFallbackJob('a'))!;
      expect(retry.dueAt, old.dueAt);
      expect((await timerRow())['attempt_id'], attempt['attemptId']);

      await reserve(retry);
      expect((await timerRow())['attempt_id'], isNull);
      expect(await db.releaseUnstartedSlaFallback(retry), isTrue);
      await reserve((await db.slaFallbackJob('a'))!);
      await db.observePlatformResponse('a',
          red: false, observedAt: start.add(const Duration(seconds: 21)));
      expect((await timerRow())['state'], 'completed');
      final next = await openCycle(40);
      expect(next.messageId, isNot(old.messageId));
      await reserve(next);
    });
  }

  test('an active unknown attempt cannot be reserved from a stale pending row',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    final attempt =
        await db.beginSlaAttempt(job, 'I am checking this for you.');
    await (await db.database).update('delivery_attempts', {'state': 'unknown'},
        where: 'attempt_id=?', whereArgs: [attempt['attemptId']]);
    await (await db.database).update('sla_fallbacks', {'state': 'pending'},
        where: 'user_id=?', whereArgs: ['a']);
    expect(
        await db.reserveSlaFallback(
            userId: 'a', messageId: job.messageId, dueAt: job.dueAt),
        isFalse);
    expect((await timerRow())['attempt_id'], attempt['attemptId']);
  });

  test(
      'exact explicit native-not-invoked proof permits an absent-receipt retry',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    final attempt =
        await db.beginSlaAttempt(job, 'I am checking this for you.');
    await db.releaseSlaFallback(
      userId: 'a',
      messageId: job.messageId,
      expectedAttemptId: attempt['attemptId'],
      nativeNotInvoked: true,
      retryDelay: Duration.zero,
    );
    expect((await timerRow())['state'], 'pending');
    final durableAttempt = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    expect(durableAttempt['state'], 'not_sent');
    await reserve((await db.slaFallbackJob('a'))!);
    expect((await timerRow())['attempt_id'], isNull);
  });

  test('mismatched expected attempt proof cannot release the current attempt',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    final attempt =
        await db.beginSlaAttempt(job, 'I am checking this for you.');
    await db.releaseSlaFallback(
      userId: 'a',
      messageId: job.messageId,
      expectedAttemptId: 'different-attempt',
      nativeNotInvoked: true,
    );
    expect((await timerRow())['state'], 'sending');
    expect((await timerRow())['attempt_id'], attempt['attemptId']);
    final durableAttempt = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    expect(durableAttempt['state'], 'sending');
  });

  test('dangling attempt pointer is uncertainty rather than retry permission',
      () async {
    final job = await openCycle(0);
    await reserve(job);
    await (await db.database).update(
        'sla_fallbacks', {'attempt_id': 'missing-owned-attempt'},
        where: 'user_id=?', whereArgs: ['a']);
    await db.releaseSlaFallback(
      userId: 'a',
      messageId: job.messageId,
      expectedAttemptId: 'missing-owned-attempt',
      nativeNotInvoked: true,
    );
    expect((await timerRow())['state'], 'reconciling');
    expect((await timerRow())['attempt_id'], 'missing-owned-attempt');
    expect(await db.slaFallbackJob('a'), isNull);
  });

  test('a different customer attempt pointer never proves this send uninvoked',
      () async {
    await db.observePlatformResponse('b', red: true, observedAt: start);
    final other = (await db.slaFallbackJob('b'))!;
    await reserve(other);
    final otherAttempt =
        await db.beginSlaAttempt(other, 'I am checking this for you.');
    final job = await openCycle(0);
    await reserve(job);
    await (await db.database).update(
        'sla_fallbacks', {'attempt_id': otherAttempt['attemptId']},
        where: 'user_id=?', whereArgs: ['a']);
    await db.releaseSlaFallback(
      userId: 'a',
      messageId: job.messageId,
      expectedAttemptId: otherAttempt['attemptId'],
      nativeNotInvoked: true,
    );
    expect((await timerRow())['state'], 'reconciling');
    expect((await timerRow())['attempt_id'], otherAttempt['attemptId']);
    final durableAttempt = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [otherAttempt['attemptId']]))
        .single;
    expect(durableAttempt['user_id'], 'b');
    expect(durableAttempt['state'], 'sending');
  });

  for (final confirmedOldCycle in [true, false]) {
    test(
        '${confirmedOldCycle ? 'confirmed' : 'unconfirmed'} old same-customer pointer requires exact cycle receipt',
        () async {
      final old = await openCycle(0);
      await reserve(old);
      final oldAttempt =
          await db.beginSlaAttempt(old, 'I am checking this for you.');
      if (confirmedOldCycle) {
        await File(oldAttempt['receiptPath']!).writeAsString(jsonEncode({
          'attemptId': oldAttempt['attemptId'],
          'customer': 'a',
          'state': 'submitted',
        }));
        await db.markSlaFallbackSent(
          userId: 'a',
          messageId: old.messageId,
          reply: 'I am checking this for you.',
          batchStartMessageId: old.batchStartMessageId,
          nativeConfirmed: true,
        );
      } else {
        // A legacy rollover can leave an unrelated, unconfirmed attempt pointer.
        await (await db.database).update(
            'sla_fallbacks', {'state': 'completed'},
            where: 'user_id=?', whereArgs: ['a']);
      }
      await db.observePlatformResponse('a',
          red: false, observedAt: start.add(const Duration(seconds: 21)));
      final next = await openCycle(40);
      await reserve(next);
      await (await db.database).update(
          'sla_fallbacks', {'attempt_id': oldAttempt['attemptId']},
          where: 'user_id=?', whereArgs: ['a']);

      await db.releaseSlaFallback(
          userId: 'a', messageId: next.messageId, retryDelay: Duration.zero);
      final row = await timerRow();
      expect(row['message_id'], next.messageId);
      expect(row['state'], confirmedOldCycle ? 'pending' : 'reconciling');
      expect(row['attempt_id'],
          confirmedOldCycle ? isNull : oldAttempt['attemptId']);
      expect(
          await db.slaFallbackJob('a'), confirmedOldCycle ? isNotNull : isNull);
      final durableAttempt = (await (await db.database).query(
              'delivery_attempts',
              where: 'attempt_id=?',
              whereArgs: [oldAttempt['attemptId']]))
          .single;
      expect(durableAttempt['state'], 'sending');
    });
  }

  test('old batch receipt cannot confirm a different unknown attempt',
      () async {
    final old = await openCycle(0);
    await reserve(old);
    final successful =
        await db.beginSlaAttempt(old, 'I am checking this for you.');
    await File(successful['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': successful['attemptId'],
      'customer': 'a',
      'state': 'submitted',
    }));
    await db.markSlaFallbackSent(
      userId: 'a',
      messageId: old.messageId,
      reply: 'I am checking this for you.',
      batchStartMessageId: old.batchStartMessageId,
      nativeConfirmed: true,
    );
    // Simulate a legacy second attempt for the already receipted old batch.
    await (await db.database).update('sla_fallbacks', {'state': 'sending'},
        where: 'user_id=?', whereArgs: ['a']);
    final unknown = await db.beginSlaAttempt(old, 'A second old holding.');
    await (await db.database).update('delivery_attempts', {'state': 'unknown'},
        where: 'attempt_id=?', whereArgs: [unknown['attemptId']]);
    await File(unknown['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': unknown['attemptId'],
      'customer': 'a',
      'state': 'unknown',
    }));
    await (await db.database).update('sla_fallbacks', {'state': 'completed'},
        where: 'user_id=?', whereArgs: ['a']);
    await db.observePlatformResponse('a',
        red: false, observedAt: start.add(const Duration(seconds: 21)));
    final next = await openCycle(40);
    await reserve(next);
    await (await db.database).update(
        'sla_fallbacks', {'attempt_id': unknown['attemptId']},
        where: 'user_id=?', whereArgs: ['a']);

    await db.releaseSlaFallback(userId: 'a', messageId: next.messageId);
    expect((await timerRow())['state'], 'reconciling');
    expect((await timerRow())['attempt_id'], unknown['attemptId']);
    expect(await db.slaFallbackJob('a'), isNull);
    final oldAttempts = await (await db.database).query('delivery_attempts',
        where: 'attempt_id IN (?,?)',
        whereArgs: [successful['attemptId'], unknown['attemptId']]);
    expect(
        oldAttempts.singleWhere(
            (a) => a['attempt_id'] == successful['attemptId'])['state'],
        'sending');
    expect(
        oldAttempts.singleWhere(
            (a) => a['attempt_id'] == unknown['attemptId'])['state'],
        'unknown');
  });

  for (final phase in ['unknown', 'submitted']) {
    test('existing $phase native receipt overrides a native-not-invoked claim',
        () async {
      final job = await openCycle(0);
      await reserve(job);
      final attempt =
          await db.beginSlaAttempt(job, 'I am checking this for you.');
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'a',
        'state': phase,
      }));
      await db.releaseSlaFallback(
        userId: 'a',
        messageId: job.messageId,
        expectedAttemptId: attempt['attemptId'],
        nativeNotInvoked: true,
      );
      expect((await timerRow())['state'], 'reconciling');
      final durableAttempt = (await (await db.database).query(
              'delivery_attempts',
              where: 'attempt_id=?',
              whereArgs: [attempt['attemptId']]))
          .single;
      expect(durableAttempt['state'], phase);
    });
  }

  for (final phase in ['missing', 'unknown', 'submitted']) {
    test('a reconciling $phase attempt survives repeated and new red cycles',
        () async {
      final old = await openCycle(0);
      await reserve(old);
      final attempt =
          await db.beginSlaAttempt(old, 'I am checking this for you.');
      if (phase != 'missing') {
        await File(attempt['receiptPath']!).writeAsString(jsonEncode({
          'attemptId': attempt['attemptId'],
          'customer': 'a',
          'state': phase,
        }));
      }
      await db.releaseSlaFallback(userId: 'a', messageId: old.messageId);
      expect((await timerRow())['state'], 'reconciling');
      await db.observePlatformResponse('a',
          red: true,
          observedAt: start.add(const Duration(seconds: 4)),
          ageSeconds: 4);
      expect((await timerRow())['state'], 'reconciling');
      expect((await timerRow())['attempt_id'], attempt['attemptId']);
      expect(await db.slaFallbackJob('a'), isNull);
      await db.observePlatformResponse('a',
          red: false, observedAt: start.add(const Duration(seconds: 21)));
      await db.observePlatformResponse('a',
          red: true, observedAt: start.add(const Duration(seconds: 40)));
      expect((await timerRow())['state'], 'reconciling');
      expect((await timerRow())['message_id'], old.messageId);
      expect((await timerRow())['attempt_id'], attempt['attemptId']);
      expect(await db.slaFallbackJob('a'), isNull);
    });
  }

  for (final phase in ['missing', 'unknown', 'submitted']) {
    test('a real $phase native attempt survives clear and new red evidence',
        () async {
      final old = await openCycle(0);
      await reserve(old);
      final attempt =
          await db.beginSlaAttempt(old, 'I am checking this for you.');
      final attemptId = attempt['attemptId']!;
      if (phase != 'missing') {
        await (await db.database).update('delivery_attempts', {'state': phase},
            where: 'attempt_id=?', whereArgs: [attemptId]);
        await File(attempt['receiptPath']!).writeAsString(jsonEncode({
          'attemptId': attemptId,
          'customer': 'a',
          'state': phase,
        }));
      }

      expect(await db.releaseUnstartedSlaFallback(old), isFalse);
      await db.observePlatformResponse('a',
          red: false, observedAt: start.add(const Duration(seconds: 21)));
      await db.observePlatformResponse('a',
          red: true, observedAt: start.add(const Duration(seconds: 40)));
      final row = await timerRow();
      expect(row['message_id'], old.messageId);
      expect(row['state'], 'sending');
      expect(row['attempt_id'], attemptId);
      expect(await db.slaFallbackJob('a'), isNull);

      await db.releaseSlaFallback(userId: 'a', messageId: old.messageId);
      expect((await timerRow())['state'], 'reconciling');
      expect((await timerRow())['attempt_id'], attemptId);
      final durableAttempt = (await (await db.database).query(
        'delivery_attempts',
        where: 'attempt_id=?',
        whereArgs: [attemptId],
      ))
          .single;
      expect(durableAttempt['state'],
          phase == 'submitted' ? 'submitted' : 'unknown');
    });
  }
}
