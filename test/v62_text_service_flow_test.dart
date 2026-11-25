import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

// Model a frozen pre-correction snapshot that still contains an old image
// receipt. The joined ledger kind remains authoritative for request routing.
class _StaleTextProjectionDatabase extends CaptureDatabase {
  _StaleTextProjectionDatabase({required super.storageRoot});
  String? staleImagePath;

  @override
  Future<List<Map<String, dynamic>>> generationMessages(String customer,
      {String? batchEndMessageId, Map<String, dynamic>? document}) async {
    final messages = await super.generationMessages(customer,
        batchEndMessageId: batchEndMessageId, document: document);
    return [
      for (final message in messages)
        if (staleImagePath != null && message['reply_input_kind'] == 'text')
          {
            ...message,
            'media_receipt_id': 'old-receipt',
            'text_origin': 'media',
            'media': [
              {'type': 'image', 'path': staleImagePath, 'is_partial': true}
            ],
          }
        else
          message,
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'junxi112233';
  late Directory root;
  late _StaleTextProjectionDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime start;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v62_text_service_');
    db = _StaleTextProjectionDatabase(
        storageRoot: Directory('${root.path}/data'));
    inventory = CustomerMediaInventory(db);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 60000,
        isUtc: true);
    session = await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/controlled_kb.md').writeAsString(
        'Controlled fixture: connect the USB cable and install the matching driver.');
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

  Future<String> text(String body, int second) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(capture(CapturedMessage(
        stableId: 'text-$second',
        direction: 'incoming',
        sender: buyer,
        sentAt: at,
        body: body,
        axPath: 'exact customer text bubble')));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  Future<({String id, String receipt, String path})> media(int second,
      {String kind = 'unknown',
      bool partial = true,
      bool fileUri = false,
      String? description}) async {
    final at = start.add(Duration(seconds: second));
    final receipt = await inventory.observe(
        customer: buyer,
        evidenceId: 'frame-$second',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: const [.3, .4, .2, .2],
        current: true);
    final admission = await db.admitMediaMessage(buyer,
        receiptId: receipt,
        evidenceId: 'frame-$second',
        occurrenceKey: 'actual-customer-bubble-$second',
        receivedAt: at,
        senderAt: at);
    await inventory.classify(receipt, kind);
    final localPath = '${root.path}/media-$second.png';
    final path = fileUri ? Uri.file(localPath).toString() : localPath;
    // The controlled CLI records file paths; it never performs real OCR.
    await File(localPath).writeAsBytes([0]);
    final message = CapturedMessage(
        stableId: admission.messageId,
        direction: 'incoming',
        sender: buyer,
        sentAt: at,
        body: '[Customer media; acquisition pending.]',
        axPath: 'exact customer media bubble',
        captureEvidenceId: 'frame-$second',
        mediaReceiptId: receipt,
        media: [
          CapturedMedia(
              type: 'image',
              path: path,
              captureSource: partial
                  ? 'verified_chat_viewport_fallback'
                  : 'jd-image-cache',
              isPartial: partial,
              description: description)
        ]);
    await db.saveCapture(capture(message));
    await inventory.persist(capture(message));
    if (kind == 'unknown') {
      await (await db.database).update('customer_media_items',
          {'kind': 'unknown', 'state': 'detected', 'media_json': '[]'},
          where: 'customer=? AND item_id=?', whereArgs: [buyer, receipt]);
    }
    return (id: admission.messageId, receipt: receipt, path: path);
  }

  Future<String> begin(String id) async {
    final token = await db.beginGeneration(
        customer: buyer,
        pendingId: (await db.conversation(buyer))!.id,
        batchEndMessageId: id);
    expect(token, isNotNull);
    return token!;
  }

  Future<({AiDraft draft, Map request, String prompt})> generate(String id,
      {String answer = '请提供寄回时使用的快递单号，方便核对这次签收记录。',
      bool describeImages = false,
      Future<String?> Function()? beforeSubmit,
      void Function(bool)? onMediaDependency}) async {
    final response = File('${root.path}/response.json');
    await response.writeAsString(jsonEncode({
      'reply': answer,
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'human_review_required': false,
      'auto_send_allowed': false,
      'risk_triggers': [],
      'actions': [],
      'attachments': [],
      'used_record_ids': ['controlled'],
      'image_descriptions': []
    }));
    final promptFile = File('${root.path}/request.txt');
    final cli = File('${root.path}/controlled-cli.py');
    await cli.writeAsString('''#!/usr/bin/python3
import sys,pathlib,json
args=sys.argv[1:]
pathlib.Path(${jsonEncode('${root.path}/cli-arguments.json')}).write_text(json.dumps(args))
prompt=sys.stdin.read()
pathlib.Path(${jsonEncode(promptFile.path)}).write_text(prompt)
request=json.loads(prompt.split('<request_json>')[-1].split('</request_json>')[0])
reply=json.loads(pathlib.Path(${jsonEncode(response.path)}).read_text())
if ${describeImages ? 'True' : 'False'}:
    reply['image_descriptions']=[{'path':p,'description':'Verified fixture image shows a USB cable.'} for p in request['attached_image_paths']]
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(reply,ensure_ascii=False))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    final service = CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/schema.json'),
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
    final draft = await service.generate(
        conversation: (await db.conversation(buyer))!,
        database: db,
        batchEndMessageId: id,
        beforeSubmit: beforeSubmit,
        onMediaDependency: onMediaDependency);
    final prompt = await promptFile.readAsString();
    final request = jsonDecode(
            prompt.split('<request_json>').last.split('</request_json>').first)
        as Map;
    return (draft: draft, request: request, prompt: prompt);
  }

  void expectTextRequest(Map request, String id) {
    expect(request['text_only_timeline_inputs'], isTrue);
    expect(request['target_message_input_kinds'], {id: 'text'});
    expect(
        (request['target_customer_batch'] as List).map((m) => m['id']), [id]);
    expect(request['attached_image_paths'], isEmpty);
    expect(request['attached_video_frame_paths'], isEmpty);
    expect(request['image_analysis_required'], isFalse);
    expect(request['reply_media_dependency_keys'], isEmpty);
    expect(request['unresolved_customer_media'], isEmpty);
  }

  test('reported previous-colleague text reaches CLI despite pending unknown',
      () async {
    final unknown = await media(0);
    final id = await text('这是你们已签收了的，上一个客服给我说没有查到这个单子', 5);
    await begin(id);
    final dependencies = <bool>[];
    final result = await generate(id, onMediaDependency: dependencies.add);
    expectTextRequest(result.request, id);
    expect(result.draft.reply, contains('快递单号'));
    expect(dependencies, everyElement(isFalse));
    expect(jsonDecode(result.draft.rawJson)['reply_media_dependency_keys'],
        isEmpty);
    expect(await db.isMessageFormallyAnswered(buyer, unknown.id), isFalse);
  });

  for (final kind in ['image', 'video', 'unknown']) {
    test('text reference to pending $kind asks useful question without decode',
        () async {
      final previous = await media(0, kind: kind);
      final id = await text('上一张图片里的接线我没有看懂，另外USB线应插在哪里？', 5);
      await begin(id);
      final result = await generate(id, answer: 'USB线连接打印机和电脑。您具体不清楚的是哪一端的接口？');
      expectTextRequest(result.request, id);
      expect(result.draft.reply, contains('打印机和电脑'));
      expect(result.prompt, contains('Answer this text batch now'));
      expect(result.prompt, isNot(contains(previous.path)));
      expect(await db.isMessageFormallyAnswered(buyer, previous.id), isFalse);
    });
  }

  test(
      'completed historical description remains context without raw reanalysis',
      () async {
    const description =
        'Verified completed image shows a disconnected USB cable.';
    final previous =
        await media(0, kind: 'image', partial: false, description: description);
    await (await db.database).update(
        'automation_session_messages', {'response_state': 'answered'},
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, buyer, previous.id]);
    final id = await text('按照上张图片的情况，USB线应该怎么连接？', 5);
    await begin(id);
    final result = await generate(id, answer: '请将USB线连接到打印机和电脑的USB接口。');
    expectTextRequest(result.request, id);
    expect(result.prompt, contains(description));
    expect(result.prompt, isNot(contains(previous.path)));
  });

  test('authoritative text kind overrides stale frozen image receipt',
      () async {
    final stale = File('${root.path}/stale-preview.png');
    await stale.writeAsBytes([0]);
    final id = await text('USB线应该怎么连接电脑？', 5);
    db.staleImagePath = stale.path;
    await begin(id);
    final result = await generate(id, answer: '将USB线连接打印机和电脑，再安装对应驱动。');
    expectTextRequest(result.request, id);
    expect(result.prompt, isNot(contains(stale.path)));
    expect((result.request['target_customer_batch'] as List).single['media'],
        isNull);
  });

  test('actual owned image still requires its complete model analysis',
      () async {
    final original = await media(0, kind: 'image', partial: false);
    await begin(original.id);
    await expectLater(
        generate(original.id),
        throwsA(isA<CodexReplyException>().having((e) => e.message, 'message',
            contains('Customer media analysis incomplete'))));
    final result = await generate(original.id,
        answer: '图中USB线未连接，请先接好打印机和电脑。', describeImages: true);
    expect(result.request['text_only_timeline_inputs'], isNull);
    expect(result.request['attached_image_paths'], [original.path]);
    expect(result.request['image_analysis_required'], isTrue);
    expect(
        result.request['reply_media_dependency_keys'], contains(original.id));
    expect(result.draft.imageDescriptions, contains(original.path));
    expect(await db.isMessageFormallyAnswered(buyer, original.id), isFalse,
        reason:
            'Analysis alone does not complete customer work before delivery');
  });

  test('missing owned original rejects before CLI and preserves its message',
      () async {
    final original = await media(0, kind: 'image', partial: false);
    await begin(original.id);
    await File(original.path).delete();
    await expectLater(
        generate(original.id),
        throwsA(isA<CodexReplyMediaUnavailable>()
            .having((e) => e.messageIds, 'messageIds', [original.id]).having(
                (e) => e.stage, 'stage', 'before_generation')));
    expect(await File('${root.path}/request.txt').exists(), isFalse,
        reason: 'The CLI must not invent an answer without its owned image');
    expect(await db.isMessageFormallyAnswered(buyer, original.id), isFalse);
    expect(await db.unansweredWorkCounts(), {buyer: 1});
    expect(await (await db.database).query('generated_drafts'), isEmpty);
  });

  test('owned file URI is analysed and retains its original description key',
      () async {
    final original =
        await media(0, kind: 'image', partial: false, fileUri: true);
    await begin(original.id);
    final result = await generate(original.id,
        answer: '图中USB线未连接，请先接好打印机和电脑。', describeImages: true);
    expect(result.request['attached_image_paths'], [original.path]);
    expect(result.draft.imageDescriptions, contains(original.path));
    final arguments =
        jsonDecode(await File('${root.path}/cli-arguments.json').readAsString())
            as List;
    expect(arguments[arguments.indexOf('--image') + 1],
        Uri.parse(original.path).toFilePath());
    expect(
        result.request['reply_media_dependency_keys'][original.id], isNotEmpty);
  });

  test('owned original disappearing at submission is detected before CLI',
      () async {
    final original = await media(0, kind: 'image', partial: false);
    await begin(original.id);
    await expectLater(
        generate(original.id, beforeSubmit: () async {
          await File(original.path).delete();
          return null;
        }),
        throwsA(isA<CodexReplyMediaUnavailable>()
            .having((e) => e.messageIds, 'messageIds', [original.id]).having(
                (e) => e.stage, 'stage', 'before_cli_submit')));
    expect(await File('${root.path}/request.txt').exists(), isFalse);
    expect(await db.isMessageFormallyAnswered(buyer, original.id), isFalse);
    expect(await (await db.database).query('generated_drafts'), isEmpty);
  });

  test('missing earlier image does not prevent the new text answer', () async {
    final original = await media(0, kind: 'image', partial: false);
    await File(original.path).delete();
    final id = await text('USB线应该怎么连接电脑？', 5);
    await begin(id);
    final result = await generate(id, answer: '将USB线连接打印机和电脑，再安装对应驱动。');
    expectTextRequest(result.request, id);
    expect(result.draft.reply, contains('打印机和电脑'));
    expect(await db.isMessageFormallyAnswered(buyer, original.id), isFalse);
  });

  test('mixed owned image and text require analysis of that image only',
      () async {
    final oldUnknown = await media(0);
    final original = await media(2, kind: 'image', partial: false);
    final id = await text('图中这个接口应该怎么接USB线？', 5);
    await begin(id);
    await expectLater(
        generate(id),
        throwsA(isA<CodexReplyException>().having((e) => e.message, 'message',
            contains('Customer media analysis incomplete'))));
    final result = await generate(id,
        answer: '图中USB线连接打印机和电脑，再安装对应驱动。', describeImages: true);
    expect(result.request['target_message_input_kinds'],
        {original.id: 'media', id: 'text'});
    expect(result.request['attached_image_paths'], [original.path]);
    expect((result.request['reply_media_dependency_keys'] as Map).keys,
        [original.id]);
    expect(result.prompt, isNot(contains(oldUnknown.path)));
    expect(await db.isMessageFormallyAnswered(buyer, oldUnknown.id), isFalse);
  });

  test(
      'text arriving after the frozen request remains separate unanswered work',
      () async {
    final id = await text('USB线应该怎么连接电脑？', 5);
    final token = await begin(id);
    late String lateId;
    final result = await generate(id, answer: '将USB线连接打印机和电脑，再安装对应驱动。',
        beforeSubmit: () async {
      lateId = await text('驱动安装完成后怎样打印测试页？', 6);
      return null;
    });
    expectTextRequest(result.request, id);
    expect(result.prompt, isNot(contains(lateId)));
    final prepared = await db.prepareAutomaticDraft(buyer, result.draft);
    final saved = await db.saveAutomaticDraft(
        (await db.conversation(buyer))!.id, prepared,
        expectedUserId: buyer,
        expectedMessageId: id,
        generationToken: token,
        deliverable: true);
    expect(saved.queued, isTrue);
    final queued = (await db.nextReadyDelivery())!;
    final covered =
        jsonDecode(queued.draft.rawJson)['formal_response_message_ids'] as List;
    expect(covered, contains(id));
    expect(covered, isNot(contains(lateId)));
    expect(covered, isNot(contains('text-6')));
    expect(await db.isMessageFormallyAnswered(buyer, lateId), isFalse);
    expect(await db.unansweredWorkCounts(), {buyer: 2});
  });
}
