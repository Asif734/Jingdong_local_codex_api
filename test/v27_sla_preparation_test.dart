import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

void main() {
  testWidgets(
      'prepare confirmed customer before twenty seconds without sending early',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('v27_prepare_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
    });
    const channel = MethodChannel('v27.prepare');
    var mono = 0;
    int? openedAt;
    int? sentAt;
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
              'redClockPresent': sentAt == null,
              'evidenceAvailable': true
            }
          ];
        case 'openConversation':
          openedAt ??= mono;
          return {'opened': true, 'customer': 'buyer'};
        case 'sendDraftOnce':
          sentAt = mono;
          return {'sent': true};
        case 'captureViewportEvidence':
          throw PlatformException(code: 'snapshot_chat_missing');
        case 'inspectOcr':
        case 'inspectViewportEvidence':
          fail('Preparing/sending holding must never wait for OCR');
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
    for (var i = 0; i < 250; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      mono += 100;
      await tester.pump(const Duration(milliseconds: 100));
      if (sentAt != null) break;
    }
    expect(openedAt, isNotNull);
    expect(openedAt, lessThan(20000));
    expect(openedAt, greaterThanOrEqualTo(14000));
    expect(sentAt, greaterThanOrEqualTo(20000));
    await tester.tap(find.text('Stop automation'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
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
