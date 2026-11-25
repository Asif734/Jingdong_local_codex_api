import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final media in [true, false]) {
    test(
        'late original invalidates attachment status, ordinary text remains independent: media=$media',
        () async {
      final root = await Directory.systemTemp.createTemp('v27_late_original_');
      final db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final received = DateTime.now().toUtc();
      await db.beginAutomationSession(startedAt: received);
      final inventory = CustomerMediaInventory(db);
      final receipt = await inventory.observe(
          customer: 'buyer',
          evidenceId: 'exact-received-video',
          observedAt: received,
          senderAt: received,
          slot: 0,
          region: [.3, .3, .2, .2],
          current: true);
      await inventory.classify(receipt, 'video');
      final mediaId = 'media-pending:$receipt';
      await admitFixtureMedia(db,
          receiptId: receipt,
          messageId: mediaId,
          receivedAt: received,
          senderAt: received);
      final admitted = (await (await db.database).query('customer_media_items',
              where: 'item_id=?', whereArgs: [receipt]))
          .single;
      expect(admitted['kind'], 'video');
      expect(admitted['admission_session_id'], db.currentAutomationSessionId);
      final workspace = await Directory('${root.path}/workspace').create();
      final knowledge = await Directory('${root.path}/knowledge').create();
      await File('${knowledge.path}/test_kb.md')
          .writeAsString('Use the supported USB cable.');
      final cli = File('${root.path}/fake.sh');
      final reply = media
          ? 'The latest video is still loading.'
          : 'Use the printer settings menu to change the date.';
      await cli.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
 if [ "\$1" = '--output-last-message' ]; then shift; output="\$1"; fi
 shift
done
cat >/dev/null
printf '%s' '{"reply":"$reply","decision":"draft","confidence":1,"risk_level":"low","used_record_ids":[],"actions":[],"attachments":[],"auto_send_allowed":false,"model":"test"}' > "\$output"
''');
      expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
                stableId: 'caption',
                direction: 'incoming',
                body: media
                    ? 'Please check the video I sent.'
                    : 'How do I change the date?',
                sentAt: DateTime.now().toUtc(),
                axPath: 'fixture')
          ]));
      final pending = (await db.conversations()).single;
      final claimed = await db.beginGeneration(
          customer: 'buyer',
          pendingId: pending.id,
          batchEndMessageId: 'caption');
      late final String token;
      if (!media) {
        token = claimed!;
      } else {
        expect(claimed, isNull,
            reason: 'Known unready media must prevent the normal CLI lease');
        expect(await db.generationDue('buyer'), isFalse);
        final sql = await db.database;
        expect(await sql.query('automation_reply_inputs'), isEmpty);
        token = 'fault-injected-legacy-media-status';
        final work = (await sql.query('automation_session_messages',
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [db.currentAutomationSessionId, 'buyer', 'caption']))
            .single;
        final document = (await (await db.history).read('buyer'))!;
        final message = (document['messages'] as List)
            .cast<Map>()
            .singleWhere((m) => m['id'] == 'caption');
        // A deliberately injected old lease preserves this lower-layer test:
        // an already-running legacy status draft must be invalidated when its
        // actual video arrives. Production exposes no preflight bypass.
        await sql.transaction((txn) async {
          await txn.update('pending_customers', {'generation_token': token},
              where: 'id=? AND user_id=?', whereArgs: [pending.id, 'buyer']);
          await txn.insert('automation_reply_inputs', {
            'session_id': db.currentAutomationSessionId,
            'user_id': 'buyer',
            'owner_id': token,
            'message_id': 'caption',
            'message_revision': work['work_revision'],
            'message_json': jsonEncode({
              ...message,
              'reply_material_input_key':
                  ConversationFileStore.materialInputKey(message),
            }),
          });
        });
      }
      final service = CodexReplyService(
          executable: cli.path,
          workspace: workspace,
          knowledgeDirectory: knowledge,
          outputSchema: File('${root.path}/reply.schema.json'));
      final draft = await service.generate(
          conversation: pending, database: db, batchEndMessageId: 'caption');
      expect(
          (jsonDecode(draft.rawJson)['reply_media_dependency_keys'] as Map)
              .containsKey(mediaId),
          media);
      expect(draft.mediaContextRevision, media ? isNotNull : isNull);
      // Complete the exact admitted attachment. A customer-wide revision by
      // itself is deliberately insufficient evidence of a changed dependency.
      final original = CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now().toUtc(),
          messages: [
            CapturedMessage(
                stableId: mediaId,
                direction: 'incoming',
                body: '[Customer sent a video]',
                sender: 'buyer',
                sentAt: received,
                axPath: 'same admitted bubble',
                mediaReceiptId: receipt,
                media:
                    await completedVideoFixture(root, name: 'exact-original'))
          ]);
      await db.saveCapture(original);
      await inventory.persist(original, verifiedAnchor: true);
      expect(await db.mediaContextCurrent('buyer', draft), !media);
      expect(
          await db.saveDraft(pending.id, draft,
              expectedMessageId: 'caption',
              expectedUserId: 'buyer',
              generationToken: token),
          media ? 0 : 1);
      expect(await db.isMessageFormallyAnswered('buyer', 'caption'), isFalse);
    });
  }
}
