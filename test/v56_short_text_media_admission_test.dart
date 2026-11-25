import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const _customer = 'jd_synthetic_v56';
const _selector = OcrImageCandidateSelector();

// Synthetic OCR uses the failed run's proportions. The colored emoji shortcut
// strip lies above the AX composer boundary; it is UI, not a detected card.
OcrInspection _view({
  String? body,
  double confidence = .3,
  List<OcrVisualRegion> cards = const [],
  List<OcrVisualRegion> play = const [],
  List<OcrObservation> extra = const [],
}) =>
    OcrInspection(
      image: Uint8List(0),
      imageWidth: 2880,
      imageHeight: 1626,
      windowId: 7,
      windowTitle: 'Synthetic JD transcript',
      recognizedText: '',
      capturedAt: DateTime.utc(2026, 11, 11, 5, 42, 26),
      activeCustomerId: _customer,
      chatLeft: .24027777777777778,
      chatRight: .7479166666666667,
      chatTop: .20418204182041821,
      chatBottom: .7921279212792128,
      observations: [
        const OcrObservation(
          text: 'jd_synthetic_v56 13:42:24',
          confidence: 1,
          x: .2731531286279964,
          y: .6468775861266821,
          width: .12229363123575848,
          height: .0192443166125158,
        ),
        if (body != null)
          OcrObservation(
            text: body,
            confidence: confidence,
            x: .2790697672587735,
            y: .6863468640259017,
            width: .014534884028964579,
            height: .020594009174192074,
          ),
        // The emoji strip produces colored pixels but no OCR observations in
        // this failure. Inventing emoji text here would make the old <4-character
        // fallback reject the crop and hide the regression.
        const OcrObservation(
          text: '口、Aa国画◎',
          confidence: .3,
          x: .3226744205144995,
          y: .7915129148670434,
          width: .12645348442925347,
          height: .025967804414906315,
        ),
        ...extra,
      ],
      visualRegions: cards,
      unboundMediaRegions: play,
    );

// Selection order used by _captureWithVisibleMedia. A rejected short-text
// proposal must not reappear through the final screenshot fallback.
List<OcrVisualRegion> _acquisitionCards(OcrInspection view,
    {bool hasPinnedImage = false}) {
  final extraction = const OcrCaptureExtractor().analyze(view);
  var cards = _selector.select(view, _customer,
      allowUnlabeledLatestImage: true,
      includeTextDense: true,
      customerText: extraction.capture?.messages
              .where((message) => message.direction == 'incoming')
              .map((message) => message.body) ??
          const []);
  cards = _selector.recoverCustomerBlocks(view, _customer,
      owned: cards, hasPinnedImage: hasPinnedImage);
  if (cards.isEmpty && !extraction.latestIncomingHasText) {
    final fallback = _selector.fallbackLatestCustomerBlock(view, _customer);
    if (fallback != null) cards = [fallback];
  }
  return cards;
}

void main() {
  for (final body in ['ok', '1', 'hi', '好', 'ok.']) {
    test('uncertain short prose "$body" does not become an image receipt', () {
      final view = _view(body: body);
      expect(const OcrCaptureExtractor().analyze(view).latestIncomingHasText,
          isFalse,
          reason: 'The ordinary OCR threshold intentionally defers this text.');
      expect(_selector.recoverCustomerBlocks(view, _customer), isEmpty);
      expect(_selector.fallbackLatestCustomerBlock(view, _customer), isNull);
      expect(_acquisitionCards(view), isEmpty);
      expect(_acquisitionCards(view, hasPinnedImage: true), isEmpty,
          reason:
              'An unrelated cache pin cannot turn uncertain prose into media.');
    });
  }

  test('known short text stays text through the fallback entry point', () {
    final view = _view(body: 'ok', confidence: 1);
    expect(const OcrCaptureExtractor().analyze(view).latestIncomingHasText,
        isTrue);
    expect(_selector.fallbackLatestCustomerBlock(view, _customer), isNull);
    expect(_acquisitionCards(view), isEmpty);
  });

  test('a truly empty sender block still retains its bounded fallback', () {
    final view = _view(extra: const [
      OcrObservation(
        text: '格志打印机小耿',
        confidence: .3,
        x: .40,
        y: .71,
        width: .1,
        height: .02,
        rotationDegrees: 24,
        isWatermark: true,
      ),
    ]);
    final fallback = _selector.fallbackLatestCustomerBlock(view, _customer);
    expect(fallback, isNotNull);
    expect(fallback!.y, greaterThan(.666));
    expect(fallback.y + fallback.height, lessThan(view.chatBottom!));
    expect(fallback.y + fallback.height, lessThan(.7915129148670434 - .006),
        reason: 'The blank crop must stop before the merged editor toolbar.');
    final recovered =
        _selector.recoverCustomerBlocks(view, _customer, hasPinnedImage: true);
    expect(recovered, hasLength(1));
    expect(recovered.single.y + recovered.single.height,
        lessThan(.7915129148670434 - .006));
  });

  test('a terminal recommendation overlay still rejects the synthetic crop',
      () {
    final view = _view(extra: const [
      OcrObservation(
          text: '智能回复 -',
          confidence: 1,
          x: .4,
          y: .765,
          width: .12,
          height: .015),
      OcrObservation(
          text: '推荐操作：为客户推荐商品',
          confidence: 1,
          x: .4,
          y: .78,
          width: .2,
          height: .03),
    ]);
    expect(_selector.fallbackLatestCustomerBlock(view, _customer), isNull);
    expect(
        _selector.recoverCustomerBlocks(view, _customer, hasPinnedImage: true),
        isEmpty);
  });

  test('uncertain prose is retained even when a detector emits an inner strip',
      () {
    final view = _view(body: 'ok', cards: const [
      OcrVisualRegion(x: .25, y: .675, width: .03, height: .035, confidence: 1),
    ]);
    expect(_acquisitionCards(view), isEmpty);
  });

  test('a real detected image containing short OCR stays eligible', () {
    const image =
        OcrVisualRegion(x: .25, y: .675, width: .2, height: .10, confidence: 1);
    for (final confidence in [.3, 1.0]) {
      final view = _view(body: 'ok', confidence: confidence, cards: [image]);
      expect(_acquisitionCards(view), [image]);
      expect(
          _selector.shouldSaveImage(image, view.observations,
              fromVerifiedCache: false),
          isTrue);
    }
  });

  test('a detected video with short text keeps its exact play region', () {
    const video =
        OcrVisualRegion(x: .25, y: .675, width: .2, height: .10, confidence: 1);
    final view = _view(body: '1', play: [video]);
    expect(_acquisitionCards(view), [video]);
  });

  test('text inside a tall native image does not become a text bubble veto',
      () {
    const image =
        OcrVisualRegion(x: .25, y: .675, width: .2, height: .20, confidence: 1);
    final view = OcrInspection(
      image: Uint8List(0),
      imageWidth: 1000,
      imageHeight: 1000,
      windowTitle: 'Synthetic text in image',
      recognizedText: '',
      capturedAt: DateTime.utc(2026, 11, 11),
      activeCustomerId: _customer,
      chatLeft: .24,
      chatRight: .75,
      chatTop: .2,
      chatBottom: .9,
      observations: const [
        OcrObservation(
            text: 'jd_synthetic_v56 13:42:24',
            confidence: 1,
            x: .27,
            y: .64,
            width: .2,
            height: .02),
        OcrObservation(
            text: 'Printer status ready',
            confidence: 1,
            x: .28,
            y: .7,
            width: .13,
            height: .02),
      ],
      visualRegions: const [image],
    );
    expect(
        _selector.select(view, _customer,
            includeTextDense: true, customerText: ['Printer status ready']),
        [image]);
  });
}
