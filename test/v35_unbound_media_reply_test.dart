import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'helpers/media_admission_fixture.dart';
import 'helpers/completed_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late File cli;
  late File requestFile;
  late File replyFile;
  late DateTime at;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v35_unbound_reply_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    at = DateTime.now().toUtc();
    await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(minutes: 5)));
    inventory = CustomerMediaInventory(db);
    await inventory.beginRun(at.subtract(const Duration(minutes: 5)));
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/setup_kb.md').writeAsString(
        'Controlled test knowledge: answer verified setup text while the new '
        'attachment is pending. Never substitute an earlier printer video.');
    cli = File('${root.path}/controlled-cli.sh');
    requestFile = File('${root.path}/request.txt');
    replyFile = File('${root.path}/reply.json');
    await replyFile.writeAsString(jsonEncode({
      'reply':
          'The readable content of your latest video has not yet been confirmed. Please keep the device powered off before checking the card slot.',
      'decision': 'draft',
      'reply_purpose': 'media_status',
      'confidence': .9,
      'risk_level': 'low',
      'auto_send_allowed': false,
      'used_record_ids': <String>[],
      'actions': <Object>[],
      'attachments': <Object>[],
    }));
    // Only records the request and returns the fixed fixture; no real CLI.
    await cli.writeAsString('''#!/usr/bin/python3
import sys,json,pathlib
args=sys.argv[1:]
output=args[args.index('--output-last-message')+1]
pathlib.Path(${jsonEncode(requestFile.path)}).write_text(sys.stdin.read())
reply=json.loads(pathlib.Path(${jsonEncode(replyFile.path)}).read_text())
paths=[args[i+1] for i,arg in enumerate(args[:-1]) if arg=='--image']
reply['image_descriptions']=[{'path':path,'description':'Controlled analysis of this supplied current input.'} for path in paths]
pathlib.Path(output).write_text(json.dumps(reply))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedConversation capture(String id, String body,
          {DateTime? sentAt,
          String? receipt,
          List<CapturedMedia> media = const []}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now().toUtc(),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                sentAt: sentAt ?? DateTime.now().toUtc(),
                axPath: 'controlled AX fixture',
                mediaReceiptId: receipt,
                media: media)
          ]);

  Future<String> readyVideo(String name, DateTime senderAt) async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: '$name-frame',
        observedAt: senderAt,
        senderAt: senderAt,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: '$name-video',
        receivedAt: senderAt,
        senderAt: senderAt);
    await inventory.classify(receipt, 'video');
    final current = capture('$name-video', '[Customer sent video]',
        sentAt: senderAt,
        receipt: receipt,
        media: await completedVideoFixture(root, name: name));
    await db.saveCapture(current);
    await inventory.persist(current);
    return '$name-video';
  }

  Future<AiDraft> generate(String end) async => CodexReplyService(
          executable: cli.path,
          workspace: Directory('${root.path}/workspace'),
          knowledgeDirectory: Directory('${root.path}/knowledge'),
          outputSchema: File('${root.path}/reply.schema.json'),
          timeout: const Duration(seconds: 5),
          capacityRetryDelays: const [])
      .generate(
          conversation: (await db.conversation('buyer'))!,
          database: db,
          batchEndMessageId: end);

  Future<Map<String, dynamic>> request() async {
    final text = await requestFile.readAsString();
    final match = RegExp(r'<request_json>\s*([\s\S]*?)\s*</request_json>')
        .firstMatch(text)!;
    return jsonDecode(match.group(1)!) as Map<String, dynamic>;
  }

  Future<String> receiptFor(String messageId) async {
    final history = await (await db.history).read('buyer');
    final message = (history!['messages'] as List)
        .whereType<Map>()
        .singleWhere((message) => message['id'] == messageId);
    return message['media_receipt_id']! as String;
  }

  Future<void> nativeConfirmed(String reply) async {
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: reply);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  test(
      'unbound capture does not replace identified media; exact parent still required',
      () async {
    final old = await readyVideo(
        'old-printer', at.subtract(const Duration(minutes: 2)));
    final conversation = (await db.conversation('buyer'))!;
    final answered = AiDraft.fromJson({
      'reply': 'Check the paper feed lever.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
    }, mediaBaseUrl: Uri());
    expect(
        await db.saveDraft(conversation.id, answered, expectedMessageId: old),
        1);
    await nativeConfirmed(answered.reply);

    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'new-unbound-video',
      'evidence_id': 'new-video-no-header',
      'customer': 'buyer',
      'state': 'unbound',
      'updated_at_ms': at.millisecondsSinceEpoch,
      'details': jsonEncode({
        'observationId': 'new-unbound-video',
        'evidenceId': 'new-video-no-header',
        'automationSessionId': db.currentAutomationSessionId,
        'capturedAt': at.toIso8601String(),
        'region': [.3, .3, .2, .2],
        'reason': 'play_overlay_without_visible_sender_header',
      }),
    });
    final audit = MediaCaptureAudit(db, record: (_, __) {});
    await audit.resolveStoredReceipt('buyer', await receiptFor(old));
    expect(await audit.captureResolved('new-unbound-video'), isFalse,
        reason: 'An earlier ready clip cannot resolve the unowned card');
    await replyFile.writeAsString(jsonEncode({
      'reply':
          'The identified video shows the paper feed. Switch off the printer before adjusting it.',
      'decision': 'draft',
      'reply_purpose': 'substantive',
      'confidence': .9,
      'risk_level': 'low',
      'auto_send_allowed': false,
      'used_record_ids': <String>[],
      'actions': <Object>[],
      'attachments': <Object>[],
    }));
    await db
        .saveCapture(capture('received-question', 'What does the video show?'));
    final token = (await db.beginGeneration(
        customer: 'buyer',
        pendingId: (await db.conversation('buyer'))!.id,
        batchEndMessageId: 'received-question'))!;
    final draft = await generate('received-question');

    expect(draft.model, isNot('local-media-receipt'),
        reason: 'An ordinary question uses the complete identified context');
    final prompt = await request();
    expect(prompt['current_media_reference_status'], isNull);
    expect(prompt['unbound_observations_are_context_only'], isTrue);
    expect(prompt['unbound_customer_media_observations'], hasLength(1));
    expect(prompt['attached_video_frame_paths'], hasLength(2));
    expect(prompt['attached_image_paths'], hasLength(3));
    expect((prompt['target_customer_batch'] as List).map((m) => m['id']),
        ['received-question']);
    expect(await db.isMessageFormallyAnswered('buyer', 'received-question'),
        isFalse);
    expect(draft.mediaContextRevision, isNotNull);

    final prepared = await db.prepareAutomaticDraft('buyer', draft);
    expect(
        await db.saveDraft((await db.conversation('buyer'))!.id, prepared,
            expectedMessageId: 'received-question', generationToken: token),
        1,
        reason:
            'The real question is answered from its own identified context');
    await db.abandonGeneration('buyer', token);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    expect(await (await db.database).query('generated_drafts'), hasLength(1));
    final readyDraft = (await (await db.database).query('generated_drafts',
            where: 'user_id=?', whereArgs: ['buyer']))
        .single;
    expect(readyDraft['batch_end_message_id'], 'received-question');
    expect(await db.isMessageFormallyAnswered('buyer', 'received-question'),
        isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1},
        reason:
            'An unresolved observation is not another business; the actual reference question remains pending');
    await nativeConfirmed(prepared.reply);
    expect(await db.isMessageFormallyAnswered('buyer', 'received-question'),
        isTrue);

    final actual = await readyVideo('new-time-card', at);
    final actualReceipt = await receiptFor(actual);
    await audit.resolveStoredReceipt('buyer', actualReceipt);
    expect(await audit.captureResolved('new-unbound-video'), isFalse,
        reason:
            'Even a new complete video cannot clear an observation before exact ownership is established');
    // This fixture now supplies the explicit same-card attribution that the
    // native capture flow proves before binding an observation to its parent.
    await audit.bindParent('new-unbound-video',
        receiptId: actualReceipt, messageId: actual);
    await audit.resolveStoredReceipt('buyer', actualReceipt);
    expect(await audit.captureResolved('new-unbound-video'), isTrue);
    final resolved = (await (await db.database).query('media_capture_audit',
            where: 'observation_id=?', whereArgs: ['new-unbound-video']))
        .single;
    expect(resolved['state'], 'video_frames_saved');
    final resolvedDetails = jsonDecode(resolved['details']! as String) as Map;
    expect(resolvedDetails['parentMessageId'], actual);
    expect(resolvedDetails['resolvedMessageId'], actual);
    expect(resolvedDetails['mediaReceiptId'], actualReceipt);
    expect(await inventory.analysisReadyMessageIds('buyer'), contains(actual));
    expect(await audit.pendingUnboundForCustomer('buyer'), isEmpty);
    final receiptDraft = await generate(actual);
    expect(receiptDraft.model, isNot('local-media-receipt'),
        reason:
            'The genuinely new media still requires its own complete answer');
    expect(jsonDecode(receiptDraft.rawJson)['reply_purpose'], 'substantive');
    final actualRequest = await request();
    expect(
        (actualRequest['target_customer_batch'] as List).single['id'], actual);
    expect(actualRequest['attached_video_frame_paths'], hasLength(2));
    expect(await inventory.analysisReadyMessageIds('buyer'), contains(actual));
    expect(await audit.pendingUnboundForCustomer('buyer'), isEmpty);
    expect(await db.isMessageFormallyAnswered('buyer', actual), isFalse,
        reason: 'Acquiring frames does not complete the real answer');
    expect(await db.isMessageFormallyAnswered('buyer', 'received-question'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', old), isTrue);
  });
}
