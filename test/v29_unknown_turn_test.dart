import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

AiDraft _draft(String reply) => AiDraft.fromJson({
      'reply': reply,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'v29',
      'used_record_ids': [],
      'actions': [],
      'attachments': []
    }, mediaBaseUrl: Uri());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v29_unknown_turn_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String id,
      {String? body,
      DateTime? sent,
      DateTime? observedAt,
      bool undated = false,
      bool history = false,
      List<CapturedMedia> media = const [],
      String? receipt}) async {
    final time = sent ?? start;
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'a',
            customerName: 'a',
            customerExternalId: 'a',
            capturedAt: observedAt ?? time,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: body ?? 'Real question $id',
                  sentAt: undated ? null : time,
                  axPath: 'fixture',
                  media: media,
                  mediaReceiptId: receipt)
            ]),
        activateReplies: !history,
        isCurrentViewport: !history);
  }

  Future<({Map<String, String> attempt, String task, int created})> unknown(
      {List<CapturedMedia> media = const [],
      String? receipt,
      bool undated = false}) async {
    await incoming('q1',
        body: 'please transter the chat', media: media, receipt: receipt);
    final draft = _draft('The earlier formal answer.');
    await db.saveDraft((await db.conversations()).single.id, draft,
        expectedMessageId: 'q1');
    final delivery = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'a', reply: draft.reply, taskId: delivery.taskId);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'unknown',
      'error': 'send_not_committed',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'a', taskId: delivery.taskId, error: 'send_not_committed');
    final row = (await (await db.database).query('delivery_attempts')).single;
    expect(row['state'], 'unknown');
    return (
      attempt: attempt,
      task: delivery.taskId!,
      created: row['created_at_ms']! as int
    );
  }

  Future<void> queueNewQuestion(int created) async {
    await incoming('q2',
        sent: DateTime.fromMillisecondsSinceEpoch(created + 5000, isUtc: true));
    expect(await db.detachUnknownForNewInput('a'), isTrue);
    expect(await db.hasUndeliveredDraft('a'), isFalse);
    await db.saveDraft((await db.conversations()).single.id,
        _draft('The newer formal answer.'),
        expectedMessageId: 'q2');
  }

  Future<String?> activeBatch() async =>
      (await (await db.database).query('generated_drafts'))
          .single['batch_end_message_id'] as String?;

  Future<Map<String, Object?>> attemptRow(String id) async =>
      (await (await db.database).query('delivery_attempts',
              where: 'attempt_id=?', whereArgs: [id]))
          .single;

  test(
      'old physical unknown stays in ledger while real q2 gets a sendable task',
      () async {
    final old = await unknown();
    await queueNewQuestion(old.created);
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        'superseded_unknown');
    for (var i = 0; i < 3; i++) {
      await db.recoverDeliveryReceipts();
    }
    expect(await activeBatch(), 'q2');
    expect(await db.isBatchUnanswered('a', 'q2'), isTrue);
    final next = (await db.nextReadyDelivery())!;
    expect(next.taskId, isNot(old.task));
    expect(next.draft.reply, 'The newer formal answer.');
    await expectLater(
        db.beginDeliveryAttempt(
            userId: 'a', reply: 'The earlier formal answer.', taskId: old.task),
        throwsStateError);
    expect(await (await db.database).query('delivery_attempts'), hasLength(1));
  });

  test('spelling reread of q1 is not a new task allowed to detach its unknown',
      () async {
    final old = await unknown();
    await incoming('q1-alias', body: 'please transfer the chat');
    expect(
        ((await (await db.history).read('a'))!['messages'] as List)
            .single['id'],
        'q1');
    expect(await db.detachUnknownForNewInput('a'), isFalse);
    expect((await attemptRow(old.attempt['attemptId']!))['state'], 'unknown');
    expect(await db.hasUndeliveredDraft('a'), isTrue);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test('historical OCR is not positive new input for detaching an unknown',
      () async {
    final old = await unknown();
    await incoming('history-only',
        sent: DateTime.fromMillisecondsSinceEpoch(old.created + 5000,
            isUtc: true),
        history: true);
    expect(await db.detachUnknownForNewInput('a'), isFalse);
    expect((await attemptRow(old.attempt['attemptId']!))['state'], 'unknown');
  });

  test(
      'same-card media representation upgrade cannot detach and resend an uncertain answer',
      () async {
    final file = await File('${root.path}/media').writeAsBytes([1]);
    final old = await unknown(media: [
      CapturedMedia(
          type: 'image', path: file.path, captureSource: 'jd_video_preview')
    ], receipt: 'same-card');
    await incoming('original',
        body: '[video]',
        media: [
          CapturedMedia(
              type: 'video', path: file.path, captureSource: 'jd_video_cache')
        ],
        receipt: 'same-card',
        observedAt: DateTime.fromMillisecondsSinceEpoch(old.created + 5000,
            isUtc: true));
    expect(await db.detachUnknownForNewInput('a'), isFalse);
    expect((await attemptRow(old.attempt['attemptId']!))['state'], 'unknown');
  });

  test('new observation with an older sender clock cannot detach an unknown',
      () async {
    final old = await unknown();
    await incoming('late-older-ocr',
        sent: start.subtract(const Duration(seconds: 1)),
        observedAt: DateTime.fromMillisecondsSinceEpoch(old.created + 5000,
            isUtc: true));
    expect(await db.detachUnknownForNewInput('a'), isFalse);
    expect((await attemptRow(old.attempt['attemptId']!))['state'], 'unknown');
  });

  test(
      'a pre-attempt saved frame is not new input even with a separate text ID',
      () async {
    final old = await unknown();
    await incoming('old-frame',
        sent: start.add(const Duration(seconds: 1)),
        observedAt: start.add(const Duration(seconds: 1)));
    expect(await db.detachUnknownForNewInput('a'), isFalse);
    expect((await attemptRow(old.attempt['attemptId']!))['state'], 'unknown');
  });

  for (final undated in [false, true]) {
    test(
        'distinct verified video cards can detach at the same or unknown sender clock: undated=$undated',
        () async {
      final inventory = CustomerMediaInventory(db);
      final a = await inventory.observe(
          customer: 'a',
          evidenceId: 'frame-a',
          observedAt: start,
          senderAt: undated ? null : start,
          slot: 0,
          region: [.2, .3, .2, .2],
          current: true);
      final firstFile = await File('${root.path}/a.mp4').writeAsBytes([1]);
      final secondFile = await File('${root.path}/b.mp4').writeAsBytes([2]);
      List<CapturedMedia> files(File file) => [
            CapturedMedia(
                type: 'video',
                path: file.path,
                captureSource: 'jd_video_cache'),
            CapturedMedia(
                type: 'image',
                path: file.path,
                captureSource: 'jd_video_frame_1fps')
          ];
      final old =
          await unknown(media: files(firstFile), receipt: a, undated: undated);
      CapturedConversation capture(
              String id, String receipt, File file, DateTime captured) =>
          CapturedConversation(
              stableKey: 'a',
              customerName: 'a',
              customerExternalId: 'a',
              capturedAt: captured,
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: '[video]',
                    sentAt: undated ? null : start,
                    axPath: 'fixture',
                    mediaReceiptId: receipt,
                    media: files(file))
              ]);
      await inventory.persist(capture('q1', a, firstFile, start),
          verifiedAnchor: true);
      final later =
          DateTime.fromMillisecondsSinceEpoch(old.created + 5000, isUtc: true);
      final b = await inventory.observe(
          customer: 'a',
          evidenceId: 'frame-b',
          observedAt: later,
          senderAt: undated ? null : start,
          slot: 1,
          region: [.2, .6, .2, .2],
          current: true);
      await incoming('q2',
          sent: start,
          observedAt: later,
          undated: undated,
          media: files(secondFile),
          receipt: b);
      await inventory.persist(capture('q2', b, secondFile, later),
          verifiedAnchor: true);
      expect(await db.detachUnknownForNewInput('a'), isTrue);
      expect((await attemptRow(old.attempt['attemptId']!))['state'],
          'superseded_unknown');
      expect(await db.hasUndeliveredDraft('a'), isFalse);
    });
  }

  test(
      'late native submitted receipt for detached q1 preserves ready q2 and its cursor',
      () async {
    final old = await unknown();
    await queueNewQuestion(old.created);
    await File(old.attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': old.attempt['attemptId'],
      'customer': 'a',
      'state': 'submitted',
      'timeMs': old.created + 1000
    }));
    await db.recoverDeliveryReceipts();
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        'superseded_submitted');
    expect(await activeBatch(), 'q2');
    expect(await db.isBatchUnanswered('a', 'q2'), isTrue);
    expect(await db.isBatchUnanswered('a', 'q1'), isFalse);
    expect((await db.nextReadyDelivery())!.draft.reply,
        'The newer formal answer.');
    final history = ((await (await db.history).read('a'))!['messages'] as List)
        .whereType<Map>();
    final reply = history.singleWhere(
        (m) => m['delivery_attempt_id'] == old.attempt['attemptId']);
    expect(reply['answered_batch_end_id'], 'q1');
  });

  test('exact observed old receipt binds only q1 despite appearing after q2',
      () async {
    final old = await unknown();
    await queueNewQuestion(old.created);
    final sent =
        DateTime.fromMillisecondsSinceEpoch(old.created + 10000, isUtc: true);
    await db.saveCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: sent.add(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'late-observed',
              direction: 'outgoing',
              body: 'The earlier formal answer.',
              sentAt: sent,
              axPath: 'fixture',
              deliveryConfirmed: true)
        ]));
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        'superseded_accepted');
    expect(await activeBatch(), 'q2');
    expect(await db.isBatchUnanswered('a', 'q2'), isTrue);
    expect(await db.isBatchUnanswered('a', 'q1'), isFalse);
    expect((await db.nextReadyDelivery())!.draft.reply,
        'The newer formal answer.');
    final replies = ((await (await db.history).read('a'))!['messages'] as List)
        .whereType<Map>()
        .where((m) => m['direction'] == 'outgoing')
        .toList();
    expect(replies, hasLength(1));
    expect(replies.single['id'], 'late-observed');
    expect(replies.single['sent_at'], sent.toIso8601String());
    expect(replies.single['source'], 'generated_reply');
    expect(replies.single['delivery_attempt_id'], old.attempt['attemptId']);
    expect(replies.single['answered_batch_end_id'], 'q1');
  });
  test(
      'retired q1 receipt rejected after submission never rebuilds q1 over ready q2',
      () async {
    final old = await unknown();
    await queueNewQuestion(old.created);
    Future<void> receipt(String state) async {
      await File(old.attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': old.attempt['attemptId'],
        'customer': 'a',
        'state': state,
        'timeMs': old.created + 1000
      }));
      await db.recoverDeliveryReceipts();
    }

    await receipt('submitted');
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        'superseded_submitted');
    await receipt('rejected');
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        startsWith('superseded_'));
    expect(await activeBatch(), 'q2');
    expect(await db.isBatchUnanswered('a', 'q2'), isTrue);
    expect((await db.nextReadyDelivery())!.draft.reply,
        'The newer formal answer.');
    expect(await (await db.database).query('delivery_attempts'), hasLength(1));
  });
  test(
      'overlapping retired and current equal replies cannot claim the same observed bubble',
      () async {
    final old = await unknown();
    await incoming('q2',
        sent: DateTime.fromMillisecondsSinceEpoch(old.created + 5000,
            isUtc: true));
    expect(await db.detachUnknownForNewInput('a'), isTrue);
    final reply = _draft('The earlier formal answer.');
    await db.saveDraft((await db.conversations()).single.id, reply,
        expectedMessageId: 'q2');
    final current = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'a', reply: reply.reply, taskId: current.taskId);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'a',
      'state': 'unknown',
      'error': 'send_not_committed',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'a', taskId: current.taskId, error: 'send_not_committed');
    final newRow = await attemptRow(attempt['attemptId']!);
    final sent = DateTime.fromMillisecondsSinceEpoch(
        (newRow['created_at_ms']! as int) + 10000,
        isUtc: true);
    await db.saveCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: sent.add(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'ambiguous-observed',
              direction: 'outgoing',
              body: reply.reply,
              sentAt: sent,
              axPath: 'fixture',
              deliveryConfirmed: true)
        ]));
    expect((await attemptRow(old.attempt['attemptId']!))['state'],
        'superseded_unknown');
    expect((await attemptRow(attempt['attemptId']!))['state'], 'unknown');
    expect(await activeBatch(), 'q2');
    expect(await db.hasUndeliveredDraft('a'), isTrue);
    expect(await db.isBatchUnanswered('a', 'q2'), isTrue);
    final observed = ((await (await db.history).read('a'))!['messages'] as List)
        .whereType<Map>()
        .singleWhere((m) => m['id'] == 'ambiguous-observed');
    expect(observed['delivery_status'], 'ownership_unverified');
    expect(observed['delivery_attempt_id'], isNull);
  });
}
