import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  final now = DateTime.now().toUtc();
  final draft = AiDraft.fromJson({
    'reply': 'A verified answer',
    'decision': 'draft',
    'confidence': 1,
    'risk_level': 'low',
    'model': 'test',
    'used_record_ids': [],
    'actions': [],
    'attachments': [],
  }, mediaBaseUrl: Uri());
  Future<void> capture(String customer, List<CapturedMessage> messages,
          {DateTime? capturedAt}) =>
      db.saveCapture(CapturedConversation(
          stableKey: 'customer:$customer',
          customerName: customer,
          customerExternalId: customer,
          capturedAt: capturedAt ?? now,
          messages: messages));
  CapturedMessage incoming(String id, DateTime at) => CapturedMessage(
      stableId: id,
      direction: 'incoming',
      body: 'Question $id',
      sentAt: at,
      axPath: 'test');
  Future<void> queued(String customer) async {
    await capture(customer, [incoming('question-$customer', now)]);
    final conversation =
        (await db.conversations()).firstWhere((c) => c.userId == customer);
    await db.saveDraft(conversation.id, draft,
        expectedMessageId: 'question-$customer');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_available_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test(
      'missing chat leaves history and draft intact without blocking other customers',
      () async {
    await queued('missing');
    await queued('visible');
    final oldTimer = (await db.slaFallbackJob('missing'))!;
    await db.suspendUnavailableConversation(
        'missing', 'conversation_not_found');
    expect((await db.nextReadyDelivery())?.userId, 'visible');
    expect(
        await db.isGeneratedDraftReadyForSend(
            userId: 'missing', reply: draft.reply),
        isFalse);
    expect(await db.slaFallbackJob('missing'), isNull);
    expect((await db.pendingSlaFallbackJobs()).map((j) => j.userId),
        isNot(contains('missing')));
    expect(
        await db.reserveSlaFallback(
            userId: 'missing',
            messageId: oldTimer.messageId,
            dueAt: oldTimer.dueAt),
        isFalse);
    expect(await db.hasUndeliveredDraft('missing'), isTrue);
    expect(await (await db.history).read('missing'), isNotNull);
  });

  test(
      'suspension survives restart and only an exact fresh sighting resumes it',
      () async {
    await queued('jd_6e4d60de36c2d');
    await db.suspendUnavailableConversation(
        'jd_6e4d60de36c2d', 'conversation_not_found');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.resumeVisibleConversations(['ja_6e4d60de36c2d']), isEmpty);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.resumeVisibleConversations(['jd_6e4d60de36c2d']),
        ['jd_6e4d60de36c2d']);
    expect((await db.nextReadyDelivery())?.userId, 'jd_6e4d60de36c2d');
    expect(await db.resumeVisibleConversations(['jd_6e4d60de36c2d']), isEmpty);
  });

  test('v14 upgrade adds suspension without losing a pending draft', () async {
    await queued('customer');
    final sqlite = await db.database;
    await sqlite.execute('DROP TABLE unavailable_conversations');
    await sqlite.execute('PRAGMA user_version = 14');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.suspendUnavailableConversation(
        'customer', 'conversation_not_found');
    expect(await db.nextReadyDelivery(), isNull);
    await db.resumeVisibleConversations(['customer']);
    expect((await db.nextReadyDelivery())?.userId, 'customer');
  });

  test('a previous turn fallback cannot discharge a new unread recovery',
      () async {
    await capture('customer',
        [incoming('old', now.subtract(const Duration(seconds: 40)))]);
    final job = (await db.slaFallbackJob('customer'))!;
    expect(
        await db.reserveSlaFallback(
            userId: 'customer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await db.markSlaFallbackSent(
        userId: 'customer', messageId: job.messageId, reply: '请稍等');
    expect(await db.hasActiveSlaFallback('customer'), isTrue);
    expect(
        await db.hasActiveSlaFallback('customer', excludingMessageIds: {'old'}),
        isFalse);
  });

  test(
      'late historical capture cannot backdate a new turn past a confirmed reply',
      () async {
    await queued('customer');
    await db.markReplySent(userId: 'customer', reply: draft.reply);
    final replyAt = DateTime.now().toUtc();
    final latestAt = replyAt.add(const Duration(seconds: 5));
    await capture(
        'customer',
        [
          incoming('late-history', now.subtract(const Duration(minutes: 2))),
          incoming('new-turn', latestAt),
        ],
        capturedAt: latestAt.add(const Duration(seconds: 6)));
    final job = (await db.slaFallbackJob('customer'))!;
    expect(job.dueAt.millisecondsSinceEpoch,
        latestAt.add(const Duration(seconds: 20)).millisecondsSinceEpoch);
    final history = await (await db.history).read('customer');
    expect(
        (history!['messages'] as List).where((m) => m['id'] == 'late-history'),
        hasLength(1));
  });

  test('messages in one unanswered turn keep the first deadline', () async {
    final firstAt = now.subtract(const Duration(seconds: 15));
    await capture('customer', [incoming('first', firstAt)]);
    final first = (await db.slaFallbackJob('customer'))!;
    await capture('customer',
        [incoming('second', now.subtract(const Duration(seconds: 2)))]);
    expect((await db.slaFallbackJob('customer'))!.dueAt, first.dueAt);
  });
}
