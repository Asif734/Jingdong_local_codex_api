import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'jd_v2_client.dart';

/// Durable accepted jobs are resumed, never replaced by a timeout retry.
class JdV2Jobs {
  JdV2Jobs(this.root, this.client,
      {this.pollInterval = const Duration(seconds: 2)});
  final Directory root;
  final JdV2Client client;
  final Duration pollInterval;
  static final Map<String, Future<Map<String, dynamic>>> _running = {};
  final Map<String, JdV2Cancellation> _pending = {};
  static final Map<String, Future<void>> _journals = {};

  /// Only disk preparation/publication is serialized. Network waits never hold
  /// this fence, so Stop can detach a lease and a later run can recover it.
  static Future<T> _journal<T>(
      String key, Future<T> Function() operation) async {
    final previous = _journals[key];
    final done = Completer<void>();
    _journals[key] = done.future;
    try {
      if (previous != null) await previous;
      return await operation();
    } finally {
      done.complete();
      if (identical(_journals[key], done.future)) _journals.remove(key);
    }
  }

  /// Override to delay a disk publication in journal race tests.
  Future<void> beforeJournalPublish(String state) async {}

  void cancelPending() {
    for (final entry in _pending.entries.toList()) {
      entry.value.cancel();
      _running.remove(entry.key);
    }
    _pending.clear();
    client.cancelPending();
  }

  static String digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static String newId() {
    final r = Random.secure();
    final bytes = List.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  Future<Map<String, dynamic>> run(
      String inputKey, Map<String, dynamic> request, List<JdV2Upload> uploads,
      {void Function()? checkCancelled,
      JdV2Cancellation? scope,
      Map<String, dynamic>? localContext}) async {
    final key = '${root.absolute.path}:$inputKey';
    final existing = _running[key];
    if (existing != null) return existing;
    final cancellation = JdV2Cancellation();
    void check() {
      cancellation.check();
      checkCancelled?.call();
    }

    final pending =
        _run(inputKey, request, uploads, check, localContext, cancellation);
    _pending[key] = cancellation;
    _running[key] = pending;
    final detach = scope?.onCancel(() {
      cancellation.cancel();
      if (identical(_running[key], pending)) _running.remove(key);
      if (identical(_pending[key], cancellation)) _pending.remove(key);
    });
    try {
      return await cancellation.wait(pending);
    } finally {
      detach?.call();
      if (identical(_running[key], pending)) _running.remove(key);
      if (identical(_pending[key], cancellation)) _pending.remove(key);
    }
  }

  /// Recover a frozen request without needing the original local media or
  /// rebuilding conversation history. A missing snapshot is the only null case.
  Future<Map<String, dynamic>?> resume(String inputKey,
      {void Function()? checkCancelled, JdV2Cancellation? scope}) async {
    checkCancelled?.call();
    final key = '${root.absolute.path}:$inputKey';
    final running = _running[key];
    if (running != null) return running;
    final file = File('${root.path}/${digest(inputKey)}/job.json');
    final job = await _journal<Map<String, dynamic>?>(key, () async {
      scope?.check();
      checkCancelled?.call();
      if (!await file.exists()) return null;
      return Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map);
    });
    if (job == null) return null;
    scope?.check();
    checkCancelled?.call();
    return run(
        inputKey, Map<String, dynamic>.from(job['request'] as Map), const [],
        checkCancelled: checkCancelled, scope: scope);
  }

  Future<Map<String, dynamic>> _run(
      String inputKey,
      Map<String, dynamic> request,
      List<JdV2Upload> uploads,
      void Function()? check,
      Map<String, dynamic>? localContext,
      JdV2Cancellation cancellation) async {
    final key = '${root.absolute.path}:$inputKey';
    final dir = Directory('${root.path}/${digest(inputKey)}');
    final file = File('${dir.path}/job.json');
    Future<void> publish(Map<String, dynamic> value,
        {bool acceptedReceipt = false}) async {
      if (!acceptedReceipt) check?.call();
      final tmp = File('${file.path}.tmp-${newId()}');
      try {
        await tmp.writeAsString(jsonEncode(value), flush: true);
        await beforeJournalPublish(value['state'] as String);
        // A stopped preparation/result must not overwrite the next lease.
        // A receipt already received from submit must remain recoverable.
        if (!acceptedReceipt) check?.call();
        await tmp.rename(file.path);
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    }

    Future<void> save(Map<String, dynamic> value,
            {bool acceptedReceipt = false}) =>
        _journal(key, () => publish(value, acceptedReceipt: acceptedReceipt));

    final job = await _journal<Map<String, dynamic>>(key, () async {
      check?.call();
      await dir.create(recursive: true);
      check?.call();
      if (await file.exists()) {
        return Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map);
      }
      final copies = <Map<String, dynamic>>[];
      for (final upload in uploads) {
        check?.call();
        final copy =
            await File(upload.path).copy('${dir.path}/${digest(upload.id)}');
        check?.call();
        copies.add(
            {'id': upload.id, 'path': copy.path, 'mimeType': upload.mimeType});
      }
      final initial = <String, dynamic>{
        'request': request,
        'files': copies,
        'localContext': localContext == null
            ? <String, dynamic>{}
            : jsonDecode(jsonEncode(localContext)),
        'state': 'unsubmitted',
        'createdAt': DateTime.now().toUtc().toIso8601String()
      };
      // Publish the frozen UUID/files before any POST, under the same fence
      // as the existence check so a cancelled preparer cannot replace it.
      await publish(initial);
      return initial;
    });
    check?.call();
    final frozen = Map<String, dynamic>.from(job['request'] as Map);
    Map<String, dynamic> resultWithContext(Map result) => {
          ..._validate(result, frozen, job['jobId'] as String),
          '_localContext': Map<String, dynamic>.from(
              job['localContext'] as Map? ?? const {}),
        };
    if (job['state'] == 'completed') {
      return resultWithContext(job['result'] as Map);
    }
    if (job['state'] == 'failed' ||
        job['state'] == 'expired' ||
        job['state'] == 'binding_mismatch') {
      throw JdV2ApiException(
          job['errorCode']?.toString() ?? job['state'].toString());
    }
    final frozenFiles = (job['files'] as List)
        .map((v) => JdV2Upload(
            id: v['id'] as String,
            path: v['path'] as String,
            mimeType: v['mimeType'] as String))
        .toList();
    var transientFailures = 0;
    while (true) {
      var delay = pollInterval;
      check?.call();
      try {
        if (job['jobId'] == null) {
          final accepted = await cancellation.wait(client.inCancellationScope(
              cancellation, () => client.submit(frozen, frozenFiles)));
          if (accepted['jobId'] is! String || accepted['pollUrl'] is! String) {
            throw const JdV2ApiException('invalid_acceptance');
          }
          job.addAll({
            'jobId': accepted['jobId'],
            'pollUrl': accepted['pollUrl'],
            'state': 'queued'
          });
          await save(job, acceptedReceipt: true);
        }
        check?.call();
        final result = await cancellation.wait(client.inCancellationScope(
            cancellation,
            () =>
                client.poll(job['jobId'] as String, job['pollUrl'] as String)));
        check?.call();
        transientFailures = 0;
        final state = (result['status'] ?? result['state'])?.toString();
        if (state == 'completed') {
          final validated = _validate(result, frozen, job['jobId'] as String);
          job.addAll({'state': 'completed', 'result': validated});
          await save(job);
          return resultWithContext(validated);
        }
        if (state == 'failed' || state == 'expired') {
          job.addAll({
            'state': state,
            'errorCode': (result['error'] is Map
                        ? (result['error'] as Map)['code']
                        : null)
                    ?.toString() ??
                state
          });
          await save(job);
          throw JdV2ApiException(job['errorCode'] as String);
        }
        if (!{'queued', 'processing', 'recovery_required'}.contains(state)) {
          throw const JdV2ApiException('invalid_job_state');
        }
        job['state'] = state;
        await save(job);
      } on JdV2ApiException catch (e) {
        if (job['state'] == 'failed' || job['state'] == 'expired') {
          rethrow; // Only the job's actual terminal state is authoritative.
        }
        if (e.statusCode == 410 || e.code == 'binding_mismatch') {
          job.addAll({
            'state': e.statusCode == 410 ? 'expired' : 'binding_mismatch',
            'errorCode': e.code
          });
          await save(job);
          rethrow;
        }
        if (!e.transient) {
          // HTTP authorization/protocol errors describe this read, not the
          // accepted generation. Correct configuration and resume the same job.
          job.addAll({
            'state': job['jobId'] == null ? 'unsubmitted' : 'recovery_required',
            'errorCode': e.code
          });
          await save(job);
          rethrow;
        }
        transientFailures++;
        delay = Duration(
            milliseconds: min(
                30000,
                pollInterval.inMilliseconds *
                    (1 << min(transientFailures, 4))));
        // The request/job identity remains unchanged even after transport loss.
      }
      check?.call();
      await cancellation.delay(delay);
    }
  }

  Map<String, dynamic> _validate(Map raw, Map request, String jobId) {
    final binding = raw['binding'];
    if (binding is! Map ||
        binding['platform'] != 'jd' ||
        binding['storeId'] != request['storeId'] ||
        binding['customerUid'] != request['customerUid'] ||
        binding['historyVersion'] != request['historyVersion'] ||
        binding['jobId'] != jobId ||
        (raw['jobId'] != null && raw['jobId'] != jobId) ||
        raw['reply'] is! Map ||
        raw['resultDigest'] is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(raw['resultDigest'] as String)) {
      throw const JdV2ApiException('binding_mismatch');
    }
    return {...Map<String, dynamic>.from(raw), 'jobId': jobId};
  }
}
