import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';
import 'package:jd_automation/backend/jd_v2_delivery.dart';

void main() {
  late Directory root;
  late File receipt;
  late DateTime clock;
  late List<Map<String, dynamic>> bodies;
  late JdV2DeliveryOutbox outbox;
  final binding = {
    'jobId': 'job-1',
    'customerUid': 'customer-1',
    'historyVersion': 'v1',
    'resultDigest': 'a' * 64
  };

  Future<void> register([JdV2DeliveryOutbox? target]) =>
      (target ?? outbox).register(
          attemptId: 'attempt-1',
          customer: 'customer-1',
          reply: 'Exact sent reply',
          receiptPath: receipt.path,
          binding: binding);
  Future<void> writeReceipt(String state,
      {String customer = 'customer-1', String attempt = 'attempt-1'}) async {
    await receipt.writeAsString(jsonEncode({
      'state': state,
      'customer': customer,
      'attemptId': attempt,
      'timeMs': clock.millisecondsSinceEpoch,
      'sendClickedAtMs': clock.millisecondsSinceEpoch - 500
    }));
  }

  Future<Map<String, dynamic>> ack(
      String job, Map<String, dynamic> body) async {
    bodies.add(body);
    return {'jobId': job, 'recorded': true};
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd-outbox-test-');
    receipt = File('${root.path}/native.json');
    clock = DateTime.utc(2026, 11, 18, 4);
    bodies = [];
    outbox = JdV2DeliveryOutbox(root, acknowledge: ack, now: () => clock);
  });
  tearDown(() => root.delete(recursive: true));

  test('confirmed native send binds digest exact text and actual click time',
      () async {
    await register();
    await writeReceipt('submitted');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies.single['status'], 'sent');
    expect(bodies.single['actualSentText'], 'Exact sent reply');
    expect(bodies.single['resultDigest'], binding['resultDigest']);
    expect(bodies.single['occurredAt'], '2026-11-18T03:59:59.500Z');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies, hasLength(1));
  });

  test(
      'lost ACK survives restart with identical stable event and never resends',
      () async {
    outbox = JdV2DeliveryOutbox(root,
        now: () => clock,
        acknowledge: (job, body) async {
          bodies.add(body);
          throw const JdV2ApiException('capacity', statusCode: 503);
        });
    await register();
    await writeReceipt('submitted');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies, hasLength(1));
    final restarted =
        JdV2DeliveryOutbox(root, acknowledge: ack, now: () => clock);
    await register(restarted);
    await restarted.reconcile();
    await restarted.pump();
    expect(bodies, hasLength(1));
    clock = clock.add(const Duration(minutes: 1));
    await restarted.pump();
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
    await restarted.pump();
    expect(bodies, hasLength(2));
  });

  test('unknown then confirmed sent uses new event and omits unconfirmed text',
      () async {
    await register();
    await writeReceipt('unknown');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies.single['status'], 'unknown');
    expect(bodies.single.containsKey('actualSentText'), false);
    clock = clock.add(const Duration(seconds: 10));
    await writeReceipt('submitted');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies, hasLength(2));
    expect(bodies.last['status'], 'sent');
    expect(bodies.last['eventId'], isNot(bodies.first['eventId']));
  });

  test('explicit failed receipt records failed without text', () async {
    await register();
    await writeReceipt('not_sent');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies.single['status'], 'failed');
    expect(bodies.single.containsKey('actualSentText'), false);
  });

  test('wrong identity attempt partial and prepared receipts cannot prove sent',
      () async {
    await register();
    await writeReceipt('submitted', customer: 'another-customer');
    await outbox.reconcile();
    await writeReceipt('submitted', attempt: 'another-attempt');
    await outbox.reconcile();
    await receipt.writeAsString('{partial');
    await outbox.reconcile();
    await writeReceipt('prepared');
    await outbox.reconcile();
    await outbox.pump();
    expect(bodies, isEmpty);
  });

  test('registration validates customer binding and prevents attempt rebinding',
      () async {
    await expectLater(
        outbox.register(
            attemptId: 'attempt-1',
            customer: 'foreign',
            reply: 'x',
            receiptPath: receipt.path,
            binding: binding),
        throwsA(isA<JdV2ApiException>()));
    await register();
    await expectLater(
        outbox.register(
            attemptId: 'attempt-1',
            customer: 'customer-1',
            reply: 'different reply',
            receiptPath: receipt.path,
            binding: binding),
        throwsA(isA<JdV2ApiException>()));
  });

  test('an unrecorded ACK response stays pending', () async {
    outbox = JdV2DeliveryOutbox(root,
        now: () => clock,
        acknowledge: (job, body) async {
          bodies.add(body);
          return {'jobId': job, 'recorded': false};
        });
    await register();
    await writeReceipt('submitted');
    await outbox.reconcile();
    await outbox.pump();
    clock = clock.add(const Duration(minutes: 1));
    final restarted =
        JdV2DeliveryOutbox(root, acknowledge: ack, now: () => clock);
    await restarted.pump();
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
  });
  test('a stalled remote ACK cannot block preparation of the next send',
      () async {
    final started = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    outbox = JdV2DeliveryOutbox(root,
        now: () => clock,
        acknowledge: (job, body) {
          started.complete();
          return response.future;
        });
    await register();
    await writeReceipt('submitted');
    await outbox.reconcile();
    final pumping = outbox.pump();
    await started.future;
    try {
      await outbox.register(
          attemptId: 'attempt-2',
          customer: 'customer-1',
          reply: 'Next reply',
          receiptPath: '${root.path}/second.json',
          binding: {
            ...binding,
            'jobId': 'job-2'
          }).timeout(const Duration(seconds: 2));
    } finally {
      response.complete({'jobId': 'job-1', 'recorded': true});
      await pumping;
    }
  });
}
