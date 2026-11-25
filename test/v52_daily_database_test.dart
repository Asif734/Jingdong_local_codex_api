import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'daily-buyer';
  late Directory root;
  late CaptureDatabase db;
  late DateTime now;
  late String original;
  final day = DateTime.utc(2026, 11, 10, 2);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_daily_database_');
    now = day;
    original = jsonEncode({
      'schema_version': 1,
      'user_id': customer,
      'display_name': customer,
      'stable_key': customer,
      'messages': [
        for (final entry in [
          ('yesterday', day.subtract(const Duration(days: 1))),
          ('today-baseline', day.subtract(const Duration(hours: 1)))
        ])
          {
            'id': entry.$1,
            'direction': 'incoming',
            'body': entry.$1 == 'yesterday' ? 'Yesterday English' : '早上好',
            'sender': customer,
            'sent_at': entry.$2.toIso8601String(),
            'captured_at': entry.$2.toIso8601String(),
          },
      ],
    });
    await File('${root.path}/$customer.json').writeAsString(original);
    db = CaptureDatabase(
        storageRoot: root, currentDayOnly: true, clock: () => now);
    await db.beginAutomationSession(startedAt: now);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> receive(DateTime at, {String body = 'hello'}) async {
    await db.saveCapture(CapturedConversation(
      stableKey: customer,
      customerName: customer,
      customerExternalId: customer,
      capturedAt: now.add(const Duration(seconds: 3)),
      automationSessionId: db.currentAutomationSessionId,
      messages: [
        CapturedMessage(
            stableId: 'capture-${at.toIso8601String()}',
            direction: 'incoming',
            body: body,
            sentAt: at,
            sender: customer,
            axPath: 'synthetic AX header'),
      ],
    ));
    return CustomerMessageTime.incomingId(customer, at);
  }

  test('production daily mode preloads only today into the Start baseline',
      () async {
    expect(db.currentBusinessDayKey, '2026-11-10');
    final store = await db.history;
    final document = (await store.read(customer))!;
    expect(
        (document['messages'] as List).map((m) => m['id']), ['today-baseline']);
    expect(store.conversationsDirectory.path,
        contains('daily_history/2026-11-10'));
    expect(
        await db.isSessionBaselineMessage(customer, 'today-baseline'), isTrue);
    expect(await db.isSessionBaselineMessage(customer, 'yesterday'), isFalse);
    expect(await db.hasPendingUnanswered(customer), isFalse);
    expect(await File('${root.path}/$customer.json').readAsString(), original);
  });

  test('today messages keep time identity while old screenshots never enqueue',
      () async {
    final today = await receive(now.add(const Duration(seconds: 1)));
    await receive(now.subtract(const Duration(days: 1)),
        body: 'late old frame');
    final records = await db.customerMessageRecords(customer);
    expect(records.map((r) => r.stableId), [today]);
    expect(records.single.status, 'pending');
    final document = (await (await db.history).read(customer))!;
    expect(
        (document['messages'] as List)
            .any((m) => m['body'] == 'late old frame'),
        isFalse);
    expect(await File('${root.path}/$customer.json').readAsString(), original);
  });

  test('automatic day rollover admits messages from its startup gap', () async {
    now = DateTime.utc(2026, 11, 10, 16, 0, 10);
    final sender = now.subtract(const Duration(seconds: 9));
    final todayStore = ConversationFileStore.forDay(root,
        businessDay: '2026-11-11', clock: () => now);
    await todayStore.appendCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        capturedAt: sender,
        messages: [
          CapturedMessage(
              stableId: 'rollover-gap',
              direction: 'incoming',
              body: 'hello during rollover',
              sender: customer,
              sentAt: sender,
              axPath: 'synthetic current-day input')
        ]));
    await db.beginAutomationSession(
        startedAt: db.currentCalendarDayStart,
        baselineBeforeStartedAtOnly: true);
    final id = CustomerMessageTime.incomingId(customer, sender);
    expect(await db.isSessionBaselineMessage(customer, id), isFalse);
    await receive(sender, body: 'hello during rollover');
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect((await db.customerMessageRecords(customer)).single.stableId, id);
    expect(await File('${root.path}/$customer.json').readAsString(), original);
  });

  test('new shop day archives old business without losing uncertain send proof',
      () async {
    final id = await receive(now.add(const Duration(seconds: 1)));
    final pending = (await db.conversation(customer))!;
    final token = (await db.beginGeneration(
        customer: customer, pendingId: pending.id, batchEndMessageId: id))!;
    var draft = AiDraft.fromJson({
      'reply': 'Which printer model are you using?',
      'decision': 'ask_clarification',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'synthetic-local',
      'reply_media_dependency_keys': <String, String>{},
    }, mediaBaseUrl: Uri());
    draft = await db.prepareAutomaticDraft(customer, draft);
    expect(
        (await db.saveAutomaticDraft(pending.id, draft,
                expectedMessageId: id,
                expectedUserId: customer,
                generationToken: token))
            .queued,
        isTrue);
    await db.abandonGeneration(customer, token);
    final ready = (await db.nextReadyDelivery())!;
    final send = await db.beginDeliveryAttempt(
        userId: customer, reply: draft.reply, taskId: ready.taskId);
    final attempt = send['attemptId']!;
    await db.markGeneratedDraftDeliveryFailure(
        userId: customer,
        taskId: ready.taskId,
        error: 'send_unconfirmed',
        retryDelay: Duration.zero);
    final sql = await db.database;
    final before = (await sql.query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt]))
        .single;
    final oldStore = await db.history;
    final oldSession = db.currentAutomationSessionId;
    now = now.add(const Duration(days: 1));
    expect(db.businessDayHasChanged, isTrue);
    await db.beginAutomationSession(startedAt: now);
    expect(db.currentBusinessDayKey, '2026-11-11');
    expect(db.businessDayHasChanged, isFalse);
    expect(db.currentAutomationSessionId, isNot(oldSession));
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await db.nextReadyDelivery(), isNull);
    expect(await oldStore.read(customer), isNotNull);
    expect((await (await db.history).read(customer))!['messages'], isEmpty);
    final after = (await sql.query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt]))
        .single;
    expect(after, before);
    expect(
        await sql.query('automation_archived_attempts',
            where: 'attempt_id=?', whereArgs: [attempt]),
        hasLength(1));
    expect(await File('${root.path}/$customer.json').readAsString(), original);
  });
}
