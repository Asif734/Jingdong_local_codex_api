import 'helpers/run_permissions.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  testWidgets(
      'persistent unresolved row is rate limited across capture and SLA; stop cancels retries',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_row_budget_');
      db = CaptureDatabase(storageRoot: root);
    });
    const channel = MethodChannel('jd.main-row-budget');
    var opens = 0;
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
              'identitySource': 'row_anchor',
              'rowKey': 'a',
              'rowToken': 'a',
              'unread': true,
              'unreadEvidence': 12,
              'unreadAgeSeconds': 13
            }
          ];
        case 'openConversationRow':
          opens++;
          return {'error': 'row_changed', 'openStage': 'row_reference'};
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'sendDraftOnce':
          fail('Unconfirmed customer must never be sent a reply.');
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
    for (var i = 0; i < 130; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(opens, inInclusiveRange(1, 2),
        reason:
            'capture and deadline must share retry delay instead of independently opening rows');
    await tester.tap(find.text('Stop automation'));
    final stoppedAt = opens;
    await tester.pump(const Duration(seconds: 40));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(opens, stoppedAt);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
