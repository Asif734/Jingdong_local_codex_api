import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const customer = 'jd_41aeec7741d05';
const fixtures = 'test/fixtures/v104_media_bounds';
Map<String, Object?> load(String name) => Map<String, Object?>.from(
    jsonDecode(File('$fixtures/$name.ocr.json').readAsStringSync()) as Map);

void main() {
  test(
      'previously verified image cannot become weak text after its card scrolls away',
      () {
    final data = load('clipped-card');
    final lines = (data['observations'] as List)
        .map((e) => Map<String, Object?>.from(e as Map))
        .toList();
    final printed = lines.singleWhere((e) => e['text'] == '日本に門*');
    printed.addAll({'text': 'ok', 'height': .018, 'confidence': .3});
    final old = OcrInspection.fromMap({
      ...data,
      'observations': lines,
      'physicalMediaRegions': [
        {
          'x': .27,
          'y': .72,
          'width': .10,
          'height': .08,
          'confidence': 1.0,
          'proof': 'full_card_pixels'
        }
      ]
    });
    final region = const OcrCaptureExtractor()
        .incomingMessageBlocks(old)
        .singleWhere((b) => b.sentAt == DateTime.utc(2026, 11, 24, 9, 29, 19))
        .region;
    printed['confidence'] = 1.0;
    final now = OcrInspection.fromMap({...data, 'observations': lines});
    expect(
        UnknownMessageClarifier.matchWeakScreenshotText(
            customer: customer,
            original: old,
            originalRegion: region,
            current: now,
            messages:
                const OcrCaptureExtractor().analyze(now).capture!.messages),
        isNull);
  });

  test('printed six-pixel image text cannot clarify an unknown media message',
      () {
    final view = OcrInspection.fromMap(load('clipped-card'));
    final blocks = const OcrCaptureExtractor().incomingMessageBlocks(view);
    final region = blocks
        .singleWhere((b) => b.sentAt == DateTime.utc(2026, 11, 24, 9, 29, 19))
        .region;
    final messages =
        const OcrCaptureExtractor().analyze(view).capture!.messages;
    // Check the fixture exercises the exact OCR output that was sent to API.
    expect(messages.any((m) => m.body == '日本に門*'), isTrue);
    expect(
        UnknownMessageClarifier.match(
            customer: customer,
            original: view,
            originalRegion: region,
            current: view,
            messages: messages),
        isNull);
  });

  for (final kind in ['image', 'video']) {
    test('known $kind pixels mask normal-sized text before media completes',
        () {
      final data = load('clipped-card');
      final observations = (data['observations'] as List)
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();
      final printed = observations.singleWhere((e) => e['text'] == '日本に門*');
      printed['height'] = .018;
      final before =
          OcrInspection.fromMap({...data, 'observations': observations});
      final region = const OcrCaptureExtractor()
          .incomingMessageBlocks(before)
          .singleWhere((b) => b.sentAt == DateTime.utc(2026, 11, 24, 9, 29, 19))
          .region;
      final card = {
        'x': .27,
        'y': .72,
        'width': .10,
        'height': .08,
        'confidence': 1.0,
        'proof': kind == 'image' ? 'full_card_pixels' : 'explicit_play_overlay'
      };
      final now = OcrInspection.fromMap({
        ...data,
        'observations': observations,
        kind == 'image' ? 'physicalMediaRegions' : 'unboundMediaRegions': [card]
      });
      // Caller omissions must not expose text inside already detected media.
      final messages =
          const OcrCaptureExtractor().analyze(before).capture!.messages;
      expect(
          UnknownMessageClarifier.match(
              customer: customer,
              original: before,
              originalRegion: region,
              current: now,
              messages: messages),
          isNull);
    });
  }
}
