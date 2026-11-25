import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/codex/customer_language.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  final at = DateTime.utc(2026, 11, 4, 6, 30);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v29_media_history_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  CapturedConversation text(String id, String body,
          {DateTime? sent, String? key, bool undated = false}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                sentAt: undated ? null : sent ?? at,
                axPath: 'fixture',
                observationTurnKey: key)
          ]);
  Future<Map> stored() async =>
      ((await (await db.history).read('buyer'))!['messages'] as List).single
          as Map;
  for (final scenario in [
    'exact',
    'saved-frame',
    'known-alias',
    'spelling',
    'deferred-clock',
    'incomplete',
    'partial-live',
    'word-order'
  ]) {
    test(
        'live $scenario observation promotes canonical history without replacing its ID',
        () async {
      var before = text('history-A', 'please transfer me');
      var after = text('live-B', 'please transfer me');
      if (scenario == 'exact') after = text('history-A', 'please transfer me');
      if (scenario == 'saved-frame' || scenario == 'known-alias') {
        before = text('history-A', '客户需要解决的问题', key: 'ocr-bubble:frame:1');
        after = text('live-B', '客户需要解决的问题', key: 'ocr-bubble:frame:1');
      }
      if (scenario == 'spelling') {
        before = text('history-A', 'please transter me');
      }
      if (scenario == 'deferred-clock') {
        before = text('history-A', 'check this printer',
            key: 'saved:clock-unresolved-after-media', undated: true);
        after = text('live-B', 'check this printer',
            sent: at.subtract(const Duration(seconds: 1)));
      }
      if (scenario == 'incomplete') {
        before = text('history-A', 'where is the repair');
        after = text('live-B', 'where is the repair centre please');
      }
      if (scenario == 'partial-live') {
        before = text('history-A', 'where is the repair centre please');
        after = text('live-B', 'where is the repair');
      }
      if (scenario == 'word-order') {
        before = text('history-A', 'please help this printer');
        after = text('live-B', 'this printer help please');
      }
      await db.saveCapture(before,
          activateReplies: false, isCurrentViewport: false);
      if (scenario == 'known-alias') {
        await db.saveCapture(after,
            activateReplies: false, isCurrentViewport: false);
      }
      expect(await db.conversations(), isEmpty);
      final changed = await db.saveCapture(after, activateReplies: true);
      expect(changed, greaterThan(0));
      final message = await stored();
      expect(message['id'], 'history-A');
      expect(message['capture_purpose'], 'live_signal');
      if (scenario == 'partial-live') {
        expect(message['body'], 'where is the repair centre please');
      }
      expect(await db.pendingMessageId('buyer'), 'history-A');
      expect(await db.conversations(), hasLength(1));
      expect(await db.saveCapture(after), 0,
          reason: 'The same live bubble is not activated twice.');
    });
  }
  test('live correction preserves an already answered canonical cursor',
      () async {
    await db.saveCapture(text('answered-A', 'please transter me'),
        activateReplies: false, isCurrentViewport: false);
    await (await db.database).insert(
        'answered_cursors', {'user_id': 'buyer', 'message_id': 'answered-A'});
    await db.saveCapture(text('corrected-B', 'please transfer me'));
    final message = await stored();
    expect(message['id'], 'answered-A');
    expect(message['observed_ids'], contains('corrected-B'));
    expect(await db.answeredMessageId('buyer'), 'answered-A');
    expect(await db.isBatchUnanswered('buyer', 'answered-A'), isFalse);
    expect(await db.conversations(), isEmpty);
  });

  test('a true later repetition remains a separate incoming message', () async {
    await db.saveCapture(text('first', 'please transfer me'),
        activateReplies: false, isCurrentViewport: false);
    await db.saveCapture(text('later', 'please transfer me',
        sent: at.add(const Duration(minutes: 1))));
    final messages =
        (await (await db.history).read('buyer'))!['messages'] as List;
    expect(messages, hasLength(2));
    expect(await db.pendingMessageId('buyer'), 'later');
  });
  test('undated historical English cannot replace explicit current Chinese',
      () {
    final selected = CustomerLanguageResolver.resolve([
      {
        'id': 'history',
        'direction': 'incoming',
        'body': 'hello, please help me',
        'capture_purpose': 'history_only',
        'captured_at': at.add(const Duration(seconds: 30)).toIso8601String()
      },
      {
        'id': 'current',
        'direction': 'incoming',
        'body': '请用中文回答我的问题',
        'sent_at': at.toIso8601String(),
        'captured_at': at.toIso8601String()
      },
    ]);
    expect(selected.language, CustomerLanguage.chinese);
    expect(selected.sourceMessageId, 'current');
  });
  test(
      'undated language history remains a fallback for the first image-only turn',
      () {
    final selected = CustomerLanguageResolver.resolve([
      {
        'id': 'old',
        'direction': 'incoming',
        'body': 'hello, please help',
        'capture_purpose': 'history_only'
      },
      {
        'id': 'image',
        'direction': 'incoming',
        'body': '[Customer sent an image.]',
        'text_origin': 'media'
      },
    ]);
    expect(selected.language, CustomerLanguage.english);
  });
  Future<CapturedConversation> media(String id, String receipt,
      {bool preview = false,
      DateTime? sent,
      DateTime? observedAt,
      bool undated = false}) async {
    final original = File('${root.path}/$id.${preview ? 'jpg' : 'mp4'}');
    await original.writeAsBytes([1]);
    final frame = File('${root.path}/$id-frame.jpg');
    await frame.writeAsBytes([2]);
    return CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: observedAt ?? at,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[media]',
              sentAt: undated ? null : sent ?? at,
              axPath: 'native-verified',
              mediaReceiptId: receipt,
              media: preview
                  ? [
                      CapturedMedia(
                          type: 'image',
                          path: original.path,
                          captureSource: 'jd_video_preview')
                    ]
                  : [
                      CapturedMedia(
                          type: 'video',
                          path: original.path,
                          captureSource: 'jd_video_cache'),
                      CapturedMedia(
                          type: 'image',
                          path: frame.path,
                          captureSource: 'jd_video_frame_1fps')
                    ])
        ]);
  }

  AiDraft draft(int revision) => AiDraft.fromJson({
        'reply': '针对刚刚视频的正式处理建议',
        'decision': 'answer',
        'confidence': 1,
        'risk_level': 'low',
        'human_review_required': false,
        'risk_triggers': [],
        'used_record_ids': [],
        'actions': [],
        'attachments': [],
        'auto_send_allowed': true,
        'model': 'v29-test'
      }, mediaBaseUrl: Uri())
          .withMediaContext(revision, true);
  test(
      'unrelated history picture persists without retiring a ready current answer',
      () async {
    final inventory = CustomerMediaInventory(db);
    await db.saveCapture(text('current', '请帮我解决刚刚视频里的打印问题'));
    await db.saveDraft((await db.conversations()).single.id, draft(0));
    final file = File('${root.path}/old-image.jpg');
    await file.writeAsBytes([1]);
    final old = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'old-image',
              direction: 'incoming',
              body: '[image]',
              sentAt: at.subtract(const Duration(hours: 2)),
              axPath: 'history',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: file.path,
                    captureSource: 'jd_image_cache')
              ])
        ]);
    await db.saveCapture(old, isCurrentViewport: false, activateReplies: false);
    await inventory.persist(old, verifiedAnchor: true, currentTaskOnly: true);
    expect(await inventory.revision('buyer'), 0);
    expect(await db.retireStaleMediaDraft('buyer'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(
        await (await db.database).query('customer_media_items'), hasLength(1));
  });
  test(
      'a late verified original still invalidates a draft depending on that preview',
      () async {
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.2, .3, .2, .2],
        current: true);
    final preview = await media('preview', receipt, preview: true);
    await db.saveCapture(preview);
    await inventory.persist(preview,
        verifiedAnchor: true, currentTaskOnly: true);
    final revision = await inventory.revision('buyer');
    await db.saveDraft((await db.conversations()).single.id, draft(revision));
    final original = await media('original', receipt);
    await db.saveCapture(original,
        activateReplies: false, isCurrentViewport: false);
    final retired = await inventory.persist(original,
        verifiedAnchor: true, currentTaskOnly: true);
    expect(retired, contains('preview'));
    expect(await inventory.revision('buyer'), greaterThan(revision));
    expect(await db.retireStaleMediaDraft('buyer'), isTrue);
  });
  test('a prior unclocked preview upgrade still invalidates the later question',
      () async {
    final inventory = CustomerMediaInventory(db);
    final earlier = at.subtract(const Duration(seconds: 5));
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'unclocked-card',
        observedAt: earlier,
        senderAt: null,
        slot: 0,
        region: [.2, .3, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final preview = await media('earlier-preview', receipt,
        preview: true, undated: true, observedAt: earlier);
    await db.saveCapture(preview);
    await inventory.persist(preview,
        verifiedAnchor: true, currentTaskOnly: true);
    await db.saveCapture(text('later-question', '请告诉我视频里是什么问题'));
    final revision = await inventory.revision('buyer');
    await db.saveDraft((await db.conversations()).single.id, draft(revision));
    final original = await media('late-unclocked-original', receipt,
        undated: true, observedAt: at.add(const Duration(seconds: 5)));
    await db.saveCapture(original,
        activateReplies: false, isCurrentViewport: false);
    final upgraded = await inventory.persist(original,
        verifiedAnchor: true, currentTaskOnly: true);
    expect(upgraded, contains('earlier-preview'));
    expect(await inventory.revision('buyer'), greaterThan(revision));
    expect(await db.retireStaleMediaDraft('buyer'), isTrue);
  });

  test('late history stays outside a frozen context even during a long run',
      () async {
    final inventory = CustomerMediaInventory(db);
    await inventory.beginRun(at.subtract(const Duration(hours: 3)));
    await db.saveCapture(text('current', '请分析刚才的视频'));
    await db.saveDraft((await db.conversations()).single.id, draft(0));
    final old = await media('old-video', 'historic-receipt',
        sent: at.subtract(const Duration(hours: 2)),
        observedAt: at.add(const Duration(seconds: 5)));
    await db.saveCapture(old, activateReplies: false, isCurrentViewport: false);
    await inventory.persist(old, verifiedAnchor: true, currentTaskOnly: true);
    expect(await inventory.revision('buyer'), 0);
    expect(await db.retireStaleMediaDraft('buyer'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
  });

  test(
      'bind observed attempt is idempotent and preserves canonical bubble and old batch',
      () async {
    final store = await db.history;
    await store.appendCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at.add(const Duration(seconds: 5)),
        messages: [
          CapturedMessage(
              stableId: 'q1',
              direction: 'incoming',
              body: 'first question',
              sentAt: at,
              axPath: 'fixture'),
          CapturedMessage(
              stableId: 'q2',
              direction: 'incoming',
              body: 'new question',
              sentAt: at.add(const Duration(seconds: 2)),
              axPath: 'fixture'),
          CapturedMessage(
              stableId: 'observed-reply',
              direction: 'outgoing',
              body: 'verified earlier answer',
              sentAt: at.add(const Duration(seconds: 5)),
              axPath: 'fixture',
              observationTurnKey: 'ocr-bubble:reply:1')
        ]));
    await store.appendCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at.add(const Duration(seconds: 6)),
        messages: [
          CapturedMessage(
              stableId: 'reply-alias',
              direction: 'outgoing',
              body: 'verified earlier answer',
              sentAt: at.add(const Duration(seconds: 5)),
              axPath: 'fixture',
              observationTurnKey: 'ocr-bubble:reply:1')
        ]));
    final before = ((await store.read('buyer'))!['messages'] as List)
        .whereType<Map>()
        .singleWhere((m) => m['id'] == 'observed-reply');
    Future<bool> bind(
            {String attempt = 'attempt-1', String message = 'reply-alias'}) =>
        store.bindObservedAttempt(
            userId: 'buyer',
            messageId: message,
            attemptId: attempt,
            taskId: 'task-1',
            batchEndMessageId: 'q1');
    expect(await bind(), isTrue);
    expect(await bind(), isTrue);
    expect(await bind(attempt: 'different-attempt'), isFalse);
    expect(await bind(message: 'missing'), isFalse);
    expect(await bind(message: 'q2'), isFalse);
    final history = (await store.read('buyer'))!['messages'] as List;
    expect(history, hasLength(3));
    final after = history
        .whereType<Map>()
        .singleWhere((m) => m['id'] == 'observed-reply');
    for (final key in [
      'id',
      'body',
      'sender',
      'sent_at',
      'captured_at',
      'observed_ids'
    ]) {
      expect(after[key], before[key], reason: key);
    }
    expect(after['source'], 'generated_reply');
    expect(after['delivery_status'], 'sent');
    expect(after['delivery_attempt_id'], 'attempt-1');
    expect(after['delivery_task_id'], 'task-1');
    expect(after['answered_batch_end_id'], 'q1');
    expect(await db.isBatchUnanswered('buyer', 'q1'), isFalse);
    expect(await db.isBatchUnanswered('buyer', 'q2'), isTrue);
  });

  test('different-thumbnail video cards are not fused by their clock and slot',
      () async {
    final inventory = CustomerMediaInventory(db);
    final a = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame-A',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.2, .3, .2, .2],
        current: true);
    await inventory.classify(a, 'video', fingerprint: '0000000000000000');
    await inventory.persist(await media('preview-A', a, preview: true),
        verifiedAnchor: true);
    final b =
        await inventory.classify(a, 'video', fingerprint: 'ffffffffffffffff');
    await inventory.persist(await media('preview-B', b, preview: true),
        verifiedAnchor: true);
    final retired = await inventory.persist(await media('original-B', b),
        verifiedAnchor: true);
    expect(retired, contains('preview-B'));
    expect(retired, isNot(contains('preview-A')));
    expect(await inventory.canonicalMessage('buyer', 'preview-A'), isNull);
    final sql = await db.database;
    final roots =
        await sql.query('customer_media_items', where: 'canonical_id IS NULL');
    expect(roots, hasLength(2));
    expect(
        roots.singleWhere((r) => r['item_id'] == a)['identity_ambiguous'], 1);
    // A's own original can subsequently resolve A, while preserving B.
    await inventory.persist(await media('original-A', a), verifiedAnchor: true);
    final finalRoots =
        await sql.query('customer_media_items', where: 'canonical_id IS NULL');
    expect(finalRoots, hasLength(2));
    expect(finalRoots.map((r) => r['message_id']).toSet(),
        {'original-A', 'original-B'});
  });
}
