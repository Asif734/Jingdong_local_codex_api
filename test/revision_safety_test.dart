import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory media;
  final at = DateTime.now().toUtc().subtract(const Duration(seconds: 20));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_revision_');
    db = CaptureDatabase(storageRoot: root);
    media = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String id, {DateTime? time}) async => db
      .saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: time ?? at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: 'please check my video',
                sentAt: time ?? at,
                axPath: 'fixture')
          ]))
      .then((_) {});
  AiDraft draft(int revision) => AiDraft.fromJson({
        'reply': 'The full video is still loading.',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'test',
        'auto_send_allowed': false,
        'media_context_revision': revision,
        'media_dependent': true
      }, mediaBaseUrl: Uri());
  Future<void> bump() async {
    await (await db.database).rawInsert(
        'INSERT INTO customer_media_versions(customer,revision) VALUES(?,1) ON CONFLICT(customer) DO UPDATE SET revision=revision+1',
        ['buyer']);
  }

  test('uncaptured recovery obtains a durable native-send lease', () async {
    final job = await db
        .reserveRecoveryFallback(userId: 'buyer', detectedAt: at, resend: false)
        .timeout(const Duration(seconds: 3));
    expect(job, isNotNull);
    final a = await db.beginSlaAttempt(job!, 'Please wait.');
    expect(a['receiptPath'], isNotEmpty);
    expect(
        (await (await db.database).query('delivery_attempts')).single['kind'],
        'sla');
  });
  test(
      'original arriving during generation rejects the obsolete result atomically',
      () async {
    await incoming('preview');
    final c = (await db.conversations()).single;
    final result = draft(await media.revision('buyer'));
    await bump();
    expect(await db.saveDraft(c.id, result, expectedMessageId: 'preview'), 0);
    expect(await db.pendingMessageId('buyer'), 'preview');
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
  });
  for (final state in ['ready', 'sending', 'delivery_unknown']) {
    test('media revision replaces only safe queued work: $state', () async {
      await incoming('preview');
      final c = (await db.conversations()).single;
      await db.saveDraft(c.id, draft(0), expectedMessageId: 'preview');
      await (await db.database)
          .update('generated_drafts', {'delivery_state': state});
      await bump();
      expect(await db.retireStaleMediaDraft('buyer'), state == 'ready');
      expect(await db.hasUndeliveredDraft('buyer'), state != 'ready');
      if (state == 'ready') {
        expect(await db.pendingMessageId('buyer'), 'preview');
      }
    });
  }
  test('late AX failure retry keeps the original SLA deadline', () async {
    await incoming('message');
    final job = (await db.slaFallbackJob('buyer'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await db.releaseSlaFallback(userId: 'buyer', messageId: job.messageId);
    final retry = (await db.slaFallbackJob('buyer'))!;
    expect(retry.dueAt, job.dueAt);
    expect(retry.retryAt, isNotNull);
  });
  test('clicked recovery uncertainty cannot become an ordinary retry',
      () async {
    final job = (await db.reserveRecoveryFallback(
        userId: 'buyer', detectedAt: at, resend: false))!;
    final a = await db.beginSlaAttempt(job, 'Please wait.');
    await File(a['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': a['attemptId'],
      'customer': 'buyer',
      'state': 'unknown',
      'timeMs': DateTime.now().millisecondsSinceEpoch
    }));
    await db.releaseSlaFallback(userId: 'buyer', messageId: job.messageId);
    expect(await db.slaFallbackJob('buyer'), isNull);
    expect((await (await db.database).query('sla_fallbacks')).single['state'],
        'reconciling');
    expect(
        await db.reserveRecoveryFallback(
            userId: 'buyer', detectedAt: at, resend: false),
        isNull);
    expect(
        (await (await db.database).query('delivery_attempts')), hasLength(1));
  });
  test('different OCR batch IDs do not resend a native-confirmed holding',
      () async {
    await incoming('first');
    final job = (await db.slaFallbackJob('buyer'))!;
    await db.reserveSlaFallback(
        userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt);
    await db.markSlaFallbackSent(
        userId: 'buyer',
        messageId: job.messageId,
        batchStartMessageId: job.batchStartMessageId,
        reply: 'Please wait.',
        nativeConfirmed: true);
    await (await db.database).update('sla_fallbacks', {
      'state': 'pending',
      'message_id': 'different-preview',
      'batch_start_message_id': 'different-preview'
    });
    final reread = (await db.slaFallbackJob('buyer'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'buyer', messageId: reread.messageId, dueAt: reread.dueAt),
        isFalse);
    expect(await db.answeredMessageId('buyer'), isNull);
  });
  test('new fault supersedes only a harmless queued acknowledgement', () async {
    await incoming('old');
    final conversation = (await db.conversations()).single;
    final acknowledgement = AiDraft.fromJson({
      'reply': '好的，您先试一下，试打后告诉我结果。',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'test',
      'auto_send_allowed': false
    }, mediaBaseUrl: Uri());
    await db.saveDraft(conversation.id, acknowledgement,
        expectedMessageId: 'old');
    await incoming('new-fault', time: at.add(const Duration(seconds: 2)));
    expect(await db.retireStaleMediaDraft('buyer'), isTrue);
    expect(await db.pendingMessageId('buyer'), 'new-fault');
    expect(await db.answeredMessageId('buyer'), isNull);
  });
  test('a technical answer survives newer text without being discarded',
      () async {
    await incoming('old');
    final conversation = (await db.conversations()).single;
    final answer = AiDraft.fromJson({
      'reply': '先关机，按住1号键接通电源，再做自检。',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'test',
      'auto_send_allowed': false
    }, mediaBaseUrl: Uri());
    await db.saveDraft(conversation.id, answer, expectedMessageId: 'old');
    await incoming('new-fault', time: at.add(const Duration(seconds: 2)));
    expect(await db.retireStaleMediaDraft('buyer'), isFalse);
    expect(await db.hasUndeliveredDraft('buyer'), isTrue);
  });
}
