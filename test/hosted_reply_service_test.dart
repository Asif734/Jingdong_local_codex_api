import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/hosted_reply_service.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';
import 'package:jd_automation/backend/jd_v2_jobs.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

class ApiFake extends JdV2Client {
  ApiFake()
      : super(
            baseUri: Uri.parse('https://api.example.test/v2'), apiKey: 'test');
  int posts = 0;
  String action = 'reply';
  String replyText = '请先检查打印机电源连接。';
  Map<String, dynamic>? request;
  Completer<void>? responseGate;
  final posted = Completer<void>();
  @override
  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> body, List<JdV2Upload> uploads) async {
    posts++;
    request = body;
    if (!posted.isCompleted) posted.complete();
    return {
      'jobId': 'job-$posts',
      'pollUrl': '/v2/replies/job-$posts?storeId=jd-grozziie'
    };
  }

  @override
  Future<Map<String, dynamic>> poll(String jobId, String pollUrl) async {
    await responseGate?.future;
    return {
      'status': 'completed',
      'jobId': jobId,
      'resultDigest': 'a' * 64,
      'binding': {
        'platform': 'jd',
        'storeId': 'jd-grozziie',
        'customerUid': request!['customerUid'],
        'historyVersion': request!['historyVersion'],
        'jobId': jobId
      },
      'reply': {
        'action': action,
        'reply_text': replyText,
        'transfer_reason': '需同事处理',
        'product_id': null,
        'product_query': null,
        'sku_label': null,
        'reason': 'private analysis'
      }
    };
  }
}

class RepairDatabase extends CaptureDatabase {
  RepairDatabase({required super.storageRoot});
  Map<String, Object?>? repair;
  bool onlyRequestedMessage = false;
  bool handoffUnavailable = false;
  @override
  Future<bool> isHandoffSuppressed(
          String customer, String requestMessageId) async =>
      handoffUnavailable;
  @override
  Future<Map<String, dynamic>?> handoffFallbackContext(String customer,
          {String? batchEndMessageId}) async =>
      handoffUnavailable
          ? {
              'requestMessageId': batchEndMessageId,
              'reason': 'previous attempt unavailable'
            }
          : null;
  @override
  Future<List<Map<String, dynamic>>> generationMessages(String customer,
      {String? batchEndMessageId, Map<String, dynamic>? document}) async {
    final input = await super.generationMessages(customer,
        batchEndMessageId: batchEndMessageId, document: document);
    if (!onlyRequestedMessage) return input;
    return input
        .where((m) =>
            m['direction'] == 'incoming' &&
            (m['id'] == batchEndMessageId ||
                (m['observed_ids'] as List? ?? const [])
                    .contains(batchEndMessageId)))
        .toList();
  }

  @override
  Future<Map<String, Object?>?> automaticReplyRepairContext(String customer,
          {String? generationToken}) async =>
      repair;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RepairDatabase db;
  late ApiFake client;
  late HostedReplyService service;
  final at = DateTime.utc(2026, 11, 18, 3);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd-hosted-');
    db = RepairDatabase(storageRoot: Directory('${root.path}/data'));
    client = ApiFake();
    await File('${root.path}/AGENTS.md').writeAsString(
        'Answer all unresolved target customer messages.\n## Output\nReturn only valid `reply.schema.json` JSON.');
    service = HostedReplyService(
        workspace: root,
        client: client,
        jobs: JdV2Jobs(Directory('${root.path}/jobs'), client,
            pollInterval: Duration.zero));
  });
  tearDown(() async {
    client.close();
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> capture(String id, String text, {int seconds = 0}) async {
    await db.saveCapture(CapturedConversation(
        automationSessionId: db.currentAutomationSessionId,
        stableKey: 'customer',
        customerName: 'customer',
        customerExternalId: 'customer',
        capturedAt: at.add(Duration(seconds: seconds)),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              sender: 'customer',
              body: text,
              sentAt: at.add(Duration(seconds: seconds)),
              axPath: 'test')
        ]));
  }

  for (final account in [null, '', '   ', ' 格志打印机小耿 ']) {
    test('instructions are fixed plus only AX account: $account', () async {
      // Legacy files must neither supply more rules nor be required at runtime.
      await File('${root.path}/AGENTS.md').delete();
      await capture('fixed-instruction', 'hello');
      await service.generate(
          conversation: (await db.conversation('customer'))!,
          database: db,
          batchEndMessageId: 'fixed-instruction',
          currentServiceAccount: account);
      expect(
          client.request!['replyInstructions'],
          account == null || account.trim().isEmpty
              ? '所有回复使用中文，包括客户用英文提问时。'
              : '所有回复使用中文，包括客户用英文提问时。\nAX读取的当前接待客服账号："格志打印机小耿"');
    });
  }

  test(
      'API generation preserves customer target/time and complete Chinese instructions without CLI',
      () async {
    await capture('m1', 'hello');
    final draft = await service.generate(
        conversation: (await db.conversation('customer'))!,
        database: db,
        batchEndMessageId: 'm1');
    expect(draft.reply, '请先检查打印机电源连接。');
    expect(draft.model, 'jd-hosted-v2');
    expect(client.posts, 1);
    expect((client.request!['targetMessageIds'] as List).single,
        startsWith('jd-message-'));
    expect(client.request!['customerUid'], 'customer');
    expect(client.request!['replyInstructions'], '所有回复使用中文，包括客户用英文提问时。');
    expect((client.request!['messages'] as List).single['occurredAt'],
        at.toIso8601String());
    expect(client.request!.containsKey('prompt'), isFalse);
    expect(jsonDecode(draft.rawJson)['jd_v2']['resultDigest'], 'a' * 64);
    await service.generate(
        conversation: (await db.conversation('customer'))!,
        database: db,
        batchEndMessageId: 'm1');
    expect(client.posts, 1,
        reason: 'Same immutable targets recover completed API job.');
  });
  test(
      'unsupported hosted action never becomes sendable through permissive review policy',
      () async {
    client.action = 'delete_order';
    await capture('m1', '请问支持蓝牙吗');
    await expectLater(
        service.generate(
            conversation: (await db.conversation('customer'))!, database: db),
        throwsA(isA<JdV2ApiException>()));
    expect(await db.hasPendingUnanswered('customer'), isTrue);
  });
  for (final text in [
    '转人工',
    '请帮我修改订单收货地址',
    '我要开发票',
    '我想找当前客服 customer',
    '打印机坏了需要维修',
  ]) {
    test('first backend transfer action survives local business context: $text',
        () async {
      client.action = 'reply_then_transfer';
      await capture('m1', text);
      final draft = await service.generate(
          conversation: (await db.conversation('customer'))!,
          database: db,
          batchEndMessageId: 'm1',
          currentServiceAccount: 'customer');
      final raw = jsonDecode(draft.rawJson) as Map;
      expect(draft.decision, 'human_review_required');
      expect(raw['risk_triggers'], ['service_colleague_required']);
      expect(raw['jd_v2']['reply']['action'], 'reply_then_transfer');
      expect(raw['jd_v2']['customerUid'], 'customer');
      expect(raw['jd_v2']['jobId'], 'job-1');
      expect(raw['jd_v2']['resultDigest'], 'a' * 64);
      expect(draft.reply, '请先检查打印机电源连接。');
    });
    test('backend reply stays reply despite local business context: $text',
        () async {
      await capture('m1', text);
      final draft = await service.generate(
          conversation: (await db.conversation('customer'))!, database: db);
      expect(draft.decision, 'draft');
      expect(jsonDecode(draft.rawJson)['risk_triggers'], isEmpty);
      expect(draft.reply, '请先检查打印机电源连接。');
    });
  }
  test('earlier unavailable handoff cannot override a fresh backend transfer',
      () async {
    client.action = 'reply_then_transfer';
    db.handoffUnavailable = true;
    await capture('m1', '转人工');
    final draft = await service.generate(
        conversation: (await db.conversation('customer'))!, database: db);
    expect(draft.decision, 'human_review_required');
    expect(jsonDecode(draft.rawJson)['risk_triggers'],
        ['service_colleague_required']);
  });
  for (final action in ['transfer', 'transfer_human', 'handoff']) {
    test('legacy action $action never becomes automatic transfer', () async {
      client.action = action;
      await capture('m1', '转人工');
      await expectLater(
          service.generate(
              conversation: (await db.conversation('customer'))!, database: db),
          throwsA(isA<JdV2ApiException>()));
    });
  }
  test('privacy filtering preserves backend transfer and customer job identity',
      () async {
    client.action = 'reply_then_transfer';
    client.replyText = '语音转写包含内部资料。请先关闭电源。';
    await capture('m1', '打印机需要维修');
    final draft = await service.generate(
        conversation: (await db.conversation('customer'))!, database: db);
    final raw = jsonDecode(draft.rawJson) as Map;
    expect(draft.reply, '请先关闭电源。');
    expect(draft.decision, 'human_review_required');
    expect(raw['jd_v2']['reply']['action'], 'reply_then_transfer');
    expect(raw['jd_v2']['reply']['reply_text'], client.replyText);
    expect(raw['jd_v2']['customerUid'], 'customer');
    expect(raw['jd_v2']['jobId'], 'job-1');
    expect(raw['jd_v2']['resultDigest'], 'a' * 64);
  });
  test(
      'answer repair state cannot submit the same source message as a new API job',
      () async {
    await capture('m1', '打印机不打印怎么办');
    final conversation = (await db.conversation('customer'))!;
    await service.generate(
        conversation: conversation, database: db, batchEndMessageId: 'm1');
    db.repair = {
      'failure_count': 1,
      'failure_reason': 'status_without_answer',
      'message_ids': ['m1'],
      'previous_reply': '请稍等'
    };
    await service.generate(
        conversation: conversation, database: db, batchEndMessageId: 'm1');
    expect(client.posts, 1);
    await service.generate(
        conversation: conversation, database: db, batchEndMessageId: 'm1');
    expect(client.posts, 1,
        reason: 'The source message already owns one immutable job.');
  });
  test(
      'request includes only current unanswered batch despite stored previous chat',
      () async {
    await capture('old', '旧问题：之前咨询过色带');
    await db.beginAutomationSession(
        startedAt: at.add(const Duration(seconds: 1)));
    await capture('current', '这次的问题：怎么连接电脑', seconds: 2);
    await service.generate(
        conversation: (await db.conversation('customer'))!,
        database: db,
        batchEndMessageId: 'current');
    final messages = client.request!['messages'] as List;
    expect(messages, hasLength(1));
    expect(messages.single['text'], '这次的问题：怎么连接电脑');
    expect(messages.single['id'],
        (client.request!['targetMessageIds'] as List).single);
    expect(jsonEncode(client.request), isNot(contains('旧问题')));
    expect(client.request!['replyInstructions'], '所有回复使用中文，包括客户用英文提问时。');
  });
  test(
      'one source message keeps its job despite later OCR body/revision changes',
      () async {
    await capture('m1', '看之前的聊天记录');
    final conversation = (await db.conversation('customer'))!;
    await service.generate(
        conversation: conversation, database: db, batchEndMessageId: 'm1');
    final original = jsonEncode(client.request);
    final history = await db.history;
    final doc = (await history.read('customer'))!;
    final messages = (doc['messages'] as List).whereType<Map>().toList();
    messages.single['body'] = '看之前聊天记录';
    await File('${root.path}/data/customer.json')
        .writeAsString(jsonEncode(doc));
    await service.generate(
        conversation: conversation, database: db, batchEndMessageId: 'm1');
    expect(client.posts, 1);
    expect(jsonEncode(client.request), original);
  });
  test('multiple unanswered source messages cannot silently become one API job',
      () async {
    await capture('m1', '第一个问题');
    await capture('m2', '第二个问题', seconds: 2);
    await expectLater(
        service.generate(
            conversation: (await db.conversation('customer'))!,
            database: db,
            batchEndMessageId: 'm2'),
        throwsA(isA<Exception>()));
    expect(client.posts, 0);
  });
  test(
      'OCR refresh and new message while API is pending cannot discard or expand submitted message',
      () async {
    final session = await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(seconds: 1)));
    await capture('m1', '看之前的聊天记录');
    final conversation = (await db.conversation('customer'))!;
    final claim = (await db.beginGenerationSnapshot(
        customer: 'customer',
        pendingId: conversation.id,
        batchEndMessageId: 'm1',
        singleMessage: true))!;
    client.responseGate = Completer<void>();
    final generating = service.generate(
        conversation: conversation,
        database: db,
        batchEndMessageId: claim.batchEndMessageId,
        beforeSubmit: () async {
          final checked = await db.refreezeGenerationBeforeSubmit(
              customer: 'customer',
              pendingId: conversation.id,
              generationToken: claim.token,
              batchEndMessageId: claim.batchEndMessageId,
              expectedSessionId: session,
              singleMessage: true);
          expect(checked!.expanded, isFalse);
          return null;
        });
    await client.posted.future;
    await capture('m1', '看之前聊天记录');
    await capture('m2', '我不想重复提了', seconds: 2);
    client.responseGate!.complete();
    final result = await generating;
    expect(client.posts, 1);
    expect(client.request!['messages'], hasLength(1));
    expect((client.request!['messages'] as List).single['text'], '看之前的聊天记录');
    expect(
        await db.generationInputVersionsCurrent('customer',
            generationToken: claim.token),
        isTrue);
    final saved = await db.saveAutomaticDraft(conversation.id, result,
        expectedMessageId: claim.batchEndMessageId,
        expectedUserId: 'customer',
        generationToken: claim.token);
    expect(saved.outcome.name, 'ready');
    expect(await db.hasPendingUnanswered('customer'), isTrue);
  });
}
