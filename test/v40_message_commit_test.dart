import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/runtime/delivery_context_guard.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

AiDraft _draft(String reply,
        {String purpose = 'substantive',
        Map<String, String> dependencies = const {},
        Map<String, String> descriptions = const {}}) =>
    AiDraft.fromJson({
      'reply': reply,
      'reply_purpose': purpose,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-v40-commit',
      'auto_send_allowed': false,
      'reply_media_dependency_keys': dependencies,
      // A legacy global version deliberately differs: modern work uses only
      // its explicit dependency snapshot at save and native insertion.
      'media_context_revision': -1,
      'image_descriptions': [
        for (final entry in descriptions.entries)
          {'path': entry.key, 'description': entry.value}
      ],
    }, mediaBaseUrl: Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  var sequence = 0;
  const customer = 'buyer';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v40_commit_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    await db.beginAutomationSession(
        startedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)));
    sequence = 0;
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> text(String id, String body) async {
    final at = DateTime.now().toUtc();
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
              body: body,
              sender: customer,
              sentAt: at,
              axPath: 'controlled exact customer')
        ]));
  }

  Future<void> completeVideo(String id, String receipt) async {
    final media =
        await completedVideoFixture(root, name: 'video-${sequence++}');
    final at = DateTime.now().toUtc();
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[Customer sent a video]',
              sender: customer,
              axPath: 'same admitted video bubble',
              mediaReceiptId: receipt,
              media: media)
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
  }

  Future<({String id, String receipt})> video({bool ready = false}) async {
    final at = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'immutable-${sequence++}',
        observedAt: at,
        senderAt: at,
        slot: sequence,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final id = 'media-pending:$receipt';
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: at, senderAt: at);
    if (ready) await completeVideo(id, receipt);
    return (id: id, receipt: receipt);
  }

  Future<String> begin(String id) async => (await db.beginGeneration(
      customer: customer,
      pendingId: (await db.conversation(customer))!.id,
      batchEndMessageId: id))!;

  Future<String> injectLegacyIncompleteReferenceLease(String id) async {
    final pending = (await db.conversation(customer))!;
    expect(
        await db.beginGeneration(
            customer: customer, pendingId: pending.id, batchEndMessageId: id),
        isNull);
    expect(await db.generationDue(customer), isFalse,
        reason: 'Known required media must stop normal flow before CLI');
    final sql = await db.database;
    expect(await sql.query('automation_reply_inputs'), isEmpty);
    final work = (await sql.query('automation_session_messages',
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [db.currentAutomationSessionId, customer, id]))
        .single;
    final document = (await (await db.history).read(customer))!;
    final message = (document['messages'] as List)
        .cast<Map>()
        .singleWhere((m) => m['id'] == id);
    final token = 'fault-injected-legacy-incomplete-reference:$id';
    // Preserve the defense-in-depth save test for a lease from an older build
    // or a model result already in flight. Production has no bypass switch.
    await sql.transaction((txn) async {
      await txn.update(
          'pending_customers',
          {
            'generation_token': token,
            'generation_attempts': 1,
          },
          where: 'id=? AND user_id=?',
          whereArgs: [pending.id, customer]);
      await txn.insert('automation_reply_inputs', {
        'session_id': db.currentAutomationSessionId,
        'user_id': customer,
        'owner_id': token,
        'message_id': id,
        'message_revision': work['work_revision'],
        'message_json': jsonEncode({
          ...message,
          'reply_material_input_key':
              ConversationFileStore.materialInputKey(message),
        }),
      });
    });
    return token;
  }

  Future<int> save(String id, String token, AiDraft draft) async {
    final prepared = await db.prepareAutomaticDraft(customer, draft);
    return db.saveDraft((await db.conversation(customer))!.id, prepared,
        expectedMessageId: id,
        expectedUserId: customer,
        generationToken: token);
  }

  Future<void> submit(String reply) async {
    final attempt =
        await db.beginDeliveryAttempt(userId: customer, reply: reply);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'state': 'submitted',
      'sendClickedAtMs': now,
      'timeMs': now,
    }));
    await db.recoverDeliveryReceipts();
  }

  test('recorded v39 history2/ledger1 freezes one consistent version',
      () async {
    final recorded = jsonDecode(await File(
            'test/fixtures/v40_message_concurrency/recorded-video-lease.json')
        .readAsString()) as Map;
    final first = recorded['first'] as Map;
    final second = recorded['second'] as Map;
    expect(first['message_revision'], 1);
    expect((first['message_json'] as Map)['service_evidence_revision'], 2);
    expect(second['message_revision'], 2);

    final card = await video();
    final store = await db.history;
    final document = (await store.read(customer))!;
    final message = Map<String, dynamic>.from(first['message_json'] as Map)
      ..['id'] = card.id
      ..['sender'] = customer
      ..['captured_at'] = DateTime.now().toUtc().toIso8601String()
      ..['sent_at'] = DateTime.now().toUtc().toIso8601String()
      ..['media_receipt_id'] = card.receipt
      ..['live_observed_session_ids'] = [db.currentAutomationSessionId];
    document['messages'] = [message];
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
        .writeAsString(jsonEncode(document));
    final sql = await db.database;
    await sql.update(
        'automation_session_messages', {'work_revision': 1, 'input_key': null},
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [db.currentAutomationSessionId, customer, card.id]);
    await sql.update('customer_media_items',
        {'state': 'ready', 'media_json': jsonEncode(message['media'])},
        where: 'customer=? AND item_id=?', whereArgs: [customer, card.receipt]);
    await db.ensurePendingForUnanswered(customer);

    final token = await begin(card.id);
    final frozen = (await db.generationMessages(customer))
        .singleWhere((m) => m['direction'] == 'incoming');
    expect(frozen['service_evidence_revision'], 2);
    expect(frozen['reply_work_revision'], 2);
    final inputs = await sql.query('automation_reply_inputs',
        where: 'owner_id=?', whereArgs: [token]);
    expect(inputs.single['message_revision'], 2);
    final images = (message['media'] as List)
        .whereType<Map>()
        .where((m) => m['type'] == 'image');
    final descriptions = {
      for (final image in images)
        image['path']! as String: 'A fully analysed paper-feed view.'
    };
    expect(descriptions, hasLength(9));
    await store.updateMediaDescriptions(customer, descriptions);
    await db.repairSessionPendingWork(customer);
    expect(
        await db.generationInputVersionsCurrent(customer,
            generationToken: token),
        isTrue);
    expect(
        await db.generationInputsAnalysisReady(customer,
            generationToken: token),
        isTrue);
    final keys = await inventory.analyzableEvidenceKeys(customer);
    const reply = 'Load single sheets through the front tray.';
    final pendingId = (await db.conversation(customer))!.id;
    expect(
        await save(
            card.id,
            token,
            _draft(reply,
                dependencies: {card.id: keys[card.id]!},
                descriptions: descriptions)),
        1);
    await db.abandonGeneration(customer, token);
    expect(
        await db.beginGeneration(
            customer: customer,
            pendingId: pendingId,
            batchEndMessageId: card.id),
        isNull);
    await submit(reply);
    expect(await db.isMessageFormallyAnswered(customer, card.id), isTrue);
    expect(await db.hasPendingUnanswered(customer), isFalse);
  });

  test('text media wait wakes only for its exact dependency', () async {
    final wanted = await video();
    await text('question', 'Please explain the problem in my attachment.');
    final token = await begin('question');
    expect(
        await save(
            'question',
            token,
            _draft('The attachment is still loading.',
                purpose: 'media_status', dependencies: {wanted.id: ''})),
        1);
    await db.abandonGeneration(customer, token);
    expect(await db.awaitingMediaMessageIds(customer), contains('question'));
    await video(ready: true);
    expect(await db.awaitingMediaMessageIds(customer), contains('question'),
        reason: 'An unrelated original must not wake this waiting question');
    await completeVideo(wanted.id, wanted.receipt);
    expect(await db.awaitingMediaMessageIds(customer),
        isNot(contains('question')));
    expect(await begin('question'), isNotEmpty);
    expect(await db.isMessageFormallyAnswered(customer, 'question'), isFalse);
  });

  test(
      'a substantive label cannot formally answer a reference before its actual media is ready',
      () async {
    final owned = await video();
    await text(
        'question', 'Please explain the paper problem shown in my video.');
    final token = await injectLegacyIncompleteReferenceLease('question');
    final premature =
        _draft('The video shows a paper jam.', dependencies: {owned.id: ''});
    final prepared = await db.prepareAutomaticDraft(customer, premature);
    final raw = jsonDecode(prepared.rawJson) as Map;
    expect(raw['reply_purpose'], 'media_status');
    expect(raw['formal_response_message_ids'], isEmpty);
    expect(await save('question', token, premature), 1);
    await db.abandonGeneration(customer, token);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
    expect(await db.isMessageFormallyAnswered(customer, 'question'), isFalse);
    expect(await db.awaitingMediaMessageIds(customer), contains('question'));
    await completeVideo(owned.id, owned.receipt);
    final retry = await begin('question');
    final key = (await inventory.analyzableEvidenceKeys(customer))[owned.id]!;
    const reply =
        'The complete video shows the front paper tray and its guide.';
    expect(
        await save(
            'question', retry, _draft(reply, dependencies: {owned.id: key})),
        1);
    await db.abandonGeneration(customer, retry);
    await submit(reply);
    expect(await db.isMessageFormallyAnswered(customer, 'question'), isTrue);
    expect(await db.isMessageFormallyAnswered(customer, owned.id), isTrue);
  });

  test(
      'a receipt fact can answer text while its separate actual media remains pending',
      () async {
    final owned = await video();
    await text('receipt-question', 'Did you receive my video?');
    final token = await begin('receipt-question');
    const reply = 'Yes, I received your video.';
    final draft =
        _draft(reply, purpose: 'receipt', dependencies: {owned.id: ''});
    expect(await save('receipt-question', token, draft), 1);
    await db.abandonGeneration(customer, token);
    expect((await db.nextReadyDelivery())?.userId, customer);
    await submit(reply);
    expect(await db.isMessageFormallyAnswered(customer, 'receipt-question'),
        isTrue);
    expect(await db.isMessageFormallyAnswered(customer, owned.id), isFalse);
    expect(await db.hasPendingUnanswered(customer), isTrue);
  });

  test(
      'wait records the actual selected dependency rather than the entry snapshot',
      () async {
    final wanted = await video();
    final complete = await completedVideoFixture(root, name: 'pending-speech');
    final media = complete
        .map((item) => item.type != 'video'
            ? item
            : CapturedMedia(
                type: 'video',
                path: item.path,
                captureSource: item.captureSource,
                description: '[Video audio: analysis pending]'))
        .toList();
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: wanted.id,
              direction: 'incoming',
              body: '[Customer sent a video]',
              axPath: 'same admitted bubble',
              mediaReceiptId: wanted.receipt,
              media: media)
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    final actual =
        (await inventory.analyzableEvidenceKeys(customer))[wanted.id]!;
    expect(await inventory.analysisReadyMessageIds(customer),
        isNot(contains(wanted.id)));
    await text('question', 'Please explain this video.');
    final token = await injectLegacyIncompleteReferenceLease('question');
    final raw = jsonDecode(_draft('The video analysis is still loading.',
        purpose: 'media_status',
        dependencies: {wanted.id: actual}).rawJson) as Map<String, dynamic>;
    raw['reply_evidence_key_snapshot'] = {wanted.id: 'obsolete-entry-snapshot'};
    expect(
        await save(
            'question', token, AiDraft.fromJson(raw, mediaBaseUrl: Uri())),
        1);
    await db.abandonGeneration(customer, token);
    final wait = (await (await db.database).query('automation_message_waits',
            where: 'message_id=?', whereArgs: ['question']))
        .single;
    expect(jsonDecode(wait['content_key']! as String), {wanted.id: actual});
    expect(await db.awaitingMediaMessageIds(customer), contains('question'));
    final sql = await db.database;
    final textVersion = (await sql.query('automation_session_messages',
            where: 'message_id=?', whereArgs: ['question']))
        .single['work_revision'];
    final videoPath = media.singleWhere((item) => item.type == 'video').path;
    await (await db.history).updateMediaDescriptions(
        customer, {videoPath: '[Video audio: no audio stream]'});
    await inventory.updateProvenVideoDescription(
        customer, videoPath, '[Video audio: no audio stream]',
        messageId: wanted.id, receiptId: wanted.receipt);
    expect(
        (await inventory.analyzableEvidenceKeys(customer))[wanted.id], actual,
        reason:
            'No-audio completion changes readiness, not the frame/transcript key');
    expect(
        await inventory.analysisReadyMessageIds(customer), contains(wanted.id));
    expect(
        (await sql.query('automation_session_messages',
                where: 'message_id=?', whereArgs: ['question']))
            .single['work_revision'],
        textVersion);
    expect(
        await db.awaitingMediaMessageIds(customer), isNot(contains('question')),
        reason: 'The exact dependency becoming ready must wake unchanged text');
    expect(await begin('question'), isNotEmpty);
  });

  for (final purpose in ['media_status', 'review_status']) {
    test('$purpose cannot permanently park a dependency already completed',
        () async {
      final owned = await video(ready: true);
      await text('question', 'Please explain this video.');
      final token = await begin('question');
      final key = (await inventory.analyzableEvidenceKeys(customer))[owned.id]!;
      expect(
          await save(
              'question',
              token,
              _draft(
                  purpose == 'media_status'
                      ? 'The video is still loading.'
                      : 'Please wait while I check.',
                  purpose: purpose,
                  dependencies: {owned.id: key})),
          1);
      await db.abandonGeneration(customer, token);
      expect(
          await (await db.database).query('automation_message_waits'), isEmpty);
      expect(await db.hasUndeliveredDraft(customer), isFalse);
      expect(await db.generationDue(customer), isFalse);
      expect(await db.hasPendingUnanswered(customer), isTrue);
      expect(await db.isMessageFormallyAnswered(customer, owned.id), isFalse);
      expect(await db.isMessageFormallyAnswered(customer, 'question'), isFalse);
      await (await db.database).update(
          'pending_customers', {'generation_retry_at_ms': 0},
          where: 'user_id=?', whereArgs: [customer]);
      final retry = await begin('question');
      const reply = 'The video shows the sheet entering the front paper tray.';
      expect(
          await save(
              'question', retry, _draft(reply, dependencies: {owned.id: key})),
          1);
      await db.abandonGeneration(customer, retry);
      await submit(reply);
      expect(await db.isMessageFormallyAnswered(customer, owned.id), isTrue);
      expect(await db.isMessageFormallyAnswered(customer, 'question'), isTrue);
    });
  }

  for (final purpose in ['media_status', 'review_status']) {
    test('$purpose without a dependency keeps real work retryable', () async {
      await text('question', 'Why does the printer stop after one sheet?');
      final token = await begin('question');
      expect(
          await save('question', token,
              _draft('Please wait while I check.', purpose: purpose)),
          1);
      await db.abandonGeneration(customer, token);
      expect(await db.hasPendingUnanswered(customer), isTrue);
      expect(await db.isMessageFormallyAnswered(customer, 'question'), isFalse);
      expect(await db.hasUndeliveredDraft(customer), isFalse);
      expect(
          await (await db.database).query('automation_message_waits'), isEmpty);
      expect(await db.generationDue(customer), isFalse,
          reason: 'Bad status output cannot cause a tight generation loop');
      await (await db.database).update(
          'pending_customers', {'generation_retry_at_ms': 0},
          where: 'user_id=?', whereArgs: [customer]);
      final retry = await begin('question');
      const reply = 'Select the correct paper source before printing.';
      expect(await save('question', retry, _draft(reply)), 1);
      await db.abandonGeneration(customer, retry);
      await submit(reply);
      expect(await db.isMessageFormallyAnswered(customer, 'question'), isTrue);
    });
  }

  test('factual text coverage is not determined by a question whitelist',
      () async {
    await text('one', 'Tell me what the first view showed.');
    await text('two', 'And what did the final view show?');
    final token = await begin('two');
    const reply =
        'The first view showed the front tray; the last showed the rear feed.';
    final prepared = await db.prepareAutomaticDraft(
        customer, _draft(reply, purpose: 'receipt'));
    final raw = jsonDecode(prepared.rawJson) as Map;
    expect(raw['formal_response_message_ids'], unorderedEquals(['one', 'two']));
    expect(await save('two', token, _draft(reply, purpose: 'receipt')), 1);
    await db.abandonGeneration(customer, token);
    await submit(reply);
    final rows = await (await db.database).query('automation_session_messages');
    expect(rows.every((row) => row['response_state'] == 'answered'), isTrue);
    expect(rows.map((row) => row['responded_at_ms']).toSet(), hasLength(1));
  });

  test('a new real input clears status backoff; a reread cannot clear it',
      () async {
    const question = 'Why does the paper stop?';
    await text('old-question', question);
    final token = await begin('old-question');
    expect(
        await save('old-question', token,
            _draft('Please wait while I check.', purpose: 'review_status')),
        1);
    await db.abandonGeneration(customer, token);
    expect(await db.generationDue(customer), isFalse);
    final before =
        (await (await db.database).query('pending_customers')).single;
    await text('old-question', question);
    await db.repairSessionPendingWork(customer);
    final reread =
        (await (await db.database).query('pending_customers')).single;
    expect(reread['generation_retry_at_ms'], before['generation_retry_at_ms']);
    expect(await db.generationDue(customer), isFalse);
    await text('new-question', 'Which paper setting should I use?');
    expect(await db.generationDue(customer), isTrue);
    final next = await begin('new-question');
    final frozen = (await db.generationMessages(customer))
        .where((m) => m['direction'] == 'incoming')
        .map((m) => m['id']);
    expect(frozen, unorderedEquals(['old-question', 'new-question']));
    expect(
        await db.generationInputVersionsCurrent(customer,
            generationToken: next),
        isTrue);
  });

  test(
      'unrelated media cannot retire a ready answer or invalidate its native guard',
      () async {
    final owned = await video(ready: true);
    final token = await begin(owned.id);
    final key = (await inventory.analyzableEvidenceKeys(customer))[owned.id]!;
    final draft = _draft('Use the front tray.', dependencies: {owned.id: key});
    expect(await save(owned.id, token, draft), 1);
    await db.abandonGeneration(customer, token);
    await video(ready: true);
    expect(await db.mediaContextCurrent(customer, draft), isTrue);
    expect(await db.retireStaleMediaDraft(customer), isFalse);
    final attempt =
        await db.beginDeliveryAttempt(userId: customer, reply: draft.reply);
    expect(attempt['mediaRevision'], '1');
    final expected =
        DeliveryContextGuard.scopedFile(root, customer, attempt['attemptId']!);
    expect(attempt['mediaGuardPath'], expected.path);
    await video(ready: true);
    expect((jsonDecode(await expected.readAsString()) as Map)['revision'], 1);
    expect(await db.hasUndeliveredDraft(customer), isTrue);
  });

  test('changed actual input rejects its old frozen answer', () async {
    final owned = await video(ready: true);
    final token = await begin(owned.id);
    final store = await db.history;
    final doc = (await store.read(customer))!;
    final message = (doc['messages'] as List).cast<Map>().single;
    final frame = await File('test/fixtures/v35_media/unbound-video-cover.jpg')
        .copy('${root.path}/extra-frame.jpg');
    final media = [
      ...(message['media'] as List)
          .cast<Map>()
          .map((m) => CapturedMedia.fromMap(m)),
      CapturedMedia(
          type: 'image',
          path: frame.path,
          captureSource: 'jd_video_frame_1fps',
          originalName: 'video_sample_extra.jpg'),
    ];
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: owned.id,
              direction: 'incoming',
              body: '[Customer sent a video]',
              axPath: 'same admitted bubble',
              mediaReceiptId: owned.receipt,
              media: media)
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    expect(
        await db.generationInputVersionsCurrent(customer,
            generationToken: token),
        isFalse);
    expect(await save(owned.id, token, _draft('An outdated answer.')), 0);
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.isMessageFormallyAnswered(customer, owned.id), isFalse);
  });

  test(
      'ready draft waits for a same-key kind recheck without blocking another customer',
      () async {
    final at = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'owned-still-image',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, 'image');
    final id = 'media-pending:$receipt';
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: at, senderAt: at);
    final image = await File('test/fixtures/v35_media/unbound-video-cover.jpg')
        .copy('${root.path}/confirmed-still.jpg');
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[Customer sent an image]',
              axPath: 'same admitted image',
              mediaReceiptId: receipt,
              media: [
                CapturedMedia(
                    type: 'image',
                    path: image.path,
                    captureSource: 'jd_image_cache')
              ])
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    final key = (await inventory.analyzableEvidenceKeys(customer))[id]!;
    final token = await begin(id);
    const reply = 'The photo shows the front paper guide.';
    expect(await save(id, token, _draft(reply, dependencies: {id: key})), 1);
    await db.abandonGeneration(customer, token);
    final sql = await db.database;
    final originalDraft = (await sql.query('generated_drafts',
            where: 'user_id=?', whereArgs: [customer]))
        .single;
    expect(
        await inventory.markMediaTypeVerificationPending(customer,
            messageId: id, receiptId: receipt, imagePath: image.path),
        isTrue);
    expect((await inventory.analyzableEvidenceKeys(customer))[id], key);
    expect(await db.retireStaleMediaDraft(customer), isFalse);
    expect(await db.nextReadyDelivery().timeout(const Duration(seconds: 2)),
        isNull);
    await expectLater(
        db.beginDeliveryAttempt(userId: customer, reply: reply),
        throwsA(isA<StateError>().having((error) => error.message, 'stage',
            'reply_media_inputs_not_ready_before_insertion')));

    const other = 'another-customer';
    await db.saveCapture(CapturedConversation(
        stableKey: other,
        customerName: other,
        customerExternalId: other,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: 'other-question',
              direction: 'incoming',
              body: 'Which paper size should I use?',
              axPath: 'other exact AX customer')
        ]));
    final pending = (await db.conversation(other))!;
    final otherToken = (await db.beginGeneration(
        customer: other,
        pendingId: pending.id,
        batchEndMessageId: 'other-question'))!;
    const otherReply = 'Select the paper size matching your sheet.';
    final prepared = await db.prepareAutomaticDraft(other, _draft(otherReply));
    expect(
        await db.saveDraft(pending.id, prepared,
            expectedUserId: other,
            expectedMessageId: 'other-question',
            generationToken: otherToken),
        1);
    await db.abandonGeneration(other, otherToken);
    final available =
        await db.nextReadyDelivery().timeout(const Duration(seconds: 2));
    expect(available?.userId, other);
    final attempt =
        await db.beginDeliveryAttempt(userId: other, reply: otherReply);
    final clicked = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': other,
      'state': 'submitted',
      'sendClickedAtMs': clicked,
      'timeMs': clicked,
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered(other, 'other-question'), isTrue);
    expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
    expect(
        await inventory.resolveMediaTypeVerification(customer,
            receiptId: receipt,
            nativeKind: 'image',
            captureSource: 'jd-image-cache',
            playbackOverlayDetected: false,
            hasImageBytes: true),
        isTrue);
    expect((await inventory.analyzableEvidenceKeys(customer))[id], key);
    final restored = (await sql.query('generated_drafts',
            where: 'user_id=?', whereArgs: [customer]))
        .single;
    expect(restored['task_id'], originalDraft['task_id']);
    expect(restored['reply'], originalDraft['reply']);
    expect((await db.nextReadyDelivery())?.taskId, originalDraft['task_id']);
    await submit(reply);
    expect(await db.isMessageFormallyAnswered(customer, id), isTrue);
  });

  test('derived descriptions and video cover roles do not change actual input',
      () async {
    final owned = await video(ready: true);
    final token = await begin(owned.id);
    final store = await db.history;
    final before = (await store.read(customer))!;
    final original = (before['messages'] as List).cast<Map>().single;
    final image = (original['media'] as List)
        .cast<Map>()
        .firstWhere((m) => m['type'] == 'image');
    final oldRevision = original['service_evidence_revision'];
    await store.updateMediaDescriptions(customer, {
      image['path']! as String:
          'The fully analysed image shows the paper guide.'
    });
    final after = (await store.read(customer))!;
    final updated = (after['messages'] as List).cast<Map>().single;
    expect(updated['service_evidence_revision'], oldRevision);
    final sameInput = jsonDecode(jsonEncode(updated)) as Map;
    (sameInput['media'] as List)
        .cast<Map>()
        .firstWhere((m) => m['type'] == 'image')['media_roles'] = [
      'first_frame',
      'video_cover'
    ];
    (sameInput['media'] as List).add({
      'type': 'image',
      'path': '/another/crop.jpg',
      'capture_source': 'jd_video_cover',
      'description': 'Another crop of the same video card.'
    });
    expect(ConversationFileStore.materialInputKey(sameInput),
        ConversationFileStore.materialInputKey(updated));
    await db.repairSessionPendingWork(customer);
    expect(
        await db.generationInputVersionsCurrent(customer,
            generationToken: token),
        isTrue);
  });

  test('new frame before its older raw frame keeps one receipt and one answer',
      () async {
    final newer = DateTime.now().toUtc();
    final older = newer.subtract(const Duration(milliseconds: 300));
    CapturedConversation frame(DateTime capturedAt) => CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: capturedAt,
            messages: [
              CapturedMessage(
                  stableId: 'same-real-bubble',
                  direction: 'incoming',
                  body: 'Why is the paper not feeding?',
                  sender: customer,
                  sentAt: older,
                  axPath: 'same proved bubble')
            ]);
    await db.saveCapture(frame(newer));
    await db.observePlatformResponse(customer,
        red: true, observedAt: newer, startedAt: older);
    final sql = await db.database;
    final first = (await sql.query('automation_session_messages')).single;
    final before = await db.platformResponseCycle(customer);
    await db.saveCapture(frame(older), isCurrentViewport: false);
    await db.repairSessionPendingWork(customer);
    final rows = await sql.query('automation_session_messages');
    expect(rows, hasLength(1));
    expect(rows.single['activated_at_ms'], first['activated_at_ms']);
    final document = (await (await db.history).read(customer))!;
    final incoming = (document['messages'] as List).cast<Map>().single;
    expect(incoming['captured_at'], newer.toIso8601String());
    final after = await db.platformResponseCycle(customer);
    expect(after?['started_at_ms'], before?['started_at_ms']);
    expect(after?['cycle_key'], before?['cycle_key']);
    final token = await begin('same-real-bubble');
    const reply =
        'Check that the selected paper source matches the loaded tray.';
    expect(await save('same-real-bubble', token, _draft(reply)), 1);
    await db.abandonGeneration(customer, token);
    await submit(reply);
    await db.saveCapture(frame(older), isCurrentViewport: false);
    await db.repairSessionPendingWork(customer);
    expect(await sql.query('automation_session_messages'), hasLength(1));
    expect(await db.hasPendingUnanswered(customer), isFalse);
    expect(await db.hasUndeliveredDraft(customer), isFalse);
  });
}
