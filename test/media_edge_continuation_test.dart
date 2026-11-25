import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_card_occurrence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const anchor = '请先关机确认纸张的热敏面朝向再打印一张试试';
  const card =
      OcrVisualRegion(x: .265, y: .35, width: .12, height: .25, confidence: 1);
  OcrObservation line(double y, {double x = .49}) => OcrObservation(
      text: anchor, confidence: .98, x: x, y: y, width: .2, height: .018);
  OcrInspection view(List<OcrObservation> lines, {String customer = 'buyer'}) =>
      OcrInspection(
          image: Uint8List(0),
          imageWidth: 2880,
          imageHeight: 1620,
          windowTitle: '',
          recognizedText: '',
          capturedAt: DateTime.utc(2026),
          activeCustomerId: customer,
          chatLeft: .23,
          chatRight: .75,
          chatTop: .21,
          chatBottom: .8,
          observations: lines);
  test('projects a clipped older card above the same seller reply', () {
    final before =
        MediaCardOccurrenceContext.inspect(view([line(.67)]), 'buyer', card);
    final part = before.projectClippedCard(view([line(.33)]), card);
    expect(part, isNotNull);
    expect(part!.y, closeTo(.21, .0001));
    expect(part.y + part.height, closeTo(.266, .0001));
    expect(
        before.projectClippedCard(view([line(.33), line(.38)]), card), isNull);
    expect(before.projectClippedCard(view([line(.33, x: .26)]), card), isNull);
    expect(
        before.projectClippedCard(view([line(.33)], customer: 'other'), card),
        isNull);
  });
  test(
      'recorded viewport geometry distinguishes the old video from the next card',
      () {
    const old = OcrVisualRegion(
        x: .26458, y: .37171, width: .11262, height: .23122, confidence: 1);
    OcrObservation seller(double y, double x) => OcrObservation(
        text: anchor, confidence: 1, x: x, y: y, width: .336, height: .022);
    final prior = MediaCardOccurrenceContext.inspect(
        view([seller(.660516605, .372093023)]), 'buyer', old);
    final fragment =
        prior.projectClippedCard(view([seller(.367609254, .370639536)]), old);
    expect(fragment, isNotNull);
    expect(fragment!.y + fragment.height, closeTo(.316022649, .0001));
    expect(fragment.y + fragment.height, lessThan(.44)); // Next video.
  });
  test(
      'uses the next timestamped customer message as an anchor without seller prose',
      () {
    OcrObservation header(String time, double y) => OcrObservation(
        text: 'buyer $time',
        confidence: .95,
        x: .27,
        y: y,
        width: .11,
        height: .014);
    final prior = MediaCardOccurrenceContext.inspect(
        view([header('11:52:44', .32), header('11:52:50', .66)]),
        'buyer',
        card);
    final clipped =
        prior.projectClippedCard(view([header('11:52:50', .32)]), card);
    expect(clipped, isNotNull);
    expect(clipped!.y + clipped.height, lessThan(.32));
    expect(prior.projectClippedCard(view([header('11:52:51', .32)]), card),
        isNull);
    expect(
        prior.projectClippedCard(
            view([header('11:52:44', .235), header('11:52:50', .32)]), card),
        isNull);
  });
}
