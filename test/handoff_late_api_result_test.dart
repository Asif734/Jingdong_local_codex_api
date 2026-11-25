import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/automatic_draft_save_result.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const buyer = 'late-api-transfer-buyer';
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_handoff_late_api_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 60000,
        isUtc: true);
    await db.beginAutomationSession(startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> incoming(String body, int second,
      {DateTime? observedAt}) async {
    final at = start.add(Duration(seconds: second));
    await db.saveCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: observedAt ?? at,
        messages: [
          CapturedMessage(
              stableId: 'late-api-$second',
              direction: 'incoming',
              sender: buyer,
              body: body,
              sentAt: at,
              captureEvidenceId: 'late-api-frame-$second',
              axPath: 'controlled exact customer message')
        ]));
    return (await db.incomingMessageIdAtTime(buyer, at))!;
  }

  AiDraft answer() => AiDraft.fromJson({
        'reply': '在打印机设置中选择对应纸张尺寸，然后重新装入纸张。',
        'decision': 'draft',
        'reply_purpose': 'substantive',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'controlled-late-api',
      }, mediaBaseUrl: Uri());

  Future<({HumanReviewTicket ticket, ChatTransferLog log, String attempt})>
      transfer(String request) async {
    final ticket = await db.createHumanReviewTicket(
        userId: buyer,
        customerRequest: 'Please transfer to the requested human agent.',
        reason: 'Explicit customer human request',
        requestMessageId: request);
    final log = (await db.reserveChatTransferLog(ticket: ticket))!;
    final attempt = await db.beginTransferAttempt(
        logId: log.id, customer: buyer, targetAccount: 'target-agent');
    await db.markTransferNativeInvoked(log.id, attempt['attemptId']!);
    return (ticket: ticket, log: log, attempt: attempt['attemptId']!);
  }

  Future<void> confirm(int logId, String attempt) async {
    await File('${root.path}/transfer_receipts/$attempt.json')
        .writeAsString(jsonEncode({
      'attemptId': attempt,
      'customer': buyer,
      'targetAccount': 'target-agent',
      'state': 'confirmed',
      'transferClicked': true,
      'timeMs':
          start.add(const Duration(milliseconds: 5500)).millisecondsSinceEpoch,
    }));
    await db.updateChatTransferLog(
        id: logId,
        status: 'transferred',
        transferClicked: true,
        expectedAttemptId: attempt);
    expect(await db.settleConfirmedTransfer(logId: logId, attemptId: attempt),
        isTrue);
  }

  Future<GenerationSnapshot?> claim(Map<String, dynamic> source) async =>
      db.beginCompletedApiDelivery(
          customer: buyer,
          pendingId: (await db.conversation(buyer))?.id ?? -1,
          source: source,
          expectedSessionId: db.currentAutomationSessionId);

  test('confirmed transfer rejects late completions for every frozen message',
      () async {
    final first = await incoming('纸张尺寸应该怎么设置？', 1);
    final request = await incoming('请转人工客服', 2);
    final firstSource = (await db.freezeReadyApiMessage(buyer, first))!;
    final requestSource = (await db.freezeReadyApiMessage(buyer, request))!;
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);

    expect(await claim(firstSource), isNull);
    expect(await claim(requestSource), isNull);
    expect(await db.hasUndeliveredDraft(buyer), isFalse);
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, buyer]);
    expect(work.map((row) => row['response_state']), everyElement('delegated'));
  });

  test(
      'old completion stays rejected after same customer returns with new text',
      () async {
    final request = await incoming('请转人工客服', 1);
    final source = (await db.freezeReadyApiMessage(buyer, request))!;
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);
    final latest = await incoming('转回来后，打印机怎么装纸？', 6);
    final latestSource = (await db.freezeReadyApiMessage(buyer, latest))!;

    expect(await claim(source), isNull);
    final current = (await claim(latestSource))!;
    expect(
        (await db.saveCompletedApiDraft(
                pendingId: (await db.conversation(buyer))!.id,
                customer: buyer,
                draft: answer(),
                source: latestSource,
                generationToken: current.token))
            .queued,
        isTrue);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: answer().reply, taskId: current.token),
        isTrue);
  });

  test('completion claimed before transfer cannot save after confirmation',
      () async {
    final request = await incoming('请转人工客服', 1);
    final source = (await db.freezeReadyApiMessage(buyer, request))!;
    final pendingId = (await db.conversation(buyer))!.id;
    final oldClaim = (await claim(source))!;
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);

    expect(
        (await db.saveCompletedApiDraft(
                pendingId: pendingId,
                customer: buyer,
                draft: answer(),
                source: source,
                generationToken: oldClaim.token))
            .outcome,
        AutomaticDraftSaveOutcome.stale);
    expect(await db.hasUndeliveredDraft(buyer), isFalse);
  });

  test('queued API reply cannot pass final native readiness after confirmation',
      () async {
    final request = await incoming('请转人工客服', 1);
    final source = (await db.freezeReadyApiMessage(buyer, request))!;
    final oldClaim = (await claim(source))!;
    expect(
        (await db.saveCompletedApiDraft(
                pendingId: (await db.conversation(buyer))!.id,
                customer: buyer,
                draft: answer(),
                source: source,
                generationToken: oldClaim.token))
            .queued,
        isTrue);
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: answer().reply, taskId: oldClaim.token),
        isFalse);
    final latest = await incoming('重新进入后的装纸问题', 6);
    final latestSource = (await db.freezeReadyApiMessage(buyer, latest))!;
    expect(await claim(latestSource), isNotNull);
    expect(await claim(source), isNull);
  });

  test('messages sent while native transfer waits are retired on confirmation',
      () async {
    final request = await incoming('请转人工客服', 1);
    final attempt = await transfer(request);
    final during = await incoming('转接之前还有一条问题', 3);
    final source = (await db.freezeReadyApiMessage(buyer, during))!;
    await confirm(attempt.log.id, attempt.attempt);
    expect(await claim(source), isNull);
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [db.currentAutomationSessionId, buyer, during]);
    expect(work.single['response_state'], 'delegated');
  });

  test('old sender time discovered after confirmation never reopens API work',
      () async {
    final request = await incoming('请转人工客服', 1);
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);
    final late = await incoming('延迟采集的转接前问题', 3);
    expect(await db.freezeReadyApiMessage(buyer, late), isNull);
    final latest = await incoming('重新进入后发送的新问题', 7);
    expect(await db.freezeReadyApiMessage(buyer, latest), isNotNull);
  });

  test('new return message in confirmation second retains its API eligibility',
      () async {
    final request = await incoming('请转人工客服', 1);
    final attempt = await transfer(request);
    await confirm(attempt.log.id, attempt.attempt);
    final latest = await incoming('重新进入后发送的新问题', 5,
        observedAt: start.add(const Duration(milliseconds: 5900)));
    final source = (await db.freezeReadyApiMessage(buyer, latest))!;
    expect(await claim(source), isNotNull);
  });

  test('a failed attempt preserves an already queued business reply', () async {
    final request = await incoming('请转人工客服', 1);
    final source = (await db.freezeReadyApiMessage(buyer, request))!;
    final completion = (await claim(source))!;
    expect(
        (await db.saveCompletedApiDraft(
                pendingId: (await db.conversation(buyer))!.id,
                customer: buyer,
                draft: answer(),
                source: source,
                generationToken: completion.token))
            .queued,
        isTrue);
    final attempt = await transfer(request);
    await db.updateChatTransferLog(
        id: attempt.log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        transferClicked: false,
        error: 'controlled native failure before click',
        expectedAttemptId: attempt.attempt);
    await db.releaseHandoffForAi(attempt.ticket.id,
        reason: 'controlled native failure before click');
    expect(await db.hasUndeliveredDraft(buyer), isTrue);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: answer().reply, taskId: completion.token),
        isTrue);
  });

  test('failed transfer retains business reply from in-flight API request',
      () async {
    final request = await incoming('请转人工客服', 1);
    final source = (await db.freezeReadyApiMessage(buyer, request))!;
    final attempt = await transfer(request);
    await db.updateChatTransferLog(
        id: attempt.log.id,
        status: 'failed',
        phase: 'retryable_preclick',
        transferClicked: false,
        error: 'controlled native failure before click',
        expectedAttemptId: attempt.attempt);
    expect(
        await db.releaseHandoffForAi(attempt.ticket.id,
            reason: 'controlled native failure before click'),
        isTrue);
    final completion = (await claim(source))!;
    expect(
        (await db.saveCompletedApiDraft(
                pendingId: (await db.conversation(buyer))!.id,
                customer: buyer,
                draft: answer(),
                source: source,
                generationToken: completion.token))
            .queued,
        isTrue);
    expect(
        await db.isCompletedApiDraftReadyForSend(
            userId: buyer, reply: answer().reply, taskId: completion.token),
        isTrue);
  });
}
