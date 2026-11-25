import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const extractor = OcrCaptureExtractor();
  const fullCard = OcrVisualRegion(
      x: .26697099208831787,
      y: .37639349699020386,
      width: .12160047888755798,
      height: .2719424068927765,
      confidence: 1);
  OcrObservation header(String time, double y,
          {bool seller = false, double confidence = 1}) =>
      OcrObservation(
          text: seller ? '$time 格志测试客服' : 'jd_fixture_customer $time',
          confidence: confidence,
          x: seller ? .615 : .2747,
          y: y,
          width: .13,
          height: .018110271162945724);
  OcrInspection frame(List<OcrObservation> lines) => OcrInspection(
      image: Uint8List(0),
      imageWidth: 2880,
      imageHeight: 1626,
      windowTitle: 'saved customer frame',
      recognizedText: '',
      activeCustomerId: 'jd_fixture_customer',
      windowId: 7,
      capturedAt: DateTime.utc(2026, 11, 4, 8, 38),
      chatTop: .20418204182041821,
      chatBottom: .8044280442804428,
      chatLeft: .24027777777777778,
      chatRight: .7479166666666667,
      observations: lines);

  test('recorded media/header overlap keeps its own 16:33:33 clock', () {
    final inspection = frame([
      header('16:33:23', .2724477242664871),
      header('16:33:33', .36503856050813477)
    ]);
    final evidence = extractor.mediaClockForRegion(inspection, fullCard);
    expect(evidence.sentAt, DateTime.utc(2026, 11, 4, 8, 33, 33));
    expect(evidence.source, 'ocr_media_sender_header');
    expect(evidence.headerBottom, greaterThan(fullCard.y + .002));
    expect(
        extractor.incomingClockAbove(inspection, fullCard.y), evidence.sentAt);
  });
  test('partial old card cannot borrow the later 好的 message clock', () {
    const partial = OcrVisualRegion(
        x: .2671072781085968,
        y: .22904598712921143,
        width: .12029555439949036,
        height: .1616554856300354,
        confidence: 1);
    final inspection = frame([
      header('16:33:46', .4034440344184489, seller: true),
      header('16:34:24', .49614395903714026, seller: true),
      header('16:34:25', .6605166050633451)
    ]);
    expect(extractor.analyze(inspection).latestIncomingSentAt,
        DateTime.utc(2026, 11, 4, 8, 34, 25));
    expect(extractor.mediaClockForRegion(inspection, partial).sentAt, isNull);
  });
  test('a nearby preceding text bubble cannot replace a missing media header',
      () {
    final inspection = frame([
      header('16:33:23', .325),
      const OcrObservation(
          text: 'Please inspect this',
          confidence: 1,
          x: .28,
          y: .349,
          width: .15,
          height: .018)
    ]);
    final evidence = extractor.mediaClockForRegion(inspection, fullCard);
    expect(evidence.sentAt, isNull);
    expect(evidence.source, 'media_header_already_owns_text');
  });
  test('photo text inside the media cannot provide a newer sender clock', () {
    final inspection =
        frame([header('16:33:33', .36503856050813477), header('16:37:00', .5)]);
    expect(extractor.mediaClockForRegion(inspection, fullCard).sentAt,
        DateTime.utc(2026, 11, 4, 8, 33, 33));
  });
  test(
      'a seller header between an older incoming header and the card rejects association',
      () {
    final inspection =
        frame([header('16:33:23', .30), header('16:33:30', .35, seller: true)]);
    expect(extractor.mediaClockForRegion(inspection, fullCard).sentAt, isNull);
  });
  test('an unrelated distant incoming header does not timestamp a media card',
      () {
    final inspection = frame([header('16:33:23', .23)]);
    expect(extractor.mediaClockForRegion(inspection, fullCard).source,
        'media_header_not_adjacent');
    expect(extractor.mediaClockForRegion(inspection, fullCard).sentAt, isNull);
  });
  test(
      'a low-confidence exact header remains direction evidence without changing AX identity',
      () {
    final inspection =
        frame([header('16:33:33', .36503856050813477, confidence: .3)]);
    final evidence = extractor.mediaClockForRegion(inspection, fullCard);
    expect(evidence.sentAt, DateTime.utc(2026, 11, 4, 8, 33, 33));
    expect(evidence.confidence, .3);
    expect(extractor.analyze(inspection).customerId, 'jd_fixture_customer');
  });
  test('later customer text does not timestamp the preceding video', () {
    final inspection = frame([
      header('16:37:28', .3631634522898861),
      header('16:37:36', .6605166049967651)
    ]);
    expect(extractor.mediaClockForRegion(inspection, fullCard).sentAt,
        DateTime.utc(2026, 11, 4, 8, 37, 28));
  });
  test('seller-column media does not acquire an incoming header', () {
    final evidence = extractor.mediaClockForRegion(
        frame([header('16:33:33', .365)]),
        const OcrVisualRegion(
            x: .60, y: .4, width: .1, height: .2, confidence: 1));
    expect(evidence.sentAt, isNull);
    expect(evidence.source, 'region_not_incoming_media');
  });
}
