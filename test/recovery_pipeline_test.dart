import 'helpers/run_permissions.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const reply = AiDraft(
    reply: 'Please tell me the exact printer model.',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'audit',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"Please tell me the exact printer model.","decision":"draft","confidence":1,"risk_level":"low","model":"audit"}');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v17_audit_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String user, String id, DateTime at) => db
      .saveCapture(CapturedConversation(
          stableKey: 'customer:$user',
          customerName: user,
          customerExternalId: user,
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'Question $id',
                sentAt: at,
                axPath: 'audit')
          ]))
      .then((_) {});
  Future<void> ready() async {
    await incoming('A', 'q1', DateTime.now().toUtc());
    final row = (await db.conversations()).single;
    await db.saveDraft(row.id, reply,
        expectedUserId: 'A', expectedMessageId: 'q1');
  }

  test(
      'unknown formal journal enters durable reconciliation, including a previously consumed receipt',
      () async {
    await ready();
    final item = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'A', reply: reply.reply, taskId: item.taskId);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'A',
      'state': 'unknown',
      'error': 'customer_not_receiving',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await (await db.database).update('delivery_attempts', {
      'receipt_seen_ms':
          DateTime.now().add(const Duration(seconds: 1)).millisecondsSinceEpoch
    });
    await db.recoverDeliveryReceipts();
    final rows = await (await db.database).query('generated_drafts');
    expect(rows.single['delivery_state'], 'delivery_unknown');
    expect(await db.nextReadyDelivery(), isNull);
    expect((await db.reconciliationWork()).single['state'], 'delivery_unknown');
    final ledger =
        (await (await db.database).query('delivery_attempts')).single;
    expect(ledger['receipt_seen_ms'], greaterThan(0));
  });
  test(
      'one damaged history is isolated and recovers without blocking another customer',
      () async {
    await incoming('A', 'qA', DateTime.now());
    await incoming('B', 'qB', DateTime.now());
    final file = File('${root.path}/A.json');
    final original = await file.readAsString();
    await file.writeAsString('{broken');
    expect((await db.conversations()).map((r) => r.userId), ['B']);
    expect((await db.historyFaults()).single['user_id'], 'A');
    expect(await db.conversation('B'), isNotNull);
    expect(await file.readAsString(), '{broken');
    await file.writeAsString(original);
    expect((await db.conversations()).map((r) => r.userId),
        containsAll(['A', 'B']));
    expect(await db.historyFaults(), isEmpty);
    expect(
        (await (await db.database).query('pending_customers'))
            .map((r) => r['user_id']),
        containsAll(['A', 'B']));
  });
  for (final (sameBody, near) in [(true, false), (false, true), (true, true)]) {
    test(
        '${sameBody ? (near ? 'nearby identical after a new question' : 'later identical') : 'nearby different'} manual OCR is retained without completing the new turn',
        () async {
      await ready();
      await db.markReplySent(userId: 'A', reply: reply.reply);
      final history = (await (await db.history).read('A'))!;
      final old = (history['messages'] as List)
          .cast<Map>()
          .singleWhere((r) => r['direction'] == 'outgoing');
      final at = DateTime.parse(old['sent_at'] as String);
      final incomingAt = at.add(Duration(seconds: near ? 1 : 60));
      await incoming('A', 'q2', incomingAt);
      await db.saveCapture(CapturedConversation(
          stableKey: 'customer:A',
          customerName: 'A',
          customerExternalId: 'A',
          capturedAt: at.add(Duration(seconds: near ? 3 : 121)),
          messages: [
            CapturedMessage(
                stableId: 'manual-actual',
                direction: 'outgoing',
                body: sameBody
                    ? reply.reply
                    : 'This is a completely different manual answer.',
                sentAt: at.add(Duration(seconds: near ? 2 : 120)),
                deliveryConfirmed: true,
                axPath: 'audit')
          ]));
      final doc = (await (await db.history).read('A'))!;
      expect(
          (doc['messages'] as List)
              .cast<Map>()
              .any((r) => r['id'] == 'manual-actual'),
          isTrue);
      expect(await db.hasPendingUnanswered('A'), isTrue,
          reason: 'Outgoing OCR is context, not positive delivery coverage.');
    });
  }
  test(
      'proven progress makes page four available through the real scheduler selector',
      () async {
    final store = CaptureEvidenceStore(db);
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
    await store.requestBackfill('A', cutoff);
    for (var i = 0; i < 3; i++) {
      await store.backfillAttempt('A', cutoff: cutoff);
    }
    expect(
        await store.reportBackfillProgress(
            'A', cutoff, cutoff.add(const Duration(minutes: 1))),
        isTrue);
    final row = (await (await db.database).query('capture_backfill')).single;
    expect(row['pages'], 3);
    expect(row['page_limit'], 6);
    expect(row['state'], 'pending');
    expect((await store.pendingBackfills()).single['pages'], 3);
  });
  test(
      'a generic native failure cannot turn an unknown journal into permission to retry',
      () async {
    await ready();
    final d = (await db.nextReadyDelivery())!;
    final a = await db.beginDeliveryAttempt(
        userId: 'A', reply: reply.reply, taskId: d.taskId);
    await File(a['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': a['attemptId'],
      'customer': 'A',
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'A', taskId: d.taskId, error: 'send_not_committed');
    expect(await db.nextReadyDelivery(), isNull);
    expect(
        (await (await db.database).query('generated_drafts'))
            .single['delivery_state'],
        'delivery_unknown');
    expect(
        (await (await db.database).query('delivery_attempts')).single['state'],
        'unknown');
  });
  test(
      'a stale unknown receipt cannot invalidate the replacement task or positive completion',
      () async {
    await ready();
    final d = (await db.nextReadyDelivery())!;
    final a = await db.beginDeliveryAttempt(
        userId: 'A', reply: reply.reply, taskId: d.taskId);
    await db.markReplySent(
        userId: 'A', reply: reply.reply, expectedTaskId: d.taskId);
    await incoming('A', 'q2', DateTime.now().add(const Duration(seconds: 2)));
    final row = (await db.conversations()).single;
    await db.saveDraft(row.id, reply, expectedMessageId: 'q2');
    final replacement = (await db.nextReadyDelivery())!.taskId;
    await File(a['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': a['attemptId'],
      'customer': 'A',
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    expect((await db.nextReadyDelivery())!.taskId, replacement);
    expect(await db.answeredMessageId('A'), 'q1');
    expect(
        (await (await db.database).query('delivery_attempts')).single['state'],
        'submitted');
  });
  test(
      'a repaired history releases a blocked ready draft even without a pending generation row',
      () async {
    await ready();
    final file = File('${root.path}/A.json');
    final original = await file.readAsString();
    await file.writeAsString('{broken');
    expect(await db.validateCustomerHistory('A'), isFalse);
    expect(await db.nextReadyDelivery(), isNull);
    await incoming('B', 'b1', DateTime.now());
    final b = (await db.conversations()).single;
    await db.saveDraft(b.id, reply, expectedMessageId: 'b1');
    expect((await db.nextReadyDelivery())?.userId, 'B');
    await file.writeAsString(original);
    await (await db.database)
        .update('customer_storage_faults', {'last_seen_ms': 0});
    await db.recheckHistoryFaults();
    expect(await db.historyFaults(), isEmpty);
    expect((await db.nextReadyDelivery())?.userId, 'A');
  });
  test(
      'legacy drafts without a task ID still enter backoff after an open failure',
      () async {
    await ready();
    await (await db.database).update('generated_drafts', {'task_id': null});
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'A', error: 'conversation_open_timeout');
    expect(await db.nextReadyDelivery(), isNull);
    expect(
        (await (await db.database).query('generated_drafts'))
            .single['delivery_state'],
        'retry');
  });
  test(
      'a post-click reception error retains uncertainty even when the final journal is not written',
      () async {
    await ready();
    final d = (await db.nextReadyDelivery())!;
    final a = await db.beginDeliveryAttempt(
        userId: 'A', reply: reply.reply, taskId: d.taskId);
    await File(a['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': a['attemptId'],
      'customer': 'A',
      'state': 'clicked',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'A', taskId: d.taskId, error: 'customer_not_receiving');
    expect(await db.nextReadyDelivery(), isNull);
    expect((await db.reconciliationWork()).single['state'], 'delivery_unknown');
  });
  testWidgets(
      'restart archives the retained draft without probing anonymous old rows',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(ready);
    var opens = 0, rowOpens = 0, sends = 0;
    var active = false;
    const channel = MethodChannel('jd.v17.audit.anonymous.restart');
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
              'customer': '',
              'identitySource': 'row_anchor',
              'rowKey': 'fresh-row',
              'rowToken': 'fresh-token',
              'unread': false,
              'unreadEvidence': 0,
              'evidenceAvailable': true
            }
          ];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'openConversation':
          opens++;
          return active
              ? {'opened': true, 'customer': 'A'}
              : {'error': 'conversation_not_found'};
        case 'checkDeliveryReadiness':
          return {'ready': true};
        case 'openConversationRow':
          rowOpens++;
          active = true;
          return {
            'opened': true,
            'customer': 'A',
            'rowKey': 'fresh-row',
            'identityProof': 'selected_row_and_stable_ax_header'
          };
        case 'sendDraftOnce':
          sends++;
          return {'sent': true, 'customer': 'A'};
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            draftSchedulerOverride: (_) {})));
    await grantRunPermissions(tester);
    await tester.tap(find.text('Start automation'));
    for (var i = 0; i < 160; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(opens, 0);
    expect(rowOpens, 0);
    expect(sends, 0);
    await tester.runAsync(() async {
      expect(await db.isConversationUnavailable('A'), isFalse);
      expect(await (await db.database).query('generated_drafts'), isEmpty);
      expect(await db.answeredMessageId('A'), isNull);
      expect(
          await (await db.database).query('automation_work_archive',
              where: 'table_name=?', whereArgs: ['generated_drafts']),
          isNotEmpty);
    });
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
