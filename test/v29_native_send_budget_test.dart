import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/direct_reply_delivery.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.v29.send-budget.test');
  late MacOSCaptureAdapter adapter;
  late DirectReplyDelivery delivery;
  late DateTime clock;
  late List<MethodCall> calls;
  late List<Map<String, Object?>> events;
  late Future<Object?> Function(MethodCall) handle;

  setUp(() {
    clock = DateTime.now();
    calls = [];
    events = [];
    handle = (call) async => call.method == 'openConversation'
        ? {'opened': true, 'activeCustomerId': 'jd_customer'}
        : {'sent': true};
    adapter = MacOSCaptureAdapter(channel: channel);
    delivery = DirectReplyDelivery(adapter,
        now: () => clock,
        record: (event, fields) => events.add({'event': event, ...fields}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handle(call);
    });
  });

  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Matcher budgetFailure(String phase) => isA<PlatformException>()
      .having((e) => e.code, 'code', 'send_preclick_budget_exceeded')
      .having((e) => (e.details as Map)['sendStage'], 'stage', phase)
      .having((e) => (e.details as Map)['clickDispatched'], 'clicked', false);

  test('one default deadline includes opening, validation and attempt creation',
      () async {
    final deadline = clock.add(const Duration(seconds: 6));
    handle = (call) async {
      if (call.method == 'openConversation') {
        clock = clock.add(const Duration(seconds: 4));
        return {'opened': true, 'activeCustomerId': 'jd_customer'};
      }
      expect(call.method, 'sendDraftOnce');
      expect((call.arguments as Map)['preClickDeadlineMs'],
          deadline.millisecondsSinceEpoch);
      expect(deadline.difference(clock), const Duration(milliseconds: 500));
      return {'sent': true};
    };
    expect(
        await delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async {
              clock = clock.add(const Duration(seconds: 1));
              return true;
            },
            beforeSend: () async {
              clock = clock.add(const Duration(milliseconds: 500));
              return {'attemptId': 'prepared-1', 'receiptPath': '/tmp/unused'};
            }),
        isTrue);
    expect(calls.map((c) => c.method), ['openConversation', 'sendDraftOnce']);
  });

  test('expired SLA deadline performs no opening or native send', () async {
    var attempts = 0;
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            preClickDeadline: clock,
            canSend: () async => true,
            beforeSend: () async {
              attempts++;
              return {};
            }),
        throwsA(budgetFailure('before_open')));
    expect(calls, isEmpty);
    expect(attempts, 0);
  });

  test('slow opening cannot reset the remaining send budget', () async {
    var validations = 0;
    handle = (call) async {
      expect(call.method, 'openConversation');
      clock = clock.add(const Duration(seconds: 7));
      return {'opened': true, 'activeCustomerId': 'jd_customer'};
    };
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async {
              validations++;
              return true;
            }),
        throwsA(budgetFailure('after_open')));
    expect(validations, 0);
    expect(calls.map((c) => c.method), ['openConversation']);
    expect(events.first['event'], 'delivery.conversation_opened');
    expect(events.last['sent'], false);
  });

  test('validation expiry prevents a delivery attempt from being created',
      () async {
    var attempts = 0;
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Answer',
            canSend: () async {
              clock = clock.add(const Duration(seconds: 7));
              return true;
            },
            beforeSend: () async {
              attempts++;
              return {};
            }),
        throwsA(budgetFailure('after_state_validation')));
    expect(attempts, 0);
    expect(calls.map((c) => c.method), ['openConversation']);
  });

  test('a prepared attempt remains known unclicked when its DB work is slow',
      () async {
    var prepared = false;
    await expectLater(
        delivery.deliver(
            customer: 'jd_customer',
            reply: 'Keep this generated answer',
            canSend: () async => true,
            beforeSend: () async {
              prepared = true;
              clock = clock.add(const Duration(seconds: 7));
              return {'attemptId': 'prepared-1', 'receiptPath': '/tmp/unused'};
            }),
        throwsA(budgetFailure('after_attempt_preparation')));
    expect(prepared, isTrue);
    expect(calls.map((c) => c.method), ['openConversation']);
    expect(events.last['nativeInvoked'], false);
  });

  test(
      'in-flight native confirmation survives the deadline and uses click time',
      () async {
    final entered = Completer<void>();
    final native = Completer<Object?>();
    final deadline = clock.add(const Duration(seconds: 2));
    final clickedAt = clock.add(const Duration(seconds: 1));
    DateTime? confirmedAt;
    delivery = DirectReplyDelivery(adapter,
        now: () => clock,
        onConfirmed: (_, at, __, ___) async => confirmedAt = at,
        record: (event, fields) => events.add({'event': event, ...fields}));
    handle = (call) async {
      if (call.method == 'openConversation') {
        return {'opened': true, 'activeCustomerId': 'jd_customer'};
      }
      expect((call.arguments as Map)['preClickDeadlineMs'],
          deadline.millisecondsSinceEpoch);
      entered.complete();
      return native.future;
    };
    final sent = delivery.deliver(
        customer: 'jd_customer',
        reply: 'Answer',
        canSend: () async => true,
        preClickDeadline: deadline);
    await entered.future;
    clock = clock.add(const Duration(seconds: 20));
    native.complete({
      'sent': true,
      'sendClickedAtMs': clickedAt.millisecondsSinceEpoch,
      'queueWaitMs': 50,
      'fullSnapshotReads': 1,
      'lightSnapshotReads': 5,
      'confirmationAXValueFailures': 2,
      'postClickComposerPreserved': false,
    });
    expect(await sent, isTrue);
    expect(
        confirmedAt?.millisecondsSinceEpoch, clickedAt.millisecondsSinceEpoch);
    expect(events.last['event'], 'delivery.direct_send_confirmed');
    expect(events.last['queueWaitMs'], 50);
    expect(events.last['lightSnapshotReads'], 5);
    expect(events.last['confirmationAXValueFailures'], 2);
    expect(calls.map((c) => c.method), ['openConversation', 'sendDraftOnce']);
  });

  test('native uncertainty retains queue, AX and composer evidence in logs',
      () async {
    handle = (_) async => {
          'error': 'send_unconfirmed',
          'clickDispatched': true,
          'queueWaitMs': 80,
          'fullSnapshotReads': 1,
          'lightSnapshotReads': 8,
          'confirmationAXValueFailures': 3,
          'postClickComposerPreserved': true,
          'composerStillMatchesReply': true,
        };
    await expectLater(
        delivery.sendConfirmed(customer: 'jd_customer', reply: 'Answer'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'send_unconfirmed')));
    expect(events.single['clickDispatched'], true);
    expect(events.single['queueWaitMs'], 80);
    expect(events.single['postClickComposerPreserved'], true);
    expect(events.single['composerStillMatchesReply'], true);
    expect(events.single['confirmationAXValueFailures'], 3);
  });
}
