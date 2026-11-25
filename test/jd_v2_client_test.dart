import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/jd_v2_client.dart';

Map<String, dynamic> payload() => {
      'storeId': 'jd-grozziie',
      'customerUid': 'synthetic-customer',
      'historyVersion': 'v1',
      'idempotencyKey': 'synthetic-idempotency',
      'replyInstructions': 'Synthetic instructions',
      'messages': [
        {'id': 'm1', 'role': 'customer', 'text': 'Question', 'mediaIds': []}
      ],
      'targetMessageIds': ['m1'],
      'referencedMediaIds': [],
      'media': [],
    };

void main() {
  late HttpServer server;
  late JdV2Client client;
  late Future<void> Function(HttpRequest) handler;
  late List<String> paths;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = JdV2Client(
        baseUri:
            Uri.parse('http://127.0.0.1:${server.port}/api/codex/qianniu/v2'),
        apiKey: 'synthetic-private-key');
    paths = [];
    handler = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    };
    server.listen((request) async {
      paths.add(request.uri.toString());
      expect(request.headers.value('X-Qianniu-Key'), 'synthetic-private-key');
      await handler(request);
    });
  });
  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('cancelling one run aborts only its HTTP request on a shared client',
      () async {
    final firstReceived = Completer<void>();
    final secondReceived = Completer<void>();
    HttpRequest? second;
    handler = (request) async {
      if (request.uri.path.endsWith('/job-1')) {
        firstReceived.complete();
      } else {
        second = request;
        secondReceived.complete();
      }
    };
    final scope = JdV2Cancellation();
    final old = client.inCancellationScope(
        scope, () => client.poll('job-1', 'replies/job-1?storeId=jd-grozziie'));
    final cancelled = expectLater(old, throwsA(isA<JdV2RequestCancelled>()));
    await firstReceived.future;
    final fresh = client.poll('job-2', 'replies/job-2?storeId=jd-grozziie');
    await secondReceived.future;
    scope.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
    second!.response.write('{}');
    await second!.response.close();
    expect(await fresh.timeout(const Duration(seconds: 1)), isEmpty);
  });

  for (final sendHeaders in [false, true]) {
    test(
        'cancelPending releases stalled HTTP (headers=$sendHeaders) and reuses client',
        () async {
      final received = Completer<void>();
      handler = (request) async {
        if (sendHeaders) {
          request.response.write('{');
          await request.response.flush();
        }
        received.complete();
        // Deliberately never finish the response.
      };
      final pending = client.poll('job-1', 'replies/job-1?storeId=jd-grozziie');
      final cancelled =
          expectLater(pending, throwsA(isA<JdV2RequestCancelled>()));
      await received.future;
      client.cancelPending();
      await cancelled.timeout(const Duration(seconds: 1));
      handler = (request) async {
        request.response.write('{}');
        await request.response.close();
      };
      expect(await client.poll('job-2', 'replies/job-2?storeId=jd-grozziie'),
          isEmpty);
      expect(paths, hasLength(2));
    });
  }

  test('status preserves base path and validates JD agent and library',
      () async {
    handler = (request) async {
      request.response.write(jsonEncode({
        'platform': 'jd',
        'storeId': 'jd-grozziie',
        'agent': {'connected': true},
        'local': {
          'library': {'ready': true}
        },
      }));
      await request.response.close();
    };
    expect((await client.status())['platform'], 'jd');
    expect(paths.single, '/api/codex/qianniu/v2/status?storeId=jd-grozziie');
    handler = (request) async {
      request.response.write('{"platform":"taobao"}');
      await request.response.close();
    };
    await expectLater(
        client.status(),
        throwsA(isA<JdV2ApiException>()
            .having((e) => e.code, 'code', 'not_ready')));
  });

  test('text acceptance retry sends identical frozen JSON and ACK body',
      () async {
    final bodies = <String>[];
    handler = (request) async {
      expect(request.headers.contentType?.mimeType, 'application/json');
      bodies.add(await utf8.decoder.bind(request).join());
      request.response.statusCode = request.uri.path.endsWith('/delivery')
          ? 200
          : (bodies.length == 1 ? 503 : 202);
      request.response.write(bodies.length == 1
          ? '{"error":{"code":"capacity"}}'
          : '{"jobId":"job-1","recorded":true}');
      await request.response.close();
    };
    await expectLater(
        client.submit(payload(), []),
        throwsA(isA<JdV2ApiException>()
            .having((e) => e.transient, 'transient', true)));
    expect((await client.submit(payload(), []))['jobId'], 'job-1');
    expect(bodies[0], bodies[1]);
    final ack = {
      'storeId': 'jd-grozziie',
      'eventId': 'event-1',
      'status': 'unknown',
      'resultDigest': 'digest'
    };
    expect((await client.acknowledge('job-1', ack))['recorded'], true);
    await client.acknowledge('job-1', ack);
    expect(bodies[2], bodies[3]);
    expect(jsonDecode(bodies[2]), ack);
    expect(paths.last, '/api/codex/qianniu/v2/replies/job-1/delivery');
  });

  test(
      'multipart has known length and images in manifest order with safe filenames',
      () async {
    final temp = await Directory.systemTemp.createTemp('jd-v2-test-');
    addTearDown(() => temp.delete(recursive: true));
    final first =
        await File('${temp.path}/first.png').writeAsString('first-image-data');
    final second = await File('${temp.path}/second.webp')
        .writeAsString('second-image-data');
    final data = payload();
    data['media'] = [
      {'id': 'first', 'messageId': 'm1', 'kind': 'image'},
      {'id': 'second', 'messageId': 'm1', 'kind': 'frame'}
    ];
    (data['messages'] as List).first['mediaIds'] = ['first', 'second'];
    handler = (request) async {
      final bytes = await request
          .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
      expect(request.contentLength, bytes.length);
      expect(request.headers.contentType?.mimeType, 'multipart/form-data');
      final text = utf8.decode(bytes);
      expect(text, contains('name="request"\r\nContent-Type: text/plain'));
      expect(text, contains(jsonEncode(data)));
      expect(text.indexOf('first-image-data'),
          lessThan(text.indexOf('second-image-data')));
      expect(text, contains('filename="image-0.png"'));
      expect(text, isNot(contains(temp.path)));
      request.response.statusCode = 202;
      request.response.write('{"jobId":"job-1"}');
      await request.response.close();
    };
    await client.submit(data, [
      JdV2Upload(id: 'second', path: second.path, mimeType: 'image/webp'),
      JdV2Upload(id: 'first', path: first.path, mimeType: 'image/png')
    ]);
  });

  test('poll enforces origin endpoint job and exactly one store query',
      () async {
    for (final url in [
      'http://foreign.example/replies/job-1?storeId=jd-grozziie',
      '/replies/job-1?storeId=jd-grozziie',
      'replies/job-2?storeId=jd-grozziie',
      'replies/job-1',
      'replies/job-1?storeId=wrong',
      'replies/job-1?storeId=jd-grozziie&storeId=jd-grozziie',
      'replies/job-1?storeId=jd-grozziie&extra=yes',
    ]) {
      await expectLater(
          client.poll('job-1', url), throwsA(isA<JdV2ApiException>()));
    }
    expect(paths, isEmpty);
    await client.poll('job-1', 'replies/job-1?storeId=jd-grozziie');
    expect(paths.single,
        '/api/codex/qianniu/v2/replies/job-1?storeId=jd-grozziie');
  });

  test(
      'redirects never forward credentials and errors never expose response text',
      () async {
    handler = (request) async {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/steal');
      request.response.write(
          '{"error":{"code":"synthetic-private-key"},"secret":"sensitive customer text"}');
      await request.response.close();
    };
    await expectLater(
        client.poll('job-1', 'replies/job-1?storeId=jd-grozziie'),
        throwsA(isA<JdV2ApiException>()
            .having((e) => e.statusCode, 'status', 302)
            .having((e) => e.toString(), 'safe error',
                isNot(contains('synthetic-private-key')))
            .having((e) => e.code, 'safe code', 'http_error')));
    expect(paths, hasLength(1));
  });

  test('limits and missing uploads fail before any network call', () async {
    final data = payload();
    data['replyInstructions'] = 'x' * 16385;
    await expectLater(
        client.submit(data, []), throwsA(isA<JdV2ApiException>()));
    data['replyInstructions'] = 'ok';
    data['media'] = [
      {'id': 'missing'}
    ];
    await expectLater(
        client.submit(data, []), throwsA(isA<JdV2ApiException>()));
    expect(paths, isEmpty);
  });

  test('HTTP expiry and validation errors are permanent and retain codes',
      () async {
    for (final status in [400, 401, 403, 409, 410, 429, 500]) {
      handler = (request) async {
        request.response.statusCode = status;
        request.response.write('{"error":{"code":"synthetic_error"}}');
        await request.response.close();
      };
      await expectLater(
          client.poll('job-1', 'replies/job-1?storeId=jd-grozziie'),
          throwsA(isA<JdV2ApiException>()
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.code, 'code', 'synthetic_error')
              .having((e) => e.transient, 'transient',
                  status == 429 || status >= 500)));
    }
  });
}
