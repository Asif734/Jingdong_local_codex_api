import 'package:jd_automation/runtime/automation_settings.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/direct_reply_delivery.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an allocated holding attempt rejected before native send can recover',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v59_uninvoked_');
    final db = CaptureDatabase(
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 20, transferRequestCount: 2),
        storageRoot: root);
    const channel = MethodChannel('jd.v59.uninvoked-holding');
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(() async {
      await adapter.close();
      await db.close();
      await root.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      fail('Expired pre-native delivery must not invoke ${call.method}');
    });
    final now = DateTime.now().toUtc();
    final start = now.subtract(const Duration(seconds: 21));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: start,
        messages: [
          CapturedMessage(
              stableId: 'question',
              direction: 'incoming',
              body: 'How do I replace the ribbon?',
              sentAt: start,
              axPath: 'fixture')
        ]));
    await db.observePlatformResponse('buyer', red: true, observedAt: start);
    final job = (await db.slaFallbackJob('buyer'))!;
    expect(
        await db.reserveSlaFallback(
            userId: job.userId,
            messageId: job.messageId,
            dueAt: job.dueAt,
            requireDue: true),
        isTrue);
    final attempt =
        await db.beginSlaAttempt(job, 'I am checking this for you.');
    final delivery = DirectReplyDelivery(adapter, now: () => now);
    late PlatformException failure;
    try {
      await delivery.sendConfirmed(
          customer: 'buyer',
          reply: 'I am checking this for you.',
          attemptId: attempt['attemptId'],
          receiptPath: attempt['receiptPath'],
          requireRedClock: true,
          preClickDeadline: now);
      fail('Expired budget should stop before invoking native send');
    } on PlatformException catch (error) {
      failure = error;
    }
    expect(failure.code, 'send_preclick_budget_exceeded');
    expect(failure.details, containsPair('nativeInvoked', false));
    expect(failure.details, containsPair('clickDispatched', false));
    expect(failure.details, containsPair('sendStage', 'before_native_send'));
    expect(calls, isEmpty);
    expect(await File(attempt['receiptPath']!).exists(), isFalse);

    await db.releaseSlaFallback(
        userId: 'buyer',
        messageId: job.messageId,
        expectedAttemptId: attempt['attemptId'],
        nativeNotInvoked: true,
        retryDelay: Duration.zero);
    final attempts = await (await db.database).query('delivery_attempts',
        where: 'attempt_id=?', whereArgs: [attempt['attemptId']]);
    expect(attempts.single['state'], 'not_sent');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);

    await db.observePlatformResponse('buyer', red: false, observedAt: now);
    await db.observePlatformResponse('buyer',
        red: true, observedAt: now.add(const Duration(seconds: 1)));
    final next = (await db.slaFallbackJob('buyer'))!;
    expect(next.messageId, isNot(job.messageId));
    expect(await db.isPlatformResponsePending(next), isTrue);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(calls, isEmpty);
  });
}
