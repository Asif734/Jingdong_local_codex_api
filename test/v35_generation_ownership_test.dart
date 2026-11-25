import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

import 'helpers/completed_video_fixture.dart';

class _SnapshotRaceDatabase extends CaptureDatabase {
  _SnapshotRaceDatabase({required super.storageRoot});

  Future<void> Function()? afterProcessingSnapshot;

  @override
  Future<List<Map<String, dynamic>>> processingMessages(String customer,
      {Map<String, dynamic>? document, bool includeAnswered = false}) async {
    final messages = await super.processingMessages(customer,
        document: document, includeAnswered: includeAnswered);
    final callback = afterProcessingSnapshot;
    afterProcessingSnapshot = null;
    await callback?.call();
    return messages;
  }
}

AiDraft _answer(String text) => AiDraft(
      reply: text,
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'controlled-fixture',
      usedRecordIds: const [],
      actions: const [],
      attachments: const [],
      rawJson: jsonEncode({
        'reply': text,
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-fixture',
      }),
    );

void main() {
  late Directory root;
  late _SnapshotRaceDatabase db;
  var sequence = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v35_generation_');
    db = _SnapshotRaceDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    sequence = 0;
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> receive(String id, {String customer = 'buyer'}) async {
    final at = DateTime.now().toUtc().add(Duration(milliseconds: sequence++));
    await db.saveCapture(CapturedConversation(
      stableKey: customer,
      customerName: customer,
      customerExternalId: customer,
      automationSessionId: db.currentAutomationSessionId,
      capturedAt: at,
      messages: [
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: 'A specific question $id',
            sentAt: at,
            axPath: 'controlled AX fixture')
      ],
    ));
  }

  Future<String?> begin(String end, {String customer = 'buyer'}) async =>
      db.beginGeneration(
          customer: customer,
          pendingId: (await db.conversation(customer))!.id,
          batchEndMessageId: end);

  Future<void> save(String end, String token,
      {String customer = 'buyer'}) async {
    expect(
        await db.saveDraft(
            (await db.conversation(customer))!.id, _answer('Answer $end'),
            expectedMessageId: end,
            expectedUserId: customer,
            generationToken: token),
        1);
    await db.abandonGeneration(customer, token);
  }

  Future<void> submit(String end, {String customer = 'buyer'}) async {
    final attempt =
        await db.beginDeliveryAttempt(userId: customer, reply: 'Answer $end');
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<List<String>> frozen(String end, {String customer = 'buyer'}) async =>
      (await db.generationMessages(customer, batchEndMessageId: end))
          .where((message) => message['direction'] == 'incoming')
          .map((message) => message['id']! as String)
          .toList();

  // The five production saved0 events had this exact ready/start/send order.
  // The generator must wait for custody of the earlier frozen input to end,
  // rather than freezing it again and discarding a finished new answer.
  for (final pair in const [
    ['50ee', 'e3c57'],
    ['8c131', '27ac9'],
    ['27ac9', '208fc'],
    ['47606', 'bbdf6'],
    ['cba8b', 'a5671'],
  ]) {
    test('recorded scope ${pair[0]} -> ${pair[1]} survives delivery overlap',
        () async {
      final previous = pair.first;
      final next = pair.last;
      await receive(previous);
      final previousToken = (await begin(previous))!;
      await receive(next);
      await save(previous, previousToken);

      expect(await begin(next), isNull,
          reason: 'The unsent answer still owns its frozen input');
      expect(await db.hasUndeliveredDraft('buyer'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', previous), isFalse);
      expect(await db.isMessageFormallyAnswered('buyer', next), isFalse);
      await submit(previous);

      final nextToken = (await begin(next))!;
      expect(await frozen(next), [next]);
      await save(next, nextToken);
      await submit(next);
      expect(await db.hasPendingUnanswered('buyer'), isFalse);
      expect(await db.isMessageFormallyAnswered('buyer', previous), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', next), isTrue);
    });
  }

  for (final state in const [
    'ready',
    'retry',
    'sending',
    'delivery_unknown',
    'committing'
  ]) {
    test('$state draft owns input without blocking another customer', () async {
      await receive('previous');
      final token = (await begin('previous'))!;
      await receive('next');
      await save('previous', token);
      await (await db.database).update(
          'generated_drafts', {'delivery_state': state},
          where: 'user_id=?', whereArgs: ['buyer']);
      expect(await begin('next'), isNull);

      await receive('other-question', customer: 'other');
      expect(await begin('other-question', customer: 'other'), isNotNull);
      expect(await frozen('other-question', customer: 'other'),
          ['other-question']);
      expect(await db.hasPendingUnanswered('buyer'), isTrue);
      expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    });
  }

  test('simultaneous generation claims lease one exact customer scope',
      () async {
    await receive('known');
    final conversation = (await db.conversation('buyer'))!;
    final tokens = await Future.wait(List.generate(
        3,
        (_) => db.beginGeneration(
            customer: 'buyer',
            pendingId: conversation.id,
            batchEndMessageId: 'known')));
    expect(tokens.whereType<String>(), hasLength(1));
    expect(await frozen('known'), ['known']);
  });

  test('delivery commit between history read and lease excludes answered input',
      () async {
    await receive('previous');
    final token = (await begin('previous'))!;
    await receive('next');
    await save('previous', token);
    db.afterProcessingSnapshot = () => submit('previous');

    final nextToken = (await begin('next'))!;
    expect(await frozen('next'), ['next']);
    await save('next', nextToken);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'next'), isFalse);
  });

  test('holding is independent of generation custody and cannot answer work',
      () async {
    await receive('previous');
    final token = (await begin('previous'))!;
    await receive('next');
    await save('previous', token);
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer',
        messageId: 'red-cycle',
        reply: 'Please wait while I check.');
    expect(await begin('next'), isNull);
    expect(await db.isMessageFormallyAnswered('buyer', 'previous'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'next'), isFalse);
    await submit('previous');
    expect(await begin('next'), isNotNull);
    expect(await frozen('next'), ['next']);
  });

  test('old-run generation cannot lease new Start work with a reused queue ID',
      () async {
    await receive('old');
    final oldSession = db.currentAutomationSessionId!;
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await receive('new');
    final conversation = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer',
            pendingId: conversation.id,
            batchEndMessageId: 'new',
            expectedSessionId: oldSession),
        isNull);
    expect(await begin('new'), isNotNull);
    expect(await frozen('new'), ['new']);
    expect(await db.isCurrentSessionMessage('buyer', 'old'), isFalse);
  });

  test('baseline aliases stay history and never consume current active input',
      () async {
    await receive('old-media');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.isSessionBaselineMessage('buyer', 'old-media'), isTrue);
    expect(
        await db.inheritSessionBaseline('buyer',
            ancestorIds: ['old-media'], aliasIds: ['fork', 'original']),
        isTrue);
    await receive('fork');
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    expect(await db.isSessionBaselineMessage('buyer', 'original'), isTrue);

    await receive('current-question');
    expect(
        await db.inheritSessionBaseline('buyer',
            ancestorIds: ['old-media'],
            aliasIds: ['current-question', 'unproven-fork']),
        isFalse);
    expect(await db.isSessionBaselineMessage('buyer', 'current-question'),
        isFalse);
    expect(
        await db.isSessionBaselineMessage('buyer', 'unproven-fork'), isFalse);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(
        await db.inheritSessionBaseline('other',
            ancestorIds: ['old-media'], aliasIds: ['cross-customer-fork']),
        isFalse);
  });

  test('sender order is stable for same-second messages and late old media',
      () async {
    final now = DateTime.now().toUtc();
    Future<void> at(String id, DateTime? sent) =>
        db.saveCapture(CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: now.add(Duration(milliseconds: sequence++)),
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: switch (id) {
                    'second-a' => 'How do I connect the printer by USB?',
                    'second-b' => 'What is the warranty period?',
                    _ => 'Specific question $id',
                  },
                  sentAt: sent,
                  observationTurnKey:
                      'ocr-bubble:${now.millisecondsSinceEpoch}:$id:0',
                  axPath: 'controlled AX fixture')
            ]));
    await at('second-a', now.subtract(const Duration(seconds: 1)));
    await at('second-b', now.subtract(const Duration(seconds: 1)));
    await at('late-earlier', now.subtract(const Duration(minutes: 2)));
    await at('unknown-clock', null);
    final token = (await begin('unknown-clock'))!;
    expect(await frozen('unknown-clock'),
        ['late-earlier', 'second-a', 'second-b', 'unknown-clock']);
    final unknown = (await db.generationMessages('buyer',
            batchEndMessageId: 'unknown-clock'))
        .singleWhere((message) => message['id'] == 'unknown-clock');
    expect(unknown['sent_at'], isNull,
        reason: 'Observation order must not invent a sender clock');
    await save('unknown-clock', token);
    await submit('unknown-clock');
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    await at('even-earlier', now.subtract(const Duration(minutes: 3)));
    expect(await begin('even-earlier'), isNotNull);
    expect(await frozen('even-earlier'), ['even-earlier']);
  });

  test('late older-clock anchor freezes already known unanswered text in order',
      () async {
    await receive('first');
    final lateAt = DateTime.now().toUtc().subtract(const Duration(minutes: 4));
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait.');
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: 'late',
              direction: 'incoming',
              body: 'How long is the printer warranty?',
              sentAt: lateAt,
              axPath: 'controlled AX fixture')
        ]));
    expect(await db.pendingMessageId('buyer'), 'first',
        reason: 'Sender order and discovery order are different boundaries');
    expect(await db.generationAnchorMessageId('buyer'), 'late');
    final token =
        (await begin((await db.generationAnchorMessageId('buyer'))!))!;
    expect(await frozen('late'), ['late', 'first']);
    expect(await db.isMessageFormallyAnswered('buyer', 'first'), isFalse);
    await save('late', token);
    await submit('late');
    expect(await db.isMessageFormallyAnswered('buyer', 'first'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'late'), isTrue);
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
  });

  test('proven card forks generate once and formal confirmation covers aliases',
      () async {
    final at = DateTime.now().toUtc();
    for (final receipt in ['base', 'fork']) {
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: 'media-pending:$receipt',
                direction: 'incoming',
                body: '[Customer sent media; acquisition pending.]',
                sentAt: at,
                axPath: 'owned-card',
                mediaReceiptId: receipt)
          ]));
    }
    await (await db.history).consolidateProvenMediaAliases('buyer',
        canonicalMessageId: 'media-pending:base',
        messageAliases: ['media-pending:base', 'media-pending:fork'],
        receiptAliases: ['base', 'fork']);
    // Production consolidation follows this persisted, strictly proven
    // inventory link. UI counts must use that DB proof without reading files.
    final completed =
        await completedVideoFixture(root, name: 'same-card-completed');
    for (final receipt in ['base', 'fork']) {
      await (await db.database).insert('customer_media_items', {
        'item_id': receipt,
        'customer': 'buyer',
        'sender_ms': at.millisecondsSinceEpoch,
        'slot': 0,
        'kind': 'video',
        'state': receipt == 'base' ? 'ready' : 'superseded',
        'first_seen_ms': at.millisecondsSinceEpoch,
        'last_seen_ms': at.millisecondsSinceEpoch,
        'message_id': 'media-pending:$receipt',
        'canonical_id': receipt == 'base' ? null : 'base',
        'media_json': jsonEncode(completed.map((m) => m.toJson()).toList()),
        'aliases_json': jsonEncode(['media-pending:$receipt']),
      });
    }
    await admitFixtureMedia(db,
        receiptId: 'base',
        messageId: 'media-pending:base',
        receivedAt: at,
        senderAt: at);
    await db.repairSessionPendingWork('buyer');
    await db.ensurePendingForUnanswered('buyer');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(await db.generationAnchorMessageId('buyer'), 'media-pending:base');
    final token =
        (await begin((await db.generationAnchorMessageId('buyer'))!))!;
    expect(await frozen('media-pending:base'), ['media-pending:base']);
    await save('media-pending:base', token);
    final draft = (await (await db.database).query('generated_drafts')).single;
    expect(
        (jsonDecode(draft['raw_json']! as String)
            as Map)['service_message_ids'],
        ['media-pending:base']);
    await submit('media-pending:base');
    expect(await db.isMessageFormallyAnswered('buyer', 'media-pending:base'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'media-pending:fork'),
        isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test('UI pending count includes unsent drafts and unanswered acquisition',
      () async {
    await receive('first');
    final token = (await begin('first'))!;
    await receive('second');
    await save('first', token);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait.');
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    await submit('first');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    final secondToken = (await begin('second'))!;
    await save('second', secondToken);
    await submit('second');
    expect(await db.unansweredWorkCounts(), isEmpty);

    final inventory = CustomerMediaInventory(db);
    final at = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'owned-video-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final media = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'media-pending:$receipt',
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              sentAt: at,
              axPath: 'owned-card',
              mediaReceiptId: receipt)
        ]);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: 'media-pending:$receipt',
        receivedAt: at,
        senderAt: at);
    await db.saveCapture(media);
    await inventory.persist(media);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1},
        reason: 'Pending reply and acquisition of one card are one duty');
    await receive('receipt-question');
    final receiptToken = (await begin('receipt-question'))!;
    await save('receipt-question', receiptToken);
    await submit('receipt-question');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 1},
        reason: 'A receipt reply has not acquired or answered video content');
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.unansweredWorkCounts(), isEmpty,
        reason: 'Start does not revive old acquisition or business');
  });

  test('unbound observations do not invent business messages for any customer',
      () async {
    final sql = await db.database;
    for (final row in const [
      ['a', 'same-card', 'buyer'],
      ['b', 'same-card', 'buyer'],
      ['c', 'another-card', 'buyer'],
      ['d', 'same-card', 'other'],
    ]) {
      await sql.insert('media_capture_audit', {
        'observation_id': row[0],
        'evidence_id': 'frame-${row[0]}',
        'customer': row[2],
        'state': 'unbound',
        'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        'details': jsonEncode({
          'observationId': row[0],
          'observationGroupId': row[1],
          'customer': row[2],
          'automationSessionId': db.currentAutomationSessionId,
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
        })
      });
    }
    expect(await db.unansweredWorkCounts(), isEmpty);
    await sql.update('media_capture_audit', {'state': 'video_frames_saved'},
        where: 'observation_id IN (?,?)', whereArgs: ['a', 'b']);
    expect(await db.unansweredWorkCounts(), isEmpty);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.unansweredWorkCounts(), isEmpty);
  });
  test('UI counts never load customer JSON or start capture work', () async {
    await receive('current-question');
    var historyReads = 0;
    db.afterProcessingSnapshot = () async {
      historyReads++;
      throw StateError('UI must not load history or start retry timers');
    };
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(historyReads, 0);
    db.afterProcessingSnapshot = null;
  });
}
