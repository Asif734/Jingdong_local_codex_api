import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

AiDraft answer({bool review = false}) => AiDraft.fromJson({
      'reply': review
          ? 'This issue needs further checking. I have kept the details you provided and will continue here after the next check.'
          : 'Connect the printer with its supplied USB cable.',
      'reply_purpose': 'substantive',
      'decision': review ? 'human_review_required' : 'draft',
      'human_review_required': review,
      'risk_triggers': review ? ['solution_not_found'] : [],
      'reason': review ? 'Codex could not find a reliable solution.' : null,
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-fixture',
      'auto_send_allowed': false,
    }, mediaBaseUrl: Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v37_message_records_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch,
        isUtc: true);
    await db.beginAutomationSession(startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> receive(String id,
      {String? receipt,
      String? body,
      DateTime? captured,
      DateTime? sender,
      String customer = 'buyer'}) async {
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: captured ?? DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body ??
                  (receipt == null
                      ? 'Question $id'
                      : '[Customer sent media; acquisition pending.]'),
              sentAt: sender,
              observationTurnKey: id,
              axPath: 'distinct incoming bubble $id',
              mediaReceiptId: receipt)
        ]));
  }

  Future<String> begin(String id) async => (await db.beginGeneration(
      customer: 'buyer',
      pendingId: (await db.conversation('buyer'))!.id,
      batchEndMessageId: id))!;
  Future<void> save(String id, String token, AiDraft draft) async {
    expect(
        await db.saveDraft((await db.conversation('buyer'))!.id, draft,
            expectedMessageId: id, generationToken: token),
        1);
    await db.abandonGeneration('buyer', token);
  }

  Future<void> provenItems({bool fork = true}) async {
    final sql = await db.database;
    for (final id in ['base', if (fork) 'fork']) {
      await sql.insert('customer_media_items', {
        'item_id': id, 'customer': 'buyer',
        'sender_ms': start.millisecondsSinceEpoch,
        'slot': 0, 'kind': 'video',
        'state': id == 'base' ? 'preview' : 'superseded',
        'first_seen_ms': start.millisecondsSinceEpoch,
        'last_seen_ms': start.millisecondsSinceEpoch,
        'canonical_id': id == 'base' ? null : 'base',
        'message_id': 'media-pending:$id', 'media_json': '[]',
        // A related text question is not a representation of the video.
        'aliases_json': jsonEncode(['media-pending:$id', 'independent']),
      });
    }
    final doc = await (await db.history).read('buyer');
    final original = (doc!['messages'] as List)
        .cast<Map>()
        .singleWhere((m) => m['id'] == 'media-pending:base');
    await admitFixtureMedia(db,
        receiptId: 'base',
        messageId: 'media-pending:base',
        receivedAt: DateTime.parse(original['captured_at']! as String));
  }

  test('receive order is distinct from sender clock and same-second bubbles',
      () async {
    final first = start.add(const Duration(seconds: 2));
    final second = start.add(const Duration(seconds: 3));
    final clock = start.add(const Duration(seconds: 1));
    await receive('paper-size',
        body: 'What paper size is supported?', captured: first, sender: clock);
    await receive('warranty',
        body: 'How long is the warranty?', captured: second, sender: clock);
    final records = await db.customerMessageRecords('buyer');
    expect(records.map((r) => r.stableId), ['paper-size', 'warranty']);
    expect(records.map((r) => r.receivedAt), [first, second]);
    expect(records.map((r) => r.messageAt), [clock, clock]);
    expect(records.every((r) => r.status == 'pending' && r.kind == 'text'),
        isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
  });

  test('native click is the reply time and status follows actual ownership',
      () async {
    await receive('connect', body: 'How do I connect by USB?');
    final token = await begin('connect');
    expect(
        (await db.customerMessageRecords('buyer')).single.status, 'analyzing');
    final draft = await db.prepareAutomaticDraft('buyer', answer());
    await save('connect', token, draft);
    expect((await db.customerMessageRecords('buyer')).single.status, 'ready');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: draft.reply);
    expect((await db.customerMessageRecords('buyer')).single.status, 'sending');
    final clicked = DateTime.now().toUtc();
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': clicked.millisecondsSinceEpoch,
      'timeMs':
          clicked.add(const Duration(milliseconds: 700)).millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
    final record = (await db.customerMessageRecords('buyer')).single;
    expect(record.status, 'answered');
    expect(record.repliedAt!.millisecondsSinceEpoch,
        clicked.millisecondsSinceEpoch);
    expect(record.replyTimeSource, 'native_click');
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test('legacy confirmed ledger projects its honest confirmation time',
      () async {
    await receive('legacy-confirmed', body: 'How do I connect the USB cable?');
    final token = await begin('legacy-confirmed');
    final draft = await db.prepareAutomaticDraft('buyer', answer());
    await save('legacy-confirmed', token, draft);
    // Imported legacy completed rows may lack an attempt journal. The
    // projection must state that provenance, without providing an automatic
    // no-proof mark-sent API for new work.
    await (await db.database).update(
        'automation_session_messages',
        {
          'response_state': 'answered',
          'responded_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [
          db.currentAutomationSessionId,
          'buyer',
          'legacy-confirmed'
        ]);
    await (await db.database)
        .delete('generated_drafts', where: 'user_id=?', whereArgs: ['buyer']);

    final record = (await db.customerMessageRecords('buyer')).single;
    final ledger = (await (await db.database).query(
            'automation_session_messages',
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [
          db.currentAutomationSessionId,
          'buyer',
          'legacy-confirmed'
        ]))
        .single;
    expect(record.status, 'answered');
    expect(record.repliedAt!.millisecondsSinceEpoch, ledger['responded_at_ms']);
    expect(record.replyTimeSource, 'ledger_confirmation');
  });

  test('review promise is parked and never completes its real question',
      () async {
    await receive('fault', body: 'The printer keeps shutting down.');
    final token = await begin('fault');
    final draft = await db.prepareAutomaticDraft('buyer', answer(review: true));
    expect(
        (jsonDecode(draft.rawJson) as Map)['reply_purpose'], 'review_status');
    await save('fault', token, draft);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'fault'), isFalse);
    expect((await db.customerMessageRecords('buyer')).single.status,
        'awaiting_review');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    await receive('independent', body: 'What is the warranty period?');
    expect(await db.generationDue('buyer'), isTrue);
    final next = await begin('independent');
    final inputs = (await db.generationMessages('buyer'))
        .where((m) => m['direction'] == 'incoming')
        .map((m) => m['id']);
    expect(inputs, ['independent']);
    await db.abandonGeneration('buyer', next);
  });

  test('proven media family has one row while related text stays independent',
      () async {
    await receive('media-pending:base', receipt: 'base');
    await receive('media-pending:fork', receipt: 'fork');
    await receive('independent', body: 'What is the paper size?');
    await provenItems();
    final records = await db.customerMessageRecords('buyer');
    expect(
        records.map((r) => r.stableId), ['media-pending:base', 'independent']);
    expect(records.map((r) => r.kind), ['video', 'text']);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
  });

  test(
      'confirmed substantive media stays completed through late derived aliases',
      () async {
    await receive('media-pending:base', receipt: 'base');
    await provenItems(fork: false);
    final sql = await db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await sql.insert('delivery_attempts', {
      'attempt_id': 'confirmed-native',
      'task_id': 'formal-media',
      'user_id': 'buyer',
      'pending_id': 1,
      'reply': 'The paper is loaded backwards; reverse it.',
      'raw_json': jsonEncode({
        'reply_purpose': 'substantive',
        'service_session_id': db.currentAutomationSessionId,
        'native_confirmed_at_ms': now,
        'service_message_ids': ['media-pending:base'],
        'formal_response_message_ids': ['media-pending:base'],
        'native_reply_at_ms': now,
        'native_reply_time_source': 'native_click'
      }),
      'batch_end_message_id': 'media-pending:base',
      'kind': 'reply',
      'state': 'submitted',
      'created_at_ms': now,
      'updated_at_ms': now,
    });
    await sql.update(
        'automation_session_messages',
        {
          'response_state': 'answered',
          'answered_attempt_id': 'confirmed-native',
          'answered_task_id': 'formal-media',
          'responded_at_ms': now
        },
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [
          db.currentAutomationSessionId,
          'buyer',
          'media-pending:base'
        ]);
    await receive('media-pending:fork', receipt: 'fork');
    await sql.insert('customer_media_items', {
      'item_id': 'fork',
      'customer': 'buyer',
      'sender_ms': start.millisecondsSinceEpoch,
      'slot': 0,
      'kind': 'video',
      'state': 'superseded',
      'first_seen_ms': now,
      'last_seen_ms': now,
      'canonical_id': 'base',
      'message_id': 'media-pending:fork',
      'media_json': '[]',
      'aliases_json': '["media-pending:fork"]',
    });
    for (final key in ['frames', 'speech', 'cover']) {
      expect(
          await db.reopenMessageForNewEvidence('buyer', 'media-pending:base',
              evidenceKey: key),
          isFalse);
      await db.repairSessionPendingWork('buyer');
      expect(await db.generationDue('buyer'), isFalse);
      expect(await db.unansweredWorkCounts(), isEmpty);
      final records = await db.customerMessageRecords('buyer');
      expect(records, hasLength(1));
      expect(records.single.status, 'answered');
    }
    await receive('independent', body: 'Does this model support Bluetooth?');
    expect(await db.generationDue('buyer'), isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('unbound observations never create business and Start remains isolated',
      () async {
    final sql = await db.database;
    for (final id in ['one', 'two']) {
      await sql.insert('media_capture_audit', {
        'observation_id': id,
        'evidence_id': id,
        'customer': 'buyer',
        'state': 'unbound',
        'details': jsonEncode({
          'automationSessionId': db.currentAutomationSessionId,
          'observationId': id,
          'observationGroupId': 'proven-one-card',
          'capturedAt': start.add(const Duration(seconds: 2)).toIso8601String()
        }),
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
      });
    }
    expect(await db.customerMessageRecords('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.customerMessageRecords('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    await receive('new', body: 'Can I use a Mac?');
    expect((await db.customerMessageRecords('buyer')).single.stableId, 'new');
  });
  test('all video phases and exact caption finish before one formal reply',
      () async {
    final inventory = CustomerMediaInventory(db);
    final observed = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'owned-frame',
        observedAt: observed,
        senderAt: observed,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final id = 'media-pending:$receipt';
    await db.registerMediaInputDependency('buyer',
        textMessageId: 'caption',
        receiptId: receipt,
        evidenceId: 'owned-frame');
    await receive(id, receipt: receipt, sender: observed);
    await receive('caption',
        body: 'check my td630, what happened to it?', sender: observed);
    await receive('other-question',
        customer: 'other', body: 'What is the warranty?');
    final video = await File('${root.path}/video.mp4').writeAsBytes([1]);
    final frame = await File('${root.path}/frame_00.jpg').writeAsBytes([2]);
    final tail = await File('${root.path}/frame_tail.jpg').writeAsBytes([4]);
    final cover = await File('${root.path}/cover.jpg').writeAsBytes([3]);
    CapturedConversation content({String? audio}) => CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: DateTime.now().toUtc(),
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: '[Customer sent a video]',
                  axPath: 'same exact owned card',
                  mediaReceiptId: receipt,
                  sentAt: observed,
                  media: [
                    CapturedMedia(
                        type: 'video',
                        path: video.path,
                        captureSource: 'jd_video_cache',
                        description: audio),
                    CapturedMedia(
                        type: 'image',
                        path: frame.path,
                        captureSource: 'jd_video_frame_1fps',
                        originalName: 'video_frame_00s.jpg'),
                    CapturedMedia(
                        type: 'image',
                        path: tail.path,
                        captureSource: 'jd_video_frame_1fps',
                        originalName: 'video_frame_tail.jpg'),
                    CapturedMedia(
                        type: 'image',
                        path: cover.path,
                        captureSource: 'jd_video_cover'),
                  ])
            ]);
    final first = content();
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: id,
        receivedAt: observed,
        senderAt: observed);
    await db.saveCapture(first);
    await inventory.persist(first, verifiedAnchor: true);
    expect(await inventory.analyzableEvidenceKeys('buyer'), isNotEmpty,
        reason: 'Decoded visual content alone is only progress');
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.generationAnchorMessageId('buyer'), isNull);
    expect(await db.generationDue('other'), isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 2, 'other': 1});
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait.');
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.nextReadyDelivery(), isNull);
    const terminal = '[Video audio: no audio stream]';
    expect(
        await inventory.updateProvenVideoDescription(
            'buyer', video.path, terminal,
            messageId: id, receiptId: receipt),
        greaterThan(0));
    await (await db.history)
        .updateMediaDescriptions('buyer', {video.path: terminal});
    expect(await inventory.analysisReadyMessageIds('buyer'), contains(id));
    expect(await db.generationDue('buyer'), isTrue);
    final end = (await db.generationAnchorMessageId('buyer'))!;
    final token = await begin(end);
    final frozen = (await db.generationMessages('buyer'))
        .where((m) => m['direction'] == 'incoming')
        .map((m) => m['id'])
        .toList();
    expect(frozen, containsAll([id, 'caption']));
    final draft = await db.prepareAutomaticDraft('buyer', answer());
    await save(end, token, draft);
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: draft.reply);
    final clicked = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': clicked,
      'timeMs': clicked + 500
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered('buyer', id), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'caption'), isTrue);
    expect(await db.unansweredWorkCounts(), {'other': 1});
    expect((await db.customerMessageRecords('buyer')).map((r) => r.status),
        ['answered', 'answered']);
    for (final extra in [
      '[Frame analysis: same existing frames]',
      '[Audio summary: no new customer input]'
    ]) {
      await (await db.history)
          .updateMediaDescriptions('buyer', {video.path: extra});
      await inventory.updateProvenVideoDescription('buyer', video.path, extra,
          messageId: id, receiptId: receipt);
      await db.repairSessionPendingWork('buyer');
      expect(await db.generationDue('buyer'), isFalse);
      expect((await db.customerMessageRecords('buyer')), hasLength(2));
      expect(await db.unansweredWorkCounts(), {'other': 1});
    }
    expect(
        (await (await db.database).query('delivery_attempts',
            where: "user_id='buyer' AND kind='reply'")),
        hasLength(1));
  });
}
