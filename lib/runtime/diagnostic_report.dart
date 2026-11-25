import 'dart:convert';
import 'dart:io';

import '../domain/message_record.dart';
import '../storage/capture_database.dart';
import 'runtime_trace.dart';
import 'app_runtime.dart';

class DiagnosticReportResult {
  const DiagnosticReportResult(
      {required this.directory, required this.reportId});
  final Directory directory;
  final String reportId;
  File get jsonFile => File('${directory.path}/report.json');
  File get htmlFile => File('${directory.path}/report.html');
}

/// Exports a stopped run after cancellation or normal worker completion.
/// Does not run capture, change work state, send messages, or invoke Codex.
class DiagnosticReportExporter {
  DiagnosticReportExporter({String? tracePath})
      : tracePath = tracePath ?? RuntimeTrace.path;
  final String tracePath;
  static const _maxFiles = 100;
  static const _maxFileBytes = 5 * 1024 * 1024;
  static const _maxTotalBytes = 50 * 1024 * 1024;

  /// [traceStartOffset] is a byte boundary after a complete JSONL record,
  /// captured at Start after flushing previous writes.
  Future<DiagnosticReportResult> export({
    required CaptureDatabase database,
    required Directory outputDirectory,
    required DateTime runStartedAt,
    required DateTime runStoppedAt,
    DateTime? processingSettledAt,
    Map<String, Object?> stopSummary = const {},
    int traceStartOffset = 0,
    required Map<String, Object?> settings,
  }) async {
    if (runStoppedAt.isBefore(runStartedAt)) {
      throw ArgumentError('Run stop precedes run start.');
    }
    final settledAt = processingSettledAt ?? runStoppedAt;
    if (settledAt.isBefore(runStoppedAt)) {
      throw ArgumentError('Processing settled before run stopped.');
    }
    final session = database.currentAutomationSessionId;
    if (session == null) throw StateError('No automation session to export.');
    await outputDirectory.create(recursive: true);
    final directory = await outputDirectory.createTemp('jd-report-');
    final result = DiagnosticReportResult(
        directory: directory,
        reportId: directory.uri.pathSegments.where((s) => s.isNotEmpty).last);
    final db = await database.database;
    final records = <CustomerMessageRecord>[];
    final timelineReadFailures = <Map<String, Object?>>[];
    final tables = <String, List<Map<String, Object?>>>{};
    // SELECT-only transaction freezes all durable work and canonical statuses.
    // History and evidence files are immutable/read-only after workers drain.
    await db.transaction((txn) async {
      for (final table in [
        'automation_session_messages',
        'automation_message_evidence',
        'automation_message_waits',
        'automation_reply_inputs',
      ]) {
        tables[table] =
            await txn.query(table, where: 'session_id=?', whereArgs: [session]);
      }
      final currentEvidence = await txn.query('capture_evidence',
          where: 'captured_at_ms>=? AND captured_at_ms<=?',
          whereArgs: [
            runStartedAt.millisecondsSinceEpoch,
            settledAt.millisecondsSinceEpoch
          ]);
      final currentMedia = await txn.query('customer_media_items',
          where:
              'admission_session_id=? OR (first_seen_ms>=? AND first_seen_ms<=?)',
          whereArgs: [
            session,
            runStartedAt.millisecondsSinceEpoch,
            settledAt.millisecondsSinceEpoch
          ]);
      final customers = <String>{
        ...tables['automation_session_messages']!
            .map((r) => r['user_id']! as String),
        ...currentEvidence.map((r) => r['customer']! as String),
        ...currentMedia.map((r) => r['customer']! as String),
      }.toList()
        ..sort();
      for (final customer in customers) {
        try {
          records.addAll(
              await database.customerMessageRecords(customer, executor: txn));
        } catch (error) {
          timelineReadFailures.add({
            'customer': customer,
            'stage': 'customerMessageRecords/readOnly',
            'sourceFile': 'lib/storage/capture_database.dart',
            'sourceSymbol':
                'CaptureDatabase.customerMessageRecords / ConversationFileStore.readOnly',
            'error': _redact('$error'),
            'bodyAvailability': '消息历史读取失败，正文不可用。下列原始任务行不是规范消息，不能据此重建消息数量或推断回复。',
            'rawWork': tables['automation_session_messages']!
                .where((row) => row['user_id'] == customer)
                .map((row) => _pick(row, const [
                      'session_id',
                      'user_id',
                      'message_id',
                      'activated_at_ms',
                      'input_kind',
                      'response_state',
                      'responded_at_ms',
                      'answered_attempt_id',
                      'answered_task_id',
                      'work_revision'
                    ]))
                .toList(),
          });
        }
      }
      for (final table in [
        'customer_media_items',
        'media_card_observations',
        'media_capture_audit',
        'capture_evidence',
        'pending_customers',
        'generated_drafts',
        'delivery_attempts',
        'conversation_control',
        'customer_storage_faults',
        'sla_fallbacks',
      ]) {
        final identity = const {
          'customer_media_items',
          'media_card_observations',
          'media_capture_audit',
          'capture_evidence'
        }.contains(table)
            ? 'customer'
            : 'user_id';
        tables[table] = customers.isEmpty
            ? []
            : await txn.query(table,
                where:
                    '$identity IN (${List.filled(customers.length, '?').join(',')})',
                whereArgs: customers);
      }
    });
    if (database.currentAutomationSessionId != session) {
      throw StateError('Automation session changed during export.');
    }
    records.sort((a, b) {
      final time =
          (a.messageAt ?? a.receivedAt).compareTo(b.messageAt ?? b.receivedAt);
      if (time != 0) return time;
      final customer = a.customerId.compareTo(b.customerId);
      return customer != 0 ? customer : a.stableId.compareTo(b.stableId);
    });
    final warnings = <String>[];
    final trace = await _readTrace(runStartedAt, settledAt, warnings,
        traceStartOffset: traceStartOffset);
    final events = trace.events;
    final evidenceFiles = <Map<String, Object?>>[];
    final paths = <String, Map<String, Object?>>{};
    final messages = <Map<String, Object?>>[];
    final root = await database.storageRoot;
    final usedMedia = <String>{};
    final usedEvidence = <String>{};
    for (final message in records) {
      final customer = message.customerId;
      final ids = <String>{message.stableId};
      // Inventory identity aliases, never customer/time proximity, identify
      // canonical representations. Associated text remains its own message.
      final textIds = tables['automation_session_messages']!
          .where((r) => r['user_id'] == customer && r['input_kind'] == 'text')
          .map((r) => r['message_id'])
          .whereType<String>()
          .toSet();
      final media = tables['customer_media_items']!.where((r) {
        if (message.kind == 'text' || r['customer'] != customer) return false;
        final aliases = _mediaIds(r)..removeAll(textIds);
        return aliases.contains(message.stableId);
      }).toList();
      for (final row in media) {
        ids.addAll(_mediaIds(row)..removeAll(textIds));
      }
      final work = tables['automation_session_messages']!
          .where(
              (r) => r['user_id'] == customer && ids.contains(r['message_id']))
          .toList();
      final edges = tables['automation_message_evidence']!
          .where(
              (r) => r['user_id'] == customer && ids.contains(r['message_id']))
          .toList();
      final evidenceIds = <String>{};
      void findEvidence(Object? object) {
        if (object is Map) {
          for (final entry in object.entries) {
            if (const {
                  'evidenceId',
                  'evidence_id',
                  'holderEvidenceId',
                  'typedEvidenceId'
                }.contains(entry.key) &&
                entry.value is String) {
              evidenceIds.add(entry.value as String);
            } else {
              findEvidence(entry.value);
            }
          }
        } else if (object is List) {
          for (final entry in object) {
            findEvidence(entry);
          }
        }
      }

      for (final row in [...work, ...edges]) {
        findEvidence(_decode(row['evidence_key']));
      }
      for (final row in media) {
        if (row['evidence_id'] is String) {
          evidenceIds.add(row['evidence_id']! as String);
        }
      }
      final observations = tables['media_card_observations']!
          .where((r) =>
              r['customer'] == customer &&
              (ids.contains(r['item_id']) || ids.contains(r['canonical_id'])))
          .toList();
      for (final row in observations) {
        if (row['evidence_id'] is String) {
          evidenceIds.add(row['evidence_id']! as String);
        }
      }
      final drafts = tables['generated_drafts']!.where((r) {
        if (r['user_id'] != customer) return false;
        final raw = _decode(r['raw_json']);
        final scope = raw is Map ? raw['service_message_ids'] : null;
        return (scope is List && scope.any(ids.contains)) ||
            ids.contains(r['batch_end_message_id']);
      }).toList();
      final attempts = tables['delivery_attempts']!.where((r) {
        if (r['user_id'] != customer) return false;
        if (r['attempt_id'] == message.replyAttemptId) return true;
        final raw = _decode(r['raw_json']);
        if (raw is! Map || raw['service_session_id'] != session) return false;
        return (raw['service_message_ids'] is List &&
                (raw['service_message_ids'] as List).any(ids.contains)) ||
            ids.contains(r['batch_end_message_id']);
      }).toList();
      final taskIds = <String>{
        ...drafts.map((r) => r['task_id']).whereType<String>(),
        ...attempts.map((r) => r['task_id']).whereType<String>(),
        ...tables['automation_reply_inputs']!
            .where((r) =>
                r['user_id'] == customer && ids.contains(r['message_id']))
            .map((r) => r['owner_id'])
            .whereType<String>(),
      };
      final attemptIds =
          attempts.map((r) => r['attempt_id']).whereType<String>().toSet();
      final scopedEvents = events.where((event) {
        if ((event['customer'] ?? event['userId'] ?? event['customerId']) !=
            customer) {
          return false;
        }
        // Explicitly conflicting identifiers must never attach by another key.
        final mid = event['messageId'];
        final eid = event['evidenceId'];
        final item = event['itemId'];
        final task = event['taskId'];
        final attempt = event['attemptId'];
        if (task != null && !taskIds.contains(task)) return false;
        if (attempt != null && !attemptIds.contains(attempt)) return false;
        final expectedAt = event['expectedMediaAtMs'];
        if (expectedAt is num &&
            (message.messageAt == null ||
                expectedAt.toInt() ~/ 1000 !=
                    message.messageAt!.millisecondsSinceEpoch ~/ 1000)) {
          return false;
        }
        if (mid != null && !ids.contains(mid)) return false;
        if (eid != null && !evidenceIds.contains(eid)) return false;
        if (item != null && !ids.contains(item)) return false;
        return (task != null && taskIds.contains(task)) ||
            (attempt != null && attemptIds.contains(attempt)) ||
            (mid != null && ids.contains(mid)) ||
            (eid != null && evidenceIds.contains(eid)) ||
            (item != null && ids.contains(item));
      }).toList();
      usedMedia.addAll(media.map((r) => '${r['customer']}|${r['item_id']}'));
      usedEvidence.addAll(evidenceIds.map((id) => '$customer|$id'));
      final evidence = tables['capture_evidence']!
          .where(
              (r) => r['customer'] == customer && evidenceIds.contains(r['id']))
          .toList();
      void reference(Object? value, String role, {bool manifest = false}) {
        if (value is! String || value.isEmpty || value.contains('://')) return;
        final file = File(value.startsWith('/') ? value : '${root.path}/$value')
            .absolute;
        paths.putIfAbsent(
            file.path,
            () => {
                  'sourcePath': file.path,
                  'role': role,
                  'customer': customer,
                  'messageIds': <String>[],
                  'sanitizeJson': manifest,
                });
        final refs = paths[file.path]!['messageIds']! as List<String>;
        if (!refs.contains(message.stableId)) refs.add(message.stableId);
      }

      void mediaReferences(Object? value) {
        if (value is Map) {
          for (final entry in value.entries) {
            if (const {
              'path',
              'preview_path',
              'previewPath',
              'imagePath',
              'evidenceFile',
              'cropPath',
              'candidatePath'
            }.contains(entry.key)) {
              reference(entry.value, 'media_crop');
            } else if (entry.key == 'manifestPath') {
              reference(entry.value, 'manifest', manifest: true);
            } else {
              mediaReferences(entry.value);
            }
          }
        } else if (value is List) {
          for (final item in value) {
            mediaReferences(item);
          }
        }
      }

      for (final row in evidence) {
        final payload = _decode(row['payload']);
        mediaReferences(payload);
        if (payload is Map && payload['manifestPath'] is String) {
          reference('${payload['manifestPath']}.ocr.json', 'ocr',
              manifest: true);
        }
      }
      for (final row in media) {
        mediaReferences(_decode(row['media_json']));
      }
      for (final row in observations) {
        reference(row['preview_path'], 'media_preview');
      }
      for (final event in scopedEvents) {
        mediaReferences(event);
      }
      final waits = tables['automation_message_waits']!
          .where(
              (r) => r['user_id'] == customer && ids.contains(r['message_id']))
          .toList();
      final uncertainReceiptHold = waits.any((row) =>
          row['content_key']?.toString().startsWith('delivery-unknown-hold:') ==
          true);
      final conditions = scopedEvents
          .where((r) => const {'media.condition', 'delivery.condition'}
              .contains(r['event']))
          .toList();
      messages.add({
        'customerId': customer,
        'stableId': message.stableId,
        'canonicalIds': ids.toList()..sort(),
        'kind': message.kind,
        'body': message.body,
        'status': message.status,
        'receivedAt': _iso(message.receivedAt),
        'messageAt': _iso(message.messageAt),
        'repliedAt': _iso(message.repliedAt),
        'replyTimeSource': message.replyTimeSource,
        'holdingAt': _iso(message.holdingAt),
        'replyAttemptId': message.replyAttemptId,
        'coveredMessageCount': message.coveredMessageCount,
        'assessment': {
          'certainty': 'observed_state',
          'step': _step(message.status, media, drafts, waits),
          'explanation': uncertainReceiptHold && message.status != 'answered'
              ? '该条旧回复的发送结果待核实，暂不重复发送；此等待仅限该条消息，后续消息与转接继续处理。关联尝试见 waits.content_key 与 deliveryAttempts。'
              : message.status == 'answered'
                  ? '规范消息账本标记为已回复，回复时间与凭据见上方。'
                  : '停止时规范消息状态为 ${message.status}。'
                      '${conditions.isEmpty ? '该消息的具体失败条件未记录 (not recorded)。' : '下方记录了可明确关联的条件尝试；这些尝试本身不能证明最终未回复的原因。'}',
        },
        'work': work
            .map((r) => _pick(r, const [
                  'message_id',
                  'response_state',
                  'input_kind',
                  'activated_at_ms',
                  'responded_at_ms',
                  'answered_attempt_id',
                  'work_revision'
                ]))
            .toList(),
        'media': media
            .map((r) => _pick(r, const [
                  'item_id',
                  'canonical_id',
                  'message_id',
                  'kind',
                  'state',
                  'identity_ambiguous',
                  'first_seen_ms',
                  'last_seen_ms',
                  'evidence_id'
                ]))
            .toList(),
        'evidence': evidence
            .map((r) => _pick(r, const [
                  'id',
                  'captured_at_ms',
                  'state',
                  'attempts',
                  'retry_at_ms',
                  'last_error'
                ]))
            .toList(),
        'mediaAudit': tables['media_capture_audit']!
            .where((r) =>
                r['customer'] == customer &&
                evidenceIds.contains(r['evidence_id']))
            .map((r) => _pick(r, const [
                  'observation_id',
                  'evidence_id',
                  'state',
                  'updated_at_ms'
                ]))
            .toList(),
        'drafts': drafts
            .map((r) => _pick(r, const [
                  'task_id',
                  'created_at_ms',
                  'delivery_state',
                  'delivery_attempts',
                  'retry_at_ms',
                  'last_error',
                  'batch_end_message_id'
                ]))
            .toList(),
        'waits': waits
            .map((r) => _pick(r, const [
                  'message_id',
                  'is_media',
                  'task_id',
                  'message_revision',
                  'content_key',
                  'updated_at_ms'
                ]))
            .toList(),
        'deliveryAttempts': attempts
            .map((r) => _pick(r, const [
                  'attempt_id',
                  'task_id',
                  'kind',
                  'state',
                  'reply',
                  'error',
                  'created_at_ms',
                  'updated_at_ms',
                  'batch_end_message_id',
                ]))
            .toList(),
        'conditions': conditions
            .map((event) => {
                  ..._safeEvent(event),
                  'attributionScope': event['taskId'] != null ||
                          event['attemptId'] != null
                      ? 'task_scope'
                      : event['messageId'] != null || event['itemId'] != null
                          ? 'message_identity'
                          : event['expectedMediaAtMs'] != null
                              ? 'evidence_and_sender_time'
                              : 'evidence_frame',
                  'attributionNote':
                      event['taskId'] != null || event['attemptId'] != null
                          ? '该任务或发送尝试明确绑定本条消息；同批任务也可能包含其他消息。'
                          : event['messageId'] == null &&
                                  event['itemId'] == null &&
                                  event['expectedMediaAtMs'] == null
                              ? '该条件属于同一采集帧，可能涉及帧内其他卡片，不能认定为本条消息的直接失败条件。'
                              : '由明确标识或采集证据与发送时间关联；仍须结合之后的尝试判断最终结果。',
                })
            .toList(),
        'events': scopedEvents
            .where((e) => !const {'media.condition', 'delivery.condition'}
                .contains(e['event']))
            .map(_safeEvent)
            .toList(),
      });
    }
    bool duringRun(Object? value) =>
        value is num &&
        value >= runStartedAt.millisecondsSinceEpoch &&
        value <= settledAt.millisecondsSinceEpoch;
    final unattributed = <Map<String, Object?>>[
      for (final row in tables['capture_evidence']!)
        if (duringRun(row['captured_at_ms']) &&
            !usedEvidence.contains('${row['customer']}|${row['id']}'))
          {
            'type': 'capture_evidence',
            'attribution': '未能关联到本轮规范消息，不能推断已处理或已回复',
            ..._pick(row, const [
              'id',
              'customer',
              'captured_at_ms',
              'state',
              'attempts',
              'last_error',
              'retry_at_ms'
            ])
          },
      for (final row in tables['customer_media_items']!)
        if ((row['admission_session_id'] == session ||
                duringRun(row['first_seen_ms'])) &&
            !usedMedia.contains('${row['customer']}|${row['item_id']}'))
          {
            'type': 'media_inventory',
            'attribution': '媒体收据尚未关联到本轮规范消息',
            ..._pick(row, const [
              'item_id',
              'customer',
              'kind',
              'state',
              'evidence_id',
              'identity_ambiguous',
              'first_seen_ms',
              'last_seen_ms'
            ])
          },
    ];
    // Preserve relevant raw capture files even when admission failed before a
    // canonical message existed. These are explicitly unattributed evidence.
    for (final row in tables['capture_evidence']!) {
      if (!duringRun(row['captured_at_ms']) ||
          usedEvidence.contains('${row['customer']}|${row['id']}')) {
        continue;
      }
      final payload = _decode(row['payload']);
      if (payload is! Map) continue;
      for (final key in ['imagePath', 'manifestPath']) {
        final value = payload[key];
        if (value is! String || value.isEmpty || value.contains('://')) {
          continue;
        }
        final source =
            File(value.startsWith('/') ? value : '${root.path}/$value')
                .absolute;
        paths.putIfAbsent(
            source.path,
            () => {
                  'sourcePath': source.path,
                  'role': 'unattributed_$key',
                  'customer': row['customer'],
                  'messageIds': <String>[],
                });
      }
    }
    final allCustomers = <String>{
      ...records.map((r) => r.customerId),
      ...timelineReadFailures.map((r) => '${r['customer']}'),
      ...unattributed.map((r) => '${r['customer']}'),
    };
    final customerEvents = events
        .where((event) => allCustomers.contains(
            event['customer'] ?? event['userId'] ?? event['customerId']))
        .map(_safeEvent)
        .toList();
    var copiedBytes = 0;
    for (final entry in paths.entries) {
      final row = {...entry.value}..remove('sanitizeJson');
      final source = File(entry.key);
      try {
        if (!await source.exists()) {
          row['status'] = 'missing';
        } else if (evidenceFiles.length >= _maxFiles ||
            await source.length() > _maxFileBytes ||
            copiedBytes + await source.length() > _maxTotalBytes) {
          row['status'] = 'omitted_size_limit';
        } else {
          final extension = source.path.split('.').last.toLowerCase();
          if (!const {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'json'}
              .contains(extension)) {
            row['status'] = 'omitted_unsupported_type';
          } else {
            final relative =
                'evidence/${evidenceFiles.length.toString().padLeft(3, '0')}.$extension';
            final destination = File('${directory.path}/$relative');
            await destination.parent.create(recursive: true);
            if (extension == 'json') {
              final json = jsonDecode(await source.readAsString());
              await destination.writeAsString(const JsonEncoder.withIndent('  ')
                  .convert(_safeManifest(json)));
            } else {
              await source.copy(destination.path);
            }
            if (copiedBytes + await destination.length() > _maxTotalBytes ||
                await destination.length() > _maxFileBytes) {
              await destination.delete();
              row['status'] = 'omitted_size_limit';
              evidenceFiles.add(row);
              continue;
            }
            copiedBytes += await destination.length();
            row.addAll({
              'status': 'copied',
              'relativePath': relative,
              'bytes': await destination.length()
            });
          }
        }
      } catch (_) {
        row['status'] = 'unreadable';
      }
      evidenceFiles.add(row);
    }
    final customerStates = <Map<String, Object?>>[];
    for (final table in [
      'pending_customers',
      'conversation_control',
      'customer_storage_faults',
      'sla_fallbacks'
    ]) {
      for (final row in tables[table]!) {
        customerStates.add({
          'table': table,
          ..._pick(row, const [
            'user_id',
            'state',
            'generation_token',
            'generation_retry_at_ms',
            'generation_last_error',
            'newest_message_id',
            'retry_at_ms',
            'due_at_ms',
            'last_error',
            'updated_at_ms'
          ])
        });
      }
    }
    final report = <String, Object?>{
      'schemaVersion': 1,
      'buildVersion': AppRuntime.version,
      'processId': pid,
      'displayTimezone': 'JD UTC+08:00; JSON timestamps use UTC (Z)',
      'unattributedEvidence': unattributed,
      'customerContextEvents': customerEvents,
      'customerContextAttribution': '客户级运行事件，仅作上下文，不能作为某条消息失败的直接证明。',
      'reportId': result.reportId,
      'sessionId': session,
      'runStartedAt': _iso(runStartedAt),
      'runStoppedAt': _iso(runStoppedAt),
      'processingSettledAt': _iso(settledAt),
      'stopSummary': stopSummary,
      'exportedAt': _iso(DateTime.now()),
      'snapshot':
          '停止后以只读事务提取本轮状态；已取消任务不再阻塞导出，取消情况见 stopSummary。消息历史和证据文件在停止后读取。'
              '正在处理或未确认的状态按实记录，缺少日志不代表条件通过或失败。',
      'settings': _safeSettings(settings),
      'summary': {
        'messages': messages.length,
        'timelineUnavailableCustomers': timelineReadFailures.length,
        'answered': records.where((r) => r.status == 'answered').length,
        'unreplied': records.where((r) => r.status != 'answered').length
      },
      'messages': messages,
      'timelineReadFailures': timelineReadFailures,
      'customerStates': customerStates,
      'traceWarnings': warnings,
      'traceByteRangeStart': trace.startOffset,
      'traceByteRangeEnd': trace.endOffset,
      'evidenceFiles': evidenceFiles,
      'evidenceLimits': {
        'maxFiles': _maxFiles,
        'maxFileBytes': _maxFileBytes,
        'maxTotalBytes': _maxTotalBytes
      },
    };
    await result.jsonFile
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await result.htmlFile.writeAsString(_html(report));
    return result;
  }

  static Set<String> _mediaIds(Map row) => {
        for (final key in ['item_id', 'canonical_id', 'message_id'])
          if (row[key] is String) row[key] as String,
        if (row['item_id'] is String) 'media-pending:${row['item_id']}',
        if (row['canonical_id'] is String)
          'media-pending:${row['canonical_id']}',
        ...((_decode(row['aliases_json']) as List?) ?? []).whereType<String>(),
      };
  static Object? _decode(Object? value) {
    if (value is! String) return null;
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }

  static String? _iso(DateTime? value) => value?.toUtc().toIso8601String();
  static Map<String, Object?> _pick(Map row, List<String> keys) => {
        for (final key in keys)
          if (row.containsKey(key)) key: _redact(row[key]),
      };
  static Object? _redact(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          if (!RegExp(
                  r'auth|secret|token|api.?key|password|credential|multipart|prompt|raw_json|request.?body|job',
                  caseSensitive: false)
              .hasMatch('${entry.key}'))
            '${entry.key}': _redact(entry.value),
      };
    }
    if (value is List) return value.map(_redact).toList();
    if (value is String) {
      if (value.toLowerCase().contains('multipart/form-data')) {
        return '[multipart payload omitted]';
      }
      return value
          .replaceAllMapped(
              RegExp(
                  r'''["']?(authorization|x-api-key|api[_-]?key|access[_-]?token|password|secret)["']?\s*[:=]\s*["']?[^"'\s,;}]+''',
                  caseSensitive: false),
              (match) => '${match.group(1)}=[redacted]')
          .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false),
              'Bearer [redacted]')
          .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{12,}'), '[redacted]')
          .replaceAll(RegExp(r'https?://[^\s]+'), '[URL omitted]');
    }
    return value;
  }

  static Map<String, Object?> _safeSettings(Map<String, Object?> settings) => {
        for (final entry in settings.entries)
          if (!RegExp(
                  r'auth|secret|token|api.?key|password|credential|multipart|url|endpoint|hosted',
                  caseSensitive: false)
              .hasMatch(entry.key))
            entry.key: _redact(entry.value),
      };
  static Object? _safeManifest(Object? value) {
    if (value is List) return value.map(_safeManifest).toList();
    if (value is! Map) return _redact(value);
    return _pick(value, const [
      'evidenceId',
      'customer',
      'capturedAtMs',
      'imagePath',
      'manifestPath',
      'region',
      'window',
      'bounds',
      'width',
      'height',
      'scale',
      'pinnedMedia',
      'messageId',
      'kind',
      'state',
      'captureSource',
      'regions',
      'lines',
      'observations',
      'text',
      'confidence',
      'imageWidth',
      'imageHeight'
    ]);
  }

  static Map<String, Object?> _safeEvent(Map event) => _pick(event, const [
        'time',
        'pid',
        'event',
        'customer',
        'userId',
        'customerId',
        'messageId',
        'itemId',
        'referenceMessageId',
        'observedAt',
        'turnKey',
        'mediaKind',
        'candidateCount',
        'originalChecks',
        'thumbnailChecks',
        'visualMatches',
        'requiresOriginalIdentityCheck',
        'evidenceId',
        'stage',
        'phase',
        'errorCode',
        'stageElapsedMs',
        'ocrRecognitionCount',
        'axProbeCount',
        'groupLabelReuseCount',
        'statusSampleCount',
        'activeCount',
        'target',
        'targetAccount',
        'requestedTarget',
        'sourceAccount',
        'axDiagnostics',
        'inspection',
        'conditionId',
        'expression',
        'actual',
        'threshold',
        'passed',
        'outcome',
        'reason',
        'error',
        'state',
        'code',
        'elapsedMs',
        'operation',
        'attemptId',
        'manifestPath',
        'capturedAtMs',
        'expectedMediaAtMs',
        'expectedMessageTime',
        'taskId',
        'sourceFile',
        'sourceLine',
        'sourceSymbol',
        'region',
        'candidatePath',
        'candidate',
        'tier',
        'path',
      ]);
  static String _step(String status, List media, List drafts, List waits) {
    if (status == 'answered') return 'reply_confirmed';
    if (waits.any((row) =>
        row['content_key']?.toString().startsWith('delivery-unknown-hold:') ==
        true)) {
      return 'uncertain_message_receipt_only_other_messages_continue';
    }
    if (status == 'sending') return 'delivery_in_flight_or_unconfirmed';
    if (drafts.isNotEmpty) return 'draft_delivery';
    if (status == 'analyzing') return 'generation_in_flight';
    if (waits.isNotEmpty) return 'waiting_for_input_or_review';
    if (media.any((r) =>
        !const {'ready', 'rejected', 'superseded'}.contains(r['state']))) {
      return 'media_acquisition';
    }
    return 'pending_or_policy_controlled';
  }

  Future<({List<Map<String, Object?>> events, int startOffset, int endOffset})>
      _readTrace(DateTime start, DateTime stop, List<String> warnings,
          {int traceStartOffset = 0}) async {
    final file = File(tracePath);
    if (!await file.exists()) {
      warnings.add('Runtime trace is missing.');
      return (events: <Map<String, Object?>>[], startOffset: 0, endOffset: 0);
    }
    final events = <Map<String, Object?>>[];
    var malformed = 0;
    var actualStart = traceStartOffset;
    var traceLength = 0;
    try {
      traceLength = await file.length();
      if (actualStart < 0 || actualStart > traceLength) {
        warnings.add(
            'Trace start offset $actualStart is outside the file; read from byte 0.');
        actualStart = 0;
      }
      await for (final line in file
          .openRead(actualStart, traceLength)
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        try {
          final value = jsonDecode(line);
          if (value is! Map) {
            malformed++;
            continue;
          }
          final time = DateTime.tryParse('${value['time']}');
          if (value['pid'] != pid) continue;
          if (time == null) {
            malformed++;
            continue;
          }
          if (!time.isBefore(start) && !time.isAfter(stop)) {
            events.add(Map<String, Object?>.from(value));
          }
        } catch (_) {
          malformed++;
        }
      }
    } catch (_) {
      warnings.add('Runtime trace could not be fully read.');
    }
    if (malformed > 0) {
      warnings.add('$malformed malformed trace line(s) ignored');
    }
    events.sort((a, b) => DateTime.parse('${a['time']}')
        .compareTo(DateTime.parse('${b['time']}')));
    return (events: events, startOffset: actualStart, endOffset: traceLength);
  }

  static String _html(Map<String, Object?> report) {
    const encoder = HtmlEscape();
    String escape(Object? value) => encoder.convert('$value');
    String jd(Object? value) {
      final date = DateTime.tryParse('$value');
      return date == null
          ? '未记录'
          : '${date.toUtc().add(const Duration(hours: 8)).toIso8601String().replaceAll('Z', '')} +08:00';
    }

    String pretty(Object? value) =>
        escape(const JsonEncoder.withIndent('  ').convert(value));
    final out =
        StringBuffer('''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>JD 停止运行诊断报告</title><style>
body{font:15px system-ui;max-width:1100px;margin:32px auto;padding:0 20px;color:#17202a}
h1,h2{line-height:1.25}article{border:1px solid #ccd4dd;padding:20px;margin:22px 0;border-radius:10px}
pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f2f5f8;padding:12px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:8px;text-align:left}small{color:#526170}
</style><h1>JD 停止运行诊断报告</h1>''');
    out.write(
        '<p>应用版本 ${escape(report['buildVersion'])} · 进程 ${escape(report['processId'])} · 时间显示 JD UTC+08:00</p>');
    out.write(
        '<p>报告 ${escape(report['reportId'])}<br>运行 ${escape(report['sessionId'])}<br>${escape(jd(report['runStartedAt']))} → ${escape(jd(report['runStoppedAt']))}<br>停止后快照时间 ${escape(jd(report['processingSettledAt']))}</p>');
    out.write(
        '<p>${escape(report['snapshot'])}</p><p><a href="report.json">机器可读报告 report.json</a></p>');
    out.write(
        '<h2>汇总与运行参数</h2><pre>${pretty(report['summary'])}\n${pretty(report['settings'])}</pre>');
    if ((report['stopSummary'] as Map? ?? const {}).isNotEmpty) {
      out.write('<h2>停止时取消的任务</h2><pre>${pretty(report['stopSummary'])}</pre>');
    }
    if ((report['timelineReadFailures'] as List).isNotEmpty) {
      out.write(
          '<h2>消息时间线读取失败</h2><p>以下客户的历史损坏、身份或日期校验失败，正文不可用。其原始任务仅作为诊断记录展示；其他客户的时间线继续导出。</p><pre>${pretty(report['timelineReadFailures'])}</pre>');
    }
    for (final message in report['messages']! as List) {
      final m = message as Map;
      out.write(
          '<article><h2>${escape(m['customerId'])} · ${escape(m['status'])}</h2><p>消息 ${escape(m['stableId'])} · ${escape(m['kind'])}<br>发送 ${escape(jd(m['messageAt']))} · 采集 ${escape(jd(m['receivedAt']))}<br>回复 ${escape(jd(m['repliedAt']))} · 时间来源 ${escape(m['replyTimeSource'])}</p><pre>${escape(m['body'])}</pre>');
      out.write(
          '<p>${escape((m['assessment'] as Map)['step'])}: ${escape((m['assessment'] as Map)['explanation'])}</p>');
      out.write('<h3>精确条件尝试（按时间顺序，actual=实际值，threshold=阈值）</h3>');
      if ((m['conditions'] as List).isEmpty) out.write('<p>未记录可精确关联的条件。</p>');
      for (final condition in m['conditions'] as List) {
        out.write('<pre>${pretty(condition)}</pre>');
      }
      out.write('<details><summary>消息任务、媒体、发送与证据状态</summary><pre>${pretty({
            for (final key in [
              'work',
              'media',
              'evidence',
              'mediaAudit',
              'drafts',
              'deliveryAttempts',
              'waits',
              'events'
            ])
              key: m[key]
          })}</pre></details></article>');
    }
    out.write(
        '<h2>客户控制与重试时间</h2><pre>${pretty(report['customerStates'])}</pre><h2>随附证据</h2><p>缺失、无法读取、不支持和超过大小限制的文件均单独标记。请分享整个文件夹以保留证据链接。</p><table><tr><th>消息</th><th>证据</th><th>状态</th></tr>');
    for (final file in report['evidenceFiles']! as List) {
      final f = file as Map;
      final relative = f['relativePath'];
      out.write(
          '<tr><td>${escape(f['customer'])}<br>${escape(f['messageIds'])}</td><td>${relative == null ? escape(f['sourcePath']) : '<a href="${escape(relative)}">${escape(relative)}</a>'}</td><td>${escape(f['status'])}</td></tr>');
    }
    out.write(
        '</table><h2>采集提示</h2><pre>${pretty(report['traceWarnings'])}</pre>');
    out.write(
        '<h2>未关联到规范消息的媒体与原始采集</h2><pre>${pretty(report['unattributedEvidence'])}</pre><h2>客户运行上下文（不证明单条消息的失败原因）</h2><pre>${pretty(report['customerContextEvents'])}</pre></html>');
    return out.toString();
  }
}
