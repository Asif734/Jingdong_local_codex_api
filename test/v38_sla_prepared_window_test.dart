import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

void main() {
  for (final mode in ['reuse', 'changed_customer', 'no_red', 'formal_at_19']) {
    testWidgets('AX-red holding preparation and commit: $mode', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_v38_sla_$mode');
        db = CaptureDatabase(storageRoot: root);
        await db.database;
      });
      final channel = MethodChannel('jd-v38-sla-$mode');
      var mono = 0;
      var opens = 0;
      var readiness = 0;
      String? active;
      final sends = <(int, String)>[];
      final red = mode != 'no_red';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
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
                'redClockPresent': red && sends.isEmpty,
                'evidenceAvailable': true,
              }
            ];
          case 'openConversation':
            opens++;
            active = args['expectedCustomer'];
            return {'opened': true, 'customer': active};
          case 'checkDeliveryReadiness':
            readiness++;
            return active == args['expectedCustomer']
                ? {'ready': true, 'customer': active}
                : {'error': 'delivery_readiness_unconfirmed', 'ready': false};
          case 'sendDraftOnce':
            expect(args['expectedCustomer'], active);
            sends.add((mono, args['reply'] as String));
            return {
              'sent': true,
              'customer': active,
              'activeCustomerId': active,
              'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
              'redClockPresentAfterSend': false,
              'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch,
            };
          case 'captureViewportEvidence':
            throw PlatformException(code: 'snapshot_chat_missing');
          case 'inspectOCR':
          case 'inspectViewportEvidence':
            fail('A red deadline must not start OCR before sending.');
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              redClockTracker: RedClockTracker(monotonicMs: () => mono),
              draftSchedulerOverride: (_) {})));
      await grantRunPermissions(tester);
      await tester.tap(find.text('Start automation'));
      var changed = false;
      var formalInserted = false;
      Future<void> insertFormal() async {
        final at = DateTime.now().toUtc();
        await db.saveCapture(CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: at,
            messages: [
              CapturedMessage(
                  stableId: 'independent-question',
                  direction: 'incoming',
                  body: 'How do I connect the USB cable?',
                  sentAt: at,
                  axPath: 'controlled:real-incoming')
            ]));
        final queued = (await db.conversation('buyer'))!;
        final token = await db.beginGeneration(
            customer: 'buyer',
            pendingId: queued.id,
            batchEndMessageId: 'independent-question');
        final draft = AiDraft.fromJson({
          'reply': 'Connect the USB cable to the printer and computer.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-ready-formal',
          'auto_send_allowed': false,
        }, mediaBaseUrl: Uri());
        await db.saveDraft(queued.id, draft,
            expectedMessageId: 'independent-question', generationToken: token);
        await db.abandonGeneration('buyer', token!);
      }

      Future<void>? injection;
      var injectionCompleted = false;
      for (var i = 0; i < 290; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        mono += 100;
        if (mode == 'changed_customer' && mono >= 18000 && !changed) {
          changed = true;
          active = 'other-customer';
        }
        if (mode == 'formal_at_19' && mono >= 19000 && !formalInserted) {
          formalInserted = true;
          await tester.runAsync(() async {
            injection = insertFormal().then((_) {
              injectionCompleted = true;
            });
          });
          // The simulated formal-ready event occurs at second 19. Complete
          // that event before advancing the independent red clock to 20.
          for (var n = 0; n < 400 && !injectionCompleted; n++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 5)));
            await tester.pump();
          }
          expect(injectionCompleted, isTrue);
        }
        await tester.pump(const Duration(milliseconds: 100));
        if (sends.isNotEmpty && mono >= 22000) break;
      }
      if (injection != null) await tester.runAsync(() => injection!);
      if (mode == 'no_red') {
        expect(opens, 0);
        expect(sends, isEmpty);
      } else if (mode == 'formal_at_19') {
        expect(sends.map((s) => s.$2),
            ['Connect the USB cable to the printer and computer.']);
      } else {
        expect(sends, hasLength(1));
        expect(sends.single.$1, greaterThanOrEqualTo(20000));
        expect(readiness, 1);
        expect(opens, mode == 'reuse' ? 1 : 2,
            reason: 'A fresh exact AX match reuses preparation; a changed '
                'customer must be opened and verified again.');
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 50));
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
