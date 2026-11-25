import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late CodexReplyService service;
  late File requestFile;
  late DateTime clock;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v45_receipt_scope_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    clock = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
    await db.beginAutomationSession(startedAt: clock);
    inventory = CustomerMediaInventory(db);
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    await File('${knowledge.path}/printer_kb.md').writeAsString(
        'Switch off the printer before checking paper feed. Follow the supplied setup guide.');
    requestFile = File('${root.path}/request.json');
    final cli = await File('${root.path}/controlled-cli.py')
        .writeAsString('''#!/usr/bin/python3
import sys,json,re,pathlib
args=sys.argv[1:]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
pathlib.Path(${jsonEncode(requestFile.path)}).write_text(json.dumps(request))
reply={'reply':'Switch off the printer before checking the paper feed shown in your image.','reply_purpose':'substantive','decision':'draft','confidence':0.99,'risk_level':'low','auto_send_allowed':False,'human_review_required':False,'risk_triggers':[],'used_record_ids':[],'required_slots':[],'actions':[],'attachments':[],'image_descriptions':[{'path':p,'description':'The supplied image shows the printer and its paper feed area.'} for p in request['attached_image_paths']]}
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(reply))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    service = CodexReplyService(
        executable: cli.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'),
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedConversation capture(String id, String body,
      {String? receipt, List<CapturedMedia> media = const []}) {
    clock = clock.add(const Duration(seconds: 1));
    return CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: clock,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body,
              sender: 'buyer',
              sentAt: clock,
              observationTurnKey: 'bubble:$id',
              captureEvidenceId: 'frozen:$id',
              mediaReceiptId: receipt,
              media: media,
              axPath: 'exact current AX buyer / separate bubble $id')
        ]);
  }

  Future<String> card(String id, String kind) async {
    clock = clock.add(const Duration(seconds: 1));
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frozen:$id',
        occurrenceKey: 'bubble:$id',
        observedAt: clock,
        senderAt: clock,
        slot: 0,
        region: [.3, .45, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: clock, senderAt: clock);
    await inventory.classify(receipt, kind);
    return receipt;
  }

  Future<void> nativeConfirmed(AiDraft draft) async {
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: draft.reply);
    expect(attempt, isNotEmpty);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<void> answeredVideo(String id) async {
    final receipt = await card(id, 'video');
    final c = capture(id, '[Customer sent a video]',
        receipt: receipt, media: await completedVideoFixture(root, name: id));
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true);
    final draft = AiDraft.fromJson({
      'reply': 'The video shows the printer paper feed.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft((await db.conversation('buyer'))!.id, draft,
            expectedMessageId: id),
        1);
    await nativeConfirmed(draft);
  }

  Future<File> completeImage(String id, String receipt) async {
    final file = await File('test/fixtures/v35_media/unbound-video-cover.jpg')
        .copy('${root.path}/$id.jpg');
    final c = capture(id, '[Customer sent an image]', receipt: receipt, media: [
      CapturedMedia(
          type: 'image', path: file.path, captureSource: 'jd_image_cache')
    ]);
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true);
    return file;
  }

  Future<void> answeredImage(String id) async {
    await completeImage(id, await card(id, 'image'));
    final draft = AiDraft.fromJson({
      'reply': 'The image shows the printer paper feed.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft((await db.conversation('buyer'))!.id, draft,
            expectedMessageId: id),
        1);
    await nativeConfirmed(draft);
  }

  Future<void> admissionGap(DateTime at, {bool proof = true}) async {
    final evidence = ViewportEvidence({
      'evidenceId': 'gap:${at.microsecondsSinceEpoch}',
      'customer': 'buyer',
      'capturedAtMs': at.millisecondsSinceEpoch,
      'imagePath': '${root.path}/gap.png',
      'manifestPath': '${root.path}/gap.json',
      'automationSessionId': db.currentAutomationSessionId,
      'replyActivationAllowed': true,
      'unreadArrivalKey': 'frozen-current-AX-arrival',
      'capturePurpose': 'live_signal',
      'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
    });
    final audit = MediaCaptureAudit(db, record: (_, __) {});
    final id = await audit.discover(
        evidence,
        const OcrVisualRegion(
            x: .3, y: .4, width: .2, height: .2, confidence: 1));
    if (proof) {
      await audit.rememberLiveArrival(id,
          evidence: evidence,
          occurrenceKey: 'actual-current-bubble:$id',
          arrivalKey: 'guarded-live-arrival:$id',
          senderAt: at,
          slot: 0);
    }
  }

  Future<AiDraft> generate(String id) async {
    final conversation = (await db.conversation('buyer'))!;
    final token = (await db.beginGeneration(
        customer: 'buyer', pendingId: conversation.id, batchEndMessageId: id))!;
    final draft = await service.generate(
        conversation: conversation, database: db, batchEndMessageId: id);
    final prepared = await db.prepareAutomaticDraft('buyer', draft);
    expect(
        await db.saveDraft(conversation.id, prepared,
            expectedMessageId: id, generationToken: token),
        1);
    await db.abandonGeneration('buyer', token);
    return prepared;
  }

  Map<String, dynamic> known(String id, String kind, {bool available = true}) =>
      {
        'mediaItemId': 'receipt:$id',
        'messageId': id,
        'kind': kind,
        'state': available ? 'ready' : 'pending',
        'detected': true,
        'clockIdentified': true,
        'identityAmbiguous': false,
        'originalVerified': available,
        'analysisAvailable': available,
        'availableMedia': <Map<String, dynamic>>[],
      };

  test('receipt policy never answers a picture question with old videos', () {
    final reply = CustomerMediaInventory.receiptReply('did you get my picture?',
        [for (var i = 0; i < 3; i++) known('old-$i', 'video')],
        english: true);
    expect(reply, isNotNull);
    expect(reply!.toLowerCase(), isNot(contains('video')));
    expect(reply.toLowerCase(), contains('image'));
    expect(reply.toLowerCase(), contains('confirm'));
  });

  test('image count uses images and latest single reference stays singular',
      () {
    final items = [
      known('old-video', 'video'),
      known('first-image', 'image'),
      known('last-image', 'image', available: false),
    ];
    final count = CustomerMediaInventory.receiptReply(
        'How many pictures did you receive?', items,
        english: true)!;
    expect(count, contains('2 image messages'));
    expect(count, isNot(contains('video')));
    final last = CustomerMediaInventory.receiptReply(
        'Did you get my picture?', items,
        english: true)!;
    expect(last, contains('1 image message'));
    expect(last, contains('not yet available'));
    expect(last, isNot(contains('2 image')));
    final first = CustomerMediaInventory.receiptReply(
        'Did you get the first picture?', items,
        english: true)!;
    expect(first, contains('1 image message'));
    expect(first, contains('available for analysis'));
  });

  test(
      'real service with three answered old videos cannot substitute them for picture receipt',
      () async {
    for (var i = 0; i < 3; i++) {
      await answeredVideo('old-video-$i');
    }
    expect(await db.unansweredWorkCounts(), isEmpty);
    await db.saveCapture(capture('picture-receipt', 'did you get my picture?'));
    final draft = await generate('picture-receipt');
    expect(draft.model, 'local-media-receipt');
    expect(draft.reply.toLowerCase(), isNot(contains('video')));
    expect(draft.reply.toLowerCase(), contains('image'));
    expect(draft.reply.toLowerCase(), contains('confirm'));
    final raw = jsonDecode(draft.rawJson) as Map;
    expect(raw['reply_purpose'], 'receipt');
    expect(raw['reply_media_dependency_keys'], isEmpty);
    expect(raw['formal_response_message_ids'], ['picture-receipt']);
    expect(await requestFile.exists(), isFalse);
    await nativeConfirmed(draft);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test(
      'pending image receipt can be answered while image itself remains pending until full analysis',
      () async {
    final receipt = await card('new-image', 'image');
    final pending = capture(
        'new-image', '[Customer media awaiting acquisition]',
        receipt: receipt);
    await db.saveCapture(pending);
    await inventory.persist(pending, verifiedAnchor: true);
    await db.saveCapture(capture('receipt-question', '你收到图片了吗？'));
    final receiptDraft = await generate('receipt-question');
    expect(receiptDraft.model, 'local-media-receipt');
    expect(receiptDraft.reply, contains('图片消息'));
    expect(receiptDraft.reply, contains('尚未'));
    expect(receiptDraft.reply, isNot(contains('视频')));
    final receiptRaw = jsonDecode(receiptDraft.rawJson) as Map;
    expect(receiptRaw['reply_purpose'], 'receipt');
    expect(receiptRaw['formal_response_message_ids'], ['receipt-question']);
    await nativeConfirmed(receiptDraft);
    expect(await db.isMessageFormallyAnswered('buyer', 'receipt-question'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'new-image'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});

    final image = await File('test/fixtures/v35_media/unbound-video-cover.jpg')
        .copy('${root.path}/new-image.jpg');
    final complete = capture('new-image', '[Customer sent an image]',
        receipt: receipt,
        media: [
          CapturedMedia(
              type: 'image', path: image.path, captureSource: 'jd_image_cache')
        ]);
    await db.saveCapture(complete);
    await inventory.persist(complete, verifiedAnchor: true);
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains('new-image'));
    final formal = await generate('new-image');
    expect(jsonDecode(formal.rawJson)['reply_purpose'], 'substantive');
    expect(formal.imageDescriptions.keys, contains(image.path));
    final request = jsonDecode(await requestFile.readAsString()) as Map;
    expect(request['attached_image_paths'], [image.path]);
    await nativeConfirmed(formal);
    expect(await db.isMessageFormallyAnswered('buyer', 'new-image'), isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test(
      'pure receipt grammar preserves facts but delegates every mixed real question',
      () {
    for (final question in [
      'Did you get my picture?',
      'Have you received the first video?',
      'How many pictures did you receive?',
      'you get how many video?',
      '你收到图片了吗？',
      '你收到了几个视频？',
      '视频不是发你了吗',
    ]) {
      expect(isExplicitMediaReceiptQuestion(question), isTrue,
          reason: question);
    }
    for (final question in [
      'Did you get my picture? How do I connect the printer?',
      'Did you receive the video; explain the issue shown in it.',
      'Can you see what is wrong in my picture?',
      '你收到图片了吗？怎么连接打印机？',
      '你看到视频了吗帮我分析故障',
      '收到图片后请告诉我如何操作',
    ]) {
      expect(isExplicitMediaReceiptQuestion(question), isFalse,
          reason: question);
    }
  });

  test(
      'an untyped current gap never borrows an earlier image or invents its count',
      () {
    final old = {
      ...known('earlier-image', 'image'),
      'receivedAt': clock.toIso8601String(),
    };
    final gap = <String, Object?>{
      'observedAt': clock.add(const Duration(seconds: 1)).toIso8601String(),
      'typeHint': 'unknown',
    };
    final current = CustomerMediaInventory.receiptFact(
        'Did you get my picture?', [old],
        english: true, pendingObservations: [gap])!;
    expect(current.reply, contains('cannot confirm'));
    expect(current.reply, isNot(contains('I can see 1 image')));
    expect(current.items, isEmpty);
    final first = CustomerMediaInventory.receiptFact(
        'Did you get the first picture?', [old],
        english: true, pendingObservations: [gap])!;
    expect(first.reply, contains('1 image message'));
    expect(first.items.single['messageId'], 'earlier-image');
    final count = CustomerMediaInventory.receiptReply(
        'How many pictures did you receive?', [old],
        english: true, pendingObservations: [gap])!;
    expect(count, contains('1 image message'));
    expect(count, contains('count may not yet be complete'));
    expect(count, isNot(contains('2 image')));
    final otherType =
        CustomerMediaInventory.receiptReply('Did you get my picture?', [old],
            english: true,
            pendingObservations: [
              {...gap, 'typeHint': 'video'}
            ])!;
    expect(otherType, contains('1 image message'));
  });

  for (final gapType in ['current', 'future', 'unproven']) {
    test(
        'real service scopes $gapType admission gap to the frozen receipt question',
        () async {
      await answeredImage('old-image');
      final questionAt = clock.add(const Duration(seconds: 2));
      await admissionGap(
          gapType == 'future'
              ? questionAt.add(const Duration(seconds: 1))
              : questionAt.subtract(const Duration(seconds: 1)),
          proof: gapType != 'unproven');
      clock = questionAt.subtract(const Duration(seconds: 1));
      await db
          .saveCapture(capture('receipt-with-gap', 'Did you get my picture?'));
      final draft = await generate('receipt-with-gap');
      expect(draft.model, 'local-media-receipt');
      final raw = jsonDecode(draft.rawJson) as Map;
      if (gapType == 'current') {
        expect(draft.reply, contains('cannot confirm'));
        expect(draft.reply, contains('still being checked'));
        expect(raw['reply_media_dependency_keys'], isEmpty);
      } else {
        expect(draft.reply, contains('1 image message'));
        expect(draft.reply, isNot(contains('still being checked')));
        expect((raw['reply_media_dependency_keys'] as Map).keys, ['old-image']);
      }
      expect(raw['formal_response_message_ids'], ['receipt-with-gap']);
      await nativeConfirmed(draft);
      expect(await db.unansweredWorkCounts(), isEmpty);
      expect(
          await MediaCaptureAudit(db).pendingAdmissionGaps(customer: 'buyer'),
          gapType == 'unproven' ? isEmpty : hasLength(1),
          reason:
              'Receipt text delivery neither creates nor completes a gap owner');
    });
  }

  test(
      'every receipt question in one frozen text batch gets its own typed answer',
      () async {
    await answeredVideo('previous-video');
    await db.saveCapture(capture('video-receipt', 'Did you get my video?'));
    await db.saveCapture(capture('image-receipt', 'Did you get my picture?'));
    final draft = await generate('image-receipt');
    expect(draft.model, 'local-media-receipt');
    expect(draft.reply, contains('1 video message'));
    expect(draft.reply, contains('cannot confirm receipt of the image'));
    expect(jsonDecode(draft.rawJson)['formal_response_message_ids'],
        ['video-receipt', 'image-receipt']);
    await nativeConfirmed(draft);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'video-receipt'), isTrue);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'image-receipt'), isTrue);
  });

  test(
      'mixed receipt and operation is never discharged by receipt or before full image analysis',
      () async {
    final receipt = await card('operation-image', 'image');
    final pending = capture(
        'operation-image', '[Customer media awaiting acquisition]',
        receipt: receipt);
    await db.saveCapture(pending);
    await inventory.persist(pending, verifiedAnchor: true);
    await db.saveCapture(capture('mixed-question',
        'Did you get my picture? How do I check the paper feed?'));
    final waitingConversation = (await db.conversation('buyer'))!;
    expect(
        await db.beginGeneration(
            customer: 'buyer',
            pendingId: waitingConversation.id,
            batchEndMessageId: 'mixed-question'),
        isNull,
        reason: 'The normal workflow cannot lease a mixed substantive question '
            'before its exact image dependency is complete');
    expect(await requestFile.exists(), isFalse,
        reason:
            'Do not run a model against incomplete media to force a result');
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    expect(
        await db.isMessageFormallyAnswered('buyer', 'mixed-question'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'operation-image'),
        isFalse);

    final image = await completeImage('operation-image', receipt);
    final formal = await generate('mixed-question');
    expect(formal.model, isNot('local-media-receipt'));
    expect(jsonDecode(formal.rawJson)['reply_purpose'], 'substantive');
    expect(
        (jsonDecode(formal.rawJson)['formal_response_message_ids'] as List)
            .toSet(),
        {'mixed-question', 'operation-image'});
    expect(formal.imageDescriptions.keys, contains(image.path));
    expect(
        formal.imageDescriptions.values.every((text) => text.trim().isNotEmpty),
        isTrue);
    await nativeConfirmed(formal);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });
}
