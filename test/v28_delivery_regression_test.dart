import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<OcrInspection> frame(String name) async => OcrInspection.fromMap(
      jsonDecode(await File('test/fixtures/v28/$name.json').readAsString()));
  test(
      'recorded 0.30-confidence sender separates actual customer question from seller',
      () async {
    final result =
        const OcrCaptureExtractor().analyze(await frame('low_sender'));
    expect(
        result.capture!.messages
            .where((m) => m.direction == 'incoming')
            .any((m) => m.body.contains('多送个色带好吗')),
        isTrue);
    expect(
        result.capture!.messages
            .where((m) => m.direction == 'outgoing')
            .any((m) => m.body.contains('多送个色带好吗')),
        isFalse);
    expect(result.latestVisibleSenderIsIncoming, isTrue);
    expect(result.latestIncomingHasText, isTrue);
  });
  test(
      'recorded font toolbar cannot become a customer message or language switch',
      () async {
    final inspection = await frame('font_toolbar');
    final result = const OcrCaptureExtractor().analyze(inspection);
    expect(
        result.capture?.messages.any(
                (m) => m.direction == 'incoming' && m.body.trim() == 'Aa') ??
            false,
        isFalse);
    // An actual left-aligned customer bubble with the same letters is retained.
    final low = await frame('low_sender');
    final real = const OcrCaptureExtractor().analyze(low.withObservations(low
        .observations
        .map((o) => o.text.contains('多送个色带好吗')
            ? OcrObservation(
                text: 'Aa',
                confidence: 1,
                x: o.x,
                y: o.y,
                width: o.width,
                height: o.height)
            : o)
        .toList()));
    expect(
        real.capture!.messages
            .any((m) => m.direction == 'incoming' && m.body.startsWith('Aa')),
        isTrue);
    expect(CustomerLanguageResolver.fromText('hello, can you help me?'),
        CustomerLanguage.english);
  });
  test(
      'recorded video-only message stays visible without pretending its text is missing',
      () async {
    final inspection = await frame('video_only');
    final result = const OcrCaptureExtractor().analyze(inspection);
    expect(result.latestVisibleSenderIsIncoming, isTrue);
    expect(result.latestIncomingHasText, isFalse);
  });
  test(
      'recorded gift exception, missing order part and price difference require order authority',
      () {
    expect(requiresOrderServiceHandoff('多送个色带好吗', []), isTrue);
    expect(requiresOrderServiceHandoff('亲，不退差价，我就重新买一台', []), isTrue);
    expect(requiresOrderServiceHandoff('之前买的车架没收到', []), isTrue);
    expect(requiresOrderServiceHandoff('这个型号包装包含色带吗？', []), isFalse);
  });
  late Directory root;
  late CaptureDatabase db;
  final now = DateTime.now();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v28_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  CapturedConversation capture(String id,
          {DateTime? at,
          List<CapturedMedia> media = const [],
          String? receipt}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: '好',
                axPath: 'fixture',
                sentAt: at ?? now,
                media: media,
                mediaReceiptId: receipt)
          ]);
  test(
      'history is saved without activating replies, but a fresh live message queues',
      () async {
    await db.saveCapture(
        capture('yesterday', at: now.subtract(const Duration(days: 1))),
        isCurrentViewport: false,
        activateReplies: false);
    expect(await db.conversations(), isEmpty);
    expect((await (await db.history).read('buyer'))!['messages'], hasLength(1));
    await db.saveCapture(capture('fresh'));
    expect(await db.conversations(), hasLength(1));
    await db.saveCapture(
        capture('old-backfill', at: now.subtract(const Duration(days: 2))),
        isCurrentViewport: false,
        activateReplies: false);
    expect((await db.conversations()).single.messages.last.stableId, 'fresh');
  });
  test('a later real red signal can promote an already saved history bubble',
      () async {
    final old =
        capture('durable-old', at: now.subtract(const Duration(days: 1)));
    await db.saveCapture(old, activateReplies: false, isCurrentViewport: false);
    expect(await db.conversations(), isEmpty);
    await db.saveCapture(old, activateReplies: true);
    expect(await db.conversations(), hasLength(1));
  });
  test(
      'v26 migration preserves transfer state without inventing permission to retry',
      () async {
    final sql = await db.database;
    for (final column in [
      'preclick_retry_count',
      'preclick_retry_at_ms',
      'acknowledged'
    ]) {
      await sql.execute('ALTER TABLE chat_transfer_logs DROP COLUMN $column');
    }
    await sql.execute('PRAGMA user_version=26');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    final upgraded = await db.database;
    expect(
        (await upgraded.rawQuery('PRAGMA user_version')).single['user_version'],
        CaptureDatabase.databaseSchemaVersion);
    final fields =
        (await upgraded.rawQuery('PRAGMA table_info(chat_transfer_logs)'))
            .map((r) => r['name']);
    expect(
        fields,
        containsAll(
            ['preclick_retry_count', 'preclick_retry_at_ms', 'acknowledged']));
    expect(await db.duePreclickHandoffs(), isEmpty);
  });
  test('operator takeover cannot be overwritten by a later automatic retry',
      () async {
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'order',
        reason: 'order',
        requestMessageId: 'r');
    await db.markTicketHandoffPending(ticket.id);
    await db.markTicketContacting(ticket.id);
    await db.markTicketHandoffPending(ticket.id);
    expect(await db.isHumanContacting('buyer'), isTrue);
    expect(await db.isHandoffPending('buyer'), isFalse);
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
  });
  test(
      'a ready cached cover upgrades to the same verified video card, without false missing-text alert',
      () async {
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame',
        observedAt: now,
        senderAt: now,
        slot: 0,
        region: [.27, .49, .10, .23],
        current: true);
    expect(
        await inventory.uniqueObservedReceipt(
            customer: 'buyer', evidenceId: 'frame', senderAt: now),
        receipt);
    expect(
        await inventory.uniqueObservedReceipt(
            customer: 'buyer', evidenceId: 'later-frame', senderAt: now),
        isNull);
    expect(
        await inventory.uniqueObservedReceipt(
            customer: 'buyer',
            evidenceId: 'later-frame',
            senderAt: now,
            nativePinnedOwner: true),
        receipt);
    final image = File('${root.path}/cover.jpg');
    await image.writeAsBytes([1]);
    final video = File('${root.path}/video.mp4');
    await video.writeAsBytes([2]);
    final sampled = File('${root.path}/sample.jpg');
    await sampled.writeAsBytes([3]);
    await inventory.persist(
        capture('cover', receipt: receipt, media: [
          CapturedMedia(
              type: 'image', path: image.path, captureSource: 'jd_image_cache')
        ]),
        verifiedAnchor: true);
    final retired = await inventory.persist(
        capture('video', receipt: receipt, media: [
          CapturedMedia(
              type: 'video', path: video.path, captureSource: 'jd_video_cache'),
          CapturedMedia(
              type: 'image',
              path: sampled.path,
              captureSource: 'jd_video_frame_1fps')
        ]),
        verifiedAnchor: true);
    expect(retired, contains('cover'));
    final rows = await (await db.database).query('customer_media_items',
        where: "customer='buyer' AND canonical_id IS NULL");
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'video');
    expect(
        await inventory.bodyState(
            customer: 'buyer', evidenceId: 'reread', senderAt: now),
        'media_available');
    // Two visible cards sharing a sender timestamp must never be guessed into one.
    await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame',
        observedAt: now,
        senderAt: now,
        slot: 1,
        region: [.27, .65, .10, .1],
        current: true);
    expect(
        await inventory.uniqueObservedReceipt(
            customer: 'buyer', evidenceId: 'frame', senderAt: now),
        isNull);
  });
  test(
      'only definitely pre-click handoff failures get three bounded retries; unknown click and notice never do',
      () async {
    final ticket = await db.createHumanReviewTicket(
        userId: 'buyer',
        customerRequest: 'refund price difference',
        reason: 'order',
        requestMessageId: 'order-1');
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    for (var count = 0; count < 3; count++) {
      await db.updateChatTransferLog(
          id: log.id, status: 'failed', error: 'preclick');
      expect(await db.schedulePreclickTransferRetry(log.id), isNotNull);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
      await (await db.database).update(
          'chat_transfer_logs', {'preclick_retry_at_ms': 1},
          where: 'id=?', whereArgs: [log.id]);
      expect(await db.reserveChatTransferLog(ticket: ticket), isNotNull);
    }
    await db.updateChatTransferLog(id: log.id, status: 'failed');
    expect(await db.schedulePreclickTransferRetry(log.id), isNull);
    await db.updateChatTransferLog(id: log.id, status: 'unconfirmed');
    expect(await db.reserveChatTransferLog(ticket: ticket), isNull);
    await db.updateChatTransferLog(id: log.id, status: 'failed');
    await db.setTransferAcknowledgement(log.id, 2);
    expect(await db.schedulePreclickTransferRetry(log.id), isNull);
  });
}
