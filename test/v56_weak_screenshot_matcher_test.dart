import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const customer = 'jd_41aeec7741d05';
final captured = DateTime.utc(2026, 11, 11, 5, 42, 30);

OcrInspection frame({
  double confidence = .3,
  double headerY = .646,
  String body = 'ok',
  String clock = '13:42:24',
  String identity = customer,
  List<Map<String, Object?>> media = const [],
  int secondsLater = 0,
  bool duplicateHeader = false,
}) =>
    OcrInspection.fromMap({
      'activeCustomerId': identity,
      'capturedAtMs':
          captured.add(Duration(seconds: secondsLater)).millisecondsSinceEpoch,
      'imageWidth': 2880,
      'imageHeight': 1626,
      'windowId': 1,
      'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .792},
      'observations': [
        {
          'text': '$customer $clock',
          'confidence': 1.0,
          'x': .27,
          'y': headerY,
          'width': .28,
          'height': .02,
        },
        {
          'text': body,
          'confidence': confidence,
          'x': .28,
          'y': headerY + .04,
          'width': .015,
          'height': .015,
        },
        if (duplicateHeader)
          {
            'text': '$customer $clock',
            'confidence': 1.0,
            'x': .27,
            'y': .28,
            'width': .28,
            'height': .02,
          },
      ],
      'visualRegions': media,
    });

void main() {
  final original = frame();
  final region =
      const OcrCaptureExtractor().incomingMessageBlocks(original).single.region;
  Object? match(OcrInspection now,
          {OcrInspection? before,
          OcrVisualRegion? box,
          List<OcrVisualRegion> excluded = const []}) =>
      UnknownMessageClarifier.matchWeakScreenshotText(
        customer: customer,
        original: before ?? original,
        originalRegion: box ?? region,
        current: now,
        messages:
            const OcrCaptureExtractor().analyze(now).capture?.messages ?? [],
        excludedRegions: excluded,
      );

  test('low-confidence ok becomes text on the same clock after scrolling', () {
    final now = frame(confidence: 1, headerY: .36, secondsLater: 16);
    final found = UnknownMessageClarifier.matchWeakScreenshotText(
        customer: customer,
        original: original,
        originalRegion: region,
        current: now,
        messages: const OcrCaptureExtractor().analyze(now).capture!.messages);
    expect(found?.body, 'ok');
    expect(found?.sentAt, DateTime.utc(2026, 11, 11, 5, 42, 24));
  });
  test('different sender second cannot correct the old screenshot', () {
    expect(match(frame(confidence: 1, clock: '13:42:25')), isNull);
  });
  test('different AX customer cannot correct the old screenshot', () {
    expect(match(frame(confidence: 1, identity: 'someone_else')), isNull);
  });
  test('a different confident text does not prove the old short bubble', () {
    expect(match(frame(confidence: 1, body: 'hi')), isNull);
  });
  test('no readable original hint does not retract a loading image', () {
    expect(match(frame(confidence: 1), before: frame(body: '')), isNull);
  });
  test('a real detected image containing ok remains media', () {
    final image = <String, Object?>{
      'x': .27,
      'y': .675,
      'width': .22,
      'height': .1,
      'confidence': 1.0,
    };
    expect(match(frame(confidence: 1), before: frame(media: [image])), isNull);
    expect(match(frame(confidence: 1, media: [image])), isNull);
  });
  test('text inside a current masked media region is not chat prose', () {
    expect(match(frame(confidence: 1), excluded: [region]), isNull);
  });
  test('a stale frame or ambiguous original clock cannot correct the parent',
      () {
    expect(match(frame(confidence: 1, secondsLater: -1)), isNull);
    final duplicate = frame(duplicateHeader: true);
    expect(match(frame(confidence: 1), before: duplicate), isNull);
  });
  test('a nearby arbitrary crop is not an original sender block', () {
    expect(
        match(frame(confidence: 1),
            box: OcrVisualRegion(
                x: region.x,
                y: region.y + .01,
                width: region.width,
                height: region.height,
                confidence: 0)),
        isNull);
  });
}
