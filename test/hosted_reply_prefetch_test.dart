import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/hosted_reply_service.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';
import 'package:jd_automation/backend/jd_v2_jobs.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

class GatedApi extends JdV2Client {
  GatedApi()
      : super(
            baseUri: Uri.parse('https://api.example.test/v2'), apiKey: 'test');
  final requests = <String, Map<String, dynamic>>{};
  final gates = <String, Completer<void>>{};
  final twoPosted = Completer<void>();
  int closes = 0;
  int polls = 0;
  bool rejectPoll = false;
  bool stallSubmit = false;

  @override
  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> request, List<JdV2Upload> uploads) async {
    final id = 'job-${requests.length + 1}';
    requests[id] = request;
    gates[id] = Completer<void>();
    if (requests.length == 2) twoPosted.complete();
    if (stallSubmit) await Completer<void>().future;
    return {'jobId': id, 'pollUrl': '/v2/replies/$id'};
  }

  @override
  Future<Map<String, dynamic>> poll(String jobId, String pollUrl) async {
    polls++;
    if (rejectPoll) {
      throw const JdV2ApiException('unauthorized', statusCode: 401);
    }
    await gates[jobId]!.future;
    final request = requests[jobId]!;
    return {
      'status': 'completed',
      'jobId': jobId,
      'resultDigest': 'a' * 64,
      'binding': {
        'platform': 'jd',
        'storeId': request['storeId'],
        'customerUid': request['customerUid'],
        'historyVersion': request['historyVersion'],
        'jobId': jobId,
      },
      'reply': {
        'action': 'reply_then_transfer',
        'reply_text': '请同事帮您处理。',
        'transfer_reason': 'troubleshooting_exhausted',
        'product_id': null,
        'product_query': null,
        'sku_label': null,
        'reason': 'internal',
      },
    };
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

class CompletionDatabase extends CaptureDatabase {
  CompletionDatabase({required super.storageRoot});
  bool blocked = false;
  @override
  Future<Set<String>> eligibleSingleMessageIds(String customer) {
    if (blocked) throw StateError('eligible scan blocked');
    return super.eligibleSingleMessageIds(customer);
  }

  @override
  Future<bool> repairSessionPendingWork(String customer) {
    if (blocked) throw StateError('background repair blocked');
    return super.repairSessionPendingWork(customer);
  }

  @override
  Future<List<Map<String, dynamic>>> generationMessages(String customer,
      {String? batchEndMessageId, Map<String, dynamic>? document}) {
    if (blocked) throw StateError('legacy generation queue blocked');
    return super.generationMessages(customer,
        batchEndMessageId: batchEndMessageId, document: document);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CompletionDatabase db;
  late GatedApi api;
  late HostedReplyService service;
  final at = DateTime.utc(2026, 11, 18, 3);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd-prefetch-');
    db = CompletionDatabase(storageRoot: Directory('${root.path}/data'));
    await db.beginAutomationSession(
        startedAt: at.subtract(const Duration(seconds: 1)));
    api = GatedApi();
    await File('${root.path}/AGENTS.md')
        .writeAsString('Answer current messages.');
    service = HostedReplyService(
        workspace: root,
        client: api,
        jobs: JdV2Jobs(Directory('${root.path}/data/jd_v2_jobs'), api,
            pollInterval: Duration.zero));
  });
  tearDown(() async {
    api.close();
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> capture() async {
    await db.saveCapture(CapturedConversation(
        automationSessionId: db.currentAutomationSessionId,
        stableKey: 'customer',
        customerName: 'customer',
        customerExternalId: 'customer',
        capturedAt: at,
        messages: [
          for (var i = 1; i <= 2; i++)
            CapturedMessage(
                stableId: 'm$i',
                direction: 'incoming',
                sender: 'customer',
                body: '第$i个问题',
                sentAt: at.add(Duration(seconds: i)),
                axPath: 'test')
        ]));
  }

  for (final stallSubmit in [false, true]) {
    test(
        'Stop releases stalled ${stallSubmit ? 'submit' : 'poll'} and new session submits immediately',
        () async {
      api.stallSubmit = stallSubmit;
      await capture();
      final oldCompletions = <HostedReplyCompletion>[];
      final errors = <Object>[];
      final old = service.prefetchPending('customer', db,
          onCompleted: oldCompletions.add, onError: errors.add);
      await api.twoPosted.future.timeout(const Duration(seconds: 5));
      if (!stallSubmit) {
        while (api.polls < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      final session = db.currentAutomationSessionId;
      HostedReplyService.cancelRun(db, sessionId: session);
      await old.timeout(const Duration(seconds: 1));
      expect(oldCompletions, isEmpty);
      expect(errors, isEmpty);
      expect(api.closes, 0);
      final jobs = await Directory('${root.path}/data/jd_v2_jobs')
          .list()
          .where((f) => f is Directory)
          .toList();
      expect(jobs, hasLength(2));
      if (!stallSubmit) {
        for (final directory in jobs) {
          final job = jsonDecode(
              await File('${directory.path}/job.json').readAsString()) as Map;
          expect(job['jobId'], isNotNull,
              reason: 'Accepted receipts survive Stop.');
        }
      }
      await db.beginAutomationSession(
          startedAt: at.add(const Duration(minutes: 1)));
      await db.saveCapture(CapturedConversation(
        automationSessionId: db.currentAutomationSessionId,
        stableKey: 'customer',
        customerName: 'customer',
        customerExternalId: 'customer',
        capturedAt: at.add(const Duration(minutes: 1)),
        messages: [
          CapturedMessage(
              stableId: 'fresh',
              direction: 'incoming',
              sender: 'customer',
              body: '新的问题',
              sentAt: at.add(const Duration(minutes: 2)),
              axPath: 'test')
        ],
      ));
      api.stallSubmit = false;
      final freshCompletions = <HostedReplyCompletion>[];
      final fresh = service.prefetchPending('customer', db,
          onCompleted: freshCompletions.add, onError: errors.add);
      while (api.requests.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect((api.requests.values.last['messages'] as List).single['text'],
          '新的问题');
      api.gates['job-3']!.complete();
      await fresh.timeout(const Duration(seconds: 2));
      // Resolving old network work cannot notify or disturb the new lease.
      for (final entry in api.gates.entries) {
        if (!entry.value.isCompleted) entry.value.complete();
      }
      await Future<void>.delayed(Duration.zero);
      expect(oldCompletions, isEmpty);
      expect(freshCompletions, hasLength(1));
      expect(errors, isEmpty);
      expect(api.requests, hasLength(3));
      expect(api.polls, stallSubmit ? 1 : 3);
    }, timeout: const Timeout(Duration(seconds: 10)));
  }

  test(
      'same customer sources POST concurrently and completed IDs stay canonical',
      () async {
    await capture();
    var ready = 0;
    final pending = service.prefetchPending('customer', db,
        onReady: () => ready++, currentServiceAccount: 'native-colleague');
    try {
      await api.twoPosted.future.timeout(const Duration(seconds: 5));
      expect(api.requests, hasLength(2));
      expect(
          api.requests.values.every((r) =>
              (r['replyInstructions'] as String).contains('native-colleague')),
          isTrue);
      expect(await HostedReplyService.completedMessageIds('customer', db),
          isEmpty);
      expect(ready, 0);
      final messages = api.requests.values
          .map((r) => (r['messages'] as List).single as Map)
          .toList();
      expect(messages.map((m) => m['text']).toSet(), {'第1个问题', '第2个问题'});
      expect(messages.map((m) => m['id']).toSet(), hasLength(2));
      expect(
          messages.every((m) => (m['id'] as String).startsWith('jd-message-')),
          isTrue);
      final repeated = service.prefetchPending('customer', db);
      api.gates.values.first.complete();
      while (ready == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final firstCompleted =
          await HostedReplyService.completedMessageIds('customer', db);
      expect(firstCompleted, hasLength(1));
      expect({
        'incoming-time:customer:2026-11-18T03:00:01Z',
        'incoming-time:customer:2026-11-18T03:00:02Z',
      }, containsAll(firstCompleted));
      api.gates.values.last.complete();
      await Future.wait([pending, repeated]);
      expect(api.requests, hasLength(2),
          reason: 'Inflight source jobs dedupe.');
      expect(await HostedReplyService.completedMessageIds('customer', db), {
        'incoming-time:customer:2026-11-18T03:00:01Z',
        'incoming-time:customer:2026-11-18T03:00:02Z',
      });
      await service.prefetchPending('customer', db, onReady: () => ready++);
      expect(ready, 2,
          reason: 'Cached completion notifies only once per source.');
      expect(api.closes, 0, reason: 'Injected clients remain caller-owned.');
      expect(await db.hasPendingUnanswered('customer'), isTrue,
          reason:
              'Prefetch must not save a draft or apply send/transfer guards.');
    } finally {
      for (final gate in api.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await pending;
    }
  });

  test('completion directly finishes while legacy repair and queue are blocked',
      () async {
    await capture();
    final completions = <HostedReplyCompletion>[];
    final pending =
        service.prefetchPending('customer', db, onCompleted: completions.add);
    try {
      await api.twoPosted.future.timeout(const Duration(seconds: 5));
      db.blocked = true;
      for (final gate in api.gates.values) {
        gate.complete();
      }
      await pending;
      expect(completions, hasLength(2));
      for (final completion in completions) {
        expect(completion.expectedSessionId, db.currentAutomationSessionId);
        expect(completion.receivedAt.isAfter(DateTime.now()), isFalse);
        expect(completion.source['reply_work_revisions'], isNotNull);
        final local = completion.rawResult['_localContext'] as Map;
        expect(local['sourceInput']['id'], completion.sourceMessageId);
        expect(local['expectedSessionId'], db.currentAutomationSessionId);
        expect(local['guardHistory'], hasLength(2));
        final persisted = jsonDecode(await File(
                '${root.path}/data/jd_v2_jobs/${JdV2Jobs.digest(JdV2Jobs.digest({
              'customer': 'customer',
              'contextPolicy': 'single-message-v1',
              'businessDay': db.currentBusinessDayKey,
              'message': completion.sourceMessageId,
            }))}/job.json')
            .readAsString()) as Map;
        expect(persisted['localContext']['sourceInput'], completion.source);
        expect(
            persisted['localContext']['guardHistory'], local['guardHistory']);
        final draft = await service.finishCompletion(completion, db);
        expect(draft.reply, isNotEmpty);
        expect(
            completion.rawResult['_localContext']['guardHistory'], isA<List>());
        expect(() => completion.source['body'] = 'changed',
            throwsUnsupportedError);
        expect(
            () => (completion.rawResult['binding'] as Map)['jobId'] = 'other',
            throwsUnsupportedError);
      }
      expect(
          api.requests.values.every((r) =>
              !r.containsKey('guardHistory') && !r.containsKey('sourceInput')),
          isTrue);
      db.blocked = false;
      await service.prefetchPending('customer', db,
          onCompleted: completions.add);
      expect(completions, hasLength(2),
          reason: 'A completed job notifies once in the same session.');
    } finally {
      db.blocked = false;
      for (final gate in api.gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await pending;
    }
  });

  test('source errors back off without repeated API polling', () async {
    await capture();
    api.rejectPoll = true;
    final errors = <Object>[];
    await service.prefetchPending('customer', db, onError: errors.add);
    expect(errors, hasLength(2));
    expect(api.polls, 2);
    await service.prefetchPending('customer', db, onError: errors.add);
    expect(api.polls, 2);
    expect(errors, hasLength(2));
  });

  test('rejected result stays durable but cannot block other completed sources',
      () async {
    await capture();
    final pending = service.prefetchPending('customer', db);
    await api.twoPosted.future.timeout(const Duration(seconds: 5));
    for (final gate in api.gates.values) {
      gate.complete();
    }
    await pending;
    final completed =
        await HostedReplyService.completedMessageIds('customer', db);
    expect(completed, hasLength(2));
    final rejected = completed.first;
    await HostedReplyService.markResultRejected(
        db, 'customer', rejected, 'unsupported_action_or_empty_answer');
    final remaining =
        await HostedReplyService.completedMessageIds('customer', db);
    expect(remaining, completed.difference({rejected}));
    await service.prefetchPending('customer', db);
    expect(api.requests, hasLength(2));
    expect(await db.hasPendingUnanswered('customer'), isTrue);
  });

  Future<void> writeJob(String source,
      {String state = 'completed',
      String customer = 'customer',
      String? bindingCustomer}) async {
    final key = JdV2Jobs.digest({
      'customer': 'customer',
      'contextPolicy': 'single-message-v1',
      'businessDay': db.currentBusinessDayKey,
      'message': source,
    });
    final directory =
        Directory('${root.path}/data/jd_v2_jobs/${JdV2Jobs.digest(key)}');
    await directory.create(recursive: true);
    await File('${directory.path}/job.json').writeAsString(jsonEncode({
      'state': state,
      'jobId': 'fixture-job',
      'request': {
        'customerUid': customer,
        'storeId': 'jd-grozziie',
        'historyVersion': 'b' * 64,
      },
      'localContext': {'sourceMessageId': source},
      'result': {
        'jobId': 'fixture-job',
        'resultDigest': 'a' * 64,
        'reply': {'action': 'reply', 'reply_text': '答复'},
        'binding': {
          'platform': 'jd',
          'customerUid': bindingCustomer ?? customer,
          'storeId': 'jd-grozziie',
          'historyVersion': 'b' * 64,
          'jobId': 'fixture-job',
        },
      },
    }));
  }

  test('completion lookup reads only current pending source job paths',
      () async {
    await capture();
    const current = 'incoming-time:customer:2026-11-18T03:00:01Z';
    await writeJob(current);
    await writeJob('old-answered-source');
    // This unrelated directory is deliberately not a usable job document.
    final old = Directory('${root.path}/data/jd_v2_jobs/unrelated-history');
    await old.create();
    await File('${old.path}/job.json').writeAsString('not-json');
    expect(await HostedReplyService.completedMessageIds('customer', db),
        {current});
    expect(api.requests, isEmpty);
  });

  test('completion lookup excludes terminal and mismatched customer bindings',
      () async {
    await capture();
    const current = 'incoming-time:customer:2026-11-18T03:00:01Z';
    for (final state in ['failed', 'expired', 'queued']) {
      await writeJob(current, state: state);
      expect(await HostedReplyService.completedMessageIds('customer', db),
          isEmpty);
    }
    await writeJob(current, customer: 'other');
    expect(
        await HostedReplyService.completedMessageIds('customer', db), isEmpty);
    await writeJob(current, bindingCustomer: 'other');
    expect(
        await HostedReplyService.completedMessageIds('customer', db), isEmpty);
  });
}
