import 'helpers/run_permissions.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  testWidgets(
      'Start archives a previous run backfill without navigating old business',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    const channel = MethodChannel('jd-main-backfill-test');
    final calls = <String>[];
    var restored = false;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_main_backfill_');
      db = CaptureDatabase(storageRoot: root);
      await CaptureEvidenceStore(db)
          .requestBackfill('test-customer', DateTime.now());
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [];
        case 'openConversation':
          return {'opened': true, 'activeCustomerId': 'test-customer'};
        case 'scrollConversation':
          if ((args['deltaY'] as num) < 0) {
            restored = true;
          }
          return {'scrolled': true};
        case 'captureViewportEvidence':
          if (args['historyCutoffMs'] == null) {
            return {'error': 'snapshot_chat_missing'};
          }
          final directory = Directory(args['directory'] as String);
          await directory.create(recursive: true);
          final metadata = {
            'evidenceId': 'test-frame',
            'customer': 'test-customer',
            'imagePath': '${directory.path}/test-frame.png',
            'manifestPath': '${directory.path}/test-frame.json',
            'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
            'historyCutoffMs': args['historyCutoffMs']
          };
          await File(metadata['imagePath']! as String).writeAsBytes([1, 2, 3]);
          await File(metadata['manifestPath']! as String)
              .writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          return {
            'activeCustomerId': 'test-customer',
            'observations': [],
            'visualRegions': []
          };
        case 'sendDraftOnce':
          fail('Backfill test must never send a customer reply');
      }
      return <String, Object?>{};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    await tester.pumpWidget(
        MaterialApp(home: CaptureHome(database: db, adapter: adapter)));
    await grantRunPermissions(tester);
    await tester.tap(find.text('Start automation'));
    for (var i = 0; i < 100 && !restored; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(restored, isFalse);
    expect(calls, isNot(contains('scrollConversation')));
    expect(calls, isNot(contains('openConversation')));
    expect(calls.where((c) => c == 'inspectOCR'), isEmpty);
    await tester.runAsync(() async {
      final store = CaptureEvidenceStore(db);
      expect(await store.pendingBackfills(), isEmpty);
      final sql = await db.database;
      expect((await sql.query('capture_backfill')).single['state'],
          'session_archived');
      expect(
          await sql.query('capture_session_archive',
              where: 'table_name=?', whereArgs: ['capture_backfill']),
          isNotEmpty);
    });
    await tester.tap(find.text('Stop automation'));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
