import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

import 'helpers/completed_video_fixture.dart';

AiDraft _reply(String body, {String? purpose, bool legacyLoading = false}) =>
    AiDraft.fromJson({
      'reply': body,
      'reply_purpose': purpose,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': legacyLoading ? 'gpt-6.1-sol' : 'controlled-fixture',
      'auto_send_allowed': false,
      'image_descriptions': <Object>[],
      if (legacyLoading) 'media_dependent': true,
    }, mediaBaseUrl: Uri());

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  var serial = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v36_reply_progress_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    serial = 0;
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> saveMessage(CapturedMessage message,
      {String customer = 'buyer'}) async {
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [message]));
  }

  Future<String> card({String kind = 'video'}) async {
    final at = DateTime.now().toUtc();
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'immutable-${serial++}',
        observedAt: at,
        senderAt: at,
        slot: serial,
        region: [.3, .4, .2, .2],
        current: true);
    await inventory.classify(receipt, kind);
    final frame = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'media-pending:$receipt',
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              sentAt: at,
              axPath: 'verified-card',
              mediaReceiptId: receipt)
        ]);
    await admitFixtureMedia(db,
        receiptId: receipt,
        messageId: 'media-pending:$receipt',
        receivedAt: at,
        senderAt: at);
    await db.saveCapture(frame);
    await inventory.persist(frame);
    return 'media-pending:$receipt';
  }

  Future<void> text(String id, String body, {String customer = 'buyer'}) =>
      saveMessage(
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body,
              sentAt: DateTime.now().toUtc(),
              axPath: 'controlled AX fixture'),
          customer: customer);

  Future<String> begin(String end, {String customer = 'buyer'}) async =>
      (await db.beginGeneration(
          customer: customer,
          pendingId: (await db.conversation(customer))!.id,
          batchEndMessageId: end))!;

  // A frozen v35 generation can still finish during an upgrade. This sets up
  // that exact old ownership state without bypassing any native send checks.
  Future<String> legacyLease(List<String> ids) async {
    final token = 'legacy-frozen-${serial++}';
    final sql = await db.database;
    final doc = (await (await db.history).read('buyer'))!;
    await sql.update('pending_customers', {'generation_token': token},
        where: 'user_id=?', whereArgs: ['buyer']);
    for (final id in ids) {
      final message = (doc['messages'] as List)
          .cast<Map>()
          .singleWhere((message) => message['id'] == id);
      final row = (await sql.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [db.currentAutomationSessionId, 'buyer', id]))
          .single;
      await sql.insert('automation_reply_inputs', {
        'session_id': db.currentAutomationSessionId,
        'user_id': 'buyer',
        'owner_id': token,
        'message_id': id,
        'message_revision': row['work_revision'],
        'message_json': jsonEncode(message),
      });
    }
    return token;
  }

  Future<int> save(AiDraft draft, String end, String token,
      {String customer = 'buyer'}) async {
    final changed = await db.saveDraft(
        (await db.conversation(customer))!.id, draft,
        expectedMessageId: end,
        expectedUserId: customer,
        generationToken: token);
    await db.abandonGeneration(customer, token);
    return changed;
  }

  Future<Map<String, String>> attempt(AiDraft draft,
          {String customer = 'buyer'}) =>
      db.beginDeliveryAttempt(userId: customer, reply: draft.reply);

  Future<void> receipt(Map<String, String> owned, String state,
      {String customer = 'buyer'}) async {
    await File(owned['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': owned['attemptId'],
      'customer': customer,
      'state': state,
      'timeMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<void> usableVideo(String id) async {
    final media =
        await completedVideoFixture(root, name: id.replaceAll(':', '_'));
    final receiptId = id.substring('media-pending:'.length);
    final current = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: 'original-$receiptId',
              direction: 'incoming',
              body: '[Customer sent video]',
              axPath: 'same exact verified card',
              mediaReceiptId: receiptId,
              media: media)
        ]);
    await db.saveCapture(current);
    await inventory.persist(current);
  }

  test('no-content media waits without an early loading draft or model turn',
      () async {
    final id = await card();
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.generationAnchorMessageId('buyer'), isNull);
    expect(await db.awaitingMediaMessageIds('buyer'), {id});
    expect(await db.nextReadyDelivery(), isNull);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer', messageId: 'red', reply: 'Please wait.');
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.generationDue('buyer'), isFalse);
  });

  test('legacy pure loading result parks both inputs without clearing business',
      () async {
    final image = await card(kind: 'image');
    final video = await card();
    final token = await legacyLease([image, video]);
    final draft = await db.prepareAutomaticDraft(
        'buyer',
        _reply(
            'Your latest media message has arrived, but its content is not available yet.',
            legacyLoading: true));
    expect(replyPurpose(draft), ReplyPurpose.mediaStatus);
    expect(await save(draft, video, token), 1);
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', image), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', video), isFalse);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.awaitingMediaMessageIds('buyer'), {image, video});
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
    for (var i = 0; i < 3; i++) {
      await (await db.database).rawUpdate(
          'UPDATE automation_session_messages SET work_revision=work_revision+1 WHERE session_id=? AND user_id=?',
          [db.currentAutomationSessionId, 'buyer']);
      expect(await db.generationDue('buyer'), isFalse,
          reason: 'A gray/crop/alias revision is not analyzable evidence');
      expect(await db.nextReadyDelivery(), isNull);
    }
  });

  test('real frames wake a parked input and formal receipt completes only it',
      () async {
    final id = await card();
    final token = await legacyLease([id]);
    final status = await db.prepareAutomaticDraft(
        'buyer',
        _reply(
            'Your media message has arrived, but its content is still loading.',
            legacyLoading: true));
    expect(await save(status, id, token), 1);
    await usableVideo(id);
    expect(await db.generationDue('buyer'), isTrue);
    final realToken = await begin(id);
    final answer = await db.prepareAutomaticDraft(
        'buyer',
        _reply('Switch off the printer and clear the paper path.',
            purpose: 'substantive'));
    expect(await save(answer, id, realToken), 1);
    final owned = await attempt(answer);
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    await receipt(owned, 'submitted');
    expect(await db.isMessageFormallyAnswered('buyer', id), isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test(
      'receipt question sends once while unknown delivery and media remain safe',
      () async {
    final id = await card();
    await text('receipt-question', 'Did you get my video?');
    final token = await begin('receipt-question');
    final draft = await db.prepareAutomaticDraft(
        'buyer',
        _reply('I can see the video message; its content is still loading.',
            purpose: 'receipt'));
    expect(replyPurpose(draft), ReplyPurpose.receipt);
    expect(await save(draft, 'receipt-question', token), 1);
    final owned = await attempt(draft);
    await receipt(owned, 'unknown');
    expect(await db.isMessageFormallyAnswered('buyer', 'receipt-question'),
        isFalse);
    expect(await db.nextReadyDelivery(), isNull);
    await receipt(owned, 'submitted');
    expect(await db.isMessageFormallyAnswered('buyer', 'receipt-question'),
        isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('independent text and another customer proceed while media is waiting',
      () async {
    final id = await card();
    await text('warranty', 'What is the warranty period?');
    await text('usb', 'How do I connect the printer?', customer: 'other');
    final token = await begin('warranty');
    final input =
        await db.generationMessages('buyer', batchEndMessageId: 'warranty');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['warranty']);
    expect(await begin('usb', customer: 'other'), isNotEmpty);
    final answer = await db.prepareAutomaticDraft('buyer',
        _reply('The warranty period is one year.', purpose: 'substantive'));
    expect(await save(answer, 'warranty', token), 1);
    await receipt(await attempt(answer), 'submitted');
    expect(await db.isMessageFormallyAnswered('buyer', 'warranty'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1, 'other': 1});
  });

  test('a media association cannot reclassify readable customer text as a card',
      () async {
    await text('video-question',
        'My printer is not working; please check this video and help me.');
    await (await db.database).insert('customer_media_items', {
      'item_id': 'associated-video',
      'customer': 'buyer',
      'sender_ms': DateTime.now().millisecondsSinceEpoch,
      'slot': 0,
      'kind': 'video',
      'state': 'pending',
      'first_seen_ms': 1,
      'last_seen_ms': 1,
      'message_id': 'video-question',
      'media_json': '[]',
      'aliases_json': jsonEncode(['video-question']),
    });
    expect(await db.generationDue('buyer'), isTrue);
    expect(await db.generationAnchorMessageId('buyer'), 'video-question');
    final token = await begin('video-question');
    final answer = await db.prepareAutomaticDraft(
        'buyer',
        _reply('Check the paper width and hold the paper guides evenly.',
            purpose: 'substantive'));
    expect(await save(answer, 'video-question', token), 1);
    await receipt(await attempt(answer), 'submitted');
    expect(
        await db.isMessageFormallyAnswered('buyer', 'video-question'), isTrue);
    expect(await db.unansweredWorkCounts(), isEmpty,
        reason:
            'A linked observation with no live admission is not another message');
    final records = await db.customerMessageRecords('buyer');
    expect(records, hasLength(1));
    expect(records.singleWhere((r) => r.stableId == 'video-question').status,
        'answered');
  });

  test('a status-waiting text input stays parked until real content advances',
      () async {
    await text('dependent-question', 'Please check the problem in this video.');
    await (await db.database).insert('customer_media_items', {
      'item_id': 'dependent-video',
      'customer': 'buyer',
      'slot': 0,
      'kind': 'video',
      'state': 'pending',
      'first_seen_ms': 1,
      'last_seen_ms': 1,
      'message_id': 'dependent-question',
      'media_json': '[]',
      'aliases_json': jsonEncode(['dependent-question']),
    });
    final token = await begin('dependent-question');
    final status = await db.prepareAutomaticDraft('buyer',
        _reply('The video content is still loading.', purpose: 'media_status'));
    expect(await save(status, 'dependent-question', token), 1);
    expect(await db.generationDue('buyer'), isFalse,
        reason: 'input_kind=text cannot bypass an existing evidence wait');
    expect(await db.nextReadyDelivery(), isNull);
    await (await db.database).update(
        'customer_media_items',
        {
          'state': 'preview',
          'media_json': jsonEncode([
            {
              'type': 'image',
              'path': '/controlled/gray.jpg',
              'capture_source': 'jd_video_preview',
              'is_loading_preview': true
            }
          ])
        },
        where: 'item_id=?',
        whereArgs: ['dependent-video']);
    expect(await db.generationDue('buyer'), isFalse);

    await (await db.database).update(
        'customer_media_items',
        {
          'state': 'ready',
          'media_json': jsonEncode([
            {
              'type': 'image',
              'path': '/controlled/decoded-frame.jpg',
              'capture_source': 'jd_video_frame_1fps'
            }
          ])
        },
        where: 'item_id=?',
        whereArgs: ['dependent-video']);
    expect(await db.generationDue('buyer'), isTrue);
    expect(await begin('dependent-question'), isNotEmpty);
    expect(await db.isMessageFormallyAnswered('buyer', 'dependent-question'),
        isFalse);
  });

  test('mixed media and dependent text status do not regenerate the same input',
      () async {
    final id = await card();
    await text('check-video', 'Please check the problem in this video.');
    final token = await legacyLease([id, 'check-video']);
    final status = await db.prepareAutomaticDraft('buyer',
        _reply('The video content is still loading.', purpose: 'media_status'));
    expect(await save(status, 'check-video', token), 1);
    expect(await db.awaitingMediaMessageIds('buyer'), {id, 'check-video'});
    for (var i = 0; i < 3; i++) {
      expect(await db.generationDue('buyer'), isFalse);
      expect(await db.generationAnchorMessageId('buyer'), isNull);
      expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    }
    await usableVideo(id);
    expect(await db.generationDue('buyer'), isTrue);
    expect(await begin('check-video'), isNotEmpty);
    final input =
        await db.generationMessages('buyer', batchEndMessageId: 'check-video');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        containsAll([id, 'check-video']));
  });

  test('mixed status parks dependent text without delaying independent text',
      () async {
    final id = await card();
    await text('check-video', 'My printer is not working; check this video.');
    await text('warranty', 'What is the warranty period?');
    final token = await legacyLease([id, 'check-video', 'warranty']);
    final status = await db.prepareAutomaticDraft('buyer',
        _reply('The video content is still loading.', purpose: 'media_status'));
    expect(await save(status, 'warranty', token), 1);
    expect(await db.awaitingMediaMessageIds('buyer'), {id, 'check-video'});
    expect(await db.generationDue('buyer'), isTrue);
    final nextToken = await begin('warranty');
    final input =
        await db.generationMessages('buyer', batchEndMessageId: 'warranty');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['warranty']);
    final answer = await db.prepareAutomaticDraft('buyer',
        _reply('The warranty period is one year.', purpose: 'substantive'));
    expect(await save(answer, 'warranty', nextToken), 1);
    await receipt(await attempt(answer), 'submitted');
    expect(await db.isMessageFormallyAnswered('buyer', 'warranty'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'check-video'), isFalse);
    expect(await db.generationDue('buyer'), isFalse);
  });

  test(
      'positive reconciliation of a v35 loading send cannot mark media answered',
      () async {
    final id = await card();
    final token = await legacyLease([id]);
    // Raw v35 GPT output had no purpose, media_dependent=true and no images.
    final legacy = _reply(
        'Your media message has arrived, but its content is still loading.',
        legacyLoading: true);
    expect(await save(legacy, id, token), 1);
    final owned = await attempt(legacy);
    await receipt(owned, 'unknown');
    expect(await db.nextReadyDelivery(), isNull);
    await receipt(owned, 'submitted');
    expect(await db.hasUndeliveredDraft('buyer'), isFalse);
    expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
    expect(await db.generationDue('buyer'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('Start isolates old evidence waits and lets a fresh text question run',
      () async {
    final old = await card();
    final oldSession = db.currentAutomationSessionId!;
    final token = await legacyLease([old]);
    final status = await db.prepareAutomaticDraft(
        'buyer',
        _reply(
            'Your media message has arrived, but its content is still loading.',
            legacyLoading: true));
    expect(await save(status, old, token), 1);
    expect(await db.awaitingMediaMessageIds('buyer'), {old});
    expect(await db.generationDue('buyer'), isFalse);
    expect(
        await (await db.database).query('automation_message_waits',
            where: 'session_id=?', whereArgs: [oldSession]),
        hasLength(1));

    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    expect(await db.awaitingMediaMessageIds('buyer'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    await text('fresh-question', 'How do I connect the printer by USB?');
    expect(await db.generationDue('buyer'), isTrue);
    expect(await begin('fresh-question'), isNotEmpty);
    final input = await db.generationMessages('buyer',
        batchEndMessageId: 'fresh-question');
    expect(input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
        ['fresh-question']);
    expect(await db.isCurrentSessionMessage('buyer', old), isFalse);
    expect(await db.isSessionBaselineMessage('buyer', old), isTrue);
  });
}
