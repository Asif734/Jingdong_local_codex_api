import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

AiDraft handoff() => AiDraft.fromJson({
      'reply': 'A colleague will handle the order.',
      'decision': 'human_review_required',
      'confidence': 1,
      'risk_level': 'medium',
      'human_review_required': true,
      'risk_triggers': ['order_service_handoff'],
      'reason': 'Requires order authority',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': 'test'
    }, mediaBaseUrl: Uri());
AiDraft businessAnswer() => AiDraft.fromJson({
      'reply':
          'Please provide your order number and describe the fault so we can verify the repair information.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': 'fixture-business-answer'
    }, mediaBaseUrl: Uri());
void main() {
  test(
      'order authority routing distinguishes actions from product policy questions',
      () {
    expect(
        requiresOrderServiceHandoff(
            'i am at shanghai, send me the repair centre location', []),
        isTrue);
    expect(requiresOrderServiceHandoff('请修改订单收货地址', []), isTrue);
    expect(requiresOrderServiceHandoff('这台机器保修几年？', []), isFalse);
    expect(
        requiresOrderServiceHandoff('How do I claim warranty?', []), isFalse);
    expect(
        requiresOrderServiceHandoff('give me that assistance then', [
          {
            'direction': 'outgoing',
            'body': 'The next step requires after-sales assistance.'
          }
        ]),
        isTrue);
    expect(isExplicitHumanTransfer(handoff()), isTrue);
    expect(
        handoffContextSummary([
          {'direction': 'incoming', 'body': 'order number TEST_ORDER'},
          {
            'direction': 'outgoing',
            'source': 'generated_reply',
            'body': 'Please obtain the repair address.'
          },
          {'direction': 'incoming', 'body': 'transfer me'}
        ]),
        contains('TEST_ORDER'));
  });
  test(
      'pending handoff keeps subsequent order details and holding without restarting AI',
      () async {
    final root = await Directory.systemTemp.createTemp('v27_context_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    Future<void> capture(String id, String body) async {
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                axPath: 'fixture')
          ]));
    }

    await capture('order', 'Please arrange repair for my order');
    final pending = (await db.conversations()).single;
    await db.saveDraft(pending.id, handoff(),
        expectedMessageId: 'order', deliverable: false);
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'Please arrange repair for my order',
        reason: 'Requires order authority',
        requestMessageId: 'order');
    await db.markTicketHandoffPending(ticket.id);
    await db.appendAutomatedNoticeSent(
        userId: 'buyer', reply: 'Your details are saved for the colleague.');
    await capture('extra-order', 'Order number EXTRA_ORDER');
    expect(
        (await (await db.database).query('human_review_tickets'))
            .single['customer_request'],
        contains('EXTRA_ORDER'));
    final current = (await db.conversations()).single;
    expect(
        await db.beginGeneration(
            customer: 'buyer',
            pendingId: current.id,
            batchEndMessageId: 'extra-order'),
        isNull);
    expect(await db.isHandoffPending('buyer'), isTrue);
    expect(await db.nextReadyDelivery(), isNull);
    await db.discardTransferOnlyDraft('buyer');
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(await db.answeredMessageId('buyer'), isNull);
    await db.observePlatformResponse('buyer', red: true);
    final job = await db.slaFallbackJob('buyer');
    expect(job, isNotNull);
    expect(await db.isPlatformResponsePending(job!), isTrue);
  });
  for (final outcome in ['failure', 'unconfirmed', 'success', 'priority']) {
    final success = outcome == 'success';
    testWidgets(
        'handoff completion requires native confirmation; outcome=$outcome',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('v27_handoff_');
        db = CaptureDatabase(storageRoot: root);
      });
      Future<T> finishWhilePumping<T>(Future<T> Function() action) async {
        var done = false;
        late T result;
        Object? failure;
        StackTrace? failureStack;
        // A UI transaction may have started in FakeAsync. Start this external
        // read without blocking the pumps needed for that transaction's next
        // callback and commit; waiting in runAsync alone would hold both sides.
        await tester.runAsync(() async {
          unawaited(action().then((value) {
            result = value;
            done = true;
          }, onError: (Object error, StackTrace stack) {
            failure = error;
            failureStack = stack;
            done = true;
          }));
        });
        for (var i = 0; i < 300 && !done; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(done, isTrue,
            reason: 'DB bookkeeping must finish while UI pumps continue');
        if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
        return result;
      }

      final channel = MethodChannel('v27.handoff.$success');
      var transfers = 0;
      var attempts = 0;
      var selectionClosures = 0;
      var urgentCycleCleared = false;
      var urgentCycleActive = false;
      var inspectionsDuringUrgency = 0;
      var transfersDuringUrgency = 0;
      final uiEvents = <String>[];
      final replies = <String>[];
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
                'unread': false,
                'redClockPresent': false,
                'evidenceAvailable': true
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': 'buyer'};
          case 'listActiveTransferAccounts':
            if (urgentCycleActive) inspectionsDuringUrgency++;
            attempts++;
            uiEvents.add('inspect:$attempts:urgent=$urgentCycleActive');
            if (outcome == 'priority' && attempts == 2) {
              final now = DateTime.now();
              await db.observePlatformResponse('urgent_buyer',
                  red: true,
                  observedAt: now,
                  startedAt: now.subtract(const Duration(seconds: 15)));
              urgentCycleActive = true;
            }
            if (outcome == 'failure') {
              throw PlatformException(code: 'transfer_budget_exceeded');
            }
            return {
              'accounts': ['agent'],
              'sourceAccount': 'source'
            };
          case 'sendDraftOnce':
            replies.add((call.arguments as Map)['reply'] as String);
            uiEvents.add('send:${replies.last}');
            return {'sent': true};
          case 'cancelTransferSelection':
            selectionClosures++;
            uiEvents.add('close:$selectionClosures');
            return {'closed': true};
          case 'transferConversation':
            if (urgentCycleActive) transfersDuringUrgency++;
            uiEvents.add('transfer:urgent=$urgentCycleActive');
            transfers++;
            return {
              'transferred': true,
              'customer': success ? 'buyer' : 'other',
              'targetAccount': 'agent',
              'attemptId': (call.arguments as Map)['attemptId'],
              'receiptState': 'confirmed',
              'transferClicked': true,
            };
          case 'captureViewportEvidence':
            throw PlatformException(code: 'snapshot_chat_missing');
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              generateDraftOverride: (c, d, b, x) async =>
                  await d.isHandoffSuppressed(c.userId, b)
                      ? businessAnswer()
                      : handoff())));
      await grantRunPermissions(tester);
      await tester.tap(find.text('Start automation'));
      for (var i = 0; i < 100 && db.currentAutomationSessionId == null; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(db.currentAutomationSessionId, isNotNull);
      await tester.runAsync(() => db.saveCapture(CapturedConversation(
              stableKey: 'buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              capturedAt: DateTime.now(),
              messages: const [
                CapturedMessage(
                    stableId: 'order',
                    direction: 'incoming',
                    body: 'Please check my order TEST_ORDER',
                    axPath: 'fixture')
              ])));
      for (var i = 0; i < 600; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
        if (outcome == 'priority' &&
            selectionClosures >= 2 &&
            !urgentCycleCleared) {
          expect(transfers, 0,
              reason: 'Urgent reply must overtake transfer click');
          await tester.runAsync(
              () => db.observePlatformResponse('urgent_buyer', red: false));
          urgentCycleCleared = true;
          urgentCycleActive = false;
          uiEvents.add('urgent_cleared');
        }
        if ((success &&
                find.textContaining('transferred').evaluate().isNotEmpty) ||
            (!success &&
                replies.contains(businessAnswer().reply) &&
                (outcome != 'priority' || urgentCycleCleared))) {
          break;
        }
      }
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      if (!success) {
        for (var i = 0; i < 100; i++) {
          final answered =
              await finishWhilePumping(() => db.answeredMessageId('buyer'));
          if (answered == 'order') break;
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 30));
        }
      }
      expect(attempts, greaterThan(0));
      if (outcome == 'priority') {
        expect(urgentCycleCleared, isTrue);
        expect(attempts, greaterThanOrEqualTo(2));
        expect(inspectionsDuringUrgency, 0,
            reason:
                'Transfer inspection must yield for the whole active urgent cycle: $uiEvents');
        expect(transfersDuringUrgency, 0,
            reason:
                'No transfer click is allowed before the urgent reply duty clears: $uiEvents');
      }
      await finishWhilePumping(() async {
        if (success) {
          expect(transfers, 1);
          expect(
              (await (await db.database).query('human_review_tickets'))
                  .single['assigned_to'],
              'agent');
          expect(await db.isMessageFormallyAnswered('buyer', 'order'), isFalse,
              reason:
                  'A confirmed handoff delegates responsibility; it does not fabricate a formal answer.');
          final delegated = await (await db.database).query(
              'automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [db.currentAutomationSessionId, 'buyer', 'order']);
          expect(delegated.single['response_state'], 'delegated');
          expect(await db.hasUndeliveredDraft('buyer'), isFalse);
        } else {
          // Once this test explicitly clears the urgent cycle, the retained
          // transfer todo may resume. That does not release it while urgency
          // is active, and an unconfirmed physical click is never repeated.
          expect(
              transfers,
              outcome == 'unconfirmed'
                  ? 1
                  : outcome == 'priority'
                      ? inInclusiveRange(0, 1)
                      : 0);
          expect(await db.isHandoffPending('buyer'), isTrue,
              reason: 'The open authority task remains, but cannot freeze AI.');
          expect(await db.isHandoffSuppressed('buyer', 'order'), isTrue);
          expect(replies, contains(businessAnswer().reply));
          expect(await db.answeredMessageId('buyer'), 'order',
              reason:
                  'state=${await (await db.database).query('generated_drafts')} '
                  'attempts=${await (await db.database).query('delivery_attempts')}');
          expect(await db.hasUndeliveredDraft('buyer'), isFalse);
          final tickets =
              await (await db.database).query('human_review_tickets');
          expect(tickets.single['assigned_to'], isNull);
          expect(tickets.single['customer_request'], contains('TEST_ORDER'));
          expect(tickets.single['status'], 'open');
        }
      });
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }

      await tester.pumpWidget(const SizedBox());
      // Disposal cancels the worker; drive its asynchronous DB bookkeeping
      // before closing the temporary database owned by this test.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }, skip: !Platform.isMacOS);
  }
}
