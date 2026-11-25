import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late String imagePath;
  late DateTime clock;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jd_v37_type_');
    db = CaptureDatabase(storageRoot: temp);
    inventory = CustomerMediaInventory(db);
    imagePath = '${temp.path}/shared.jpeg';
    await File(imagePath).writeAsBytes([1, 2, 3]);
    clock = DateTime.now().toUtc().subtract(const Duration(seconds: 10));
    await db.beginAutomationSession(
        startedAt: clock.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<String> image(String message, {DateTime? at}) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: message,
        observedAt: DateTime.now(),
        senderAt: at ?? clock,
        slot: 0,
        region: [.2, .4, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: message,
        receivedAt: DateTime.now().toUtc(),
        senderAt: at ?? clock);
    await inventory.classify(receipt, 'image');
    final c = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: DateTime.now(),
        automationSessionId: db.currentAutomationSessionId,
        messages: [
          CapturedMessage(
              stableId: message,
              direction: 'incoming',
              body: 'customer image',
              axPath: 'fixture',
              sentAt: at ?? clock,
              mediaReceiptId: receipt,
              media: [
                CapturedMedia(
                    type: 'image',
                    path: imagePath,
                    captureSource: 'jd_image_cache')
              ])
        ]);
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true, currentTaskOnly: true);
    return receipt;
  }

  Future<Map<String, Object?>> row(String receipt) async =>
      (await (await db.database).query('customer_media_items',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
  Future<bool> hint(String receipt, String message) =>
      inventory.markMediaTypeVerificationPending('buyer',
          messageId: message, receiptId: receipt, imagePath: imagePath);
  test('AI video hint waits for native type without changing business identity',
      () async {
    final receipt = await image('real-photo');
    final first = await row(receipt);
    expect(await hint(receipt, 'real-photo'), isTrue);
    expect((await row(receipt))['kind'], 'image');
    expect((await row(receipt))['state'], 'awaiting_kind');
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await inventory.reconcileProvenMediaAliases(customer: 'buyer');
    expect((await row(receipt))['state'], 'awaiting_kind');
    expect(
        await inventory.resolveMediaTypeVerification('buyer',
            receiptId: receipt,
            nativeKind: 'image',
            captureSource: 'crop',
            playbackOverlayDetected: false,
            hasImageBytes: true),
        isFalse);
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    expect(
        await inventory.resolveMediaTypeVerification('buyer',
            receiptId: receipt,
            nativeKind: 'image',
            captureSource: 'jd-image-cache',
            playbackOverlayDetected: false,
            hasImageBytes: true),
        isTrue);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains('real-photo'));
    expect(await hint(receipt, 'real-photo'), isFalse,
        reason: 'an image of a video player must not loop on the same AI hint');
    final last = await row(receipt);
    expect(last['item_id'], first['item_id']);
    expect(last['message_id'], first['message_id']);
    expect(last['first_seen_ms'], first['first_seen_ms']);
    expect(
        await (await db.database).query('customer_media_items'), hasLength(1));
  });
  test('same file genuinely resent belongs to a separate native type check',
      () async {
    final first = await image('first');
    final second =
        await image('second', at: clock.add(const Duration(seconds: 1)));
    expect(
        await inventory.markMediaTypeVerificationPending('buyer',
            messageId: 'first', receiptId: second, imagePath: imagePath),
        isFalse);
    expect(await hint(first, 'first'), isTrue);
    expect((await row(second))['state'], 'ready');
    expect(
        await inventory.analysisReadyMessageIds('buyer'), contains('second'));
    expect(await inventory.analysisReadyMessageIds('buyer'),
        isNot(contains('first')));
    expect(
        await inventory.resolveMediaTypeVerification('buyer',
            receiptId: first,
            nativeKind: 'image',
            captureSource: 'jd-image-cache',
            playbackOverlayDetected: false,
            hasImageBytes: true),
        isTrue);
    expect(await hint(second, 'second'), isTrue,
        reason: 'proof for one real send is not proof for its later resend');
  });
  test(
      'native video proof upgrades the same receipt and still waits for whole parsing',
      () async {
    final receipt = await image('original-business');
    final original = await row(receipt);
    expect(await hint(receipt, 'original-business'), isTrue);
    expect(
        await inventory.resolveMediaTypeVerification('buyer',
            receiptId: receipt,
            nativeKind: 'video',
            captureSource: 'frozen-frame-video-cache',
            playbackOverlayDetected: true,
            hasVideoObject: true),
        isTrue);
    final next = await row(receipt);
    expect(next['kind'], 'video');
    expect(next['state'], 'preview');
    expect(next['message_id'], original['message_id']);
    final payload =
        (jsonDecode(next['media_json']! as String) as List).cast<Map>();
    expect(payload.single['type_verification'], 'video_confirmed');
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    expect(
        await (await db.database).query('customer_media_items'), hasLength(1));
  });
  test('native image verdict clears pending markers in every proven alias',
      () async {
    final receipt = await image('canonical');
    expect(await hint(receipt, 'canonical'), isTrue);
    final original = await row(receipt);
    final sql = await db.database;
    await sql.insert('customer_media_items', {
      ...original,
      'item_id': 'known-alias',
      'canonical_id': receipt,
      'admission_key': null,
      'admission_session_id': null,
      'admitted_at_ms': null,
      'state': 'superseded',
      'message_id': 'known-source'
    });
    expect(
        await inventory.resolveMediaTypeVerification('buyer',
            receiptId: 'known-alias',
            nativeKind: 'image',
            captureSource: 'jd-image-cache',
            playbackOverlayDetected: false,
            hasImageBytes: true),
        isTrue);
    for (final r in await sql.query('customer_media_items')) {
      expect(
          (jsonDecode(r['media_json']! as String) as List)
              .cast<Map>()
              .any((m) => m['type_verification'] == 'pending'),
          isFalse);
    }
    expect(await inventory.analysisReadyMessageIds('buyer'),
        containsAll(['canonical', 'known-source']));
    expect(await hint(receipt, 'canonical'), isFalse);
  });
}
