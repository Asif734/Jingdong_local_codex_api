import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const _buyer = 'jd_41aeec7741d05';
const _question = 'can you share me a video?';
const _fixtures = 'test/fixtures/v39_message_correction';

void main() {
  late OcrInspection original;
  late OcrVisualRegion region;
  Future<Map<String, Object?>> source(String name) async =>
      Map<String, Object?>.from(
          jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
              as Map);
  Future<OcrInspection> frame(String name) async =>
      OcrInspection.fromMap(await source(name));
  setUp(() async {
    original = await frame('clipped-text');
    region = const OcrImageCandidateSelector()
        .fallbackLatestCustomerBlock(original, _buyer)!;
  });
  for (final phase in ['early-full-text', 'full-text']) {
    test('recorded $phase clarifies the same clipped bubble', () async {
      final now = await frame(phase);
      final messages =
          const OcrCaptureExtractor().analyze(now).capture!.messages;
      final found = UnknownMessageClarifier.match(
          customer: _buyer,
          original: original,
          originalRegion: region,
          current: now,
          messages: messages);
      expect(found, isNotNull);
      expect(found!.body, _question);
      expect(found.sentAt, DateTime.utc(2026, 11, 8, 7, 40, 39));
    });
  }
  test('equal timestamp without the same preceding block grants no match',
      () async {
    final now = await frame('early-full-text');
    final altered = now.withObservations([
      for (final line in now.observations)
        if (line.text.contains('15:39:53'))
          OcrObservation(
              text: line.text.replaceAll('15:39:53', '15:39:54'),
              confidence: line.confidence,
              x: line.x,
              y: line.y,
              width: line.width,
              height: line.height)
        else
          line,
    ]);
    expect(
        UnknownMessageClarifier.match(
            customer: _buyer,
            original: original,
            originalRegion: region,
            current: altered,
            messages:
                const OcrCaptureExtractor().analyze(altered).capture!.messages),
        isNull);
  });
  test('a second real bubble in the same second remains distinct', () async {
    final now = await frame('early-full-text');
    final current = now.withObservations([
      ...now.observations,
      const OcrObservation(
          text: 'jd_41aeec7741d05 15:40:39',
          confidence: 1,
          x: .273,
          y: .735,
          width: .2,
          height: .018),
      const OcrObservation(
          text: 'and how do I change the ribbon?',
          confidence: 1,
          x: .28,
          y: .764,
          width: .21,
          height: .018),
    ]);
    final messages =
        const OcrCaptureExtractor().analyze(current).capture!.messages;
    final blocks = IncomingTextBlock.locate(current, _buyer, messages)
        .where((b) => b.message.sentAt == DateTime.utc(2026, 11, 8, 7, 40, 39))
        .toList();
    expect(blocks, hasLength(2));
    final found = UnknownMessageClarifier.match(
        customer: _buyer,
        original: original,
        originalRegion: region,
        current: current,
        messages: messages);
    expect(found!.body, _question);
    expect(found.stableId, isNot(blocks.last.message.stableId));
  });
  test('text in a verified media region cannot clarify the placeholder',
      () async {
    final now = await frame('early-full-text');
    expect(
        UnknownMessageClarifier.match(
            customer: _buyer,
            original: original,
            originalRegion: region,
            current: now,
            messages:
                const OcrCaptureExtractor().analyze(now).capture!.messages,
            excludedRegions: const [
              OcrVisualRegion(
                  x: .25, y: .67, width: .25, height: .06, confidence: 1),
            ]),
        isNull);
  });
  test('wrong AX identity cannot attach the correct-looking text', () async {
    final raw = await source('early-full-text');
    final wrong = OcrInspection.fromMap({...raw, 'activeCustomerId': 'other'});
    expect(
        UnknownMessageClarifier.match(
            customer: _buyer,
            original: original,
            originalRegion: region,
            current: wrong,
            messages:
                const OcrCaptureExtractor().analyze(wrong).capture?.messages ??
                    []),
        isNull);
  });
  test('a detected media rectangle is not a header-only placeholder', () async {
    final now = await frame('early-full-text');
    expect(
        UnknownMessageClarifier.match(
            customer: _buyer,
            original: original,
            originalRegion: const OcrVisualRegion(
                x: .27, y: .71, width: .15, height: .07, confidence: 1),
            current: now,
            messages:
                const OcrCaptureExtractor().analyze(now).capture!.messages),
        isNull);
  });
}
