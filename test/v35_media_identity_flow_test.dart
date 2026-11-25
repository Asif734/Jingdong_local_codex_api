import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_visual_matcher.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixtures = 'test/fixtures/v35_message_flow';
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore evidence;
  late CustomerMediaInventory inventory;
  late DateTime now;
  late Map<String, dynamic> provenance;
  setUp(() async {
    provenance =
        jsonDecode(await File('$fixtures/provenance.json').readAsString());
    root = await Directory.systemTemp.createTemp('jd_v35_media_identity_');
    db = CaptureDatabase(storageRoot: root);
    now = DateTime.now().toUtc();
    final session = await db.beginAutomationSession(
        startedAt: now.subtract(const Duration(seconds: 1)));
    evidence = CaptureEvidenceStore(db);
    await evidence.beginSession(
        sessionId: session,
        startedAt: now.subtract(const Duration(seconds: 1)));
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  List<double> box(String name) => (provenance[name]['region'] as List)
      .cast<num>()
      .map((n) => n.toDouble())
      .toList();
  Future<Uint8List> bytes(String name, {bool card = false}) =>
      File('$fixtures/$name${card ? '-card' : ''}.png').readAsBytes();
  Future<void> frame(int index, String name) async {
    final path = File('${root.path}/frame-$index.png');
    await path.writeAsBytes(await bytes(name));
    final payload = ViewportEvidence({
      'evidenceId': 'frame-$index',
      'customer': 'buyer',
      'imagePath': path.path,
      'manifestPath': '${path.path}.json',
      'capturedAtMs': now.add(Duration(seconds: index)).millisecondsSinceEpoch,
      'automationSessionId': db.currentAutomationSessionId,
      'capturePurpose': 'live_signal',
      'replyActivationAllowed': true,
      'chatRegion': provenance[name]['chatRegion'],
    });
    await File('${path.path}.json').writeAsString(payload.toJson());
    await evidence.record(payload);
  }

  CapturedConversation capture(String receipt,
          {bool original = false, DateTime? clock}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: 'media-pending:$receipt',
                direction: 'incoming',
                body: original ? 'original image' : 'media pending',
                axPath: 'test',
                sender: 'buyer',
                sentAt: clock,
                mediaReceiptId: receipt,
                media: original
                    ? [
                        CapturedMedia(
                            type: 'image',
                            path: '$fixtures/image-original.jpeg',
                            captureSource: 'jd_image_cache',
                            isPartial: false)
                      ]
                    : [])
          ]);
  Future<String> observe(int index, String name,
      {DateTime? clock,
      int slot = 0,
      String? fingerprint,
      Uint8List? preview}) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame-$index',
        observedAt: now.add(Duration(seconds: index)),
        senderAt: clock,
        slot: slot,
        region: box(name),
        current: true);
    return inventory.classify(receipt, 'image',
        fingerprint: fingerprint ?? provenance[name]['fingerprint'],
        previewBytes: preview ?? await bytes(name, card: true),
        evidenceId: 'frame-$index',
        region: box(name));
  }

  test('recorded white loading card and nested loaded image keep one receipt',
      () async {
    expect(
        await MediaVisualMatcher.isLoadingCover(
            await bytes('image-loading', card: true)),
        isTrue);
    await frame(0, 'image-loading');
    final first = await observe(0, 'image-loading', clock: now);
    await admitFixtureMedia(db,
        receiptId: first,
        messageId: 'media-pending:$first',
        receivedAt: now,
        senderAt: now);
    await db.saveCapture(capture(first, clock: now));
    await inventory.persist(capture(first, clock: now));
    await frame(1, 'image-inner');
    final next = await observe(1, 'image-inner', clock: now);
    expect(next, first);
    await db.saveCapture(capture(next, original: true, clock: now));
    await inventory.persist(capture(next, original: true, clock: now));
    expect(await db.processingMessages('buyer'), hasLength(1));
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('an ambiguous crop rebinds to its exact original, not a new question',
      () async {
    await frame(1, 'image-inner');
    final first = await observe(1, 'image-inner', clock: now);
    await admitFixtureMedia(db,
        receiptId: first,
        messageId: 'media-pending:$first',
        receivedAt: now,
        senderAt: now);
    await db.saveCapture(capture(first, original: true, clock: now));
    await inventory.persist(capture(first, original: true, clock: now));
    await (await db.database).update(
        'customer_media_items', {'identity_ambiguous': 1},
        where: 'item_id=?', whereArgs: [first]);
    await frame(2, 'image-scrolled');
    final next = await observe(2, 'image-scrolled',
        clock: now,
        preview: await File('$fixtures/image-original.jpeg').readAsBytes());
    expect(next, first);
    expect(await db.processingMessages('buyer'), hasLength(1));
    final stored = await (await db.database)
        .query('customer_media_items', where: 'item_id=?', whereArgs: [first]);
    expect(stored.single['identity_ambiguous'], 0);
  });

  test(
      'the same image genuinely resent at a new clock stays a separate message',
      () async {
    await frame(1, 'image-inner');
    final first = await observe(1, 'image-inner', clock: now);
    await admitFixtureMedia(db,
        receiptId: first,
        messageId: 'media-pending:$first',
        receivedAt: now,
        senderAt: now);
    await db.saveCapture(capture(first, original: true, clock: now));
    await inventory.persist(capture(first, original: true, clock: now));
    await frame(2, 'image-inner');
    final later = now.add(const Duration(seconds: 1));
    final next = await observe(2, 'image-inner', clock: later);
    expect(next, isNot(first));
    await admitFixtureMedia(db,
        receiptId: next,
        messageId: 'media-pending:$next',
        receivedAt: now.add(const Duration(seconds: 2)),
        senderAt: later);
    await db.saveCapture(capture(next, original: true, clock: later));
    await inventory.persist(capture(next, original: true, clock: later));
    expect(await db.processingMessages('buyer'), hasLength(2));
  });

  test('unclocked frozen observations never create business without a parent',
      () async {
    await frame(1, 'image-inner');
    final first = await observe(1, 'image-inner');
    await db.saveCapture(capture(first, original: true));
    await inventory.persist(capture(first, original: true));
    await frame(2, 'image-inner');
    final next =
        await observe(2, 'image-inner', fingerprint: '0000000000000000');
    expect(next, isNot(first),
        reason: 'Observation IDs need not be business IDs');
    expect(await db.processingMessages('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    final rows = await (await db.database).query('customer_media_items');
    expect(rows.every((row) => row['message_id'] == null), isTrue);
  });

  test(
      'an old frame after Start stays observation-only and cannot reactivate business',
      () async {
    await frame(1, 'image-inner');
    final first = await observe(1, 'image-inner', clock: now);
    await admitFixtureMedia(db,
        receiptId: first,
        messageId: 'media-pending:$first',
        receivedAt: now,
        senderAt: now);
    await db.saveCapture(capture(first, original: true, clock: now));
    await inventory.persist(capture(first, original: true, clock: now));
    final start = now.add(const Duration(milliseconds: 10));
    final session = await db.beginAutomationSession(startedAt: start);
    await evidence.beginSession(sessionId: session, startedAt: start);
    await frame(2, 'image-inner');
    final other = await File(
            'test/fixtures/v34_discovery/video-cover-after-reply-card.png')
        .readAsBytes();
    final fork = await observe(2, 'image-inner',
        clock: now, fingerprint: '0101010101010101', preview: other);
    expect(fork, isNot(first));
    expect(await db.isSessionBaselineMessage('buyer', 'media-pending:$first'),
        isTrue);
    expect(await db.isSessionBaselineMessage('buyer', 'media-pending:$fork'),
        isFalse,
        reason:
            'A new observation is not another business needing a baseline cursor');
    expect(
        await inventory.resolveParent('buyer',
            receiptId: fork, requireCurrentSession: true),
        isNull);
    await db.saveCapture(capture(fork, original: true, clock: now));
    expect(await db.processingMessages('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test('strict frozen-card identity also compares transcript outside the card',
      () async {
    expect(
        await MediaVisualMatcher.frozenCardContinuation(
            previousCard: await bytes('image-inner', card: true),
            currentCard: await bytes('image-inner', card: true),
            previousFrame: await bytes('image-inner'),
            currentFrame: await bytes('image-scrolled'),
            previousRegion: box('image-inner'),
            currentRegion: box('image-scrolled'),
            transcript: [
              for (final k in ['left', 'top', 'right', 'bottom'])
                (provenance['image-inner']['chatRegion'][k] as num).toDouble()
            ]),
        isFalse);
  });
}
