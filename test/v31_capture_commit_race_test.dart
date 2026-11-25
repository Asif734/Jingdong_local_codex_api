import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

class _PausedCaptureDatabase extends CaptureDatabase {
  _PausedCaptureDatabase({required super.storageRoot});
  bool pauseNextProcessing = false;
  final paused = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<List<Map<String, dynamic>>> processingMessages(String customer,
      {Map<String, dynamic>? document, bool includeAnswered = false}) async {
    final snapshot = await super.processingMessages(customer,
        document: document, includeAnswered: includeAnswered);
    if (pauseNextProcessing) {
      pauseNextProcessing = false;
      paused.complete();
      await resume.future;
    }
    return snapshot;
  }
}

void main() {
  late Directory root;
  late _PausedCaptureDatabase db;
  final started = DateTime.now().toUtc().subtract(const Duration(seconds: 3));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_capture_commit_race_');
    db = _PausedCaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: started);
  });
  tearDown(() async {
    if (db.paused.isCompleted && !db.resume.isCompleted) db.resume.complete();
    await db.close();
    await root.delete(recursive: true);
  });

  CapturedConversation frame(String id, {bool outgoing = false}) {
    final at = DateTime.now().toUtc();
    return CapturedConversation(
      stableKey: 'buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: at,
      automationSessionId: db.currentAutomationSessionId,
      messages: [
        CapturedMessage(
            stableId: id,
            direction: outgoing ? 'outgoing' : 'incoming',
            body: outgoing
                ? 'Manually answered the previous question.'
                : 'Question $id',
            sentAt: at,
            deliveryConfirmed: outgoing,
            axPath: 'controlled AX fixture')
      ],
    );
  }

  Future<String> freshReadyAndPending() async {
    await db.saveCapture(frame('current-question'));
    final pending = (await db.conversations()).single;
    await db.saveDraft(
        pending.id,
        AiDraft.fromJson({
          'reply': 'Answer to the current question.',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-test',
          'used_record_ids': [],
          'required_slots': [],
          'actions': [],
          'attachments': [],
        }, mediaBaseUrl: Uri()),
        expectedMessageId: 'current-question');
    await db.saveCapture(frame('current-follow-up'));
    return (await (await db.database).query('generated_drafts'))
        .single['task_id']! as String;
  }

  for (final outgoing in [false, true]) {
    test(
        'old ${outgoing ? 'manual answer' : 'incoming'} commit cannot change a new run',
        () async {
      await db.saveCapture(frame('previous-question'));
      db.pauseNextProcessing = true;
      final oldWrite =
          db.saveCapture(frame('previous-late', outgoing: outgoing));
      // Hold the exact old processing snapshot, with no sleeps or speculative
      // timer scheduling, until the new run already owns both queue and draft.
      await db.paused.future.timeout(const Duration(seconds: 5));
      await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
      final currentTask = await freshReadyAndPending();
      db.resume.complete();
      await oldWrite.timeout(const Duration(seconds: 5));
      expect(await db.pendingMessageId('buyer'), 'current-follow-up');
      expect(
          (await (await db.database).query('generated_drafts'))
              .single['task_id'],
          currentTask);
      expect(await db.answeredMessageId('buyer'), isNull);
      expect(await db.isBatchUnanswered('buyer', 'current-question'), isTrue);
    });
  }
  test('durable session commit rejects a write before its memory owner changes',
      () async {
    final sql = await db.database;
    await sql.insert('automation_sessions', {
      'session_id': 'next-session-committed',
      'started_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    // This is the narrow interval after a new session transaction has committed
    // while the suspended caller still sees the previous in-memory owner.
    await db.saveCapture(frame('previous-owner-question'));
    expect(await sql.query('pending_customers'), isEmpty);
    expect(await sql.query('sla_fallbacks'), isEmpty);
    expect(await db.answeredMessageId('buyer'), isNull);
  });
}
