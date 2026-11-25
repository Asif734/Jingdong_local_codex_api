import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Local cancellation is separate from API errors and must never trigger retries.
class JdV2RequestCancelled implements Exception {
  const JdV2RequestCancelled();
}

class JdV2Cancellation {
  final _cancelled = Completer<void>();
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled.isCompleted;
  void check() {
    if (isCancelled) throw const JdV2RequestCancelled();
  }

  void cancel() {
    if (isCancelled) return;
    _cancelled.complete();
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  Future<void> delay(Duration duration) async {
    check();
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await wait(elapsed.future);
    } finally {
      timer.cancel();
    }
  }

  Future<T> wait<T>(Future<T> operation) async {
    // Attach to the supplied future even if cancellation happened while the
    // caller created it, so a late transport error remains observed.
    final result = await Future.any<T>([
      operation,
      _cancelled.future.then<T>((_) => throw const JdV2RequestCancelled()),
    ]);
    check();
    return result;
  }
}

class JdV2Upload {
  const JdV2Upload(
      {required this.id, required this.path, required this.mimeType});
  final String id;
  final String path;
  final String mimeType;
}

class JdV2ApiException implements Exception {
  const JdV2ApiException(this.code, {this.statusCode});
  final int? statusCode;
  final String code;
  bool get transient =>
      code == 'transport' ||
      code == 'timeout' ||
      statusCode == 429 ||
      (statusCode != null && statusCode! >= 500 && statusCode! <= 599);

  // Never interpolate server strings, URLs, credentials or response bodies.
  @override
  String toString() =>
      'JD API request failed${statusCode == null ? '' : ' (HTTP $statusCode)'}.';
}

class JdV2Client {
  JdV2Client(
      {required Uri baseUri, required String apiKey, HttpClient? httpClient})
      : _baseUri = baseUri.replace(
            path: baseUri.path.replaceFirst(RegExp(r'/+$'), ''),
            query: null,
            fragment: null),
        _apiKey = apiKey,
        _httpClient = httpClient ?? HttpClient() {
    if (!{'http', 'https'}.contains(baseUri.scheme) ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        apiKey.trim().isEmpty ||
        apiKey.contains(RegExp(r'[\r\n]'))) {
      throw const JdV2ApiException('invalid_configuration');
    }
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  static const storeId = 'jd-grozziie';
  static const _mib = 1024 * 1024;
  final Uri _baseUri;
  final String _apiKey;
  final HttpClient _httpClient;
  final Map<JdV2Cancellation, void Function()> _pending = {};
  static final _scopeKey = Object();

  Future<T> inCancellationScope<T>(
          JdV2Cancellation cancellation, Future<T> Function() operation) =>
      runZoned(operation, zoneValues: {_scopeKey: cancellation});
  int _cancelEpoch = 0;

  /// Abort only current work; the client can serve a later automation run.
  void cancelPending() {
    _cancelEpoch++;
    for (final entry in _pending.entries.toList()) {
      entry.key.cancel();
      entry.value();
    }
    _pending.clear();
  }

  Uri _endpoint(String suffix, {bool store = false}) => _baseUri.replace(
      path: '${_baseUri.path}/$suffix',
      queryParameters: store ? const {'storeId': storeId} : null);

  String _job(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(id)) {
      throw const JdV2ApiException('invalid_job_id');
    }
    return id;
  }

  Future<Map<String, dynamic>> status() async {
    final result =
        await _send('GET', _endpoint('status', store: true), expected: 200);
    if (result['platform'] != 'jd' ||
        result['storeId'] != storeId ||
        (result['agent'] as Object?) is! Map ||
        (result['agent'] as Map)['connected'] != true ||
        result['local'] is! Map ||
        (result['local'] as Map)['library'] is! Map ||
        ((result['local'] as Map)['library'] as Map)['ready'] != true) {
      throw const JdV2ApiException('not_ready');
    }
    return result;
  }

  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> request, List<JdV2Upload> uploads) async {
    final epoch = _cancelEpoch;
    final scope = Zone.current[_scopeKey] as JdV2Cancellation?;
    scope?.check();
    final json = _validateRequest(request);
    final media = request['media'] as List;
    if (uploads.length != media.length ||
        uploads.length > 50 ||
        uploads.map((item) => item.id).toSet().length != uploads.length) {
      throw const JdV2ApiException('invalid_uploads');
    }
    if (uploads.isEmpty) {
      return _send('POST', _endpoint('replies'),
          expected: 202,
          body: json,
          contentType: 'application/json; charset=utf-8');
    }
    final byId = {for (final upload in uploads) upload.id: upload};
    final ordered = <JdV2Upload>[];
    for (final item in media) {
      if (item is! Map ||
          item['id'] is! String ||
          !byId.containsKey(item['id'])) {
        throw const JdV2ApiException('invalid_uploads');
      }
      ordered.add(byId[item['id']]!);
    }
    if (ordered.map((item) => item.id).toSet().length != ordered.length) {
      throw const JdV2ApiException('invalid_uploads');
    }
    final boundary =
        'jd-v2-${List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final bytes = BytesBuilder(copy: false);
    void append(String text) => bytes.add(utf8.encode(text));
    append(
        '--$boundary\r\nContent-Disposition: form-data; name="request"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n');
    bytes.add(json);
    append('\r\n');
    var combined = 0;
    for (var index = 0; index < ordered.length; index++) {
      final upload = ordered[index];
      final extension = const {
        'image/png': 'png',
        'image/jpeg': 'jpg',
        'image/webp': 'webp'
      }[upload.mimeType];
      if (extension == null) throw const JdV2ApiException('unsupported_media');
      try {
        final file = File(upload.path);
        final length = await file.length();
        scope?.check();
        if (length > 20 * _mib || combined + length > 50 * _mib) {
          throw const JdV2ApiException('media_too_large');
        }
        final image = BytesBuilder(copy: false);
        await for (final chunk in file.openRead()) {
          scope?.check();
          if (image.length + chunk.length > 20 * _mib ||
              combined + image.length + chunk.length > 50 * _mib) {
            throw const JdV2ApiException('media_too_large');
          }
          image.add(chunk);
        }
        combined += image.length;
        append(
            '--$boundary\r\nContent-Disposition: form-data; name="images"; filename="image-$index.$extension"\r\nContent-Type: ${upload.mimeType}\r\n\r\n');
        bytes.add(image.takeBytes());
        append('\r\n');
      } on FileSystemException {
        throw const JdV2ApiException('media_unavailable');
      }
    }
    append('--$boundary--\r\n');
    if (bytes.length > 55 * _mib) {
      throw const JdV2ApiException('multipart_too_large');
    }
    scope?.check();
    if (epoch != _cancelEpoch) throw const JdV2RequestCancelled();
    return _send('POST', _endpoint('replies'),
        expected: 202,
        body: bytes.takeBytes(),
        contentType: 'multipart/form-data; boundary=$boundary');
  }

  List<int> _validateRequest(Map<String, dynamic> request) {
    if (request['storeId'] != storeId ||
        request.containsKey('platform') ||
        request.containsKey('prompt') ||
        request.containsKey('model') ||
        request.containsKey('testOnly')) {
      throw const JdV2ApiException('invalid_request');
    }
    final messages = request['messages'];
    final instructions = request['replyInstructions'];
    final media = request['media'];
    if (messages is! List ||
        messages.length > 100 ||
        instructions is! String ||
        utf8.encode(instructions).length > 16384 ||
        media is! List ||
        media.length > 50) {
      throw const JdV2ApiException('invalid_request');
    }
    for (final message in messages) {
      if (message is! Map ||
          message['text'] is! String ||
          (message['text'] as String).runes.length > 10000) {
        throw const JdV2ApiException('invalid_request');
      }
    }
    try {
      final bytes = utf8.encode(jsonEncode(request));
      if (bytes.length > 200000) {
        throw const JdV2ApiException('request_too_large');
      }
      return bytes;
    } on JsonUnsupportedObjectError {
      throw const JdV2ApiException('invalid_request');
    }
  }

  Future<Map<String, dynamic>> poll(String jobId, String pollUrl) async {
    final expected = _endpoint('replies/${_job(jobId)}', store: true);
    Uri resolved;
    try {
      resolved = Uri.parse('${_baseUri.toString()}/').resolve(pollUrl);
    } on FormatException {
      throw const JdV2ApiException('invalid_poll_url');
    }
    if (resolved.scheme != expected.scheme ||
        resolved.host != expected.host ||
        resolved.port != expected.port ||
        resolved.userInfo.isNotEmpty ||
        resolved.path != expected.path ||
        resolved.hasFragment ||
        resolved.queryParametersAll.length != 1 ||
        resolved.queryParametersAll['storeId']?.length != 1 ||
        resolved.queryParameters['storeId'] != storeId) {
      throw const JdV2ApiException('invalid_poll_url');
    }
    return _send('GET', expected, expected: 200);
  }

  Future<Map<String, dynamic>> acknowledge(
      String jobId, Map<String, dynamic> body) async {
    if (body['storeId'] != storeId) {
      throw const JdV2ApiException('invalid_delivery');
    }
    return _send('POST', _endpoint('replies/${_job(jobId)}/delivery'),
        expected: 200,
        body: utf8.encode(jsonEncode(body)),
        contentType: 'application/json; charset=utf-8');
  }

  Future<Map<String, dynamic>> _send(String method, Uri uri,
      {required int expected, List<int>? body, String? contentType}) async {
    HttpClientRequest? request;
    var expired = false;
    final cancellation = JdV2Cancellation();
    _pending[cancellation] = () => request?.abort();
    final scope = Zone.current[_scopeKey] as JdV2Cancellation?;
    final detach = scope?.onCancel(() {
      cancellation.cancel();
      request?.abort();
    });
    try {
      return await cancellation.wait((() async {
        request = await _httpClient.openUrl(method, uri);
        if (expired || cancellation.isCancelled) {
          request!.abort();
          cancellation.check();
          throw const JdV2ApiException('timeout');
        }
        request!.followRedirects = false;
        request!.headers.set('X-Qianniu-Key', _apiKey);
        request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (body != null) {
          request!.headers.set(HttpHeaders.contentTypeHeader, contentType!);
          request!.contentLength = body.length;
          request!.add(body);
        }
        final response = await request!.close();
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2 * _mib) {
            request!.abort();
            throw JdV2ApiException('response_too_large',
                statusCode: response.statusCode);
          }
          bytes.add(chunk);
        }
        Map<String, dynamic>? result;
        try {
          final value = jsonDecode(utf8.decode(bytes.takeBytes()));
          if (value is Map<String, dynamic>) result = value;
        } on FormatException {/* Report a safe protocol error below. */}
        if (response.statusCode != expected) {
          final error = result?['error'];
          final code = error is Map ? error['code'] : result?['code'];
          throw JdV2ApiException(
              code is String &&
                      RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(code) &&
                      !code.contains(_apiKey)
                  ? code
                  : 'http_error',
              statusCode: response.statusCode);
        }
        if (result == null) throw const JdV2ApiException('invalid_response');
        return result;
      })()
          .timeout(const Duration(seconds: 45)));
    } on TimeoutException {
      expired = true;
      request?.abort();
      throw const JdV2ApiException('timeout');
    } on IOException {
      cancellation.check();
      throw const JdV2ApiException('transport');
    } finally {
      detach?.call();
      _pending.remove(cancellation);
    }
  }

  void close() => _httpClient.close(force: true);
}
