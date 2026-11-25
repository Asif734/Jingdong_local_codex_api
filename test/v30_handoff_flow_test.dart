import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

AiDraft decision() => AiDraft.fromJson({
      'reply': 'Order repair requires an authorized colleague.',
      'decision': 'human_review_required',
      'human_review_required': true,
      'risk_triggers': ['order_service_handoff'],
      'reason': 'Requires order authority',
      'confidence': 1,
      'risk_level': 'medium',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': 'fixture'
    }, mediaBaseUrl: Uri());
AiDraft businessAnswer() => AiDraft.fromJson({
      'reply':
          'Please provide the order number and whether the power indicator turns on. An authorized colleague must verify repair eligibility.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': 'fixture-answer'
    }, mediaBaseUrl: Uri());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'legacy_unclicked',
    'new_request_reception_ready',
    'new_request_composer_occupied',
    'same_unknown_request'
  ]) {
    final fresh = scenario.startsWith('new_request_');
    final shouldTransfer = scenario == 'new_request_reception_ready';
    testWidgets('business handoff reaches a real outcome: $scenario',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      late int oldTicketId;
      late int oldLogId;
      const customer = 'business_buyer';
      const source = 'source_agent';
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('v30_handoff_flow_');
        db = CaptureDatabase(storageRoot: root);
      });
      Future<void> seedHandoff() async {
        Future<void> message(String id) async {
          await db.saveCapture(CapturedConversation(
              stableKey: customer,
              customerName: customer,
              customerExternalId: customer,
              capturedAt: DateTime.now(),
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: 'Order repair $id',
                    axPath: 'fixture')
              ]));
        }

        await message('order1');
        final pending = (await db.conversations()).single;
        if (!fresh) {
          await db.saveDraft(pending.id, decision(),
              expectedMessageId: 'order1', deliverable: false);
        }
        final ticket = await db.createHumanReviewTicket(
            userId: customer,
            customerRequest: 'Repair order1',
            reason: 'Order authority',
            requestMessageId: 'order1');
        final log = (await db.reserveChatTransferLog(ticket: ticket))!;
        oldTicketId = ticket.id;
        oldLogId = log.id;
        await db.markTicketHandoffPending(ticket.id);
        if (scenario == 'legacy_unclicked') {
          await (await db.database).update(
              'chat_transfer_logs',
              {
                'status': 'failed',
                'phase': 'legacy',
                'source_account': source,
                'owner_pid': null,
                'error':
                    'transfer_budget_exceeded; no transfer was clicked; transferClicked: false'
              },
              where: 'id=?',
              whereArgs: [log.id]);
        } else {
          await db.updateChatTransferLog(
              id: log.id, status: 'unconfirmed', sourceAccount: source);
        }
      }

      if (!fresh) await tester.runAsync(seedHandoff);
      final channel = MethodChannel('v30.business.$scenario');
      var transfers = 0;
      var ownershipReads = 0;
      var generated = 0;
      var notices = 0;
      var formalAttempts = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
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
                'customer': customer,
                'identitySource': 'ax',
                'unread': false,
                'redClockPresent': false,
                'evidenceAvailable': true
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': customer};
          case 'captureViewportEvidence':
            throw PlatformException(code: 'snapshot_chat_missing');
          case 'checkDeliveryReadiness':
            ownershipReads++;
            expect((call.arguments as Map)['requireCurrentOwnership'], isTrue);
            if (scenario == 'new_request_composer_occupied') {
              return {'ready': false, 'error': 'composer_not_empty'};
            }
            return {
              'ready': true,
              'ownershipConfirmed': true,
              'ownershipProof': 'current_enabled_empty_reception_ax',
              'currentCustomer': customer,
              'activeCustomerId': customer,
              'sourceAccount': source,
              'observedAtMs': DateTime.now().millisecondsSinceEpoch
            };
          case 'listActiveTransferAccounts':
            return {
              'accounts': ['authorized_agent'],
              'sourceAccount': source
            };
          case 'cancelTransferSelection':
            return {'closed': true};
          case 'sendDraftOnce':
            if ((call.arguments as Map)['reply'] == businessAnswer().reply) {
              formalAttempts++;
              return {'sent': false, 'error': 'composer_not_empty'};
            }
            notices++;
            return {'sent': true};
          case 'transferConversation':
            transfers++;
            return {
              'transferred': true,
              'customer': customer,
              'targetAccount': 'authorized_agent',
              'attemptId': (call.arguments as Map)['attemptId'],
              'receiptState': 'confirmed',
              'transferClicked': true
            };
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              generateDraftOverride: (c, d, b, x) async {
                generated++;
                return await d.isHandoffSuppressed(c.userId, b)
                    ? businessAnswer()
                    : decision();
              })));
      await grantRunPermissions(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Start automation'));
      });
      for (var i = 0; i < 100 && db.currentAutomationSessionId == null; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(db.currentAutomationSessionId, isNotNull);
      if (fresh) {
        await tester.runAsync(() async {
          await seedHandoff();
          await db.saveCapture(CapturedConversation(
              stableKey: customer,
              customerName: customer,
              customerExternalId: customer,
              capturedAt: DateTime.now(),
              messages: const [
                CapturedMessage(
                    stableId: 'order2',
                    direction: 'incoming',
                    body: 'Order repair order2',
                    axPath: 'fixture')
              ]));
        });
      }
      for (var i = 0; i < 320; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump(const Duration(milliseconds: 30));
        if (shouldTransfer && transfers == 1) {
          for (var j = 0; j < 20; j++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)));
            await tester.pump(const Duration(milliseconds: 20));
          }
          break;
        }
        if (!fresh && i >= 30) break;
        if (fresh && !shouldTransfer && formalAttempts > 0) break;
      }
      if (!fresh) {
        expect(generated, 0, reason: 'Archived work is inert.');
      } else {
        expect(generated, greaterThanOrEqualTo(1));
      }
      expect(transfers, shouldTransfer ? 1 : 0,
          reason: 'A current-session replacement ticket must remain eligible '
              'after strict AX proof. ownershipReads=$ownershipReads');
      await tester.runAsync(() async {
        final tickets = await (await db.database).query('human_review_tickets');
        final logs = await (await db.database).query('chat_transfer_logs');
        if (shouldTransfer) {
          expect(
              tickets.where((t) => t['status'] == 'contacted'), hasLength(1));
          expect(
              tickets.singleWhere(
                  (t) => t['status'] == 'contacted')['assigned_to'],
              'authorized_agent');
          expect(
              await db.isCurrentSessionTicket(tickets
                  .singleWhere((t) => t['status'] == 'contacted')['id'] as int),
              isTrue);
          expect(await db.hasUndeliveredDraft(customer), isFalse);
          expect(notices, 1);
          if (scenario == 'new_request_reception_ready') {
            expect(ownershipReads, 1);
            expect(tickets.singleWhere((t) => t['id'] == oldTicketId)['status'],
                'superseded_unconfirmed');
            expect(logs.singleWhere((l) => l['id'] == oldLogId)['status'],
                'unconfirmed');
            expect(logs, hasLength(2));
          }
        } else if (fresh) {
          expect(await db.answeredMessageId(customer), isNull);
          expect(await db.hasUndeliveredDraft(customer), isTrue);
          expect(await db.isHandoffPending(customer), isTrue,
              reason:
                  'The unresolved business ticket remains, while AI is released.');
          expect(await db.isHandoffSuppressed(customer, 'order2'), isTrue);
          expect(await db.blockedHandoffServices(), isNotEmpty);
          expect(notices, 0,
              reason:
                  'Uncertain ownership cannot send another transfer acknowledgement');
          expect(ownershipReads, greaterThanOrEqualTo(1));
        } else {
          expect(tickets.single['status'], 'session_archived');
          expect(await db.hasUndeliveredDraft(customer), isFalse);
          expect(await db.isHandoffPending(customer), isFalse);
          expect(await db.blockedHandoffServices(), isEmpty);
          expect(notices, 0);
          expect(ownershipReads, 0);
          expect(logs.single['status'],
              scenario == 'legacy_unclicked' ? 'failed' : 'unconfirmed');
        }
      });
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }, skip: !Platform.isMacOS);
  }
}
