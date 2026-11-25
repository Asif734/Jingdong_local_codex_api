import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_chat_layout.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

OcrObservation text(String value,
        {double x = .25,
        double y = .7915,
        double width = .22,
        double height = .03,
        double confidence = .3}) =>
    OcrObservation(
        text: value,
        confidence: confidence,
        x: x,
        y: y,
        width: width,
        height: height);

OcrInspection inspection(List<OcrObservation> lines,
        {double bottom = .7922, List<OcrVisualRegion> media = const []}) =>
    OcrInspection(
        image: Uint8List(0),
        imageWidth: 1600,
        imageHeight: 1000,
        windowTitle: 'synthetic',
        recognizedText: '',
        capturedAt: DateTime.utc(2026, 11, 11),
        chatTop: .2,
        chatBottom: bottom,
        chatLeft: .24,
        chatRight: .75,
        observations: lines,
        visualRegions: media);

void main() {
  test('merged low-confidence toolbar may straddle the raw AX bottom', () {
    final toolbar = text('口、Aa国画◎');
    final layout = OcrChatLayout(inspection([toolbar]));
    expect(toolbar.y + toolbar.height / 2, greaterThan(layout.bottom));
    expect(layout.isInterface(toolbar), isTrue);
    expect(
        layout.allowedMedia(const OcrVisualRegion(
            x: .26, y: .670, width: .30, height: .122, confidence: .7)),
        isFalse);
    expect(
        layout.allowedMedia(const OcrVisualRegion(
            x: .26, y: .55, width: .30, height: .15, confidence: 1)),
        isTrue);
  });

  test('icon spelling alone never masks customer prose or emoji', () {
    for (final line in [
      text('😀😀😀😀😀'),
      text('Aa国画'),
      text('Please use Aa and these icons 口◎'),
      text('口、Aa国画◎', y: .6),
      text('口、Aa国画◎', x: .55, width: .18),
    ]) {
      expect(OcrChatLayout(inspection([line])).isInterface(line), isFalse);
    }
  });

  test('a complete toolbar row printed inside customer media stays media', () {
    final toolbar = text('口、Aa国画◎', y: .82, height: .015);
    const image =
        OcrVisualRegion(x: .25, y: .71, width: .30, height: .13, confidence: 1);
    final layout =
        OcrChatLayout(inspection([toolbar], bottom: .85, media: const [image]));
    expect(layout.isInterface(toolbar), isFalse);
    expect(layout.allowedMedia(image), isTrue);
    final aa = text('Aa', x: .36, y: .82, width: .025, height: .015);
    final exact =
        OcrChatLayout(inspection([aa], bottom: .85, media: const [image]));
    expect(exact.isInterface(aa), isFalse);
    expect(exact.allowedMedia(image), isTrue);
  });

  test('nearby sender-clock evidence prevents treating text as a toolbar', () {
    final toolbar = text('口、Aa国画◎', height: .012);
    final clock =
        text('synthetic 12:34:56', y: .780, height: .01, confidence: 1);
    final layout = OcrChatLayout(inspection([clock, toolbar]));
    expect(layout.isInterface(toolbar), isFalse);
  });

  test('a structural native bottom excludes the shortcut strip without OCR',
      () {
    final emoji = text('😀😁😂😃😄', y: .74, height: .025);
    final layout = OcrChatLayout(inspection([emoji], bottom: .735));
    expect(layout.inTranscript(emoji), isFalse);
    expect(layout.isInterface(emoji), isFalse);
    expect(
        layout.allowedMedia(const OcrVisualRegion(
            x: .26, y: .670, width: .30, height: .122, confidence: .7)),
        isFalse);
    expect(
        layout.allowedMedia(const OcrVisualRegion(
            x: .26, y: .57, width: .30, height: .16, confidence: 1)),
        isTrue);
  });
}
