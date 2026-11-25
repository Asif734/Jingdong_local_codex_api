import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  const customer = 'buyer';
  final today = DateTime.utc(2026, 11, 10, 4);
  late Directory root;
  late DateTime clock;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v52_daily_history_');
    clock = today;
  });
  tearDown(() async => root.delete(recursive: true));

  ConversationFileStore daily([String day = '2026-11-10']) =>
      ConversationFileStore.forDay(root, businessDay: day, clock: () => clock);

  Map<String, Object?> incoming(String body, DateTime at,
          {String buyer = customer}) =>
      {
        'id': CustomerMessageTime.incomingId(buyer, at),
        'customer_message_time_key': CustomerMessageTime.incomingId(buyer, at),
        'direction': 'incoming',
        'body': body,
        'sender': buyer,
        'sent_at': at.toIso8601String(),
        'captured_at':
            at.add(const Duration(milliseconds: 100)).toIso8601String(),
        'source': 'jd_automation',
        'observed_ids': ['legacy-${at.millisecondsSinceEpoch}'],
        'service_evidence_revision': 7,
        'live_observed_session_ids': ['original-session'],
        'media': <Object?>[],
      };

  Map<String, Object?> receipt(String id, DateTime at, String boundary,
          {String status = 'submitted'}) =>
      {
        'id': 'assistant:$id',
        'direction': 'outgoing',
        'body': 'Confirmed reply $id',
        'sender': 'controlled-v52',
        'sent_at': at.toIso8601String(),
        'captured_at': at.toIso8601String(),
        'source': 'generated_reply',
        'delivery_status': status,
        'delivery_attempt_id': id,
        'delivery_task_id': 'task-$id',
        'answered_batch_end_id': boundary,
        'reply_metadata': {
          'raw_response': {
            'service_session_id': 'original-session',
            'service_message_ids': [boundary],
            'formal_response_message_ids': [boundary],
            'native_reply_at_ms': at.millisecondsSinceEpoch,
          },
        },
        'media': <Object?>[],
      };

  Future<File> legacy(List<Map<String, Object?>> messages,
      {String buyer = customer, String? name}) async {
    final file = File('${root.path}/${name ?? '$buyer.json'}');
    await file.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'user_id': buyer,
          'display_name': 'Original customer name',
          'stable_key': 'original-exact-identity',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': today.toIso8601String(),
          'extra_metadata': {'preserve': true, 'sequence': 12},
          'messages': messages,
        }),
        flush: true);
    return file;
  }

  Future<String> digest(File file) async =>
      sha256.convert(await file.readAsBytes()).toString();

  Future<CaptureAppendResult> capture(ConversationFileStore store, int second,
      {String buyer = customer, DateTime? sent}) async {
    final at = sent ?? today.add(Duration(seconds: second));
    return store.appendCapture(CapturedConversation(
        stableKey: buyer,
        customerName: buyer,
        customerExternalId: buyer,
        capturedAt: clock,
        messages: [
          CapturedMessage(
              stableId: 'captured-$buyer-$second',
              direction: 'incoming',
              sender: buyer,
              body: 'Question $second',
              sentAt: at,
              axPath: 'controlled exact original')
        ]));
  }

  AiDraft draft(String text) => AiDraft.fromJson({
        'reply': text,
        'decision': 'draft',
        'risk_level': 'low',
        'confidence': 1,
        'model': 'controlled-v52',
      }, mediaBaseUrl: Uri());

  test('business day uses JD UTC+8 independently of the computer timezone', () {
    expect(
        ConversationFileStore.businessDayFor(
            DateTime.parse('2026-11-10T15:59:59Z')),
        '2026-11-10');
    expect(
        ConversationFileStore.businessDayFor(
            DateTime.parse('2026-11-10T16:00:00Z')),
        '2026-11-11');
    expect(
        ConversationFileStore.businessDayFor(
            DateTime.parse('2026-11-11T00:00:00+08:00')),
        '2026-11-11');
    expect(() => daily('../2026-11-10'), throwsArgumentError);
    expect(() => daily('2026-02-30'), throwsArgumentError);
  });

  test('5374 historical rows are imported once into a small exact daily file',
      () async {
    final old = DateTime.utc(2026, 11, 8, 16);
    final retained = incoming('Current question', today);
    retained['media_receipt_id'] = 'original-receipt';
    retained['media'] = [
      {
        'type': 'video',
        'path': '/unchanged/original.mp4',
        'description': 'Completed original analysis',
        'is_partial': false
      }
    ];
    final sent = receipt('original-attempt', today, retained['id']! as String,
        status: 'sent');
    final source = await legacy([
      for (var i = 0; i < 5374; i++)
        incoming('Historical $i ${'x' * 1700}', old.add(Duration(seconds: i))),
      retained,
      sent,
    ]);
    expect(await source.length(), greaterThan(10000000));
    final before = await digest(source);
    final modified = (await source.stat()).modified;
    final store = daily();
    await store.prepareDay();
    final document = (await store.read(customer))!;
    expect(document['messages'], [retained, sent]);
    expect(document['extra_metadata'], {'preserve': true, 'sequence': 12});
    expect(document['history_business_day'], '2026-11-10');
    final hot = File('${store.conversationsDirectory.path}/buyer.json');
    expect(hot.path, '${root.path}/daily_history/2026-11-10/buyer.json');
    expect(await hot.length(), lessThan(10000));
    expect(await digest(source), before);
    expect((await source.stat()).modified, modified);
    expect(store.mediaDirectory.path, '${root.path}/media');

    // A hot read must not touch the old 10 MB source again, including a fresh
    // store instance in the same working day and another baseline preparation.
    await source.writeAsString('intentionally unavailable archived source');
    final restarted = daily();
    await restarted.prepareDay();
    expect((await restarted.read(customer))!['messages'], [retained, sent]);
    await capture(restarted, 1);
    expect((await restarted.read(customer))!['messages'] as List, hasLength(3));
  });

  test('a legacy customer with no messages today gets a durable empty copy',
      () async {
    final source = await legacy([
      incoming('Yesterday', today.subtract(const Duration(days: 1))),
    ]);
    final original = await digest(source);
    final store = daily();
    await store.prepareDay();
    expect((await store.read(customer))!['messages'], isEmpty);
    expect(await digest(source), original);
    await source.writeAsString('archived source is not a hot dependency');
    expect((await daily().read(customer))!['messages'], isEmpty);
  });

  test('new customers write only to the daily folder', () async {
    final store = daily();
    await store.prepareDay();
    await capture(store, 1);
    expect(await File('${root.path}/buyer.json').exists(), isFalse);
    expect((await store.read(customer))!['messages'] as List, hasLength(1));
    expect(
        await File('${store.conversationsDirectory.path}/.prepared-v1')
            .exists(),
        isTrue);
  });

  test('daily import preserves a legacy hashed filename without renaming it',
      () async {
    const buyer = '客户 / 精确账号';
    final name = 'user_${sha256.convert(utf8.encode(buyer))}.json';
    final source = await legacy([incoming('Today', today, buyer: buyer)],
        buyer: buyer, name: name);
    final original = await digest(source);
    final store = daily();
    await store.prepareDay();
    expect((await store.read(buyer))!['user_id'], buyer);
    expect(await source.exists(), isTrue);
    expect(await digest(source), original);
    expect(await File('${root.path}/${store.safeUserId(buyer)}.json').exists(),
        isFalse);
  });

  test('foreign file identity is blocked without rewriting either archive',
      () async {
    final source = await legacy([incoming('Foreign', today, buyer: 'foreign')],
        buyer: 'foreign', name: 'buyer.json');
    final original = await digest(source);
    final store = daily();
    await store.prepareDay();
    await expectLater(store.read(customer), throwsStateError);
    expect(await digest(source), original);
    expect(
        await File('${store.conversationsDirectory.path}/buyer.json').exists(),
        isFalse);
  });

  test('first preparation, capture and receipt writes share one customer owner',
      () async {
    final seed = incoming('Existing today', today);
    final source = await legacy([seed]);
    final original = await digest(source);
    final first = daily();
    final second = daily();
    await Future.wait<Object?>([
      first.prepareDay(),
      second.prepareDay(),
      for (var i = 1; i <= 20; i++) capture(i.isEven ? first : second, i),
      for (var i = 1; i <= 5; i++)
        second.appendSentReply(
            userId: customer,
            displayName: customer,
            stableKey: customer,
            draft: draft('Actual reply $i'),
            taskId: 'task-$i',
            attemptId: 'attempt-$i',
            batchEndMessageId: seed['id']! as String),
      for (var i = 0; i < 10; i++) first.read(customer),
    ]);
    final messages =
        ((await first.read(customer))!['messages'] as List).cast<Map>();
    expect(messages.where((m) => m['direction'] == 'incoming'), hasLength(21));
    expect(
        messages.where((m) => m['source'] == 'generated_reply'), hasLength(5));
    expect(messages.map((m) => m['id']).toSet(), hasLength(26));
    expect(await digest(source), original);
    expect(
        await first.conversationsDirectory
            .list()
            .where((file) => file.path.endsWith('.tmp'))
            .isEmpty,
        isTrue);
  });

  test('daily purge serializes with capture and retains exact unknown attempts',
      () async {
    final boundary = CustomerMessageTime.incomingId(customer, today);
    final owned = receipt('owned', today, boundary);
    final orphan = receipt('orphan', today, boundary);
    final sent = receipt('sent', today, boundary, status: 'sent');
    final source = await legacy([
      incoming('Today', today),
      owned,
      orphan,
      sent,
      receipt(
          'yesterday',
          today.subtract(const Duration(days: 1)),
          CustomerMessageTime.incomingId(
              customer, today.subtract(const Duration(days: 1)))),
    ]);
    final original = await digest(source);
    final store = daily();
    await store.prepareDay();
    final results = await Future.wait<Object?>([
      store.purgeLegacyUnsentDrafts(ownedDeliveryAttempts: {
        'owned': {
          'attempt_id': 'owned',
          'user_id': customer,
          'task_id': 'task-owned',
          'batch_end_message_id': boundary,
          'reply': owned['body']
        },
      }),
      capture(store, 1),
    ]);
    expect(results.first, 1);
    final messages =
        ((await store.read(customer))!['messages'] as List).cast<Map>();
    expect(messages, hasLength(4));
    expect(messages.singleWhere((m) => m['delivery_attempt_id'] == 'owned'),
        owned);
    expect(
        messages.singleWhere((m) => m['delivery_attempt_id'] == 'sent'), sent);
    expect(await digest(source), original);
  });

  test('midnight keeps old in-flight receipts in their exact original task day',
      () async {
    clock = DateTime.utc(2026, 11, 10, 15, 59, 59);
    final old = daily();
    await old.prepareDay();
    final boundary = CustomerMessageTime.incomingId(customer, clock);
    await capture(old, 1, sent: clock);
    clock = DateTime.utc(2026, 11, 10, 16, 0, 1);
    final next = daily('2026-11-11');
    await next.prepareDay();
    await old.appendSentReply(
        userId: customer,
        displayName: customer,
        stableKey: customer,
        draft: draft('Reply clicked before midnight'),
        taskId: 'old-task',
        attemptId: 'old-attempt',
        batchEndMessageId: boundary);
    expect(await next.read(customer), isNull);
    expect(
        await next.acceptAttemptReceipt(
            userId: customer, attemptId: 'old-attempt'),
        isFalse);
    expect(
        await old.acceptAttemptReceipt(
            userId: customer, attemptId: 'old-attempt'),
        isTrue);
    final oldMessages =
        ((await old.read(customer))!['messages'] as List).cast<Map>();
    expect(
        oldMessages.singleWhere((m) =>
            m['delivery_attempt_id'] == 'old-attempt')['delivery_status'],
        'sent');
    final lateCapture = await capture(old, 2, sent: clock);
    expect(lateCapture.changed, 0);
    await capture(next, 3, sent: clock);
    expect((await next.read(customer))!['messages'] as List, hasLength(1));
    expect((await old.read(customer))!['messages'] as List, hasLength(2));
  });

  test(
      'late-confirmed yesterday replies do not enter today during legacy import',
      () async {
    final previous = DateTime.utc(2026, 11, 9, 15, 59, 59);
    final question = incoming('Yesterday task', previous);
    final late = receipt('cross-midnight', DateTime.utc(2026, 11, 9, 16, 0, 1),
        question['id']! as String,
        status: 'sent');
    final current = incoming('Current question', today);
    final source = await legacy([question, late, current]);
    final before = await digest(source);
    final store = daily();
    await store.prepareDay();
    expect((await store.read(customer))!['messages'], [current]);
    expect(await digest(source), before);
  });

  test('default construction retains the legacy all-history API', () async {
    final previous =
        incoming('Yesterday', today.subtract(const Duration(days: 1)));
    final current = incoming('Today', today);
    await legacy([previous, current]);
    final store = ConversationFileStore(root);
    expect(store.businessDay, isNull);
    expect(store.conversationsDirectory.path, root.path);
    expect((await store.read(customer))!['messages'], [previous, current]);
  });

  test('an undated historical reread is not dated by today screenshot time',
      () async {
    final unknown = {
      ...incoming('Old English issue', today),
      'id': 'legacy-undated-history',
      'capture_purpose': 'history_only',
    }
      ..remove('sent_at')
      ..remove('customer_message_time_key');
    final dated = {
      ...incoming('Confirmed today', today),
      'capture_purpose': 'history_only',
    };
    final source = await legacy([unknown, dated]);
    final before = await digest(source);
    final store = daily();
    await store.prepareDay();
    expect((await store.read(customer))!['messages'], [dated]);
    expect(await digest(source), before);
  });
}
