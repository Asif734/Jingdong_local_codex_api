import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/hosted_reply_service.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';
import 'package:jd_automation/backend/jd_v2_jobs.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

class ImmediateTransferApi extends JdV2Client {
  ImmediateTransferApi()
      : super(
            baseUri: Uri.parse('https://fixture.example/v2'),
            apiKey: 'fixture');
  bool blockFirstSubmit = false;
  final firstSubmit = Completer<Map<String, dynamic>>();
  Map<String, dynamic>? request;
  int submissions = 0;
  @override
  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> value, List<JdV2Upload> uploads) async {
    submissions++;
    request = value;
    if (blockFirstSubmit && submissions == 1) return firstSubmit.future;
    return {
      'jobId': 'widget-transfer',
      'pollUrl': '/v2/replies/widget-transfer'
    };
  }

  @override
  Future<Map<String, dynamic>> poll(String jobId, String pollUrl) async => {
        'status': 'completed',
        'jobId': jobId,
        'resultDigest': 'a' * 64,
        'binding': {
          'platform': 'jd',
          'storeId': request!['storeId'],
          'customerUid': request!['customerUid'],
          'historyVersion': request!['historyVersion'],
          'jobId': jobId
        },
        'reply': {
          'action': 'reply_then_transfer',
          'reply_text': '由客服同事接续处理。',
          'transfer_reason': 'troubleshooting_exhausted',
          'product_id': null,
          'product_query': null,
          'sku_label': null,
          'reason': 'API decision'
        }
      };
}

void main() {
  for (final scenario in [
    (false, '转wenwen'),
    (true, '转wenwen'),
    (false, '打印机需要维修'),
    (false, '停止重启后的新问题')
  ]) {
    final withUncertainReply = scenario.$1;
    final customerRequest = scenario.$2;
    final restartScenario = customerRequest == '停止重启后的新问题';
    final useHosted = customerRequest == '打印机需要维修' || restartScenario;
    testWidgets(
        'named handoff uses one modal; old uncertain reply=$withUncertainReply request=$customerRequest',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      late HostedReplyService service;
      final api = ImmediateTransferApi()..blockFirstSubmit = restartScenario;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('single-modal-handoff-');
        db = CaptureDatabase(storageRoot: root);
        await db.database;
        await File('${root.path}/AGENTS.md')
            .writeAsString('Answer this message.');
        service = HostedReplyService(
            workspace: root,
            client: api,
            jobs: JdV2Jobs(Directory('${root.path}/jd_v2_jobs'), api,
                pollInterval: Duration.zero));
      });
      const channel = MethodChannel('test.single.modal.handoff');
      var opens = 0, inspections = 0, closes = 0, sends = 0, transfers = 0;
      var modalOpen = false;
      final blockedViewport = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments is Map ? call.arguments as Map : const {};
        switch (call.method) {
          case 'prepareRunPermissions':
          case 'runPermissionsStatus':
            return {'ready': true};
          case 'status':
            return {'trusted': true};
          case 'ensureReceptionWindow':
            return {'opened': true};
          case 'listConversationRows':
            return <Object>[];
          case 'flushDiagnosticTrace':
            return null;
          case 'captureViewportEvidence':
            if (restartScenario) return blockedViewport.future;
            throw PlatformException(code: 'snapshot_chat_missing');
          case 'openConversation':
            opens++;
            return {
              'opened': true,
              'customer': 'buyer',
              'activeCustomerId': 'buyer',
              'focusVerified': true,
              'identityProof': 'exact_active_ax'
            };
          case 'listActiveTransferAccounts':
            inspections++;
            modalOpen = true;
            return {
              'accounts': ['格志打印机文文（雯雯）', '另一店铺文文'],
              'sourceAccount': '格志打印机小耿'
            };
          case 'cancelTransferSelection':
            closes++;
            modalOpen = false;
            return {'closed': true};
          case 'sendDraftOnce':
            sends++;
            return {'sent': true};
          case 'transferConversation':
            expect(modalOpen, isTrue);
            if (customerRequest.startsWith('转')) {
              expect(args['targetAccount'], '格志打印机文文（雯雯）');
            } else {
              expect(args['targetAccount'], isIn(['格志打印机文文（雯雯）', '另一店铺文文']));
            }
            transfers++;
            modalOpen = false;
            return {
              'transferred': true,
              'customer': 'buyer',
              'targetAccount': args['targetAccount'],
              'attemptId': args['attemptId'],
              'transferClicked': true,
              'receiptState': 'confirmed'
            };
        }
        return <String, Object?>{};
      });
      Future<void> tick([int n = 20]) async {
        for (var i = 0; i < n; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              reportOutputDirectory: Directory('${root.path}/exports'),
              adapter: MacOSCaptureAdapter(channel: channel),
              replyServiceOverride: useHosted ? service : null,
              generateDraftOverride: useHosted
                  ? null
                  : (c, d, b, x) async => AiDraft.fromJson({
                        'reply': 'Internal transfer decision.',
                        'decision': 'human_review_required',
                        'human_review_required': true,
                        'risk_triggers': ['service_colleague_required'],
                        'jd_v2': {
                          'reply': {'action': 'reply_then_transfer'}
                        },
                        'reason': 'Customer explicitly requested human agent.',
                        'confidence': 1,
                        'risk_level': 'medium',
                        'model': 'controlled-handoff',
                      }, mediaBaseUrl: Uri()),
              draftSchedulerOverride: useHosted ? null : (_) {})));
      await tick();
      await grantRunPermissions(tester);
      await tester.runAsync(() => tester.tap(find.text('Start automation')));
      await tick();
      if (restartScenario) {
        final previousSession = db.currentAutomationSessionId;
        await tester.runAsync(() async {
          final at = DateTime.now();
          await db.saveCapture(
              CapturedConversation(
                  stableKey: 'buyer',
                  customerName: 'buyer',
                  customerExternalId: 'buyer',
                  capturedAt: at,
                  automationSessionId: previousSession,
                  messages: [
                    CapturedMessage(
                        stableId: 'stalled-before-stop',
                        direction: 'incoming',
                        body: '停止前的问题',
                        sentAt: at,
                        axPath: 'fixture')
                  ]),
              activeIncomingIds: {'stalled-before-stop'});
        });
        for (var i = 0; i < 160 && api.submissions == 0; i++) {
          await tick(1);
        }
        expect(api.submissions, 1);
        expect(transfers, 0);
        await tester.runAsync(() => tester.tap(find.text('Stop automation')));
        await tick();
        expect(find.text('Start automation'), findsOneWidget);
        // Export must not wait for the deliberately uncooperative old API/OCR.
        await tester.runAsync(() =>
            tester.tap(find.byKey(const ValueKey('export-stopped-report'))));
        for (var i = 0;
            i < 160 && find.textContaining('报告已导出：').evaluate().isEmpty;
            i++) {
          await tick(1);
        }
        expect(find.textContaining('报告已导出：'), findsOneWidget);
        final exported = await tester
            .runAsync(() => Directory('${root.path}/exports').list().toList());
        expect(
            exported!.whereType<File>().where((f) => f.path.endsWith('.zip')),
            hasLength(1));
        await tester.runAsync(() => tester.tap(find.text('Start automation')));
        await tick();
        expect(db.currentAutomationSessionId, isNot(previousSession));
      }
      await tester.runAsync(() async {
        final now = DateTime.now();
        if (withUncertainReply) {
          final oldAt = now;
          await db.saveCapture(
              CapturedConversation(
                  stableKey: 'buyer',
                  customerName: 'buyer',
                  customerExternalId: 'buyer',
                  capturedAt: oldAt,
                  automationSessionId: db.currentAutomationSessionId,
                  messages: [
                    CapturedMessage(
                        stableId: 'old',
                        direction: 'incoming',
                        body: 'hello',
                        sentAt: oldAt,
                        axPath: 'fixture')
                  ]),
              activeIncomingIds: {'old'});
          final oldPending = (await db.conversation('buyer'))!;
          await db.saveDraft(
              oldPending.id,
              AiDraft.fromJson({
                'reply': '您好，在的。',
                'decision': 'draft',
                'confidence': 1,
                'risk_level': 'low',
                'model': 'test'
              }, mediaBaseUrl: Uri()),
              expectedMessageId: 'old');
          final attempt =
              await db.beginDeliveryAttempt(userId: 'buyer', reply: '您好，在的。');
          await File(attempt['receiptPath']!).writeAsString(jsonEncode({
            'attemptId': attempt['attemptId'],
            'customer': 'buyer',
            'state': 'submitted',
            'timeMs': now.millisecondsSinceEpoch
          }));
          await db.recoverDeliveryReceipts();
          expect(
              await db.noteObservedRejection(
                  customer: 'buyer',
                  body: '您好，在的。',
                  fingerprint: 'old-failed',
                  capturedAt: now.add(const Duration(seconds: 1))),
              isTrue);
          await db.recoverDeliveryReceipts();
          expect(await db.hasUndeliveredDraft('buyer'), isTrue);
        }
      });
      if (withUncertainReply) {
        for (var i = 0; i < 160; i++) {
          if (await tester.runAsync(() => db.hasUndeliveredDraft('buyer')) ==
              false) {
            break;
          }
          await tick(1);
        }
        expect(await tester.runAsync(() => db.hasUndeliveredDraft('buyer')),
            isFalse);
      }
      await tester.runAsync(() async {
        final now = DateTime.now();
        await db.saveCapture(
            CapturedConversation(
                stableKey: 'buyer',
                customerName: 'buyer',
                customerExternalId: 'buyer',
                capturedAt: now,
                automationSessionId: db.currentAutomationSessionId,
                messages: [
                  CapturedMessage(
                      stableId: 'request',
                      direction: 'incoming',
                      body: customerRequest,
                      sentAt: now.add(const Duration(seconds: 2)),
                      axPath: 'fixture')
                ]),
            activeIncomingIds: {'request'});
        if (useHosted) return;
        final requestId = (await db.incomingMessageIdAtTime(
            'buyer', now.add(const Duration(seconds: 2))))!;
        final pending = (await db.conversation('buyer'))!;
        final token = await db.beginGeneration(
            customer: 'buyer',
            pendingId: pending.id,
            batchEndMessageId: requestId,
            singleMessage: true);
        expect(token, isNotNull);
        expect(
            await db.saveDraft(
                pending.id,
                AiDraft.fromJson({
                  'reply': 'Internal transfer decision.',
                  'decision': 'human_review_required',
                  'human_review_required': true,
                  'risk_triggers': ['service_colleague_required'],
                  'jd_v2': {
                    'reply': {'action': 'reply_then_transfer'}
                  },
                  'reason': 'Customer explicitly requested human agent.',
                  'confidence': 1,
                  'risk_level': 'medium',
                  'model': 'controlled-handoff',
                }, mediaBaseUrl: Uri()),
                expectedMessageId: requestId,
                generationToken: token,
                deliverable: false),
            1);
        await db.abandonGeneration('buyer', token!);
        await db.createHumanReviewTicket(
            userId: 'buyer',
            customerRequest: customerRequest,
            reason: 'Customer explicitly requested human agent.',
            requestMessageId: requestId);
      });
      for (var i = 0; i < 160 && transfers == 0; i++) {
        await tick(1);
      }
      await tick(10);
      expect(transfers, 1,
          reason:
              'opens=$opens inspections=$inspections closes=$closes sends=$sends');
      if (useHosted) expect(api.submissions, restartScenario ? 2 : 1);
      expect(inspections, 1);
      expect(closes, 0);
      expect(sends, 0);
      expect(opens, 1);
      await tester.runAsync(() => tester.tap(find.text('Stop automation')));
      await tick();
      await tester.pumpWidget(const SizedBox());
      await tick(5);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        if (!api.firstSubmit.isCompleted)
          api.firstSubmit.complete(
              {'jobId': 'abandoned', 'pollUrl': '/v2/replies/abandoned'});
        if (!blockedViewport.isCompleted)
          blockedViewport.complete({'error': 'automation_stopped'});
        api.close();
        await db.close();
        await root.delete(recursive: true);
      });
    }, skip: !Platform.isMacOS);
  }
}
