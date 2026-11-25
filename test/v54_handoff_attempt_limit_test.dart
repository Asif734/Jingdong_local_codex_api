import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/runtime/automation_settings.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'buyer';
  const source = 'source-agent';
  const target = 'target-agent';
  late Directory root;
  late CaptureDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v54_handoff_');
    // These fixtures explicitly exercise the original 20-second SLA window.
    db = CaptureDatabase(
        storageRoot: root,
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> receive(String buyer, {DateTime? senderAt}) async {
    final at = senderAt ?? DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        capturedAt: at,
        automationSessionId: db.currentAutomationSessionId,
        messages: [
          CapturedMessage(
              stableId: '$buyer-request',
              direction: 'incoming',
              body: 'Please help with the paper source setting.',
              sender: buyer,
              sentAt: at,
              captureEvidenceId: '$buyer-frame',
              axPath: 'controlled-customer-text'),
        ]));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<(HumanReviewTicket, ChatTransferLog)> prepare(
      {bool session = true}) async {
    if (session) {
      await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    }
    final message = await receive(customer);
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'Controlled authorized service request',
        reason: 'Authorized order service',
        requestMessageId: message);
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.updateChatTransferLog(
        id: log.id,
        status: 'ready',
        sourceAccount: source,
        targetAccount: target);
    if (!session) await db.markTicketHandoffPending(ticket.id);
    return (ticket, log);
  }

  Future<Map<String, Object?>> row(int id) async => (await (await db.database)
          .query('chat_transfer_logs', where: 'id=?', whereArgs: [id]))
      .single;

  Future<void> setRow(int id, Map<String, Object?> changes) async {
    await (await db.database)
        .update('chat_transfer_logs', changes, where: 'id=?', whereArgs: [id]);
  }

  Future<void> makeDue(int id) => setRow(
      id, {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1});

  Future<void> failTransfer(HumanReviewTicket ticket, ChatTransferLog log,
      {String error = 'controlled_preclick_failure'}) async {
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        error: error);
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: error, countPreclickFailure: true),
        isTrue);
  }

  AiDraft answer(String buyer) => AiDraft.fromJson({
        'reply': 'Select the paper source for $buyer in printer settings.',
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-v54',
        'reply_media_dependency_keys': <String, String>{},
      }, mediaBaseUrl: Uri());

  Future<void> timedAnswer(String buyer, DateTime start, int generatedSecond,
      {bool red = true,
      bool identityVerified = true,
      int queueOrder = 0}) async {
    final id = await receive(buyer, senderAt: start);
    if (red) {
      await db.observePlatformResponse(buyer,
          red: true,
          observedAt: start,
          startedAt: start,
          identityVerified: identityVerified);
    }
    final conversation = (await db.conversation(buyer))!;
    await db.saveDraft(conversation.id, answer(buyer), expectedMessageId: id);
    await (await db.database).update(
        'generated_drafts',
        {
          'created_at_ms': start
              .add(Duration(seconds: generatedSecond))
              .millisecondsSinceEpoch,
          'queued_at_ms': start.millisecondsSinceEpoch + queueOrder,
        },
        where: 'user_id=?',
        whereArgs: [buyer]);
  }

  test(
      'ten actual session failures include the initial attempt, with no eleventh',
      () async {
    final (ticket, log) = await prepare();
    expect(CaptureDatabase.handoffMaxAttempts, 10);
    for (var attempt = 1;
        attempt <= CaptureDatabase.handoffMaxAttempts;
        attempt++) {
      final failedAt = DateTime.now().millisecondsSinceEpoch;
      await failTransfer(ticket, log);
      final failed = await row(log.id);
      expect(failed['preclick_retry_count'], attempt);
      expect(await db.hasPendingUnanswered(customer), isTrue);
      expect(await db.answeredMessageId(customer), isNull);
      if (attempt == CaptureDatabase.handoffMaxAttempts) {
        expect(failed['preclick_retry_at_ms'], 0);
        expect(await db.schedulePreclickTransferRetry(log.id), isNull);
        expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
        expect(await db.duePreclickHandoffs(), isEmpty);
        final status = (await db.handoffServiceStatus(customer))!;
        expect(status['state'], 'retry_exhausted');
        expect(status['requiresOperator'], isTrue);
        break;
      }
      final delay = attempt == 1
          ? 30
          : attempt == 2
              ? 60
              : 180;
      expect(
          failed['preclick_retry_at_ms'],
          inInclusiveRange(failedAt + delay * 1000,
              DateTime.now().millisecondsSinceEpoch + delay * 1000));
      expect((await db.handoffServiceStatus(customer))!['state'],
          'retry_scheduled');
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
      await makeDue(log.id);
      expect((await db.duePreclickHandoffs()).single.id, ticket.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
      expect((await row(log.id))['preclick_retry_count'], attempt,
          reason: 'Reservation does not consume another failure');
    }
  });

  test('retry scheduling clamps the backoff throughout the ten-attempt budget',
      () async {
    final (_, log) = await prepare();
    for (final (count, seconds) in [
      (0, 30),
      (1, 30),
      (2, 60),
      (3, 180),
      (9, 180)
    ]) {
      await setRow(log.id, {
        'status': 'failed',
        'phase': 'retryable_preclick',
        'preclick_retry_count': count,
      });
      final before = DateTime.now();
      final retry = await db.schedulePreclickTransferRetry(log.id);
      expect(retry, isNotNull);
      expect(retry!.difference(before).inMilliseconds,
          inInclusiveRange(seconds * 1000, seconds * 1000 + 1000));
    }
    await setRow(log.id, {'preclick_retry_count': 10});
    expect(await db.schedulePreclickTransferRetry(log.id), isNull);
  });

  test('recovery, due, reserve and status share the same exhaustion boundary',
      () async {
    final (ticket, log) = await prepare();
    await setRow(log.id, {'preclick_retry_count': 9});
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await row(log.id))['status'], 'failed');
    expect((await db.duePreclickHandoffs()).single.id, ticket.id);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    await setRow(log.id, {
      'preclick_retry_count': 10,
      'status': 'ready',
      'phase': 'ready',
      'preclick_retry_at_ms': 0,
    });
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await row(log.id))['preclick_retry_at_ms'], 0);
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    // A stale imported timer cannot reopen an exhausted request either.
    await makeDue(log.id);
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(
        (await db.handoffServiceStatus(customer))!['state'], 'retry_exhausted');
    await expectLater(
        db.beginTransferAttempt(
            logId: log.id, customer: customer, targetAccount: target),
        throwsStateError);
  });

  test('identity wake and saved continuation allow nine failures, not ten',
      () async {
    final (ticket, log) = await prepare();
    await setRow(log.id, {'preclick_retry_count': 9});
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isTrue);
    expect(await db.handoffReplyContinuation(ticket.id), isNotNull);
    expect((await row(log.id))['preclick_retry_count'], 9);
    await setRow(log.id, {
      'status': 'failed',
      'phase': 'retryable_preclick',
      'error': 'identity_unresolved',
      'preclick_retry_at_ms': 0,
    });
    expect(await db.wakeCurrentHandoffAfterIdentity(customer), isTrue);
    await setRow(log.id, {
      'preclick_retry_count': 10,
      'preclick_retry_at_ms': 0,
    });
    expect(await db.wakeCurrentHandoffAfterIdentity(customer), isFalse);
    expect((await row(log.id))['preclick_retry_at_ms'], 0);
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isFalse);
    expect(await db.handoffReplyContinuation(ticket.id), isNull);
    expect(await db.hasPendingUnanswered(customer), isTrue);
  });

  test('uncertain click never becomes another retry and keeps its journal',
      () async {
    final (ticket, log) = await prepare();
    await db.setTransferAcknowledgement(log.id, 1);
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: customer, targetAccount: target);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    final receipt = jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'targetAccount': target,
      'state': 'unknown',
      'transferClicked': true,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    });
    final file = File(attempt['receiptPath']!);
    await file.writeAsString(receipt, flush: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    final unknown = await row(log.id);
    expect(unknown['status'], 'unconfirmed');
    expect(unknown['transfer_clicked'], 1);
    expect(unknown['preclick_retry_at_ms'], 0);
    expect(await db.schedulePreclickTransferRetry(log.id), isNull);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(await db.handoffReplyContinuation(ticket.id), isNull);
    expect(
        await db.deferHandoffForReply(
            logId: log.id,
            ticketId: ticket.id,
            resumePhase: 'revalidate_target',
            provenNotClickedAttemptId: attempt['attemptId']),
        isFalse);
    expect((await db.handoffServiceStatus(customer))!['state'],
        'previous_transfer_unknown');
    expect(await file.readAsString(), receipt);
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.answeredMessageId(customer), isNull);
  });

  test(
      'repeated SLA yields consume no failure and preserve both formal replies',
      () async {
    final (ticket, log) = await prepare();
    await receive('other');
    for (final conversation in await db.conversations()) {
      await db.saveDraft(conversation.id, answer(conversation.userId),
          expectedMessageId: await db.pendingMessageId(conversation.userId));
    }
    await db.observePlatformResponse('other', red: true, ageSeconds: 18);
    final sql = await db.database;
    final drafts = await sql.query('generated_drafts', orderBy: 'user_id');
    final cycle = await db.platformResponseCycle('other');
    expect(drafts, hasLength(2));
    for (var pause = 0;
        pause < CaptureDatabase.handoffMaxAttempts + 2;
        pause++) {
      expect(
          await db.deferHandoffForReply(
              logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
          isTrue);
      expect((await row(log.id))['preclick_retry_count'], 0);
      expect(await db.handoffReplyContinuation(ticket.id), isNotNull);
      await makeDue(log.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    }
    expect(await sql.query('generated_drafts', orderBy: 'user_id'), drafts);
    expect(await db.platformResponseCycle('other'), cycle);
    expect(await db.unansweredWorkCounts(), {customer: 1, 'other': 1});
    expect(await db.isHumanContacting(customer), isFalse);
    expect(await db.answeredMessageId(customer), isNull);
    expect(await db.answeredMessageId('other'), isNull);
  });

  test('legacy initial attempt plus nine retries also stops at ten total',
      () async {
    final (ticket, log) = await prepare(session: false);
    for (var attempt = 1;
        attempt <= CaptureDatabase.handoffMaxAttempts;
        attempt++) {
      expect((await row(log.id))['preclick_retry_count'], attempt - 1);
      await db.updateChatTransferLog(
          id: log.id,
          status: 'failed',
          phase: 'retryable_preclick',
          error: 'controlled_legacy_failure');
      final retry = await db.schedulePreclickTransferRetry(log.id);
      if (attempt == CaptureDatabase.handoffMaxAttempts) {
        expect(retry, isNull);
        expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
        expect(await db.duePreclickHandoffs(), isEmpty);
        expect((await db.handoffServiceStatus(customer))!['state'],
            'retry_exhausted');
        break;
      }
      expect(retry, isNotNull);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
      await makeDue(log.id);
      expect((await db.duePreclickHandoffs()).single.id, ticket.id);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    }
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.answeredMessageId(customer), isNull);
  });

  test('customer-scoped ready selection keeps all delivery state guards',
      () async {
    await prepare();
    await receive('other');
    for (final conversation in await db.conversations()) {
      await db.saveDraft(conversation.id, answer(conversation.userId),
          expectedMessageId: await db.pendingMessageId(conversation.userId));
    }
    final sql = await db.database;
    final before = await sql.query('generated_drafts', orderBy: 'user_id');
    expect((await db.nextReadyDelivery(userId: 'other'))!.userId, 'other');
    expect(await db.nextReadyDelivery(userId: 'absent'), isNull);
    expect(await sql.query('generated_drafts', orderBy: 'user_id'), before,
        reason: 'Selection is not permission to click or consume a reply');
    for (final state in ['sending', 'delivery_unknown', 'transfer_only']) {
      await sql.update('generated_drafts', {'delivery_state': state},
          where: 'user_id=?', whereArgs: ['other']);
      expect(await db.nextReadyDelivery(userId: 'other'), isNull,
          reason: '$state cannot authorize another send');
    }
    await sql.update(
        'generated_drafts',
        {
          'delivery_state': 'retry',
          'retry_at_ms': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch
        },
        where: 'user_id=?',
        whereArgs: ['other']);
    expect(await db.nextReadyDelivery(userId: 'other'), isNull);
    await sql.update('generated_drafts',
        {'retry_at_ms': DateTime.now().millisecondsSinceEpoch - 1},
        where: 'user_id=?', whereArgs: ['other']);
    expect((await db.nextReadyDelivery(userId: 'other'))!.userId, 'other');
    await sql.update('generated_drafts', {'delivery_state': 'delivery_unknown'},
        where: 'user_id=?', whereArgs: ['other']);
    expect((await db.nextReadyDelivery())!.userId, customer,
        reason: 'Default queue selection remains unchanged');
  });

  test('response priority skips a late head and returns an early formal answer',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer('late', start, 21);
    await timedAnswer('early', start, 18, queueOrder: 1);
    expect((await db.nextReadyDelivery())!.userId, 'late');
    final early = await db.nextReadyDelivery(onlyWithinResponseWindow: true);
    expect(early!.userId, 'early');
    expect(early.generatedAt!.millisecondsSinceEpoch,
        start.add(const Duration(seconds: 18)).millisecondsSinceEpoch);
    expect(
        await db.nextReadyDelivery(
            userId: 'late', onlyWithinResponseWindow: true),
        isNull);
    expect(await db.unansweredWorkCounts(), {'late': 1, 'early': 1});
    expect(await (await db.database).query('generated_drafts'), hasLength(2));
  });

  test('unverified or missing red-cycle proof cannot preempt a transfer',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer('no-cycle', start, 18, red: false);
    await timedAnswer('unverified', start, 18, identityVerified: false);
    expect(await db.nextReadyDelivery(onlyWithinResponseWindow: true), isNull);
    expect(
        (await db.nextReadyDelivery(userId: 'no-cycle'))!.userId, 'no-cycle');
    expect((await db.nextReadyDelivery(userId: 'unverified'))!.userId,
        'unverified');
  });

  test('holding clearance retains the original window and the late answer',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer('late', start, 21);
    await timedAnswer('early', start, 18);
    for (final buyer in ['late', 'early']) {
      await db.confirmPlatformResponse(
          buyer, start.add(const Duration(seconds: 20)));
      await db.observePlatformResponse(buyer,
          red: false, observedAt: start.add(const Duration(seconds: 25)));
      final cycle = (await db.platformResponseCycle(buyer))!;
      expect(cycle['state'], 'cleared');
      expect(cycle['started_at_ms'], start.millisecondsSinceEpoch);
    }
    expect(
        await db.nextReadyDelivery(
            userId: 'late', onlyWithinResponseWindow: true),
        isNull);
    expect(
        (await db.nextReadyDelivery(
                userId: 'early', onlyWithinResponseWindow: true))!
            .userId,
        'early');
    expect((await db.nextReadyDelivery(userId: 'late'))!.userId, 'late',
        reason: 'After transfer, ordinary delivery still owns the late reply');
    expect(await db.unansweredWorkCounts(), {'late': 1, 'early': 1});
    expect(await db.answeredMessageId('late'), isNull);
  });

  test(
      'a new live cycle cannot upgrade an old late draft or move an early window',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer('late', start, 25);
    await timedAnswer('early', start, 18);
    for (final buyer in ['late', 'early']) {
      await db.confirmPlatformResponse(
          buyer, start.add(const Duration(seconds: 20)));
      await db.observePlatformResponse(buyer,
          red: false, observedAt: start.add(const Duration(seconds: 26)));
      await db.observePlatformResponse(buyer,
          red: true,
          clockReset: true,
          startedAt: start.add(const Duration(seconds: 30)),
          observedAt: start.add(const Duration(seconds: 30)));
    }
    final late = (await db.nextReadyDelivery(userId: 'late'))!;
    final early = (await db.nextReadyDelivery(userId: 'early'))!;
    expect(late.responseWindowStartedAt!.millisecondsSinceEpoch,
        start.millisecondsSinceEpoch);
    expect(late.wasGeneratedWithinResponseWindow, isFalse);
    expect(early.responseWindowStartedAt!.millisecondsSinceEpoch,
        start.millisecondsSinceEpoch);
    expect(early.wasGeneratedWithinResponseWindow, isTrue);
    expect(
        await db.nextReadyDelivery(
            userId: 'late', onlyWithinResponseWindow: true),
        isNull);
    expect(
        (await db.nextReadyDelivery(
                userId: 'early', onlyWithinResponseWindow: true))!
            .userId,
        'early');
    expect(await db.unansweredWorkCounts(), {'late': 1, 'early': 1});
  });

  for (final freezeBeforeNewCycle in [true, false]) {
    test(
        'generation freezes its own response window beforeNewCycle=$freezeBeforeNewCycle',
        () async {
      final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await db.beginAutomationSession(
          startedAt: start.subtract(const Duration(seconds: 1)));
      final id = await receive(customer, senderAt: start);
      await db.observePlatformResponse(customer,
          red: true, startedAt: start, observedAt: start);
      final pending = (await db.conversation(customer))!;
      Future<String> claim() async => (await db.beginGeneration(
          customer: customer, pendingId: pending.id, batchEndMessageId: id))!;
      String? token;
      if (freezeBeforeNewCycle) token = await claim();
      await db.confirmPlatformResponse(
          customer, start.add(const Duration(seconds: 20)));
      await db.observePlatformResponse(customer,
          red: false, observedAt: start.add(const Duration(seconds: 26)));
      await db.observePlatformResponse(customer,
          red: true,
          clockReset: true,
          startedAt: start.add(const Duration(seconds: 30)),
          observedAt: start.add(const Duration(seconds: 30)));
      token ??= await claim();
      final draft = await db.prepareAutomaticDraft(customer, answer(customer));
      await db.saveAutomaticDraft(pending.id, draft,
          expectedUserId: customer,
          expectedMessageId: id,
          generationToken: token);
      await db.abandonGeneration(customer, token);
      final delivery = (await db.nextReadyDelivery(userId: customer))!;
      if (freezeBeforeNewCycle) {
        expect(delivery.responseWindowStartedAt!.millisecondsSinceEpoch,
            start.millisecondsSinceEpoch);
      } else {
        expect(delivery.responseWindowStartedAt, isNull,
            reason:
                'An old input cannot borrow the new red cycle after waiting');
      }
      expect(delivery.wasGeneratedWithinResponseWindow, isFalse);
      expect(
          await db.nextReadyDelivery(
              userId: customer, onlyWithinResponseWindow: true),
          isNull);
    });
  }

  for (final generatedSecond in [18, 21]) {
    test(
        'SLA atomically yields only to an in-window reply at ${generatedSecond}s',
        () async {
      final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
      await db.beginAutomationSession(
          startedAt: start.subtract(const Duration(seconds: 1)));
      await timedAnswer(customer, start, generatedSecond);
      final job = (await db.slaFallbackJob(customer))!;
      expect(
          await db.reserveSlaFallback(
              userId: customer, messageId: job.messageId, dueAt: job.dueAt),
          isTrue);
      final attempt = await db.beginSlaAttempt(
          job, 'Please wait while I check.',
          yieldToReadyReply: true, readyReplyMustBeWithinResponseWindow: true);
      expect(attempt.isEmpty, generatedSecond <= 20);
      final fallbacks = await (await db.database)
          .query('sla_fallbacks', where: 'user_id=?', whereArgs: [customer]);
      expect(fallbacks.single['state'],
          generatedSecond <= 20 ? 'pending' : 'sending');
      expect(await (await db.database).query('generated_drafts'), hasLength(1));
      expect(await db.unansweredWorkCounts(), {customer: 1});
      expect(await db.answeredMessageId(customer), isNull);
    });
  }

  test('an early ready row awaiting real media cannot also cancel holding',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer(customer, start, 18);
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'actual-media-type-frame',
        observedAt: DateTime.now().toUtc(),
        senderAt: start,
        slot: 0,
        region: [.3, .4, .2, .1],
        current: true);
    await inventory.classify(receipt, 'image');
    await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'actual-media-type-frame',
        occurrenceKey: 'same-customer-and-clock',
        receivedAt: DateTime.now().toUtc(),
        senderAt: start);
    expect(
        await db.nextReadyDelivery(
            userId: customer, onlyWithinResponseWindow: true),
        isNull);
    final sql = await db.database;
    final before = (await sql.query('generated_drafts')).single;
    expect(before['delivery_state'], 'ready',
        reason: 'Type verification retains the exact already-generated reply');
    final job = (await db.slaFallbackJob(customer))!;
    expect(
        await db.reserveSlaFallback(
            userId: customer, messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    final attempt = await db.beginSlaAttempt(job, 'Please wait while I check.',
        yieldToReadyReply: true, readyReplyMustBeWithinResponseWindow: true);
    expect(attempt['attemptId'], isNotNull,
        reason:
            'Pending media and a waiting formal reply must not deadlock SLA');
    expect((await sql.query('generated_drafts')).single, before);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(await db.answeredMessageId(customer), isNull);
  });

  test('a stale early ready row does not reserve the holding response',
      () async {
    final start = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final session = await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await timedAnswer(customer, start, 18);
    final sql = await db.database;
    await sql.rawUpdate('''UPDATE automation_session_messages
      SET work_revision=work_revision+1 WHERE session_id=? AND user_id=?''',
        [session, customer]);
    final job = (await db.slaFallbackJob(customer))!;
    expect(
        await db.reserveSlaFallback(
            userId: customer, messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    final attempt = await db.beginSlaAttempt(job, 'Please wait while I check.',
        yieldToReadyReply: true, readyReplyMustBeWithinResponseWindow: true);
    expect(attempt['attemptId'], isNotNull);
    expect(await db.unansweredWorkCounts(), {customer: 1});
  });

  test('only valid response-yield checkpoints retain the transfer slot',
      () async {
    final (ticket, log) = await prepare();
    expect(await db.hasResumableHandoffCheckpoint(), isFalse);
    expect(
        await db.deferHandoffForReply(
            logId: log.id, ticketId: ticket.id, resumePhase: 'acknowledge'),
        isTrue);
    expect(await db.hasResumableHandoffCheckpoint(), isTrue);
    await makeDue(log.id);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    expect(await db.hasResumableHandoffCheckpoint(), isTrue);
    await failTransfer(ticket, log);
    expect(await db.hasResumableHandoffCheckpoint(), isFalse);
    await setRow(log.id, {
      'status': 'deferred',
      'phase': 'reply_deferred:acknowledge',
      'attempt_id': null,
    });
    for (final unsafe in <Map<String, Object?>>[
      {'status': 'cancelled'},
      {'status': 'unconfirmed'},
      {'transfer_clicked': 1},
      {'acknowledged': 2},
      {'preclick_retry_count': CaptureDatabase.handoffMaxAttempts},
      {'attempt_id': 'uncertain-attempt'},
    ]) {
      final previous = await row(log.id);
      await setRow(log.id, unsafe);
      expect(await db.hasResumableHandoffCheckpoint(), isFalse);
      await setRow(log.id, {for (final key in unsafe.keys) key: previous[key]});
    }
    await (await db.database).update(
        'conversation_control', {'state': 'human_contacting'},
        where: 'user_id=?', whereArgs: [customer]);
    expect(await db.hasResumableHandoffCheckpoint(), isFalse);
    await (await db.database).delete('conversation_control',
        where: 'user_id=?', whereArgs: [customer]);
    expect(await db.hasResumableHandoffCheckpoint(), isTrue);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.hasResumableHandoffCheckpoint(), isFalse);
  });
}
