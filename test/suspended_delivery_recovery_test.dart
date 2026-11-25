import 'helpers/run_permissions.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

const draft = AiDraft(
    reply: 'Preserved answer',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'test',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"Preserved answer","decision":"draft","confidence":1,"risk_level":"low","model":"test"}');
Future<void> seed(CaptureDatabase db, {DateTime? capturedAt}) async {
  final at = capturedAt ?? DateTime.now().subtract(const Duration(seconds: 40));
  await db.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: at,
      messages: [
        CapturedMessage(
            stableId: 'question',
            direction: 'incoming',
            body: 'Self-test is normal',
            sentAt: at,
            axPath: 'test')
      ]));
  final pending = (await db.conversations()).single;
  await db.saveDraft(pending.id, draft, expectedMessageId: 'question');
  await db.suspendUnavailableConversation(
      'buyer', 'conversation_verification_failed');
}

void main() {
  test(
      'suspension lease survives restart, is atomic and preserves original deadline',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_lease_');
    var db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await seed(db);
    final sql = await db.database;
    final oldDue = (await sql.query('sla_fallbacks')).single['due_at_ms'];
    final later = DateTime.now().add(const Duration(seconds: 4));
    final claims = await Future.wait([
      db.claimUnavailableProbe('buyer', now: later),
      db.claimUnavailableProbe('buyer', now: later)
    ]);
    expect(claims.whereType<Map>(), hasLength(1));
    expect(claims.whereType<Map>().single['original_deadline_ms'], oldDue);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect(await db.claimUnavailableProbe('buyer', now: later), isNull);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(await db.resumeVisibleConversations(['buyer']), isEmpty);
    expect(
        await db
            .resumeVisibleConversations(['buyer'], verifiedActive: ['buyer']),
        ['buyer']);
    expect((await db.nextReadyDelivery())?.draft.reply, draft.reply);
    expect((await db.slaFallbackJob('buyer'))?.dueAt.millisecondsSinceEpoch,
        oldDue);
  });
  test('repeated failures keep probe attempts and bounded future probing',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_lease_repeat_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await seed(db);
    var at = DateTime.now().add(const Duration(seconds: 4));
    for (var i = 1; i <= 6; i++) {
      final claim = await db.claimUnavailableProbe('buyer', now: at);
      expect(claim?['probe_attempts'], i);
      final next = claim!['next_probe_at_ms'] as int;
      expect(next - at.millisecondsSinceEpoch, lessThanOrEqualTo(15000));
      await db.suspendUnavailableConversation(
          'buyer', 'conversation_verification_failed');
      at = DateTime.fromMillisecondsSinceEpoch(next + 1);
    }
  });
  test(
      'current ownership block requires positive readiness, not sidebar sighting',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_owner_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await seed(db);
    await db.suspendUnavailableConversation('buyer', 'customer_not_receiving');
    expect(
        await db
            .resumeVisibleConversations(['buyer'], verifiedActive: ['buyer']),
        isEmpty);
    expect(
        await db.resumeVisibleConversations(['buyer'],
            verifiedActive: ['buyer'], deliveryReady: ['buyer']),
        ['buyer']);
  });
  test(
      'draft-owned rejected bubble remains excluded from independent retry after restart',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_rejection_');
    var db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.ownFailedOutgoing('buyer', 'fingerprint');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect(await db.isDraftOwnedFailure('buyer', 'fingerprint'), isTrue);
    expect(await db.isDraftOwnedFailure('other', 'fingerprint'), isFalse);
  });
  test(
      'rejected generated bubble is not a manual answer; exact positive receipt reconciles it',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_rejected_capture_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await seed(db);
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'buyer', error: 'send_platform_rejected');
    final at = DateTime.now().toUtc();
    CapturedConversation observed(bool confirmed) => CapturedConversation(
            stableKey: 'customer:buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            capturedAt: at,
            messages: [
              CapturedMessage(
                  stableId: 'failed-bubble',
                  direction: 'outgoing',
                  body: draft.reply,
                  sentAt: at,
                  deliveryConfirmed: confirmed,
                  axPath: 'ocr:test')
            ]);
    await db.saveCapture(observed(false));
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(await db.answeredMessageId('buyer'), isNull);
    await db.saveCapture(observed(true));
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.answeredMessageId('buyer'), 'question');
  });
  test(
      'v20 migration resumes a paused ready draft without losing its original SLA',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v20_probe_');
    var db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await seed(db);
    final sql = await db.database;
    final deadline = (await sql.query('sla_fallbacks')).single['due_at_ms'];
    await sql.execute(
        'ALTER TABLE unavailable_conversations RENAME TO old_unavailable');
    await sql.execute(
        'CREATE TABLE unavailable_conversations(user_id TEXT PRIMARY KEY,failed_at_ms INTEGER NOT NULL,reason TEXT NOT NULL)');
    await sql.execute(
        'INSERT INTO unavailable_conversations SELECT user_id,failed_at_ms,reason FROM old_unavailable');
    await sql.execute('DROP TABLE old_unavailable');
    await sql.execute('DROP TABLE draft_owned_failures');
    await sql.execute('PRAGMA user_version=20');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    final upgraded = await db.database;
    expect(
        (await upgraded.rawQuery('PRAGMA user_version')).single['user_version'],
        CaptureDatabase.databaseSchemaVersion);
    final claim = await db.claimUnavailableProbe('buyer');
    expect(claim, isNotNull);
    expect(claim!['original_deadline_ms'], deadline);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
  });
  for (final scenario in [
    'identity_failure',
    'ownership_blocked',
    'platform_rejected',
    'success'
  ]) {
    final verified = scenario != 'identity_failure';
    final delivered = scenario == 'success';
    testWidgets(
        'current-session unread probes its suspended draft; scenario=$scenario',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      var opens = 0, sends = 0, readiness = 0;
      var unread = false;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_probe_ui_');
        db = CaptureDatabase(storageRoot: root);
      });
      final channel = MethodChannel('jd.recovery.$scenario');
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
                'customer': 'buyer',
                'identitySource': 'ax',
                'unread': unread,
                'redClockPresent': unread,
                'unreadAgeSeconds': unread ? 0 : null,
                'unreadEvidence': unread ? 20 : 0
              }
            ];
          case 'openConversation':
            opens++;
            return verified
                ? {'opened': true, 'customer': 'buyer'}
                : {'error': 'conversation_verification_failed'};
          case 'checkDeliveryReadiness':
            readiness++;
            return scenario == 'ownership_blocked'
                ? {'error': 'customer_not_receiving'}
                : {'ready': true};
          case 'sendDraftOnce':
            sends++;
            if (scenario == 'platform_rejected') {
              return {
                'error': 'send_platform_rejected',
                'rejectedFingerprint': 'owned-failure'
              };
            }
            return {
              'sent': true,
              'confirmation': 'composer_cleared_no_visible_rejection'
            };
          case 'captureViewportEvidence':
            return {'error': 'snapshot_chat_missing'};
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              draftSchedulerOverride: (_) {})));
      await grantRunPermissions(tester);
      await tester.runAsync(() => tester.tap(find.text('Start automation')));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
        if (db.currentAutomationSessionId != null &&
            find.text('Stop automation').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(db.currentAutomationSessionId, isNotNull);
      await tester.runAsync(() async {
        await seed(db, capturedAt: DateTime.now().toUtc());
        await (await db.database)
            .update('unavailable_conversations', {'next_probe_at_ms': 0});
        unread = true;
      });
      // The fresh unread transition is observed by the normal two-second AX
      // poll; the startup poll intentionally saw no previous-run business.
      for (var i = 0; i < 180; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        if (delivered && sends > 0) break;
      }
      expect(opens, greaterThan(0));
      expect(sends, (delivered || scenario == 'platform_rejected') ? 1 : 0);
      expect(readiness, verified ? 1 : 0);
      await tester.runAsync(() async {
        expect(await db.isConversationUnavailable('buyer'), !delivered);
        if (scenario == 'platform_rejected') {
          expect(
              await db.isDraftOwnedFailure('buyer', 'owned-failure'), isTrue);
        }
        if (!delivered) expect(await db.hasUndeliveredDraft('buyer'), isTrue);
      });
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }, skip: !Platform.isMacOS);
  }
}
