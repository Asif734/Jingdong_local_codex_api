import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  testWidgets(
      'sidebar shows exact customer IDs and durable unanswered counts, not transfers',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late CaptureDatabase db;
    final now = DateTime.now().toUtc();
    Future<void> add(String customer, String id) async {
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: switch (id) {
                  'a1' => 'How do I connect Bluetooth?',
                  'a2' => 'Which paper size is supported?',
                  'a3' => 'How long is the warranty?',
                  _ => 'The print is blank.',
                },
                sentAt: now,
                sender: customer,
                axPath: 'test:$id')
          ]));
    }

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v35_sidebar_');
      db = CaptureDatabase(storageRoot: root);
      await db.beginAutomationSession(
          startedAt: now.subtract(const Duration(seconds: 1)));
      await add('jd_customer_A', 'a1');
      await add('jd_customer_A', 'a2');
      await add('jd_customer_B', 'b1');
      expect(await db.unansweredWorkCounts(),
          {'jd_customer_A': 2, 'jd_customer_B': 1});
    });
    const channel = MethodChannel('jd-v35-sidebar');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'trusted': true};
      if (call.method == 'sendDraftOnce' || call.method == 'openConversation') {
        fail('A read-only pending sidebar must never send or open a customer.');
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db, adapter: MacOSCaptureAdapter(channel: channel))));
    Future<void> settle() async {
      for (var n = 0; n < 100; n++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    await settle();
    expect(find.text('Transfer records'), findsNothing);
    expect(find.text('待回复客户'), findsOneWidget);
    expect(find.text('jd_customer_A'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '));
    expect(find.text('jd_customer_B'), findsOneWidget);
    Text count(String c) =>
        tester.widget<Text>(find.byKey(ValueKey('unanswered-count:$c')));
    expect(count('jd_customer_A').data, '2 条');
    expect(count('jd_customer_B').data, '1 条');
    await tester.runAsync(() => add('jd_customer_A', 'a3'));
    await tester.tap(find.byTooltip('Refresh connection status'));
    await settle();
    expect(count('jd_customer_A').data, '3 条');
    expect(count('jd_customer_B').data, '1 条');
    expect(find.textContaining('兜底不计为答复'), findsOneWidget);
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
