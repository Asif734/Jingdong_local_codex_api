import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  OcrInspection fixture(String name) => OcrInspection.fromMap(jsonDecode(
          File('test/fixtures/ocr_regressions/$name.json').readAsStringSync())
      as Map<String, dynamic>);
  test('recorded hi never absorbs the JD last-session card', () {
    final inspection = fixture('summary');
    final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
    final incoming =
        capture.messages.where((m) => m.direction == 'incoming').toList();
    expect(incoming.map((m) => m.body), ['hi']);
    expect(
        const OcrImageCandidateSelector()
            .select(inspection, 'jd_fixture_customer', includeTextDense: true),
        isEmpty);
  });
  test(
      'recorded window title is not a sender for a scrolled seller text bubble',
      () {
    final inspection = fixture('seller');
    final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
    expect(
        capture.messages
            .where((m) => m.direction == 'incoming')
            .map((m) => m.body),
        ['where can i get this app?']);
    expect(
        const OcrImageCandidateSelector()
            .select(inspection, 'jd_fixture_customer', includeTextDense: true),
        isEmpty);
  });
  test(
      'recorded customer photo stays eligible below the real sender, not header',
      () {
    final inspection = fixture('photo');
    final regions = const OcrImageCandidateSelector()
        .select(inspection, 'jd_fixture_customer', includeTextDense: true);
    expect(regions, hasLength(1));
    expect(regions.single.y, greaterThan(.519));
    expect(
        const OcrCaptureExtractor()
            .incomingClockAbove(inspection, regions.single.y),
        DateTime.utc(2026, 11, 1, 4, 32, 10));
  });
  test(
      'summary words inside a narrow customer screenshot are still eligible media',
      () {
    final inspection = OcrInspection(
        image: Uint8List(0),
        imageWidth: 1600,
        imageHeight: 1200,
        windowTitle: 'fixture',
        recognizedText: '',
        capturedAt: DateTime.now(),
        activeCustomerId: 'jd_fixture_customer',
        chatLeft: .24,
        chatRight: .75,
        chatTop: .2,
        chatBottom: .84,
        observations: const [
          OcrObservation(
              text: 'jd_fixture_customer 12:32:10',
              confidence: 1,
              x: .27,
              y: .3,
              width: .2,
              height: .02),
          OcrObservation(
              text: '上次会话小结',
              confidence: 1,
              x: .28,
              y: .35,
              width: .1,
              height: .02),
          OcrObservation(
              text: '设置 收起',
              confidence: 1,
              x: .38,
              y: .35,
              width: .08,
              height: .02),
          OcrObservation(
              text: '用户诉求：截图内容',
              confidence: 1,
              x: .28,
              y: .4,
              width: .16,
              height: .02),
          OcrObservation(
              text: '客服方案：截图内容',
              confidence: 1,
              x: .28,
              y: .45,
              width: .16,
              height: .02)
        ],
        visualRegions: const [
          OcrVisualRegion(
              x: .26, y: .34, width: .22, height: .25, confidence: 1)
        ]);
    expect(
        const OcrImageCandidateSelector()
            .select(inspection, 'jd_fixture_customer', includeTextDense: true),
        hasLength(1));
  });
}
