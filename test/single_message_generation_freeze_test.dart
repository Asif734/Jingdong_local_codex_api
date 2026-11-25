import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'junxi112233';
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime start;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_single_message_freeze_');
    db = HeavyWorkBlockedDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 60000,
        isUtc: true);
    session = await db.beginAutomationSession(startedAt: start);
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

  Future<String> text(String body, int second, {String? dependency}) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(
        capture(CapturedMessage(
            stableId: 'text-$second',
            direction: 'incoming',
            sender: buyer,
            sentAt: at,
            body: body,
            axPath: 'exact-current-customer',
            captureEvidenceId: 'text-frame-$second')),
        mediaInputDependencies: dependency == null
            ? const {}
            : {
                'text-$second': {dependency}
              },
        dependencyEvidenceId: dependency == null ? null : 'text-frame-$second');
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<Map> work(String id) async =>
      (await (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, buyer, id]))
          .single;

  AiDraft answer(String reply, {Map<String, String> dependencies = const {}}) =>
      AiDraft.fromJson({
        'reply': reply,
        'decision': 'draft',
        'reply_purpose': 'substantive',
        'confidence': 1,
        'risk_level': 'low',
        'auto_send_allowed': true,
        'model': 'controlled-v62-text-timeline',
        'reply_media_dependency_keys': dependencies,
      }, mediaBaseUrl: Uri());

  Future<AutomaticDraftSaveResult> save(
          String id, String token, AiDraft draft) async =>
      db.saveAutomaticDraft((await db.conversation(buyer))!.id,
          await db.prepareAutomaticDraft(buyer, draft),
          expectedMessageId: id, expectedUserId: buyer, generationToken: token);

  Future<void> submit() async {
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: delivery.draft.reply, taskId: delivery.taskId!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'timeMs': now,
      'sendClickedAtMs': now,
    }));
    await db.recoverDeliveryReceipts();
    await db.abandonGeneration(buyer, delivery.taskId!);
  }

  test(
      'single message claim keeps oldest frozen body across OCR, retry and restart',
      () async {
    final first = await text('这是你们已签收了的', 1);
    final second = await text('上一个客服给我说没有查到这个单子', 2);
    final pending = (await db.conversation(buyer))!.id;
    final claim = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: pending,
        batchEndMessageId: second,
        expectedSessionId: session,
        singleMessage: true))!;
    expect(claim.batchEndMessageId, first);
    final revision = (await work(first))['work_revision'];
    await text('这是你们已签收了', 1);
    final third = await text('请查一下', 3);
    expect((await work(first))['work_revision'], revision);
    expect(
        await db.generationInputVersionsCurrent(buyer,
            generationToken: claim.token),
        isTrue);
    final snapshot = (await db.refreezeGenerationBeforeSubmit(
        customer: buyer,
        pendingId: pending,
        generationToken: claim.token,
        batchEndMessageId: second,
        expectedSessionId: session,
        singleMessage: true))!;
    expect(snapshot.token, claim.token);
    expect(snapshot.batchEndMessageId, first);
    var incoming = (await db.generationMessages(buyer))
        .where((m) => m['direction'] == 'incoming')
        .toList();
    expect(incoming.map((m) => m['id']), [first]);
    expect(incoming.single['body'], '这是你们已签收了的');
    expect(
        (await save(first, claim.token, answer('请提供这个快递的单号，我帮您核实签收记录。')))
            .queued,
        isTrue);
    await submit();
    expect(await db.isMessageFormallyAnswered(buyer, first), isTrue);
    expect((await work(second))['response_state'], 'pending');
    expect((await work(third))['response_state'], 'pending');
    final retry = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: third,
        singleMessage: true))!;
    expect(retry.batchEndMessageId, second);
    await db.abandonGeneration(buyer, retry.token);
    await db.close();
    db = HeavyWorkBlockedDatabase(storageRoot: root);
    await db.database;
    await text('后来的识别结果', 2);
    final history = (await (await db.history).read(buyer))!;
    expect(
        (history['messages'] as List)
            .whereType<Map>()
            .singleWhere((m) => m['id'] == second)['body'],
        '上一个客服给我说没有查到这个单子');
  });
  test('frozen text cannot change type through a late native media promotion',
      () async {
    final id = await text('这是你们已签收了的', 1);
    final token = (await db.beginGeneration(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: id,
        singleMessage: true))!;
    final changed = await (await db.history).promoteMedia(
        buyer,
        id,
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            sender: buyer,
            axPath: 'exact-customer',
            sentAt: start.add(const Duration(seconds: 1)),
            body: '[Customer sent an image.]',
            media: [CapturedMedia(type: 'image', path: '/late-cache.png')]));
    expect(changed, isFalse);
    expect(
        await db.generationInputVersionsCurrent(buyer, generationToken: token),
        isTrue);
    expect(
        (await db.generationMessages(buyer)).last['reply_input_kind'], 'text');
  });

  test('single message mode leaves incomplete media available for acquisition',
      () async {
    final at = start.add(const Duration(seconds: 1));
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: 'pending-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    final media = await db.admitMediaMessage(buyer,
        receiptId: receipt,
        evidenceId: 'pending-frame',
        occurrenceKey: 'pending-media',
        receivedAt: at,
        senderAt: at);
    final id = await text('请查一下单号', 2);
    final claim = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: id,
        singleMessage: true))!;
    expect(claim.batchEndMessageId, id);
    final document = (await (await db.history).read(buyer))!;
    final pending = (document['messages'] as List)
        .whereType<Map>()
        .singleWhere((m) => m['id'] == media.messageId);
    expect(pending['service_input_frozen'], isNull);
    expect((await work(media.messageId))['response_state'], 'pending');
    expect(await db.isIncompleteImageAcquisitionAllowed(buyer, media.messageId),
        isTrue);
  });
  test('single logical message refreeze retains proven legacy ledger aliases',
      () async {
    final id = await text('这是你们已签收了的', 1);
    final sql = await db.database;
    final original = Map<String, Object?>.from(await work(id));
    await sql.insert(
        'automation_session_messages', {...original, 'message_id': 'text-1'});
    final pending = (await db.conversation(buyer))!.id;
    final claim = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: pending,
        batchEndMessageId: id,
        singleMessage: true))!;
    final inputs = await db.generationMessages(buyer);
    expect(
        inputs.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        [id]);
    final refreshed = await db.refreezeGenerationBeforeSubmit(
        customer: buyer,
        pendingId: pending,
        generationToken: claim.token,
        batchEndMessageId: claim.batchEndMessageId,
        expectedSessionId: session,
        singleMessage: true);
    expect(refreshed, isNotNull);
    expect(refreshed!.token, claim.token);
    expect(refreshed.batchEndMessageId, claim.batchEndMessageId);
  });
  test('API inputs freeze independently while another customer token is active',
      () async {
    final first = await text('第一条的内容', 1);
    final pending = (await db.conversation(buyer))!.id;
    final token = (await db.beginGeneration(
        customer: buyer,
        pendingId: pending,
        batchEndMessageId: first,
        singleMessage: true))!;
    final second = await text('第二条的内容', 2);
    final third = await text('第三条的内容', 3);
    expect(await db.eligibleSingleMessageIds(buyer),
        containsAll([first, second, third]));
    final frozen = await Future.wait([second, third].map((id) =>
        db.freezeReadyApiMessage(buyer, id, expectedSessionId: session)));
    expect(frozen.map((m) => m!['id']), [second, third]);
    expect(frozen.every((m) => m!['reply_input_kind'] == 'text'), isTrue);
    await text('第二条内容', 2);
    expect((await db.freezeReadyApiMessage(buyer, second))!['body'], '第二条的内容');
    expect(
        await db.generationInputVersionsCurrent(buyer, generationToken: token),
        isTrue);
    expect((await db.generationMessages(buyer)).last['id'], first);
    await db.abandonGeneration(buyer, token);
    final selected = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: pending,
        batchEndMessageId: third,
        singleMessage: true,
        eligibleMessageIds: {third}))!;
    expect(selected.batchEndMessageId, third);
    expect(
        (await db.generationMessages(buyer))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        [third]);
    expect((await work(first))['response_state'], 'pending');
    expect((await work(second))['response_state'], 'pending');
    expect(
        (await save(third, selected.token, answer('请提供快递单号，我会帮您核实。'))).queued,
        isTrue);
    await submit();
    expect((await work(first))['response_state'], 'pending');
    final earlier = await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: first,
        singleMessage: true,
        eligibleMessageIds: {first});
    expect(earlier, isNotNull);
    expect(earlier!.batchEndMessageId, first);
  });
  test('new hosted result wakes customer retry without releasing current lease',
      () async {
    final id = await text('请查一下单号', 1);
    final pending = (await db.conversation(buyer))!.id;
    await db.recordGenerationFailure(buyer, StateError('older API job failed'));
    expect(
        await db.beginGenerationSnapshot(
            customer: buyer,
            pendingId: pending,
            batchEndMessageId: id,
            singleMessage: true,
            eligibleMessageIds: {id}),
        isNull);
    await db.wakeHostedGenerationResult(buyer);
    final claim = (await db.beginGenerationSnapshot(
        customer: buyer,
        pendingId: pending,
        batchEndMessageId: id,
        singleMessage: true,
        eligibleMessageIds: {id}))!;
    await db.wakeHostedGenerationResult(buyer);
    expect(
        await db.generationInputVersionsCurrent(buyer,
            generationToken: claim.token),
        isTrue);
  });
  test('completed API claim save and native readiness avoid heavy preparation',
      () async {
    final first = await text('请核实第一条消息', 1);
    final second = await text('请核实第二条消息', 2);
    final source = (await db.freezeReadyApiMessage(buyer, first))!;
    final pending = (await db.conversation(buyer))!.id;
    (db as HeavyWorkBlockedDatabase).blockHeavy = true;
    (db as HeavyWorkBlockedDatabase).blockHistory = true;
    final claim = (await db.beginCompletedApiDelivery(
        customer: buyer,
        pendingId: pending,
        source: source,
        expectedSessionId: session))!;
    final draft = answer('请提供您的快递单号，我会帮您核实签收记录。');
    expect(
        (await db.saveCompletedApiDraft(
                pendingId: pending,
                customer: buyer,
                draft: draft,
                source: source,
                generationToken: claim.token))
            .queued,
        isTrue);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: draft.reply, taskId: claim.token),
        isTrue);
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: buyer, reply: draft.reply, taskId: claim.token),
        isTrue);
    expect(await db.retireStaleMediaDraft(buyer), isFalse);
    final delivery = (await db.nextReadyDelivery(userId: buyer))!;
    expect(delivery.taskId, claim.token);
    expect((await db.deliveryTiming(buyer, claim.token))['customerMessageAt'],
        source['sent_at']);
    final attempt = await db.beginDeliveryAttempt(
        userId: buyer, reply: draft.reply, taskId: claim.token);
    (db as HeavyWorkBlockedDatabase).blockHistory = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'timeMs': now,
      'sendClickedAtMs': now
    }));
    await db.recoverDeliveryReceipts();
    expect((await work(first))['response_state'], 'answered');
    expect((await work(second))['response_state'], 'pending');
  });
  test(
      'completed fast claim rejects stale customer session revisions kind and answered work',
      () async {
    final id = await text('请查一下单号', 1);
    final source = (await db.freezeReadyApiMessage(buyer, id))!;
    final pending = (await db.conversation(buyer))!.id;
    final sql = await db.database;
    final original = Map<String, Object?>.from(await work(id));
    (db as HeavyWorkBlockedDatabase).blockHeavy = true;
    expect(
        await db.beginCompletedApiDelivery(
            customer: 'other-customer', pendingId: pending, source: source),
        isNull);
    expect(
        await db.beginCompletedApiDelivery(
            customer: buyer,
            pendingId: pending,
            source: source,
            expectedSessionId: 'old-session'),
        isNull);
    expect(
        await db.beginCompletedApiDelivery(
            customer: buyer,
            pendingId: pending,
            source: {...source, 'body': 'different bytes'}),
        isNull);
    for (final change in <Map<String, Object?>>[
      {'response_state': 'answered'},
      {'work_revision': (original['work_revision']! as int) + 1},
      {'input_key': 'different-key'},
      {'input_kind': 'media'},
    ]) {
      await sql.update('automation_session_messages', change,
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [session, buyer, id]);
      expect(
          await db.beginCompletedApiDelivery(
              customer: buyer, pendingId: pending, source: source),
          isNull);
      await sql.update('automation_session_messages', original,
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [session, buyer, id]);
    }
    final claim = (await db.beginCompletedApiDelivery(
        customer: buyer, pendingId: pending, source: source))!;
    await sql.update('automation_session_messages',
        {'work_revision': (original['work_revision']! as int) + 1},
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, buyer, id]);
    final result = await db.saveCompletedApiDraft(
        pendingId: pending,
        customer: buyer,
        draft: answer('请提供您的快递单号。'),
        source: source,
        generationToken: claim.token);
    expect(result.outcome, AutomaticDraftSaveOutcome.stale);
    expect(await sql.query('generated_drafts'), isEmpty);
  });

  test(
      'completed status-only output repairs without sending or marking answered',
      () async {
    final id = await text('请查一下单号', 1);
    final source = (await db.freezeReadyApiMessage(buyer, id))!;
    final pending = (await db.conversation(buyer))!.id;
    (db as HeavyWorkBlockedDatabase).blockHeavy = true;
    final claim = (await db.beginCompletedApiDelivery(
        customer: buyer, pendingId: pending, source: source))!;
    final result = await db.saveCompletedApiDraft(
        pendingId: pending,
        customer: buyer,
        draft: answer('Please wait while I check the issue.'),
        source: source,
        generationToken: claim.token);
    expect(result.outcome, AutomaticDraftSaveOutcome.needsAnswer);
    expect(await (await db.database).query('generated_drafts'), isEmpty);
    expect((await work(id))['response_state'], 'pending');
    expect(await (await db.database).query('automation_message_waits'),
        isNotEmpty);
  });

  test('general draft save cannot authorize fast proof from server metadata',
      () async {
    final id = await text('请查一下单号', 1);
    final source = (await db.freezeReadyApiMessage(buyer, id))!;
    final token = (await db.beginGeneration(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: id,
        singleMessage: true))!;
    final raw =
        jsonDecode(answer('请提供您的快递单号。').rawJson) as Map<String, dynamic>;
    raw['_local_hosted_completed_api'] = true;
    raw['_local_hosted_completed_source'] = source;
    expect(
        (await save(id, token, AiDraft.fromJson(raw, mediaBaseUrl: Uri())))
            .queued,
        isTrue);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: '请提供您的快递单号。', taskId: token),
        isNull);
  });
}

class HeavyWorkBlockedDatabase extends CaptureDatabase {
  HeavyWorkBlockedDatabase({required super.storageRoot});
  bool blockHeavy = false;
  bool blockHistory = false;
  @override
  Future<ConversationFileStore> get history {
    if (blockHistory) throw StateError('history forbidden before native send');
    return super.history;
  }

  @override
  Future<bool> repairSessionPendingWork(String customer) {
    if (blockHeavy) throw StateError('heavy repair forbidden after API result');
    return super.repairSessionPendingWork(customer);
  }

  @override
  Future<List<Map<String, dynamic>>> processingMessages(String customer,
      {Map<String, dynamic>? document, bool includeAnswered = false}) {
    if (blockHeavy) {
      throw StateError('processing/history scan forbidden after API result');
    }
    return super.processingMessages(customer,
        document: document, includeAnswered: includeAnswered);
  }

  @override
  Future<AiDraft> prepareAutomaticDraft(String customer, AiDraft draft) {
    if (blockHeavy) throw StateError('general automatic preparation forbidden');
    return super.prepareAutomaticDraft(customer, draft);
  }
}
