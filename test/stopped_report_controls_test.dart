import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

void main() {
  testWidgets('export only after stop and settings lock for entire run',
      (tester) async {
    tester.view.physicalSize = const Size(814, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_report_controls_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
    });
    const channel = MethodChannel('jd.report.controls.test');
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
          return <Object>[];
        case 'captureViewportEvidence':
          throw PlatformException(code: 'snapshot_chat_missing');
        case 'flushDiagnosticTrace':
          return null;
        case 'sendDraftOnce':
          fail('No real customer sends in UI test.');
      }
      return <String, Object?>{};
    });
    Future<void> tick([int n = 20]) async {
      for (var i = 0; i < n; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            reportOutputDirectory: Directory('${root.path}/exports'),
            adapter: MacOSCaptureAdapter(channel: channel),
            draftSchedulerOverride: (_) {})));
    await tick();
    expect(find.byKey(const ValueKey('message-timeline-pane')), findsNothing);
    expect(
        find.byKey(const ValueKey('unanswered-customers-pane')), findsNothing);
    expect(find.text('消息时间线'), findsNothing);
    expect(find.text('待回复客户'), findsNothing);
    final export = find.byKey(const ValueKey('export-stopped-report'));
    final holding = find.byKey(const ValueKey('holding-seconds'));
    expect(find.byKey(const ValueKey('transfer-request-count')), findsNothing);
    expect(tester.widget<OutlinedButton>(export).onPressed, isNull);
    expect(tester.widget<TextField>(holding).controller!.text, '50');
    await grantRunPermissions(tester);
    await tick();
    await tester.enterText(holding, '19');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start automation'))
            .onPressed,
        isNull);
    await tester.enterText(holding, '60');
    await tick();
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    await tick(40);
    expect(find.text('Stop automation'), findsOneWidget);
    expect(tester.widget<TextField>(holding).enabled, false);
    expect(tester.widget<OutlinedButton>(export).onPressed, isNull);
    expect(db.holdingDelay, const Duration(seconds: 60));
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    await tick();
    expect(find.text('Start automation'), findsOneWidget);
    expect(tester.widget<TextField>(holding).enabled, true);
    expect(tester.widget<OutlinedButton>(export).onPressed, isNotNull);
    await tester.runAsync(() => tester.tap(export));
    await tick(50);
    final files = await tester
        .runAsync(() => Directory('${root.path}/exports').list().toList());
    expect(files!.whereType<File>().where((f) => f.path.endsWith('.zip')),
        hasLength(1));
    expect(files.whereType<Directory>(), hasLength(1));
    expect(files.whereType<File>().single.path,
        startsWith('${root.path}/exports/jd-report-'));
    expect(find.textContaining('报告已导出：'), findsOneWidget);
    expect(find.textContaining('Error:'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tick(5);
    await tester.runAsync(() => db.close());
    // Reopening the application reads the last values from disk, not defaults.
    final reopened = CaptureDatabase(storageRoot: root);
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: reopened,
            adapter: MacOSCaptureAdapter(channel: channel),
            draftSchedulerOverride: (_) {})));
    await tick();
    expect(tester.widget<TextField>(holding).controller!.text, '60');
    expect(tester.widget<TextField>(holding).enabled, true);
    await tester.pumpWidget(const SizedBox());
    await tick(5);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await tester.runAsync(() async {
      await reopened.close();
      await root.delete(recursive: true);
    });
  }, skip: !Platform.isMacOS);
}
