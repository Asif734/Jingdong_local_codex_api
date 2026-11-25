import 'helpers/run_permissions.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  for (final legacy in [false, true]) {
    testWidgets(
        legacy
            ? 'startup parks old process row references without UI retries'
            : 'a new unread starts recovery while the archived old draft stays unsent',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      var newUnread = false;
      var sends = 0;
      var invalidOpens = 0;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_new_unread_');
        db = CaptureDatabase(storageRoot: root);
        final now = DateTime.now().toUtc();
        if (legacy) {
          await CaptureEvidenceStore(db).observe('pending-row:previous-process',
              now.subtract(const Duration(minutes: 1)));
        } else {
          await db.saveCapture(CapturedConversation(
              stableKey: 'customer:buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              capturedAt: now,
              messages: [
                CapturedMessage(
                    stableId: 'old',
                    direction: 'incoming',
                    body: 'old question',
                    sentAt: now.subtract(const Duration(seconds: 4)),
                    axPath: 'ocr:test')
              ]));
          final pending = (await db.conversations()).single;
          await db.saveDraft(
              pending.id,
              const AiDraft(
                  reply: 'old answer',
                  decision: 'draft',
                  confidence: 1,
                  riskLevel: 'low',
                  model: 'test',
                  usedRecordIds: [],
                  actions: [],
                  attachments: [],
                  rawJson:
                      '{"reply":"old answer","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}'),
              expectedMessageId: 'old');
          await CaptureEvidenceStore(db)
              .observe('buyer', now.subtract(const Duration(seconds: 1)));
        }
      });
      final channel = MethodChannel('jd.new-unread.$legacy');
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
            return legacy
                ? []
                : [
                    {
                      'customer': 'buyer',
                      'identitySource': 'ax',
                      'unread': newUnread,
                      'unreadEvidence': 12,
                      'unreadAgeSeconds': null
                    }
                  ];
          case 'captureViewportEvidence':
            return {'error': 'snapshot_chat_missing'};
          case 'openConversationRow':
            invalidOpens++;
            return {'error': 'row_reference_expired'};
          case 'openConversation':
            final args = call.arguments as Map;
            if (args['expectedCustomer']
                .toString()
                .startsWith('pending-row:')) {
              invalidOpens++;
            }
            return {'opened': true, 'customer': 'buyer'};
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
      await tester.tap(find.text('Start automation'));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      if (!legacy) {
        expect(sends, 0, reason: 'Start must archive the previous run draft');
        await tester.runAsync(() async {
          expect(await db.nextReadyDelivery(), isNull);
          expect(await db.answeredMessageId('buyer'), isNull);
        });
        newUnread = true;
        // Advance the poll timer; a null unread-age OCR must not keep the
        // customer suppressed as already processed after the old send.
        await tester.pump(const Duration(seconds: 2));
        var recovered = false;
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            final rows = await (await db.database).query('capture_observations',
                where: 'customer=?', whereArgs: ['buyer']);
            recovered = rows.isNotEmpty && rows.single['state'] == 'observed';
          });
          await tester.pump();
          if (recovered) break;
        }
        expect(recovered, isTrue,
            reason: 'fresh red badge must reopen recovery without timer OCR');
        expect(sends, 0,
            reason: 'new unread must not replay an archived old answer');
      } else {
        expect(find.textContaining('row_reference_expired'), findsNothing);
        expect(invalidOpens, 0);
        expect(sends, 0);
      }
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 15; i++) {
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
