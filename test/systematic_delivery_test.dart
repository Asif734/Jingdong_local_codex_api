import 'helpers/run_permissions.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/capture/jd_ui_scheduler.dart';

const answer = AiDraft(
    reply: 'Answer for A only',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'test',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"Answer for A only","decision":"draft","confidence":1,"risk_level":"low","model":"test"}');
const transfer = AiDraft(
    reply: 'Transfer please',
    decision: 'human_review',
    confidence: 1,
    riskLevel: 'high',
    model: 'test',
    usedRecordIds: [],
    actions: ['transfer_to_human'],
    attachments: [],
    rawJson:
        '{"reply":"Transfer please","decision":"human_review","confidence":1,"risk_level":"high","model":"test","actions":["transfer_to_human"]}');
void main() {
  late Directory root;
  late CaptureDatabase db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_system_fix_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String user, String id, {DateTime? at}) async {
    final clock = at ?? DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
        stableKey: 'customer:$user',
        customerName: user,
        customerExternalId: user,
        capturedAt: clock,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'Question $id',
              sentAt: clock,
              axPath: 'test')
        ]));
  }

  Future<void> ready({String id = 'q1'}) async {
    await incoming('A', id);
    final q = (await db.conversations()).single;
    await db.saveDraft(q.id, answer, expectedMessageId: id);
  }

  Future<void> startRun(WidgetTester tester) async {
    final previous = db.currentAutomationSessionId;
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (db.currentAutomationSessionId != previous &&
          find.text('Stop automation').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(db.currentAutomationSessionId, isNot(previous));
    expect(find.text('Stop automation'), findsOneWidget);
  }

  Future<void> manualA() async {
    await db.saveCapture(CapturedConversation(
        stableKey: 'customer:A',
        customerName: 'A',
        customerExternalId: 'A',
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: 'manual',
              direction: 'outgoing',
              body: 'Manual answer',
              sentAt: DateTime.now(),
              deliveryConfirmed: true,
              axPath: 'test')
        ]));
  }

  test('reused queue row cannot attach an old generation to another customer',
      () async {
    await db.beginAutomationSession(startedAt: DateTime.now());
    await incoming('A', 'qA');
    final old = (await db.conversations()).single;
    final token = await db.beginGeneration(
        customer: 'A', pendingId: old.id, batchEndMessageId: 'qA');
    await manualA();
    expect(await db.hasPendingUnanswered('A'), isTrue,
        reason: 'An OCR outgoing candidate cannot complete the generation.');
    expect(
        await db.confirmManualReplyCoverage('A',
            messageIds: ['qA'], sentAt: DateTime.now(), reply: 'Manual answer'),
        isTrue);
    await incoming('B', 'qB');
    final fresh = (await db.conversations()).single;
    expect(fresh.id, old.id);
    expect(
        await db.saveDraft(old.id, answer,
            expectedUserId: 'A',
            expectedMessageId: 'qA',
            generationToken: token),
        0);
    expect(await db.saveDraft(old.id, answer, expectedMessageId: 'qA'), 0,
        reason:
            'Legacy callers must also prove the frozen message belongs to the row customer.');
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.pendingMessageId('B'), 'qB');
  });
  test('stopped or superseded generation lease cannot overwrite a later turn',
      () async {
    await incoming('A', 'q1');
    final old = (await db.conversations()).single;
    final token = await db.beginGeneration(
        customer: 'A', pendingId: old.id, batchEndMessageId: 'q1');
    await db.cancelGenerationLeases();
    expect(
        await db.saveDraft(old.id, answer,
            expectedUserId: 'A',
            expectedMessageId: 'q1',
            generationToken: token),
        0);
    final replacement = await db.beginGeneration(
        customer: 'A', pendingId: old.id, batchEndMessageId: 'q1');
    expect(
        await db.saveDraft(old.id, answer,
            expectedUserId: 'A',
            expectedMessageId: 'q1',
            generationToken: replacement),
        1);
  });
  test('legacy interrupted SLA has explicit reconciliation work after restart',
      () async {
    await incoming('A', 'q1');
    final job = (await db.slaFallbackJob('A'))!;
    await db.reserveSlaFallback(userId: 'A', messageId: 'q1', dueAt: job.dueAt);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect((await db.reconciliationWork()).single['state'], 'reconciling');
  });
  test('new SLA attempt not started natively is safely rearmed after restart',
      () async {
    await incoming('A', 'q1');
    final job = (await db.slaFallbackJob('A'))!;
    await db.reserveSlaFallback(userId: 'A', messageId: 'q1', dueAt: job.dueAt);
    await db.beginSlaAttempt(job, '请稍等。');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.recoverDeliveryReceipts();
    expect((await db.slaFallbackJob('A'))?.messageId, 'q1');
  });
  test(
      'next frozen batch has its own SLA identity and does not inherit old holding receipt',
      () async {
    await incoming('A', 'q1');
    final pending = (await db.conversations()).single;
    final old = (await db.slaFallbackJob('A'))!;
    await db.reserveSlaFallback(userId: 'A', messageId: 'q1', dueAt: old.dueAt);
    await db.markSlaFallbackSent(userId: 'A', messageId: 'q1', reply: '请稍等。');
    await db.saveDraft(pending.id, answer, expectedMessageId: 'q1');
    await incoming('A', 'q2');
    await db.markReplySent(userId: 'A', reply: answer.reply);
    final next = (await db.slaFallbackJob('A'))!;
    expect(next.batchStartMessageId, 'q2');
    expect(
        await db.reserveSlaFallback(
            userId: 'A', messageId: 'q2', dueAt: next.dueAt),
        isTrue);
  });
  test(
      'interrupted formal send preserves uncertainty and receipt only answers its frozen batch',
      () async {
    await ready();
    await incoming('A', 'q2');
    await (await db.database).update(
        'generated_drafts', {'delivery_state': 'sending', 'last_error': null});
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect(await db.nextReadyDelivery(), isNull);
    await db.saveCapture(CapturedConversation(
        stableKey: 'customer:A',
        customerName: 'A',
        customerExternalId: 'A',
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: 'receipt',
              direction: 'outgoing',
              body: answer.reply,
              sentAt: DateTime.now(),
              deliveryConfirmed: true,
              axPath: 'test')
        ]));
    expect(await db.answeredMessageId('A'), 'q1');
    expect(await db.pendingMessageId('A'), 'q2');
    expect(await db.hasPendingUnanswered('A'), isTrue);
  });
  test('bad draft is quarantined and does not block a healthy customer',
      () async {
    await ready();
    await incoming('B', 'qB');
    final b = (await db.conversations()).single;
    await db.saveDraft(b.id, answer);
    await (await db.database).update('generated_drafts', {'raw_json': '{bad'},
        where: 'user_id=?', whereArgs: ['A']);
    expect((await db.nextReadyDelivery())?.userId, 'B');
    final bad = (await (await db.database)
            .query('generated_drafts', where: 'user_id=?', whereArgs: ['A']))
        .single;
    expect(bad['delivery_state'], 'quarantined');
    expect(bad['raw_json'], '{bad');
  });
  test(
      'unknown sender clock never makes a later turn an eternal historical variant',
      () async {
    final old = DateTime.now().subtract(const Duration(days: 1));
    CapturedConversation frame(DateTime at, List<CapturedMessage> m) =>
        CapturedConversation(
            stableKey: 'customer:A',
            customerName: 'A',
            customerExternalId: 'A',
            capturedAt: at,
            messages: m);
    await db.saveCapture(frame(old, const [
      CapturedMessage(
          stableId: 'old',
          direction: 'incoming',
          body: 'help me',
          axPath: 'ocr')
    ]));
    await db.saveCapture(frame(old.add(const Duration(seconds: 5)), [
      CapturedMessage(
          stableId: 'old-answer',
          direction: 'outgoing',
          body: 'Old answer',
          sentAt: old.add(const Duration(seconds: 5)),
          deliveryConfirmed: true,
          axPath: 'test')
    ]));
    expect(
        await db.saveCapture(frame(DateTime.now(), const [
          CapturedMessage(
              stableId: 'new',
              direction: 'incoming',
              body: 'help me?',
              axPath: 'ocr')
        ])),
        1);
    expect(await db.pendingMessageId('A'), 'new');
  });
  test('bounded transfer phases yield to an urgent deadline at safe boundaries',
      () async {
    final scheduler = JdUiScheduler();
    final gate = Completer<void>();
    final order = <String>[];
    final phase1 = scheduler.run(() async {
      order.add('inspect');
      await gate.future;
      order.add('modal-closed');
    });
    await Future<void>.delayed(Duration.zero);
    final urgent = scheduler.run(() async {
      order.add('urgent-send');
    }, priority: JdUiPriority.responseDeadline, deadline: DateTime.now());
    final phase2 = scheduler.run(() async {
      order.add('reopen-revalidate-transfer');
    });
    gate.complete();
    await Future.wait([phase1, phase2, urgent]);
    expect(order, [
      'inspect',
      'modal-closed',
      'urgent-send',
      'reopen-revalidate-transfer'
    ]);
  });
  test(
      'native submitted journal recovers a crashed confirmation without resending',
      () async {
    await ready();
    await incoming('A', 'q2');
    final delivery = (await db.nextReadyDelivery())!;
    final options = await db.beginDeliveryAttempt(
        userId: 'A', reply: answer.reply, taskId: delivery.taskId);
    await File(options['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': options['attemptId'],
      'customer': 'A',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.recoverDeliveryReceipts();
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.answeredMessageId('A'), 'q1');
    expect(await db.pendingMessageId('A'), 'q2');
  });
  test(
      'late rejection restores uncertainty and cannot consume newer unanswered content',
      () async {
    await ready();
    final task = (await db.nextReadyDelivery())!;
    final options = await db.beginDeliveryAttempt(
        userId: 'A', reply: answer.reply, taskId: task.taskId);
    await db.markReplySent(
        userId: 'A', reply: answer.reply, expectedTaskId: task.taskId);
    await incoming('A', 'q2');
    await File(options['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': options['attemptId'],
      'customer': 'A',
      'state': 'late_rejection_uncertain',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.hasUndeliveredDraft('A'), isTrue);
    expect(await db.nextReadyDelivery(), isNull,
        reason:
            'An unattributed late error cannot authorize duplicate typing.');
    expect(await db.pendingMessageId('A'), 'q2');
    expect(await db.answeredMessageId('A'), isNull);
  });
  test(
      'concurrent completion only records one local reply and preserves frozen identity',
      () async {
    await ready();
    final task = (await db.nextReadyDelivery())!;
    await db.beginDeliveryAttempt(
        userId: 'A', reply: answer.reply, taskId: task.taskId);
    final results = await Future.wait([
      db.markReplySent(
          userId: 'A', reply: answer.reply, expectedTaskId: task.taskId),
      db.markReplySent(
          userId: 'A', reply: answer.reply, expectedTaskId: task.taskId)
    ]);
    expect(results.where((r) => r), hasLength(1));
    final history = await (await db.history).read('A');
    expect(
        (history!['messages'] as List)
            .where((m) => m['source'] == 'generated_reply'),
        hasLength(1));
  });
  test(
      'task CAS guards completion and failure even for equal text and millisecond',
      () async {
    await ready();
    final old = (await db.nextReadyDelivery())!;
    await (await db.database).update(
        'generated_drafts', {'task_id': 'replacement'},
        where: 'user_id=?', whereArgs: ['A']);
    expect(
        await db.markReplySent(
            userId: 'A', reply: answer.reply, expectedTaskId: old.taskId),
        isFalse);
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'A', error: 'send_unconfirmed', taskId: old.taskId);
    expect((await db.nextReadyDelivery())?.taskId, 'replacement');
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: 'A', reply: answer.reply, taskId: old.taskId),
        isFalse);
  });
  for (final phase in ['prepared', 'clicked']) {
    test(
        'native $phase journal distinguishes no click from an uncertain click on restart',
        () async {
      await ready();
      final old = (await db.nextReadyDelivery())!;
      final attempt = await db.beginDeliveryAttempt(
          userId: 'A', reply: answer.reply, taskId: old.taskId);
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'A',
        'state': phase,
        'timeMs': DateTime.now().millisecondsSinceEpoch
      }));
      await db.close();
      db = CaptureDatabase(storageRoot: root);
      await db.recoverDeliveryReceipts();
      if (phase == 'prepared') {
        expect((await db.nextReadyDelivery())?.userId, 'A');
      } else {
        expect(await db.nextReadyDelivery(), isNull);
        expect((await db.reconciliationWork()).single['state'],
            'delivery_unknown');
      }
    });
  }
  test(
      'background rejected body restores submitted work without typing or answering the next turn',
      () async {
    await ready();
    final draft = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'A', reply: answer.reply, taskId: draft.taskId);
    await db.markReplySent(
        userId: 'A', reply: answer.reply, expectedTaskId: draft.taskId);
    await incoming('A', 'q2',
        at: DateTime.now().add(const Duration(seconds: 1)));
    final at = DateTime.now().add(const Duration(seconds: 2));
    expect(
        await db.noteObservedRejection(
            customer: 'B',
            body: answer.reply,
            fingerprint: 'wrong',
            capturedAt: at),
        isFalse);
    expect(
        await db.noteObservedRejection(
            customer: 'A',
            body: answer.reply,
            fingerprint: 'failure',
            capturedAt: at),
        isTrue);
    await db.recoverDeliveryReceipts();
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.isBatchUnanswered('A', 'q2'), isTrue);
    expect((await db.reconciliationWork()).single['state'], 'delivery_unknown');
    final ledger = await (await db.database).query('delivery_attempts',
        where: 'attempt_id=?', whereArgs: [attempt['attemptId']]);
    expect(ledger.single['state'], 'unknown');
  });
  test('receipt reconciliation rotates beyond 100 unresolved records',
      () async {
    await ready();
    final draft = (await db.nextReadyDelivery())!;
    final real = await db.beginDeliveryAttempt(
        userId: 'A', reply: answer.reply, taskId: draft.taskId);
    final sql = await db.database;
    final row = (await sql.query('delivery_attempts')).single;
    for (var i = 0; i < 105; i++) {
      await sql.insert('delivery_attempts', {
        ...row,
        'attempt_id': 'old-$i',
        'user_id': 'old-$i',
        'state': 'submitted',
        'created_at_ms': (row['created_at_ms'] as int) + 1000 + i
      });
    }
    await File(real['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': real['attemptId'],
      'customer': 'A',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    expect(
        await db.isGeneratedDraftReadyForSend(userId: 'A', reply: answer.reply),
        isFalse);
    await db.recoverDeliveryReceipts();
    expect(
        (await sql
            .query('generated_drafts', where: 'user_id=?', whereArgs: ['A'])),
        isEmpty);
    expect(await db.isBatchUnanswered('A', 'q1'), isFalse);
  });
  testWidgets(
      'Start archives prior-run paused work without opening or resending it',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await ready();
      await db.suspendUnavailableConversation('A', 'send_platform_rejected');
    });
    var opens = 0, sends = 0, generations = 0;
    final channel = MethodChannel('jd.system.archived.pause');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [
            {
              'customer': 'A',
              'identitySource': 'active_ax',
              'unread': false,
              'redClockPresent': false,
              'unreadEvidence': 0
            }
          ];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'openConversation':
          opens++;
          return {'opened': true, 'customer': 'A'};
        case 'sendDraftOnce':
          sends++;
          return {'sent': true};
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            generateDraftOverride: (_, __, ___, ____) async {
              generations++;
              return answer;
            })));
    await grantRunPermissions(tester);
    await startRun(tester);
    // Exercise both the regular AX poll and maintenance after the new boundary.
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(opens, 0);
    expect(sends, 0);
    expect(generations, 0);
    await tester.runAsync(() async {
      final sql = await db.database;
      expect(await sql.query('pending_customers'), isEmpty);
      expect(await sql.query('generated_drafts'), isEmpty);
      expect(await sql.query('unavailable_conversations'), isEmpty);
      final archived = await sql.query('automation_work_archive');
      expect(archived.map((row) => row['table_name']),
          containsAll(['generated_drafts', 'unavailable_conversations']));
      expect(
          archived
              .where((row) => row['table_name'] == 'generated_drafts')
              .single['row_json'],
          contains(answer.reply));
      expect(await db.answeredMessageId('A'), isNull);
      expect((await (await db.history).read('A'))!['messages'], isNotEmpty);
    });
    await tester.tap(find.text('Stop automation'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
  testWidgets(
      'current-run paused work probes and sends without relying on a red badge',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opens = 0, sends = 0;
    final channel = MethodChannel('jd.system.fixed.no-red');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [
            {
              'customer': 'A',
              'identitySource': 'active_ax',
              'unread': false,
              'unreadEvidence': 0
            }
          ];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'openConversation':
          opens++;
          return {'opened': true, 'customer': 'A'};
        case 'checkDeliveryReadiness':
          return {'ready': true};
        case 'sendDraftOnce':
          sends++;
          return {'sent': true};
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            draftSchedulerOverride: (_) {})));
    await grantRunPermissions(tester);
    await startRun(tester);
    await tester.runAsync(() async {
      await ready();
      await db.suspendUnavailableConversation('A', 'send_platform_rejected');
      await (await db.database)
          .update('unavailable_conversations', {'next_probe_at_ms': 0});
    });
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (sends > 0) break;
    }
    expect(opens, greaterThan(0));
    expect(sends, 1);
    await tester.tap(find.text('Stop automation'));
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
  testWidgets('Stop cancels an old generation before it can save or transfer',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gate = Completer<AiDraft>();
    var generations = 0, mutations = 0;
    final channel = MethodChannel('jd.system.stop');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'sendDraftOnce':
        case 'listActiveTransferAccounts':
        case 'transferConversation':
          mutations++;
          return {'sent': true};
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            generateDraftOverride: (c, d, b, cancel) async {
              generations++;
              return gate.future;
            })));
    await grantRunPermissions(tester);
    // Keep asynchronous file/SQLite work in the real event loop; pump alone
    // cannot advance the serialized I/O chain started in FakeAsync.
    await startRun(tester);
    await tester.runAsync(() => incoming('A', 'q1'));
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (generations > 0) break;
    }
    expect(generations, 1);
    await tester.tap(find.text('Stop automation'));
    await tester.pump();
    gate.complete(transfer);
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(mutations, 0);
    await tester.runAsync(() async {
      expect(await db.hasUndeliveredDraft('A'), isFalse);
      expect(await db.pendingMessageId('A'), 'q1');
    });
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
  testWidgets(
      'rapid Stop/Start cannot give an old open operation new-run send permission',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gate = Completer<Map<String, Object?>>();
    var opens = 0, sends = 0, currentEpoch = 0;
    final sentEpochs = <int>[];
    final channel = MethodChannel('jd.system.restart-epoch');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args =
          call.arguments is Map ? call.arguments as Map : <Object?, Object?>{};
      switch (call.method) {
        case 'setAutomationEpoch':
          currentEpoch = args['epoch'] as int;
          return {};
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'openConversation':
          opens++;
          if (opens == 1) return gate.future;
          return {'opened': true, 'customer': 'A'};
        case 'sendDraftOnce':
          sends++;
          sentEpochs.add(args['automationEpoch'] as int);
          return {'sent': true};
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            draftSchedulerOverride: (_) {})));
    await grantRunPermissions(tester);
    await startRun(tester);
    await tester.runAsync(() => ready());
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (opens > 0) break;
    }
    expect(opens, 1);
    await tester.tap(find.text('Stop automation'));
    await tester.pump();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await grantRunPermissions(tester);
    await startRun(tester);
    await tester.runAsync(() => ready(id: 'q2'));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    gate.complete({'opened': true, 'customer': 'A'});
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (sends > 0) break;
    }
    expect(opens, greaterThanOrEqualTo(2));
    expect(sends, 1);
    expect(sentEpochs, [currentEpoch]);
    await tester.tap(find.text('Stop automation'));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
