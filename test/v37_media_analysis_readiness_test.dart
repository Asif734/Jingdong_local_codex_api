import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jd_v37_analysis_ready_');
    db = CaptureDatabase(storageRoot: temp);
    inventory = CustomerMediaInventory(db);
    for (final relative in [
      'visible-cover.png',
      'frames_old/frame_01.jpg',
      'frames_exact_t0_v2/frame_00.jpg',
      'frames_exact_full_v3/frame_tail.jpg',
      'original',
    ]) {
      final file = File('${temp.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
    }
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test('audio failure and background progress are not successful analysis', () {
    for (final text in [
      'optional background analysis',
      'analysis unavailable',
      'permission denied',
      'timeout',
      ''
    ]) {
      expect(
          CustomerMediaInventory.hasTerminalVideoAudio([
            {'type': 'video', 'description': text}
          ]),
          isFalse);
    }
    for (final text in [
      '[Video speech transcript (en-US): paper jam]',
      '[Video audio: no audio stream]',
      '[Video audio: an audio stream exists, but no meaningful audible content was detected]',
      '[Video audio: audible content exists, but no speech was recognized]'
    ]) {
      expect(
          CustomerMediaInventory.hasTerminalVideoAudio([
            {'type': 'video', 'description': text}
          ]),
          isTrue);
    }
  });
  test(
      'one received video waits for original, t0, tail, cover and actual audio conclusion',
      () async {
    final clock = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'card',
        observedAt: DateTime.now(),
        senderAt: clock,
        slot: 0,
        region: [.2, .4, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: 'media-pending:$receipt',
        receivedAt: DateTime.now().toUtc(),
        senderAt: clock);
    await inventory.classify(receipt, 'video');
    final capture = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: DateTime.now(),
        automationSessionId: db.currentAutomationSessionId,
        messages: [
          CapturedMessage(
              stableId: 'media-pending:$receipt',
              direction: 'incoming',
              body: 'Media acquisition pending.',
              axPath: 'fixture',
              sentAt: clock,
              mediaReceiptId: receipt)
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture);
    final sql = await db.database;
    Future<void> media(List<Map<String, Object?>> payload) =>
        sql.update('customer_media_items', {'media_json': jsonEncode(payload)},
            where: 'item_id=?', whereArgs: [receipt]);
    final original = <String, Object?>{
      'type': 'video',
      'path': '/owned.mp4',
      'description': 'optional background analysis'
    };
    final cover = <String, Object?>{
      'type': 'image',
      'path': '${temp.path}/visible-cover.png',
      'capture_source': 'jd_video_cover',
      'is_partial': true
    };
    final oldSample = <String, Object?>{
      'type': 'image',
      'path': '${temp.path}/frames_old/frame_01.jpg',
      'capture_source': 'jd_video_frame_1fps'
    };
    final first = <String, Object?>{
      'type': 'image',
      'path': '${temp.path}/frames_exact_t0_v2/frame_00.jpg',
      'capture_source': 'jd_video_frame_1fps',
      'original_name': 'video_frame_00s.jpg'
    };
    final tail = <String, Object?>{
      'type': 'image',
      'path': '${temp.path}/frames_exact_full_v3/frame_tail.jpg',
      'capture_source': 'jd_video_frame_1fps',
      'original_name': 'video_frame_tail.jpg'
    };
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await media([cover]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await media([original, cover, oldSample]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await media([original, cover, first]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    final terminal = {
      ...original,
      'description': '[Video audio: no audio stream]'
    };
    await media([terminal, first]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await media([terminal, cover, first]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await media([terminal, cover, first, tail]);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains('media-pending:$receipt'));
    final rows = await sql.query('customer_media_items');
    expect(rows, hasLength(1));
    expect(rows.single['message_id'],
        CustomerMessageTime.incomingId('buyer', clock));
  });
  test(
      'a genuine image is ready only after its original replaces a partial crop',
      () async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'photo',
        observedAt: DateTime.now(),
        senderAt: DateTime.now().toUtc(),
        slot: 0,
        region: [.2, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'image');
    final sql = await db.database;
    await sql.update(
        'customer_media_items',
        {
          'message_id': 'picture',
          'media_json': jsonEncode([
            {'type': 'image', 'path': 'crop', 'is_partial': true}
          ])
        },
        where: 'item_id=?',
        whereArgs: [receipt]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await sql.update(
        'customer_media_items',
        {
          'media_json': jsonEncode([
            {
              'type': 'image',
              'path': '${temp.path}/original',
              'capture_source': 'jd_image_cache'
            }
          ])
        },
        where: 'item_id=?',
        whereArgs: [receipt]);
    expect(
        await inventory.analysisReadyMessageIds('buyer'), contains('picture'));
  });
}
