import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/runtime/diagnostic_work_tracker.dart';
import 'package:jd_automation/capture/viewport_capture_pump.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Stop cancels old diagnostic leases without releasing new run work',
      () async {
    final tracker = DiagnosticWorkTracker();
    final releaseOld = tracker.acquire();
    final oldWait = tracker.whenIdle;
    expect(tracker.cancelPending(), 1);
    await oldWait;
    final releaseNew = tracker.acquire();
    var newIdle = false;
    final waitNew = tracker.whenIdle.then((_) => newIdle = true);
    releaseOld();
    await Future<void>.delayed(Duration.zero);
    expect(newIdle, isFalse);
    releaseNew();
    await waitNew;
  });
  test(
      'Stop releases blocked OCR awaiter and restart sends fresh native request',
      () async {
    const channel = MethodChannel('jd.stop.lifecycle');
    final blocked = Completer<Map<String, Object?>>();
    var calls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setAutomationEpoch') return {'updated': true};
      if (call.method == 'inspectOCR') {
        if (++calls == 1) return blocked.future;
        return {
          'windowId': 7,
          'activeCustomerId': 'new',
          'observations': <Object?>[]
        };
      }
      return <String, Object?>{};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(() async {
      if (!blocked.isCompleted) blocked.complete({});
      await adapter.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await adapter.setAutomationEpoch(1, running: true);
    final old = adapter.inspectOcr(windowId: 7);
    final cancelled = expectLater(
        old,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'automation_stopped')));
    await adapter.setAutomationEpoch(2, running: false);
    await cancelled;
    await adapter.setAutomationEpoch(3, running: true);
    expect((await adapter.inspectOcr(windowId: 7)).activeCustomerId, 'new');
    expect(calls, 2);
    blocked.complete({'activeCustomerId': 'old', 'observations': <Object?>[]});
    await Future<void>.delayed(Duration.zero);
  });
  test('stopped frame registration cannot hold a new run drain lease',
      () async {
    final root = await Directory.systemTemp.createTemp('jd-stop-pump-');
    final oldEntered = Completer<void>(),
        oldRelease = Completer<void>(),
        newEntered = Completer<void>();
    final pump = ViewportCapturePump();
    var current = 1;
    void begin(int epoch) => pump.begin(
        epoch: epoch,
        sessionId: 'run-$epoch',
        directory: root,
        current: () => current == epoch,
        consume: (e, s) async {
          if (epoch == 1) {
            oldEntered.complete();
            await oldRelease.future;
          } else {
            newEntered.complete();
          }
        },
        onError: (e) {});
    ViewportEvidence frame(int epoch) => ViewportEvidence({
          'evidenceId': 'frame-$epoch',
          'customer': 'buyer',
          'capturedAtMs': epoch,
          'pngSHA256': 'frame-$epoch',
          'chatContentSHA256': 'frame-$epoch',
          'automationSessionId': 'run-$epoch'
        });
    addTearDown(() async {
      if (!oldRelease.isCompleted) oldRelease.complete();
      current = 0;
      pump.stop();
      await root.delete(recursive: true);
    });
    begin(1);
    await pump.save(1, frame(1), {});
    await oldEntered.future;
    current = 0;
    final snapshot = pump.stop();
    expect(snapshot['registrationInFlight'], isTrue);
    await pump.whenIdle;
    current = 2;
    begin(2);
    await pump.save(2, frame(2), {});
    await newEntered.future;
    oldRelease.complete();
    await pump.whenIdle;
    final oldPending = await Directory('${root.path}/raw_inbox/run-1')
        .list()
        .where((f) => f.path.endsWith('.pending.json'))
        .length;
    expect(oldPending, 1);
  });
}
