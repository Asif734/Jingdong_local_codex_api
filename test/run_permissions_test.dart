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
      'Start stays disabled through pending/denied permissions and rechecks revocation',
      (tester) async {
    tester.view.physicalSize = const Size(813, 616);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_permissions_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
    });
    const channel = MethodChannel('jd-permissions-regression');
    final pending = Completer<Map<String, Object?>>();
    var requests = 0;
    var permissionStillValid = true;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'status':
          return {'trusted': true};
        case 'prepareRunPermissions':
          requests++;
          if (requests == 1) return pending.future;
          return {'ready': true, 'message': '所需权限已就绪，可以开始。'};
        case 'runPermissionsStatus':
          return {'ready': permissionStillValid};
        case 'ensureReceptionWindow':
          fail(
              'Permission checks must finish before any customer window operation.');
        case 'sendDraftOnce':
          fail('No customer send is allowed in this permissions test.');
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db, adapter: MacOSCaptureAdapter(channel: channel))));
    FilledButton start() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start automation'));
    expect(start().onPressed, isNull);
    expect(calls, isNot(contains('prepareRunPermissions')),
        reason: 'No permissions prompt at launch.');
    await tester.tap(find.text('授权所需权限'));
    for (var i = 0; i < 100 && requests == 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump();
    expect(requests, 1);
    expect(start().onPressed, isNull);
    expect(find.text('正在授权…'), findsOneWidget);
    pending.complete({'ready': false, 'message': '请允许屏幕录制后重新检查'});
    await tester.pump();
    await tester.pump();
    expect(start().onPressed, isNull);
    expect(find.textContaining('请允许屏幕录制'), findsWidgets);
    await grantRunPermissions(tester);
    expect(start().onPressed, isNotNull);
    expect(find.text('权限已就绪'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'Header buttons must fit the current 813px app window.');
    permissionStillValid = false;
    final checksBefore =
        calls.where((method) => method == 'runPermissionsStatus').length;
    await tester.tap(find.text('Start automation'));
    // Start first verifies the existing database, then checks permissions.
    // Pump the real async checks instead of assuming two microtask turns.
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find.text('Start automation').evaluate().isNotEmpty &&
          calls.where((method) => method == 'runPermissionsStatus').length >
              checksBefore) {
        break;
      }
    }
    expect(calls.where((method) => method == 'runPermissionsStatus').length,
        greaterThan(checksBefore));
    expect(start().onPressed, isNull);
    expect(calls, isNot(contains('ensureReceptionWindow')));
    expect(calls, isNot(contains('sendDraftOnce')));
    expect(requests, 2,
        reason:
            'Start must only check status, never open a new authorization prompt.');
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);

  test('video audio runtime has no authorization request side effect', () {
    final source =
        File('macos/Runner/AccessibilityBridge.swift').readAsStringSync();
    final runtime = source.substring(
        source.indexOf('final class VideoAudioTranscriber'),
        source.indexOf('final class QianniuOCRInspector'));
    expect(runtime, isNot(contains('requestAuthorization')));
    expect(runtime, contains('authorizationStatus() == .authorized'));
  });
}
