import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/completed_video_fixture.dart';

AiDraft _answer(String text) => AiDraft.fromJson({
      'reply': text,
      'decision': 'draft',
      'reply_purpose': 'substantive',
      'confidence': 1,
      'risk_level': 'low',
      'auto_send_allowed': false,
      'model': 'controlled-v44-dependency-closure',
      'reply_media_dependency_keys': <String, String>{},
    }, mediaBaseUrl: Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime clock;
  var sequence = 0;
  const buyer = 'buyer';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_dependency_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    clock = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(startedAt: clock);
    sequence = 0;
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<int> text(String id, String body,
      {Map<String, Set<String>> dependencies = const {}}) {
    clock = clock.add(const Duration(seconds: 1));
    return db.saveCapture(
        CapturedConversation(
            stableKey: buyer,
            customerName: buyer,
            customerExternalId: buyer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: clock,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: body,
                  sender: buyer,
                  sentAt: clock,
                  axPath: 'exact customer text $id',
                  observationTurnKey: 'ocr-bubble:$id:0',
                  captureEvidenceId: 'immutable-$id')
            ]),
        mediaInputDependencies: dependencies,
        dependencyEvidenceId: dependencies.isEmpty ? null : 'immutable-$id');
  }

  Future<({String id, String receipt})> card(String id,
      {String kind = 'video', bool admit = true}) async {
    clock = clock.add(const Duration(seconds: 1));
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: 'card-${sequence++}',
        observedAt: clock,
        senderAt: clock,
        slot: sequence,
        region: [.3, .3, .2, .2],
        current: true,
        occurrenceKey: 'actual-bubble-$id');
    var owner = id;
    if (admit) {
      final admission = await db.admitMediaMessage(buyer,
          receiptId: receipt,
          evidenceId: 'immutable-card-$id',
          occurrenceKey: 'actual-bubble-$id',
          receivedAt: clock,
          senderAt: clock,
          messageId: id);
      owner = admission.messageId;
    }
    await inventory.classify(receipt, kind);
    return (id: owner, receipt: receipt);
  }

  Future<void> videoPayload(
      ({String id, String receipt}) item, List<CapturedMedia> media) async {
    clock = clock.add(const Duration(seconds: 1));
    final capture = CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: clock,
        messages: [
          CapturedMessage(
              stableId: item.id,
              direction: 'incoming',
              body: '[Customer sent a video]',
              sender: buyer,
              mediaReceiptId: item.receipt,
              media: media,
              axPath: 'same proved video original and full timeline')
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
  }

  Future<void> complete(({String id, String receipt}) item) async =>
      videoPayload(item, await completedVideoFixture(root, name: item.id));

  Future<String?> begin(String id) async => db.beginGeneration(
      customer: buyer,
      pendingId: (await db.conversation(buyer))!.id,
      batchEndMessageId: id);

  Future<int> save(String id, String token, String reply) async {
    final prepared = await db.prepareAutomaticDraft(buyer, _answer(reply));
    return db.saveDraft((await db.conversation(buyer))!.id, prepared,
        expectedMessageId: id, expectedUserId: buyer, generationToken: token);
  }

  Future<void> submit(String reply) async {
    final attempt = await db.beginDeliveryAttempt(userId: buyer, reply: reply);
    final at = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': buyer,
      'state': 'submitted',
      'sendClickedAtMs': at,
      'timeMs': at,
    }));
    await db.recoverDeliveryReceipts();
  }

  test('known video reference leases text without waiting for video parsing',
      () async {
    final video = await card('video');
    await text('question', 'check this');
    var modelCalls = 0;
    Future<String?> claim() async {
      final token = await begin('question');
      if (token != null) modelCalls++;
      return token;
    }

    final token = (await claim())!;
    expect(modelCalls, 1);
    final sql = await db.database;
    expect(await sql.query('automation_message_waits'), isEmpty);
    final inputs = await db.generationMessages(buyer);
    final question = inputs.singleWhere((m) =>
        m['id'] == 'question' ||
        (m['observed_ids'] as List? ?? const []).contains('question'));
    expect(question['reply_input_kind'], 'text');
    expect(question['reply_media_input_dependencies'], isEmpty);
    final unrelated = await card('future-video');
    await complete(unrelated);
    await complete(video);
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
    expect(await save('question', token, 'Please check the paper path.'), 1);
    await submit('Please check the paper path.');
    expect(await db.isMessageFormallyAnswered(buyer, 'question'), isTrue);
    expect(await db.isMessageFormallyAnswered(buyer, video.id), isFalse);
    expect(await db.isMessageFormallyAnswered(buyer, unrelated.id), isFalse);
  });

  test('caption ledger and known dependency commit together before claiming',
      () async {
    final image = await card('image', kind: 'image');
    final pendingId = (await db.conversation(buyer))!.id;
    final entered = Completer<void>();
    final release = Completer<void>();
    final store = await db.history;
    final held = store.withCustomerSnapshot(buyer, (_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final saving = text('caption', 'How do I power it on?', dependencies: {
      'caption': {image.receipt}
    });
    final claiming = db.beginGeneration(
        customer: buyer, pendingId: pendingId, batchEndMessageId: 'caption');
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await held;
    await saving;
    expect(await claiming, isNotNull);
    expect(await db.generationDue(buyer), isTrue);
    final sql = await db.database;
    final frozen = await sql.query('automation_reply_inputs');
    expect(frozen, hasLength(1));
    final caption = frozen.single['message_id'];
    expect(
        (await sql.query('automation_session_messages',
                where: 'message_id=?', whereArgs: [caption]))
            .single['response_state'],
        'pending');
    final edge = (await sql.query('automation_message_evidence',
            where: 'message_id=?', whereArgs: [caption]))
        .single;
    expect((jsonDecode(edge['evidence_key']! as String) as Map)['receiptId'],
        image.receipt);
    expect(
        (await sql.query('automation_message_waits',
            where: 'message_id=?', whereArgs: [caption])),
        isEmpty);
  });

  test('a real photo arriving during generation does not mutate the old lease',
      () async {
    await text('question', 'How do I power it on?');
    final token = (await begin('question'))!;
    final modelStarted = Completer<void>();
    final modelRelease = Completer<void>();
    const reply = 'Connect the supplied cable and hold the power button.';
    final result = () async {
      final input = (await db.generationMessages(buyer)).single;
      expect(input['reply_media_input_dependencies'], isEmpty);
      modelStarted.complete();
      await modelRelease.future;
      expect(
          await db.generationInputsAnalysisReady(buyer, generationToken: token),
          isTrue);
      return save('question', token, reply);
    }();
    await modelStarted.future;
    final laterPhoto = await card('later-photo', kind: 'image');
    await text('question', 'How do I power it on?', dependencies: {
      'question': {laterPhoto.receipt}
    });
    modelRelease.complete();
    expect(await result, 1);
    final ready = (await db.nextReadyDelivery())!;
    expect(ready.taskId, token);
    await submit(reply);
    expect(await db.isMessageFormallyAnswered(buyer, 'question'), isTrue);
    expect(await db.isMessageFormallyAnswered(buyer, laterPhoto.id), isFalse);
    expect(await db.hasPendingUnanswered(buyer), isTrue);
  });

  test('unchanged analyzable key still wakes at the audio terminal state',
      () async {
    final video = await card('video');
    final completeMedia =
        await completedVideoFixture(root, name: 'audio-terminal');
    final pendingAudio = completeMedia
        .map((m) => m.type != 'video'
            ? m
            : CapturedMedia(
                type: m.type,
                path: m.path,
                mimeType: m.mimeType,
                originalName: m.originalName,
                captureSource: m.captureSource,
                description:
                    'Original customer video. [Video audio: analysis pending]',
                mediaRoles: m.mediaRoles))
        .toList();
    await videoPayload(video, pendingAudio);
    await text('question', 'Please review this video.');
    final keyBefore =
        (await inventory.analyzableEvidenceKeys(buyer))[video.receipt];
    expect(await begin(video.id), isNull);
    // Replay the production late-audio path. A fresh capture representation
    // does not replace a longer pending description; audio enrichment appends
    // its exact terminal conclusion to this proved owner/path instead.
    final original = pendingAudio.singleWhere((m) => m.type == 'video');
    final terminal = '${original.description}\n'
        '${completeMedia.singleWhere((m) => m.type == 'video').description}';
    await (await db.history)
        .updateMediaDescriptions(buyer, {original.path: terminal});
    expect(
        await inventory.updateProvenVideoDescription(
            buyer, original.path, terminal,
            messageId: video.id, receiptId: video.receipt),
        greaterThan(0));
    expect((await inventory.analyzableEvidenceKeys(buyer))[video.receipt],
        keyBefore);
    expect(await inventory.analysisReadyMessageIds(buyer), contains(video.id));
    final token = (await begin(video.id))!;
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
  });

  test('unadmitted history and factual receipt questions cannot park business',
      () async {
    await card('unbound-history', admit: false);
    await text('independent', 'What is the printer warranty?');
    final first = (await begin('independent'))!;
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: first),
        isTrue);
    expect(await save('independent', first, 'The warranty is one year.'), 1);
    await submit('The warranty is one year.');
    await card('actual-video');
    await text('receipt-question', 'Did you receive my video?');
    expect(await begin('receipt-question'), isNotNull);
  });

  test('requesting a guide never depends on a previous unready customer video',
      () async {
    await card('old-video');
    await text('guide', 'Can you share a setup video for M880?');
    final token = (await begin('guide'))!;
    final question = (await db.generationMessages(buyer)).singleWhere((m) =>
        m['id'] == 'guide' ||
        (m['observed_ids'] as List? ?? const []).contains('guide'));
    expect(question['reply_media_input_dependencies'], isEmpty);
    expect(
        await db.generationInputsAnalysisReady(buyer, generationToken: token),
        isTrue);
  });
}
