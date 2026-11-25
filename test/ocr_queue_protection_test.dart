import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/transcript_text.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  test(
      'recorded seller chrome cannot change language or swallow real questions',
      () {
    expect(TranscriptText.clean('hi 格志打印料'), 'hi');
    expect(TranscriptText.clean('video? 格志打印'), 'video?');
    expect(TranscriptText.clean('I have a 格志打印机'), 'I have a 格志打印机');
    expect(CustomerLanguageResolver.fromText('I have a 格志打印机'),
        CustomerLanguage.english);
    for (final text in ['格志打印', '格志打印机格志打印机', '“ま打印机小啾']) {
      expect(TranscriptText.clean(text), isEmpty);
      expect(CustomerLanguageResolver.fromText(text), isNull);
    }
    for (final text in ['格志打印机好用吗', '格志打印机支持蓝牙吗？', '打印机', 'hi']) {
      expect(TranscriptText.clean(text), text);
    }
    expect(
        CustomerLanguageResolver.resolve([
          {'direction': 'incoming', 'body': 'find the problem here'},
          {'direction': 'incoming', 'body': '格志打印机格志打印机'},
        ]).language,
        CustomerLanguage.english);
  });

  for (final seller in ['格志打印', 'an unverified seller fragment']) {
    test('production mixed capture keeps original media queued despite $seller',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_queue_chrome_');
      final db = CaptureDatabase(storageRoot: root);
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final at = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch - 4000,
          isUtc: true);
      await db.saveCapture(CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at.add(const Duration(seconds: 2)),
          messages: [
            CapturedMessage(
                stableId: 'photo',
                direction: 'incoming',
                body: '[Customer sent an image; original copied from JD cache]',
                sentAt: at,
                axPath: 'cache',
                media: const [
                  CapturedMedia(
                      type: 'image',
                      path: '/original.jpg',
                      captureSource: 'jd_image_cache')
                ]),
            CapturedMessage(
                stableId: 'bad-seller',
                direction: 'outgoing',
                body: seller,
                sender: '格志打印机小',
                axPath: 'ocr'),
          ]));
      expect(await db.pendingMessageId('buyer'), 'photo');
      expect(await db.hasPendingUnanswered('buyer'), isTrue);
      expect(await db.answeredMessageId('buyer'), isNull);
      final sla = (await db.pendingSlaFallbackJobs()).single;
      expect(sla.messageId, 'photo');
      expect(sla.dueAt.isAtSameMomentAs(at.add(const Duration(seconds: 20))),
          isTrue);
    });
  }

  test('an OCR sighting cannot resume a quarantined identity mismatch',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_id_quarantine_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.suspendUnavailableConversation(
        'JQ_alias', 'conversation_verification_failed');
    expect(await db.resumeVisibleConversations(['JQ_alias']), isEmpty);
    expect(await db.isConversationUnavailable('JQ_alias'), isTrue);
    expect(
        await db.resumeVisibleConversations(['JQ_alias'],
            verifiedActive: ['JQ_alias']),
        ['JQ_alias']);
    expect(await db.isConversationUnavailable('JQ_alias'), isFalse);
  });
}
