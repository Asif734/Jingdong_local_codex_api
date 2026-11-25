import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';
import 'package:jd_automation/backend/jd_v2_jobs.dart';

class FakeClient extends JdV2Client {
  FakeClient()
      : super(
            baseUri: Uri.parse('https://example.test/api'), apiKey: 'private');
  int posts = 0, polls = 0;
  Map<String, dynamic>? frozen;
  bool lostAcceptance = false, wrongCustomer = false;
  void Function()? afterSubmit;
  JdV2ApiException? pollError;
  bool serverFailed = false;
  bool processing = false;
  final firstPoll = Completer<void>();
  List<String> polledJobs = [];
  List<JdV2Upload>? submittedFiles;
  @override
  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> request, List<JdV2Upload> files) async {
    posts++;
    submittedFiles = files;
    frozen ??= request;
    expect(jsonEncode(request), jsonEncode(frozen));
    if (lostAcceptance && posts == 1) throw const JdV2ApiException('transport');
    afterSubmit?.call();
    return {
      'jobId': 'job-1',
      'pollUrl': '/api/replies/job-1?storeId=jd-grozziie'
    };
  }

  @override
  Future<Map<String, dynamic>> poll(String jobId, String pollUrl) async {
    polls++;
    if (!firstPoll.isCompleted) firstPoll.complete();
    polledJobs.add(jobId);
    if (processing) return {'status': 'processing'};
    if (pollError != null) throw pollError!;
    if (serverFailed) {
      return {
        'status': 'failed',
        'error': {'code': 'transport'}
      };
    }
    return {
      'status': 'completed',
      'jobId': jobId,
      'binding': {
        'platform': 'jd',
        'storeId': 'jd-grozziie',
        'customerUid': wrongCustomer ? 'other' : frozen!['customerUid'],
        'historyVersion': frozen!['historyVersion'],
        'jobId': jobId
      },
      'resultDigest': 'a' * 64,
      'reply': {'action': 'reply', 'reply_text': '您好'}
    };
  }
}

class GatedJournalJobs extends JdV2Jobs {
  GatedJournalJobs(super.root, super.client, this.gatedState);
  final String gatedState;
  final publishing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> beforeJournalPublish(String state) async {
    if (state == gatedState && !publishing.isCompleted) {
      publishing.complete();
      await release.future;
    }
  }
}

void main() {
  late Directory dir;
  late FakeClient client;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jd-jobs-');
    client = FakeClient();
  });
  tearDown(() async {
    client.close();
    await dir.delete(recursive: true);
  });
  Map<String, dynamic> request() => {
        'customerUid': 'customer',
        'historyVersion': 'v1',
        'idempotencyKey': 'persisted',
        'storeId': 'jd-grozziie'
      };
  test(
      'Stop interrupts long poll delay and detaches lease for immediate resume',
      () async {
    client.processing = true;
    final store =
        JdV2Jobs(dir, client, pollInterval: const Duration(minutes: 5));
    final old = store.run('input-key', request(), []);
    final cancelled = expectLater(old, throwsA(isA<JdV2RequestCancelled>()));
    await client.firstPoll.future;
    // Let the processing response reach the poll timer.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    store.cancelPending();
    client.processing = false;
    final fresh = store.resume('input-key');
    await cancelled.timeout(const Duration(seconds: 1));
    expect(
        (await fresh.timeout(const Duration(seconds: 1)))!['jobId'], 'job-1');
    expect(client.posts, 1,
        reason: 'Cancellation preserves accepted job receipt.');
    expect(client.polls, 2);
  });

  test(
      'Stop before initial journal publication cannot replace new frozen request',
      () async {
    final store = GatedJournalJobs(dir, client, 'unsubmitted');
    final scope = JdV2Cancellation();
    final old = store.run('input-key', request(), [], scope: scope);
    final cancelled = expectLater(old, throwsA(isA<JdV2RequestCancelled>()));
    await store.publishing.future;
    scope.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
    final nextRequest = {...request(), 'idempotencyKey': 'new-request'};
    final fresh = JdV2Jobs(dir, client).run('input-key', nextRequest, []);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(client.posts, 0);
    store.release.complete();
    expect((await fresh)['jobId'], 'job-1');
    expect(client.posts, 1);
    expect(client.frozen!['idempotencyKey'], 'new-request');
    final files = await Directory('${dir.path}/${JdV2Jobs.digest('input-key')}')
        .list()
        .toList();
    expect(files.where((f) => f.path.contains('.tmp-')), isEmpty);
  });

  test(
      'Stop during accepted receipt publication fences same-key resume without repost',
      () async {
    final store = GatedJournalJobs(dir, client, 'queued');
    final scope = JdV2Cancellation();
    final old = store.run('input-key', request(), [], scope: scope);
    final cancelled = expectLater(old, throwsA(isA<JdV2RequestCancelled>()));
    await store.publishing.future;
    scope.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
    var resumed = false;
    final fresh = JdV2Jobs(dir, client).resume('input-key').then((value) {
      resumed = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final postsBeforeRelease = client.posts;
    final resumedBeforeRelease = resumed;
    store.release.complete();
    await cancelled;
    expect((await fresh)!['jobId'], 'job-1');
    expect(postsBeforeRelease, 1,
        reason: 'Resume must wait for the accepted receipt publication.');
    expect(resumedBeforeRelease, isFalse);
    expect(client.posts, 1);
    expect(client.polls, 1);
    final saved = jsonDecode(
        await File('${dir.path}/${JdV2Jobs.digest('input-key')}/job.json')
            .readAsString()) as Map;
    expect(saved['state'], 'completed');
  });

  test('completed job is reused across store recreation without another POST',
      () async {
    final store = JdV2Jobs(dir, client, pollInterval: Duration.zero);
    final result = await store.run('input-key', request(), const []);
    expect(result['resultDigest'], 'a' * 64);
    await JdV2Jobs(dir, client, pollInterval: Duration.zero)
        .run('input-key', {'changed': 'body'}, const []);
    expect(client.posts, 1);
    expect(client.polls, 1);
  });
  test('lost acceptance retries exact frozen body and idempotency key',
      () async {
    client.lostAcceptance = true;
    await JdV2Jobs(dir, client, pollInterval: Duration.zero)
        .run('input-key', request(), const []);
    expect(client.posts, 2);
  });
  test('foreign completed binding cannot become an answer', () async {
    client.wrongCustomer = true;
    await expectLater(
        JdV2Jobs(dir, client, pollInterval: Duration.zero)
            .run('input-key', request(), const []),
        throwsA(isA<JdV2ApiException>()));
    expect(client.posts, 1);
  });
  test('resume finds no snapshot without submitting a job', () async {
    expect(await JdV2Jobs(dir, client).resume('missing'), isNull);
    expect(client.posts, 0);
  });

  test('accepted cancellation resumes original job without local originals',
      () async {
    final original =
        await File('${dir.path}/original.png').writeAsString('image');
    var cancelled = false;
    client.afterSubmit = () => cancelled = true;
    final store = JdV2Jobs(dir, client, pollInterval: Duration.zero);
    await expectLater(
        store.run('input-key', request(), [
          JdV2Upload(id: 'media-1', path: original.path, mimeType: 'image/png'),
        ], checkCancelled: () {
          if (cancelled) throw StateError('cancelled');
        }),
        throwsStateError);
    await original.delete();
    expect(await File(client.submittedFiles!.single.path).exists(), true);
    client.afterSubmit = null;
    final result = await JdV2Jobs(dir, client, pollInterval: Duration.zero)
        .resume('input-key');
    expect(result!['jobId'], 'job-1');
    expect(client.posts, 1);
    expect(client.polledJobs, ['job-1']);
  });

  test('corrected authentication resumes accepted job after failed poll read',
      () async {
    client.pollError = const JdV2ApiException('unauthorized', statusCode: 401);
    final store = JdV2Jobs(dir, client, pollInterval: Duration.zero);
    await expectLater(store.run('input-key', request(), []),
        throwsA(isA<JdV2ApiException>()));
    final file = File('${dir.path}/${JdV2Jobs.digest('input-key')}/job.json');
    final saved = jsonDecode(await file.readAsString());
    expect(saved['state'], 'recovery_required');
    expect(saved['jobId'], 'job-1');
    client.pollError = null;
    final result = await JdV2Jobs(dir, client, pollInterval: Duration.zero)
        .resume('input-key');
    expect(result!['jobId'], 'job-1');
    expect(client.posts, 1);
    expect(client.polledJobs, ['job-1', 'job-1']);
  });

  test('local context survives restart without entering frozen API request',
      () async {
    client.pollError = const JdV2ApiException('forbidden', statusCode: 403);
    final local = {
      'mediaRevision': 3,
      'dependencyKeys': {'m1': 'evidence'}
    };
    await expectLater(
        JdV2Jobs(dir, client, pollInterval: Duration.zero)
            .run('input-key', request(), [], localContext: local),
        throwsA(isA<JdV2ApiException>()));
    local['mediaRevision'] = 999;
    client.pollError = null;
    final result = await JdV2Jobs(dir, client, pollInterval: Duration.zero)
        .resume('input-key');
    expect(result!['_localContext'], {
      'mediaRevision': 3,
      'dependencyKeys': {'m1': 'evidence'}
    });
    expect(client.frozen!.containsKey('localContext'), false);
    expect(client.frozen!.containsKey('_localContext'), false);
    final cached = await JdV2Jobs(dir, client)
        .run('input-key', {}, [], localContext: {'mediaRevision': 999});
    expect(cached['_localContext'], result['_localContext']);
    expect(client.posts, 1);
    expect(client.polls, 2);
  });

  test('HTTP410 remains terminal across resume', () async {
    client.pollError = const JdV2ApiException('expired', statusCode: 410);
    await expectLater(
        JdV2Jobs(dir, client, pollInterval: Duration.zero)
            .run('input-key', request(), []),
        throwsA(isA<JdV2ApiException>()));
    client.pollError = null;
    await expectLater(
        JdV2Jobs(dir, client).resume('input-key'),
        throwsA(
            isA<JdV2ApiException>().having((e) => e.code, 'code', 'expired')));
    expect(client.posts, 1);
    expect(client.polls, 1);
  });
  test('server-reported failed remains terminal even with transport error code',
      () async {
    client.serverFailed = true;
    await expectLater(
        JdV2Jobs(dir, client, pollInterval: Duration.zero)
            .run('input-key', request(), []),
        throwsA(isA<JdV2ApiException>()));
    client.serverFailed = false;
    await expectLater(JdV2Jobs(dir, client).resume('input-key'),
        throwsA(isA<JdV2ApiException>()));
    expect(client.posts, 1);
    expect(client.polls, 1);
  });
}
