import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.frozen-evidence.test');
  late MacOSCaptureAdapter adapter;
  late List<String> calls;
  setUp(() {
    adapter = MacOSCaptureAdapter(channel: channel);
    calls = [];
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  final evidence = ViewportEvidence({
    'evidenceId': 'immutable-a',
    'customer': 'customer-a',
    'imagePath': '/cache/a.png',
    'manifestPath': '/cache/a.json',
    'capturedAtMs': 1000
  });
  test(
      'saved OCR and image cropping keep their original customer after a live switch',
      () async {
    var currentCustomer = 'customer-a';
    final pending = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = call.arguments as Map;
      expect(args['expectedCustomer'], 'customer-a');
      expect(args['manifestPath'], '/cache/a.json');
      if (call.method == 'inspectViewportEvidence') return pending.future;
      if (call.method == 'cropViewportEvidence') {
        expect(currentCustomer, 'customer-b');
        return {
          'kind': 'image',
          'dataBase64': 'AQID',
          'captureSource': 'frozen-window-crop'
        };
      }
      fail('Saved evidence must not call a live window API.');
    });
    final work = adapter.inspectViewportEvidence(evidence);
    await Future<void>.delayed(Duration.zero);
    currentCustomer = 'customer-b';
    pending.complete({
      'activeCustomerId': 'customer-a',
      'capturedAtMs': 1000,
      'imageWidth': 200,
      'imageHeight': 100,
      'observations': []
    });
    expect((await work).activeCustomerId, 'customer-a');
    final image = await adapter.cropViewportEvidence(
        evidence,
        const OcrVisualRegion(
            x: .2, y: .3, width: .2, height: .2, confidence: 1));
    expect(image.bytes, [1, 2, 3]);
    expect(calls, ['inspectViewportEvidence', 'cropViewportEvidence']);
  });
  test(
      'timeout does not create another recognition request for the same saved frame',
      () async {
    final pending = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect((call.arguments as Map)['liveRegistration'], isTrue);
      return pending.future;
    });
    final first =
        adapter.inspectViewportEvidence(evidence, liveRegistration: true);
    await expectLater(
        first.timeout(Duration.zero), throwsA(isA<TimeoutException>()));
    final retry = adapter.inspectViewportEvidence(evidence);
    expect(identical(first, retry), isTrue);
    expect(calls, ['inspectViewportEvidence']);
    pending.complete({
      'activeCustomerId': 'customer-a',
      'capturedAtMs': 1000,
      'observations': []
    });
    expect((await retry).capturedAt.millisecondsSinceEpoch, 1000);
  });
  test('history capture persists its cutoff before recognition can start',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureViewportEvidence');
      final args = call.arguments as Map;
      expect(args['historyCutoffMs'], 1000);
      expect(args['historyCutoffs'], {'customer-a': 900});
      return evidence.metadata;
    });
    await adapter.captureViewportEvidence(
        expectedCustomer: 'customer-a',
        directory: '/cache',
        historyCutoff: DateTime.fromMillisecondsSinceEpoch(1000),
        historyCutoffs: {'customer-a': 900});
  });
  test(
      'frozen video payload keeps its verified original and needs no live window',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'cropViewportEvidence');
      expect(
          (call.arguments as Map)['destinationDirectory'], '/media/a/videos');
      return {
        'kind': 'video',
        'captureSource': 'frozen-frame-video-cache',
        'reason': 'pixel_matched_same_chat_video_companion',
        'video': {
          'path': '/media/a/videos/verified.mp4',
          'originalName': 'original.mp4',
          'mimeType': 'video/mp4'
        }
      };
    });
    final payload = await adapter.cropViewportEvidence(
        evidence,
        const OcrVisualRegion(
            x: .2, y: .3, width: .2, height: .2, confidence: 1),
        destinationDirectory: '/media/a/videos');
    expect(payload.video!.path, '/media/a/videos/verified.mp4');
    expect(payload.kind, 'video');
    expect(calls, ['cropViewportEvidence']);
  });
  test('blank crop is unverified, never a fabricated customer image', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'kind': 'unverified',
                  'reason': 'insufficient_visual_evidence',
                  'foregroundFraction': 0.0
                });
    final payload = await adapter.cropViewportEvidence(
        evidence,
        const OcrVisualRegion(
            x: .2, y: .3, width: .2, height: .2, confidence: 1));
    expect(payload.kind, 'unverified');
    expect(payload.bytes, isNull);
    expect(payload.reason, 'insufficient_visual_evidence');
  });
  test('two sidebar timers share the native row read until it completes',
      () async {
    final result = Completer<List<Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return result.future;
    });
    final first = adapter.listConversationRows();
    final second = adapter.listConversationRows();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['listConversationRows']);
    result.complete([]);
    await first;
    await second;
  });
}
