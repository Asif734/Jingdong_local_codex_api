import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'buyer';
  const region = [.24, .67, .42, .12];
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime sender;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v56_weak_text_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    sender = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 60000,
        isUtc: true);
    session = await db.beginAutomationSession(
        startedAt: sender.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedConversation capture(CapturedMessage message) => CapturedConversation(
      stableKey: buyer,
      customerName: buyer,
      customerExternalId: buyer,
      automationSessionId: session,
      capturedAt: DateTime.now().toUtc(),
      messages: [message]);

  CapturedMessage text(String id, DateTime at, {String body = 'ok'}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          sender: buyer,
          sentAt: at,
          body: body,
          axPath: 'exact incoming chat bubble with complete sender header',
          observationTurnKey: 'ocr-bubble:text-$id:exact',
          captureEvidenceId: 'text-$id');

  Future<({String id, String receipt, DateTime at, String evidence})> weak(
      {int second = 0,
      String source = 'verified_chat_viewport_fallback',
      bool partial = true,
      bool audit = true,
      bool playback = false}) async {
    final at = sender.add(Duration(seconds: second));
    final evidence = 'weak-$second';
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: evidence,
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: region,
        current: true);
    final admission = await db.admitMediaMessage(buyer,
        receiptId: receipt,
        evidenceId: evidence,
        occurrenceKey: 'incoming-$second',
        receivedAt: at,
        senderAt: at);
    await inventory.classify(receipt, 'image',
        fingerprint: 'ffffc0c1fffffefe', evidenceId: evidence, region: region);
    final message = CapturedMessage(
        stableId: admission.messageId,
        direction: 'incoming',
        sender: buyer,
        sentAt: at,
        body: '[Customer sent an image; acquisition pending.]',
        axPath: 'synthetic clipped viewport',
        captureEvidenceId: evidence,
        mediaReceiptId: receipt,
        media: [
          CapturedMedia(
              type: 'image',
              path: '${root.path}/$second.png',
              captureSource: source,
              isPartial: partial,
              captureQuality: const {
                'width': 1210,
                'height': 198,
                'touchesViewportEdge': true
              })
        ]);
    await db.saveCapture(capture(message));
    await inventory.persist(capture(message));
    if (audit) {
      // Audit and inventory observation IDs intentionally differ, as they do
      // in the recorded run. Evidence/receipt/parent prove their association.
      await (await db.database).insert('media_capture_audit', {
        'observation_id': 'audit-$second',
        'evidence_id': evidence,
        'customer': buyer,
        'state': 'image_partial',
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        'details': jsonEncode({
          'automationSessionId': session,
          'parentMessageId': admission.messageId,
          'mediaReceiptId': receipt,
          'kind': 'image',
          'source': 'frozen-window-crop',
          'isPartial': true,
          'reason': 'visible_crop_only',
          'playbackOverlayDetected': playback
        }),
      });
    }
    return (
      id: admission.messageId,
      receipt: receipt,
      at: at,
      evidence: evidence
    );
  }

  Future<Map> record(String id) async =>
      ((await (await db.history).read(buyer))!['messages'] as List)
          .cast<Map>()
          .singleWhere((m) => m['id'] == id);

  Future<String?> correct(
      ({String id, String receipt, DateTime at, String evidence}) item,
      {CapturedMessage? observation}) {
    final reading = observation ?? text(item.id, item.at);
    return db.clarifyWeakImageMessageAsText(buyer,
        parentMessageId: item.id,
        receiptId: item.receipt,
        text: reading,
        evidenceId: reading.captureEvidenceId!,
        expectedSessionId: session);
  }

  Future<void> complete(String anchor, List<String> ids) async {
    final pending = (await db.conversation(buyer))!;
    final token = (await db.beginGeneration(
        customer: buyer, pendingId: pending.id, batchEndMessageId: anchor))!;
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
    final draft = AiDraft.fromJson({
      'reply': 'You are welcome.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-v56',
      'formal_response_message_ids': ids
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(pending.id, draft,
            generationToken: token, expectedMessageId: anchor),
        1);
    await db.abandonGeneration(buyer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: buyer, reply: draft.reply);
    final at = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'sendClickedAtMs': at,
      'timeMs': at + 100
    }));
    await db.recoverDeliveryReceipts();
  }

  test('unknown then weak image then chat ok remains one formal-sendable input',
      () async {
    final item = await weak();
    expect(await db.generationAnchorMessageId(buyer), isNull);
    expect(await db.isWeakScreenshotTextCandidate(buyer, item.receipt), isTrue);
    await (await db.database).insert('automation_message_waits', {
      'session_id': session,
      'user_id': buyer,
      'message_id': item.id,
      'is_media': 1,
      'content_key': 'old-screenshot',
      'message_revision': 1,
      'task_id': 'old-wait',
      'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    expect(await correct(item), item.id);
    final message = await record(item.id);
    expect(message['body'], 'ok');
    expect(message['media'], isEmpty);
    expect(message['clarified_screenshot_media'], hasLength(1));
    expect(isClarifiedTextMessage(message), isTrue);
    expect(await db.generationAnchorMessageId(buyer), item.id);
    expect(await inventory.pendingMediaForTask(buyer), isEmpty);
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    final sql = await db.database;
    expect(await sql.query('automation_message_waits'), isEmpty);
    expect(
        (await sql.query('automation_session_messages')).single['input_kind'],
        'text');
    expect((await sql.query('media_capture_audit')).single['state'],
        'rejected_text');
    expect(
        (await sql.query('media_card_observations')).single['classified_kind'],
        isNull);
    await complete(item.id, [item.id]);
    expect(await db.isMessageFormallyAnswered(buyer, item.id), isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await correct(item), isNull,
        reason: 'A late callback must not reopen a completed input.');
  });

  test('two identical ok crops at separate sender seconds stay separate',
      () async {
    final a = await weak();
    final b = await weak(second: 199);
    expect(a.receipt, isNot(b.receipt));
    expect(await correct(a), a.id);
    expect(await correct(b), b.id);
    expect(await db.unansweredWorkCounts(), {buyer: 2});
    final incoming =
        ((await (await db.history).read(buyer))!['messages'] as List)
            .cast<Map>()
            .where((m) => m['direction'] == 'incoming');
    expect(incoming.map((m) => m['id']).toSet(), {a.id, b.id});
    await complete(b.id, [a.id, b.id]);
    expect(await db.isMessageFormallyAnswered(buyer, a.id), isTrue);
    expect(await db.isMessageFormallyAnswered(buyer, b.id), isTrue);
  });

  test(
      'late classifier and exact-clock original cannot reattach after text claim',
      () async {
    final item = await weak();
    final read = Completer<void>(), resume = Completer<void>();
    final racing = CustomerMediaInventory(db,
        beforeClassificationCommitForTesting: (_) async {
      read.complete();
      await resume.future;
    });
    final classify = racing.classify(item.receipt, 'image',
        evidenceId: item.evidence, region: region);
    await read.future;
    expect(await correct(item), item.id);
    resume.complete();
    await classify;
    final late = capture(CapturedMessage(
        stableId: item.id,
        direction: 'incoming',
        sender: buyer,
        sentAt: item.at,
        body: '[Customer sent an image; original copied from JD cache]',
        mediaReceiptId: item.receipt,
        axPath: 'late native completion',
        media: [
          CapturedMedia(
              type: 'image',
              path: '${root.path}/original.png',
              captureSource: 'jd_image_cache')
        ]));
    await db.saveCapture(late);
    await inventory.persist(late);
    expect(
        await (await db.history)
            .promoteMedia(buyer, item.id, late.messages.single),
        isFalse);
    expect((await record(item.id))['body'], 'ok');
    expect((await record(item.id))['media'], isEmpty);
    expect(
        (await (await db.database).query('customer_media_items'))
            .single['kind'],
        'text');
    expect(await inventory.pendingMediaForTask(buyer), isEmpty);
  });

  for (final value in [
    'jd_image_cache',
    'jd_image_viewer_download',
    'verified_window_crop'
  ]) {
    test('genuine $value image cannot be retracted as chat text', () async {
      final item = await weak(source: value);
      expect(
          await db.isWeakScreenshotTextCandidate(buyer, item.receipt), isFalse);
      expect(await correct(item), isNull);
      expect((await record(item.id))['media'], isNotEmpty);
    });
  }
  test('complete image, unaudited detector and playback proof stay media',
      () async {
    for (final item in [
      await weak(partial: false),
      await weak(second: 1, audit: false),
      await weak(second: 2, playback: true)
    ]) {
      expect(await correct(item), isNull);
      expect((await record(item.id))['media'], isNotEmpty);
    }
  });

  test('a real video classification can never be withdrawn as chat text',
      () async {
    final item = await weak();
    await inventory.classify(item.receipt, 'video',
        evidenceId: item.evidence, region: region);
    expect(await correct(item), isNull);
    expect((await record(item.id))['media'], isNotEmpty);
    expect(
        (await (await db.database).query('customer_media_items'))
            .single['kind'],
        'video');
  });

  test(
      'repair accepted current text without frozen input and retain newer reading',
      () async {
    final item = await weak();
    await db.saveCapture(capture(text(item.id, item.at, body: 'ok thank you')));
    expect(await correct(item, observation: text(item.id, item.at)), item.id);
    await db.repairSessionPendingWork(buyer);
    expect((await record(item.id))['body'], 'ok thank you');
    expect((await record(item.id))['media'], isEmpty);
    expect(await db.generationAnchorMessageId(buyer), item.id);
    expect(await (await db.database).query('automation_reply_inputs'), isEmpty);
  });

  test('accepted chat text with no source metadata outranks a stale correction',
      () async {
    final item = await weak();
    // The ordinary extractor initially saves readable chat text before its
    // immutable evidence attribution; both optional source fields are null.
    await db.saveCapture(capture(CapturedMessage(
        stableId: item.id,
        direction: 'incoming',
        sender: buyer,
        sentAt: item.at,
        body: 'ok thank you for the updated instructions',
        axPath: 'ordinary extracted customer chat text')));
    final before = await record(item.id);
    expect(before['text_origin'], 'customer_text');
    expect(before['text_source_evidence_id'], isNull);
    expect(await correct(item, observation: text(item.id, item.at)), item.id);
    final after = await record(item.id);
    expect(after['body'], 'ok thank you for the updated instructions');
    expect(after['media'], isEmpty);
    expect(await db.generationAnchorMessageId(buyer), item.id);
  });

  test('durable file correction after crash finishes its exact queue commit',
      () async {
    final item = await weak();
    final reading = text(item.id, item.at);
    final stored = await (await db.history).clarifyUnknownMessageAsText(buyer,
        parentMessageId: item.id,
        receiptId: item.receipt,
        text: reading,
        sessionId: session,
        evidenceId: reading.captureEvidenceId!,
        allowWeakScreenshot: true,
        minimumRevision: 2);
    expect(stored, isNotNull);
    await db.repairSessionPendingWork(buyer);
    expect(await inventory.pendingMediaForTask(buyer), isEmpty);
    expect(await db.generationAnchorMessageId(buyer), item.id);
    expect(
        (await (await db.database).query('automation_session_messages'))
            .single['input_kind'],
        'text');
  });

  test(
      'wrong sender second and unknown native click preserve original pending duty',
      () async {
    final item = await weak();
    expect(
        await correct(item,
            observation:
                text(item.id, item.at.add(const Duration(seconds: 1)))),
        isNull);
    final sql = await db.database;
    final at = DateTime.now().millisecondsSinceEpoch;
    await sql.insert('delivery_attempts', {
      'attempt_id': 'uncertain-native',
      'task_id': 'old-task',
      'user_id': buyer,
      'pending_id': 1,
      'reply': 'old',
      'raw_json': jsonEncode({'service_session_id': session}),
      'batch_end_message_id': item.id,
      'state': 'sending',
      'created_at_ms': at,
      'updated_at_ms': at,
      'kind': 'reply'
    });
    expect(await correct(item), isNull);
    expect((await record(item.id))['media'], isNotEmpty);
    expect(await db.unansweredWorkCounts(), {buyer: 1});
  });
}
