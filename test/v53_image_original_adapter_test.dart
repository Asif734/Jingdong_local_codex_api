import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.v53.original-image.test');
  late MacOSCaptureAdapter adapter;
  final sender = DateTime.utc(2026, 11, 10, 10, 55, 2);
  const customer = 'customer-a';
  const message = 'incoming-time:customer-a:2026-11-10T10:55:02Z';
  final evidence = ViewportEvidence({
    'evidenceId': 'fresh-frame',
    'customer': customer,
    'manifestPath': '/private/evidence/fresh-frame.json',
  });
  const region =
      OcrVisualRegion(x: .3, y: .5, width: .1, height: .2, confidence: 1);
  Map<String, Object?> result({String state = 'pending'}) => {
        'state': state,
        'customer': customer,
        'messageId': message,
        'messageTimeKey': message,
        'senderAtMs': sender.millisecondsSinceEpoch,
        'receiptId': 'receipt-a',
        'automationEpoch': 53,
        'token': 'original-token',
        if (state == 'ready') ...{
          'kind': 'image',
          'dataBase64': 'AQID',
          'contentComplete': true,
          'pixelWidth': 600,
          'pixelHeight': 800,
          'captureSource': 'jd-image-viewer-download',
        },
      };
  Future<ImageOriginalAcquisitionResult> acquire() =>
      adapter.acquireImageOriginal(
          evidence: evidence,
          region: region,
          customer: customer,
          messageId: message,
          senderAt: sender,
          receiptId: 'receipt-a',
          automationEpoch: 53);
  Future<ImageOriginalAcquisitionResult> poll() => adapter.pollImageOriginal(
      token: 'original-token',
      customer: customer,
      messageId: message,
      senderAt: sender,
      receiptId: 'receipt-a',
      automationEpoch: 53);

  setUp(() {
    adapter = MacOSCaptureAdapter(channel: channel);
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('acquisition carries fresh frame and exact durable message proof',
      () async {
    mock((call) async {
      expect(call.method, 'acquireImageOriginal');
      final args = call.arguments as Map;
      expect(args['manifestPath'], evidence.manifestPath);
      expect(args['evidenceId'], evidence.id);
      expect(args['expectedCustomer'], customer);
      expect(args['messageId'], message);
      expect(args['messageTimeKey'], message);
      expect(args['senderAtMs'], sender.millisecondsSinceEpoch);
      expect(args['receiptId'], 'receipt-a');
      expect(args['automationEpoch'], 53);
      expect(args['x'], .3);
      expect(args['height'], .2);
      return {...result(), 'reason': 'download_triggered'};
    });
    final value = await acquire();
    expect(value.ready, false);
    expect(value.token, 'original-token');
    expect(value.receiptId, 'receipt-a');
    expect(value.image, isNull);
  });

  test('slow file stays pending across polls and later returns full original',
      () async {
    var polls = 0;
    mock((call) async {
      expect(call.method, 'pollImageOriginal');
      expect((call.arguments as Map)['token'], 'original-token');
      return result(state: ++polls == 4 ? 'ready' : 'pending');
    });
    for (var i = 0; i < 3; i++) {
      final value = await poll();
      expect(value.ready, false);
      expect(value.token, 'original-token');
    }
    final value = await poll();
    expect(value.ready, true);
    expect(value.image!.bytes, [1, 2, 3]);
    expect(value.image!.captureSource, 'jd-image-viewer-download');
  });

  test(
      'source movement returns relocation outcome without image or business completion',
      () async {
    mock((call) async => {
          ...result(state: 'source_changed'),
          'reason': 'customer_window_or_pixels_changed'
        });
    final value = await acquire();
    expect(value.state, 'source_changed');
    expect(value.ready, false);
    expect(value.messageId, message);
    expect(value.image, isNull);
  });

  for (final field in [
    'customer',
    'messageId',
    'messageTimeKey',
    'receiptId',
    'senderAtMs',
    'automationEpoch'
  ]) {
    test('rejects ready result with mismatched $field', () async {
      mock((call) async => {
            ...result(state: 'ready'),
            field:
                field.endsWith('Ms') || field == 'automationEpoch' ? 1 : 'wrong'
          });
      await expectLater(
          acquire(),
          throwsA(isA<PlatformException>()
              .having((e) => e.code, 'code', 'image_original_proof_mismatch')));
    });
  }
  test('partial crop cannot be declared ready', () async {
    mock((call) async => {...result(state: 'ready'), 'contentComplete': false});
    await expectLater(
        acquire(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'image_original_incomplete')));
  });
  test('yield is independent of an in-flight acquisition', () async {
    final acquiring = Completer<Object?>();
    final calls = <String>[];
    mock((call) async {
      calls.add(call.method);
      if (call.method == 'acquireImageOriginal') return acquiring.future;
      expect(call.method, 'requestImageAcquisitionYield');
      expect((call.arguments as Map)['automationEpoch'], 53);
      acquiring.complete({...result(), 'reason': 'acquisition_yielded'});
      return {'interrupted': true};
    });
    final work = acquire();
    await Future<void>.delayed(Duration.zero);
    expect(
        await adapter.requestImageAcquisitionYield(automationEpoch: 53), true);
    expect((await work).reason, 'acquisition_yielded');
    expect(calls, ['acquireImageOriginal', 'requestImageAcquisitionYield']);
  });
  test('a newer run never upgrades an old acquisition epoch', () async {
    mock((call) async {
      if (call.method == 'setAutomationEpoch') return {'updated': true};
      expect((call.arguments as Map)['automationEpoch'], 53);
      return {...result(), 'reason': 'automation_stopped'};
    });
    await adapter.setAutomationEpoch(54, running: true);
    final value = await acquire();
    expect(value.ready, false);
    expect(value.automationEpoch, 53);
  });
  test('explicit release waits for native cleanup and preserves old epoch',
      () async {
    mock((call) async {
      if (call.method == 'setAutomationEpoch') return {'updated': true};
      expect(call.method, 'requestImageAcquisitionYield');
      expect((call.arguments as Map)['automationEpoch'], 53);
      expect((call.arguments as Map)['awaitRelease'], true);
      return {'interrupted': true, 'viewerReleased': false};
    });
    await adapter.setAutomationEpoch(54, running: true);
    expect(await adapter.releaseImageAcquisitionViewer(automationEpoch: 53),
        false);
  });
  test('image-only saved crop forwards optional sender clock', () async {
    mock((call) async {
      expect(call.method, 'cropViewportEvidence');
      expect((call.arguments as Map)['expectedMediaAtMs'],
          sender.millisecondsSinceEpoch);
      return {'kind': 'image', 'captureSource': 'frozen-window-crop'};
    });
    await adapter.cropViewportEvidence(evidence, region,
        expectedMediaAt: sender);
  });
  test('legacy identity stays exact with a separate canonical time key',
      () async {
    const legacy = 'incoming-media:retained-original-id';
    mock((call) async {
      final args = call.arguments as Map;
      expect(args['messageId'], legacy);
      expect(args['messageTimeKey'], message);
      return {...result(state: 'ready'), 'messageId': legacy};
    });
    final value = await adapter.acquireImageOriginal(
        evidence: evidence,
        region: region,
        customer: customer,
        messageId: legacy,
        senderAt: sender,
        receiptId: 'receipt-a',
        automationEpoch: 53);
    expect(value.ready, true);
    expect(value.messageId, legacy);
  });
}
