import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  late Map<String, Object?> recorded;
  setUp(() async {
    recorded = Map<String, Object?>.from(jsonDecode(
        await File('test/fixtures/v44_text_body/clipped-seller-header.ocr.json')
            .readAsString()) as Map);
  });

  test('recorded damaged seller header cannot extend the TD630 question', () {
    final result =
        const OcrCaptureExtractor().analyze(OcrInspection.fromMap(recorded));
    final question = result.capture!.messages
        .where((m) => m.body.startsWith('i got some issue regarding'))
        .single;
    expect(question.body, 'i got some issue regarding td630');
    expect(question.direction, 'incoming');
    expect(question.sender, 'jd_41aeec7741d05');
    expect(result.latestVisibleSenderIsIncoming, isFalse);
  });

  test('the same words inside the incoming body remain customer content', () {
    final observations = (recorded['observations'] as List)
        .map((o) => Map<String, Object?>.from(o as Map))
        .toList();
    final damaged = observations
        .singleWhere((o) => (o['text'] as String).startsWith('12・A0:20'));
    damaged['x'] = .279;
    recorded['observations'] = observations;
    final result =
        const OcrCaptureExtractor().analyze(OcrInspection.fromMap(recorded));
    expect(
        result.capture!.messages
            .singleWhere((m) => m.body.startsWith('i got some issue regarding'))
            .body,
        contains('12・A0:20柊杰打印机小耿'));
  });

  test('right-hand prose without the intact matching header is not guessed',
      () {
    recorded['observations'] = (recorded['observations'] as List)
        .where((o) => !(o as Map)['text'].toString().contains('格志打印机小耿'))
        .toList();
    final result =
        const OcrCaptureExtractor().analyze(OcrInspection.fromMap(recorded));
    expect(
        result.capture!.messages
            .singleWhere((m) => m.body.startsWith('i got some issue regarding'))
            .body,
        contains('12・A0:20柊杰打印机小耿'));
  });
}
