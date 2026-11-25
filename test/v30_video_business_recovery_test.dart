import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

AiDraft videoRecoveryDraft(String model) => AiDraft.fromJson({
      'reply':
          'The original video needs an authorized colleague to retrieve it.',
      'decision': 'human_review_required',
      'human_review_required': true,
      'confidence': 1,
      'risk_level': 'medium',
      'risk_triggers': ['media_original_unavailable'],
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
      'model': model,
    }, mediaBaseUrl: Uri());

AiDraft normalAnswer() => AiDraft.fromJson({
      'reply':
          'Please check the paper width and make sure the paper guides hold it evenly.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': true,
      'model': 'fixture-normal-answer',
    }, mediaBaseUrl: Uri());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'video original escalation is restricted to the trusted local recovery model',
      () {
    expect(
        isExplicitHumanTransfer(
            videoRecoveryDraft('jd-video-original-recovery-v1')),
        isTrue);
    expect(isExplicitHumanTransfer(videoRecoveryDraft('untrusted-model')),
        isFalse);
    expect(isExplicitHumanTransfer(videoRecoveryDraft('gpt-model')), isFalse);
  });
  for (final scenario in [
    'waiting_holding',
    'old_pending_original',
    'old_pending_no_agents',
    'original_arrives',
    'unrelated_ambiguous',
    'ambiguous_same_alias'
  ]) {
    testWidgets('video business recovery: $scenario', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const customer = 'video_buyer';
      const messageId = 'current-question';
      const receipt = 'known-video-card';
      final oldPending = scenario.startsWith('old_pending_');
      final noAgents = scenario == 'old_pending_no_agents';
      final delayedGeneration =
          scenario == 'waiting_holding' ? Completer<AiDraft>() : null;
      final ambiguous = scenario.contains('ambiguous');
      final unrelated = scenario == 'unrelated_ambiguous';
      late Directory root;
      late CaptureDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('v30_video_business_');
        db = CaptureDatabase(storageRoot: root);
      });
      Future<void> seedCurrentVideo() async {
        final now = DateTime.now();
        await db.saveCapture(CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            capturedAt: now,
            messages: [
              CapturedMessage(
                  stableId: messageId,
                  direction: 'incoming',
                  body: unrelated
                      ? 'What paper width should I use?'
                      : 'My printer is not working; please check this video and help me.',
                  sentAt: now,
                  axPath: 'fixture')
            ]));
        final first = now
            .subtract(Duration(seconds: oldPending || ambiguous ? 500 : 5))
            .millisecondsSinceEpoch;
        await (await db.database).insert('customer_media_items', {
          'item_id': receipt,
          'customer': customer,
          'sender_ms': now.millisecondsSinceEpoch,
          'slot': 0,
          'kind': 'video',
          'state': 'pending',
          'first_seen_ms': first,
          'last_seen_ms': now.millisecondsSinceEpoch,
          'evidence_id': 'saved-card',
          'message_id': unrelated ? 'other-history-card' : messageId,
          'identity_ambiguous': ambiguous ? 1 : 0,
          'media_json': '[]',
          'aliases_json':
              jsonEncode([unrelated ? 'other-history-card' : messageId]),
        });
      }

      final channel = MethodChannel('v30.video.$scenario');
      var generated = 0;
      var holding = 0;
      var transferNotices = 0;
      var formal = 0;
      var transfers = 0;
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
                'redClockPresent':
                    scenario == 'waiting_holding' && holding == 0,
                'unreadAgeSeconds':
                    scenario == 'waiting_holding' && holding == 0 ? 21 : null,
                'evidenceAvailable': true
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': customer};
          case 'captureViewportEvidence':
            throw PlatformException(code: 'snapshot_chat_missing');
          case 'captureRecentCachedMedia':
            return <String, Object?>{};
          case 'listActiveTransferAccounts':
            return {
              'accounts': noAgents ? <String>[] : ['authorized_agent'],
              'sourceAccount': 'source_agent'
            };
          case 'cancelTransferSelection':
            return {'closed': true};
          case 'sendDraftOnce':
            final args = call.arguments as Map;
            final reply = args['reply']! as String;
            if (isHoldingReply(reply)) {
              holding++;
            } else if (reply == normalAnswer().reply) {
              formal++;
            } else {
              transferNotices++;
            }
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
              generateDraftOverride: (_, __, ___, ____) async {
                generated++;
                return delayedGeneration == null
                    ? normalAnswer()
                    : await delayedGeneration.future;
              })));
      await grantRunPermissions(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Start automation'));
      });
      Future<void> advance([int count = 1]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 15)));
          await tester.pump(const Duration(milliseconds: 30));
        }
      }

      for (var i = 0; i < 100 && db.currentAutomationSessionId == null; i++) {
        await advance();
      }
      expect(db.currentAutomationSessionId, isNotNull);
      await tester.runAsync(seedCurrentVideo);

      if (scenario == 'original_arrives') {
        await advance(25);
        expect(generated, lessThanOrEqualTo(1),
            reason:
                'Acquisition state cannot suppress a useful reply to known text');
        await tester.runAsync(() async {
          await (await db.database).update(
              'customer_media_items', {'state': 'ready', 'media_json': '[]'},
              where: 'item_id=?', whereArgs: [receipt]);
        });
      }
      for (var i = 0; i < 400; i++) {
        await advance();
        if (scenario == 'waiting_holding' && holding > 0) break;
        if (scenario != 'waiting_holding' && formal > 0) break;
      }
      await advance(15);
      if (scenario == 'waiting_holding') {
        expect(holding, 1,
            reason:
                'The original-video wait must not block the twenty-second response');
        // Sending holding and claiming a generation lease run independently.
        // Wait for the actual generation milestone under concurrent test I/O.
        for (var i = 0; i < 200 && generated == 0; i++) {
          await advance();
        }
        expect(generated, 1,
            reason: 'The pending real question must enter generation');
        expect(holding, 1,
            reason: 'Waiting for generation cannot create another holding');
        expect(formal, 0);
        expect(transfers, 0);
        await tester.runAsync(() async {
          expect(await db.answeredMessageId(customer), isNull,
              reason: 'Holding is not a formal business answer');
          expect(await db.hasPendingUnanswered(customer), isTrue);
        });
        delayedGeneration!.complete(normalAnswer());
        for (var i = 0; i < 200 && formal == 0; i++) {
          await advance();
        }
        expect(formal, 1,
            reason: 'Holding never replaces the eventual real business reply');
      } else {
        expect(generated, 1);
        expect(formal, 1);
        expect(transfers, 0);
        expect(transferNotices, 0);
        await tester.runAsync(() async {
          expect(
              await db.isMessageFormallyAnswered(customer, messageId), isTrue);
          expect(
              await (await db.database).query('human_review_tickets'), isEmpty,
              reason: 'Elapsed media age must not manufacture a handoff');
        });
      }
      await tester.tap(find.text('Stop automation'));
      await advance(15);
      await tester.pumpWidget(const SizedBox());
      await advance(8);
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }, skip: !Platform.isMacOS);
  }
}
