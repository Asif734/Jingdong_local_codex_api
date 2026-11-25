import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_message_activation.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  final signalAt = DateTime.utc(2026, 11, 4, 12);
  CapturedMessage text(String id,
          {DateTime? at,
          bool deferred = false,
          String direction = 'incoming',
          String? body}) =>
      CapturedMessage(
        stableId: id,
        direction: direction,
        body: body ?? 'Question $id',
        sentAt: at,
        axPath: 'OCR controlled bubble',
        observationTurnKey: 'ocr-bubble:controlled:$id'
            '${deferred ? ':clock-unresolved-after-media' : ''}',
      );
  CapturedMessage media(String id, {DateTime? at}) => CapturedMessage(
        stableId: id,
        direction: 'incoming',
        body: '[video]',
        sentAt: at,
        axPath: 'controlled video card',
        media: [CapturedMedia(type: 'video', path: '/unused/$id.mp4')],
      );
  CapturedConversation capture(List<CapturedMessage> messages) =>
      CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: signalAt.add(const Duration(seconds: 3)),
        messages: messages,
      );
  Set<String> select(List<CapturedMessage> messages) => activeLiveIncomingIds(
        capture(messages),
        replyActivationAllowed: true,
        signalAt: signalAt,
      );

  test('only workflow authorization decides whether a capture can activate',
      () {
    final fresh = capture([text('new', at: signalAt)]);
    expect(
        activeLiveIncomingIds(fresh,
            replyActivationAllowed: false, signalAt: signalAt),
        isEmpty);
    expect(
        activeLiveIncomingIds(fresh,
            replyActivationAllowed: true,
            historyCutoff: signalAt,
            signalAt: signalAt),
        {'new'});
    expect(
        activeLiveIncomingIds(null,
            replyActivationAllowed: true, signalAt: signalAt),
        isEmpty);
  });
  test('recent media anchors its following headerless real text', () {
    expect(
        select([
          media('new-video', at: signalAt),
          text('new-question', deferred: true),
          text('new-follow-up'),
        ]),
        {'new-video', 'new-question', 'new-follow-up'});
  });
  test('unknown older inputs are reported for database baseline filtering', () {
    expect(
        select([
          text('old-clockless'),
          text('old', at: signalAt.subtract(const Duration(days: 1))),
          media('new-video', at: signalAt),
          text('new-question', deferred: true),
        ]),
        {'old-clockless', 'old', 'new-video', 'new-question'});
  });
  test('sender clock alone cannot prove that an input was already answered',
      () {
    expect(
        select([
          text('old-first', at: signalAt.subtract(const Duration(days: 1))),
          text('old-latest', at: signalAt.subtract(const Duration(minutes: 5))),
        ]),
        {'old-first', 'old-latest'});
  });
  test('old media clocks do not expire the following unanswered body', () {
    expect(
        select([
          media('old-video', at: signalAt.subtract(const Duration(days: 1))),
          text('old-question', deferred: true),
        ]),
        {'old-video', 'old-question'});
  });
  test('an intervening seller reply cannot mark every earlier input answered',
      () {
    expect(
        select([
          text('answered', at: signalAt),
          text('seller', direction: 'outgoing', at: signalAt),
          media('current-video', at: signalAt),
          text('current-question', deferred: true),
        ]),
        {'answered', 'current-video', 'current-question'});
  });
  test('holding does not split the real unanswered incoming block', () {
    expect(
        select([
          media('new-video', at: signalAt),
          text('holding',
              direction: 'outgoing', body: englishHoldingReplies.first),
          text('new-question', deferred: true),
        ]),
        {'new-video', 'new-question'});
  });
  test('clockless media-only capture retains its existing activation', () {
    expect(select([media('first-video'), media('second-video')]),
        {'first-video', 'second-video'});
  });
  test('clockless media and explicitly deferred text remain one received turn',
      () {
    expect(
        select([
          text('unanchored-prior-text'),
          media('new-video'),
          text('new-question', deferred: true),
        ]),
        {'unanchored-prior-text', 'new-video', 'new-question'});
  });
  test('authorized clockless text enters the per-message work ledger', () {
    expect(select([text('unproven')]), {'unproven'});
  });
  test('known old clock does not hide a fresh clockless media/text tail', () {
    final frame = capture([
      text('known-yesterday', at: signalAt.subtract(const Duration(days: 1))),
      // Real merged captures can place these equally unclocked records in
      // either order. The deferred marker preserves the visual relationship.
      text('current-question', deferred: true),
      media('current-video'),
    ]);
    expect(
        activeLiveIncomingIds(frame,
            replyActivationAllowed: true,
            signalAt: signalAt,
            knownIncomingIds: {'known-yesterday'}),
        {'known-yesterday', 'current-question', 'current-video'});
  });
  test('an unknown old clock does not discard newly captured inputs', () {
    expect(
        select([
          text('unknown-yesterday',
              at: signalAt.subtract(const Duration(days: 1))),
          text('unproven-question', deferred: true),
          media('unproven-video'),
        ]),
        {'unknown-yesterday', 'unproven-question', 'unproven-video'});
  });
  test('activated headerless question queues while old baseline stays history',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_live_activation_');
    final db = CaptureDatabase(storageRoot: root);
    try {
      final old = text('old', at: signalAt.subtract(const Duration(days: 1)));
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: signalAt.subtract(const Duration(days: 1)),
          messages: [old]));
      await db.beginAutomationSession(startedAt: signalAt);
      final receipt = await CustomerMediaInventory(db).observe(
          customer: 'buyer',
          evidenceId: 'current-live-frame',
          observedAt: signalAt,
          senderAt: signalAt,
          slot: 0,
          region: [.28, .4, .15, .2],
          current: true,
          occurrenceKey: 'current-live-card');
      await db.admitMediaMessage('buyer',
          receiptId: receipt,
          evidenceId: 'current-live-frame',
          occurrenceKey: 'current-live-card',
          receivedAt: signalAt,
          senderAt: signalAt,
          messageId: 'current-video');
      final frame = capture([
        old,
        media('current-video', at: signalAt),
        text('current-question', deferred: true)
      ]);
      await db.saveCapture(frame,
          activeIncomingIds: activeLiveIncomingIds(frame,
              replyActivationAllowed: true, signalAt: signalAt));
      expect(await db.pendingMessageId('buyer'), 'current-question');
      expect((await db.processingMessages('buyer')).map((m) => m['id']),
          ['current-video', 'current-question']);
      expect(await db.answeredMessageId('buyer'), isNull);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
