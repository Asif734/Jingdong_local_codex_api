import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';
import 'package:jd_automation/ui/customer_message_timeline.dart';

void main() {
  testWidgets('a recovering message is never displayed as no message received',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CustomerMessageTimeline(
                customer: 'buyer', records: [], recoveringCount: 2))));
    expect(
        find.byKey(const ValueKey('timeline-admission-gaps')), findsOneWidget);
    expect(find.text('该客户本轮暂无消息记录'), findsNothing);
    expect(find.text('正在恢复消息记录，尚未正式回复'), findsOneWidget);
    expect(find.text('已回复'), findsNothing);
  });

  testWidgets('a proved admission gap stays visible and is not double counted',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    const customer = 'jd_recovering_customer';
    const channel = MethodChannel('jd-v45-pending-visibility');
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v45_visibility_');
      db = CaptureDatabase(storageRoot: root);
      final at = DateTime.now().toUtc();
      final session = await db.beginAutomationSession(
          startedAt: at.subtract(const Duration(seconds: 1)));
      final audit = MediaCaptureAudit(db, record: (_, __) {});
      for (var i = 0; i < 2; i++) {
        final frame = ViewportEvidence({
          'evidenceId': 'image-$i',
          'customer': customer,
          'capturedAtMs': at.millisecondsSinceEpoch,
          'imagePath': '${root.path}/image-$i.png',
          'manifestPath': '${root.path}/image-$i.json',
          'automationSessionId': session,
          'replyActivationAllowed': true,
          'capturePurpose': 'live_signal',
          'unreadArrivalKey': 'proved-arrival-$i',
        });
        final observation = await audit.discover(
            frame,
            const OcrVisualRegion(
                x: .27, y: .4, width: .1, height: .2, confidence: 1));
        await audit.rememberLiveArrival(observation,
            evidence: frame,
            occurrenceKey: 'bubble:$observation',
            arrivalKey: 'proved-arrival-$i',
            senderAt: at,
            slot: 0);
      }
      expect(await db.unansweredWorkCounts(), isEmpty);
      expect(await audit.pendingAdmissionGaps(), hasLength(2));
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'trusted': true};
      if (call.method == 'sendDraftOnce' || call.method == 'openConversation') {
        fail('Pending visibility cannot open or send to a real customer.');
      }
      return <String, Object?>{};
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await db.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db, adapter: MacOSCaptureAdapter(channel: channel))));
    Future<void> refreshUntil(bool Function() done) async {
      for (var n = 0; n < 200 && !done(); n++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(done(), isTrue);
    }

    await refreshUntil(() => find
        .byKey(const ValueKey('pending-admission-gaps'))
        .evaluate()
        .isNotEmpty);
    expect(find.text('当前没有待回复问题'), findsNothing);
    expect(find.byKey(const ValueKey('unanswered-customer:$customer')),
        findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('1 位客户 · 2 条待回复消息'), findsOneWidget);
    await tester.runAsync(() async {
      final result = await MediaMessageRegistrar(db)
          .recoverPendingAdmissions(customer: customer);
      expect(result.createdAdmissions, hasLength(2));
      expect(await db.unansweredWorkCounts(), {customer: 2});
      expect(await MediaCaptureAudit(db).pendingAdmissionGaps(), isEmpty);
    });
    await tester.tap(find.byTooltip('Refresh connection status'));
    await refreshUntil(() {
      final count = find.byKey(const ValueKey('unanswered-count:$customer'));
      return find
              .byKey(const ValueKey('pending-admission-gaps'))
              .evaluate()
              .isEmpty &&
          count.evaluate().isNotEmpty &&
          tester.widget<Text>(count).data == '2 条';
    });
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('2 条待恢复'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  });
}
