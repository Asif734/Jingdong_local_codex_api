import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/jd_ui_scheduler.dart';
import 'package:jd_automation/capture/optional_ui_work_yield.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final purpose in [
    'early formal',
    '20-second fallback',
    'late formal',
    'preparation'
  ]) {
    test('$purpose signals only its authorized native work', () async {
      final channel = MethodChannel('jd.v54.ui-yield.$purpose');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final entered = Completer<void>();
      final inspection = Completer<Map<String, Object?>>();
      final events = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        events.add(call.method);
        switch (call.method) {
          case 'listActiveTransferAccounts':
            entered.complete();
            return inspection.future;
          case 'requestTransferInspectionYield':
            expect((call.arguments as Map)['automationEpoch'], 54);
            return {'yieldRequested': true};
          case 'requestImageAcquisitionYield':
            expect((call.arguments as Map)['automationEpoch'], 54);
            return {'interrupted': true};
        }
        return <String, Object?>{};
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final pending = adapter.listActiveTransferAccounts('buyer');
      await entered.future;
      await OptionalUiWorkYield.notify(
          mayInterruptTransfer:
              purpose == 'early formal' || purpose == '20-second fallback',
          transferActive: true,
          imageAcquisitionActive: true,
          yieldTransfer: () =>
              adapter.requestTransferInspectionYield(automationEpoch: 54),
          yieldImage: () async {
            await adapter.requestImageAcquisitionYield(automationEpoch: 54);
          });
      expect(events.contains('requestTransferInspectionYield'),
          purpose == 'early formal' || purpose == '20-second fallback');
      expect(events.contains('requestImageAcquisitionYield'), isTrue);
      expect(inspection.isCompleted, isFalse,
          reason: 'An urgent hint must not wait behind a slow inspection.');
      inspection.complete({
        'sourceAccount': 'self',
        'accounts': ['other']
      });
      await pending;
    });
  }

  test(
      'queued transfer has first priority over holding, formal replies and scans',
      () async {
    final scheduler = JdUiScheduler();
    final activeTransfer =
        await scheduler.acquire(priority: JdUiPriority.transfer);
    final order = <String>[];
    final nextTransfer = scheduler.run(() async {
      order.add('transfer');
    }, priority: JdUiPriority.transfer);
    final scan = scheduler.run(() async {
      order.add('scan');
    }, priority: JdUiPriority.capture);
    final earlyFormal = scheduler.run(() async {
      order.add('formal');
    }, priority: JdUiPriority.delivery);
    final holding = scheduler.run(() async {
      order.add('holding');
    }, priority: JdUiPriority.responseDeadline);
    expect(order, isEmpty,
        reason: 'A queued task never types into the current transfer phase.');
    activeTransfer.release();
    await Future.wait([nextTransfer, scan, earlyFormal, holding]);
    expect(order, ['transfer', 'holding', 'formal', 'scan']);
  });

  test('one failed hint cannot prevent the other authorized release', () async {
    var mediaReleased = false;
    await expectLater(
        OptionalUiWorkYield.notify(
            mayInterruptTransfer: true,
            transferActive: true,
            imageAcquisitionActive: true,
            yieldTransfer: () async {
              throw StateError('transport unavailable');
            },
            yieldImage: () async {
              mediaReleased = true;
            }),
        throwsStateError);
    expect(mediaReleased, isTrue);
  });
}
