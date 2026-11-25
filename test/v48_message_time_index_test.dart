import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'support/legacy_media_owner.dart';

const _customer = 'jd_time_buyer';
final _sent = DateTime.utc(2026, 11, 10, 4, 0, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v48_time_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: _sent.subtract(const Duration(seconds: 1)));
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> text(String body,
      {String customer = _customer,
      DateTime? sentAt,
      String id = 'legacy-read',
      int captureSecond = 2,
      bool masked = false}) async {
    final at = sentAt ?? _sent;
    final key = CustomerMessageTime.incomingId(customer, at);
    await db.saveCapture(
        CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: _sent.add(Duration(seconds: captureSecond)),
            messages: [
              CapturedMessage(
                  stableId: masked ? key : id,
                  direction: 'incoming',
                  body: body,
                  sender: customer,
                  sentAt: at,
                  captureEvidenceId: 'controlled-text-$captureSecond',
                  observationTurnKey: 'ocr-bubble:controlled-$captureSecond',
                  axPath: 'controlled non-media customer text')
            ]),
        activeIncomingIds: masked ? {key} : null);
  }

  Future<List<Map>> incoming([String customer = _customer]) async =>
      ((await (await db.history).read(customer))?['messages'] as List? ??
              const [])
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();
  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer]);

  test('complete UTC calendar second is the incoming identity', () {
    final key = CustomerMessageTime.incomingId('buyer:name', _sent);
    expect(key, 'incoming-time:buyer%3Aname:2026-11-10T04:00:01Z');
    expect(
        CustomerMessageTime.incomingId(
            'buyer:name', _sent.add(const Duration(milliseconds: 999))),
        key);
    expect(
        CustomerMessageTime.incomingId(
            'buyer:name', DateTime.parse('2026-11-10T12:00:01+08:00')),
        key);
    expect(CustomerMessageTime.incomingId('other', _sent), isNot(key));
    expect(
        CustomerMessageTime.incomingId(
            'buyer:name', _sent.add(const Duration(seconds: 1))),
        isNot(key));
    expect(
        CustomerMessageTime.incomingId(
            'buyer:name', _sent.add(const Duration(days: 1))),
        isNot(key));
  });

  test(
      'synthetic OCR uses full incoming seconds and never fills missing seconds with zero',
      () {
    OcrInspection view(String clock, String body, {DateTime? captured}) =>
        OcrInspection(
            image: Uint8List(0),
            imageWidth: 1440,
            imageHeight: 813,
            windowTitle: 'Controlled',
            recognizedText: '',
            activeCustomerId: _customer,
            capturedAt: captured ?? _sent.add(const Duration(seconds: 10)),
            chatLeft: .24,
            chatRight: .75,
            chatTop: .2,
            chatBottom: .8,
            observations: [
              OcrObservation(
                  text: '$_customer $clock',
                  confidence: 1,
                  x: .27,
                  y: .30,
                  width: .26,
                  height: .02),
              OcrObservation(
                  text: body,
                  confidence: 1,
                  x: .28,
                  y: .35,
                  width: .25,
                  height: .025)
            ]);
    const extractor = OcrCaptureExtractor();
    final first =
        extractor.extract(view('12:00:01', 'printer offline'))!.messages.single;
    final later = extractor
        .extract(view('12:00:01', 'printer is offline',
            captured: _sent.add(const Duration(minutes: 1))))!
        .messages
        .single;
    expect(first.stableId, CustomerMessageTime.incomingId(_customer, _sent));
    expect(later.stableId, first.stableId);
    final missing =
        extractor.extract(view('12:00', 'printer offline'))!.messages.single;
    expect(missing.sentAt, isNull);
    expect(CustomerMessageTime.isTimeId(missing.stableId), isFalse);
    for (final invalidClock in ['12:99:01', '12:00:99']) {
      final invalid = extractor.extract(view(invalidClock, 'printer offline'));
      expect(invalid?.messages.any((m) => m.sentAt != null) ?? false, isFalse,
          reason: 'Invalid OCR clocks must not become a real message time.');
    }
    final midnight = extractor
        .extract(view('23:59:59', 'printer offline',
            captured: DateTime.utc(2026, 11, 10, 16, 0, 10)))!
        .messages
        .single;
    expect(midnight.sentAt, DateTime.utc(2026, 11, 10, 15, 59, 59));
  });

  test(
      'different observations and OCR bodies in one second keep one business record',
      () async {
    await text('printer is offline', id: 'read-1');
    await text('printer is not offline', id: 'read-2', captureSecond: 20);
    await text('printer is not offline', id: 'read-3', captureSecond: 30);
    expect(await incoming(), hasLength(1));
    expect((await incoming()).single['id'],
        CustomerMessageTime.incomingId(_customer, _sent));
    expect(await work(), hasLength(1));
    expect((await db.customerMessageRecords(_customer)), hasLength(1));
    expect(await db.hasPendingUnanswered(_customer), isTrue);
    await text('another second',
        id: 'read-4', sentAt: _sent.add(const Duration(seconds: 1)));
    await text('another customer', id: 'read-5', customer: 'jd_other');
    expect(await incoming(), hasLength(2));
    expect(await incoming('jd_other'), hasLength(1));
  });

  test(
      'clockless media gains a time alias without changing its existing parent',
      () async {
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'controlled-media',
        senderAt: null,
        observedAt: _sent.add(const Duration(seconds: 2)),
        slot: 0,
        region: [.27, .3, .2, .2],
        current: true,
        occurrenceKey: 'clockless-physical-block');
    final original = await seedLegacyClocklessMediaOwner(db,
        customer: _customer,
        receiptId: receipt,
        evidenceId: 'controlled-media',
        occurrenceKey: 'clockless-physical-block',
        receivedAt: _sent.add(const Duration(seconds: 2)),
        messageId: 'temporary-owner');
    expect(original.messageId, 'temporary-owner');
    final canonical =
        await db.bindIncomingMessageTime(_customer, original.messageId, _sent);
    expect(canonical, original.messageId);
    expect(
        await db.incomingMessageIdAtTime(_customer, _sent), original.messageId);
    final repeated = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: 'controlled-later',
        occurrenceKey: 'old-caller-key',
        receivedAt: _sent.add(const Duration(seconds: 5)),
        senderAt: _sent,
        messageId: 'random-next-sequence');
    expect(repeated.messageId, original.messageId);
    expect(repeated.created, isFalse);
    expect(await incoming(), hasLength(1));
    expect((await incoming()).single['observed_ids'],
        contains(CustomerMessageTime.incomingId(_customer, _sent)));
    expect(await work(), hasLength(1));
    expect(
        (await (await db.database).query('customer_media_items',
                where: 'item_id=?', whereArgs: [receipt]))
            .single['admission_key'],
        CustomerMessageTime.occurrenceKey(_customer, _sent));
  });

  test(
      'same-second masked customer text clarifies an empty unknown owner only once',
      () async {
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'unknown',
        observedAt: _sent.add(const Duration(seconds: 2)),
        senderAt: _sent,
        slot: 0,
        region: [.27, .3, .2, .2],
        current: true);
    final original = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: 'unknown',
        occurrenceKey: 'ignored',
        receivedAt: _sent.add(const Duration(seconds: 2)),
        senderAt: _sent,
        messageId: 'random');
    expect(
        original.messageId, CustomerMessageTime.incomingId(_customer, _sent));
    await text('How can I connect it?', masked: true, captureSecond: 4);
    await text('How can I connect it?', masked: true, captureSecond: 6);
    expect(await incoming(), hasLength(1));
    expect((await incoming()).single['id'], original.messageId);
    expect((await work()).single['input_kind'], 'text');
    expect((await work()).single['response_state'], 'pending');
  });

  test(
      'native formal answer stays answered after same-second OCR and late media',
      () async {
    await text('How do I connect it?', masked: true);
    final id = CustomerMessageTime.incomingId(_customer, _sent);
    final pending = (await db.conversation(_customer))!;
    final token = (await db.beginGeneration(
        customer: _customer, pendingId: pending.id, batchEndMessageId: id))!;
    final draft = await db.prepareAutomaticDraft(
        _customer,
        AiDraft.fromJson({
          'reply': 'Connect the USB cable directly.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-time-index',
          'reply_media_dependency_keys': <String, String>{}
        }, mediaBaseUrl: Uri()));
    expect(
        await db.saveDraft(pending.id, draft,
            expectedUserId: _customer,
            expectedMessageId: id,
            generationToken: token),
        1);
    await db.abandonGeneration(_customer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
    final now = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': _customer,
      'state': 'submitted',
      'sendClickedAtMs': now,
      'timeMs': now
    }));
    await Future.wait([
      db.recoverDeliveryReceipts(),
      text('How can I connect the printer?',
          id: 'ocr-finishing-during-native-receipt', captureSecond: 35),
    ]);
    expect(await db.isMessageFormallyAnswered(_customer, id), isTrue);
    await text('How can I connect the printer?',
        id: 'later-ocr', captureSecond: 40);
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'late-media',
        observedAt: _sent.add(const Duration(seconds: 45)),
        senderAt: _sent,
        slot: 0,
        region: [.27, .3, .2, .2],
        current: true);
    final late = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: 'late-media',
        occurrenceKey: 'different-caller-key',
        receivedAt: _sent.add(const Duration(seconds: 45)),
        senderAt: _sent,
        messageId: 'must-not-win');
    expect(late.messageId, id);
    expect(late.created, isFalse);
    expect(await incoming(), hasLength(1));
    expect(await db.isMessageFormallyAnswered(_customer, id), isTrue);
    expect(await db.hasPendingUnanswered(_customer), isFalse);
    expect((await work()).where((row) => row['response_state'] == 'pending'),
        isEmpty);
    expect(await db.nextReadyDelivery(), isNull);
  });

  test(
      'merged legacy work stays as receipt audit without a ghost timeline duty',
      () async {
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'unknown-before-time',
        senderAt: null,
        observedAt: _sent.add(const Duration(seconds: 1)),
        slot: 0,
        region: [.27, .3, .2, .2],
        current: true,
        occurrenceKey: 'unresolved-physical-owner');
    final temporary = await seedLegacyClocklessMediaOwner(db,
        customer: _customer,
        receiptId: receipt,
        evidenceId: 'unknown-before-time',
        occurrenceKey: 'unresolved-physical-owner',
        receivedAt: _sent.add(const Duration(seconds: 1)),
        messageId: 'temporary-before-clock');
    await text('The printer is offline', masked: true, captureSecond: 3);
    final timeId = CustomerMessageTime.incomingId(_customer, _sent);
    final pending = (await db.conversation(_customer))!;
    final token = (await db.beginGeneration(
        customer: _customer,
        pendingId: pending.id,
        batchEndMessageId: timeId))!;
    final draft = await db.prepareAutomaticDraft(
        _customer,
        AiDraft.fromJson({
          'reply': 'Check the USB connection.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-time-alias-audit',
          'reply_media_dependency_keys': <String, String>{}
        }, mediaBaseUrl: Uri()));
    expect(
        await db.saveDraft(pending.id, draft,
            expectedUserId: _customer,
            expectedMessageId: timeId,
            generationToken: token),
        1);
    await db.abandonGeneration(_customer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
    final journal = File(attempt['receiptPath']!);
    final now = DateTime.now().millisecondsSinceEpoch;
    await journal.writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': _customer,
      'state': 'submitted',
      'sendClickedAtMs': now,
      'timeMs': now
    }));
    await db.recoverDeliveryReceipts();
    expect(await incoming(), hasLength(2));
    expect(
        await db.bindIncomingMessageTime(_customer, temporary.messageId, _sent),
        temporary.messageId);
    expect(await incoming(), hasLength(1));
    final rows = await work();
    expect(rows, hasLength(2));
    expect(
        rows
            .where((row) => row['response_state'] == 'merged')
            .single['message_id'],
        timeId);
    expect(await db.isMessageFormallyAnswered(_customer, temporary.messageId),
        isTrue);
    expect(
        (await db.processingMessages(_customer))
            .where((m) => m['direction'] == 'incoming'),
        isEmpty);
    final records = await db.customerMessageRecords(_customer);
    expect(records, hasLength(1));
    expect(records.single.replyAttemptId, attempt['attemptId']);
    expect((await db.unansweredWorkCounts())[_customer] ?? 0, 0);
    expect(await journal.exists(), isTrue);
    final storedAttempt = (await (await db.database).query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    expect(storedAttempt['state'], anyOf('submitted', 'accepted'));
    expect(
        (jsonDecode(storedAttempt['raw_json']! as String)
            as Map)['formal_response_message_ids'],
        [timeId]);
  });
}
