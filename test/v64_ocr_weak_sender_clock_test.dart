import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

// Geometry and clock pattern of the incident, with synthetic names and text.
const _axId = 'jd_0a123bc4567de';

OcrInspection _frame({
  String? weakHeader = '易 i0 0a123bc456de 13:26:24',
  String? customer = _axId,
  List<OcrVisualRegion> visualRegions = const [],
}) =>
    OcrInspection(
      image: Uint8List(0),
      imageWidth: 2880,
      imageHeight: 1626,
      windowTitle: 'fixture',
      recognizedText: '',
      capturedAt: DateTime.utc(2026, 11, 15, 5, 26, 36),
      activeCustomerId: customer,
      chatLeft: .240278,
      chatRight: .747917,
      chatTop: .204182,
      chatBottom: .792128,
      visualRegions: visualRegions,
      observations: [
        const OcrObservation(
            text: '$_axId 13:23:14',
            confidence: 1,
            x: .2718,
            y: .4625,
            width: .1177,
            height: .0157),
        const OcrObservation(
            text: '上一条客户文字',
            confidence: 1,
            x: .2791,
            y: .4987,
            width: .0887,
            height: .0234),
        const OcrObservation(
            text: '13:24:51 格志打印机小甲',
            confidence: .5,
            x: .6134,
            y: .5553,
            width: .1032,
            height: .0180),
        const OcrObservation(
            text: '请问，您需要客服协助吗？',
            confidence: 1,
            x: .5509,
            y: .5910,
            width: .1541,
            height: .0259),
        const OcrObservation(
            text: '已读',
            confidence: 1,
            x: .5218,
            y: .6039,
            width: .0189,
            height: .0209),
        if (weakHeader != null)
          OcrObservation(
              text: weakHeader,
              confidence: .3,
              x: .2489,
              y: .6321,
              width: .1413,
              height: .0534,
              rotationDegrees: 7.747),
        const OcrObservation(
            text: '我还是不明白',
            confidence: 1,
            x: .2790,
            y: .6836,
            width: .0611,
            height: .0236,
            rotationDegrees: -.424),
      ],
    );

void main() {
  const extractor = OcrCaptureExtractor();

  test('unfolds the incident transcript by side and exact AX-owned second', () {
    final result = extractor.analyze(_frame());
    final messages = result.capture!.messages;
    expect(
        messages.map((m) => m.direction), ['incoming', 'outgoing', 'incoming']);
    expect(messages[1].body, '请问，您需要客服协助吗？');
    expect(messages.last.body, '我还是不明白');
    expect(messages.last.sender, _axId);
    expect(messages.last.sentAt, DateTime.utc(2026, 11, 15, 5, 26, 24));
    expect(messages.last.stableId, 'incoming-time:$_axId:2026-11-15T05:26:24Z');
    expect(result.latestVisibleSenderIsIncoming, isTrue);
  });

  test('an absent header never assigns clearly left text to a seller', () {
    final messages =
        extractor.analyze(_frame(weakHeader: null)).capture!.messages;
    expect(messages.map((m) => m.direction), ['incoming', 'outgoing']);
    expect(messages.last.body, '请问，您需要客服协助吗？');
  });

  test(
      'damaged header without seconds stays on the left with no invented clock',
      () {
    final result =
        extractor.analyze(_frame(weakHeader: '易 i0 0a123bc456de 13:26'));
    final messages = result.capture!.messages;
    expect(messages[1].body, '请问，您需要客服协助吗？');
    expect(messages.last.body, '我还是不明白');
    expect(messages.last.sentAt, isNull);
    expect(messages.last.stableId, isNot(startsWith('incoming-time:')));
    expect(result.latestIncomingSentAt, isNull);
  });

  test('foreign OCR sender cannot supply the AX customer or their clock', () {
    final result =
        extractor.analyze(_frame(weakHeader: '易 i0 987654321098 13:26:24'));
    expect(result.capture!.messages.last.direction, 'outgoing');
    expect(result.capture!.messages.last.body, isNot(contains('我还是')));
    expect(extractor.analyze(_frame(customer: null)).capture, isNull);
  });

  test('ID-like content printed inside a customer media card is not a header',
      () {
    const card = OcrVisualRegion(
        x: .24, y: .628, width: .20, height: .11, confidence: 1);
    final result = extractor.analyze(_frame(visualRegions: const [card]));
    expect(result.capture!.messages.last.direction, 'outgoing');
    expect(result.capture!.messages.last.body, isNot(contains('我还是')));
  });

  OcrObservation refinedTime(String text, {double x = .31}) => OcrObservation(
      text: text, confidence: .93, x: x, y: .646, width: .04, height: .016);

  test('a unique clock recovered in the original header crop can key the body',
      () async {
    final view = _frame(weakHeader: '易 i0 0a123bc456de 13:26');
    var crops = 0;
    final repaired = await extractor.refineIncomingClockHeaders(view,
        refine: (region) async {
      crops++;
      expect(region.y + region.height, lessThan(.687));
      return [refinedTime('13:26:24')];
    });
    expect(crops, 1);
    final message = extractor.analyze(repaired).capture!.messages.last;
    expect(message.sentAt, DateTime.utc(2026, 11, 15, 5, 26, 24));
    expect(message.body, '我还是不明白');
  });

  test('conflicts and out-of-crop results leave the saved frame unchanged',
      () async {
    final view = _frame(weakHeader: '易 i0 0a123bc456de 13:26');
    for (final lines in [
      [refinedTime('13:26:24'), refinedTime('13:26:25')],
      [refinedTime('13:25:24')],
      [refinedTime('13:26:24', x: .55)],
      [refinedTime('jd_1234500000 13:26:24')],
    ]) {
      final result = await extractor.refineIncomingClockHeaders(view,
          refine: (_) async => lines);
      expect(result, same(view));
      expect(extractor.analyze(result).latestIncomingSentAt, isNull);
    }
  });

  test('a weak hour cannot backdate a later bubble across its seller header',
      () async {
    final view = _frame(weakHeader: '易 i0 0a123bc456de 18:26:24');
    expect(extractor.analyze(view).latestIncomingSentAt, isNull);
    final repaired = await extractor.refineIncomingClockHeaders(view,
        refine: (_) async => [refinedTime('13:26:24')]);
    expect(extractor.analyze(repaired).latestIncomingSentAt,
        DateTime.utc(2026, 11, 15, 5, 26, 24));
  });
}
