import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('outgoing tutorial requests include the exact recorded wording', () {
    for (final question in [
      'can you share me a video?',
      'Could you share me some videos?',
      'Could you send me a video?',
      'Please share me a video',
      'Can you provide a setup video?',
      '请发给我一个视频',
      '可以给我发个视频吗',
      'Please send the setup video guide',
      '请发设置视频教程',
    ]) {
      expect(isVideoGuideRequest(question), isTrue, reason: question);
    }
  });
  test('incoming videos and receipt questions do not become tutorial requests',
      () {
    for (final question in [
      'Did you get my video?',
      'Please check my video',
      'Please check my setup video',
      'I can send you a video',
      'I will send you a setup video',
      'Can I send you a video tutorial?',
      'I sent a fault video',
      '可以给你发个视频教程吗',
      '我发一个设置视频给你',
      '看一下我发的视频',
    ]) {
      expect(isVideoGuideRequest(question), isFalse, reason: question);
    }
  });

  for (final purpose in ['substantive', 'review_status']) {
    test(
        'corrected text routes through real service catalog with old unbound context: $purpose',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_v39_tutorial_');
      final db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final now = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true);
      final session = await db.beginAutomationSession(
          startedAt: now.subtract(const Duration(minutes: 2)));
      final inventory = CustomerMediaInventory(db);
      final sourceClock = now.subtract(const Duration(seconds: 1));
      final receipt = await inventory.observe(
          customer: 'buyer',
          evidenceId: 'clipped-frame',
          occurrenceKey: 'recorded-tutorial-question',
          observedAt: now,
          senderAt: sourceClock,
          slot: 0,
          region: [.24, .70, .42, .08],
          current: true);
      final parent = await db.admitMediaMessage('buyer',
          receiptId: receipt,
          evidenceId: 'clipped-frame',
          occurrenceKey: 'recorded-tutorial-question',
          receivedAt: now,
          senderAt: sourceClock);
      expect(
          await db.clarifyUnknownMessageAsText('buyer',
              parentMessageId: parent.messageId,
              receiptId: receipt,
              text: CapturedMessage(
                  stableId: 'ocr:complete-tutorial',
                  direction: 'incoming',
                  body: 'can you share me a video?',
                  sender: 'buyer',
                  sentAt: sourceClock,
                  axPath: 'verified-current-customer'),
              evidenceId: 'complete-frame',
              expectedSessionId: session),
          parent.messageId);
      await (await db.database).insert('media_capture_audit', {
        'observation_id': 'old-unbound',
        'evidence_id': 'old-frame',
        'customer': 'buyer',
        'state': 'unbound',
        'updated_at_ms': now.millisecondsSinceEpoch,
        'details': jsonEncode({
          'observationId': 'old-unbound',
          'evidenceId': 'old-frame',
          'automationSessionId': session,
          'capturedAt':
              now.subtract(const Duration(seconds: 30)).toIso8601String(),
          'region': [.3, .3, .2, .2],
          'reason': 'older-unbound-context'
        }),
      });
      final workspace = await Directory('${root.path}/workspace').create();
      final knowledge = await Directory('${root.path}/knowledge').create();
      await File('${knowledge.path}/fixture_kb.md').writeAsString(
          'Ask for the exact machine model and operation before selecting a tutorial.');
      await Directory('${knowledge.path}/rag_cards').create();
      await File('${knowledge.path}/rag_cards/china_market_video_catalog.json')
          .writeAsString(jsonEncode({
        'entries': [
          {
            'content_id': 'controlled-ribbon-guide',
            'title_zh': '色带安装',
            'title_en': 'Ribbon installation',
            'product_line': 'attendance_machine',
            'models': ['M880'],
            'keywords': ['ribbon', 'installation'],
            'platform_urls': {'JD': 'https://example.test/jd/ribbon'},
            'analysis_status': 'verified-fixture'
          }
        ],
      }));
      final requestFile = File('${root.path}/request.txt');
      final responseFile = File('${root.path}/response.json');
      await responseFile.writeAsString(jsonEncode({
        'reply': purpose == 'substantive'
            ? 'Which machine model and operation would you like the tutorial for?'
            : 'I am still looking for the tutorial and will share it later.',
        'reply_purpose': purpose,
        'decision': purpose == 'substantive' ? 'ask_clarification' : 'draft',
        'confidence': 1.0,
        'risk_level': 'low',
        'auto_send_allowed': false,
        'used_record_ids': [],
        'actions': [],
        'attachments': [],
        'image_descriptions': [],
      }));
      final cli = File('${root.path}/controlled-cli.py');
      await cli.writeAsString('''#!/usr/bin/python3
import sys,pathlib
args=sys.argv[1:]
pathlib.Path(${jsonEncode(requestFile.path)}).write_text(sys.stdin.read())
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(pathlib.Path(${jsonEncode(responseFile.path)}).read_text())
''');
      expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
      final conversation = (await db.conversation('buyer'))!;
      final token = (await db.beginGeneration(
          customer: 'buyer',
          pendingId: conversation.id,
          batchEndMessageId: parent.messageId))!;
      expect(
          await db.generationInputsAnalysisReady('buyer',
              generationToken: token),
          isTrue);
      final draft = await CodexReplyService(
              executable: cli.path,
              workspace: workspace,
              knowledgeDirectory: knowledge,
              outputSchema: File('${workspace.path}/reply.schema.json'),
              timeout: const Duration(seconds: 10),
              capacityRetryDelays: [])
          .generate(
              conversation: conversation,
              database: db,
              batchEndMessageId: parent.messageId);
      final prompt = await requestFile.readAsString();
      final match = RegExp(r'<request_json>\s*([\s\S]*?)\s*</request_json>')
          .firstMatch(prompt)!;
      final request = jsonDecode(match.group(1)!) as Map;
      expect(request['latest_message']['body'], 'can you share me a video?');
      expect((request['target_customer_batch'] as List).single['id'],
          parent.messageId);
      expect(request['video_guide_requested'], isTrue);
      expect((request['available_jd_video_tutorials'] as List).single['id'],
          'controlled-ribbon-guide');
      expect(request['received_customer_media_inventory'], isEmpty);
      expect(request['attached_image_paths'], isEmpty);
      expect(request['current_media_reference_status'], isNull);
      expect(request['unbound_observations_are_context_only'], isTrue);
      expect(
          (request['unbound_customer_media_observations'] as List)
              .single['observationId'],
          'old-unbound');
      expect(draft.mediaContextRevision, isNull);
      final prepared = await db.prepareAutomaticDraft('buyer', draft);
      final raw = jsonDecode(prepared.rawJson) as Map;
      expect(raw['reply_purpose'], purpose);
      expect(
          await db.saveDraft(conversation.id, prepared,
              expectedMessageId: parent.messageId, generationToken: token),
          1);
      if (purpose == 'substantive') {
        expect(raw['formal_response_message_ids'], contains(parent.messageId));
        expect(await db.hasUndeliveredDraft('buyer'), isTrue);
      } else {
        expect(raw['formal_response_message_ids'], isEmpty);
        expect(await db.hasUndeliveredDraft('buyer'), isFalse);
      }
      expect(await db.isMessageFormallyAnswered('buyer', parent.messageId),
          isFalse);
      expect(
          (await MediaCaptureAudit(db).pendingUnboundForCustomer('buyer'))
              .single['observationId'],
          'old-unbound');
    });
  }
}
