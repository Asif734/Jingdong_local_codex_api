import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'helpers/run_permissions.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  for (final unknownAge in [false, true]) {
    testWidgets(
        'row discovery sends holding to canonical AX customer; unknown AX timer=$unknownAge',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_row_flow_');
        db = CaptureDatabase(storageRoot: root);
      });
      const channel = MethodChannel('jd.row-binding-flow');
      final calls = <String>[];
      var sent = 0;
      var mono = 0;
      var started = DateTime.now().toUtc();
      var firstRows = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'prepareRunPermissions':
          case 'runPermissionsStatus':
            return {'ready': true};
          case 'status':
            return {'trusted': true};
          case 'ensureReceptionWindow':
            return {'opened': true};
          case 'listConversationRows':
            if (firstRows) {
              started = DateTime.now().toUtc();
              firstRows = false;
            }
            return [
              {
                'customer': 'unusable OCR lIQQ',
                'identitySource': 'row_anchor',
                'rowKey': 'shape-a',
                'rowToken': 'token-a',
                'rowIndex': 0,
                'unread': true,
                'unreadEvidence': 12,
                'unreadAgeSeconds': unknownAge ? null : 21,
                'redClockPresent': sent == 0,
                'evidenceAvailable': true,
              }
            ];
          case 'openConversationRow':
            expect((call.arguments as Map)['expectedCustomer'], isNull);
            return {
              'opened': true,
              'customer': 'jd_canonical',
              'rowKey': 'shape-a',
              'identityProof': 'selected_row_and_stable_ax_header'
            };
          case 'openConversation':
            expect((call.arguments as Map)['expectedCustomer'], 'jd_canonical');
            return {'opened': true, 'customer': 'jd_canonical'};
          case 'captureViewportEvidence':
            throw PlatformException(code: 'snapshot_chat_missing');
          case 'sendDraftOnce':
            if (unknownAge) expect(mono, greaterThanOrEqualTo(20000));
            expect(DateTime.now().toUtc().difference(started).inMilliseconds,
                lessThan(10000),
                reason:
                    'already overdue red clock must dispatch without starting a new timer');
            final args = call.arguments as Map;
            expect(args['expectedCustomer'], 'jd_canonical');
            expect(isHoldingReply(args['reply']), isTrue);
            sent++;
            return {'sent': true};
          case 'inspectOcr':
          case 'inspectViewportEvidence':
            fail('SLA identity discovery must not wait for OCR');
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              redClockTracker: RedClockTracker(monotonicMs: () => mono),
              adapter: MacOSCaptureAdapter(channel: channel),
              draftSchedulerOverride: (_) {})));
      await grantRunPermissions(tester);
      await tester.tap(find.text('Start automation'));
      Map<String, dynamic>? history;
      for (var i = 0; i < 240; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          history = await (await db.history).read('jd_canonical');
        });
        mono += 100;
        await tester.pump(const Duration(milliseconds: 100));
        if ((history?['messages'] as List? ?? const []).isNotEmpty) break;
      }
      expect(sent, 1,
          reason:
              'An already 21-second-old unread must not get a new 20-second clock on binding. Calls: $calls; UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}');
      await tester.runAsync(() async {
        final observed =
            await CaptureEvidenceStore(db).firstObserved('jd_canonical');
        expect(observed, isNotNull);
        if (!unknownAge) {
          expect(
              observed!.isBefore(started.subtract(const Duration(seconds: 11))),
              isTrue);
        }
        expect(await (await db.history).read('pending-row:shape-a'), isNull);
        expect(await db.pendingMessageId('pending-row:shape-a'), isNull);
      });
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 25));
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
