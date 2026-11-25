import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/transcript_text.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  Future<OcrInspection> frame(String name) async => OcrInspection.fromMap(
      jsonDecode(await File('test/fixtures/v27/$name.json').readAsString()));
  test('actual emoji-code customer prose survives metadata filtering',
      () async {
    final result =
        const OcrCaptureExtractor().analyze(await frame('emoji_body'));
    final message = result.capture!.messages
        .where((m) => m.direction == 'incoming' && m.body.contains('半天'))
        .single;
    expect(message.body, contains('不是这种'));
    expect(message.sentAt!.toUtc(), DateTime.utc(2026, 11, 4, 3, 15, 2));
    expect(result.latestIncomingHasText, isTrue);
  });
  for (final body in [
    '7:30',
    '我的班次7:30到15:00，可以吗？',
    '打不出来…怎么办？',
    '为什么显示已读但没有回复？'
  ]) {
    test('real body containing time or chrome words survives: $body', () async {
      final inspection = await frame('emoji_body');
      final observations = inspection.observations
          .map((o) => o.x > .24 && o.text.contains('半天')
              ? OcrObservation(
                  text: body,
                  confidence: o.confidence,
                  x: o.x,
                  y: o.y,
                  width: o.width,
                  height: o.height)
              : o)
          .toList();
      final result = const OcrCaptureExtractor()
          .analyze(inspection.withObservations(observations));
      expect(
          result.capture!.messages
              .any((m) => m.direction == 'incoming' && m.body == body),
          isTrue);
    });
  }
  test('actual assistance text bubble is not registered as a video or image',
      () async {
    final inspection = await frame('text_not_video');
    final result = const OcrCaptureExtractor().analyze(inspection);
    final texts = result.capture!.messages
        .where((m) => m.direction == 'incoming')
        .map((m) => m.body);
    expect(texts, contains('give me that assistance then'));
    final regions = const OcrImageCandidateSelector().select(
        inspection, 'buyer',
        includeTextDense: true, customerText: texts);
    expect(regions.where((r) => r.y > .45 && r.y < .55), isEmpty);
  });
  test('actual customer image remains eligible despite text exclusion',
      () async {
    final inspection = await frame('image_caption');
    final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
    expect(
        const OcrImageCandidateSelector().select(inspection, 'buyer',
            includeTextDense: true,
            customerText: capture.messages
                .where((m) => m.direction == 'incoming')
                .map((m) => m.body)),
        isNotEmpty);
  });
  test(
      'control suffix reread preserves one message; a later real repeat stays separate',
      () async {
    final root = await Directory.systemTemp.createTemp('v27_chrome_');
    addTearDown(() => root.delete(recursive: true));
    final store = ConversationFileStore(root);
    final at = DateTime.now().toUtc();
    Future<void> save(String id, String text, DateTime time) async {
      await store.appendCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: text,
                sentAt: time,
                axPath: 'fixture')
          ]));
    }

    await save('original', 'oh..', at);
    await save('reread', 'oh.. 更多', at);
    expect((await store.read('buyer'))!['messages'] as List, hasLength(1));
    await save('repeat', 'oh..', at.add(const Duration(seconds: 5)));
    expect((await store.read('buyer'))!['messages'] as List, hasLength(2));
    expect(TranscriptText.clean('暂停|微え'), isEmpty);
    expect(TranscriptText.clean('查看更多选项在哪里'), '查看更多选项在哪里');
  });
  test(
      'unique deferred clock refines in place without orphaning a reply cursor',
      () async {
    final root = await Directory.systemTemp.createTemp('v27_clock_');
    addTearDown(() => root.delete(recursive: true));
    final store = ConversationFileStore(root);
    final at = DateTime.now().toUtc();
    Future<void> save(String id, DateTime? clock, String? turn) async {
      await store.appendCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: '下一步怎么操作',
                sentAt: clock,
                axPath: 'fixture',
                observationTurnKey: turn)
          ]));
    }

    await save('old', null, 'ocr-bubble:fixture:clock-unresolved-after-media');
    await save('new', at.subtract(const Duration(seconds: 1)), null);
    var messages = (await store.read('buyer'))!['messages'] as List;
    expect(messages, hasLength(1));
    expect(messages.single['id'], 'old');
    expect(messages.single['sent_at'], isNotNull);
    await save('real-repeat', at.add(const Duration(seconds: 5)), null);
    messages = (await store.read('buyer'))!['messages'] as List;
    expect(messages, hasLength(2));
  });
}
