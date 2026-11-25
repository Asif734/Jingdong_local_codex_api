import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  late Directory root;
  late ConversationFileStore store;
  final at = DateTime.utc(2026, 11, 5, 10);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v33_work_history_');
    store = ConversationFileStore(root);
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> save(CapturedMessage message,
      {String customer = 'buyer',
      String session = 'current',
      bool history = false}) async {
    await store.appendCapture(
        CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: session,
          capturedAt: at,
          messages: [message],
        ),
        historyOnly: history);
  }

  Future<List<Map>> messages([String customer = 'buyer']) async =>
      ((await store.read(customer))!['messages'] as List).cast<Map>();
  CapturedMessage card(String id, String receipt,
          {List<CapturedMedia> media = const []}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          body: media.isEmpty
              ? '[Customer sent media; acquisition pending.]'
              : '[Customer sent video]',
          sentAt: at.subtract(const Duration(hours: 1)),
          axPath: 'verified-card',
          mediaReceiptId: receipt,
          media: media);

  test('live reread stamps a previously saved canonical input for queue repair',
      () async {
    final question = CapturedMessage(
        stableId: 'q',
        direction: 'incoming',
        body: 'Cannot connect to the computer.',
        axPath: 'fixture');
    await save(question, history: true);
    expect((await messages()).single['live_observed_session_ids'], isNull);
    await save(question);
    await save(question);
    final saved = (await messages()).single;
    expect(saved['id'], 'q');
    expect(saved['live_observed_session_ids'], ['current']);
    expect(saved['observed_session_id'], 'current');
  });

  test(
      'placeholder preview and original stay one message; each real upgrade revises once',
      () async {
    await save(card('media-pending:r', 'r'));
    final preview = card('preview', 'r', media: [
      CapturedMedia(
          type: 'image',
          path: '/fixture/preview.png',
          isPartial: true,
          captureSource: 'jd_video_preview')
    ]);
    await save(preview);
    await save(preview);
    var record = (await messages()).single;
    expect(record['id'], 'media-pending:r');
    expect(record['service_evidence_revision'], 1);
    final original = card('original', 'r', media: [
      CapturedMedia(
          type: 'video',
          path: '/fixture/original.mp4',
          captureSource: 'jd_video_cache')
    ]);
    await save(original);
    await save(original);
    record = (await messages()).single;
    expect(record['id'], 'media-pending:r');
    expect(record['service_evidence_revision'], 2);
    expect(record['text_origin'], 'media');
    expect(record['observed_ids'], containsAll(['preview', 'original']));
    final active = (record['media'] as List).cast<Map>();
    expect(active.map((m) => m['path']).toSet(),
        {'/fixture/original.mp4', '/fixture/preview.png'});
    expect(
        active.singleWhere((m) => m['path'] == '/fixture/original.mp4')['type'],
        'video');
    expect(
        active.singleWhere(
            (m) => m['path'] == '/fixture/preview.png')['capture_source'],
        'jd_video_preview');
    expect(
        active.singleWhere(
            (m) => m['path'] == '/fixture/preview.png')['is_partial'],
        isTrue);
  });

  test('an ordinary photo keeps only its complete original active', () async {
    await save(card('media-pending:photo', 'photo'));
    await save(card('photo-crop', 'photo', media: [
      const CapturedMedia(
          type: 'image',
          path: '/fixture/photo-crop.png',
          captureSource: 'verified_window_crop',
          isPartial: true)
    ]));
    final original = card('photo-original', 'photo', media: [
      const CapturedMedia(
          type: 'image',
          path: '/fixture/photo-original.jpeg',
          captureSource: 'jd_image_cache')
    ]);
    await save(original);
    await save(original);
    final record = (await messages()).single;
    expect(record['id'], 'media-pending:photo');
    expect(record['service_evidence_revision'], 2);
    final active = (record['media'] as List).cast<Map>();
    expect(active, hasLength(1));
    expect(active.single['path'], '/fixture/photo-original.jpeg');
    expect(active.single['capture_source'], 'jd_image_cache');
    expect(active.single['is_partial'], isFalse);
    final alternates = (record['media_alternates'] as List).cast<Map>();
    expect(alternates, hasLength(1));
    expect(alternates.single['path'], '/fixture/photo-crop.png');
  });

  test('different receipts and customers never merge placeholder ownership',
      () async {
    await save(card('media-pending:r1', 'r1'));
    await save(card('media-pending:r2', 'r2'));
    await save(card('media-pending:r1', 'r1'), customer: 'other');
    expect(await messages(), hasLength(2));
    expect(await messages('other'), hasLength(1));
  });
}
