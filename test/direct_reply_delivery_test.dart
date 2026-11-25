import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/direct_reply_delivery.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/runtime/app_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.direct-delivery.test');
  late MacOSCaptureAdapter adapter;
  late DirectReplyDelivery delivery;
  late List<String> calls;
  late List<Map<String, Object?>> events;
  late Future<Object?> Function(MethodCall) handle;
  setUp(() {
    calls = [];
    events = [];
    handle = (call) async {
      if (call.method == 'openConversation') {
        expect((call.arguments as Map)['allowActivation'], isTrue);
        return {'opened': true, 'activeCustomerId': 'jd_customer'};
      }
      if (call.method == 'sendDraftOnce') {
        expect((call.arguments as Map)['expectedCustomer'], 'jd_customer');
        return {'sent': true};
      }
      fail('Unexpected send-path operation: ${call.method}');
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return handle(call);
    });
    adapter = MacOSCaptureAdapter(channel: channel);
    delivery = DirectReplyDelivery(adapter, record: (event, fields) {
      events.add({'event': event, ...fields});
    });
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('open, revalidate, send, and confirm with no OCR calls', () async {
    expect(
        await delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async {
              expect(calls, ['openConversation']);
              return true;
            }),
        isTrue);
    expect(calls, ['openConversation', 'sendDraftOnce']);
    expect(events.map((e) => e['event']),
        ['delivery.conversation_opened', 'delivery.direct_send_confirmed']);
    expect(events.last['sent'], isTrue);
    expect(events.every((e) => e['elapsedMs'] is int), isTrue);
  });

  test('a timed-out native OCR still running cannot block a generated reply',
      () async {
    final pending = Completer<Map<String, Object?>>();
    final ordinary = handle;
    handle =
        (call) => call.method == 'inspectOCR' ? pending.future : ordinary(call);
    final ocr = adapter.inspectOcr(windowId: 7);
    await expectLater(
        ocr.timeout(Duration.zero), throwsA(isA<TimeoutException>()));
    expect(identical(ocr, adapter.inspectOcr(windowId: 7)), isTrue);
    expect(
        await delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async => true),
        isTrue);
    expect(pending.isCompleted, isFalse);
    expect(calls, ['inspectOCR', 'openConversation', 'sendDraftOnce']);
    final discarded = expectLater(ocr, throwsA(isA<PlatformException>()));
    pending.complete({'error': 'customer_changed_during_capture'});
    await discarded;
    expect(events.last['event'], 'delivery.direct_send_confirmed');
  });

  test('invalidated draft or human takeover after opening vetoes sending',
      () async {
    expect(
        await delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async => false),
        isFalse);
    expect(calls, ['openConversation']);
    expect(events.last['event'], 'delivery.skipped');
  });

  test('opening failure is logged separately and never clicks Send', () async {
    handle = (_) async => {'error': 'conversation_not_found'};
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async => true),
        throwsA(isA<PlatformException>()));
    expect(calls, ['openConversation']);
    expect(events.last['stage'], 'open_conversation');
    expect(events.last['errorCode'], 'conversation_not_found');
  });

  for (final code in [
    'composer_not_empty',
    'composer_not_settable',
    'pre_send_verification_failed',
    'final_customer_verification_failed',
    'send_not_committed',
    'send_platform_rejected',
    'customer_not_receiving',
    'send_unconfirmed'
  ]) {
    test('native safeguard $code remains a failure without confirmed-send log',
        () async {
      final ordinary = handle;
      handle = (call) async =>
          call.method == 'sendDraftOnce' ? {'error': code} : ordinary(call);
      await expectLater(
          delivery.deliver(
              customer: 'jd_customer',
              reply: 'Answer',
              canSend: () async => true),
          throwsA(isA<PlatformException>()));
      expect(events.last['stage'], 'native_send');
      expect(events.last['errorCode'], code);
      expect(events.any((e) => e['event'] == 'delivery.direct_send_confirmed'),
          isFalse);
      expect(calls, ['openConversation', 'sendDraftOnce']);
    });
  }

  test('missing native confirmation cannot mark a draft sent', () async {
    final ordinary = handle;
    handle = (call) async =>
        call.method == 'sendDraftOnce' ? {'sent': false} : ordinary(call);
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async => true),
        throwsA(isA<PlatformException>()));
    expect(events.last['errorCode'], 'send_not_confirmed');
  });

  test(
      'holding asks native for a fresh red-clock guard; cleared clock is not a send',
      () async {
    handle = (call) async {
      expect(call.method, 'sendDraftOnce');
      expect((call.arguments as Map)['requireRedClock'], isTrue);
      return {'error': 'red_clock_cleared', 'message': 'No red clock remains'};
    };
    await expectLater(
        delivery.sendConfirmed(
            customer: 'jd_customer',
            reply: 'Please wait',
            requireRedClock: true),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'red_clock_cleared')));
    expect(calls, ['sendDraftOnce']);
    expect(events.where((e) => e['event'] == 'delivery.direct_send_confirmed'),
        isEmpty);
  });

  test(
      'native red-clear proof completes the cycle only after confirmed physical send',
      () async {
    final order = <String>[];
    delivery = DirectReplyDelivery(adapter,
        onConfirmed: (customer, started, attempt, cycle) async {
      order.add('sent');
    }, onRedClockCleared: (customer, observedAt, cycle) async {
      order.add('cleared');
    });
    handle = (call) async => {
          'sent': true,
          'redClockPresentAfterSend': false,
          'redClockObservedAtMs': 1793698400000
        };
    await delivery.sendConfirmed(customer: 'jd_customer', reply: 'answer');
    expect(order, ['sent', 'cleared']);
    expect(calls, ['sendDraftOnce']);
  });

  test('visible full version matches the build metadata source', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
        RegExp(r'^version:\s*(\S+)', multiLine: true)
            .firstMatch(pubspec)!
            .group(1),
        AppRuntime.version);
    expect(AppRuntime.version, matches(r'^\d+\.\d+\.\d+\+\d+$'));
  });

  test('holding click bound and out-of-band yield bind the same attempt',
      () async {
    final due = DateTime.now().add(const Duration(seconds: 1));
    final preparing = Completer<void>();
    final finish = Completer<Map<String, Object?>>();
    handle = (call) async {
      final args = call.arguments as Map;
      if (call.method == 'setAutomationEpoch') return {'updated': true};
      expect(args['automationEpoch'], 4);
      expect(args['expectedCustomer'], 'jd_customer');
      expect(args['attemptId'], 'attempt-4');
      if (call.method == 'sendDraftOnce') {
        expect(args['requireRedClock'], isTrue);
        expect(args['holdingClickNotBeforeMs'], due.millisecondsSinceEpoch);
        preparing.complete();
        return finish.future;
      }
      expect(call.method, 'requestHoldingSendYield');
      finish.complete({
        'error': 'holding_yielded_to_formal',
        'clickDispatched': false,
      });
      return {'yieldRequested': true};
    };
    await adapter.setAutomationEpoch(4, running: true);
    final sending = delivery.sendConfirmed(
        customer: 'jd_customer',
        reply: 'Please wait.',
        attemptId: 'attempt-4',
        requireRedClock: true,
        holdingClickNotBefore: due,
        responseCycleId: 'red-4');
    final notSent = expectLater(
        sending,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'holding_yielded_to_formal')));
    await preparing.future;
    expect(
        await adapter.requestHoldingSendYield(
            expectedCustomer: 'jd_customer', attemptId: 'attempt-4'),
        isTrue);
    await notSent;
    expect(events.last['clickDispatched'], isFalse);
  });
}
