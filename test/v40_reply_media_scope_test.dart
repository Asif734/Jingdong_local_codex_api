import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late DateTime clock;
  late File requestFile;
  late File responseFile;
  late CodexReplyService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v40_reply_scope_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    clock = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    await db.beginAutomationSession(startedAt: clock);
    inventory = CustomerMediaInventory(db);
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    await File('${knowledge.path}/printer_kb.md').writeAsString(
        'Switch off the device before removing its ribbon. Use the supplied USB cable.');
    requestFile = File('${root.path}/request.json');
    responseFile = File('${root.path}/response.json');
    final cli = await File('${root.path}/controlled-cli.py')
        .writeAsString('''#!/usr/bin/python3
import sys,json,re,pathlib
args=sys.argv[1:]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
pathlib.Path(${jsonEncode(requestFile.path)}).write_text(json.dumps(request))
reply=json.loads(pathlib.Path(${jsonEncode(responseFile.path)}).read_text())
reply['image_descriptions']=[{'path':p,'description':'Complete controlled visual analysis of this supplied view.'} for p in request['attached_image_paths']]
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

  Future<void> response(String text) => responseFile.writeAsString(jsonEncode({
        'reply': text,
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': .99,
        'risk_level': 'low',
        'auto_send_allowed': false,
        'human_review_required': false,
        'risk_triggers': [],
        'used_record_ids': [],
        'required_slots': [],
        'actions': [],
        'attachments': [],
      }));

  CapturedConversation capture(String id, String body,
          {String? receipt, List<CapturedMedia> media = const []}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: clock = clock.add(const Duration(seconds: 1)),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                sender: 'buyer',
                sentAt: clock,
                observationTurnKey: id,
                mediaReceiptId: receipt,
                media: media,
                axPath: 'current AX customer / distinct incoming bubble $id')
          ]);

  Future<void> unbound() async {
    for (var i = 0; i < 3; i++) {
      await (await db.database).insert('media_capture_audit', {
        'observation_id': 'old-crop-$i',
        'evidence_id': 'old-frame-$i',
        'customer': 'buyer',
        'state': 'unbound',
        'updated_at_ms': clock.millisecondsSinceEpoch,
        'details': jsonEncode({
          'observationId': 'old-crop-$i',
          'evidenceId': 'old-frame-$i',
          'automationSessionId': db.currentAutomationSessionId,
          'capturedAt': clock.toIso8601String(),
          'observationGroupId': 'same-old-video',
          'reason': 'pixel_matched_same_chat_video_companion',
          'region': [.27, .24, .11, .18],
        }),
      });
    }
  }

  Future<void> nativeConfirmed(AiDraft draft) async {
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: draft.reply);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<(AiDraft, Map)> generate(String id) async {
    final conversation = (await db.conversation('buyer'))!;
    final token = (await db.beginGeneration(
        customer: 'buyer', pendingId: conversation.id, batchEndMessageId: id))!;
    expect(
        await db.generationInputsAnalysisReady('buyer', generationToken: token),
        isTrue);
    final draft = await service.generate(
        conversation: conversation, database: db, batchEndMessageId: id);
    final prepared = await db.prepareAutomaticDraft('buyer', draft);
    expect(
        await db.saveDraft(conversation.id, prepared,
            expectedMessageId: id, generationToken: token),
        1);
    await db.abandonGeneration('buyer', token);
    return (prepared, jsonDecode(await requestFile.readAsString()) as Map);
  }

  Future<(String, CapturedConversation)> readyVideo(String name,
      {int frameCount = 2, bool answered = true}) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: '$name-frame',
        occurrenceKey: '$name-arrival',
        observedAt: clock,
        senderAt: clock,
        slot: 0,
        region: [.27, .48, .11, .24],
        current: true);
    final id = '$name-video';
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: clock, senderAt: clock);
    final basic = await completedVideoFixture(root, name: name);
    final frames = <CapturedMedia>[basic[1]];
    for (var i = 1; i < frameCount - 1; i++) {
      final file =
          await File(basic[1].path).copy('${root.path}/$name-sample-$i.jpg');
      frames.add(CapturedMedia(
          type: 'image',
          path: file.path,
          captureSource: 'jd_video_frame_1fps',
          originalName: 'video_frame_${i.toString().padLeft(2, '0')}s.jpg'));
    }
    frames.add(basic[2]);
    final current = capture(id, '[Customer sent a video]',
        receipt: receipt, media: [basic[0], ...frames, basic[3]]);
    await db.saveCapture(current);
    await inventory.persist(current, verifiedAnchor: true);
    if (answered) {
      final draft = AiDraft.fromJson({
        'reply': 'Switch off the device before checking its paper feed.',
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
      }, mediaBaseUrl: Uri());
      final conversation = (await db.conversation('buyer'))!;
      expect(
          await db.saveDraft(conversation.id, draft, expectedMessageId: id), 1);
      await nativeConfirmed(draft);
    }
    return (id, current);
  }

  test('all unanswered texts remain work despite unrelated unbound captures',
      () async {
    await unbound();
    await db.saveCapture(capture('paper', 'What paper size should I use?'));
    await db.saveCapture(capture('cable', 'Which USB cable is supplied?'));
    await response('Use the supported paper size and the supplied USB cable.');
    final (draft, request) = await generate('cable');
    expect((request['target_customer_batch'] as List).map((m) => m['id']),
        ['paper', 'cable']);
    expect(request['current_media_reference_status'], isNull);
    expect(request['unbound_observations_are_context_only'], isTrue);
    expect(request['unbound_customer_media_observations'], hasLength(3));
    expect(request['unresolved_customer_media'], isEmpty);
    expect(jsonDecode(draft.rawJson)['reply_media_dependency_keys'], isEmpty);
    expect(jsonDecode(draft.rawJson)['formal_response_message_ids'],
        containsAll(['paper', 'cable']));
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    await nativeConfirmed(draft);
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await MediaCaptureAudit(db).pendingUnboundForCustomer('buyer'),
        hasLength(3),
        reason: 'No unsupported attribution of unknown captures');
  });

  for (final question in [
    'how many frame, you analyzed?',
    'how many frame was there?',
    'What should I do about the video?',
  ]) {
    test(
        'identified analysed media remains usable for real question: $question',
        () async {
      final (video, _) = await readyVideo('m880', frameCount: 16);
      await unbound();
      await db.saveCapture(capture('question', question));
      await response('Switch off the device before checking its ribbon.');
      final (draft, request) = await generate('question');
      expect(request['current_media_reference_status'], isNull);
      expect(request['attached_video_frame_paths'], hasLength(16));
      expect(request['attached_image_paths'], hasLength(17));
      expect(draft.imageDescriptions, hasLength(17));
      final dependencies =
          jsonDecode(draft.rawJson)['reply_media_dependency_keys'] as Map;
      expect(dependencies.keys, [video]);
      expect(jsonDecode(draft.rawJson)['formal_response_message_ids'],
          ['question']);
      expect(await db.hasUndeliveredDraft('buyer'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', 'question'), isFalse);
      await nativeConfirmed(draft);
      expect(await db.isMessageFormallyAnswered('buyer', 'question'), isTrue);
      expect(await db.unansweredWorkCounts(), isEmpty);
    });
  }

  test('only actual referenced card invalidates a completed answer', () async {
    final (first, _) = await readyVideo('first');
    final (second, secondCapture) = await readyVideo('second');
    await unbound();
    await db
        .saveCapture(capture('question', 'What does the first video show?'));
    await response('The supplied view shows the paper feed area.');
    final (draft, request) = await generate('question');
    final dependencies =
        jsonDecode(draft.rawJson)['reply_media_dependency_keys'] as Map;
    expect(dependencies.keys, [first]);
    expect(
        (request['attached_image_paths'] as List)
            .every((path) => (path as String).contains('/first-')),
        isTrue);
    final extra = await File(secondCapture.messages.single.media[1].path)
        .copy('${root.path}/second-extra.jpg');
    final changed = capture(
        second, '[Same second video, another decoded frame]',
        receipt: secondCapture.messages.single.mediaReceiptId,
        media: [
          ...secondCapture.messages.single.media,
          CapturedMedia(
              type: 'image',
              path: extra.path,
              captureSource: 'jd_video_frame_1fps')
        ]);
    await inventory.persist(changed,
        verifiedAnchor: true, currentTaskOnly: true);
    expect(await db.mediaContextCurrent('buyer', draft), isTrue);
    expect(await db.retireStaleMediaDraft('buyer'), isFalse);
    await nativeConfirmed(draft);
    expect(await db.isMessageFormallyAnswered('buyer', 'question'), isTrue);
  });

  test('later text does not hide an earlier unanswered media question',
      () async {
    final (video, _) = await readyVideo('m880');
    await unbound();
    await db
        .saveCapture(capture('video-question', 'What does the video show?'));
    await db
        .saveCapture(capture('cable-question', 'Which USB cable is supplied?'));
    await response(
        'The view shows the paper feed. Use the supplied USB cable.');
    final (draft, request) = await generate('cable-question');
    expect((request['target_customer_batch'] as List).map((m) => m['id']),
        ['video-question', 'cable-question']);
    expect(request['attached_video_frame_paths'], hasLength(2));
    expect(
        (jsonDecode(draft.rawJson)['reply_media_dependency_keys'] as Map).keys,
        [video]);
    expect(jsonDecode(draft.rawJson)['formal_response_message_ids'],
        containsAll(['video-question', 'cable-question']));
    await nativeConfirmed(draft);
    expect(await db.unansweredWorkCounts(), isEmpty);
    final records = (await db.customerMessageRecords('buyer'))
        .where((record) => record.stableId.endsWith('-question'))
        .toList();
    expect(records, hasLength(2));
    expect(records.every((record) => record.status == 'answered'), isTrue);
    expect(records.map((record) => record.repliedAt).toSet(), hasLength(1));
  });

  test('a current real video keeps full analysis and precise dependency',
      () async {
    await readyVideo('older');
    final (current, _) =
        await readyVideo('current', frameCount: 9, answered: false);
    await unbound();
    await response('Switch off the device before checking the paper feed.');
    final (draft, request) = await generate(current);
    expect(request['attached_video_frame_paths'], hasLength(9));
    expect(request['attached_image_paths'], hasLength(10));
    expect(draft.imageDescriptions, hasLength(10));
    expect(
        (jsonDecode(draft.rawJson)['reply_media_dependency_keys'] as Map).keys,
        [current]);
    expect((request['target_customer_batch'] as List).single['id'], current);
    await nativeConfirmed(draft);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  for (final lateAdmission in [false, true]) {
    test(
        'leased text references earlier-received media; late admission=$lateAdmission',
        () async {
      Future<String> pendingVideo(String name, {DateTime? receivedAt}) async {
        final received =
            receivedAt ?? (clock = clock.add(const Duration(seconds: 1)));
        final receipt = await inventory.observe(
            customer: 'buyer',
            evidenceId: '$name-frame',
            occurrenceKey: '$name-arrival',
            observedAt: received,
            senderAt: received,
            slot: 0,
            region: [.27, .48, .11, .24],
            current: true);
        await inventory.classify(receipt, 'video');
        await admitFixtureMedia(db,
            receiptId: receipt,
            messageId: name,
            receivedAt: received,
            senderAt: received);
        return name;
      }

      const parent = 'already-received-video';
      final earlierReceived = clock.add(const Duration(seconds: 1));
      if (lateAdmission) {
        clock = clock.add(const Duration(seconds: 2));
      } else {
        await pendingVideo(parent);
      }
      await db
          .saveCapture(capture('question', 'Please check the video I sent.'));
      final conversation = (await db.conversation('buyer'))!;
      final claimed = await db.beginGeneration(
          customer: 'buyer',
          pendingId: conversation.id,
          batchEndMessageId: 'question');
      late final String token;
      if (lateAdmission) {
        token = claimed!;
      } else {
        // Normal v44 flow must stop before CLI for this known unready input.
        // Preserve the original service/save safety regression by explicitly
        // injecting the older text-only lease that this test investigated.
        expect(claimed, isNull);
        expect(await requestFile.exists(), isFalse);
        expect(await db.generationDue('buyer'), isFalse);
        token = 'fault-injected-v40-text-only-lease';
        final sql = await db.database;
        final work = (await sql.query('automation_session_messages',
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [
              db.currentAutomationSessionId,
              'buyer',
              'question'
            ]))
            .single;
        final document = (await (await db.history).read('buyer'))!;
        final message = (document['messages'] as List)
            .cast<Map>()
            .singleWhere((m) => m['id'] == 'question');
        await sql.transaction((txn) async {
          await txn.update('pending_customers', {'generation_token': token},
              where: 'id=? AND user_id=?',
              whereArgs: [conversation.id, 'buyer']);
          await txn.insert('automation_reply_inputs', {
            'session_id': db.currentAutomationSessionId,
            'user_id': 'buyer',
            'owner_id': token,
            'message_id': 'question',
            'message_revision': work['work_revision'],
            'message_json': jsonEncode({
              ...message,
              'reply_material_input_key':
                  ConversationFileStore.materialInputKey(message),
            }),
          });
        });
      }
      expect(
          (await db.generationMessages('buyer'))
              .where((message) => message['direction'] == 'incoming')
              .map((message) => message['id']),
          ['question']);
      if (lateAdmission) {
        // Its immutable frame was received before the question, but text
        // registration took priority over processing/admitting this media.
        await pendingVideo(parent, receivedAt: earlierReceived);
        final ledger = await (await db.database).query(
            'automation_session_messages',
            columns: ['rowid', 'message_id', 'activated_at_ms'],
            where: 'session_id=? AND user_id=?',
            whereArgs: [db.currentAutomationSessionId, 'buyer']);
        final mediaRow =
            ledger.singleWhere((row) => row['message_id'] == parent);
        final textRow =
            ledger.singleWhere((row) => row['message_id'] == 'question');
        expect(mediaRow['rowid'] as int, greaterThan(textRow['rowid'] as int));
        expect(mediaRow['activated_at_ms'] as int,
            lessThan(textRow['activated_at_ms'] as int));
      }
      final later = await pendingVideo('later-unrelated-video');
      await unbound();
      await response('The video content is still being retrieved.');
      final output = jsonDecode(await responseFile.readAsString()) as Map;
      output['reply_purpose'] = 'media_status';
      await responseFile.writeAsString(jsonEncode(output));
      final draft = await service.generate(
          conversation: conversation,
          database: db,
          batchEndMessageId: 'question');
      final request = jsonDecode(await requestFile.readAsString()) as Map;
      expect(
          (request['target_customer_batch'] as List).single['id'], 'question');
      expect(
          (request['received_customer_media_inventory'] as List)
              .map((item) => item['messageId']),
          [parent]);
      expect(jsonEncode(request['conversation']), contains(parent));
      expect(jsonEncode(request['conversation']), isNot(contains(later)));
      expect(request['attached_image_paths'], isEmpty);
      expect(request['unbound_observations_are_context_only'], isTrue);
      expect(jsonDecode(draft.rawJson)['reply_media_dependency_keys'],
          {parent: ''});
      final prepared = await db.prepareAutomaticDraft('buyer', draft);
      expect(
          jsonDecode(prepared.rawJson)['formal_response_message_ids'], isEmpty);
      expect(
          await db.saveDraft(conversation.id, prepared,
              expectedMessageId: 'question', generationToken: token),
          1);
      await db.abandonGeneration('buyer', token);
      expect(await db.hasUndeliveredDraft('buyer'), isFalse);
      expect(await db.isMessageFormallyAnswered('buyer', 'question'), isFalse);
      expect(await db.isMessageFormallyAnswered('buyer', parent), isFalse);
      expect(await db.unansweredWorkCounts(), {'buyer': 3});
    });
  }
}
