import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late ConversationFileStore store;
  final at = DateTime.utc(2026, 11, 1, 3);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_media_persist_');
    store = ConversationFileStore(root);
  });
  tearDown(() => root.delete(recursive: true));
  CapturedMessage media(String id, String type, {DateTime? sentAt}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          body: '[Customer sent media; visible portion captured]',
          sentAt: sentAt ?? at,
          axPath: 'ocr:visible-image-region',
          media: [
            CapturedMedia(
                type: type,
                path: '/test/$id',
                visualFingerprint: 'ffffffffffffffff')
          ]);
  Future<void> append(List<CapturedMessage> messages) async {
    await store.appendCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: at,
        messages: messages));
  }

  test(
      'two different images with the same sender clock and placeholder must both survive',
      () async {
    await append([media('image-a', 'image'), media('image-b', 'image')]);
    final messages = (await store.read('a'))!['messages'] as List;
    expect(messages.map((m) => (m as Map)['id']), ['image-a', 'image-b']);
  });
  test('different videos with identical preview fingerprints must not merge',
      () async {
    await append([media('video-a', 'video')]);
    await append([media('video-b', 'video')]);
    expect(((await store.read('a'))!['messages'] as List).length, 2);
  });
  test('same stable media ID is deduplicated while a later resend is retained',
      () async {
    await append([media('same-file:clock-1', 'image')]);
    await append([media('same-file:clock-1', 'image')]);
    await append([
      media('same-file:clock-2', 'image',
          sentAt: at.add(const Duration(seconds: 1)))
    ]);
    final messages = (await store.read('a'))!['messages'] as List;
    expect(messages.length, 2);
  });
  test(
      'database queue points to the last media while retaining the entire burst',
      () async {
    final db = CaptureDatabase(storageRoot: root);
    try {
      final inserted = await db.saveCapture(CapturedConversation(
          stableKey: 'a',
          customerName: 'a',
          customerExternalId: 'a',
          capturedAt: at,
          messages: [
            media('image-a', 'image'),
            media('image-b', 'image'),
            media('video-c', 'video')
          ]));
      expect(inserted, 3);
      expect(await db.pendingMessageId('a'), 'video-c');
      expect(await db.hasPendingUnanswered('a'), isTrue);
      final document = await (await db.history).read('a');
      expect((document!['messages'] as List).length, 3);
    } finally {
      await db.close();
    }
  });
}
