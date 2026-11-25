import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/text_first_ocr_policy.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  test(
      'two different unproductive frames skip redundant fast OCR only for that customer',
      () {
    final policy = TextFirstOcrPolicy();
    final now = DateTime.utc(2026, 11, 17);
    policy.record('buyer', 'one', now, useful: false);
    policy.record('buyer', 'one', now, useful: false);
    expect(policy.shouldTry('buyer', now), isTrue);
    policy.record('buyer', 'two', now, useful: false);
    expect(policy.shouldTry('buyer', now), isFalse);
    expect(policy.shouldTry('other buyer', now), isTrue);
    expect(policy.shouldTry('buyer', now.add(const Duration(seconds: 15))),
        isTrue);
    policy.record('buyer', 'three', now.add(const Duration(seconds: 15)),
        useful: true);
    expect(policy.shouldTry('buyer', now.add(const Duration(seconds: 16))),
        isTrue);
  });

  test('an old video and a later seller reply do not veto safe customer text',
      () {
    final view = OcrInspection(
      image: Uint8List(0),
      imageWidth: 2880,
      imageHeight: 1626,
      windowTitle: 'saved',
      recognizedText: '',
      activeCustomerId: 'buyer',
      ocrEngine: 'apple_vision_text_first',
      capturedAt: DateTime.utc(2026, 11, 3, 9, 24),
      chatLeft: .24,
      chatRight: .75,
      chatTop: .2,
      chatBottom: .85,
      observations: const [
        OcrObservation(
            text: 'buyer 17:22:01',
            confidence: .99,
            x: .27,
            y: .28,
            width: .14,
            height: .02),
        OcrObservation(
            text: 'buyer 17:23:34',
            confidence: .99,
            x: .27,
            y: .52,
            width: .14,
            height: .02),
        OcrObservation(
            text: 'How do I connect USB?',
            confidence: .99,
            x: .28,
            y: .55,
            width: .15,
            height: .02),
        OcrObservation(
            text: '格志打印机小耿 17:23:40',
            confidence: .99,
            x: .50,
            y: .65,
            width: .22,
            height: .02),
        OcrObservation(
            text: '您好',
            confidence: .99,
            x: .64,
            y: .68,
            width: .04,
            height: .02),
      ],
      unboundMediaRegions: const [
        OcrVisualRegion(x: .28, y: .32, width: .14, height: .14, confidence: 1),
      ],
    );
    const extractor = OcrCaptureExtractor();
    final plan = extractor.planTextFirst(view, 'buyer');
    expect(plan.independentText?.messages.map((m) => m.body),
        ['How do I connect USB?']);
    expect(plan.needsFullRecognition, isFalse, reason: plan.reasons.toString());

    final caption = view.withObservations([
      ...view.observations.take(2),
      const OcrObservation(
          text: '请看上面的视频',
          confidence: .99,
          x: .28,
          y: .55,
          width: .15,
          height: .02),
      ...view.observations.skip(3),
    ]);
    expect(extractor.planTextFirst(caption, 'buyer').independentText, isNull);
  });

  test('text-first accepts a complete timed turn but defers ambiguous frames',
      () {
    const extractor = OcrCaptureExtractor();
    OcrInspection inspect({
      String header = 'buyer 17:23:34',
      String body = 'Please check the printer',
      double confidence = .99,
      List<OcrVisualRegion> media = const [],
      String customer = 'buyer',
    }) =>
        OcrInspection(
          image: Uint8List(0),
          imageWidth: 2880,
          imageHeight: 1626,
          windowTitle: 'saved',
          recognizedText: '',
          activeCustomerId: customer,
          ocrEngine: 'apple_vision_text_first',
          capturedAt: DateTime.utc(2026, 11, 3, 9, 24),
          chatLeft: .24,
          chatRight: .75,
          chatTop: .2,
          chatBottom: .85,
          unboundMediaRegions: media,
          observations: [
            OcrObservation(
                text: header,
                confidence: 1,
                x: .273,
                y: .3,
                width: .2,
                height: .02),
            OcrObservation(
                text: body,
                confidence: confidence,
                x: .28,
                y: .35,
                width: .14,
                height: .02),
          ],
        );
    expect(extractor.acceptsTextFirst(inspect(), 'buyer'), isTrue);
    expect(extractor.acceptsTextFirst(inspect(header: 'buyer 17:23'), 'buyer'),
        isFalse);
    expect(
        extractor.acceptsTextFirst(inspect(body: 'D', confidence: .3), 'buyer'),
        isFalse);
    expect(extractor.acceptsTextFirst(inspect(customer: 'other'), 'buyer'),
        isFalse);
    expect(
        extractor.acceptsTextFirst(
            inspect(media: const [
              OcrVisualRegion(
                  x: .29, y: .48, width: .12, height: .1, confidence: 1),
            ]),
            'buyer'),
        isFalse);
  });
}
