import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.v55.transfer-open');
  const customer = 'jd_exact_I1l';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MacOSCaptureAdapter adapter;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) response;

  Map<String, Object?> confirmed() => {
        'opened': true,
        'customer': customer,
        'activeCustomerId': customer,
        'focusVerified': true,
        'identityProof': 'exact_active_ax',
        'transferClicked': false,
      };

  setUp(() {
    calls = [];
    response = (_) async => confirmed();
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return response(call);
    });
    adapter = MacOSCaptureAdapter(channel: channel);
  });
  tearDown(() async {
    await adapter.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> open() => adapter.openConversation(customer,
      purpose: ConversationOpenPurpose.transfer);

  test('transfer requests a cooperative step without the old total deadline',
      () async {
    await open();
    final args = calls.single.arguments as Map;
    expect(calls.single.method, 'openConversation');
    expect(args['expectedCustomer'], customer);
    expect(args['purpose'], 'transfer');
    expect(args.containsKey('timeoutMs'), isFalse);
  });

  test('normal delivery retains its original bounded opening contract',
      () async {
    await adapter.openConversation(customer);
    final args = calls.single.arguments as Map;
    expect(args['timeoutMs'], 4000);
    expect(args.containsKey('purpose'), isFalse);
  });

  for (final reason in [
    'ax_temporarily_unavailable',
    'row_evidence_pending',
    'header_not_stable',
    'step_budget_yield',
    'focus_verification_pending'
  ]) {
    test('$reason returns its checkpoint without starting a fallback or loop',
        () async {
      response = (_) async => {
            'opened': false,
            'openState': 'pending',
            'error': 'conversation_open_pending',
            'pendingReason': reason,
            'rowToken': 'original-token',
            'rowKey': 'original-row',
            'openStage': 'row_selection_confirmation',
            'clickDispatched': true,
            'transferClicked': false,
            'activeCustomerId': customer,
          };
      await expectLater(
          open(),
          throwsA(isA<PlatformException>()
              .having((e) => e.code, 'code', 'conversation_open_pending')
              .having((e) => (e.details as Map)['rowToken'], 'same token',
                  'original-token')
              .having((e) => (e.details as Map)['pendingReason'], 'same reason',
                  reason)
              .having((e) => (e.details as Map)['clickDispatched'],
                  'row clicked', true)));
      expect(calls, hasLength(1),
          reason: 'A pending step must return its UI lease.');
      response = (_) async => confirmed();
      await open();
      expect(calls, hasLength(2));
    });
  }

  test('incomplete final focus proof is pending, not successful opening',
      () async {
    response = (_) async => {...confirmed(), 'focusVerified': false};
    await expectLater(
        open(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'conversation_open_pending')));
  });

  test('a different exact AX identity never becomes a pending success',
      () async {
    response =
        (_) async => {...confirmed(), 'activeCustomerId': 'jd_exact_l1I'};
    await expectLater(
        open(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'customer_identity_mismatch')));
  });

  test('a row-only identity cannot start transfer-purpose UI actions',
      () async {
    await expectLater(
        adapter.openConversation('pending-row:unverified',
            purpose: ConversationOpenPurpose.transfer),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'conversation_open_pending')));
    expect(calls, isEmpty);
  });

  test('an unexpected transfer click never becomes safe open recovery',
      () async {
    response = (_) async => {
          'openState': 'pending',
          'error': 'conversation_open_pending',
          'transferClicked': true
        };
    await expectLater(
        open(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'transfer_unconfirmed')));
  });

  test('reply yield can interrupt transfer opening without waiting for it',
      () async {
    final entered = Completer<void>();
    final opening = Completer<Object?>();
    response = (call) async {
      if (call.method == 'openConversation') {
        entered.complete();
        return opening.future;
      }
      if (call.method == 'requestTransferInspectionYield') {
        opening.complete({
          'error': 'handoff_yielded_for_reply',
          'opened': false,
          'transferClicked': false,
          'rowToken': 'keep-token'
        });
        return {'yieldRequested': true};
      }
      return {};
    };
    final pending = open();
    final result = expectLater(
        pending,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'handoff_yielded_for_reply')
            .having((e) => (e.details as Map)['rowToken'], 'checkpoint',
                'keep-token')));
    await entered.future;
    await adapter.requestTransferInspectionYield(automationEpoch: 55);
    await result;
    expect(calls.map((c) => c.method),
        ['openConversation', 'requestTransferInspectionYield']);
  });
}
