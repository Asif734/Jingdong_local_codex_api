import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

const _draft = AiDraft(
    reply: 'Formal answer',
    decision: 'draft',
    confidence: 1,
    riskLevel: 'low',
    model: 'v29',
    usedRecordIds: [],
    actions: [],
    attachments: [],
    rawJson:
        '{"reply":"Formal answer","decision":"draft","confidence":1,"risk_level":"low","model":"v29"}');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late DateTime start;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v29_response_turn_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 1000,
        isUtc: true);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> incoming(String id, int second, {bool history = false}) async {
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'a',
            customerName: 'a',
            customerExternalId: 'a',
            capturedAt: start.add(Duration(seconds: second)),
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: 'Real question $id',
                  sentAt: start.add(Duration(seconds: second)),
                  axPath: 'fixture')
            ]),
        activateReplies: !history,
        isCurrentViewport: !history);
  }

  Future<SlaFallbackJob> red(int second) async {
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(Duration(seconds: second)));
    return (await db.slaFallbackJob('a'))!;
  }

  test('continuous red re-arms for real q2 after a confirmed holding',
      () async {
    await incoming('q1', 0);
    final first = await red(0);
    expect(
        await db.reserveSlaFallback(
            userId: 'a', messageId: first.messageId, dueAt: first.dueAt),
        isTrue);
    final attempt = await db.beginSlaAttempt(first, 'Please wait');
    await db.confirmPlatformResponse('a', start.add(const Duration(seconds: 1)),
        attemptId: attempt['attemptId']);
    expect(
        (await db.platformResponseCycle('a'))!['response_boundary_id'], 'q1');
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 2)));
    expect(await db.slaFallbackJob('a'), isNull);
    await incoming('q2', 5);
    final second = await red(6);
    expect(second.batchStartMessageId, isNot(first.batchStartMessageId));
    expect(second.dueAt.toUtc(), start.add(const Duration(seconds: 26)),
        reason: 'A fresh AX red cycle starts at its observation, not q2 age.');
    expect(await db.isPlatformResponsePending(second), isTrue);
    await incoming('q3', 7);
    final sameRound = await red(8);
    expect(sameRound.batchStartMessageId, second.batchStartMessageId);
    expect(sameRound.dueAt, second.dueAt);
    expect(await db.hasPendingUnanswered('a'), isTrue);
  });

  test(
      'formal-send confirmation freezes its input boundary despite newer pending q2',
      () async {
    await incoming('q1', 0);
    final first = await red(0);
    await db.saveDraft((await db.conversations()).single.id, _draft);
    final delivery = (await db.nextReadyDelivery())!;
    final attempt = await db.beginDeliveryAttempt(
        userId: 'a', reply: _draft.reply, taskId: delivery.taskId);
    expect(
        (await (await db.database).query('delivery_attempts'))
            .single['input_boundary_id'],
        'q1');
    await incoming('q2', 5);
    expect((await db.platformResponseCycle('a'))!['state'], 'waiting',
        reason: 'cycle immediately before formal confirmation');
    await db.confirmPlatformResponse('a', start.add(const Duration(seconds: 1)),
        attemptId: attempt['attemptId']);
    expect(
        (await db.platformResponseCycle('a'))!['response_boundary_id'], 'q1');
    final next = await red(6);
    expect(next.batchStartMessageId, isNot(first.batchStartMessageId));
    expect(next.dueAt.toUtc(), start.add(const Duration(seconds: 26)));
    expect(await db.pendingMessageId('a'), 'q2');
  });

  test(
      'same-card original and late history do not manufacture another holding round',
      () async {
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: 'a',
        evidenceId: 'card',
        observedAt: start,
        senderAt: null,
        slot: 0,
        region: [.2, .3, .2, .2],
        current: true);
    await inventory.classify(receipt, 'video');
    final file = await File('${root.path}/media').writeAsBytes([1]);
    CapturedConversation media(String id, bool original, int second) =>
        CapturedConversation(
            stableKey: 'a',
            customerName: 'a',
            customerExternalId: 'a',
            capturedAt: start.add(Duration(seconds: second)),
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: '[video]',
                  axPath: 'fixture',
                  mediaReceiptId: receipt,
                  media: original
                      ? [
                          CapturedMedia(
                              type: 'video',
                              path: file.path,
                              captureSource: 'jd_video_cache'),
                          CapturedMedia(
                              type: 'image',
                              path: file.path,
                              captureSource: 'jd_video_frame_1fps')
                        ]
                      : [
                          CapturedMedia(
                              type: 'image',
                              path: file.path,
                              captureSource: 'jd_video_preview')
                        ])
            ]);
    final preview = media('preview', false, 0);
    await db.saveCapture(preview);
    await inventory.persist(preview, verifiedAnchor: true);
    final first = await red(0);
    await db.confirmPlatformResponse(
        'a', start.add(const Duration(seconds: 1)));
    final original = media('original', true, 5);
    await db.saveCapture(original);
    await inventory.persist(original, verifiedAnchor: true);
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 6)));
    expect((await db.platformResponseCycle('a'))!['cycle_id'],
        first.batchStartMessageId);
    expect(await db.slaFallbackJob('a'), isNull);
    await incoming('late-history', 7, history: true);
    await db.observePlatformResponse('a',
        red: true, observedAt: start.add(const Duration(seconds: 8)));
    expect(await db.slaFallbackJob('a'), isNull);
  });

  test('new clock session discards elapsed time without current AX digits', () {
    var mono = 0;
    var wall = start;
    final tracker =
        RedClockTracker(monotonicMs: () => mono, wallNow: () => wall);
    tracker.observe('a', present: true, ageSeconds: 19);
    mono = 1000;
    expect(tracker.remaining('a'), Duration.zero);
    tracker.beginSession();
    wall = wall.add(const Duration(minutes: 2));
    final current = tracker.observe('a', present: true)!;
    expect(current.elapsed, Duration.zero);
    expect(current.startedAt, wall);
    expect(tracker.remaining('a'), const Duration(seconds: 20));
  });

  test(
      'resume without AX digits starts fresh, not at the old persisted deadline',
      () async {
    await incoming('q1', 0);
    final old = await red(0);
    await db.requireFreshPlatformClock();
    expect(await db.isPlatformResponsePending(old), isFalse);
    final resumed = await red(40);
    expect(resumed.batchStartMessageId, isNot(old.batchStartMessageId));
    expect(resumed.dueAt.toUtc(), start.add(const Duration(seconds: 60)));
    expect((await db.platformResponseCycle('a'))!['resume_pending'], 1);
  });

  test('matching incoming history cannot backdate a resumed AX red cycle',
      () async {
    await incoming('q1', 0);
    await red(0);
    await db.requireFreshPlatformClock();
    await red(40);
    expect(
        await db.refineResumedResponseClock('a',
            visibleIncomingIds: ['different'],
            capturedAt: start.add(const Duration(seconds: 41))),
        isFalse);
    expect(
        await db.refineResumedResponseClock('a',
            visibleIncomingIds: ['q1'], capturedAt: start),
        isFalse);
    expect(
        await db.refineResumedResponseClock('a',
            visibleIncomingIds: ['q1'],
            capturedAt: start.add(const Duration(seconds: 41))),
        isFalse);
    final restored = (await db.slaFallbackJob('a'))!;
    expect(restored.dueAt.toUtc(), start.add(const Duration(seconds: 60)));
    expect((await db.platformResponseCycle('a'))!['resume_pending'], 0,
        reason:
            'The current view confirms resume without rewriting its clock.');
  });
}
