import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_identity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'controlled-time-conflicts';
  final at = DateTime.utc(2026, 11, 10, 4, 0, 1);
  late Directory root;
  late CaptureDatabase db;
  late ConversationFileStore store;
  late CustomerMediaInventory inventory;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v49_time_conflicts_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(seconds: 1)));
    store = await db.history;
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> save(String id, DateTime? senderAt, String body,
      {String? receipt,
      String? observation,
      String? evidence,
      List<CapturedMedia> media = const [],
      bool activate = true}) async {
    await db.saveCapture(
        CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: at.add(const Duration(seconds: 10)),
            messages: [
              CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                sender: customer,
                sentAt: senderAt,
                mediaReceiptId: receipt,
                media: media,
                observationTurnKey: observation,
                captureEvidenceId: evidence,
                axPath: 'controlled time ownership input',
              )
            ]),
        activateReplies: activate,
        activeIncomingIds: {id});
  }

  Future<List<Map>> incoming() async =>
      ((await store.read(customer))?['messages'] as List? ?? const [])
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();
  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, customer]);

  test(
      'legacy stable ID and frozen locator cannot merge different sender seconds',
      () async {
    await save('legacy-same-id', at, 'first question',
        observation: 'ocr-bubble:old-locator');
    final next = at.add(const Duration(seconds: 1));
    await save('legacy-same-id', next, 'second question',
        observation: 'ocr-bubble:old-locator');
    final rows = await incoming();
    expect(rows, hasLength(2));
    expect(rows.map((m) => m['customer_message_time_key']).toSet(), {
      CustomerMessageTime.incomingId(customer, at),
      CustomerMessageTime.incomingId(customer, next),
    });
    final newer = rows.singleWhere(
        (m) => m['id'] == CustomerMessageTime.incomingId(customer, next));
    expect(ConversationFileStore.messageAliases(newer),
        isNot(contains('legacy-same-id')));
    expect((await work()).where((w) => w['response_state'] == 'pending'),
        hasLength(2));
    expect(await db.hasPendingUnanswered(customer), isTrue);
  });

  test(
      'a foreign receipt cannot steal the original time owner or its cached media',
      () async {
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'first',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    final first = await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'first',
        occurrenceKey: 'ignored',
        receivedAt: at,
        senderAt: at);
    final next = at.add(const Duration(seconds: 1));
    await save('media-pending:$receipt', next,
        '[Customer sent media; acquisition pending.]',
        receipt: receipt,
        media: const [
          CapturedMedia(type: 'image', path: '/controlled/foreign.jpg')
        ]);
    final rows = await incoming();
    expect(rows, hasLength(2));
    final newer = rows.singleWhere(
        (m) => m['id'] == CustomerMessageTime.incomingId(customer, next));
    expect(newer['media_receipt_id'], isNull);
    expect(newer['media'], isEmpty);
    final original = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [receipt]))
        .single;
    expect(original['message_id'], first.messageId);
    expect(original['sender_ms'], at.millisecondsSinceEpoch);
    await expectLater(
        db.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: 'second',
            occurrenceKey: 'ignored',
            receivedAt: next,
            senderAt: next),
        throwsStateError);
  });

  test(
      'clockless text remains observation and body similarity does not assign ownership',
      () async {
    await save('unreadable-one', null, 'printer is still offline',
        observation: 'ocr-bubble:saved-one', evidence: 'saved-one');
    await save('unreadable-two', null, 'still printer is offline',
        observation: 'ocr-bubble:saved-two', evidence: 'saved-two');
    await save('unreadable-three', null, 'printer is still offline today',
        observation: 'ocr-bubble:saved-three', evidence: 'saved-three');
    expect(await incoming(), hasLength(3));
    expect(await work(), isEmpty);
    expect(await db.hasPendingUnanswered(customer), isFalse);
    await db.repairSessionPendingWork(customer);
    expect(await work(), isEmpty);
    await save(CustomerMessageTime.incomingId(customer, at), at,
        'printer is still offline',
        observation: 'ocr-bubble:saved-one', evidence: 'saved-one');
    expect(await incoming(), hasLength(3));
    expect(await work(), hasLength(1));
    expect(await store.incomingMessageIdAtTime(customer, at), 'unreadable-one');
  });

  test('media locator cannot rewrite an already complete time identity',
      () async {
    await save('old-media', at, '[Customer sent an image]',
        media: const [
          CapturedMedia(type: 'image', path: '/controlled/original.jpg')
        ],
        activate: false);
    final id = CustomerMessageTime.incomingId(customer, at);
    final next = at.add(const Duration(seconds: 1));
    final resolver = MediaIdentityResolver(store);
    final other = await resolver.resolve(
        customer: customer,
        kind: 'image',
        digest: 'same-asset',
        observedAt: next,
        sentAt: next,
        anchoredMessageId: id);
    expect(other.id, CustomerMessageTime.incomingId(customer, next));
    expect(other.reused, isFalse);
    await store.refineMediaClock(customer, id, next,
        verifiedCardCorrection: true);
    final original = (await incoming()).single;
    expect(original['sent_at'], at.toIso8601String());
    expect(original['customer_message_time_key'], id);
    final same = await resolver.resolve(
        customer: customer,
        kind: 'image',
        digest: 'different-preview',
        observedAt: next,
        sentAt: at);
    expect(same.id, id);
    expect(same.reused, isTrue);
  });

  test(
      'new media without a complete clock is rejected at the admission boundary',
      () async {
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'clockless-source',
        observedAt: at,
        senderAt: null,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await expectLater(
        db.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: 'clockless-source',
            occurrenceKey: 'old-random-occurrence',
            receivedAt: at,
            messageId: 'old-random-message'),
        throwsStateError);
    expect(await work(), isEmpty);
    expect(await incoming(), isEmpty);
  });

  test('a history-only time record receives its first business admission once',
      () async {
    await save(
        'observed-first', at, '[Customer sent media; acquisition pending.]',
        activate: false);
    expect(await work(), isEmpty);
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'now-live',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    final first = await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'now-live',
        occurrenceKey: 'ignored',
        receivedAt: at,
        senderAt: at);
    expect(first.created, isTrue);
    final again = await db.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: 'later-frame',
        occurrenceKey: 'ignored-again',
        receivedAt: at,
        senderAt: at);
    expect(again.created, isFalse);
    expect(await incoming(), hasLength(1));
    expect(await work(), hasLength(1));
  });

  test('pre-Start clocks stay observational while the Start second is accepted',
      () async {
    final before = at.subtract(const Duration(seconds: 10));
    await save('old-transcript-question', before, 'old session question');
    await db.repairSessionPendingWork(customer);
    expect(await work(), isEmpty);
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'old-transcript-card',
        observedAt: at,
        senderAt: before,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await expectLater(
        db.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: 'old-transcript-card',
            occurrenceKey: 'old-proof',
            receivedAt: at,
            senderAt: before),
        throwsStateError);
    expect(await work(), isEmpty);
    await db.beginAutomationSession(
        startedAt: at.add(const Duration(milliseconds: 500)));
    await save('same-start-second', at, 'new same-second question');
    expect(await work(), hasLength(1));
  });
}
