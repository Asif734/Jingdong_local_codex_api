import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

import 'helpers/completed_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime started;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v33_media_inventory_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    started = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now()
            .subtract(const Duration(seconds: 10))
            .millisecondsSinceEpoch,
        isUtc: true);
    await db.beginAutomationSession(startedAt: started);
    await inventory.beginRun(started);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> card({int slot = 0, String? kind = 'video'}) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame-$slot',
        observedAt: started.add(Duration(seconds: slot + 1)),
        senderAt: started.subtract(const Duration(hours: 2)),
        slot: slot,
        region: [.3, .4, .2, .2],
        current: true);
    if (kind != null) await inventory.classify(receipt, kind);
    return receipt;
  }

  CapturedConversation capture(String id, String receipt,
          {List<CapturedMedia> media = const [], int second = 1}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: started.add(Duration(seconds: second)),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: '[media awaiting acquisition]',
                sentAt: started.subtract(const Duration(hours: 2)),
                axPath: 'owned-card',
                mediaReceiptId: receipt,
                media: media)
          ]);

  Future<CapturedConversation> placeholder(String receipt,
      {int second = 1, bool currentTaskOnly = false}) async {
    final c = capture('media-pending:$receipt', receipt, second: second);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: 'media-pending:$receipt',
        receivedAt: c.capturedAt,
        senderAt: c.messages.first.sentAt);
    await db.saveCapture(c);
    await inventory.persist(c, currentTaskOnly: currentTaskOnly);
    return c;
  }

  Future<CapturedConversation> original(String receipt,
      {String id = 'verified-original', int second = 3}) async {
    final file = await File('${root.path}/$id.mp4').writeAsBytes([1]);
    final frame = await File('${root.path}/$id.jpg').writeAsBytes([2]);
    return capture(id, receipt, second: second, media: [
      CapturedMedia(
          type: 'video', path: file.path, captureSource: 'jd_video_cache'),
      CapturedMedia(
          type: 'image', path: frame.path, captureSource: 'jd_video_frame_1fps')
    ]);
  }

  Future<List<Map<String, dynamic>>> history() async =>
      ((await (await db.history).read('buyer'))?['messages'] as List? ?? [])
          .cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> context(List<Map<String, dynamic>> frozen,
          {bool allowHistorical = false}) =>
      inventory.context('buyer',
          history: frozen,
          before: started.add(const Duration(seconds: 5)),
          observedBefore: started.add(const Duration(seconds: 5)),
          allowHistorical: allowHistorical);

  test('answered receipt keeps acquisition duty without an age deadline',
      () async {
    final receipt = await card();
    await placeholder(receipt);
    await (await db.database).update(
        'automation_session_messages', {'response_state': 'answered'},
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, 'buyer']);
    expect(await db.processingMessages('buyer'), isEmpty);
    final pending = await inventory.pendingMediaForTask('buyer');
    expect(pending, hasLength(1));
    expect(pending.single['receiptId'], receipt);
    expect(pending.single['kind'], 'video');
    expect(pending.single['messageId'], 'media-pending:$receipt');
    expect(pending.single['aliases'], contains('media-pending:$receipt'));
    expect(
        pending.single['firstSeenAt'], started.add(const Duration(seconds: 1)));
    expect(await inventory.acquisitionFloor('buyer'),
        started.subtract(const Duration(hours: 2)));
    expect(
        await inventory.previewWait('buyer', 'media-pending:$receipt',
            started.add(const Duration(days: 3))),
        Duration.zero);
    await (await db.database).update(
        'customer_media_items', {'state': 'failed'},
        where: 'item_id=?', whereArgs: [receipt]);
    expect(await inventory.pendingMediaForTask('buyer'), hasLength(1));
    await (await db.database).update(
        'automation_session_messages', {'response_state': 'delegated'},
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, 'buyer']);
    expect(await inventory.pendingMediaForTask('buyer'), isEmpty);
  });

  test('unknown card is a pending received item without invented files',
      () async {
    final receipt = await card(kind: null);
    await placeholder(receipt);
    final pending = await inventory.pendingMediaForTask('buyer');
    expect(pending, hasLength(1));
    expect(pending.single['kind'], 'unknown');
    final items = await context(await history());
    expect(items, hasLength(1));
    expect(items.single['kind'], 'unknown');
    expect(items.single['availableMedia'], isEmpty);
    expect(items.single['analysisAvailable'], isFalse);
    expect(items.single['originalVerified'], isFalse);
    expect(items.single['evidenceId'], 'frame-0');
    expect(
        CustomerMediaInventory.receiptReply('你收到视频了吗', items, english: false),
        contains('类型和内容仍在读取确认中'));
    final stored =
        (await (await db.database).query('customer_media_items')).single;
    expect(jsonDecode(stored['media_json']! as String), isEmpty);
  });

  test('empty placeholders cannot create receipts or bind another customer',
      () async {
    await inventory.persist(capture('media-pending:missing', 'missing'));
    expect(await (await db.database).query('customer_media_items'), isEmpty);
    final receipt = await inventory.observe(
        customer: 'another-buyer',
        evidenceId: 'foreign-frame',
        observedAt: started,
        senderAt: started,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    await inventory.persist(capture('media-pending:$receipt', receipt));
    final stored =
        (await (await db.database).query('customer_media_items')).single;
    expect(stored['customer'], 'another-buyer');
    expect(stored['message_id'], isNull);
    expect(jsonDecode(stored['aliases_json']! as String), isEmpty);
  });

  test('verified original upgrades the same durable placeholder identity',
      () async {
    final receipt = await card();
    await placeholder(receipt);
    final previewFile =
        await File('${root.path}/preview.png').writeAsBytes([3]);
    final preview = capture('preview-observation', receipt, second: 2, media: [
      CapturedMedia(
          type: 'image',
          path: previewFile.path,
          captureSource: 'jd_video_preview')
    ]);
    await db.saveCapture(preview);
    await inventory.persist(preview, verifiedAnchor: true);
    final c = await original(receipt);
    await db.saveCapture(c);
    final retired = await inventory.persist(c, verifiedAnchor: true);
    expect(retired, isNot(contains('media-pending:$receipt')));
    expect(await inventory.canonicalMessageId(receipt, customer: 'buyer'),
        'media-pending:$receipt');
    expect(await inventory.canonicalMessage('buyer', 'verified-original'),
        'media-pending:$receipt');
    expect(await inventory.pendingMediaForTask('buyer'), isEmpty);
    final active = await (await db.database)
        .query('customer_media_items', where: 'canonical_id IS NULL');
    expect(active, hasLength(1));
    expect(active.single['item_id'], receipt);
    expect(active.single['state'], 'ready');
    expect(
        jsonDecode(active.single['aliases_json']! as String),
        containsAll([
          'media-pending:$receipt',
          'preview-observation',
          'verified-original'
        ]));
    final revision = await inventory.revision('buyer');
    expect(await inventory.persist(c, verifiedAnchor: true), isEmpty);
    expect(await inventory.revision('buyer'), revision);
    final items = await context(await history());
    expect(items, hasLength(1));
    expect(items.single['messageId'], 'media-pending:$receipt');
    expect(items.single['analysisAvailable'], isTrue);
    expect(items.single['originalVerified'], isTrue);
    expect(items.single['evidenceId'], 'frame-0');
  });

  test('frozen receipt scope excludes future pending and late-acquired files',
      () async {
    final first = await card();
    await placeholder(first);
    final frozen = await history();
    final second = await card(slot: 1);
    await placeholder(second, second: 2);
    var items = await context(frozen);
    expect(items.map((m) => m['mediaItemId']), [first]);
    final c = await original(first);
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true);
    items = await context(frozen);
    expect(items, hasLength(1));
    expect(items.single['availableMedia'], isEmpty);
    expect(items.single['analysisAvailable'], isFalse);
    expect(items.single['originalVerified'], isFalse);
    final live = await context(await history());
    expect(live, hasLength(2));
    expect(live.first['analysisAvailable'], isTrue);
    expect(live.last['analysisAvailable'], isFalse);
  });

  test('revision guard follows frozen inputs rather than later pending cards',
      () async {
    final first = await card();
    await placeholder(first);
    // This lease begins after every extraction phase has completed. Later
    // material for that same card still exercises the frozen revision guard.
    final completed = await completedVideoFixture(root, name: 'first-complete');
    final initial = capture('first-completed-video', first, media: completed);
    await db.saveCapture(initial);
    await inventory.persist(initial);
    final conversation = (await db.conversation('buyer'))!;
    final token = await db.beginGeneration(
        customer: 'buyer',
        pendingId: conversation.id,
        batchEndMessageId: 'media-pending:$first');
    expect(token, isNotNull);
    final revision = await inventory.revision('buyer');
    final second = await card(slot: 1);
    await placeholder(second, second: 2, currentTaskOnly: true);
    expect(await inventory.revision('buyer'), revision);
    final c = await original(first);
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true, currentTaskOnly: true);
    expect(await inventory.revision('buyer'), revision + 1);
  });

  test('Start isolates old unresolved acquisitions from this run', () async {
    final receipt = await card();
    await placeholder(receipt);
    expect(await inventory.pendingMediaForTask('buyer'), hasLength(1));
    await db.beginAutomationSession(
        startedAt: started.add(const Duration(seconds: 9)));
    await inventory.beginRun(started.add(const Duration(seconds: 9)));
    expect(await inventory.pendingMediaForTask('buyer'), isEmpty);
    expect(await context(await history()), isEmpty);
    expect(await context(await history(), allowHistorical: true), hasLength(1));
  });

  test('legacy callers retain the existing bounded preview wait', () async {
    final legacy =
        CaptureDatabase(storageRoot: Directory('${root.path}/legacy'));
    try {
      final oldInventory = CustomerMediaInventory(legacy);
      final receipt = await oldInventory.observe(
          customer: 'buyer',
          evidenceId: 'legacy-frame',
          observedAt: started,
          senderAt: started,
          slot: 0,
          region: [.3, .4, .2, .2],
          current: true);
      await oldInventory.classify(receipt, 'video');
      final preview =
          await File('${root.path}/legacy-preview.png').writeAsBytes([1]);
      final c = capture('legacy-preview', receipt, media: [
        CapturedMedia(
            type: 'image',
            path: preview.path,
            captureSource: 'jd_video_preview')
      ]);
      await legacy.saveCapture(c);
      await oldInventory.persist(c);
      expect(
          await oldInventory.previewWait('buyer', 'legacy-preview',
              started.add(const Duration(seconds: 2))),
          const Duration(seconds: 6));
    } finally {
      await legacy.close();
    }
  });
}
