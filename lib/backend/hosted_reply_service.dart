import 'dart:convert';
import 'dart:io';

import '../codex/codex_reply_service.dart';
import '../codex/customer_language.dart';
import '../domain/capture_models.dart';
import '../domain/reply_progress.dart';
import '../storage/capture_database.dart';
import '../storage/customer_media_inventory.dart';
import '../runtime/app_runtime.dart';
import '../runtime/runtime_trace.dart';
import 'hosted_reply_completion.dart';
export 'hosted_reply_completion.dart';

import 'jd_v2_client.dart';
import 'jd_v2_config.dart';
import 'jd_v2_jobs.dart';
import 'jd_v2_payload.dart';

class _HostedRun {
  _HostedRun(this.session);
  final String? session;
  final cancellation = JdV2Cancellation();
  final prefetchKeys = <String>{};
}

/// Production generation uses the hosted service. The base class retains the
/// customer-facing safeguards and test doubles, not a CLI fallback.
class HostedReplyService extends CodexReplyService {
  HostedReplyService(
      {required super.workspace,
      required this.jobs,
      required this.client,
      this.ownsClient = false})
      : super(
            executable: '',
            knowledgeDirectory: workspace,
            outputSchema: File('${workspace.path}/unused-hosted-schema'),
            model: 'jd-hosted-v2',
            capacityFallbackModel: 'jd-hosted-v2',
            timeout: null,
            chineseOnly: true);
  final JdV2Jobs jobs;
  final JdV2Client client;
  final bool ownsClient;

  static Future<HostedReplyService> discoverHosted(
      CaptureDatabase database) async {
    final config = await JdV2Config.load();
    final root = await database.storageRoot;
    final resources = await AppRuntime.resources(root);
    final client = JdV2Client(baseUri: config.baseUri, apiKey: config.apiKey);
    return HostedReplyService(
        workspace: resources.workspace,
        client: client,
        ownsClient: true,
        jobs: JdV2Jobs(Directory('${root.path}/jd_v2_jobs'), client));
  }

  static final Map<CaptureDatabase, Set<_HostedRun>> _activeRuns = {};

  static _HostedRun _beginRun(CaptureDatabase database) {
    final run = _HostedRun(database.currentAutomationSessionId);
    (_activeRuns[database] ??= {}).add(run);
    return run;
  }

  static void _endRun(CaptureDatabase database, _HostedRun run) {
    final runs = _activeRuns[database];
    runs?.remove(run);
    if (runs?.isEmpty == true) _activeRuns.remove(database);
  }

  /// Cancels local requests and leases immediately while retaining frozen jobs.
  /// Calling this does not close reusable injected clients or cancel server jobs.
  static void cancelRun(CaptureDatabase database, {String? sessionId}) {
    final runs = _activeRuns[database];
    if (runs == null) return;
    for (final run in runs.toList()) {
      if (sessionId != null && run.session != sessionId) continue;
      run.cancellation.cancel();
      for (final key in run.prefetchKeys) {
        _prefetching.remove(key);
        _retryAfter.remove(key);
        _failures.remove(key);
        _notifiedSources.remove(key);
      }
      runs.remove(run);
    }
    if (runs.isEmpty) _activeRuns.remove(database);
  }

  static final Map<String, Future<HostedReplyCompletion?>> _prefetching = {};
  static final Set<String> _notifiedCompletions = {};
  static final Set<String> _notifiedSources = {};
  static final Map<String, DateTime> _retryAfter = {};
  static final Map<String, int> _failures = {};

  /// Starts every ready source immediately. Each production request owns its
  /// own client, so one customer's pending API job cannot block another source.
  static Future<void> prefetch(String customer, CaptureDatabase database,
          {void Function()? onReady,
          void Function(HostedReplyCompletion)? onCompleted,
          void Function(Object)? onError,
          bool Function()? isActive,
          String? currentServiceAccount}) =>
      _prefetch(customer, database, () => discoverHosted(database),
          closeService: true,
          onReady: onReady,
          onCompleted: onCompleted,
          onError: onError,
          isActive: isActive,
          currentServiceAccount: currentServiceAccount);

  /// Injection entry point for callers that own their service and client.
  Future<void> prefetchPending(String customer, CaptureDatabase database,
          {void Function()? onReady,
          void Function(HostedReplyCompletion)? onCompleted,
          void Function(Object)? onError,
          bool Function()? isActive,
          String? currentServiceAccount}) =>
      _prefetch(customer, database, () async => this,
          closeService: false,
          onReady: onReady,
          onCompleted: onCompleted,
          onError: onError,
          isActive: isActive,
          currentServiceAccount: currentServiceAccount);

  static Future<void> _prefetch(String customer, CaptureDatabase database,
      Future<HostedReplyService> Function() createService,
      {required bool closeService,
      void Function()? onReady,
      void Function(HostedReplyCompletion)? onCompleted,
      void Function(Object)? onError,
      bool Function()? isActive,
      String? currentServiceAccount}) async {
    final run = _beginRun(database);
    final session = run.session;
    void check() {
      run.cancellation.check();
      if (isActive?.call() == false ||
          database.currentAutomationSessionId != session) {
        throw const CodexGenerationCancelled();
      }
    }

    try {
      final root = await run.cancellation.wait(database.storageRoot);
      check();
      final ids = await run.cancellation
          .wait(database.eligibleSingleMessageIds(customer));
      check();
      await Future.wait(ids.map((id) async {
        if (run.cancellation.isCancelled || isActive?.call() == false) return;
        final key =
            '${root.absolute.path}:$session:$customer:${database.currentBusinessDayKey}:$id';
        run.prefetchKeys.add(key);
        if (_retryAfter[key]?.isAfter(DateTime.now()) == true) return;
        var pending = _prefetching[key];
        if (pending == null) {
          // Install the future before awaiting disk preparation to dedupe callers
          // that observe the same source while it is still being frozen.
          pending = (() async {
            final source = await database.freezeReadyApiMessage(customer, id,
                expectedSessionId: session);
            if (source == null || isActive?.call() == false) return null;
            check();
            final service = await createService();
            try {
              check();
              // Prepare local policy context before waiting for the server. The
              // completion path must not re-enter history/eligibility queues.
              final document = await (await database.history).read(customer);
              final guardHistory = (document?['messages'] as List? ?? const [])
                  .whereType<Map>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList();
              final result = await service._runSource(
                  customer: customer,
                  inputs: [source],
                  rawHistory: guardHistory,
                  database: database,
                  end: source['id'] as String,
                  currentServiceAccount: currentServiceAccount,
                  run: run,
                  checkActive: () {
                    if (isActive?.call() == false ||
                        database.currentAutomationSessionId != session) {
                      throw const CodexGenerationCancelled();
                    }
                  });
              final local = Map<String, dynamic>.from(
                  result['_localContext'] as Map? ?? const {});
              local.putIfAbsent('guardHistory', () => guardHistory);
              local.putIfAbsent('sourceInput', () => source);
              local.putIfAbsent('expectedSessionId', () => session);
              return HostedReplyCompletion(
                  customer: customer,
                  source:
                      Map<String, dynamic>.from(local['sourceInput'] as Map),
                  rawResult: {...result, '_localContext': local},
                  receivedAt: DateTime.now().toUtc(),
                  expectedSessionId: session);
            } finally {
              if (closeService && service.ownsClient) service.client.close();
            }
          })();
          _prefetching[key] = pending;
        }
        try {
          final completed = await run.cancellation.wait(pending);
          check();
          _retryAfter.remove(key);
          _failures.remove(key);
          if (completed != null &&
              isActive?.call() != false &&
              database.currentAutomationSessionId == session) {
            final completionKey =
                '${root.absolute.path}:${completed.jobId}:$session';
            if (onCompleted != null &&
                _notifiedCompletions.add(completionKey)) {
              onCompleted(completed);
            }
            if (onReady != null && _notifiedSources.add(key)) onReady();
          }
        } catch (error) {
          if (error is CodexGenerationCancelled ||
              error is JdV2RequestCancelled ||
              run.cancellation.isCancelled) {
            return;
          }
          // Concurrent observers share one failure and one retry deadline.
          if (_retryAfter[key]?.isAfter(DateTime.now()) != true) {
            final failures = (_failures[key] ?? 0) + 1;
            _failures[key] = failures;
            final seconds = failures == 1 ? 10 : (failures == 2 ? 30 : 60);
            _retryAfter[key] = DateTime.now().add(Duration(seconds: seconds));
            if (isActive?.call() != false) onError?.call(error);
          }
        } finally {
          if (identical(_prefetching[key], pending)) _prefetching.remove(key);
        }
      }));
    } on JdV2RequestCancelled {
      // Stop is not a retryable API failure.
    } on CodexGenerationCancelled {
      // Session invalidation has the same local cancellation semantics.
    } finally {
      _endRun(database, run);
    }
  }

  static Future<void> markResultRejected(CaptureDatabase database,
      String customer, String sourceMessageId, String code) async {
    final root = await database.storageRoot;
    final directory = Directory('${root.path}/jd_v2_jobs/rejected');
    await directory.create(recursive: true);
    await File('${directory.path}/${JdV2Jobs.digest([
          customer,
          sourceMessageId
        ])}.json')
        .writeAsString(
            jsonEncode({
              'customer': customer,
              'sourceMessageId': sourceMessageId,
              'code': code,
              'rejectedAt': DateTime.now().toUtc().toIso8601String(),
            }),
            flush: true);
  }

  static String _sourceJobKey(
          String customer, String source, CaptureDatabase database) =>
      JdV2Jobs.digest({
        'customer': customer,
        'contextPolicy': 'single-message-v1',
        'businessDay': database.currentBusinessDayKey,
        'message': source,
      });

  /// Read only the current customer's pending source paths. Historical and
  /// unrelated customer jobs add no filesystem work to this lookup.
  static Future<Set<String>> completedMessageIds(
      String customer, CaptureDatabase database) async {
    final pending = await database.eligibleSingleMessageIds(customer);
    if (pending.isEmpty) return {};
    final root = await database.storageRoot;
    final directory = Directory('${root.path}/jd_v2_jobs');
    final ids = <String>{};
    await Future.wait(pending.map((source) async {
      final key = _sourceJobKey(customer, source, database);
      final file = File('${directory.path}/${JdV2Jobs.digest(key)}/job.json');
      final rejected = File('${directory.path}/rejected/${JdV2Jobs.digest([
            customer,
            source
          ])}.json');
      try {
        if (await rejected.exists() || !await file.exists()) return;
        final job = jsonDecode(await file.readAsString());
        if (job is! Map || job['state'] != 'completed') return;
        final request = job['request'];
        final local = job['localContext'];
        final result = job['result'];
        if (request is! Map ||
            local is! Map ||
            result is! Map ||
            request['customerUid'] != customer ||
            local['sourceMessageId'] != source) {
          return;
        }
        final binding = result['binding'];
        if (binding is! Map ||
            binding['platform'] != 'jd' ||
            binding['customerUid'] != customer ||
            binding['storeId'] != request['storeId'] ||
            binding['historyVersion'] != request['historyVersion'] ||
            binding['jobId'] != job['jobId'] ||
            result['jobId'] != job['jobId']) {
          return;
        }
        ids.add(source);
      } on FormatException {
        // Corrupt job documents are never considered ready to send.
      } on FileSystemException {
        // Another lifecycle operation may remove a job during this read.
      }
    }));
    return ids;
  }

  String _instructions(String? account) {
    const text = '所有回复使用中文，包括客户用英文提问时。';
    final name = account?.trim();
    return name == null || name.isEmpty
        ? text
        : '$text\nAX读取的当前接待客服账号：${jsonEncode(name)}';
  }

  @override
  Future<AiDraft> generate(
      {required ConversationSummary conversation,
      required CaptureDatabase database,
      String? batchEndMessageId,
      CodexGenerationCancellation? cancellation,
      bool secondInvestigation = false,
      void Function(bool)? onMediaDependency,
      Future<String?> Function()? beforeSubmit,
      String? currentServiceAccount}) async {
    final run = _beginRun(database);
    try {
      return await run.cancellation.wait(_generateHosted(
          run: run,
          conversation: conversation,
          database: database,
          batchEndMessageId: batchEndMessageId,
          cancellation: cancellation,
          onMediaDependency: onMediaDependency,
          beforeSubmit: beforeSubmit,
          currentServiceAccount: currentServiceAccount));
    } on JdV2RequestCancelled {
      throw const CodexGenerationCancelled();
    } on JdV2ApiException catch (error) {
      RuntimeTrace.record('generation.api_failed', {
        'customer': conversation.userId,
        'code': error.code,
        'statusCode': error.statusCode
      });
      rethrow;
    } finally {
      _endRun(database, run);
      if (ownsClient) client.close();
    }
  }

  Future<AiDraft> _generateHosted(
      {required _HostedRun run,
      required ConversationSummary conversation,
      required CaptureDatabase database,
      String? batchEndMessageId,
      CodexGenerationCancellation? cancellation,
      void Function(bool)? onMediaDependency,
      Future<String?> Function()? beforeSubmit,
      String? currentServiceAccount}) async {
    var end = batchEndMessageId;
    var checked = false;
    while (true) {
      run.cancellation.check();
      cancellation?.throwIfCancelled();
      final customer = conversation.userId;
      final document = await (await database.history).read(customer);
      final rawHistory = (document?['messages'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final generation = await database.generationMessages(customer,
          batchEndMessageId: end, document: document);
      final inputs =
          generation.where((m) => m['direction'] == 'incoming').toList();
      if (inputs.isEmpty) {
        throw const CodexReplyException('Frozen customer batch is empty.');
      }
      if (inputs.length != 1) {
        throw const CodexReplyException(
            'Hosted generation requires one claimed customer message.');
      }
      if (!checked) {
        checked = true;
        final refreshed = await beforeSubmit?.call();
        cancellation?.throwIfCancelled();
        if (refreshed != null) {
          end = refreshed;
          continue;
        }
      }
      final result = await _runSource(
          run: run,
          customer: customer,
          inputs: inputs,
          rawHistory: rawHistory,
          database: database,
          end: end,
          cancellation: cancellation,
          onMediaDependency: onMediaDependency,
          currentServiceAccount: currentServiceAccount);
      return _finish(result, inputs, rawHistory, database, customer,
          currentServiceAccount, cancellation);
    }
  }

  /// Prepare and recover one immutable API request without applying local
  /// reply, invoice, or transfer business effects.
  Future<Map<String, dynamic>> _runSource(
      {required String customer,
      required List<Map<String, dynamic>> inputs,
      required List<Map<String, dynamic>> rawHistory,
      required CaptureDatabase database,
      String? end,
      CodexGenerationCancellation? cancellation,
      void Function(bool)? onMediaDependency,
      String? currentServiceAccount,
      void Function()? checkActive,
      required _HostedRun run}) async {
    void check() {
      run.cancellation.check();
      cancellation?.throwIfCancelled();
      checkActive?.call();
    }

    check();
    final sourceMessageId = inputs.single['id'] as String;
    final wireMessageId =
        'jd-message-${JdV2Jobs.digest([customer, sourceMessageId])}';
    final targetIds = {wireMessageId};
    final key = _sourceJobKey(customer, sourceMessageId, database);
    final recovered =
        await jobs.resume(key, checkCancelled: check, scope: run.cancellation);
    check();
    if (recovered != null) {
      final local = Map<String, dynamic>.from(
          recovered['_localContext'] as Map? ?? const {});
      onMediaDependency?.call(local['dependent'] == true);
      return recovered;
    }

    final inventory = CustomerMediaInventory(database);
    final evidence = await inventory.analyzableEvidenceKeys(customer);
    final mediaRevision = await inventory.revision(customer);
    final mediaInputs = inputs
        .where((m) =>
            m['reply_input_kind'] == 'media' ||
            m['reply_input_kind'] != 'text' &&
                (m['media'] as List? ?? const []).isNotEmpty)
        .toList();
    final dependent = mediaInputs.isNotEmpty;
    onMediaDependency?.call(dependent);
    final lastTime = inputs
        .map((m) => DateTime.tryParse(m['sent_at']?.toString() ?? ''))
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final received = dependent
        ? await inventory.context(customer,
            history: rawHistory, before: lastTime ?? DateTime.now())
        : <Map<String, dynamic>>[];
    final merged = <String, Map<String, dynamic>>{};
    // Only the immutable unanswered customer batch leaves this device.
    for (final row in inputs) {
      merged[row['id'] as String] = Map<String, dynamic>.from(row);
    }
    final dependencies = <String, String>{};
    for (final input in mediaInputs) {
      final id = input['id'] as String;
      final aliases = {
        id,
        ...(input['observed_ids'] as List? ?? const []).whereType<String>()
      };
      final owned = received
          .where((r) =>
              aliases.contains(r['messageId']) ||
              (r['messageAliases'] as List? ?? const []).any(aliases.contains))
          .toList();
      if (owned.any((r) => r['analysisAvailable'] != true)) {
        throw CodexReplyMediaUnavailable([id], stage: 'hosted_preparation');
      }
      final available = owned
          .expand((r) =>
              (r['availableMedia'] as List? ?? const []).whereType<Map>())
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      if (available.isNotEmpty) merged[id] = {...input, 'media': available};
      if (owned.isNotEmpty) {
        final item = owned.first;
        dependencies[id] = CustomerMediaInventory.analyzablePayloadKey(
                item['kind'] as String, available,
                receiptId: item['mediaItemId'] as String) ??
            '';
      } else {
        dependencies[id] = evidence[id] ?? '';
      }
    }
    final instructions = _instructions(currentServiceAccount);
    late JdV2PreparedPayload provisional;
    try {
      provisional = await JdV2Payload.prepare(
          customer: customer,
          historyVersion: '0' * 64,
          idempotencyKey: JdV2Jobs.newId(),
          instructions: instructions,
          messages: [
            {...merged[sourceMessageId]!, 'id': wireMessageId}
          ],
          targetMessageIds: targetIds,
          referencedMediaIds: const {});
    } on StateError catch (error) {
      if (error.message.toString().startsWith('jd_v2_media_') ||
          error.message.toString().startsWith('jd_v2_video_')) {
        throw CodexReplyMediaUnavailable(
            mediaInputs.map((m) => m['id'] as String),
            stage: 'hosted_upload');
      }
      rethrow;
    }

    final request = provisional.request;
    request['historyVersion'] = JdV2Jobs.digest({...request}
      ..remove('idempotencyKey')
      ..remove('historyVersion'));
    RuntimeTrace.record('generation.api_started', {
      'customer': customer,
      'historyVersion': request['historyVersion'],
      'targetCount': targetIds.length,
      'mediaCount': provisional.files.length
    });
    check();
    final result = await jobs.run(
        key,
        request,
        provisional.files
            .map((f) => JdV2Upload(
                id: f['id']!, path: f['path']!, mimeType: f['mimeType']!))
            .toList(),
        checkCancelled: check,
        scope: run.cancellation,
        localContext: {
          'mediaRevision': mediaRevision,
          'dependent': dependent,
          'evidence': evidence,
          'dependencies': dependencies,
          'sourceMessageId': sourceMessageId,
          'requestMessageId': wireMessageId,
          'sourceInput': inputs.single,
          'expectedSessionId': database.currentAutomationSessionId,
          'guardHistory': rawHistory,
        });
    return result;
  }

  Future<AiDraft> finishCompletion(
      HostedReplyCompletion completion, CaptureDatabase database,
      {CodexGenerationCancellation? cancellation,
      String? currentServiceAccount}) async {
    cancellation?.throwIfCancelled();
    if (completion.expectedSessionId != database.currentAutomationSessionId) {
      throw const CodexGenerationCancelled();
    }
    final local = completion.rawResult['_localContext'] as Map? ?? const {};
    final guardHistory = (local['guardHistory'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    return _finish(completion.rawResult, [completion.source], guardHistory,
        database, completion.customer, currentServiceAccount, cancellation);
  }

  Future<AiDraft> _finish(
      Map<String, dynamic> result,
      List<Map<String, dynamic>> inputs,
      List<Map<String, dynamic>> rawHistory,
      CaptureDatabase database,
      String customer,
      String? currentServiceAccount,
      CodexGenerationCancellation? cancellation) async {
    cancellation?.throwIfCancelled();
    final local =
        Map<String, dynamic>.from(result['_localContext'] as Map? ?? const {});
    final binding = Map<String, dynamic>.from(result['binding'] as Map);
    var draft = JdV2Payload.toDraft(
        Map<String, dynamic>.from(result['reply'] as Map),
        receiptMetadata: {
          ...binding,
          'jobId': result['jobId'],
          'resultDigest': result['resultDigest'],
          'sourceMessageId': local['sourceMessageId'],
          'requestMessageId': local['requestMessageId']
        });
    try {
      draft = await _guard(draft, inputs, rawHistory, database, customer,
          currentServiceAccount, cancellation);
    } on JdV2ApiException catch (error) {
      final source = local['sourceMessageId'];
      if (error.code == 'unsupported_action_or_empty_answer' &&
          source is String) {
        await markResultRejected(database, customer, source, error.code);
      }
      rethrow;
    }
    RuntimeTrace.record('generation.api_completed', {
      'customer': customer,
      'jobId': result['jobId'],
      'targetCount': inputs.length
    });
    return withReplyProgress(
        normalizeReplyProgress(draft.withMediaContext(
            local['mediaRevision'] as int? ?? 0, local['dependent'] == true)),
        {
          'reply_evidence_key_snapshot': local['evidence'] ?? const {},
          'reply_media_dependency_keys': local['dependencies'] ?? const {},
          if (database.currentAutomationSessionId != null)
            'service_session_id': database.currentAutomationSessionId,
        });
  }

  Future<AiDraft> _guard(
      AiDraft draft,
      List<Map<String, dynamic>> inputs,
      List<Map<String, dynamic>> history,
      CaptureDatabase database,
      String customer,
      String? account,
      CodexGenerationCancellation? cancellation) async {
    final originalRaw = jsonDecode(draft.rawJson) as Map;
    if ((originalRaw['risk_triggers'] as List? ?? const [])
        .contains('jd_v2_unsupported_action')) {
      throw const JdV2ApiException('unsupported_action_or_empty_answer');
    }
    cancellation?.throwIfCancelled();
    final latest = inputs.map((m) => m['body']?.toString() ?? '').join('\n');
    return enforceCustomerFacingPolicy(draft, latest,
        language: CustomerLanguage.chinese,
        preserveEscalationAnswer: JdV2Payload.requestsTransfer(draft));
  }
}
