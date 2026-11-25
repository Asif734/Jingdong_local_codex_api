import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

/// Pause a real asynchronous persistence boundary without changing production
/// storage code or introducing a timer into the delivery flow.
class _GatedDatabase extends CaptureDatabase {
  _GatedDatabase(this.root, DateTime Function() clock)
      : super(storageRoot: root, currentDayOnly: true, clock: clock);
  final Directory root;
  int _rootCalls = 0;
  Completer<void>? entered;
  Completer<void>? resume;

  void gateRootCall(int ordinal) {
    _rootCalls = ordinal;
    entered = Completer<void>();
    resume = Completer<void>();
  }

  @override
  Future<Directory> get storageRoot async {
    if (_rootCalls > 0 && --_rootCalls == 0) {
      entered!.complete();
      await resume!.future;
    }
    return root;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'controlled-day-receipt';
  const reply = 'Select the correct paper source before printing.';
  late Directory root;
  late DateTime clock;
  late _GatedDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v52_day_receipt_');
    clock = DateTime.utc(2026, 11, 10, 15, 59, 30);
    db = _GatedDatabase(root, () => clock);
  });
  tearDown(() async {
    if (db.resume != null && !db.resume!.isCompleted) db.resume!.complete();
    await db.close();
    await root.delete(recursive: true);
  });

  AiDraft draft({List<String>? scope}) => AiDraft.fromJson({
        'reply': reply,
        'reply_purpose': 'substantive',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-day-receipt',
        'reply_media_dependency_keys': <String, String>{},
        if (scope != null) 'service_message_ids': scope,
        if (scope != null) 'formal_response_message_ids': scope,
      }, mediaBaseUrl: Uri());

  Future<String> receive(String text, DateTime at) async {
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'captured-${at.toIso8601String()}',
              direction: 'incoming',
              body: text,
              sender: customer,
              sentAt: at,
              axPath: 'controlled original customer')
        ]));
    return (await db.incomingMessageIdAtTime(customer, at))!;
  }

  test('a claimed native send crossing Start commits only to its original day',
      () async {
    await db.beginAutomationSession(startedAt: clock);
    final oldId = await receive(
        'Why does the paper stop?', clock.add(const Duration(seconds: 1)));
    final pending = (await db.conversation(customer))!;
    final token = (await db.beginGeneration(
        customer: customer, pendingId: pending.id, batchEndMessageId: oldId))!;
    final prepared = await db.prepareAutomaticDraft(customer, draft());
    expect(
        (await db.saveAutomaticDraft(pending.id, prepared,
                expectedUserId: customer,
                expectedMessageId: oldId,
                generationToken: token))
            .outcome,
        AutomaticDraftSaveOutcome.ready);
    await db.abandonGeneration(customer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: customer, reply: reply);
    final native = File(attempt['receiptPath']!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await native.writeAsString(
        jsonEncode({
          'attemptId': attempt['attemptId'],
          'customer': customer,
          'state': 'submitted',
          'sendClickedAtMs': now,
          'timeMs': now,
        }),
        flush: true);
    final proof = await native.readAsString();

    // First root access verifies the native receipt. The second selects the
    // immutable task-day file after the row has already entered committing.
    db.gateRootCall(2);
    final committing =
        db.markReplySent(userId: customer, reply: reply, expectedTaskId: token);
    await db.entered!.future.timeout(const Duration(seconds: 5));
    final sql = await db.database;
    expect((await sql.query('generated_drafts')).single['delivery_state'],
        'committing');
    clock = DateTime.utc(2026, 11, 10, 16, 0, 5);
    await db.beginAutomationSession(startedAt: clock);
    final currentId = await receive(
        'A new question today.', clock.add(const Duration(seconds: 1)));
    db.resume!.complete();
    expect(await committing, isFalse,
        reason: 'An old commit cannot finish the new session queue');

    final old = ConversationFileStore.forDay(root,
        businessDay: '2026-11-10', clock: () => clock);
    final oldMessages =
        ((await old.read(customer))!['messages'] as List).cast<Map>();
    final archivedReply = oldMessages.singleWhere(
        (message) => message['delivery_attempt_id'] == attempt['attemptId']);
    expect(archivedReply['answered_batch_end_id'], oldId);
    expect(archivedReply['delivery_task_id'], token);
    expect(archivedReply['body'], reply);
    final current = (await (await db.history).read(customer))!;
    expect(
        (current['messages'] as List)
            .cast<Map>()
            .any((message) => message['body'] == reply),
        isFalse);
    expect(await db.pendingMessageId(customer), currentId);
    expect(await db.isMessageFormallyAnswered(customer, currentId), isFalse);
    expect(await db.unansweredWorkCounts(), {customer: 1});
    expect(await native.readAsString(), proof);
    expect(
        await sql.query('automation_archived_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]),
        hasLength(1));
  });

  test('a detached late receipt uses canonical raw scope before a new Start',
      () async {
    clock = DateTime.utc(2026, 11, 11, 4);
    final sql = await db.database;
    final previous = DateTime.utc(2026, 11, 10, 15, 59, 50);
    final oldId = CustomerMessageTime.incomingId(customer, previous);
    final old = ConversationFileStore.forDay(root,
        businessDay: '2026-11-10', clock: () => clock);
    await old.appendCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        capturedAt: previous,
        messages: [
          CapturedMessage(
            stableId: 'legacy-ocr-boundary',
            direction: 'incoming',
            body: 'An older original question.',
            sender: customer,
            sentAt: previous,
            axPath: 'controlled previous original',
          )
        ]));
    const attempt = 'controlled-detached-old';
    final now = DateTime.now().millisecondsSinceEpoch;
    await sql.insert('delivery_attempts', {
      'attempt_id': attempt,
      'task_id': 'old-detached-task',
      'user_id': customer,
      'pending_id': 0,
      'reply': reply,
      'raw_json': draft(scope: [oldId]).rawJson,
      'batch_end_message_id': 'legacy-ocr-boundary',
      'state': 'superseded_unknown',
      'kind': 'reply',
      'created_at_ms': now,
      'updated_at_ms': now,
    });
    final native = File('${root.path}/delivery_receipts/$attempt.json');
    await native.parent.create(recursive: true);
    await native.writeAsString(
        jsonEncode({
          'attemptId': attempt,
          'customer': customer,
          'state': 'submitted',
          'sendClickedAtMs': now,
          'timeMs': now,
        }),
        flush: true);
    await db.recoverDeliveryReceipts();
    expect(db.currentAutomationSessionId, isNull);
    final oldMessages =
        ((await old.read(customer))!['messages'] as List).cast<Map>();
    expect(
        oldMessages.singleWhere(
            (message) => message['delivery_attempt_id'] == attempt)['body'],
        reply);
    expect(await (await db.history).read(customer), isNull);
    expect(
        (await sql.query('delivery_attempts',
                where: 'attempt_id=?', whereArgs: [attempt]))
            .single['state'],
        'superseded_submitted');
    expect(await native.exists(), isTrue);
  });
}
