import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/evidence_coverage.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/response_timing_policy.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  final at = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true)
      .subtract(const Duration(minutes: 2));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_inventory_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    inventory = CustomerMediaInventory(db);
    await inventory.beginRun(at.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<String> observe(
          {String customer = 'buyer',
          int second = 0,
          int slot = 0,
          bool current = true}) =>
      inventory.observe(
          customer: customer,
          evidenceId: 'frame-$customer-$second-$slot',
          observedAt: at.add(Duration(seconds: second)),
          senderAt: at.add(Duration(seconds: second)),
          slot: slot,
          region: [.3, .4, .2, .2],
          current: current);
  Future<CapturedConversation> media(String id, String receipt,
      {int second = 0, bool preview = false, String customer = 'buyer'}) async {
    final original = File('${root.path}/$id.${preview ? 'png' : 'mp4'}');
    await original.writeAsBytes([1]);
    final frame = File('${root.path}/$id-frame.jpg');
    await frame.writeAsBytes([2]);
    return CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        capturedAt: at.add(Duration(seconds: second)),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: '[media]',
              sentAt: at.add(Duration(seconds: second)),
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
                          captureSource: 'jd_video_frame_1fps',
                          description: 'Already analysed paper movement.')
                    ])
        ]);
  }

  test(
      'late verified preview binds existing ready original without downgrading',
      () async {
    final first = await observe();
    await inventory.classify(first, 'video', fingerprint: '0101010101010101');
    await inventory.persist(await media('original', first),
        verifiedAnchor: true);
    final sql = await db.database;
    final row = (await sql.query('customer_media_items',
            where: 'item_id=?', whereArgs: [first]))
        .single;
    await sql.insert('customer_media_items', {
      ...row,
      'item_id': 'late-card',
      'kind': 'video',
      'state': 'pending',
      'canonical_id': null,
      'message_id': null,
      'aliases_json': '[]'
    });
    final aliases = await inventory.persist(
        await media('late', 'late-card', preview: true),
        verifiedAnchor: true);
    expect(aliases, contains('late'));
    expect(await inventory.canonicalMessage('buyer', 'late'), 'original');
    final active =
        await sql.query('customer_media_items', where: 'canonical_id IS NULL');
    expect(active, hasLength(1));
    expect(active.single['state'], 'ready');
  });

  test('late preview at another slot is not guessed to be the original',
      () async {
    final first = await observe();
    await inventory.persist(await media('original', first),
        verifiedAnchor: true);
    final other = await observe(slot: 1);
    await inventory.persist(await media('late', other, preview: true),
        verifiedAnchor: true);
    expect(await inventory.canonicalMessage('buyer', 'late'), isNull);
  });

  test(
      'a preview using an already canonical receipt becomes an alias of the ready original',
      () async {
    final receipt = await observe();
    final original = await media('original', receipt);
    await db.saveCapture(original);
    await inventory.persist(original, verifiedAnchor: true);
    await (await db.database).insert(
        'answered_cursors', {'user_id': 'buyer', 'message_id': 'original'});
    final late = await media('late', receipt, preview: true);
    await db.saveCapture(late);
    final aliases = await inventory.persist(late, verifiedAnchor: true);
    expect(aliases, contains('late'));
    expect(await inventory.canonicalMessage('buyer', 'late'), 'original');
    await db.retireMediaPreviews('buyer', aliases);
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    expect(await db.answeredMessageId('buyer'), 'late');
  });

  test('canonical preview retirement never covers a real new customer question',
      () async {
    final receipt = await observe();
    final original = await media('original', receipt);
    await db.saveCapture(original);
    await inventory.persist(original, verifiedAnchor: true);
    await (await db.database).insert(
        'answered_cursors', {'user_id': 'buyer', 'message_id': 'original'});
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'real-question',
              direction: 'incoming',
              body: 'How do I fix this?',
              sentAt: at,
              axPath: 'fixture')
        ]));
    final late = await media('late', receipt, preview: true);
    await db.saveCapture(late);
    final aliases = await inventory.persist(late, verifiedAnchor: true);
    await db.retireMediaPreviews('buyer', aliases);
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.answeredMessageId('buyer'), 'original');
  });

  Future<void> save(CapturedConversation c) async {
    await db.saveCapture(c);
    await inventory.persist(c);
  }

  Future<List<Map<String, dynamic>>> context(
      {String customer = 'buyer', DateTime? boundary}) async {
    final d = await (await db.history).read(customer);
    return inventory.context(customer,
        history: (d?['messages'] as List? ?? []).cast<Map<String, dynamic>>(),
        before: boundary ?? at.add(const Duration(minutes: 1)));
  }

  test('recorded first video survives the 8.249 millisecond clock boundary',
      () {
    final d = jsonDecode(
        File('test/fixtures/video_watermarks/first_video_seconds_boundary.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final i = OcrInspection.fromMap(d);
    final regions = const OcrImageCandidateSelector().select(i, 'buyer_video',
        allowUnlabeledLatestImage: true, includeTextDense: true);
    expect(CustomerMediaInventory.isReference('请看看上一段'), isTrue);
    expect(regions, hasLength(1));
    final sender =
        const OcrCaptureExtractor().incomingClockAbove(i, regions.single.y)!;
    final floor = DateTime.parse('2026-11-03T03:53:33.008249Z')
        .subtract(EvidenceCoverage.overlap);
    expect(floor.difference(sender).inMicroseconds, 8249);
    expect(EvidenceCoverage.mediaOverlapsWindow(sender, floor), isTrue);
    expect(
        EvidenceCoverage.mediaOverlapsWindow(
            sender, floor.add(const Duration(seconds: 1))),
        isFalse);
    expect(EvidenceCoverage.mediaOverlapsWindow(null, floor), isTrue);
  });
  test('pending cards survive restart before acquisition or a filtered window',
      () async {
    final id = await observe(current: false);
    await db.close();
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    inventory = CustomerMediaInventory(db);
    final rows = await (await db.database).query('customer_media_items');
    expect(rows.single['item_id'], id);
    expect(rows.single['state'], 'historical');
    expect(await context(), isEmpty,
        reason:
            'A retained unverified rectangle is not a confirmed media receipt.');
  });
  test(
      'two videos at distinct clocks retain separate receipts and availability',
      () async {
    final first = await observe();
    await inventory.classify(first, 'video');
    final second = await observe(second: 65);
    await save(await media('video-two', second, second: 65));
    final rows = await context(boundary: at.add(const Duration(minutes: 2)));
    expect(rows, hasLength(2));
    expect(rows.first['state'], 'pending');
    expect(rows.last['state'], 'ready');
    final answer = CustomerMediaInventory.receiptReply(
        'you get how many video?', rows,
        english: true)!;
    expect(answer, contains('2 video messages'));
    expect(answer, contains('1 video is available'));
    expect(answer, contains('not yet available'));
    final latestReceipt =
        CustomerMediaInventory.receiptReply('视频不是发你了吗', rows, english: false)!;
    expect(latestReceipt, contains('1条视频消息'));
    expect(latestReceipt, isNot(contains('2条视频消息')));
  });
  test('same-second different slots and different customers never merge',
      () async {
    final a = await observe();
    final b = await observe(slot: 1);
    final c = await observe(customer: 'Buyer');
    expect({a, b, c}, hasLength(3));
    await save(await media('a', a));
    await save(await media('b', b));
    expect(await context(), hasLength(2));
    final other = await (await db.database).query('customer_media_items',
        where: 'customer=?', whereArgs: ['Buyer']);
    expect(other, hasLength(1));
    expect(other.single['media_json'], '[]');
    await expectLater(context(customer: 'Buyer'), throwsStateError);
  });
  test('preview upgrades in place and preserves both message aliases',
      () async {
    final id = await observe();
    await inventory.classify(id, 'video', fingerprint: 'same');
    await save(await media('preview', id, preview: true));
    expect(
        await inventory.previewWait(
            'buyer', 'preview', at.add(const Duration(seconds: 2))),
        const Duration(seconds: 6));
    final original = await media('original', id);
    await db.saveCapture(original);
    expect(await inventory.persist(original), ['preview']);
    final rows = await context();
    expect(rows, hasLength(1));
    expect(rows.single['messageId'], 'original');
    expect(await inventory.canonicalMessage('buyer', 'preview'), 'original');
    expect(
        await inventory.previewWait(
            'buyer', 'original', at.add(const Duration(seconds: 3))),
        Duration.zero);
    expect(await inventory.persist(original), isEmpty);
  });
  test('different thumbnails at a recycled clock/slot cannot replace a preview',
      () async {
    final id = await observe();
    await inventory.classify(id, 'video', fingerprint: 'old');
    await save(await media('preview', id, preview: true));
    final other =
        await inventory.classify(id, 'video', fingerprint: 'different');
    expect(other, isNot(id));
    await save(await media('another-video', other));
    final rows = await context();
    expect(rows, hasLength(2));
    expect(rows.every((m) => m['identityAmbiguous'] == true), isTrue);
    expect(await inventory.canonicalMessage('buyer', 'preview'), isNull);
    final uncertain = CustomerMediaInventory.receiptReply(
        'you get how many videos?', rows,
        english: true)!;
    expect(uncertain, contains('cannot confirm'));
    expect(uncertain, isNot(matches(RegExp(r'\b\d+ video messages?'))),
        reason: 'Ambiguous thumbnails must never become a confirmed count');
    expect(uncertain, isNot(contains('content is available for analysis')));
  });
  test('frozen request does not expose an original from a later batch',
      () async {
    final id = await observe();
    await save(await media('original', id));
    final rows = await inventory.context('buyer',
        history: [], before: at.add(const Duration(seconds: 1)));
    expect(rows.single['availableMedia'], isEmpty);
    expect(rows.single['analysisAvailable'], isFalse);
  });
  test('a deleted frame is pending evidence, not available analysis', () async {
    final id = await observe();
    await save(await media('original', id));
    await File('${root.path}/original-frame.jpg').delete();
    final rows = await context();
    expect(rows.single['analysisAvailable'], isFalse);
    expect(rows.single['state'], 'awaiting_available_files');
  });
  for (final state in ['ready', 'sending', 'delivery_unknown', 'quarantined']) {
    test('media upgrade retires only a safe preview draft: $state', () async {
      final id = await observe();
      await save(await media('preview', id, preview: true));
      final conversation = (await db.conversations()).single;
      const draft = AiDraft(
          reply: 'Pending preview reply',
          decision: 'draft',
          confidence: 1,
          riskLevel: 'low',
          model: 'test',
          usedRecordIds: [],
          actions: [],
          attachments: [],
          rawJson: '{}');
      await db.saveDraft(conversation.id, draft, expectedMessageId: 'preview');
      final sql = await db.database;
      await sql.update('generated_drafts', {'delivery_state': state});
      await db.retireMediaPreviews('buyer', ['preview']);
      expect(await sql.query('generated_drafts'),
          state == 'ready' ? isEmpty : hasLength(1));
      expect(await db.pendingMessageId('buyer'),
          state == 'ready' ? 'preview' : isNull);
      expect(await db.isBatchUnanswered('buyer', 'preview'), isTrue);
    });
  }
  test('cancelling an old media generation cannot release a newer lease',
      () async {
    final id = await observe();
    await save(await media('preview', id, preview: true));
    final conversation = (await db.conversations()).single;
    final old = await db.beginGeneration(
        customer: 'buyer',
        pendingId: conversation.id,
        batchEndMessageId: 'preview');
    final replacement = await db.beginGeneration(
        customer: 'buyer',
        pendingId: conversation.id,
        batchEndMessageId: 'preview');
    expect(old, isNotNull);
    expect(replacement, isNot(old));
    await db.abandonGeneration('buyer', old!);
    final row = (await (await db.database).query('pending_customers')).single;
    expect(row['generation_token'], replacement);
    await db.abandonGeneration('buyer', replacement!);
    expect(
        (await (await db.database).query('pending_customers'))
            .single['generation_token'],
        isNull);
  });

  test(
      'a radically changed loading-cover remains ambiguous without card linkage',
      () async {
    final id = await observe();
    await inventory.classify(id, 'video', fingerprint: 'fffffff1f1f0f0f0');
    await save(await media('loading-preview', id, preview: true));
    final rendered =
        await inventory.classify(id, 'video', fingerprint: 'ff7f3f1e16040400');
    final original = await media('owned-original', rendered);
    await db.saveCapture(original);
    final upgraded = await inventory.persist(original, verifiedAnchor: true);
    expect(upgraded, isNot(contains('loading-preview')));
    final rows = await context();
    expect(rows, hasLength(2));
    expect(rows.any((row) => row['identityAmbiguous'] == true), isTrue);
    expect(
        rows.singleWhere(
            (row) => row['messageId'] == 'owned-original')['state'],
        'ready');
    expect(
        await inventory.canonicalMessage('buyer', 'loading-preview'), isNull);
  });
  test('three-bit thumbnail drift is an observation, not another video',
      () async {
    final id = await observe();
    await inventory.classify(id, 'video', fingerprint: 'f9e1fdfbfde10107');
    expect(
        await inventory.classify(id, 'video', fingerprint: 'e1e0fdfbfde10107'),
        id);
    expect(
        await (await db.database).query('customer_media_items'), hasLength(1));
  });
  test('same original stored under v22 receipt aliases is counted once',
      () async {
    final id = await observe();
    await save(await media('original', id));
    final sql = await db.database;
    final row =
        (await sql.query('customer_media_items', where: "state='ready'"))
            .single;
    await sql.insert('customer_media_items',
        {...row, 'item_id': 'v22-duplicate', 'canonical_id': null});
    final rows = await context();
    expect(rows, hasLength(1));
    expect(rows.single['messageId'], 'original');
    expect(
        (await sql.query('customer_media_items',
            where: "state='ready' AND canonical_id IS NULL")),
        hasLength(1));
  });
  test('two different originals at the same sender second are never fused',
      () async {
    final id = await observe();
    final a = await media('original-a', id);
    await db.saveCapture(a);
    await inventory.persist(a, verifiedAnchor: true);
    final b = await media('original-b', id);
    await db.saveCapture(b);
    await inventory.persist(b, verifiedAnchor: true);
    final rows = await context();
    expect(rows, hasLength(2));
    expect(
        rows.map((m) => m['messageId']).toSet(), {'original-a', 'original-b'});
  });
  test('frame-count questions do not substitute an older readable video',
      () async {
    final ready = await observe();
    await save(await media('old-video', ready));
    final pending = await observe(second: 10);
    await inventory.classify(pending, 'video');
    final items = await context();
    final answer = CustomerMediaInventory.receiptReply(
        'how many frames?', items,
        english: true)!;
    expect(answer, contains('not available'));
    expect(answer, isNot(contains('1 sampled')));
  });
  test('late old-batch reply cannot satisfy a newer question by timestamp', () {
    final reply = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'generated_reply',
      'delivery_status': 'submitted',
      'body': 'Old answer',
      'sent_at': at.add(const Duration(seconds: 39)).toIso8601String(),
      'answered_batch_end_id': 'old-model'
    };
    expect(
        ResponseTimingPolicy.isReplyForBatch(reply,
            batchEndMessageId: 'new-video-question', isHolding: false),
        isFalse);
    expect(
        ResponseTimingPolicy.isReplyForBatch(reply,
            batchEndMessageId: 'old-model', isHolding: false),
        isTrue);
    reply['delivery_status'] = 'delivery_unknown';
    expect(
        ResponseTimingPolicy.isReplyForBatch(reply,
            batchEndMessageId: 'old-model', isHolding: false),
        isFalse);
  });
  test(
      'real reply request reattaches both previously analysed clips on followup',
      () async {
    final photo = File('${root.path}/model-photo.jpg');
    await photo.writeAsBytes([3]);
    await save(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at.subtract(const Duration(seconds: 1)),
        messages: [
          CapturedMessage(
              stableId: 'model-photo',
              direction: 'incoming',
              body: '[image]',
              sentAt: at.subtract(const Duration(seconds: 1)),
              axPath: 'verified-native',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: photo.path,
                    captureSource: 'jd_image_cache',
                    description: 'Already analysed model label.')
              ])
        ]));
    final first = await observe();
    await save(await media('first-video', first));
    final second = await observe(second: 10);
    await save(await media('second-video', second, second: 10));
    // Prior clips have already been answered; this is a new customer turn.
    await (await db.database).insert(
        'answered_cursors', {'user_id': 'buyer', 'message_id': 'second-video'});
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at.add(const Duration(seconds: 20)),
        messages: [
          CapturedMessage(
              stableId: 'question',
              direction: 'incoming',
              body:
                  'Compare the previous video with this video, is the paper moving?',
              sentAt: at.add(const Duration(seconds: 20)),
              axPath: 'fixture')
        ]));
    final workspace = await Directory('${root.path}/workspace').create();
    final kb = await Directory('${root.path}/knowledge').create();
    await File('${kb.path}/test_support_kb.md').writeAsString(
        'Turn off the printer before touching its internal components.');
    final input = File('${root.path}/input.txt');
    final argsLog = File('${root.path}/args.txt');
    final cli = File('${root.path}/fake-cli.sh');
    await cli.writeAsString('''#!/usr/bin/python3
import sys,json,pathlib
args=sys.argv[1:]
pathlib.Path(${jsonEncode(argsLog.path)}).write_text('\\n'.join(args))
output=args[args.index('--output-last-message')+1]
pathlib.Path(${jsonEncode(input.path)}).write_text(sys.stdin.read())
paths=[args[i+1] for i,arg in enumerate(args[:-1]) if arg=='--image']
reply={'reply':'Turn off the printer before touching its internal components.','decision':'draft','confidence':0.9,'risk_level':'low','used_record_ids':['test_support_kb.md'],'actions':[],'attachments':[],'auto_send_allowed':False,'image_descriptions':[{'path':path,'description':'Controlled review of this supplied clip frame.'} for path in paths]}
pathlib.Path(output).write_text(json.dumps(reply))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    final service = CodexReplyService(
        executable: cli.path,
        workspace: workspace,
        knowledgeDirectory: kb,
        outputSchema: File('${root.path}/schema.json'));
    final comparisonDraft = await service.generate(
        conversation: (await db.conversations()).single,
        database: db,
        batchEndMessageId: 'question');
    final request = await input.readAsString();
    final arguments = await argsLog.readAsLines();
    expect(arguments, contains('${root.path}/first-video-frame.jpg'));
    expect(arguments, contains('${root.path}/second-video-frame.jpg'));
    expect(request, contains('${root.path}/first-video-frame.jpg'));
    expect(request, contains('${root.path}/second-video-frame.jpg'));
    expect(request, contains('received_customer_media_inventory'));
    expect(arguments, isNot(contains(photo.path)));
    // Generation alone does not answer this comparison. Finish the earlier
    // task with native send evidence before asserting a new first-only turn.
    expect(
        await db.saveDraft(
            (await db.conversation('buyer'))!.id, comparisonDraft,
            expectedMessageId: 'question'),
        1);
    final comparisonAttempt = await db.beginDeliveryAttempt(
        userId: 'buyer', reply: comparisonDraft.reply);
    await File(comparisonAttempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': comparisonAttempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.answeredMessageId('buyer'), 'question');
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at.add(const Duration(seconds: 30)),
        messages: [
          CapturedMessage(
              stableId: 'first-question',
              direction: 'incoming',
              body: 'Please explain the first video.',
              sentAt: at.add(const Duration(seconds: 30)),
              axPath: 'fixture')
        ]));
    await service.generate(
        conversation: (await db.conversations()).single,
        database: db,
        batchEndMessageId: 'first-question');
    final firstArguments = await argsLog.readAsLines();
    expect(firstArguments, contains('${root.path}/first-video-frame.jpg'));
    expect(
        firstArguments, isNot(contains('${root.path}/second-video-frame.jpg')));
    expect(firstArguments, isNot(contains(photo.path)));
    await db.saveCapture(CapturedConversation(
        stableKey: 'unread-video',
        customerName: 'unread-video',
        customerExternalId: 'unread-video',
        capturedAt: at.add(const Duration(seconds: 40)),
        messages: [
          CapturedMessage(
              stableId: 'video-question',
              direction: 'incoming',
              body: 'Can you inspect the video I sent?',
              sentAt: at.add(const Duration(seconds: 40)),
              axPath: 'fixture')
        ]));
    final withoutFile = await service.generate(
        conversation: (await db.conversations())
            .firstWhere((c) => c.userId == 'unread-video'),
        database: db,
        batchEndMessageId: 'video-question');
    expect(withoutFile.mediaContextRevision, isNull,
        reason:
            'Unowned capture context must not invent a media dependency for a real question.');
    expect(jsonDecode(withoutFile.rawJson)['reply_media_dependency_keys'],
        isEmpty);
    expect(await input.readAsString(), contains('video-question'));
  });
}
