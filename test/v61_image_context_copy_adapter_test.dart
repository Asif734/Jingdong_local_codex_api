import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_acquisition_route.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.v61.context-copy.test');
  const customer = 'context-image-buyer';
  final sender = DateTime.utc(2026, 11, 12, 2, 46, 51);
  const message = 'incoming-time:context-image-buyer:2026-11-12T02:46:51Z';
  const receipt = 'original-image-receipt';
  const epoch = 61;
  final evidence = ViewportEvidence({
    'evidenceId': 'fresh-context-frame',
    'customer': customer,
    'manifestPath': '/private/evidence/fresh-context-frame.json',
  });
  final target = <String, Object?>{
    'pointX': .277,
    'pointY': .494,
    'header': {
      'text': '$customer 10:46:51',
      'confidence': 1.0,
      'x': .273,
      'y': .46,
      'width': .25,
      'height': .02,
    },
    'bodyTop': .484,
    'bodyBottom': .79,
    'chat': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
  };
  late MacOSCaptureAdapter adapter;

  Map<String, Object?> result({String state = 'pending'}) => {
        'state': state,
        'customer': customer,
        'messageId': message,
        'messageTimeKey': message,
        'senderAtMs': sender.millisecondsSinceEpoch,
        'receiptId': receipt,
        'automationEpoch': epoch,
        'token': 'copied-image-token',
        'imageConfirmed': true,
        if (state == 'ready') ...{
          'kind': 'image',
          'dataBase64': 'AQID',
          'contentComplete': true,
          'pixelWidth': 640,
          'pixelHeight': 1386,
          'captureSource': 'jd-message-context-copy-cache',
        },
      };
  Future<ImageOriginalAcquisitionResult> copy({bool knownImage = false}) =>
      adapter.copyImageFromMessageContext(
          evidence: evidence,
          target: target,
          customer: customer,
          messageId: message,
          senderAt: sender,
          receiptId: receipt,
          automationEpoch: epoch,
          knownImage: knownImage);
  Future<ImageOriginalAcquisitionResult> poll() => adapter.pollImageOriginal(
      token: 'copied-image-token',
      customer: customer,
      messageId: message,
      senderAt: sender,
      receiptId: receipt,
      automationEpoch: epoch);
  void mock(Future<Object?> Function(MethodCall) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);

  setUp(() => adapter = MacOSCaptureAdapter(channel: channel));
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('context copy forwards immutable frame, exact owner and anchored hit',
      () async {
    mock((call) async {
      expect(call.method, 'copyImageFromMessageContext');
      final args = call.arguments as Map;
      expect(args['manifestPath'], evidence.manifestPath);
      expect(args['evidenceId'], evidence.id);
      expect(args['expectedCustomer'], customer);
      expect(args['messageId'], message);
      expect(args['messageTimeKey'], message);
      expect(args['senderAtMs'], sender.millisecondsSinceEpoch);
      expect(args['receiptId'], receipt);
      expect(args['automationEpoch'], epoch);
      expect(args['target'], target);
      expect(args['knownImage'], isFalse);
      expect(args.containsKey('width'), isFalse,
          reason: 'A sender block is not forwarded as an image crop.');
      return result();
    });
    final value = await copy();
    expect(value.ready, isFalse);
    expect(value.imageConfirmed, isTrue);
    expect(value.token, 'copied-image-token');
    expect(value.image, isNull);
  });

  test('known image status is forwarded independently of its acquisition state',
      () async {
    mock((call) async {
      expect((call.arguments as Map)['knownImage'], isTrue);
      return {...result(), 'reason': 'copied_image_verification_pending'};
    });
    final value = await copy(knownImage: true);
    expect(value.ready, isFalse);
    expect(value.imageConfirmed, isTrue);
  });

  test('a newer adapter epoch and Zone cannot rewrite the copy ownership',
      () async {
    mock((call) async {
      if (call.method == 'setAutomationEpoch') return {'updated': true};
      expect(call.method, 'copyImageFromMessageContext');
      expect((call.arguments as Map)['automationEpoch'], epoch);
      return result();
    });
    await adapter.setAutomationEpoch(62, running: true);
    final value = await runZoned(() => copy(), zoneValues: {
      MacOSCaptureAdapter.automationEpochZoneKey: 999,
    });
    expect(value.automationEpoch, epoch);
  });

  for (final state in ['pending', 'ready']) {
    for (final field in [
      'customer',
      'messageId',
      'messageTimeKey',
      'senderAtMs',
      'receiptId',
      'automationEpoch',
    ]) {
      test('$state copy cannot confirm an image for mismatched $field',
          () async {
        mock((call) async => {
              ...result(state: state),
              field: field.endsWith('Ms') || field == 'automationEpoch'
                  ? 1
                  : 'another-message',
            });
        await expectLater(
            copy(),
            throwsA(isA<PlatformException>().having((error) => error.code,
                'code', 'image_original_proof_mismatch')));
      });
    }
  }

  for (final invalid in <Map<String, Object?>>[
    {'contentComplete': false},
    {'contentComplete': null},
    {'kind': 'text'},
    {'dataBase64': ''},
    {'dataBase64': null},
    {'pixelWidth': 0},
    {'pixelHeight': 0},
  ]) {
    test('ready requires full image payload: $invalid', () async {
      mock((call) async => {...result(state: 'ready'), ...invalid});
      await expectLater(
          copy(),
          throwsA(isA<PlatformException>().having(
              (error) => error.code, 'code', 'image_original_incomplete')));
    });
  }

  test('a retained original ID keeps its separate canonical message-time key',
      () async {
    const retained = 'incoming-media:retained-image-original';
    mock((call) async {
      final args = call.arguments as Map;
      expect(args['messageId'], retained);
      expect(args['messageTimeKey'], message);
      return {...result(), 'messageId': retained};
    });
    final value = await adapter.copyImageFromMessageContext(
        evidence: evidence,
        target: target,
        customer: customer,
        messageId: retained,
        senderAt: sender,
        receiptId: receipt,
        automationEpoch: epoch);
    expect(value.messageId, retained);
    expect(value.senderAt, sender);
  });

  test('background polls retain proof and never invoke another UI operation',
      () async {
    final calls = <String>[];
    var count = 0;
    mock((call) async {
      calls.add(call.method);
      expect(call.method, 'pollImageOriginal');
      final args = call.arguments as Map;
      expect(args['token'], 'copied-image-token');
      expect(args['expectedCustomer'], customer);
      expect(args['messageId'], message);
      expect(args['messageTimeKey'], message);
      expect(args['senderAtMs'], sender.millisecondsSinceEpoch);
      expect(args['receiptId'], receipt);
      expect(args['automationEpoch'], epoch);
      return result(state: ++count < 3 ? 'pending' : 'ready');
    });
    expect((await poll()).ready, isFalse);
    expect((await poll()).ready, isFalse);
    final value = await poll();
    expect(value.ready, isTrue);
    expect(value.imageConfirmed, isTrue);
    expect(value.image!.bytes, [1, 2, 3]);
    expect(value.image!.captureSource, 'jd-message-context-copy-cache');
    expect(calls, List.filled(3, 'pollImageOriginal'));
  });

  test('actual adapter copy finishes its UI lease before background polling',
      () async {
    final copyStarted = Completer<void>();
    final pollStarted = Completer<void>();
    final copying = Completer<Object?>();
    final comparing = Completer<Object?>();
    var uiHeld = false;
    final events = <String>[];
    mock((call) async {
      if (call.method == 'copyImageFromMessageContext') {
        expect(uiHeld, isTrue);
        events.add('native-copy');
        copyStarted.complete();
        return copying.future;
      }
      expect(call.method, 'pollImageOriginal');
      expect(uiHeld, isFalse);
      events.add('background-poll');
      pollStarted.complete();
      return comparing.future;
    });
    final work = ImageAcquisitionRoute.run<ImageOriginalAcquisitionResult,
            ImageOriginalAcquisitionResult>(
        kind: 'unknown',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => true,
        viaVision: () async => fail('No rectangle permits this route'),
        copyUnderUiLease: () async {
          uiHeld = true;
          try {
            return await copy();
          } finally {
            uiHeld = false;
            events.add('ui-released');
          }
        },
        compareInBackground: (copied) async {
          expect(copied.token, 'copied-image-token');
          return poll();
        });
    await copyStarted.future;
    expect(events, ['native-copy']);
    copying.complete(result());
    await pollStarted.future;
    expect(uiHeld, isFalse);
    events.add('reply-ui-available');
    comparing.complete(result(state: 'ready'));
    expect((await work)!.ready, isTrue);
    expect(events, [
      'native-copy',
      'ui-released',
      'background-poll',
      'reply-ui-available',
    ]);
  });

  test('yield remains available while the native context copy is pending',
      () async {
    final copying = Completer<Object?>();
    final started = Completer<void>();
    mock((call) async {
      if (call.method == 'copyImageFromMessageContext') {
        started.complete();
        return copying.future;
      }
      expect(call.method, 'requestImageAcquisitionYield');
      expect((call.arguments as Map)['automationEpoch'], epoch);
      copying.complete({...result(), 'reason': 'acquisition_yielded'});
      return {'interrupted': true};
    });
    final work = copy();
    await started.future;
    expect(await adapter.requestImageAcquisitionYield(automationEpoch: epoch),
        isTrue);
    expect((await work).reason, 'acquisition_yielded');
  });
}
