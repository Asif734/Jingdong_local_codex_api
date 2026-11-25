import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

void main() {
  testWidgets(
      'new red clock is persisted while another customer holds the send UI lease',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_red_while_sending_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
    });
    const channel = MethodChannel('jd.red-monitor-lease');
    final opened = Completer<Map<String, Object?>>();
    var opening = false;
    var sent = 0;
    var concurrentReads = 0;
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
          if (opening && !opened.isCompleted) concurrentReads++;
          return [
            {
              'customer': 'a',
              'identitySource': 'ax',
              'unread': sent == 0,
              'unreadAgeSeconds': sent == 0 ? 21 : null,
              'redClockPresent': sent == 0,
              'evidenceAvailable': true
            },
            if (opening)
              {
                'customer': 'b',
                'identitySource': 'ax',
                'unread': true,
                'redClockPresent': true,
                'evidenceAvailable': true
              }
          ];
        case 'openConversation':
          opening = true;
          return opened.future;
        case 'sendDraftOnce':
          sent++;
          return {'sent': true};
        case 'captureViewportEvidence':
          throw PlatformException(code: 'snapshot_chat_missing');
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
    Map<String, Object?>? cycle;
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        cycle = await db.platformResponseCycle('b');
      });
      await tester.pump(const Duration(milliseconds: 100));
      if (cycle != null && concurrentReads > 0) break;
    }
    expect(opening, isTrue);
    expect(opened.isCompleted, isFalse);
    expect(concurrentReads, greaterThan(0));
    expect(cycle?['state'], 'waiting');
    expect(cycle?['identity_verified'], 1);
    opened.complete({'opened': true, 'customer': 'a'});
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
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
