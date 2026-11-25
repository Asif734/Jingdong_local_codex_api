import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reply yield dispatches while native transfer inspection is pending',
      () async {
    const channel = MethodChannel('jd.v32.transfer-yield.pending');
    final inspection = Completer<Map<String, Object?>>();
    final entered = Completer<void>();
    final epochs = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'setAutomationEpoch':
          return {'updated': true};
        case 'listActiveTransferAccounts':
          entered.complete();
          return inspection.future;
        case 'requestTransferInspectionYield':
          epochs.add((call.arguments as Map)['automationEpoch']);
          return {'yieldRequested': true};
      }
      return <String, Object?>{};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await adapter.setAutomationEpoch(7, running: true);
    final pending = adapter.listActiveTransferAccounts('exact_customer_I1l');
    final rejected = expectLater(
        pending,
        throwsA(isA<PlatformException>().having(
            (error) => error.code, 'code', 'handoff_yielded_for_reply')));
    await entered.future;

    await adapter.requestTransferInspectionYield();

    expect(epochs, [7]);
    expect(inspection.isCompleted, isFalse,
        reason: 'Reply signalling must not wait for inspection completion');
    inspection.complete({'error': 'handoff_yielded_for_reply'});
    await rejected;
  });

  for (final explicit in [false, true]) {
    test('yield forwards the original ${explicit ? 'explicit' : 'zone'} epoch',
        () async {
      final channel = MethodChannel('jd.v32.transfer-yield.epoch.$explicit');
      final received = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'requestTransferInspectionYield') {
          received.add((call.arguments as Map)['automationEpoch']);
          return {'yieldRequested': false};
        }
        return {'updated': true};
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await adapter.setAutomationEpoch(8, running: true);

      if (explicit) {
        await adapter.requestTransferInspectionYield(automationEpoch: 7);
      } else {
        await runZoned(() => adapter.requestTransferInspectionYield(),
            zoneValues: {MacOSCaptureAdapter.automationEpochZoneKey: 7});
      }

      expect(received, [7],
          reason: 'A stale callback cannot signal a newer automation run');
    });
  }
}
