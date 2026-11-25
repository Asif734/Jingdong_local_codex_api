import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

AiDraft answer(String text) => AiDraft(
    reply: text,
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'test',
    usedRecordIds: const [],
    actions: const [],
    attachments: const [],
    rawJson: jsonEncode({
      'reply': text,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'test'
    }));

class _ReceiptReadRaceDatabase extends CaptureDatabase {
  _ReceiptReadRaceDatabase({required super.storageRoot});

  Future<void> Function()? beforeStorageRootRead;

  @override
  Future<Directory> get storageRoot async {
    final callback = beforeStorageRootRead;
    beforeStorageRootRead = null;
    await callback?.call();
    return super.storageRoot;
  }
}

void main() {
  late Directory root;
  late _ReceiptReadRaceDatabase db;
  var tick = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_message_hold_');
    db = _ReceiptReadRaceDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(minutes: 1)));
    tick = 0;
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<Map<String, dynamic>> receive(String id) async {
    final at =
        DateTime.now().toUtc().subtract(Duration(seconds: 30 - 2 * tick++));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'Question $id',
              sentAt: at,
              axPath: 'test')
        ]));
    return (await db.processingMessages('buyer')).firstWhere((m) =>
        m['direction'] == 'incoming' &&
        ((m['observed_ids'] as List? ?? []).contains(id) || m['id'] == id));
  }

  Future<void> save(String id) async {
    final pending = (await db.conversation('buyer'))!;
    final token = await db.beginGeneration(
        customer: 'buyer',
        pendingId: pending.id,
        batchEndMessageId: id,
        singleMessage: true);
    expect(token, isNotNull);
    expect(
        await db.saveDraft(pending.id, answer('Answer $id'),
            expectedMessageId: id,
            expectedUserId: 'buyer',
            generationToken: token),
        1);
    await db.abandonGeneration('buyer', token!);
  }

  Future<Map<String, String>> lateRejection() async {
    await receive('old');
    await save('old');
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: 'Answer old');
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.recoverDeliveryReceipts();
    expect(
        await db.noteObservedRejection(
            customer: 'buyer',
            body: 'Answer old',
            fingerprint: 'failed-old',
            capturedAt: DateTime.now().add(const Duration(seconds: 2))),
        isTrue);
    await db.recoverDeliveryReceipts();
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    return attempt;
  }

  test(
      'late failed bubble holds only its source and completed API for next source proceeds',
      () async {
    final attempt = await lateRejection();
    await db.suspendUnavailableConversation(
        'buyer', 'send_unconfirmed: reconciliation_required');
    final newer = await receive('new');
    expect(await db.isolateUncertainDelivery('buyer'), isTrue);
    expect(await db.isConversationUnavailable('buyer'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isFalse);
    final held = (await db.reconciliationWork()).single;
    expect(held['held'], isTrue);
    expect(held['blocksCustomer'], isFalse);
    expect(held['attempt_id'], attempt['attemptId']);
    expect(
        await db.beginGeneration(
            customer: 'buyer',
            pendingId: (await db.conversation('buyer'))!.id,
            batchEndMessageId: 'old'),
        isNull);
    final source = <String, dynamic>{
      ...newer,
      'reply_api_customer': 'buyer',
      'reply_api_session_id': db.currentAutomationSessionId,
      'reply_material_input_key': ConversationFileStore.materialInputKey(newer)
    };
    final pending = (await db.conversation('buyer'))!;
    final lease = await db.beginCompletedApiDelivery(
        customer: 'buyer', pendingId: pending.id, source: source);
    expect(lease, isNotNull);
    final saved = await db.saveCompletedApiDraft(
        pendingId: pending.id,
        customer: 'buyer',
        draft: answer('Answer new'),
        source: source,
        generationToken: lease!.token);
    expect(saved.queued, isTrue);
    await db.abandonGeneration('buyer', lease.token);
    final current =
        (await (await db.database).query('generated_drafts')).single;
    for (var n = 0; n < 3; n++) {
      await db.recoverDeliveryReceipts();
      expect(await db.isolateUncertainDelivery('buyer'), isFalse);
    }
    expect(
        (await (await db.database).query('generated_drafts')).single, current);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch + 2000
    }));
    await db.recoverDeliveryReceipts();
    expect(
        (await (await db.database).query('generated_drafts')).single, current);
    expect(await db.isMessageFormallyAnswered('buyer', 'new'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isTrue);
    expect(
        (await db.beginDeliveryAttempt(userId: 'buyer', reply: 'Answer new')),
        isNotEmpty);
  });

  for (final phase in ['not_sent', 'rejected']) {
    test(
        'proven $phase restores the original snapshot only after newer work finishes',
        () async {
      final attempt = await lateRejection();
      final original =
          (await (await db.database).query('generated_drafts')).single;
      final oldSource = (await db.processingMessages('buyer'))
          .firstWhere((m) => m['direction'] == 'incoming');
      await receive('new');
      expect(await db.isolateUncertainDelivery('buyer'), isTrue);
      final source = <String, dynamic>{
        ...oldSource,
        'reply_api_customer': 'buyer',
        'reply_api_session_id': db.currentAutomationSessionId,
        'reply_material_input_key':
            ConversationFileStore.materialInputKey(oldSource)
      };
      expect(
          await db.beginCompletedApiDelivery(
              customer: 'buyer',
              pendingId: (await db.conversation('buyer'))!.id,
              source: source),
          isNull);
      await save('new');
      final newer =
          (await (await db.database).query('generated_drafts')).single;
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'buyer',
        'state': phase,
        'timeMs': DateTime.now().millisecondsSinceEpoch + 1000
      }));
      await db.recoverDeliveryReceipts();
      expect(
          (await (await db.database).query('generated_drafts')).single, newer);
      expect(await db.isMessageFormallyAnswered('buyer', 'old'), isFalse);
      final send =
          await db.beginDeliveryAttempt(userId: 'buyer', reply: 'Answer new');
      await File(send['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': send['attemptId'],
        'customer': 'buyer',
        'state': 'submitted',
        'timeMs': DateTime.now().millisecondsSinceEpoch + 2000
      }));
      await db.recoverDeliveryReceipts();
      final restored =
          (await (await db.database).query('generated_drafts')).single;
      expect(restored['reply'], original['reply']);
      expect(restored['raw_json'], original['raw_json']);
      expect(restored['task_id'], original['task_id']);
      expect(restored['delivery_state'], 'retry');
      expect(await db.isMessageFormallyAnswered('buyer', 'new'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', 'old'), isFalse);
      expect(await db.isolateUncertainDelivery('buyer'), isFalse);
      expect(
          await db.beginDeliveryAttempt(userId: 'buyer', reply: 'Answer old'),
          isNotEmpty);
    });
  }

  test(
      'isolation during nested native verification preserves detached ownership',
      () async {
    final attempt = await lateRejection();
    await receive('new');
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch + 2000
    }));
    final paused = Completer<void>();
    final resume = Completer<void>();
    db.beforeStorageRootRead = () async {
      paused.complete();
      await resume.future;
    };
    final commit = db.markReplySent(userId: 'buyer', reply: 'Answer old');
    await paused.future;
    expect(await db.isolateUncertainDelivery('buyer'), isTrue);
    resume.complete();
    expect(await commit, isFalse);
    final ledger = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    expect(ledger['state'].toString(), startsWith('superseded_'));
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'new'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
  });

  test(
      'a confirmation after a proven no-send cancels only its restored unsent slot',
      () async {
    final attempt = await lateRejection();
    expect(await db.isolateUncertainDelivery('buyer'), isTrue);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'not_sent',
      'timeMs': DateTime.now().millisecondsSinceEpoch + 1000
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch + 2000
    }));
    await db.recoverDeliveryReceipts();
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', 'old'), isTrue);
  });

  for (final phase in [
    'unknown',
    'late_rejection_uncertain',
    'submitted',
    'not_sent',
    'rejected'
  ]) {
    test(
        'isolation during $phase receipt IO cannot reacquire or downgrade held ownership',
        () async {
      final attempt = await lateRejection();
      await receive('new');
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': 'buyer',
        'state': phase,
        'timeMs': DateTime.now().millisecondsSinceEpoch + 1000
      }));
      final paused = Completer<void>();
      final resume = Completer<void>();
      db.beforeStorageRootRead = () async {
        paused.complete();
        await resume.future;
      };
      final recovery = db.recoverDeliveryReceipts();
      await paused.future;
      expect(await db.isolateUncertainDelivery('buyer'), isTrue);
      resume.complete();
      await recovery;
      final ledger = (await (await db.database).query('delivery_attempts',
              where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
          .single;
      expect(ledger['state'].toString(), startsWith('superseded_'));
      expect(await db.hasUndeliveredDraft('buyer'), isFalse);
      if (phase != 'submitted') {
        await File(attempt['receiptPath']!).writeAsString(jsonEncode({
          'attemptId': attempt['attemptId'],
          'customer': 'buyer',
          'state': 'submitted',
          'timeMs': DateTime.now().millisecondsSinceEpoch + 2000
        }));
        await db.recoverDeliveryReceipts();
      }
      expect(await db.isMessageFormallyAnswered('buyer', 'old'), isTrue);
      expect(await db.isMessageFormallyAnswered('buyer', 'new'), isFalse);
    });
  }

  test(
      'a legacy source hold rejects direct save without requiring a session ledger',
      () async {
    await db.close();
    db = _ReceiptReadRaceDatabase(storageRoot: root);
    await db.database;
    await receive('legacy-old');
    final pending = (await db.conversation('buyer'))!;
    expect(
        await db.saveDraft(pending.id, answer('legacy answer'),
            expectedMessageId: 'legacy-old'),
        1);
    await db.beginDeliveryAttempt(userId: 'buyer', reply: 'legacy answer');
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'buyer', error: 'send_unconfirmed');
    expect(await db.isolateUncertainDelivery('buyer'), isTrue);
    expect(
        await db.saveDraft(pending.id, answer('duplicate old'),
            expectedMessageId: 'legacy-old'),
        0);
  });

  test(
      'sending attempt cannot be isolated and real unavailable guard survives isolation',
      () async {
    await receive('old');
    await save('old');
    await db.beginDeliveryAttempt(userId: 'buyer', reply: 'Answer old');
    expect(await db.isolateUncertainDelivery('buyer'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
    await db.markGeneratedDraftDeliveryFailure(
        userId: 'buyer', error: 'send_unconfirmed');
    await db.suspendUnavailableConversation('buyer', 'customer_not_receiving');
    expect(await db.isolateUncertainDelivery('buyer'), isTrue);
    expect(await db.isConversationUnavailable('buyer'), isTrue);
  });
}
