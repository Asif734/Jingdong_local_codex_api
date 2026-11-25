import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'owned audio failures keep waiting; verified terminal results wake the same input',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v36_late_speech_');
    final db = CaptureDatabase(storageRoot: root);
    try {
      const customer = 'late-speech-customer';
      final started = DateTime.now().toUtc();
      final session = await db.beginAutomationSession(startedAt: started);
      final inventory = CustomerMediaInventory(db);
      final receipt = await inventory.observe(
          customer: customer,
          evidenceId: 'current-immutable-video-frame',
          observedAt: started,
          senderAt: started,
          slot: 0,
          region: [.27, .3, .12, .2],
          current: true);
      final messageId = 'media-pending:$receipt';
      await admitFixtureMedia(db,
          customer: customer,
          receiptId: receipt,
          messageId: messageId,
          receivedAt: started,
          senderAt: started);
      final path = '${root.path}/current-video.mp4';
      final capture = CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: session,
          capturedAt: started.add(const Duration(milliseconds: 1)),
          messages: [
            CapturedMessage(
                stableId: messageId,
                direction: 'incoming',
                body: '[Customer sent a video]',
                sender: customer,
                axPath: 'test:exact-owned-video',
                mediaReceiptId: receipt,
                media: [
                  CapturedMedia(
                      type: 'video',
                      path: path,
                      captureSource: 'jd_video_cache',
                      description: 'Original video; audio analysis pending'),
                  CapturedMedia(
                      type: 'image',
                      path: '${root.path}/frame-00.jpg',
                      originalName: 'video_frame_00s.jpg',
                      description: 'First decoded video frame (t=0).',
                      captureSource: 'jd_video_frame_1fps'),
                  CapturedMedia(
                      type: 'image',
                      path: '${root.path}/tail.jpg',
                      originalName: 'video_frame_tail.jpg',
                      captureSource: 'jd_video_frame_1fps'),
                  CapturedMedia(
                      type: 'image',
                      path: '${root.path}/cover.jpg',
                      captureSource: 'jd_video_cover',
                      isPartial: true),
                ])
          ]);
      await db.saveCapture(capture);
      await inventory.persist(capture, verifiedAnchor: true);
      final key =
          (await inventory.analyzableEvidenceKeys(customer))[messageId]!;
      final work = (await (await db.database).query(
              'automation_session_messages',
              where: 'message_id=?',
              whereArgs: [messageId]))
          .single;
      await (await db.database).insert('automation_message_waits', {
        'session_id': session,
        'user_id': customer,
        'message_id': messageId,
        'is_media': 1,
        'content_key': jsonEncode({messageId: key}),
        'message_revision': work['work_revision'],
        'task_id': 'already-sent-media-status',
        'updated_at_ms': started.millisecondsSinceEpoch,
      });
      expect(await db.hasPendingUnanswered(customer), isTrue);
      expect(await db.generationDue(customer), isFalse);
      final history = await db.history;
      final beforeFailure =
          ((await history.read(customer))!['messages'] as List)
              .cast<Map>()
              .single['service_evidence_revision'];
      const failure =
          '[Video audio: speech transcription temporarily unavailable; retry pending]';
      expect(await history.updateMediaDescriptions(customer, {path: failure}),
          greaterThan(0));
      expect(
          await inventory.updateProvenVideoDescription(customer, path, failure,
              messageId: messageId, receiptId: receipt),
          greaterThan(0));
      expect(
          ((await history.read(customer))!['messages'] as List)
              .cast<Map>()
              .single['service_evidence_revision'],
          beforeFailure,
          reason:
              'A retryable failure is progress metadata, not new customer input');
      expect(await db.generationDue(customer), isFalse,
          reason:
              'Failed speech extraction must not impersonate complete parsing');
      const noSpeech = '[Video audio: no audio stream]';
      expect(await history.updateMediaDescriptions(customer, {path: noSpeech}),
          greaterThan(0));
      expect(
          await inventory.updateProvenVideoDescription(customer, path, noSpeech,
              messageId: messageId, receiptId: receipt),
          greaterThan(0));
      expect(
          (await inventory.analyzableEvidenceKeys(customer))[messageId], key);
      expect(await inventory.analysisReadyMessageIds(customer),
          contains(messageId));
      expect(await db.generationDue(customer), isTrue,
          reason:
              'A verified no-audio conclusion completes parsing even when frame key stays unchanged');

      const speech = '[Video speech transcript (en-US): '
          'The printer stops feeding after the first page]';
      expect(await history.updateMediaDescriptions(customer, {path: speech}),
          greaterThan(0));
      final beforeSync = (await (await db.database).query(
              'customer_media_items',
              where: 'customer=? AND canonical_id IS NULL',
              whereArgs: [customer]))
          .single;
      expect(beforeSync['media_json'], isNot(contains('stops feeding')),
          reason:
              'Writing history alone must not claim the exact inventory is synchronized');
      expect(
          (await inventory.analyzableEvidenceKeys(customer))[messageId], key);
      expect(
          await inventory.updateProvenVideoDescription(customer, path, speech,
              messageId: messageId, receiptId: receipt),
          greaterThan(0));
      await db.repairSessionPendingWork(customer);
      final rows = await (await db.database).query('customer_media_items',
          where: 'customer=? AND canonical_id IS NULL', whereArgs: [customer]);
      final media = (jsonDecode(rows.single['media_json']! as String) as List)
          .whereType<Map>();
      expect(media.singleWhere((m) => m['type'] == 'video')['description'],
          contains('stops feeding'));
      expect((await inventory.analyzableEvidenceKeys(customer))[messageId],
          isNot(key));
      expect(await db.hasPendingUnanswered(customer), isTrue);
      final finalWork = await (await db.database).query(
          'automation_session_messages',
          where: 'message_id=?',
          whereArgs: [messageId]);
      expect(finalWork, hasLength(1));
      expect(finalWork.single['activated_at_ms'], work['activated_at_ms']);
      expect(await db.awaitingMediaMessageIds(customer), isEmpty);
      expect(await db.generationDue(customer), isTrue,
          reason: 'Late speech wakes the same pending input, not a new task');
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
