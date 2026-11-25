import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  const customer = 'buyer';
  const target = 'agent_lI1';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v29_handoff_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<(HumanReviewTicket, ChatTransferLog)> reserved() async {
    final ticket = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'please refund',
        reason: 'order',
        requestMessageId: 'm1');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    await db.markTicketHandoffPending(ticket.id);
    return (ticket, log);
  }

  Future<Map<String, Object?>> logRow(int id) async =>
      (await (await db.database)
              .query('chat_transfer_logs', where: 'id=?', whereArgs: [id]))
          .single;
  Future<Map<String, String>> nativeAttempt(int id) async {
    await db.updateChatTransferLog(
        id: id, status: 'ready', targetAccount: target);
    await db.setTransferAcknowledgement(id, 1);
    return db.beginTransferAttempt(
        logId: id, customer: customer, targetAccount: target);
  }

  Future<void> journal(Map<String, String> attempt, String state,
      {bool clicked = false, String? owner, String? account}) async {
    await File(attempt['receiptPath']!).writeAsString(
        jsonEncode({
          'attemptId': attempt['attemptId'],
          'customer': owner ?? customer,
          'targetAccount': account ?? target,
          'state': state,
          'transferClicked': clicked,
          'timeMs': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true);
  }

  Future<void> capture(String id) => db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'order $id',
                axPath: 'test')
          ]));
  Future<void> decisionDraft() async {
    await capture('m1');
    final pending = (await db.conversations()).single;
    final draft = AiDraft.fromJson({
      'reply': 'transfer decision',
      'decision': 'human_review_required',
      'confidence': 1,
      'risk_level': 'medium',
      'human_review_required': true,
      'risk_triggers': [],
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': 'fixture'
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(pending.id, draft,
            expectedMessageId: 'm1', deliverable: false),
        1);
  }

  test('explicit pre-click Stop permits a later new request', () async {
    final (ticket, log) = await reserved();
    await db.updateChatTransferLog(
        id: log.id,
        status: 'cancelled',
        phase: 'cancelled_preclick',
        transferClicked: false);
    final later = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'please transfer now',
        reason: 'order',
        requestMessageId: 'm2');
    expect(later.id, ticket.id);
    expect(await db.reserveChatTransferLog(ticket: later), isNotNull);
    expect(await db.isHandoffPending(customer), isTrue);
  });
  test(
      'adapter carries the transfer journal and preserves native no-click proof',
      () async {
    const channel = MethodChannel('v29.transfer.journal');
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'openConversation') {
        return {'opened': true, 'customer': customer};
      }
      expect(call.method, 'transferConversation');
      expect((call.arguments as Map)['attemptId'], 'one_shot');
      expect((call.arguments as Map)['receiptPath'], '/tmp/one_shot.json');
      return {
        'error': 'transfer_budget_exceeded',
        'transferClicked': false,
        'attemptId': 'one_shot',
        'receiptState': 'not_clicked',
        'receiptPersisted': true
      };
    });
    await adapter.openConversation(customer);
    await expectLater(
        adapter.transferConversation(
            expectedCustomer: customer,
            targetAccount: target,
            attemptId: 'one_shot',
            receiptPath: '/tmp/one_shot.json'),
        throwsA(isA<PlatformException>()
            .having((e) => e.details, 'journal proof',
                containsPair('receiptState', 'not_clicked'))
            .having((e) => e.details, 'attempt lease',
                containsPair('attemptId', 'one_shot'))));
    await expectLater(
        adapter.transferConversation(
            expectedCustomer: customer,
            targetAccount: target,
            attemptId: 'missing_path'),
        throwsArgumentError);
  });
  for (final stoppedStatus in ['pending', 'ready', 'cancelled']) {
    test(
        'restart resumes known pre-click $stoppedStatus without repeating acknowledgement',
        () async {
      final (ticket, log) = await reserved();
      if (stoppedStatus != 'pending') {
        await db.updateChatTransferLog(id: log.id, status: stoppedStatus);
      }
      await db.setTransferAcknowledgement(log.id, 1);
      await db.close();
      db = CaptureDatabase(storageRoot: root);
      await db.recoverChatTransferAttempts(activeCustomers: {});
      expect((await db.duePreclickHandoffs()).single.id, ticket.id);
      expect(await db.transferAcknowledgement(log.id), 1);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
      expect((await logRow(log.id))['phase'], 'reserved');
    });
  }
  test('Dart preparation without invoking native is safely recoverable',
      () async {
    final (ticket, log) = await reserved();
    await nativeAttempt(log.id);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['phase'], 'retryable_preclick');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
  });
  test(
      'in-flight native preparation is not stolen and a live-owner uncertain call waits for not_clicked',
      () async {
    final (ticket, log) = await reserved();
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await db.recoverChatTransferAttempts(activeCustomers: {customer});
    expect((await logRow(log.id))['phase'], 'invoking_native');
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['status'], 'unconfirmed');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    await journal(attempt, 'not_clicked');
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['phase'], 'retryable_preclick');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
  });
  test('a dead process owner with a matching prepared journal can recover',
      () async {
    final (ticket, log) = await reserved();
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await (await db.database).update(
        'chat_transfer_logs', {'owner_pid': 999999},
        where: 'id=?', whereArgs: [log.id]);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['phase'], 'retryable_preclick');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
  });
  for (final phase in ['click_intent', 'clicked', 'unknown']) {
    test(
        '$phase cannot authorize another transfer, even for a new customer request',
        () async {
      final (_, log) = await reserved();
      final attempt = await nativeAttempt(log.id);
      await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
      await journal(attempt, phase, clicked: phase != 'click_intent');
      await db.recoverChatTransferAttempts(activeCustomers: {});
      expect((await logRow(log.id))['status'], 'unconfirmed');
      expect(await db.duePreclickHandoffs(), isEmpty);
      final next = await db.createHumanReviewTicket(
          userId: customer,
          customerRequest: 'transfer again',
          reason: 'order',
          requestMessageId: 'm2');
      expect(await db.reserveChatTransferLog(ticket: next), isNull);
    });
  }
  for (final invalid in [
    'missing',
    'corrupt',
    'wrong_customer',
    'wrong_target'
  ]) {
    test('$invalid invocation journal stays uncertain', () async {
      final (ticket, log) = await reserved();
      final attempt = await nativeAttempt(log.id);
      await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
      final file = File(attempt['receiptPath']!);
      if (invalid == 'missing') {
        await file.delete();
      }
      if (invalid == 'corrupt') {
        await file.writeAsString('{broken');
      }
      if (invalid == 'wrong_customer') {
        await journal(attempt, 'confirmed', clicked: true, owner: 'other');
      }
      if (invalid == 'wrong_target') {
        await journal(attempt, 'confirmed',
            clicked: true, account: 'agent_1I1');
      }
      await db.recoverChatTransferAttempts(activeCustomers: {});
      expect((await logRow(log.id))['status'], 'unconfirmed');
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    });
  }
  test(
      'matching positive journal completes the retained ticket and cannot be downgraded by a late failure',
      () async {
    final (ticket, log) = await reserved();
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await journal(attempt, 'confirmed', clicked: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    final row = await logRow(log.id);
    expect(row['phase'], 'confirmed');
    expect(row['status'], 'transferred');
    final ticketRow = (await (await db.database).query('human_review_tickets',
            where: 'id=?', whereArgs: [ticket.id]))
        .single;
    expect(ticketRow['status'], 'contacted');
    expect(ticketRow['assigned_to'], target);
    await db.updateChatTransferLog(
        id: log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        transferClicked: false,
        error: 'late callback');
    expect((await logRow(log.id))['phase'], 'confirmed');
    expect((await logRow(log.id))['status'], 'transferred');
    expect(await db.isHandoffPending(customer), isFalse);
  });
  test(
      'confirmed database fact survives a missing journal during local completion',
      () async {
    final (ticket, log) = await reserved();
    await db.updateChatTransferLog(
        id: log.id, status: 'transferred', targetAccount: target);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['status'], 'transferred');
    expect(
        (await (await db.database).query('human_review_tickets',
                where: 'id=?', whereArgs: [ticket.id]))
            .single['status'],
        'contacted');
  });
  test(
      'an unknown acknowledgement does not send another notice or begin a native attempt',
      () async {
    final (ticket, log) = await reserved();
    await db.setTransferAcknowledgement(log.id, 2);
    await db.updateChatTransferLog(
        id: log.id, status: 'cancelled', transferClicked: false);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(await db.transferAcknowledgement(log.id), 2);
    expect((await logRow(log.id))['status'], 'unconfirmed');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    expect(await db.schedulePreclickTransferRetry(log.id), isNull);
    expect(
        db.beginTransferAttempt(
            logId: log.id, customer: customer, targetAccount: target),
        throwsStateError);
  });
  test('another live process owns its in-flight reservation', () async {
    final (ticket, log) = await reserved();
    await (await db.database).update('chat_transfer_logs', {'owner_pid': 1},
        where: 'id=?', whereArgs: [log.id]);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['status'], 'pending');
    expect(await db.duePreclickHandoffs(), isEmpty);
    await db.updateChatTransferLog(
        id: log.id, status: 'failed', phase: 'retryable_preclick');
    await (await db.database).update(
        'chat_transfer_logs', {'preclick_retry_at_ms': 1},
        where: 'id=?', whereArgs: [log.id]);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
  }, skip: !Platform.isMacOS);
  test(
      'pre-click recovery retains the retry cap and later new requests start fresh',
      () async {
    final (ticket, log) = await reserved();
    // Legacy records count retries after the initial reservation. Exercise
    // all ten authorized attempts before verifying the cap.
    for (var n = 1; n < CaptureDatabase.handoffMaxAttempts; n++) {
      await db.updateChatTransferLog(
          id: log.id, status: 'failed', phase: 'retryable_preclick');
      expect(await db.schedulePreclickTransferRetry(log.id), isNotNull);
      await (await db.database).update(
          'chat_transfer_logs', {'preclick_retry_at_ms': 1},
          where: 'id=?', whereArgs: [log.id]);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    }
    await db.updateChatTransferLog(
        id: log.id, status: 'cancelled', phase: 'cancelled_preclick');
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(await db.duePreclickHandoffs(), isEmpty);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    final next = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'new request',
        reason: 'order',
        requestMessageId: 'm2');
    expect(await db.reserveChatTransferLog(ticket: next), isNotNull);
    expect((await logRow(log.id))['preclick_retry_count'], 0);
  });
  test('recovery columns migrate legacy records without erasing their state',
      () async {
    final (_, log) = await reserved();
    final sql = await db.database;
    for (final column in [
      'phase',
      'attempt_id',
      'transfer_clicked',
      'owner_pid',
      'journal_seen_ms',
      'attempt_started_at_ms'
    ]) {
      await sql.execute('ALTER TABLE chat_transfer_logs DROP COLUMN $column');
    }
    await db.ensureChatTransferRecoveryColumns(sql);
    await db.ensureChatTransferRecoveryColumns(sql);
    expect((await logRow(log.id))['status'], 'pending');
    expect((await logRow(log.id))['phase'], 'legacy');
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['phase'], 'retryable_preclick');
  });
  test('maintenance does not add retries to an already classified failure',
      () async {
    final (_, log) = await reserved();
    await db.updateChatTransferLog(
        id: log.id, status: 'failed', phase: 'retryable_preclick');
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['preclick_retry_at_ms'], 0);
    expect(await db.duePreclickHandoffs(), isEmpty);
  });
  test('restart after confirmed fact atomically finishes old draft and cursor',
      () async {
    await decisionDraft();
    final (_, log) = await reserved();
    await nativeAttempt(log.id);
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        phase: 'confirmed',
        transferClicked: true);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(
        (await (await db.database).query('human_review_tickets'))
            .single['status'],
        'contacted');
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.answeredMessageId(customer), 'm1');
    expect((await (await db.history).read(customer))!['messages'], isNotEmpty);
  });
  test('confirmed handoff preserves newer pending work, draft and cursor',
      () async {
    await decisionDraft();
    final (_, log) = await reserved();
    await nativeAttempt(log.id);
    await capture('m2');
    final sql = await db.database;
    await sql.update(
        'generated_drafts',
        {
          'batch_end_message_id': 'm2',
          'task_id': 'new_task',
          'created_at_ms': DateTime.now().millisecondsSinceEpoch + 1000,
        },
        where: 'user_id=?',
        whereArgs: [customer]);
    await sql
        .insert('answered_cursors', {'user_id': customer, 'message_id': 'm2'});
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        phase: 'confirmed',
        transferClicked: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(await db.hasUndeliveredDraft(customer), isTrue);
    expect(await db.pendingMessageId(customer), 'm2');
    expect(await db.answeredMessageId(customer), 'm2');
  });
  test('legacy confirmed transfer also finishes its old decision safely',
      () async {
    await decisionDraft();
    final (_, log) = await reserved();
    await (await db.database).update(
        'chat_transfer_logs',
        {
          'status': 'transferred',
          'phase': 'legacy',
          'target_account': target,
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch
        },
        where: 'id=?',
        whereArgs: [log.id]);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.answeredMessageId(customer), 'm1');
  });
  test('a receipt without explicit no-click evidence remains uncertain',
      () async {
    final (ticket, log) = await reserved();
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await (await db.database).update(
        'chat_transfer_logs', {'owner_pid': 999999},
        where: 'id=?', whereArgs: [log.id]);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'targetAccount': target,
      'state': 'prepared',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['status'], 'unconfirmed');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
  });
  test('completing an old decision cannot move a later answered cursor back',
      () async {
    await decisionDraft();
    final (_, log) = await reserved();
    await nativeAttempt(log.id);
    await capture('m2');
    await (await db.database)
        .insert('answered_cursors', {'user_id': customer, 'message_id': 'm2'});
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        phase: 'confirmed',
        transferClicked: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.answeredMessageId(customer), 'm2');
    expect(await db.pendingMessageId(customer), 'm2');
  });
  test('completion of an old handoff leaves a newer open ticket untouched',
      () async {
    await decisionDraft();
    final (ticket, log) = await reserved();
    await nativeAttempt(log.id);
    await db.updateChatTransferLog(
        id: log.id,
        status: 'transferred',
        phase: 'confirmed',
        transferClicked: true);
    final sql = await db.database;
    await sql.update('human_review_tickets', {'status': 'contacted'},
        where: 'id=?', whereArgs: [ticket.id]);
    final newer = await db.createHumanReviewTicket(
        userId: customer,
        customerRequest: 'new order',
        reason: 'order',
        requestMessageId: 'm2');
    expect(newer.id, isNot(ticket.id));
    await db.markTicketContacted(ticket.id, assignedTo: target);
    expect(await db.hasUndeliveredDraft(customer), isTrue);
    expect((await db.humanReviewTickets()).single.id, newer.id);
    expect(
        (await sql.query('conversation_control',
                where: 'user_id=?', whereArgs: [customer]))
            .single['state'],
        'ai_active');
  });
  test('confirmed handoff closes old response duty even without a draft',
      () async {
    final (_, log) = await reserved();
    final old = DateTime.now().subtract(const Duration(seconds: 10));
    await db.observePlatformResponse(customer,
        red: true, observedAt: old, startedAt: old);
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await journal(attempt, 'confirmed', clicked: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await db.platformResponseCycle(customer))!['state'], 'cleared');
    expect(
        (await (await db.database).query('sla_fallbacks',
                where: 'user_id=?', whereArgs: [customer]))
            .single['state'],
        'completed');
  });
  test('malformed receipt fields cannot break maintenance or grant retry',
      () async {
    final (_, log) = await reserved();
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'targetAccount': target,
      'state': 'not_clicked',
      'transferClicked': false,
      'timeMs': 'invalid',
    }));
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await logRow(log.id))['status'], 'unconfirmed');
    expect(await db.duePreclickHandoffs(), isEmpty);
  });
  test('handoff confirmation cannot close a cycle newer than its attempt',
      () async {
    final (_, log) = await reserved();
    final old = DateTime.now().subtract(const Duration(seconds: 10));
    await db.observePlatformResponse(customer,
        red: true, observedAt: old, startedAt: old);
    final attempt = await nativeAttempt(log.id);
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    final newer = DateTime.now().add(const Duration(seconds: 2));
    await db.observePlatformResponse(customer,
        red: false, observedAt: newer.subtract(const Duration(seconds: 1)));
    await db.observePlatformResponse(customer,
        red: true, observedAt: newer, startedAt: newer, clockReset: true);
    final current = (await db.platformResponseCycle(customer))!['cycle_id'];
    await journal(attempt, 'confirmed', clicked: true);
    await db.recoverChatTransferAttempts(activeCustomers: {});
    expect((await db.platformResponseCycle(customer))!['cycle_id'], current);
    expect((await db.platformResponseCycle(customer))!['state'], 'waiting');
    expect(
        (await (await db.database).query('sla_fallbacks',
                where: 'user_id=?', whereArgs: [customer]))
            .single['state'],
        'pending');
  });
}
