import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

void main() {
  testWidgets('Stop/Start stale unread clock cannot claim the new red deadline',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('v29_resume_notice_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
    });
    const channel = MethodChannel('v29.resume-notice');
    var mono = 0;
    int? badgeAge = 19;
    var activatedOpens = 0;
    var sends = 0;
    final adapter = MacOSCaptureAdapter(channel: channel);
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
              'unread': true,
              'unreadEvidence': 20,
              'unreadAgeSeconds': badgeAge,
              'redClockPresent': true,
              'evidenceAvailable': true,
            }
          ];
        case 'openConversation':
          if ((call.arguments as Map)['allowActivation'] == true) {
            activatedOpens++;
          }
          return {'opened': true, 'customer': 'buyer'};
        case 'captureViewportEvidence':
          throw PlatformException(code: 'snapshot_chat_missing');
        case 'sendDraftOnce':
          sends++;
          return {'sent': true};
      }
      return <String, Object?>{};
    });
    Future<void> settle([int steps = 12]) async {
      for (var i = 0; i < steps; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: adapter,
            redClockTracker: RedClockTracker(monotonicMs: () => mono),
            draftSchedulerOverride: (_) {})));
    await grantRunPermissions(tester);
    await tester.tap(find.text('Start automation'));
    Map<String, Object?>? firstCycle;
    for (var i = 0; i < 200 && firstCycle == null; i++) {
      await settle(1);
      firstCycle = await tester.runAsync<Map<String, Object?>?>(
          () => db.platformResponseCycle('buyer'));
    }
    expect(firstCycle, isNotNull);
    await tester.tap(find.text('Stop automation'));
    await settle();
    mono += 60000;
    await tester.pump(const Duration(seconds: 60));
    badgeAge = null;
    final resumedAt = DateTime.now();
    final opensBeforeResume = activatedOpens;
    final sendsBeforeResume = sends;
    final oldSession = db.currentAutomationSessionId;
    await tester.tap(find.text('Start automation'));
    for (var i = 0;
        i < 100 && db.currentAutomationSessionId == oldSession;
        i++) {
      await settle(1);
    }
    expect(db.currentAutomationSessionId, isNot(oldSession));
    Map<String, Object?>? resumed;
    for (var i = 0; i < 100 && resumed == null; i++) {
      await settle(1);
      resumed = await tester.runAsync<Map<String, Object?>?>(
          () => db.platformResponseCycle('buyer'));
    }
    expect(resumed, isNotNull);
    expect(resumed!['state'], 'waiting');
    expect(resumed['started_at_ms'],
        greaterThanOrEqualTo(resumedAt.millisecondsSinceEpoch - 100));
    await tester.runAsync(() async {
      expect(
          await (await db.database).query('automation_work_archive',
              where: 'table_name=?', whereArgs: ['platform_response_cycles']),
          isNotEmpty);
    });
    for (var i = 0; i < 5; i++) {
      mono += 1000;
      await tester.pump(const Duration(seconds: 1));
      await settle(3);
    }
    expect(activatedOpens, opensBeforeResume,
        reason: 'Old unread/recovery clocks cannot take a new response lease');
    expect(sends, sendsBeforeResume);
    await tester.tap(find.text('Stop automation'));
    await settle();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
