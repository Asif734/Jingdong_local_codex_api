import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/capture/transcript_text.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  test(
      'watermark spelling errors are not customer language and internal media notes are not transfer subjects',
      () {
    for (final text in ['格患打印机小瞅', '格志打印机门', '#打印机小联', '格志打印机小！', '格志打印机小!']) {
      expect(TranscriptText.clean(text), isEmpty);
      expect(CustomerLanguageResolver.fromText(text), isNull);
    }
    for (final text in [
      '[Customer sent a video; copied from JD cache]',
      'Please check [Video audio: pending]'
    ]) {
      expect(TranscriptText.customerQuestionSummary(text), isEmpty);
    }
    expect(TranscriptText.customerQuestionSummary('The printer is jammed'),
        'The printer is jammed');
    expect(TranscriptText.customerQuestionSummary('我的打印机卡纸了'), '我的打印机卡纸了');
  });

  for (final n in [1, 2]) {
    test('recorded video $n survives unmodified watermark OCR', () {
      final json = jsonDecode(
          File('test/fixtures/video_watermarks/video_$n.json')
              .readAsStringSync()) as Map<String, dynamic>;
      final inspection = OcrInspection.fromMap(json);
      final regions = const OcrImageCandidateSelector().select(
          inspection, 'buyer_video',
          allowUnlabeledLatestImage: true, includeTextDense: true);
      expect(regions, hasLength(1));
      expect(regions.single.x, greaterThanOrEqualTo(inspection.chatLeft!));
      expect(regions.single.x + regions.single.width,
          lessThanOrEqualTo(inspection.chatRight!));
    });
  }
  for (final english in [true, false]) {
    test(
        'media language never overrides ${english ? 'English' : 'Chinese'} customer text',
        () {
      final real = {
        'id': 'text',
        'direction': 'incoming',
        'source': 'jd_automation',
        'text_origin': 'customer_text',
        'body': english ? 'Can you check my video?' : '请看一下我发的视频',
        'sent_at': '2026-11-03T02:40:00Z'
      };
      final opposite =
          english ? '这是一段中文媒体文字' : 'This is English text inside the video';
      final mediaSources = [
        'image_ocr',
        'video_subtitle',
        'video_transcript',
        'audio_transcript',
        'media_analysis'
      ];
      final rows = [
        real,
        for (final source in mediaSources)
          {
            'id': source,
            'direction': 'incoming',
            'source': source,
            'body': opposite,
            'sent_at': '2026-11-03T02:41:00Z'
          },
        {
          'id': 'photo',
          'direction': 'incoming',
          'body': opposite,
          'media': [
            {'type': 'image', 'description': opposite}
          ],
          'sent_at': '2026-11-03T02:41:01Z'
        },
        {
          'id': 'video',
          'direction': 'incoming',
          'text_origin': 'media',
          'body': opposite,
          'sent_at': '2026-11-03T02:41:02Z'
        },
      ];
      final persisted =
          (jsonDecode(jsonEncode(rows)) as List).cast<Map<String, dynamic>>();
      final result = CustomerLanguageResolver.resolve(persisted);
      expect(result.language,
          english ? CustomerLanguage.english : CustomerLanguage.chinese);
      expect(result.sourceMessageId, 'text');
      expect(CustomerLanguageResolver.resolve(persisted.skip(1)).language,
          CustomerLanguage.unknown);
      persisted.add({
        'id': 'switch',
        'direction': 'incoming',
        'text_origin': 'customer_text',
        'body': opposite,
        'sent_at': '2026-11-03T02:42:00Z'
      });
      expect(CustomerLanguageResolver.resolve(persisted).language,
          english ? CustomerLanguage.chinese : CustomerLanguage.english);
    });
  }
}
