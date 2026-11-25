import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  const customer = 'customer-a';
  const reconciliation = 'send_unconfirmed: reconciliation_required';
  late Directory root;
  late CaptureDatabase db;
  late DateTime base;

  DateTime at(int seconds) => base.add(Duration(seconds: seconds));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v64_cycle_isolation_');
    db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    base = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 25000,
        isUtc: true);
    await db.beginAutomationSession(startedAt: at(-1));
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<bool> reserve(SlaFallbackJob job) => db.reserveSlaFallback(
      userId: job.userId, messageId: job.messageId, dueAt: job.dueAt);

  Future<void> writeReceipt(
      Map<String, String> attempt, String state, int receiptSecond) async {
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'state': state,
      'timeMs': at(receiptSecond).millisecondsSinceEpoch,
    }));
  }

  Future<(SlaFallbackJob, Map<String, String>)> uncertainHolding() async {
    await db.observePlatformResponse(customer, red: true, observedAt: base);
    final old = (await db.slaFallbackJob(customer))!;
    expect(await reserve(old), isTrue);
    final attempt = await db.beginSlaAttempt(old, 'Old holding response.');
    await writeReceipt(attempt, 'unknown', 26);
    await db.releaseSlaFallback(
        userId: customer,
        messageId: old.messageId,
        expectedAttemptId: attempt['attemptId']);
    await db.suspendUnavailableConversation(customer, reconciliation);
    return (old, attempt);
  }

  Future<String?> attemptState(Map<String, String> attempt) async =>
      (await (await db.database).query('delivery_attempts',
              columns: ['state'],
              where: 'attempt_id=?',
              whereArgs: [attempt['attemptId']]))
          .single['state'] as String?;

  test('old uncertain holding stays in the journal and releases only its slot',
      () async {
    final (old, attempt) = await uncertainHolding();
    expect(await db.slaFallbackJob(customer), isNull);
    expect(await reserve(old), isFalse);
    await db.observePlatformResponse(customer, red: true, observedAt: at(40));
    expect(await db.isPlatformResponsePending(old), isTrue);
    expect(await db.slaFallbackJob(customer), isNull,
        reason: 'age alone is not a new red period');
    await db.requireFreshPlatformClock();
    await db.observePlatformResponse(customer, red: true, observedAt: at(40));
    expect(await db.isPlatformResponsePending(old), isTrue,
        reason: 'a resumed red without a fresh counter is not a new round');
    await db.observePlatformResponse(customer, red: false, observedAt: at(41));
    await db.observePlatformResponse(customer,
        red: true, observedAt: at(65), identityVerified: false);
    expect(await db.slaFallbackJob(customer), isNull,
        reason: 'replacement requires a verified observation');

    await db.observePlatformResponse(customer, red: true, observedAt: at(66));
    final next = await db.slaFallbackJob(customer);
    expect(next, isNotNull,
        reason: 'new verified red period must take over the active SLA slot');
    expect(next!.messageId, isNot(old.messageId));
    expect(next.dueAt.toUtc(), at(85));
    expect(await db.isPlatformResponsePending(next), isTrue);
    expect(await db.isConversationUnavailable(customer), isFalse);
    expect(await attemptState(attempt), 'unknown');
    expect(await File(attempt['receiptPath']!).exists(), isTrue);
    expect(await reserve(old), isFalse);
    // A previous scheduler snapshot can still request suspension. It must not
    // recreate the old receipt's customer-wide block after releasing the slot.
    await db.suspendUnavailableConversation(customer, reconciliation);
    expect(await db.isConversationUnavailable(customer), isFalse);
    expect(await reserve(next), isTrue);
  });

  test('late exact old native receipt cannot satisfy the later red cycle',
      () async {
    final (old, attempt) = await uncertainHolding();
    await db.observePlatformResponse(customer, red: false, observedAt: at(41));
    await db.observePlatformResponse(customer, red: true, observedAt: at(65));
    final cycle = (await db.platformResponseCycle(customer))!;

    await db.confirmPlatformResponse(customer, at(67),
        attemptId: attempt['attemptId']);
    expect((await db.platformResponseCycle(customer))!['state'], 'waiting',
        reason: 'an old SLA attempt is explicitly bound to its prior cycle');

    // Simulate a late submitted journal with no physical click stamp. Its
    // confirmation time is later than the start of the different red period.
    await writeReceipt(attempt, 'submitted', 68);
    await db.recoverDeliveryReceipts();
    expect(await attemptState(attempt), 'submitted');
    expect((await db.platformResponseCycle(customer))!['state'], 'waiting');
    expect((await db.platformResponseCycle(customer))!['cycle_id'],
        cycle['cycle_id']);
    final active = (await db.slaFallbackJob(customer))!;
    expect(active.messageId, isNot(old.messageId));
    expect(await db.hasConfirmedResponseForCycle(active), isFalse);
    expect(await reserve(active), isTrue);
    final receipts = await (await db.database).query('sla_delivery_receipts',
        where: 'user_id=?', whereArgs: [customer]);
    expect(receipts.map((r) => r['batch_start_message_id']),
        [old.batchStartMessageId]);
  });

  test('a late send callback cannot confirm a different current red round',
      () async {
    await db.observePlatformResponse(customer, red: true, observedAt: base);
    final prior = (await db.slaFallbackJob(customer))!;
    await db.observePlatformResponse(customer, red: false, observedAt: at(21));
    await db.observePlatformResponse(customer, red: true, observedAt: at(30));
    final next = (await db.slaFallbackJob(customer))!;

    await db.confirmPlatformResponse(customer, at(31),
        expectedCycleId: prior.messageId);
    expect(await db.isPlatformResponsePending(next), isTrue);
    await db.confirmPlatformResponse(customer, at(32),
        expectedCycleId: next.messageId);
    expect(await db.isPlatformResponsePending(next), isFalse);
  });

  test('other customers keep independent pending deadlines and reservations',
      () async {
    final (old, _) = await uncertainHolding();
    await db.observePlatformResponse('customer-b',
        red: true, observedAt: at(61));
    await db.observePlatformResponse('customer-c',
        red: true, observedAt: at(60));
    expect((await db.pendingSlaFallbackJobs()).map((j) => j.userId),
        ['customer-c', 'customer-b']);
    expect(await reserve(old), isFalse);

    await db.observePlatformResponse(customer, red: false, observedAt: at(64));
    await db.observePlatformResponse(customer, red: true, observedAt: at(65));
    final jobs = await db.pendingSlaFallbackJobs();
    expect(jobs.map((j) => j.userId), ['customer-c', 'customer-b', customer]);
    expect(jobs.map((j) => j.dueAt.toUtc()), [at(80), at(81), at(85)]);
    for (final job in jobs) {
      expect(await reserve(job), isTrue);
    }
  });

  test('a new red cycle does not clear a real conversation suspension',
      () async {
    await uncertainHolding();
    await db.suspendUnavailableConversation(customer, 'conversation_changed');
    await db.observePlatformResponse(customer, red: false, observedAt: at(41));
    await db.observePlatformResponse(customer, red: true, observedAt: at(65));
    expect(await db.isConversationUnavailable(customer), isTrue);
    expect(await db.slaFallbackJob(customer), isNull);
    await db.resumeVisibleConversations([customer], verifiedActive: [customer]);
    expect((await db.slaFallbackJob(customer))!.dueAt.toUtc(), at(85));
  });

  Future<String> receive(String id, String body, DateTime received) async {
    await db.saveCapture(CapturedConversation(
      stableKey: customer,
      customerName: customer,
      customerExternalId: customer,
      capturedAt: received,
      automationSessionId: db.currentAutomationSessionId,
      messages: [
        CapturedMessage(
          stableId: id,
          direction: 'incoming',
          sender: customer,
          body: body,
          sentAt: received,
          axPath: 'fixture',
        ),
      ],
    ));
    return (await db.incomingMessageIdAtTime(customer, received))!;
  }

  Future<String> prepareEarlyAnswer() async {
    await db.observePlatformResponse(customer, red: true, observedAt: base);
    final canonical = await receive(
        'first-question', 'Please tell me the Wi-Fi prerequisites.', at(1));
    final pending = (await db.conversation(customer))!;
    final draft = AiDraft.fromJson({
      'reply': 'Connect the phone and printer to the same 2.4 GHz network.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'auto_send_allowed': true,
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(pending.id, draft,
            expectedUserId: customer, expectedMessageId: canonical),
        1);
    await (await db.database).update(
        'generated_drafts', {'created_at_ms': at(18).millisecondsSinceEpoch},
        where: 'user_id=?', whereArgs: [customer]);
    return canonical;
  }

  test('formal priority follows configured fifty-second response window',
      () async {
    db.configureAutomationSettings(const AutomationSettings());
    await prepareEarlyAnswer();
    final job = (await db.slaFallbackJob(customer))!;
    expect(job.dueAt.toUtc(), at(50));
    await (await db.database).update(
        'generated_drafts', {'created_at_ms': at(35).millisecondsSinceEpoch},
        where: 'user_id=?', whereArgs: [customer]);
    final early = await db.nextReadyDelivery(
        onlyWithinResponseWindow: true, expectedResponseCycleId: job.messageId);
    expect(early, isNotNull);
    expect(early!.wasGeneratedWithinResponseWindow, isTrue);
    await (await db.database).update(
        'generated_drafts', {'created_at_ms': at(51).millisecondsSinceEpoch},
        where: 'user_id=?', whereArgs: [customer]);
    expect(
        await db.nextReadyDelivery(
            onlyWithinResponseWindow: true,
            expectedResponseCycleId: job.messageId),
        isNull);
    expect(await db.nextReadyDelivery(userId: customer), isNotNull);
  });

  test('ready answer from a previous round cannot veto the current holding',
      () async {
    await prepareEarlyAnswer();
    final first = (await db.slaFallbackJob(customer))!;
    expect(
        (await db.nextReadyDelivery(
                onlyWithinResponseWindow: true,
                expectedResponseCycleId: first.messageId))
            ?.responseWindowCycleId,
        first.messageId);
    await db.observePlatformResponse(customer, red: false, observedAt: at(30));
    await db.observePlatformResponse(customer, red: true, observedAt: at(35));
    final next = (await db.slaFallbackJob(customer))!;
    expect(next.messageId, isNot(first.messageId));
    expect(
        await db.nextReadyDelivery(
            userId: customer, expectedResponseCycleId: next.messageId),
        isNull);
    expect(await reserve(next), isTrue);
    final attempt = await db.beginSlaAttempt(next, 'Current holding.',
        yieldToReadyReply: true, readyReplyMustBeWithinResponseWindow: true);
    expect(attempt['attemptId'], isNotNull);
    expect(await db.nextReadyDelivery(userId: customer), isNotNull,
        reason: 'the earlier real answer remains independent');
  });

  test('recovery of an older formal send preserves the newer red clock',
      () async {
    final answered = await prepareEarlyAnswer();
    final old = (await db.slaFallbackJob(customer))!;
    final delivery = (await db.nextReadyDelivery(userId: customer))!;
    final attempt = await db.beginDeliveryAttempt(
        userId: customer, reply: delivery.draft.reply, taskId: delivery.taskId);
    await db.observePlatformResponse(customer, red: false, observedAt: at(30));
    await db.observePlatformResponse(customer, red: true, observedAt: at(35));
    final next = (await db.slaFallbackJob(customer))!;
    expect(next.messageId, isNot(old.messageId));
    final unanswered = await receive(
        'another-question', 'Which network should I use?', at(35));

    // Exact native success retains its formal message coverage, but the
    // receipt's attempt was created for an earlier red round.
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'state': 'submitted',
      'timeMs': at(38).millisecondsSinceEpoch,
      'sendClickedAtMs': at(36).millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.isPlatformResponsePending(next), isTrue);
    expect(await db.isMessageFormallyAnswered(customer, answered), isTrue);
    expect(await db.isMessageFormallyAnswered(customer, unanswered), isFalse);
    expect((await db.slaFallbackJob(customer))!.messageId, next.messageId);
  });
}
