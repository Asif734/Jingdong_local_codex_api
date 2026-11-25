import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'missing one supplied frame cannot produce a draft; complete analysis can',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_v37_complete_analysis_');
    final db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    try {
      final now = DateTime.now().toUtc();
      await db.beginAutomationSession(
          startedAt: now.subtract(const Duration(seconds: 1)));
      final inventory = CustomerMediaInventory(db);
      final receipt = await inventory.observe(
          customer: 'buyer',
          evidenceId: 'owned-video',
          observedAt: now,
          senderAt: now,
          slot: 0,
          region: [.3, .3, .2, .2],
          current: true);
      await inventory.classify(receipt, 'video');
      final id = 'media-pending:$receipt';
      await admitFixtureMedia(db,
          receiptId: receipt, messageId: id, receivedAt: now, senderAt: now);
      final video = await File('${root.path}/video.mp4').writeAsBytes([1]);
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=');
      final frame = await File('${root.path}/frame.jpg').writeAsBytes(bytes);
      final tail = await File('${root.path}/tail.jpg').writeAsBytes(bytes);
      final cover = await File('${root.path}/cover.jpg').writeAsBytes(bytes);
      final capture = CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: '[Customer sent a video]',
                sentAt: now,
                axPath: 'same exact video bubble',
                mediaReceiptId: receipt,
                media: [
                  CapturedMedia(
                      type: 'video',
                      path: video.path,
                      captureSource: 'jd_video_cache',
                      description: '[Video audio: no audio stream]'),
                  CapturedMedia(
                      type: 'image',
                      path: frame.path,
                      captureSource: 'jd_video_frame_1fps',
                      originalName: 'video_frame_00s.jpg'),
                  CapturedMedia(
                      type: 'image',
                      path: tail.path,
                      captureSource: 'jd_video_frame_1fps',
                      originalName: 'video_frame_tail.jpg'),
                  CapturedMedia(
                      type: 'image',
                      path: cover.path,
                      captureSource: 'jd_video_cover'),
                ])
          ]);
      await db.saveCapture(capture);
      await inventory.persist(capture, verifiedAnchor: true);
      expect(await db.generationDue('buyer'), isTrue);
      final workspace = await Directory('${root.path}/workspace').create();
      final knowledge = await Directory('${root.path}/knowledge').create();
      await File('${knowledge.path}/printer_kb.md').writeAsString(
          'Switch off the printer before checking the paper feed.');
      final mode = await File('${root.path}/mode').writeAsString('missing');
      final input = File('${root.path}/request.json');
      final cli = await File('${root.path}/controlled-cli.py')
          .writeAsString('''#!/usr/bin/python3
import sys,json,re,pathlib
args=sys.argv[1:]
output=args[args.index('--output-last-message')+1]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
pathlib.Path(${jsonEncode(input.path)}).write_text(json.dumps(request))
paths=request['attached_image_paths']
if pathlib.Path(${jsonEncode(mode.path)}).read_text().strip()=='missing': paths=paths[:-1]
reply={'reply':'Switch off the printer before checking the paper feed.','reply_purpose':'substantive','decision':'draft','confidence':0.9,'risk_level':'low','auto_send_allowed':False,'human_review_required':False,'risk_triggers':[],'used_record_ids':[],'required_slots':[],'actions':[],'attachments':[],'image_descriptions':[{'path':p,'description':'The supplied view shows the paper feed area.'} for p in paths]}
pathlib.Path(output).write_text(json.dumps(reply))
''');
      expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
      final service = CodexReplyService(
          executable: cli.path,
          workspace: workspace,
          knowledgeDirectory: knowledge,
          outputSchema: File('${root.path}/reply.schema.json'),
          capacityRetryDelays: const []);
      final conversation = (await db.conversation('buyer'))!;
      final first = (await db.beginGeneration(
          customer: 'buyer',
          pendingId: conversation.id,
          batchEndMessageId: id))!;
      await expectLater(
          service.generate(
              conversation: conversation, database: db, batchEndMessageId: id),
          throwsA(isA<CodexReplyException>().having((e) => e.message, 'reason',
              contains('media analysis incomplete'))));
      final request = jsonDecode(await input.readAsString()) as Map;
      expect(request['attached_image_paths'], hasLength(3));
      expect(await (await db.database).query('generated_drafts'), isEmpty);
      expect(await db.hasPendingUnanswered('buyer'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
      await db.abandonGeneration('buyer', first);
      await mode.writeAsString('complete');
      final second = (await db.beginGeneration(
          customer: 'buyer',
          pendingId: conversation.id,
          batchEndMessageId: id))!;
      final draft = await service.generate(
          conversation: conversation, database: db, batchEndMessageId: id);
      expect(draft.imageDescriptions.keys.toSet(),
          {frame.path, tail.path, cover.path});
      final prepared = await db.prepareAutomaticDraft('buyer', draft);
      expect(
          await db.saveDraft(conversation.id, prepared,
              expectedMessageId: id, generationToken: second),
          1);
      await db.abandonGeneration('buyer', second);
      expect(await db.hasUndeliveredDraft('buyer'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
