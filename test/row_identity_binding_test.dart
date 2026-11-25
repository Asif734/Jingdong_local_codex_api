import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.row-binding.test');
  late MacOSCaptureAdapter adapter;
  setUp(() {
    adapter = MacOSCaptureAdapter(channel: channel);
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Map<String, Object?> row(String label,
          {String token = 'token-a', int index = 0}) =>
      {
        'customer': label,
        'identitySource': 'row_anchor',
        'rowKey': 'shape-a',
        'rowToken': token,
        'rowIndex': index,
        'unread': true,
        'unreadEvidence': 12,
        'unreadAgeSeconds': 13,
        'evidenceAvailable': true,
      };
  test(
      'wrong/missing OCR names cannot become customer IDs; a moved row binds through AX',
      () async {
    var moved = false;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'listConversationRows') {
        return [
          row(moved ? '' : 'entirely_wrong_lIQQ',
              token: moved ? 'token-b' : 'token-a', index: moved ? 1 : 0)
        ];
      }
      if (call.method == 'openConversationRow') {
        final args = call.arguments as Map;
        expect(args['rowToken'], 'token-b');
        expect(args['expectedCustomer'], isNull);
        return {
          'opened': true,
          'customer': 'jd_real_customer',
          'rowKey': 'shape-a',
          'identityProof': 'selected_row_and_stable_ax_header'
        };
      }
      if (call.method == 'openConversation') {
        return {'opened': true, 'customer': 'jd_real_customer'};
      }
      if (call.method == 'sendDraftOnce') {
        expect((call.arguments as Map)['expectedCustomer'], 'jd_real_customer');
        return {'sent': true};
      }
      return null;
    });
    final before = (await adapter.listConversationRows()).single;
    expect(before.customer, 'pending-row:shape-a');
    expect(before.unreadAgeSeconds, 13);
    moved = true;
    final after = (await adapter.listConversationRows()).single;
    expect(after.customer, before.customer,
        reason: 'a new top row must not reset the tracked row identity');
    await adapter.openConversation(after.customer);
    expect(
        adapter.verifiedCustomerIdentity(after.customer), 'jd_real_customer');
    await expectLater(
        adapter.sendDraftOnce(expectedCustomer: after.customer, reply: 'wait'),
        throwsA(isA<PlatformException>()));
    await adapter.sendDraftOnce(
        expectedCustomer: 'jd_real_customer', reply: 'wait');
    expect(calls.where((c) => c.method == 'sendDraftOnce'), hasLength(1));
  });

  for (final invalid in ['wrong-row-key', 'no-proof', 'stale-header-proof']) {
    test('unconfirmed row result $invalid cannot establish an identity',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listConversationRows') return [row('anything')];
        return {
          'opened': true,
          'customer': 'other-customer',
          'rowKey': invalid == 'wrong-row-key' ? 'shape-b' : 'shape-a',
          'identityProof': invalid == 'no-proof'
              ? null
              : invalid == 'stale-header-proof'
                  ? 'exact_active_ax'
                  : 'selected_row_and_stable_ax_header'
        };
      });
      final observed = (await adapter.listConversationRows()).single.customer;
      await expectLater(adapter.openConversation(observed),
          throwsA(isA<PlatformException>()));
      expect(adapter.verifiedCustomerIdentity(observed), observed);
    });
  }

  test('simultaneous row resolution shares one native operation', () async {
    final gate = Completer<Map<String, Object?>>();
    var opens = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listConversationRows') return [row('wrong')];
      opens++;
      return gate.future;
    });
    final customer = (await adapter.listConversationRows()).single.customer;
    final first = adapter.openConversation(customer);
    final second = adapter.openConversation(customer);
    await Future<void>.delayed(Duration.zero);
    expect(opens, 1);
    gate.complete({
      'opened': true,
      'customer': 'real',
      'rowKey': 'shape-a',
      'identityProof': 'selected_row_and_stable_ax_header'
    });
    await Future.wait([first, second]);
    expect(adapter.verifiedCustomerIdentity(customer), 'real');
  });

  test(
      'adopting an earlier row detection never resets the SLA or live processing flags',
      () {
    final start = DateTime.utc(2026, 11, 1, 10);
    final recovery = UnreadCaptureRecovery(
        customer: 'real',
        unreadEvidence: 0,
        detectedAt: start.add(const Duration(seconds: 12)),
        knownIncomingIds: {},
        knownOutgoingIds: {});
    recovery.videoProcessing = true;
    recovery.holdingSent = true;
    recovery.holdingSentAt = start.add(const Duration(seconds: 15));
    expect(recovery.inheritDetection(start, 12), isTrue);
    expect(recovery.detectedAt, start);
    expect(recovery.unreadEvidence, 12);
    expect(recovery.videoProcessing, isTrue);
    expect(recovery.holdingSent, isTrue);
    expect(recovery.inheritDetection(start.add(const Duration(seconds: 20)), 8),
        isFalse);
    expect(recovery.detectedAt, start);
    expect(recovery.unreadEvidence, 12);
  });
}
