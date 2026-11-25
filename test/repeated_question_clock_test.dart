import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  for (final gap in [const Duration(seconds: 1), const Duration(days: 46)]) {
    test(
        'repeated question with punctuation change and distinct clock survives $gap',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_repeat_clock_');
      final db = CaptureDatabase(storageRoot: root);
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final old = DateTime.utc(2026, 9, 16, 5, 51, 32);
      final later = old.add(gap);
      CapturedConversation frame(String id, String body, DateTime sent) =>
          CapturedConversation(
              stableKey: 'customer:buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              capturedAt: sent.add(const Duration(seconds: 3)),
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    axPath: 'ocr:test',
                    body: body,
                    sentAt: sent)
              ]);
      await db.saveCapture(frame('old', 'what is in the image', old));
      await db.saveCapture(frame('new', 'what is in the image?', later));
      final history = await (await db.history).read('buyer');
      final messages = (history!['messages'] as List).cast<Map>();
      expect(messages.where((m) => m['direction'] == 'incoming'), hasLength(2));
      expect(await db.pendingMessageId('buyer'), 'new');
    });
  }
  test('same bubble punctuation reread remains deduplicated', () async {
    final root = await Directory.systemTemp.createTemp('jd_repeat_same_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final at = DateTime.utc(2026, 11, 1);
    for (final (id, body) in [
      ('a', 'what is in the image'),
      ('b', 'what is in the image?')
    ]) {
      await db.saveCapture(CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                axPath: 'ocr:test',
                body: body,
                sentAt: at)
          ]));
    }
    expect(((await (await db.history).read('buyer'))!['messages'] as List),
        hasLength(1));
  });
  for (final reply in [
    '请稍等，我正在核对您刚发来的消息。',
    'Please wait a moment while I check your latest message.',
    'Sorry, I could not clearly read the content you just sent. Could you describe the problem again or resend the photo or video? I will continue checking it for you.'
  ]) {
    test('OCR recovery wording cannot cancel a new question: $reply', () async {
      final root =
          await Directory.systemTemp.createTemp('jd_recovery_not_final_');
      final db = CaptureDatabase(storageRoot: root);
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final at = DateTime.now().toUtc();
      await db.saveCapture(CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: 'question',
                direction: 'incoming',
                body: 'what is in the image?',
                sentAt: at.subtract(const Duration(seconds: 3)),
                axPath: 'ocr:test'),
            CapturedMessage(
                stableId: 'ocr-holding',
                direction: 'outgoing',
                body: reply,
                sentAt: at,
                axPath: 'ocr:test')
          ]));
      expect(await db.pendingMessageId('buyer'), 'question');
      expect(await db.hasPendingUnanswered('buyer'), isTrue);
      expect(await db.answeredMessageId('buyer'), isNull);
    });
  }
}
