import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const customer = 'jd_41aeec7741d05';
  for (final name in ['video-gray-after-reply', 'video-cover-after-reply']) {
    test('recorded $name keeps the incoming video above our same-second reply',
        () {
      final trace = jsonDecode(
              File('test/fixtures/v34_discovery/$name.json').readAsStringSync())
          as Map<String, dynamic>;
      final inspection = OcrInspection.fromMap(trace);
      final attempt = const OcrCaptureExtractor().analyze(inspection);
      final candidates = const OcrImageCandidateSelector().select(
        inspection,
        customer,
        includeTextDense: true,
        allowUnlabeledLatestImage: true,
        customerText: (attempt.capture?.messages ?? const [])
            .where((m) => m.direction == 'incoming' && m.media.isEmpty)
            .map((m) => m.body),
      );
      expect(inspection.activeCustomerId, customer);
      expect(attempt.latestVisibleSenderIsIncoming, isFalse,
          reason: 'The already-sent text reply is below the new video.');
      expect(candidates, hasLength(1));
      expect(candidates.single.x, inInclusiveRange(.26, .28));
      expect(candidates.single.y, inInclusiveRange(.38, .40));
      expect(candidates.single.height, greaterThan(.24));
      final clock = const OcrCaptureExtractor()
          .mediaClockForRegion(inspection, candidates.single);
      expect(clock.sentAt, DateTime.utc(2026, 11, 5, 5, 51, 2));
      expect(
          inspection.observations.any((line) =>
              line.text == 'What issue are you having with your TD630G?'),
          isTrue);
      expect(trace['chatContentSHA256'], hasLength(64));
    });
  }
}
