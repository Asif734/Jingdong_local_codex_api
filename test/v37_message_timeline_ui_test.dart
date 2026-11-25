import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  testWidgets('center customer selection only reads its left message timeline',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    final at = DateTime.utc(2026, 11, 8, 2, 26, 1);
    final screenshot = Platform.environment['JD_UI_SCREENSHOT_PATH'];
    if (screenshot != null) {
      await tester.runAsync(() async {
        final font = FontLoader('JDPreview');
        font.addFont(File('/System/Library/Fonts/STHeiti Light.ttc')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
        await font.load();
      });
    }
    Future<void> incoming(String customer, String id, String text) => db
        .saveCapture(CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            capturedAt: at,
            automationSessionId: db.currentAutomationSessionId,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: text,
                  sentAt: at,
                  axPath: 'controlled-real-bubble:$id')
            ]))
        .then((_) {});
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v37_timeline_ui_');
      db = CaptureDatabase(storageRoot: root);
      await db.beginAutomationSession(
          startedAt: at.subtract(const Duration(seconds: 1)));
      await incoming('customer_A', 'first-real-bubble', 'How do I load paper?');
      final queued = (await db.conversation('customer_A'))!;
      final token = await db.beginGeneration(
          customer: 'customer_A',
          pendingId: queued.id,
          batchEndMessageId: 'first-real-bubble');
      final reply = AiDraft.fromJson({
        'reply': 'Load the paper straight and close the cover.',
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-ui-fixture',
        'auto_send_allowed': false,
      }, mediaBaseUrl: Uri());
      await db.saveDraft(queued.id, reply,
          expectedMessageId: 'first-real-bubble', generationToken: token);
      final attempt = await db.beginDeliveryAttempt(
          userId: 'customer_A', reply: reply.reply);
      final clickedAt = DateTime.now().millisecondsSinceEpoch;
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'customer_A',
        'state': 'submitted',
        'sendClickedAtMs': clickedAt,
        'timeMs': clickedAt,
      }));
      await db.recoverDeliveryReceipts();
      await db.abandonGeneration('customer_A', token!);
      await incoming(
          'customer_A', 'second-real-bubble', 'Which button feeds paper?');
      await incoming(
          'customer_B', 'other-customer-bubble', 'How do I connect USB?');
    });
    const channel = MethodChannel('jd-v37-timeline-ui');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'trusted': true};
      if (call.method == 'openConversation' || call.method == 'sendDraftOnce') {
        fail('Selecting a record must not manipulate a JD conversation.');
      }
      return <String, Object?>{};
    });
    const boundaryKey = ValueKey('timeline-ui-screenshot');
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            fontFamily: screenshot == null ? null : 'JDPreview',
            colorSchemeSeed: const Color(0xfff26b21),
            useMaterial3: true),
        home: RepaintBoundary(
            key: boundaryKey,
            child: CaptureHome(
                database: db,
                adapter: MacOSCaptureAdapter(channel: channel)))));
    Future<void> settle() async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)));
        await tester.pump();
      }
    }

    await settle();
    final center = find.byKey(const ValueKey('unanswered-customers-pane'));
    final left = find.byKey(const ValueKey('message-timeline-pane'));
    expect(tester.getCenter(center).dx, greaterThan(tester.getCenter(left).dx));
    expect(find.text('Transfer records'), findsNothing);
    expect(find.text('消息时间线'), findsOneWidget);
    final a = find.byKey(const ValueKey('unanswered-customer:customer_A'));
    expect(find.descendant(of: center, matching: a), findsOneWidget);
    await tester.tap(a);
    await settle();
    expect(find.byKey(const ValueKey('message-record:first-real-bubble')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('message-record:second-real-bubble')),
        findsOneWidget);
    expect(find.text('已回复'), findsOneWidget);
    expect(find.text('待回复'), findsOneWidget);
    final firstReply = tester.widget<Text>(
        find.byKey(const ValueKey('message-replied:first-real-bubble')));
    expect(firstReply.data, isNot('回复 —'));
    expect(
        tester
            .widget<Text>(find
                .byKey(const ValueKey('message-replied:second-real-bubble')))
            .data,
        '回复 —');
    expect(find.text('How do I connect USB?'), findsNothing);
    expect(tester.takeException(), isNull);
    if (screenshot != null) {
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(screenshot).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester
        .tap(find.byKey(const ValueKey('unanswered-customer:customer_B')));
    await settle();
    expect(find.text('How do I connect USB?'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-record:first-real-bubble')),
        findsNothing);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(814, 600);
    await tester.pump();
    expect(find.byKey(const ValueKey('message-timeline-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('unanswered-customers-pane')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
