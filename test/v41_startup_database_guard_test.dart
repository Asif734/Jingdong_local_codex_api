import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

class _ReadinessDatabase extends CaptureDatabase {
  _ReadinessDatabase({required super.storageRoot, required this.broken});
  bool broken;
  int checks = 0;

  @override
  Future<void> ensureAutomationSchemaReady() async {
    checks++;
    await super.ensureAutomationSchemaReady();
    if (broken) {
      throw StateError('database_schema_incompatible: required message field');
    }
  }
}

void main() {
  for (final brokenAtMount in [true, false]) {
    testWidgets(
        'database readiness blocks Start before JD operations: '
        'initiallyBroken=$brokenAtMount', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late _ReadinessDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_v41_start_guard_');
        db = _ReadinessDatabase(storageRoot: root, broken: brokenAtMount);
        await db.database;
      });
      final channel = MethodChannel('v41.startup.guard.$brokenAtMount');
      final operations = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        operations.add(call.method);
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
          case 'sendDraftOnce':
            fail('No real business is injected by this readiness test.');
        }
        return <String, Object?>{};
      });
      Future<void> tick([int count = 1]) async {
        for (var i = 0; i < count; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      FilledButton start() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Start automation'));
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              draftSchedulerOverride: (_) {})));
      await tick(20);
      if (!brokenAtMount) {
        await grantRunPermissions(tester);
        expect(start().onPressed, isNotNull);
        db.broken = true;
        await tester.runAsync(() => tester.tap(find.text('Start automation')));
      } else {
        expect(start().onPressed, isNull);
        await tester.runAsync(() => tester.tap(find.text('授权所需权限')));
      }
      await tick(20);
      // Technical exceptions remain recorded for the stopped-run report.
      expect(find.textContaining('数据库初始化失败，自动化未启动'), findsNothing);
      expect(start().onPressed, isNull);
      expect(db.currentAutomationSessionId, isNull);
      expect(operations, isNot(contains('ensureReceptionWindow')));
      expect(operations, isNot(contains('setAutomationEpoch')));
      expect(operations, isNot(contains('sendDraftOnce')));

      db.broken = false;
      await tester.runAsync(
          () => tester.tap(find.byTooltip('Refresh connection status')));
      await tick(20);
      await grantRunPermissions(tester);
      expect(start().onPressed, isNotNull);
      expect(find.textContaining('数据库初始化失败，自动化未启动'), findsNothing);
      expect(db.checks, greaterThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tick(5);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
    }, skip: !Platform.isMacOS);
  }
}
