import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/processed_video_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime at;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v62_media_files_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    inventory = CustomerMediaInventory(db);
    at = DateTime.now().toUtc().subtract(const Duration(seconds: 10));
    session = await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<File> asset(String name) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  Future<({String receipt, String message})> admit(
      String kind, List<CapturedMedia> media) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'owned-card',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.25, .4, .15, .3],
        current: true);
    final admission = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'owned-card',
        occurrenceKey: 'arrival-1',
        receivedAt: at,
        senderAt: at);
    await inventory.classify(receipt, kind);
    final capture = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at,
        automationSessionId: session,
        messages: [
          CapturedMessage(
              stableId: admission.messageId,
              direction: 'incoming',
              sender: 'buyer',
              sentAt: at,
              body: '[Customer sent $kind]',
              axPath: 'owned canonical sender second',
              mediaReceiptId: receipt,
              media: media)
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    return (receipt: receipt, message: admission.messageId);
  }

  test('missing ready image requeues its original receipt and sender second',
      () async {
    final image = await asset('original.png');
    final owner = await admit('image', [
      CapturedMedia(
          type: 'image', path: image.path, captureSource: 'jd_image_cache')
    ]);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(owner.message));
    expect(await inventory.pendingMediaForTask('buyer'), isEmpty);
    await image.delete();
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    final pending = (await inventory.pendingMediaForTask('buyer')).single;
    expect(pending['receiptId'], owner.receipt);
    expect(pending['messageId'], owner.message);
    expect((pending['senderAt']! as DateTime).millisecondsSinceEpoch ~/ 1000,
        at.millisecondsSinceEpoch ~/ 1000);
    expect(await db.isMessageFormallyAnswered('buyer', owner.message), isFalse);
    await image.writeAsBytes([1, 2, 3]);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(owner.message));
    expect(await inventory.pendingMediaForTask('buyer'), isEmpty);
    expect(
        await (await db.database).query('customer_media_items'), hasLength(1));
  });

  test('zero-byte, directory and missing image paths are not analysis inputs',
      () async {
    final file = await asset('image.png');
    Future<bool> check(String path) =>
        CustomerMediaInventory.analysisFilesPresent('image', [
          {'type': 'image', 'path': path, 'capture_source': 'jd_image_cache'}
        ]);
    expect(await check(file.uri.toString()), isTrue);
    await file.writeAsBytes([]);
    expect(await check(file.path), isFalse);
    expect(await check(root.path), isFalse);
    expect(await check('${root.path}/missing.png'), isFalse);
    expect(await check('https://example.com/image.png'), isFalse);
    expect(
        await CustomerMediaInventory.analysisFilesPresent('image', [
          {'type': 'image', 'path': file.path, 'is_partial': true}
        ]),
        isFalse);
  });

  test('parsed video needs every frame and cover, not the decoded original',
      () async {
    final first = await asset('first.jpg');
    final tail = await asset('tail.jpg');
    final cover = await asset('cover.jpg');
    final owner = await admit('video', [
      CapturedMedia(
          type: 'video',
          path: '${root.path}/original-already-removed.mp4',
          captureSource: 'jd_video_cache',
          description: '[Video audio: no audio stream]'),
      CapturedMedia(
          type: 'image',
          path: first.path,
          captureSource: 'jd_video_frame_1fps',
          originalName: 'video_frame_00s.jpg'),
      CapturedMedia(
          type: 'image',
          path: tail.path,
          captureSource: 'jd_video_frame_1fps',
          originalName: 'video_frame_tail.jpg'),
      CapturedMedia(
          type: 'image', path: cover.path, captureSource: 'jd_video_cover'),
    ]);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(owner.message));
    await tail.writeAsBytes([]);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    final pending = (await inventory.pendingMediaForTask('buyer')).single;
    expect(pending['receiptId'], owner.receipt);
    expect(pending['kind'], 'video');
    expect(pending['messageId'], owner.message);
    await tail.writeAsBytes([4, 5]);
    await cover.delete();
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await cover.writeAsBytes([6]);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(owner.message));
    expect(await db.isMessageFormallyAnswered('buyer', owner.message), isFalse);
  });

  test('processed video cache recreates zero-byte artifacts instead of reusing',
      () async {
    final cache = Directory('${root.path}/processed');
    final frame = File('${root.path}/frame.jpg');
    final original = await asset('original.mp4');
    var creates = 0;
    Future<CapturedMessage> create() async {
      creates++;
      await frame.writeAsBytes([1, 2, 3]);
      return CapturedMessage(
          stableId: 'artifact',
          direction: 'incoming',
          body: '[Video artifact]',
          axPath: 'existing decoder output',
          media: [
            CapturedMedia(type: 'video', path: original.path),
            CapturedMedia(
                type: 'image',
                path: frame.path,
                captureSource: 'jd_video_frame_1fps')
          ]);
    }

    Future<CapturedMessage> load() =>
        ProcessedVideoStore(cache).getOrCreate('buyer', 'digest', create,
            cacheContract: 'same-decoder-contract');
    await load();
    await load();
    expect(creates, 1);
    await frame.writeAsBytes([]);
    await load();
    expect(creates, 2);
    expect(await frame.length(), greaterThan(0));
    await load();
    expect(creates, 2);
  });
}
