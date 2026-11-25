import '../backend/jd_v2_payload.dart';
import '../runtime/delivery_context_guard.dart';
import '../runtime/automation_settings.dart';
import '../capture/response_timing_policy.dart';
import '../capture/transcript_text.dart';
import '../codex/holding_replies.dart';
import '../codex/customer_language.dart';
import '../codex/fixed_replies.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/capture_models.dart';
import '../domain/automatic_draft_save_result.dart';
import '../runtime/app_runtime.dart';
import '../runtime/runtime_trace.dart';
import '../domain/reply_progress.dart';
import '../domain/message_record.dart';
import '../domain/customer_message_time.dart';
import '../domain/named_agent_request.dart';
import '../domain/incomplete_image_policy.dart';
import 'conversation_file_store.dart';
import 'customer_media_inventory.dart';

/// One immutable generation claim. A pre-submit expansion replaces the claim
/// atomically; it never changes a snapshot already submitted to the CLI.
class GenerationSnapshot {
  const GenerationSnapshot(this.token, this.batchEndMessageId,
      {this.expanded = false});
  final String token;
  final String batchEndMessageId;
  final bool expanded;
}

class IncompleteImagePolicyResult {
  const IncompleteImagePolicyResult(
      {this.changed = false,
      this.queuedResponse = false,
      this.retiredMessageIds = const {}});
  final bool changed;
  final bool queuedResponse;
  final Set<String> retiredMessageIds;
}

class _GenerationClaimAborted implements Exception {
  const _GenerationClaimAborted();
}

class _MessageGroup {
  _MessageGroup(this.ids);
  final Set<String> ids;
  final List<Map<String, Object?>> work = [];
  final List<Map<String, Object?>> media = [];
  // An attribution edge is not a message identity edge.
  final List<Map<String, Object?>> associatedWork = [];

  bool get pending => work.any((r) => r['response_state'] == 'pending');
  bool get delegated =>
      work.isNotEmpty && work.every((r) => r['response_state'] == 'delegated');
  bool get acquisition =>
      !delegated &&
      media.any((r) =>
          r['canonical_id'] == null &&
          const {'video', 'image', 'unknown'}.contains(r['kind']) &&
          !const {'ready', 'rejected', 'superseded'}.contains(r['state']));
  bool get unanswered => pending;
}

/// Explicit inventory edges identify media representations. A text question
/// associated with a video remains a separate incoming bubble.
List<_MessageGroup> _canonicalMessageGroups(
    Iterable<Map<String, Object?>> work, Iterable<Map<String, Object?>> media) {
  // A time alias retains its old SQL row solely for frozen receipt audit. It
  // is not another customer duty or a completed-looking timeline message.
  work = work.where((row) => row['response_state'] != 'merged');
  final texts = work
      .where((r) => r['input_kind'] == 'text')
      .map((r) => r['message_id']! as String)
      .toSet();
  final groups = <_MessageGroup>[];
  void merge(Set<String> ids, {Map<String, Object?>? item}) {
    final result = _MessageGroup(ids);
    if (item != null) result.media.add(item);
    var changed = true;
    while (changed) {
      changed = false;
      for (final group in groups.toList()) {
        if (group.ids.intersection(result.ids).isEmpty) continue;
        result.ids.addAll(group.ids);
        result.work.addAll(group.work);
        result.media.addAll(group.media);
        result.associatedWork.addAll(group.associatedWork);
        groups.remove(group);
        changed = true;
      }
    }
    groups.add(result);
  }

  for (final item in media) {
    final id = item['item_id']! as String;
    final canonical = item['canonical_id']?.toString();
    final aliases = {
      id,
      'media-pending:$id',
      if (canonical != null) ...[canonical, 'media-pending:$canonical'],
      if (item['message_id'] is String) item['message_id']! as String,
      ...(jsonDecode(item['aliases_json']?.toString() ?? '[]') as List)
          .whereType<String>(),
    };
    final owners = work
        .where((r) =>
            texts.contains(r['message_id']) &&
            aliases.contains(r['message_id']))
        .toList();
    aliases.removeAll(texts);
    merge(aliases, item: item);
    groups.firstWhere((g) => g.ids.contains(id)).associatedWork.addAll(owners);
  }
  for (final row in work) {
    final id = row['message_id']! as String;
    final group = groups.where((g) => g.ids.contains(id)).firstOrNull;
    if (group == null) {
      groups.add(_MessageGroup({id})..work.add(row));
    } else {
      group.work.add(row);
    }
  }
  return groups.where((g) => g.work.isNotEmpty).toList();
}

/// SQLite contains the durable processing, delivery, and SLA state. Messages
/// and confirmed sent replies live in per-user JSON documents managed by
/// [history]. Unsent generated drafts remain outside conversation history.
class CaptureDatabase {
  CaptureDatabase(
      {Directory? storageRoot,
      bool currentDayOnly = false,
      DateTime Function()? clock,
      AutomationSettings automationSettings = const AutomationSettings()})
      : _automationSettings = automationSettings,
        _storageRoot = storageRoot,
        _currentDayOnly = currentDayOnly,
        _businessClock = clock ?? DateTime.now;

  AutomationSettings _automationSettings;
  AutomationSettings get automationSettings => _automationSettings;
  Duration get holdingDelay => _automationSettings.holdingDelay;

  /// The caller applies preferences only while automation is stopped.
  /// Each run keeps this immutable snapshot until it stops.
  void configureAutomationSettings(AutomationSettings settings) {
    settings.validate();
    _automationSettings = settings;
  }

  final Directory? _storageRoot;
  final bool _currentDayOnly;
  final DateTime Function() _businessClock;
  String? _workingBusinessDay;
  Database? _database;
  Future<Database>? _openingDatabase;
  ConversationFileStore? _history;
  bool _legacyDraftsPurged = false;
  bool _reviewControlsSynced = false;
  static const slaFallbackDelay = Duration(seconds: 50);
  static const handoffMaxAttempts = 10;
  static const _postTransferReviewReason =
      'newer_request_after_confirmed_transfer';
  static const _replyWithinResponseWindowSql =
      r'''CASE WHEN json_valid(raw_json)
    THEN CASE WHEN json_type(raw_json,'$.service_response_window') IS NOT NULL
      THEN json_extract(raw_json,'$.service_response_window.customer')=user_id
        AND json_extract(raw_json,'$.service_response_window.identityVerified')=1
        AND json_extract(raw_json,'$.service_response_window.dueAtMs')=
          json_extract(raw_json,'$.service_response_window.startedAtMs')+?
        AND created_at_ms<=json_extract(raw_json,'$.service_response_window.dueAtMs')
      ELSE EXISTS(SELECT 1 FROM platform_response_cycles c
        WHERE c.user_id=generated_drafts.user_id AND c.identity_verified=1
          AND created_at_ms>=c.started_at_ms AND created_at_ms<=c.started_at_ms+?)
      END ELSE 0 END''';
  static const _replyForExpectedResponseCycleSql =
      r'''CASE WHEN json_valid(raw_json) THEN EXISTS(
        SELECT 1 FROM platform_response_cycles c
        WHERE c.user_id=generated_drafts.user_id AND c.cycle_id=?
          AND c.identity_verified=1 AND c.state='waiting'
          AND CASE WHEN json_type(raw_json,'$.service_response_window') IS NOT NULL
          THEN json_extract(raw_json,'$.service_response_window.cycleId')=c.cycle_id
          ELSE created_at_ms>=c.started_at_ms END) ELSE 0 END''';
  static const _nativeResponseCycleKey = 'native_platform_response_cycle_id';
  static const _readyReplyCustomerGuardSql =
      'user_id NOT IN(SELECT user_id FROM customer_storage_faults) '
      'AND user_id NOT IN(SELECT user_id FROM unavailable_conversations) '
      'AND user_id NOT IN(SELECT user_id FROM conversation_control '
      "WHERE state='human_contacting' OR state LIKE 'handoff_%')";
  // Persisted schema changes require a version bump: existing databases do
  // not execute onCreate. Version 35 adds the material input_key to v34 work.
  static const databaseSchemaVersion = 35;
  String? _automationSessionId;
  DateTime? _automationSessionStartedAt;
  final Map<String, Set<String>> _sessionBaselineIds = {};
  final Map<String, Future<void>> _textClarificationTails = {};
  final Map<String, Future<void>> _timeIdentityTails = {};

  Future<T> _ownTimeIdentity<T>(String customer, Future<T> Function() action) {
    final result = (_timeIdentityTails[customer] ?? Future<void>.value())
        .then((_) => action());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _timeIdentityTails[customer] = tail;
    tail.then((_) {
      if (identical(_timeIdentityTails[customer], tail)) {
        _timeIdentityTails.remove(customer);
      }
    });
    return result;
  }

  String? get currentAutomationSessionId => _automationSessionId;
  DateTime? get automationSessionStartedAt => _automationSessionStartedAt;

  /// JD message headers use the shop's UTC+8 calendar, independent of the
  /// Mac's display time zone. One run owns one immutable history partition.
  String? get currentBusinessDayKey => !_currentDayOnly
      ? null
      : (_workingBusinessDay ??=
          ConversationFileStore.businessDayFor(_businessClock()));

  bool get businessDayHasChanged =>
      _currentDayOnly &&
      currentBusinessDayKey !=
          ConversationFileStore.businessDayFor(_businessClock());

  DateTime get currentCalendarDayStart => DateTime.parse(
          '${ConversationFileStore.businessDayFor(_businessClock())}T00:00:00+08:00')
      .toUtc();

  bool isOnCurrentBusinessDay(DateTime value) =>
      !_currentDayOnly ||
      ConversationFileStore.businessDayFor(value) == currentBusinessDayKey;

  /// A Start is a new service run, not permission to resume yesterday's work.
  /// Original rows and unknown physical receipts remain auditable; no cursor
  /// or customer case is falsely marked answered/contacted during this reset.
  Future<String> beginAutomationSession(
      {required DateTime startedAt,
      bool baselineBeforeStartedAtOnly = false}) async {
    if (_currentDayOnly) {
      final day = ConversationFileStore.businessDayFor(startedAt);
      if (day != currentBusinessDayKey) {
        _workingBusinessDay = day;
        _history = null;
      }
    }
    final db = await database;
    final id = 'run-${_taskId()}';
    final baseline = <String, Set<String>>{};
    final store = await history;
    await store.prepareDay();
    if (await store.conversationsDirectory.exists()) {
      await for (final file in store.conversationsDirectory.list()) {
        if (file is! File || !file.path.endsWith('.json')) continue;
        try {
          final doc = jsonDecode(await file.readAsString());
          if (doc is! Map || doc['user_id'] is! String) continue;
          baseline[doc['user_id']! as String] = {
            for (final m
                in (doc['messages'] as List? ?? const []).whereType<Map>())
              if (!baselineBeforeStartedAtOnly ||
                  (DateTime.tryParse(m['sent_at']?.toString() ?? '') ??
                              DateTime.tryParse(
                                  m['captured_at']?.toString() ?? ''))
                          ?.isBefore(startedAt) !=
                      false) ...<String>[
                if (m['id'] is String) m['id']! as String,
                ...(m['observed_ids'] as List? ?? const []).whereType<String>()
              ]
          };
        } catch (_) {
          /* A damaged history still fails its normal identity guard. */
        }
      }
    }
    const transientTables = [
      'pending_customers',
      'generated_drafts',
      'conversation_control',
      'sla_fallbacks',
      'platform_response_cycles',
      'unavailable_conversations',
      'human_transfer_requests',
      'human_transfer_request_events',
      'sla_delivery_receipts'
    ];
    await db.transaction((txn) async {
      await txn.insert('automation_sessions', {
        'session_id': id,
        'started_at_ms': startedAt.millisecondsSinceEpoch
      });
      for (final table in transientTables) {
        final exists = await txn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [table]);
        if (exists.isEmpty) continue;
        for (final row in await txn.query(table)) {
          await txn.insert('automation_work_archive', {
            'session_id': id,
            'table_name': table,
            'record_key':
                row['user_id']?.toString() ?? row['id']?.toString() ?? '',
            'row_json': jsonEncode(row),
            'archived_at_ms': startedAt.millisecondsSinceEpoch
          });
        }
        await txn.delete(table);
      }
      for (final row in await txn.query('human_review_tickets',
          where: "status IN ('open','contacting')")) {
        await txn.insert('automation_work_archive', {
          'session_id': id,
          'table_name': 'human_review_tickets',
          'record_key': row['id'].toString(),
          'row_json': jsonEncode(row),
          'archived_at_ms': startedAt.millisecondsSinceEpoch
        });
        await txn.update(
            'human_review_tickets',
            {
              'status': 'session_archived',
              'updated_at_ms': startedAt.millisecondsSinceEpoch
            },
            where: 'id=?',
            whereArgs: [row['id']]);
      }
      for (final row in await txn.query('delivery_attempts')) {
        await txn.insert(
            'automation_archived_attempts',
            {
              'attempt_id': row['attempt_id'],
              'archived_session_id': id,
              'state_at_archive': row['state']
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final entry in baseline.entries) {
        await txn.insert('automation_session_baselines', {
          'session_id': id,
          'user_id': entry.key,
          'known_ids_json': jsonEncode(entry.value.toList())
        });
      }
    });
    _automationSessionId = id;
    _automationSessionStartedAt = startedAt;
    _sessionBaselineIds
      ..clear()
      ..addAll(baseline);
    RuntimeTrace.record('automation.session_started', {
      'sessionId': id,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'oldBusinessResumed': false,
      'historyPreserved': true,
      'physicalReceiptsPreserved': true
    });
    return id;
  }

  Future<bool> isCurrentSessionMessage(
      String customer, String messageId) async {
    final session = _automationSessionId;
    if (session == null) return true;
    final rows = await (await database).query('automation_session_messages',
        columns: ['message_id'],
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, customer, messageId]);
    if (rows.isNotEmpty) return true;
    final doc = await (await history).read(customer);
    final active = await _activeSessionIds(customer);
    return (doc?['messages'] as List? ?? const []).whereType<Map>().any((m) =>
        (m['id'] == messageId ||
            (m['observed_ids'] as List? ?? const []).contains(messageId)) &&
        (active.contains(m['id']) ||
            (m['observed_ids'] as List? ?? const []).any(active.contains)));
  }

  /// The first passive frame establishes unknown pre-existing history without
  /// pretending it was answered. Only its exact current-run reservation may
  /// extend Start's durable ID baseline; later discovery cannot move it.
  Future<bool> registerDiscoveryBaseline(
      String customer, Iterable<String> messageIds,
      {required String evidenceId, required String expectedSessionId}) async {
    if (expectedSessionId != _automationSessionId) return false;
    final document = await (await history).read(customer);
    final requested = messageIds.toSet();
    final candidates = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['direction'] == 'incoming' &&
            (requested.contains(m['id']) ||
                (m['observed_ids'] as List? ?? const [])
                    .any(requested.contains)))
        .toList();
    Set<String>? merged;
    final result = await (await database).transaction((txn) async {
      if (!await _captureSessionMatches(txn, expectedSessionId)) return false;
      final reservation = await txn.query('capture_discovery_state',
          where: 'session_id=? AND customer=? AND evidence_id=? AND kind=?',
          whereArgs: [expectedSessionId, customer, evidenceId, 'baseline']);
      if (reservation.isEmpty) return false;
      if (reservation.single['ready'] == 1) return true;
      final old = await txn.query('automation_session_baselines',
          where: 'session_id=? AND user_id=?',
          whereArgs: [expectedSessionId, customer]);
      final ids = <String>{
        if (old.isNotEmpty)
          ...(jsonDecode(old.single['known_ids_json']! as String) as List)
              .whereType<String>(),
      };
      final active = (await txn.query('automation_session_messages',
              columns: ['message_id'],
              where: 'session_id=? AND user_id=?',
              whereArgs: [expectedSessionId, customer]))
          .map((r) => r['message_id'])
          .toSet();
      for (final message in candidates) {
        final aliases = <String>{
          if (message['id'] is String) message['id'] as String,
          ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
        };
        // A positive live capture that raced baseline extraction remains work.
        if (aliases.any(active.contains)) continue;
        ids.addAll(aliases);
      }
      await txn.insert(
          'automation_session_baselines',
          {
            'session_id': expectedSessionId,
            'user_id': customer,
            'known_ids_json': jsonEncode(ids.toList()),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update('capture_discovery_state', {'ready': 1},
          where: 'session_id=? AND customer=? AND evidence_id=?',
          whereArgs: [expectedSessionId, customer, evidenceId]);
      merged = ids;
      return true;
    });
    if (merged != null && expectedSessionId == _automationSessionId) {
      _sessionBaselineIds[customer] = merged!;
    }
    return result;
  }

  Future<Set<String>> _knownSessionBaselineIds(String customer) async {
    final owner = _automationSessionId;
    if (owner == null) return const {};
    final rows = await (await database).query('automation_session_baselines',
        where: 'session_id=? AND user_id=?', whereArgs: [owner, customer]);
    return {
      ...?_sessionBaselineIds[customer],
      if (rows.isNotEmpty)
        ...(jsonDecode(rows.single['known_ids_json']! as String) as List)
            .whereType<String>(),
    };
  }

  Future<bool> isSessionBaselineMessage(
      String customer, String messageId) async {
    final owner = _automationSessionId;
    final known = await _knownSessionBaselineIds(customer);
    if (owner == null || owner != _automationSessionId || known.isEmpty) {
      return false;
    }
    if (known.contains(messageId)) return true;
    final document = await (await history).read(customer);
    if (owner != _automationSessionId) return false;
    return (document?['messages'] as List? ?? const []).whereType<Map>().any(
        (message) =>
            (message['id'] == messageId ||
                (message['observed_ids'] as List? ?? const [])
                    .contains(messageId)) &&
            _matchesWorkId(message, known));
  }

  /// A proven alias of a pre-Start card remains history, even when its visual
  /// fingerprint or original-file ID becomes available later. A current-run
  /// task always wins over a proposed baseline alias.
  Future<bool> inheritSessionBaseline(String customer,
      {required Iterable<String> ancestorIds,
      required Iterable<String> aliasIds}) async {
    final owner = _automationSessionId;
    if (owner == null) return false;
    final ancestors = ancestorIds.where((id) => id.isNotEmpty).toSet();
    final aliases = aliasIds.where((id) => id.isNotEmpty).toSet();
    if (ancestors.isEmpty || aliases.isEmpty) return false;
    Set<String>? merged;
    final inherited = await (await database).transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) return false;
      final rows = await txn.query('automation_session_baselines',
          where: 'session_id=? AND user_id=?', whereArgs: [owner, customer]);
      final known = <String>{
        if (rows.isNotEmpty)
          ...(jsonDecode(rows.single['known_ids_json']! as String) as List)
              .whereType<String>(),
      };
      if (!ancestors.any(known.contains)) return false;
      final active = (await txn.query('automation_session_messages',
              columns: ['message_id'],
              where: 'session_id=? AND user_id=?',
              whereArgs: [owner, customer]))
          .map((row) => row['message_id'])
          .toSet();
      if (ancestors.any(active.contains) || aliases.any(active.contains)) {
        return false;
      }
      merged = {...known, ...aliases};
      await txn.insert(
          'automation_session_baselines',
          {
            'session_id': owner,
            'user_id': customer,
            'known_ids_json': jsonEncode(merged!.toList()),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
    if (inherited && owner == _automationSessionId) {
      _sessionBaselineIds[customer] = merged!;
    }
    return inherited;
  }

  Future<Set<String>> _activeSessionIds(String customer) async =>
      (await (await database).query('automation_session_messages',
              columns: ['message_id'],
              where: 'session_id=? AND user_id=?',
              whereArgs: [_automationSessionId, customer]))
          .map((m) => m['message_id']! as String)
          .toSet();

  // A confirmed transfer retires this reception's messages, not the buyer ID.
  // Keep the cutoff in the same durable settlement record as its effects so
  // delayed captures and late API completions obey the same boundary.
  Future<int?> _confirmedTransferCutoff(
      DatabaseExecutor txn, String customer) async {
    final records = await txn.query('automation_work_archive',
        columns: ['row_json'],
        where: "session_id=? AND table_name='chat_transfer_settlements'",
        whereArgs: [_automationSessionId]);
    int? cutoff;
    for (final record in records) {
      final data = jsonDecode(record['row_json']! as String) as Map;
      final at = data['confirmed_at_ms'];
      if (data['customer'] == customer &&
          at is int &&
          (cutoff == null || at > cutoff)) {
        cutoff = at;
      }
    }
    return cutoff;
  }

  Future<Set<String>> _retirePreTransferWork(
      DatabaseExecutor txn, String customer,
      {int? confirmedAtMs}) async {
    final cutoff =
        confirmedAtMs ?? await _confirmedTransferCutoff(txn, customer);
    if (cutoff == null || _automationSessionId == null) return {};
    final retired = <String>{};
    final rows = await txn.query('automation_session_messages',
        where: "session_id=? AND user_id=? AND response_state='pending'",
        whereArgs: [_automationSessionId, customer]);
    for (final row in rows) {
      final sentAt =
          _originalIncomingTime(customer, row)?.millisecondsSinceEpoch;
      final observedAt = row['activated_at_ms']! as int;
      // Sender clocks identify whole seconds. A new return message observed
      // after confirmation in that same second has no pre-transfer proof.
      final before = sentAt == null
          ? observedAt <= cutoff
          : sentAt ~/ 1000 < cutoff ~/ 1000 ||
              (sentAt ~/ 1000 == cutoff ~/ 1000 && observedAt <= cutoff);
      if (!before) continue;
      retired.add(row['message_id']! as String);
      await txn.update(
          'automation_session_messages',
          {
            'response_state': 'delegated',
            'responded_at_ms': cutoff,
          },
          where:
              "session_id=? AND user_id=? AND message_id=? AND response_state='pending'",
          whereArgs: [_automationSessionId, customer, row['message_id']]);
    }
    return retired;
  }

  Future<Set<String>> _pendingSessionIds(String customer,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await database;
    await _retirePreTransferWork(db, customer);
    return (await db.query('automation_session_messages',
            columns: ['message_id'],
            where: "session_id=? AND user_id=? AND response_state='pending'",
            whereArgs: [_automationSessionId, customer]))
        .map((m) => m['message_id']! as String)
        .toSet();
  }

  String _contentKey(Map<String, String> keys, String id, bool isMedia,
      {Iterable<String>? dependencyIds}) {
    if (isMedia) return keys[id] ?? '';
    if (dependencyIds != null) {
      final ids = dependencyIds.toSet().toList()..sort();
      return jsonEncode(
          {for (final dependency in ids) dependency: keys[dependency] ?? ''});
    }
    // Compatibility only for a waiting task created by an older application.
    final values = keys.values.toSet().toList()..sort();
    return jsonEncode(values);
  }

  String _currentWaitKey(Map<String, String> keys, Map wait) {
    final previous = wait['content_key']?.toString() ?? '';
    if (previous.startsWith('{')) {
      final dependencies = jsonDecode(previous) as Map;
      return _contentKey(keys, wait['message_id']! as String, false,
          dependencyIds: dependencies.keys.map((id) => '$id'));
    }
    return _contentKey(
        keys, wait['message_id']! as String, wait['is_media'] == 1);
  }

  bool _waitDependenciesReady(Map wait, Set<String> ready) {
    final encoded = wait['content_key']?.toString() ?? '';
    if (!encoded.startsWith('{')) return false;
    final dependencies = jsonDecode(encoded) as Map;
    return dependencies.keys.every(ready.contains);
  }

  Map<String, String>? _mediaDependencyKeys(Map raw) {
    if (raw['reply_media_dependency_keys'] case final Map dependencies) {
      return dependencies.map((key, value) => MapEntry('$key', '$value'));
    }
    return null;
  }

  // The timeline kind owns routing. A reference to an attachment is context
  // for a text question, never another message's parsing prerequisite.
  bool _isMediaReplyInput(Map message) =>
      message['reply_input_kind'] == 'media' ||
      (message['reply_input_kind'] != 'text' && isMediaWorkMessage(message));

  Set<String> _replyMediaAliases(Map message, {String? messageId}) => {
        if (messageId != null) messageId,
        if (message['id'] is String) message['id']! as String,
        if (message['media_receipt_id'] is String) ...{
          message['media_receipt_id']! as String,
          'media-pending:${message['media_receipt_id']}',
        },
        ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
        ...(message['media_receipt_aliases'] as List? ?? const [])
            .whereType<String>(),
      };

  Future<Map<String, String>?> _scopedMediaDependencyKeys(
      DatabaseExecutor executor, String customer, Map raw,
      {String? ownerId}) async {
    final keys = _mediaDependencyKeys(raw);
    if (keys == null || keys.isEmpty || _automationSessionId == null) {
      return keys;
    }
    final scope =
        (raw['service_message_ids'] as List?)?.whereType<String>().toSet();
    if (ownerId == null && scope == null) {
      ownerId = (await executor.query('pending_customers',
              columns: ['generation_token'],
              where: 'user_id=?',
              whereArgs: [customer]))
          .firstOrNull?['generation_token']
          ?.toString();
    }
    // Preserve legacy/manual behavior when there is no current-run input owner.
    if (ownerId == null && scope == null) return keys;
    final inputs = await executor.rawQuery('''SELECT i.*,m.input_kind
      FROM automation_reply_inputs i JOIN automation_session_messages m
      ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
      WHERE i.session_id=? AND i.user_id=? ${ownerId == null ? '' : 'AND i.owner_id=?'}''',
        [_automationSessionId, customer, if (ownerId != null) ownerId]);
    final aliases = <String>{};
    for (final input in inputs) {
      if (input['input_kind'] != 'media' ||
          scope != null && !scope.contains(input['message_id'])) {
        continue;
      }
      final message =
          jsonDecode(input['message_json']?.toString() ?? '{}') as Map;
      aliases.addAll(_replyMediaAliases(message,
          messageId: input['message_id']! as String));
    }
    return {
      for (final entry in keys.entries)
        if (aliases.contains(entry.key)) entry.key: entry.value
    };
  }

  ({int revision, String key}) _materialWorkVersion(Map message, Map? work) {
    final key = ConversationFileStore.materialInputKey(message);
    final stored = (work?['work_revision'] as num?)?.toInt() ?? 0;
    final document =
        (message['service_evidence_revision'] as num?)?.toInt() ?? 0;
    if (work?['input_key'] == key) return (revision: stored, key: key);
    return (
      revision: max(document, stored + (work?['input_key'] == null ? 0 : 1)),
      key: key
    );
  }

  Future<bool> _mediaDependencyKeysCurrent(
      DatabaseExecutor executor, String customer, Map raw) async {
    final snapshot = await _scopedMediaDependencyKeys(executor, customer, raw);
    if (snapshot == null) return true;
    if (snapshot.isEmpty) return true;
    final keys = await CustomerMediaInventory(this)
        .analyzableEvidenceKeys(customer, executor: executor);
    return snapshot.entries
        .every((entry) => (keys[entry.key] ?? '') == entry.value);
  }

  Future<void> _newInputResetsGenerationBackoff(
          DatabaseExecutor txn, String customer) =>
      txn.update(
          'pending_customers',
          {
            'generation_retry_at_ms': 0,
            'generation_last_error': null,
            'generation_attempts': 0,
          },
          where: 'user_id=?',
          whereArgs: [customer]);

  Future<String?> incomingMessageIdAtTime(
          String customer, DateTime senderAt) async =>
      (await history).incomingMessageIdAtTime(customer, senderAt);

  bool _mediaItemMatchesTime(String customer, Map item, String timeKey) {
    final admission = item['admission_key'];
    if (admission is String && CustomerMessageTime.isTimeId(admission)) {
      return admission == timeKey;
    }
    final sender = item['sender_ms'];
    if (sender is num) {
      return CustomerMessageTime.incomingId(
              customer,
              DateTime.fromMillisecondsSinceEpoch(sender.toInt(),
                  isUtc: true)) ==
          timeKey;
    }
    return true;
  }

  bool _senderTimeInCurrentSession(DateTime? senderAt) =>
      senderAt != null &&
      isOnCurrentBusinessDay(senderAt) &&
      _automationSessionStartedAt != null &&
      !CustomerMessageTime.second(senderAt)
          .isBefore(CustomerMessageTime.second(_automationSessionStartedAt!));

  Future<String?> bindIncomingMessageTime(
          String customer, String messageId, DateTime senderAt) =>
      _ownTimeIdentity(customer,
          () => _bindIncomingMessageTime(customer, messageId, senderAt));

  Future<String?> _bindIncomingMessageTime(
      String customer, String messageId, DateTime senderAt) async {
    final canonical = await (await history)
        .bindIncomingMessageTime(customer, messageId, senderAt);
    if (canonical == null) return null;
    await _synchronizeIncomingTime(customer, canonical);
    return canonical;
  }

  Future<Set<String>> _formallyAnsweredIds(String customer) async {
    final db = await database;
    final result = <String>{};
    for (final row in await db.rawQuery('''SELECT w.message_id,w.session_id,a.*
      FROM automation_session_messages w JOIN delivery_attempts a
        ON a.attempt_id=w.answered_attempt_id AND a.user_id=w.user_id
      WHERE w.user_id=? AND w.response_state='answered' ''', [customer])) {
      if (_positiveCompletionMetadata(row, row['session_id']! as String)) {
        result.add(row['message_id']! as String);
      }
    }
    return result;
  }

  /// File aliases preserve old frozen tasks. SQL projects only an actual
  /// positive native/formal receipt through this customer's exact time key.
  Future<void> _synchronizeIncomingTime(
      String customer, String canonicalId) async {
    final document = await (await history).read(customer);
    final message = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) => m['id'] == canonicalId)
        .firstOrNull;
    if (message == null) return;
    final time = CustomerMessageTime.forMessage(customer, message);
    if (time == null) return;
    final aliases = ConversationFileStore.messageAliases(message);
    final receipts = <String>{
      if (message['media_receipt_id'] is String)
        message['media_receipt_id']! as String,
      ...(message['media_receipt_aliases'] as List? ?? const [])
          .whereType<String>(),
    };
    final session = _automationSessionId;
    final db = await database;
    await db.transaction((txn) async {
      if (session != null && !await _captureSessionMatches(txn, session)) {
        return;
      }
      final items = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final matched = items
          .where((m) =>
              (aliases.contains(m['message_id']) ||
                  receipts.contains(m['item_id'])) &&
              _mediaItemMatchesTime(customer, m, time))
          .toList();
      final roots = matched.where((m) => m['canonical_id'] == null).toList();
      roots.sort((a, b) => ((a['admitted_at_ms'] ?? a['first_seen_ms']) as int)
          .compareTo((b['admitted_at_ms'] ?? b['first_seen_ms']) as int));
      final root = roots.firstOrNull;
      if (root != null) {
        final rootId = root['item_id']! as String;
        for (final item in matched.where((m) => m['item_id'] != rootId)) {
          await txn.update('customer_media_items', {'admission_key': null},
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, item['item_id']]);
        }
        for (final item in matched) {
          final itemAliases =
              (jsonDecode(item['aliases_json']?.toString() ?? '[]') as List)
                  .whereType<String>()
                  .toSet()
                ..addAll(aliases);
          await txn.update(
              'customer_media_items',
              {
                'message_id': canonicalId,
                'sender_ms': CustomerMessageTime.second(
                        DateTime.parse(message['sent_at']! as String))
                    .millisecondsSinceEpoch,
                'aliases_json': jsonEncode(itemAliases.toList()),
                if (item['item_id'] == rootId &&
                    item['admission_session_id'] != null)
                  'admission_key': time,
                if (item['item_id'] == rootId &&
                    item['kind'] == 'text' &&
                    message['media_receipt_id'] != null) ...{
                  'kind': 'unknown',
                  'state': 'detected'
                },
                if (item['item_id'] != rootId) ...{
                  'canonical_id': rootId,
                  'state': 'superseded',
                  'admission_key': null
                },
              },
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, item['item_id']]);
          if (item['item_id'] != rootId) {
            await txn.update(
                'media_card_observations', {'canonical_id': rootId},
                where: 'customer=? AND (item_id=? OR canonical_id=?)',
                whereArgs: [customer, item['item_id'], item['item_id']]);
          }
        }
      }
      if (session == null) return;
      final work = (await txn.query('automation_session_messages',
              where: 'session_id=? AND user_id=?',
              whereArgs: [session, customer]))
          .where((w) => aliases.contains(w['message_id']))
          .toList();
      if (work.isEmpty) return;
      Map<String, Object?>? proof;
      for (final attempt in await txn.query('delivery_attempts',
          where: "user_id=? AND kind IN ('reply','manual_confirmation')",
          whereArgs: [customer])) {
        final raw = jsonDecode(attempt['raw_json']?.toString() ?? '{}') as Map;
        final scope = (raw['formal_response_message_ids'] as List? ??
                raw['service_message_ids'] as List? ??
                const [])
            .whereType<String>()
            .toSet();
        final owner = raw['service_session_id'];
        if (owner is String &&
            scope.intersection(aliases).isNotEmpty &&
            _positiveCompletionMetadata(attempt, owner) &&
            _formalInputScope(raw, scope).intersection(aliases).isNotEmpty) {
          proof = attempt;
          break;
        }
      }
      final previous =
          work.where((w) => w['message_id'] == canonicalId).firstOrNull ??
              work.first;
      final version = _materialWorkVersion(message, previous);
      final first = work.map((w) => w['activated_at_ms']! as int).reduce(min);
      final values = <String, Object?>{
        ...previous,
        'message_id': canonicalId,
        'activated_at_ms': first,
        'work_revision': version.revision,
        'input_key': version.key,
        'input_kind': isMediaWorkMessage(message) ? 'media' : 'text',
        if (proof != null) ...{
          'response_state': 'answered',
          'answered_task_id': proof['task_id'],
          'answered_attempt_id': proof['attempt_id'],
          'responded_at_ms': (jsonDecode(proof['raw_json']! as String)
                  as Map)['native_reply_at_ms'] ??
              proof['updated_at_ms']
        },
      };
      if (work.any((row) => row['message_id'] == canonicalId)) {
        await txn.update('automation_session_messages', values,
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [session, customer, canonicalId]);
      } else {
        await txn.insert('automation_session_messages', values);
      }
      for (final duplicate
          in work.where((w) => w['message_id'] != canonicalId)) {
        await txn.update(
            'automation_session_messages', {'response_state': 'merged'},
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [session, customer, duplicate['message_id']]);
        await txn.delete('automation_message_waits',
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [session, customer, duplicate['message_id']]);
      }
    });
  }

  /// Live admission is the only operation that creates media business. The
  /// caller supplies an occurrence proved relative to the live chat frontier;
  /// an observation hash, clock or `current` flag is not admission evidence.
  Future<MediaMessageAdmission> admitMediaMessage(String customer,
          {required String receiptId,
          required String evidenceId,
          required String occurrenceKey,
          required DateTime receivedAt,
          DateTime? senderAt,
          String? messageId}) =>
      _ownTimeIdentity(
          customer,
          () => _admitMediaMessage(customer,
              receiptId: receiptId,
              evidenceId: evidenceId,
              occurrenceKey: occurrenceKey,
              receivedAt: receivedAt,
              senderAt: senderAt,
              messageId: messageId));

  Future<MediaMessageAdmission> _admitMediaMessage(String customer,
      {required String receiptId,
      required String evidenceId,
      required String occurrenceKey,
      required DateTime receivedAt,
      DateTime? senderAt,
      String? messageId}) async {
    final owner = _automationSessionId;
    if (owner == null ||
        occurrenceKey.trim().isEmpty ||
        receivedAt.isBefore(_automationSessionStartedAt!)) {
      throw StateError('media_admission_requires_current_live_occurrence');
    }
    final db = await database;
    final store = await history;
    final timeKey = senderAt == null
        ? null
        : CustomerMessageTime.incomingId(customer, senderAt);
    String? existingTimeMessage;
    if (senderAt != null) {
      senderAt = CustomerMessageTime.second(senderAt);
      occurrenceKey = timeKey!;
      final original = (await db.query('customer_media_items',
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, receiptId]))
          .firstOrNull;
      if (original != null &&
          !_mediaItemMatchesTime(customer, original, timeKey)) {
        throw StateError('media_admission_sender_time_conflict');
      }
      if (original?['message_id'] is String &&
          original?['admission_key'] != null) {
        existingTimeMessage = await _bindIncomingMessageTime(
            customer, original!['message_id']! as String, senderAt);
      }
      existingTimeMessage ??=
          await store.incomingMessageIdAtTime(customer, senderAt);
      messageId = existingTimeMessage ?? timeKey;
    }
    final observedReceipt = (await db.query('customer_media_items',
            columns: ['canonical_id'],
            where: 'customer=? AND item_id=?',
            whereArgs: [customer, receiptId]))
        .firstOrNull;
    if (observedReceipt == null) {
      throw StateError('media_admission_receipt_missing');
    }
    final hasMediaProof =
        await _receiptHasRealMediaProof(db, customer, receiptId);
    if (existingTimeMessage != null &&
        !hasMediaProof &&
        observedReceipt['canonical_id'] == null) {
      final original = (await store.read(customer))?['messages'] as List?;
      final text = (original ?? const [])
          .whereType<Map>()
          .where((row) => row['id'] == existingTimeMessage)
          .firstOrNull;
      if (text != null &&
          ConversationFileStore.isConfirmedCustomerText(text,
              customer: customer)) {
        // Associate raw evidence with the existing time owner, without
        // changing its file receipt or live input kind. A later real pixel
        // classification can still enrich this same original message.
        await db.transaction((txn) async {
          if (!await _captureSessionMatches(txn, owner)) {
            throw StateError('media_admission_session_changed');
          }
          await txn.update(
              'customer_media_items',
              {
                'message_id': existingTimeMessage,
                'admission_key': occurrenceKey,
                'admission_session_id': owner,
                'admitted_at_ms': receivedAt.millisecondsSinceEpoch,
              },
              where: 'customer=? AND item_id=? AND canonical_id IS NULL',
              whereArgs: [customer, receiptId]);
        });
        return MediaMessageAdmission(
            messageId: existingTimeMessage,
            receiptId: receiptId,
            admittedAt: receivedAt,
            created: false);
      }
    }
    Future<MediaMessageAdmission?> existing(DatabaseExecutor txn) async {
      var found = (await txn.query('customer_media_items',
              where:
                  'customer=? AND admission_session_id=? AND admission_key=?',
              whereArgs: [customer, owner, occurrenceKey]))
          .firstOrNull;
      if (found == null && existingTimeMessage != null) {
        found = (await txn.query('customer_media_items',
                where:
                    'customer=? AND message_id=? AND canonical_id IS NULL AND admission_key IS NOT NULL',
                whereArgs: [customer, existingTimeMessage]))
            .firstOrNull;
      }
      if (found == null) return null;
      if (timeKey != null && !_mediaItemMatchesTime(customer, found, timeKey)) {
        throw StateError('media_admission_sender_time_conflict');
      }
      final candidate = (await txn.query('customer_media_items',
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, receiptId]))
          .firstOrNull;
      if (candidate != null && candidate['item_id'] != found['item_id']) {
        Map<String, Object?>? ancestor = candidate;
        final ancestors = <String>{};
        while (ancestor != null) {
          final ancestorId = ancestor['item_id']! as String;
          if (!ancestors.add(ancestorId)) {
            throw StateError('media_admission_parent_cycle');
          }
          if (timeKey != null &&
              !_mediaItemMatchesTime(customer, ancestor, timeKey)) {
            throw StateError('media_admission_sender_time_conflict');
          }
          if (ancestor['admission_key'] != null &&
              ancestorId != found['item_id'] &&
              timeKey == null) {
            throw StateError('media_admission_parent_conflict');
          }
          final next = ancestor['canonical_id'];
          if (next == null) break;
          ancestor = (await txn.query('customer_media_items',
                  where: 'customer=? AND item_id=?',
                  whereArgs: [customer, next]))
              .firstOrNull;
          if (ancestor == null) {
            throw StateError('media_admission_parent_missing');
          }
        }

        if (timeKey == null &&
            candidate['admission_key'] != null &&
            (candidate['admission_key'] != occurrenceKey ||
                candidate['admission_session_id'] != owner)) {
          throw StateError('media_admission_parent_conflict');
        }
        await txn.update(
            'customer_media_items',
            {
              'canonical_id': found['item_id'],
              'state': 'superseded',
              if (timeKey != null) 'admission_key': null,
            },
            where: 'customer=? AND item_id=?',
            whereArgs: [customer, receiptId]);
        await txn.update(
            'media_card_observations', {'canonical_id': found['item_id']},
            where: 'customer=? AND (item_id=? OR canonical_id=?)',
            whereArgs: [customer, receiptId, receiptId]);
      }
      return MediaMessageAdmission(
          messageId: found['message_id']! as String,
          receiptId: found['item_id']! as String,
          admittedAt: DateTime.fromMillisecondsSinceEpoch(
              found['admitted_at_ms']! as int,
              isUtc: true),
          created: false);
    }

    final duplicate = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) {
        throw StateError('media_admission_session_changed');
      }
      return existing(txn);
    });
    if (duplicate != null) return duplicate;
    if (senderAt == null) {
      throw StateError('media_admission_requires_complete_sender_time');
    }
    if (!_senderTimeInCurrentSession(senderAt)) {
      final held = existingTimeMessage == null
          ? const <Map<String, Object?>>[]
          : await db.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [owner, customer, existingTimeMessage]);
      if (held.isEmpty) {
        throw StateError('media_admission_sender_before_session');
      }
    }
    final seen = <String>{};
    var rootId = receiptId;
    Map<String, Object?> root;
    while (true) {
      if (!seen.add(rootId)) throw StateError('media_admission_parent_cycle');
      final row = (await db.query('customer_media_items',
              where: 'customer=? AND item_id=?', whereArgs: [customer, rootId]))
          .firstOrNull;
      if (row == null) throw StateError('media_admission_receipt_missing');
      root = row;
      if (row['canonical_id'] == null) break;
      rootId = row['canonical_id']! as String;
    }
    if (root['admission_key'] != null) {
      throw StateError('media_admission_parent_conflict');
    }
    var parent = messageId ?? 'media-pending:$rootId';
    final baseline = await isSessionBaselineMessage(customer, parent);
    if (baseline && existingTimeMessage == null) {
      throw StateError('media_admission_baseline_observation');
    }
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: owner,
        capturedAt: receivedAt,
        messages: [
          CapturedMessage(
              stableId: parent,
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              sender: customer,
              sentAt: senderAt,
              axPath: 'live-occurrence:$occurrenceKey',
              mediaReceiptId: rootId,
              captureEvidenceId: evidenceId)
        ]);
    final answeredIds = await _formallyAnsweredIds(customer);
    await store.appendCapture(capture,
        formallyAnsweredIds: answeredIds,
        verifiedMediaReceiptIds: hasMediaProof ? {receiptId} : const {});
    final document = await store.read(customer);
    final persisted = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            ConversationFileStore.messageAliases(m).contains(parent) &&
            m['direction'] == 'incoming' &&
            isMediaWorkMessage(m))
        .firstOrNull;
    if (persisted == null) {
      throw StateError('media_admission_history_not_persisted');
    }
    parent = persisted['id']! as String;
    final alreadyAnswered = ConversationFileStore.messageAliases(persisted)
        .intersection(answeredIds)
        .isNotEmpty;
    final result = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) {
        throw StateError('media_admission_session_changed');
      }
      final reused = await existing(txn);
      if (reused != null) return reused;
      final current = (await txn.query('customer_media_items',
              where: 'customer=? AND item_id=?', whereArgs: [customer, rootId]))
          .single;
      if (current['canonical_id'] != null || current['admission_key'] != null) {
        throw StateError('media_admission_parent_changed');
      }
      await txn.update(
          'customer_media_items',
          {
            'message_id': parent,
            'admission_key': occurrenceKey,
            'admission_session_id': owner,
            'admitted_at_ms': receivedAt.millisecondsSinceEpoch,
          },
          where: 'customer=? AND item_id=?',
          whereArgs: [customer, rootId]);
      final oldWork = (await txn.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [owner, customer, parent]))
          .firstOrNull;
      if (oldWork != null || (!alreadyAnswered && !baseline)) {
        final version = _materialWorkVersion(persisted, oldWork);
        await txn.rawInsert(
            '''INSERT INTO automation_session_messages(
        session_id,user_id,message_id,activated_at_ms,work_revision,input_kind,input_key)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,user_id,message_id) DO UPDATE SET
        work_revision=excluded.work_revision,input_kind=excluded.input_kind,input_key=excluded.input_key''',
            [
              owner,
              customer,
              parent,
              receivedAt.millisecondsSinceEpoch,
              version.revision,
              'media',
              version.key
            ]);
      }
      if (oldWork == null && !alreadyAnswered && !baseline) {
        await _newInputResetsGenerationBackoff(txn, customer);
      }
      return MediaMessageAdmission(
          messageId: parent,
          receiptId: rootId,
          admittedAt: receivedAt.toUtc(),
          created: oldWork == null && !alreadyAnswered && !baseline);
    });
    if (owner == _automationSessionId) {
      await ensurePendingForUnanswered(customer);
    }
    return result;
  }

  /// Called only after the live capture pipeline proves that an empty
  /// placeholder and the readable OCR body are the same incoming bubble.
  /// This changes its representation, not its business identity or SLA cycle.
  Future<String?> clarifyUnknownMessageAsText(String customer,
      {required String parentMessageId,
      required String receiptId,
      required CapturedMessage text,
      required String evidenceId,
      required String expectedSessionId}) {
    final key = '$expectedSessionId:$customer:$parentMessageId';
    final previous = _textClarificationTails[key] ?? Future<void>.value();
    final result = previous.then((_) => _clarifyUnknownMessageAsText(customer,
        parentMessageId: parentMessageId,
        receiptId: receiptId,
        text: text,
        evidenceId: evidenceId,
        expectedSessionId: expectedSessionId));
    _textClarificationTails[key] =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// The live matcher has proved readable chat text in the exact original
  /// customer/sender-second bubble. Only clipped UI fallback pixels may be
  /// withdrawn; originals and independently detected media remain immutable.
  Future<String?> clarifyWeakImageMessageAsText(String customer,
      {required String parentMessageId,
      required String receiptId,
      required CapturedMessage text,
      required String evidenceId,
      required String expectedSessionId}) {
    final key = '$expectedSessionId:$customer:$parentMessageId';
    final previous = _textClarificationTails[key] ?? Future<void>.value();
    final result = previous.then((_) => _clarifyUnknownMessageAsText(customer,
        parentMessageId: parentMessageId,
        receiptId: receiptId,
        text: text,
        evidenceId: evidenceId,
        expectedSessionId: expectedSessionId,
        allowWeakScreenshot: true));
    _textClarificationTails[key] =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<bool> isWeakScreenshotTextCandidate(
      String customer, String receiptId) async {
    final session = _automationSessionId;
    if (session == null) return false;
    final db = await database;
    final rows = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final root = rows.where((r) => r['item_id'] == receiptId).firstOrNull;
    return root != null &&
        await _weakScreenshotFamily(db, customer, session, root, rows);
  }

  Set<String> _mediaReceiptFamily(
      List<Map<String, Object?>> rows, String root) {
    final family = <String>{root};
    var changed = true;
    while (changed) {
      changed = false;
      for (final row in rows) {
        if (family.contains(row['canonical_id']) &&
            family.add(row['item_id']! as String)) {
          changed = true;
        }
      }
    }
    return family;
  }

  Future<bool> _weakScreenshotFamily(DatabaseExecutor txn, String customer,
      String session, Map root, List<Map<String, Object?>> rows) async {
    if (root['canonical_id'] != null ||
        root['message_id'] is! String ||
        root['admission_session_id'] != session ||
        root['identity_ambiguous'] == 1 ||
        root['sender_ms'] is! int ||
        !const {'image', 'text'}.contains(root['kind'])) {
      return false;
    }
    final family = _mediaReceiptFamily(rows, root['item_id']! as String);
    var pixels = false;
    for (final row in rows.where((r) => family.contains(r['item_id']))) {
      if (!const {'unknown', 'image', 'text'}.contains(row['kind']) ||
          row['identity_ambiguous'] == 1 ||
          row['state'] == 'ready' ||
          (row['message_id'] != null &&
              row['message_id'] != root['message_id']) ||
          (row['sender_ms'] != null && row['sender_ms'] != root['sender_ms'])) {
        return false;
      }
      final media = (jsonDecode(row['media_json']?.toString() ?? '[]') as List);
      if (media.any((m) =>
          m is! Map || !ConversationFileStore.isWeakScreenshotPayload(m))) {
        return false;
      }
      pixels |= media.isNotEmpty;
    }
    if (!pixels) return false;
    for (final observation in await txn.query('media_card_observations',
        where: 'customer=?', whereArgs: [customer])) {
      if (!family.contains(observation['item_id']) &&
          !family.contains(observation['canonical_id'])) {
        continue;
      }
      if (observation['classified_kind'] == 'video') return false;
      if (observation['classified_ms'] == null) continue;
      if (observation['classified_kind'] != 'image') return false;
      final audits = await txn.query('media_capture_audit',
          where: 'customer=? AND evidence_id=?',
          whereArgs: [customer, observation['evidence_id']]);
      if (!audits.any((audit) {
        final d = jsonDecode(audit['details']! as String) as Map;
        final occurrence = d['occurrenceContext'] as Map?;
        return audit['state'] == 'image_partial' &&
            d['automationSessionId'] == session &&
            d['parentMessageId'] == root['message_id'] &&
            family.contains(d['mediaReceiptId']) &&
            d['kind'] == 'image' &&
            d['source'] == 'frozen-window-crop' &&
            d['isPartial'] == true &&
            d['playbackOverlayDetected'] != true &&
            occurrence?['explicitVideo'] != true &&
            const {'visible_crop_only', 'matching_media_already_in_history'}
                .contains(d['reason']);
      })) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _receiptHasRealMediaProof(
      DatabaseExecutor db, String customer, String receipt) async {
    var root = receipt;
    final visited = <String>{};
    while (true) {
      if (!visited.add(root)) {
        return true; // Invalid ownership is not text proof.
      }
      final row = (await db.query('customer_media_items',
              columns: ['canonical_id'],
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, root]))
          .firstOrNull;
      if (row == null) return false;
      if (row['canonical_id'] is! String) break;
      root = row['canonical_id']! as String;
    }
    final rows = await db.rawQuery('''WITH RECURSIVE family(item_id) AS (
      SELECT item_id FROM customer_media_items WHERE customer=? AND item_id=?
      UNION SELECT m.item_id FROM customer_media_items m JOIN family f
        ON m.canonical_id=f.item_id WHERE m.customer=?
    ) SELECT m.* FROM customer_media_items m JOIN family f
      ON m.item_id=f.item_id WHERE m.customer=?''',
        [customer, root, customer, customer]);
    if (rows.any((row) =>
        const {'image', 'video'}.contains(row['kind']) ||
        (jsonDecode(row['media_json']?.toString() ?? '[]') as List)
            .isNotEmpty)) {
      return true;
    }
    final ids = rows.map((row) => row['item_id']).toSet();
    if (ids.isEmpty) return false;
    final marks = List.filled(ids.length, '?').join(',');
    return (await db.rawQuery('''SELECT 1 FROM media_card_observations
      WHERE customer=? AND classified_ms IS NOT NULL
        AND classified_kind IN ('image','video') AND
        (item_id IN ($marks) OR canonical_id IN ($marks)) LIMIT 1''',
            [customer, ...ids, ...ids]))
        .isNotEmpty;
  }

  /// Preserve the one customer+sender-second owner. Only actual frozen text
  /// can repair legacy contamination; an untyped visual region cannot assert
  /// that it is text, nor can it erase a classified image/video.
  Future<String?> preserveConfirmedTextAtTime(String customer,
      {required DateTime senderAt,
      required String evidenceId,
      required String expectedSessionId,
      String? receiptId}) async {
    if (_automationSessionId != expectedSessionId) return null;
    final store = await history;
    final document = await store.read(customer);
    final time = CustomerMessageTime.incomingId(customer, senderAt);
    final message = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((message) =>
            ConversationFileStore.incomingTimeKey(customer, message) == time)
        .firstOrNull;
    if (message == null) return null;
    final db = await database;
    final weakReceipt = message['media_receipt_id'];
    if (weakReceipt is String &&
        (receiptId == null || receiptId == weakReceipt) &&
        message['text_origin'] == 'customer_text' &&
        message['body']?.toString().trim().isNotEmpty == true &&
        !message['body'].toString().startsWith('[Customer sent') &&
        await isWeakScreenshotTextCandidate(customer, weakReceipt)) {
      final source =
          message['text_source_evidence_id'] ?? message['capture_evidence_id'];
      if (source is String && source.isNotEmpty) {
        return clarifyWeakImageMessageAsText(customer,
            parentMessageId: message['id']! as String,
            receiptId: weakReceipt,
            text: CapturedMessage(
                stableId: message['id']! as String,
                direction: 'incoming',
                body: message['body']! as String,
                sender: customer,
                sentAt: senderAt,
                captureEvidenceId: source,
                observationTurnKey:
                    message['text_source_observation_turn_key']?.toString(),
                axPath: 'persisted-exact-customer-text'),
            evidenceId: source,
            expectedSessionId: expectedSessionId);
      }
    }
    if (receiptId != null &&
        await _receiptHasRealMediaProof(db, customer, receiptId)) {
      return null;
    }
    if (ConversationFileStore.isConfirmedCustomerText(message,
        customer: customer)) {
      return message['id']! as String;
    }
    final contaminatedReceipt = message['media_receipt_id'];
    if (contaminatedReceipt is! String ||
        await _receiptHasRealMediaProof(db, customer, contaminatedReceipt)) {
      return null;
    }
    final id = message['id']! as String;
    final work = (await db.query('automation_session_messages',
            where:
                "session_id=? AND user_id=? AND message_id=? AND response_state='pending'",
            whereArgs: [expectedSessionId, customer, id]))
        .firstOrNull;
    if (work == null) return null;
    for (final input in await db.query('automation_reply_inputs',
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [expectedSessionId, customer, id],
        orderBy: 'rowid DESC')) {
      final frozen =
          jsonDecode(input['message_json']?.toString() ?? '{}') as Map;
      if (!ConversationFileStore.isConfirmedCustomerText(frozen,
              customer: customer) ||
          ConversationFileStore.incomingTimeKey(customer, frozen) != time) {
        continue;
      }
      final source =
          frozen['text_source_evidence_id'] ?? frozen['capture_evidence_id'];
      if (source is! String || source.isEmpty) continue;
      final currentText = Map<String, Object?>.from(message)
        ..remove('media_receipt_id')
        ..remove('media_receipt_aliases');
      final useCurrentText = ConversationFileStore.isConfirmedCustomerText(
          currentText,
          customer: customer);
      // A newer, complete OCR reading may already have refined this exact
      // utterance while its old unknown type was waiting for repair. Correct
      // that type without restoring the obsolete frozen body. Only unchanged
      // material is eligible to retain its already-generated answer below.
      final textBody = useCurrentText ? currentText['body'] : frozen['body'];
      final textSource = useCurrentText
          ? currentText['text_source_evidence_id'] ??
              currentText['capture_evidence_id'] ??
              source
          : source;
      return _clarifyUnknownMessageAsText(customer,
          parentMessageId: id,
          receiptId: contaminatedReceipt,
          text: CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: textBody! as String,
              sender: customer,
              sentAt: senderAt,
              captureEvidenceId: textSource.toString(),
              observationTurnKey: (useCurrentText
                      ? currentText['observation_turn_key']
                      : frozen['observation_turn_key'])
                  ?.toString(),
              axPath: 'exact-frozen-customer-text'),
          evidenceId: textSource.toString(),
          expectedSessionId: expectedSessionId,
          trustedFrozenOwner: input['owner_id']! as String,
          expectedCurrentMaterialKey:
              ConversationFileStore.materialInputKey(message));
    }
    return null;
  }

  Future<void> _repairFrozenTextKinds(String customer, String session) async {
    // This same-session repair also completes a crash between the terminal
    // receipt claim, durable text write and queue commit. It uses only text
    // already accepted for the exact customer/sender-second record.
    final live = await (await history).read(customer);
    for (final message
        in (live?['messages'] as List? ?? const []).whereType<Map>()) {
      if (message['text_origin'] != 'customer_text' ||
          message['media_receipt_id'] is! String ||
          !(message['live_observed_session_ids'] as List? ?? const [])
              .contains(session)) {
        continue;
      }
      final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
      if (at == null) continue;
      await preserveConfirmedTextAtTime(customer,
          senderAt: at,
          evidenceId: message['capture_evidence_id']?.toString() ?? '',
          expectedSessionId: session,
          receiptId: message['media_receipt_id']! as String);
    }
    // Do not rescan the day's history for ordinary replies or for new media
    // with no original frozen text. Only current contaminated duties qualify.
    final candidates = (await (await database).rawQuery('''SELECT w.message_id
      FROM automation_session_messages w WHERE w.session_id=? AND w.user_id=?
        AND w.response_state='pending' AND w.input_kind='media' AND EXISTS(
          SELECT 1 FROM automation_reply_inputs i WHERE i.session_id=w.session_id
            AND i.user_id=w.user_id AND i.message_id=w.message_id
            AND json_extract(i.message_json,'\$.text_origin')='customer_text'
            AND json_extract(i.message_json,'\$.media_receipt_id') IS NULL
            AND COALESCE(json_array_length(i.message_json,'\$.media'),0)=0)''',
            [session, customer]))
        .map((row) => row['message_id'])
        .toSet();
    if (candidates.isEmpty) return;
    final document = await (await history).read(customer);
    for (final message
        in (document?['messages'] as List? ?? const []).whereType<Map>()) {
      if (message['direction'] != 'incoming' ||
          !candidates.contains(message['id']) ||
          message['media_receipt_id'] is! String ||
          (message['media'] as List? ?? const []).isNotEmpty) {
        continue;
      }
      final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
      if (at == null) continue;
      await preserveConfirmedTextAtTime(customer,
          senderAt: at,
          evidenceId: message['capture_evidence_id']?.toString() ?? '',
          expectedSessionId: session,
          receiptId: message['media_receipt_id']! as String);
    }
  }

  Future<Map<String, Object?>?> _unknownTextParent(DatabaseExecutor txn,
      String customer, String session, String parent, String receipt,
      {required Set<String> observationIds,
      bool allowWeakScreenshot = false}) async {
    if (!await _captureSessionMatches(txn, session)) return null;
    final work = (await txn.query('automation_session_messages',
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [session, customer, parent]))
        .firstOrNull;
    if (work == null ||
        (work['response_state'] != 'pending' &&
            !(allowWeakScreenshot &&
                retiredImageResponseStates.contains(work['response_state'])))) {
      return null;
    }
    final rows = await txn.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final root = rows.where((row) => row['item_id'] == receipt).firstOrNull;
    if (root == null ||
        root['message_id'] != parent ||
        root['canonical_id'] != null ||
        root['admission_session_id'] != session ||
        root['admission_key'] == null ||
        root['identity_ambiguous'] == 1) {
      return null;
    }
    final family = <String>{receipt};
    var added = true;
    while (added) {
      added = false;
      for (final row in rows) {
        if (family.contains(row['canonical_id']) &&
            family.add(row['item_id']! as String)) {
          added = true;
        }
      }
    }
    final hasMedia = rows.where((r) => family.contains(r['item_id'])).any((r) =>
        (jsonDecode(r['media_json']?.toString() ?? '[]') as List).isNotEmpty ||
        !const {'unknown', 'text'}.contains(r['kind']));
    final weak = allowWeakScreenshot &&
        await _weakScreenshotFamily(txn, customer, session, root, rows);
    if (work['response_state'] != 'pending' && !weak) return null;
    if (hasMedia && !weak) {
      return null;
    }
    for (final observation in await txn.query('media_card_observations',
        where: 'customer=?', whereArgs: [customer])) {
      if ((family.contains(observation['item_id']) ||
              family.contains(observation['canonical_id'])) &&
          observation['classified_ms'] != null &&
          const {'image', 'video'}.contains(observation['classified_kind']) &&
          !weak) {
        return null;
      }
    }
    final other = await txn.query('automation_session_messages',
        where: 'session_id=? AND user_id=? AND message_id!=?',
        whereArgs: [session, customer, parent]);
    if (other.any((r) => observationIds.contains(r['message_id']))) return null;
    final identities = {parent, ...observationIds};
    for (final attempt in await txn.rawQuery(
        '''SELECT a.* FROM delivery_attempts a
      WHERE a.user_id=? AND a.kind='reply' AND NOT EXISTS(
        SELECT 1 FROM automation_archived_attempts old WHERE old.attempt_id=a.attempt_id)''',
        [customer])) {
      if (const {
        'not_sent',
        'rejected',
        'superseded_not_sent',
        'superseded_rejected'
      }.contains(attempt['state'])) {
        continue;
      }
      final raw = jsonDecode(attempt['raw_json']?.toString() ?? '{}') as Map;
      final scope = <String>{
        if (attempt['batch_end_message_id'] is String)
          attempt['batch_end_message_id']! as String,
        ...(raw['service_message_ids'] as List? ?? const [])
            .whereType<String>(),
      };
      if (scope.intersection(identities).isNotEmpty) {
        // A confirmed request to resend never answered this wrongly typed
        // original text. Only the existing exact weak-screenshot proof may
        // correct it; uncertain sends and actual answers stay protected.
        if (!(weak &&
            retiredImageResponseStates.contains(work['response_state']) &&
            _isImageResendDraft(raw) &&
            _positiveCompletionMetadata(attempt, session))) {
          return null;
        }
      }
    }
    final activeDrafts = await txn
        .query('generated_drafts', where: 'user_id=?', whereArgs: [customer]);
    for (final draft in activeDrafts) {
      final ids = await _replyInputIds(
          txn, customer, draft['task_id']?.toString() ?? '',
          rawJson: draft['raw_json']?.toString());
      if (ids.contains(parent) || draft['batch_end_message_id'] == parent) {
        if (!const {'ready', 'retry'}.contains(draft['delivery_state'])) {
          return null;
        }
        if (draft['attempt_id'] case final String attempt) {
          final state = (await txn.query('delivery_attempts',
                  columns: ['state'],
                  where: 'user_id=? AND attempt_id=?',
                  whereArgs: [customer, attempt]))
              .firstOrNull?['state'];
          if (!const {'not_sent', 'rejected'}.contains(state)) return null;
        }
      }
    }
    return {...root, 'work_revision': work['work_revision']};
  }

  Future<String?> _clarifyUnknownMessageAsText(String customer,
      {required String parentMessageId,
      required String receiptId,
      required CapturedMessage text,
      required String evidenceId,
      required String expectedSessionId,
      String? trustedFrozenOwner,
      String? expectedCurrentMaterialKey,
      bool allowWeakScreenshot = false}) async {
    if (expectedSessionId != _automationSessionId ||
        evidenceId.isEmpty ||
        text.direction != 'incoming' ||
        (text.sender != null && text.sender != customer) ||
        text.body.trim().isEmpty ||
        text.media.isNotEmpty ||
        text.mediaReceiptId != null) {
      return null;
    }
    final store = await history;
    final before = await store.read(customer);
    final messages =
        (before?['messages'] as List? ?? const []).whereType<Map>();
    final candidate =
        messages.where((m) => m['id'] == parentMessageId).firstOrNull;
    if (candidate == null) return null;
    if (allowWeakScreenshot &&
        (text.sender != customer ||
            text.sentAt == null ||
            text.captureEvidenceId != evidenceId ||
            ConversationFileStore.incomingTimeKey(customer, candidate) !=
                CustomerMessageTime.incomingId(customer, text.sentAt!))) {
      return null;
    }
    if (expectedCurrentMaterialKey != null &&
        ConversationFileStore.materialInputKey(candidate) !=
            expectedCurrentMaterialKey) {
      return null;
    }
    final observationIds = <String>{text.stableId};
    for (final m in messages.where((m) => _matchesWorkId(m, observationIds))) {
      observationIds
          .addAll((m['observed_ids'] as List? ?? const []).whereType<String>());
      if (m['id'] is String) observationIds.add(m['id']! as String);
    }
    observationIds.remove(parentMessageId);
    final db = await database;
    final claimed = await db.transaction((txn) async {
      final parent = await _unknownTextParent(
          txn, customer, expectedSessionId, parentMessageId, receiptId,
          observationIds: observationIds,
          allowWeakScreenshot: allowWeakScreenshot);
      if (parent == null) return null;
      if (trustedFrozenOwner != null) {
        final input = (await txn.query('automation_reply_inputs',
                where:
                    'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
                whereArgs: [
              expectedSessionId,
              customer,
              trustedFrozenOwner,
              parentMessageId
            ]))
            .firstOrNull;
        if (input == null) return null;
        final frozen =
            jsonDecode(input['message_json']?.toString() ?? '{}') as Map;
        if (!ConversationFileStore.isConfirmedCustomerText(frozen,
                customer: customer) ||
            DateTime.tryParse(frozen['sent_at']?.toString() ?? '') !=
                text.sentAt) {
          return null;
        }
        final currentText = Map<String, Object?>.from(candidate)
          ..remove('media_receipt_id')
          ..remove('media_receipt_aliases');
        final matchesFrozen = frozen['body'] == text.body;
        final matchesCurrent = expectedCurrentMaterialKey != null &&
            ConversationFileStore.isConfirmedCustomerText(currentText,
                customer: customer) &&
            currentText['body'] == text.body;
        if (!matchesFrozen && !matchesCurrent) return null;
        if (matchesFrozen) {
          await txn.insert(
              'automation_message_evidence',
              {
                'session_id': expectedSessionId,
                'user_id': customer,
                'message_id': parentMessageId,
                'evidence_key': jsonEncode({
                  'type': 'confirmed_text_kind_repair',
                  'receiptId': receiptId,
                  'frozenOwner': trustedFrozenOwner,
                  'materialKey': ConversationFileStore.materialInputKey(frozen),
                }),
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      // Mark the receipt before file I/O so a late crop cannot turn this proven
      // text back into an image. A failed write restores its acquisition state.
      await txn.update(
          'customer_media_items', {'kind': 'text', 'state': 'superseded'},
          where: 'customer=? AND item_id=?', whereArgs: [customer, receiptId]);
      return parent;
    });
    if (claimed == null) return null;
    Map<String, Object?>? clarified;
    try {
      clarified = await store.clarifyUnknownMessageAsText(customer,
          parentMessageId: parentMessageId,
          receiptId: receiptId,
          text: text,
          sessionId: expectedSessionId,
          evidenceId: evidenceId,
          expectedMaterialKey: expectedCurrentMaterialKey,
          allowWeakScreenshot: allowWeakScreenshot,
          minimumRevision: (claimed['work_revision']! as num).toInt() + 1);
    } catch (_) {
      await _restoreUnclarifiedReceipt(customer, receiptId, claimed);
      rethrow;
    }
    if (clarified == null) {
      await _restoreUnclarifiedReceipt(customer, receiptId, claimed);
      return null;
    }
    final completed = await _finishTextClarification(customer, clarified,
        expectedSessionId: expectedSessionId);
    if (!completed) return null;
    await ensurePendingForUnanswered(customer);
    return parentMessageId;
  }

  Future<void> _restoreUnclarifiedReceipt(
      String customer, String receipt, Map<String, Object?> previous) async {
    if (previous['kind'] == 'text') return;
    await (await database).update('customer_media_items',
        {'kind': previous['kind'], 'state': previous['state']},
        where: "customer=? AND item_id=? AND kind='text'",
        whereArgs: [customer, receipt]);
  }

  Future<bool> _finishTextClarification(String customer, Map message,
      {required String expectedSessionId}) async {
    if (!isClarifiedTextMessage(message)) return false;
    final proof = message['message_kind_evidence'] as Map;
    if (proof['sessionId'] != expectedSessionId) return false;
    final parentId = message['id']! as String;
    final receipt = proof['receiptId']! as String;
    final ids = <String>{
      ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
    }..remove(parentId);
    return (await database).transaction((txn) async {
      final parent = await _unknownTextParent(
          txn, customer, expectedSessionId, parentId, receipt,
          observationIds: ids,
          allowWeakScreenshot: proof['weakScreenshot'] == true);
      if (parent == null) return false;
      await txn.update(
          'customer_media_items', {'kind': 'text', 'state': 'superseded'},
          where: 'customer=? AND item_id=?', whereArgs: [customer, receipt]);
      if (proof['weakScreenshot'] == true) {
        final rows = await txn.query('customer_media_items',
            where: 'customer=?', whereArgs: [customer]);
        final family = _mediaReceiptFamily(rows, receipt);
        for (final id in family) {
          await txn.update('customer_media_items',
              {'kind': 'text', 'state': 'superseded', 'media_json': '[]'},
              where: 'customer=? AND item_id=?', whereArgs: [customer, id]);
        }
        for (final row in await txn.query('media_card_observations',
            where: 'customer=?', whereArgs: [customer])) {
          if (family.contains(row['item_id']) ||
              family.contains(row['canonical_id'])) {
            await txn.update('media_card_observations',
                {'classified_kind': null, 'classified_ms': null},
                where: 'customer=? AND observation_id=?',
                whereArgs: [customer, row['observation_id']]);
          }
        }
        for (final row in await txn.query('media_capture_audit',
            where: 'customer=?', whereArgs: [customer])) {
          final d = jsonDecode(row['details']! as String) as Map;
          if (d['automationSessionId'] != expectedSessionId ||
              d['parentMessageId'] != parentId ||
              !family.contains(d['mediaReceiptId'])) {
            continue;
          }
          await txn.update(
              'media_capture_audit',
              {
                'state': 'rejected_text',
                'details': jsonEncode({
                  ...d,
                  'state': 'rejected_text',
                  'reason': 'exact_customer_text_retracted_weak_screenshot',
                  'captureResolved': true,
                  'analysisComplete': true
                }),
              },
              where: 'customer=? AND observation_id=?',
              whereArgs: [customer, row['observation_id']]);
        }
      }
      final revision = (message['service_evidence_revision'] as num).toInt();
      final currentRevision =
          max(revision, (parent['work_revision']! as num).toInt());
      await txn.update(
          'automation_session_messages',
          {
            'response_state': 'pending',
            'answered_task_id': null,
            'answered_attempt_id': null,
            'responded_at_ms': null,
            'input_kind': 'text',
            'input_key': ConversationFileStore.materialInputKey(message),
            'work_revision': currentRevision
          },
          where:
              "session_id=? AND user_id=? AND message_id=? AND response_state IN ('pending','skipped_image','skipped_media','resend_requested')",
          whereArgs: [expectedSessionId, customer, parentId]);
      await txn.delete('automation_message_waits',
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [expectedSessionId, customer, parentId]);
      for (final row in await txn.query('automation_message_evidence',
          where: 'session_id=? AND user_id=?',
          whereArgs: [expectedSessionId, customer])) {
        final encoded = row['evidence_key']! as String;
        if (!encoded.startsWith('{')) continue;
        final value = jsonDecode(encoded) as Map;
        if (value['type'] == 'media_input_dependency' &&
            value['receiptId'] == receipt) {
          await txn.delete('automation_message_evidence',
              where:
                  'session_id=? AND user_id=? AND message_id=? AND evidence_key=?',
              whereArgs: [
                expectedSessionId,
                customer,
                row['message_id'],
                encoded
              ]);
        }
      }
      final pending = (await txn.query('pending_customers',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      final token = pending?['generation_token']?.toString();
      final preserved = await _preserveRestoredTextSnapshots(
          txn, customer, message, currentRevision,
          activeToken: token);
      if (token != null &&
          !preserved.contains(token) &&
          (await _replyInputIds(txn, customer, token)).contains(parentId)) {
        await txn.update(
            'pending_customers',
            {
              'generation_token': null,
              'generation_retry_at_ms': 0,
              'generation_last_error': null
            },
            where: 'user_id=? AND generation_token=?',
            whereArgs: [customer, token]);
      }
      await _retireInvalidInputDraft(txn, customer);
      return true;
    });
  }

  Future<Set<String>> _preserveRestoredTextSnapshots(
      DatabaseExecutor txn, String customer, Map message, int revision,
      {String? activeToken}) async {
    final session = _automationSessionId;
    if (session == null) return {};
    final id = message['id']! as String;
    final material = ConversationFileStore.materialInputKey(message);
    var authorized = false;
    for (final row in await txn.query('automation_message_evidence',
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [session, customer, id])) {
      final encoded = row['evidence_key']! as String;
      if (!encoded.startsWith('{')) continue;
      final proof = jsonDecode(encoded);
      if (proof is Map &&
          proof['type'] == 'confirmed_text_kind_repair' &&
          proof['materialKey'] == material &&
          proof['receiptId'] ==
              (message['message_kind_evidence'] as Map?)?['receiptId']) {
        authorized = true;
      }
    }
    if (!authorized) return {};
    final drafts = await txn.query('generated_drafts',
        where: "user_id=? AND delivery_state IN ('ready','retry')",
        whereArgs: [customer]);
    final owners = <String>{if (activeToken != null) activeToken};
    for (final draft in drafts) {
      if (draft['attempt_id'] case final String attempt) {
        final state = (await txn.query('delivery_attempts',
                columns: ['state'],
                where: 'user_id=? AND attempt_id=?',
                whereArgs: [customer, attempt]))
            .firstOrNull?['state'];
        if (!const {'not_sent', 'rejected'}.contains(state)) continue;
      }
      if (draft['task_id'] case final String task) owners.add(task);
    }
    final preserved = <String>{};
    for (final owner in owners) {
      final row = (await txn.query('automation_reply_inputs',
              where:
                  'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
              whereArgs: [session, customer, owner, id]))
          .firstOrNull;
      if (row == null) continue;
      final frozen = jsonDecode(row['message_json']?.toString() ?? '{}') as Map;
      if (!ConversationFileStore.isConfirmedCustomerText(frozen,
              customer: customer) ||
          ConversationFileStore.materialInputKey(frozen) != material) {
        continue;
      }
      await txn.update(
          'automation_reply_inputs',
          {
            'message_revision': revision,
            'message_json': jsonEncode({
              ...frozen,
              'reply_work_revision': revision,
              'reply_work_revisions': {
                ...(frozen['reply_work_revisions'] as Map? ?? const {}),
                id: revision,
              },
            }),
          },
          where: 'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
          whereArgs: [session, customer, owner, id]);
      for (final draft in drafts.where((draft) => draft['task_id'] == owner)) {
        final raw = jsonDecode(draft['raw_json']! as String) as Map;
        await txn.update(
            'generated_drafts',
            {
              'raw_json': jsonEncode({
                ...raw,
                'service_message_revisions': {
                  ...(raw['service_message_revisions'] as Map? ?? const {}),
                  id: revision,
                },
              })
            },
            where: 'user_id=? AND task_id=?',
            whereArgs: [customer, owner]);
      }
      preserved.add(owner);
    }
    return preserved;
  }

  Future<bool> _mediaAdmissionMatches(DatabaseExecutor txn, String session,
      String customer, Map message) async {
    final ids = <String>{
      if (message['id'] is String) message['id']! as String,
      ...(message['observed_ids'] as List? ?? const []).whereType<String>()
    };
    final rows = await txn.query('customer_media_items',
        where:
            'customer=? AND admission_session_id=? AND admission_key IS NOT NULL',
        whereArgs: [customer, session]);
    return rows.any((row) => ids.contains(row['message_id']));
  }

  /// A caption and a media bubble remain two incoming messages. This edge is
  /// supplied only by the immutable frame's exact adjacency proof, before
  /// either input is made eligible for generation.
  Future<void> _insertMediaInputDependency(
      DatabaseExecutor txn, String session, String customer,
      {required String textMessageId,
      required String receiptId,
      required String evidenceId,
      String? textInputKey}) async {
    final receipt = await txn.query('customer_media_items',
        columns: ['item_id', 'message_id'],
        where: 'customer=? AND item_id=?',
        whereArgs: [customer, receiptId]);
    if (receipt.isEmpty) throw StateError('media_dependency_receipt_missing');
    if (receipt.single['message_id'] == textMessageId &&
        !await _receiptHasRealMediaProof(txn, customer, receiptId)) {
      final text = (await txn.query('automation_session_messages',
              columns: ['input_kind'],
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, customer, textMessageId]))
          .firstOrNull;
      if (text?['input_kind'] == 'text') return;
    }
    await txn.insert(
        'automation_message_evidence',
        {
          'session_id': session,
          'user_id': customer,
          'message_id': textMessageId,
          'evidence_key': jsonEncode({
            'type': 'media_input_dependency',
            'receiptId': receiptId,
            'evidenceId': evidenceId,
            if (textInputKey != null) 'textInputKey': textInputKey,
          }),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> registerMediaInputDependency(String customer,
      {required String textMessageId,
      required String receiptId,
      required String evidenceId}) async {
    final owner = _automationSessionId;
    if (owner == null) return;
    final db = await database;
    await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) return;
      await _insertMediaInputDependency(txn, owner, customer,
          textMessageId: textMessageId,
          receiptId: receiptId,
          evidenceId: evidenceId);
    });
  }

  static const _imageExpiryPrefix = 'image-expiry:';
  static const _imageResendModel = 'jd-incomplete-image-resend-v1';
  static const retiredImageResponseStates = {
    'skipped_image',
    'skipped_media',
    'resend_requested'
  };

  Map<String, dynamic>? _imageExpiry(Map row) {
    final key = row['content_key']?.toString() ?? '';
    if (!key.startsWith(_imageExpiryPrefix)) return null;
    try {
      return Map<String, dynamic>.from(
          jsonDecode(key.substring(_imageExpiryPrefix.length)) as Map);
    } on FormatException {
      return null;
    }
  }

  bool _isImageResendDraft(Map raw) =>
      raw['model'] == _imageResendModel &&
      raw['image_resend_policy'] is Map &&
      (FixedReplies.isVariant(
              FixedReplies.incompleteImageResend, raw['reply']) ||
          FixedReplies.isVariant(
              FixedReplies.incompleteMediaResend, raw['reply']));

  DateTime? _originalIncomingTime(String customer, Map row) {
    final id = row['message_id']?.toString() ?? row['id']?.toString() ?? '';
    final prefix = 'incoming-time:${Uri.encodeComponent(customer)}:';
    return id.startsWith(prefix)
        ? DateTime.tryParse(id.substring(prefix.length))
        : DateTime.tryParse(row['sent_at']?.toString() ?? '');
  }

  Future<List<String>> incompleteImagePolicyCustomers() async {
    final session = _automationSessionId;
    if (session == null) return [];
    return (await (await database).rawQuery('''SELECT DISTINCT w.user_id
      FROM automation_session_messages w JOIN customer_media_items i
        ON i.customer=w.user_id AND i.message_id=w.message_id
      WHERE w.session_id=? AND i.admission_session_id=?
        AND i.kind='image' AND i.state!='awaiting_kind' AND i.identity_ambiguous=0
        AND w.input_kind='media' AND i.canonical_id IS NULL
        AND (w.response_state='pending' OR EXISTS(
          SELECT 1 FROM automation_session_messages p WHERE p.session_id=w.session_id
            AND p.user_id=w.user_id AND p.response_state='pending' AND p.input_kind='text'))''',
            [session, session]))
        .map((row) => row['user_id']! as String)
        .toList();
  }

  String? _incompleteMediaPolicySourceKind(Map row) {
    // The sender's original clock drives the image expiry only after the
    // payload is known to be an image. An unknown card may be a video,
    // ordinary text, or a reaction and must remain available for acquisition.
    if (row['kind'] != 'image' || row['state'] == 'awaiting_kind') return null;
    try {
      final media = (jsonDecode(row['media_json']?.toString() ?? '[]') as List)
          .whereType<Map>()
          .toList();
      final videoProof = media.any((m) =>
          const {'video', 'audio'}.contains(m['type']) ||
          m['capture_source']?.toString().startsWith('jd_video') == true ||
          ConversationFileStore.mediaRoles(m).any((role) => const {
                'video_cover',
                'first_frame',
                'last_frame'
              }.contains(role)));
      if (videoProof || media.any((m) => m['type_verification'] == 'pending')) {
        return null;
      }
      return 'image';
    } on FormatException {
      return null;
    }
  }

  bool _knownImagePolicyRoot(Map row) =>
      _incompleteMediaPolicySourceKind(row) != null;

  Future<Set<String>> retiredIncompleteImageMessageIds(String customer,
      {DatabaseExecutor? executor}) async {
    final session = _automationSessionId;
    if (session == null) return {};
    final db = executor ?? await database;
    final work = await db.query('automation_session_messages',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer]);
    final retired = work
        .where(
            (row) => retiredImageResponseStates.contains(row['response_state']))
        .map((row) => row['message_id']! as String)
        .toSet();
    for (final wait in await db.query('automation_message_waits',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer])) {
      if (_imageExpiry(wait) != null) {
        retired.add(wait['message_id']! as String);
      }
    }
    return retired;
  }

  Future<Map<String, Map<String, dynamic>>> _incompleteImageReferenceContexts(
      DatabaseExecutor db,
      String customer,
      Iterable<Map<String, dynamic>> messages) async {
    final session = _automationSessionId;
    if (session == null) return {};
    final work = await db.query('automation_session_messages',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer]);
    final policies = <String, Map<String, dynamic>>{};
    for (final wait in await db.query('automation_message_waits',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer])) {
      final policy = _imageExpiry(wait);
      if (policy != null) policies[wait['message_id']! as String] = policy;
    }
    if (policies.isEmpty) return {};
    final images = (await db.query('customer_media_items',
            where:
                "customer=? AND admission_session_id=? AND canonical_id IS NULL AND kind IN ('image','unknown') AND identity_ambiguous=0",
            whereArgs: [
          customer,
          session
        ]))
        .where((row) =>
            _originalIncomingTime(
                customer, {'message_id': row['message_id']}) !=
            null)
        .toList()
      ..sort((a, b) =>
          _originalIncomingTime(customer, {'message_id': a['message_id']})!
              .compareTo(_originalIncomingTime(
                  customer, {'message_id': b['message_id']})!));
    final result = <String, Map<String, dynamic>>{};
    for (final message in messages) {
      if (message['direction'] != 'incoming' ||
          !IncompleteImagePolicy.referencesPreviousImage(
              message['body']?.toString() ?? '')) {
        continue;
      }
      final row = work
          .where((r) =>
              r['response_state'] == 'pending' &&
              r['input_kind'] == 'text' &&
              _matchesWorkId(message, {r['message_id']! as String}))
          .firstOrNull;
      if (row == null) continue;
      final at = _originalIncomingTime(customer, row);
      if (at == null) continue;
      final prior = images
          .where((image) => _originalIncomingTime(
                  customer, {'message_id': image['message_id']})!
              .isBefore(at))
          .toList();
      if (prior.isEmpty) continue;
      final source = prior.last;
      if (images.last['message_id'] != source['message_id']) continue;
      final sourceId = source['message_id']! as String;
      final policy = policies[sourceId];
      if (policy == null) continue;
      result[row['message_id']! as String] = {
        'expired_image_message_ids': [sourceId],
        'source_receipt_id': source['item_id'],
        'source_kind': policy['source_kind'] ?? 'image',
        'reason': 'incomplete_image_expired',
      };
    }
    return result;
  }

  Future<bool> isIncompleteImageAcquisitionAllowed(
      String customer, String messageId,
      {DateTime? now}) async {
    final session = _automationSessionId;
    if (session == null) return true;
    final db = await database;
    final roots = await db.query('customer_media_items',
        where:
            "customer=? AND message_id=? AND canonical_id IS NULL AND kind IN ('image','unknown') AND admission_session_id=?",
        whereArgs: [customer, messageId, session]);
    if (roots.length != 1 ||
        roots.single['identity_ambiguous'] == 1 ||
        !_knownImagePolicyRoot(roots.single)) {
      return true;
    }
    // Existing dispositions stay readable, but age alone never prevents
    // recovery of a still-pending image.
    return !(await retiredIncompleteImageMessageIds(customer, executor: db))
        .contains(messageId);
  }

  /// A network-resend request is an explicit service decision, not successful
  /// image parsing. Its durable original message and native delivery receipt
  /// remain separate from any newly uploaded image or later text question.
  Future<IncompleteImagePolicyResult> processIncompleteImagePolicy(
      String customer,
      {DateTime? now}) async {
    final session = _automationSessionId;
    if (session == null) return const IncompleteImagePolicyResult();
    final at = now ?? DateTime.now();
    final db = await database;
    final knownImages = await db.query('customer_media_items',
        where:
            "customer=? AND canonical_id IS NULL AND kind IN ('image','unknown') AND admission_session_id=? AND identity_ambiguous=0",
        whereArgs: [customer, session]);
    if (!knownImages.any(_knownImagePolicyRoot)) {
      return const IncompleteImagePolicyResult();
    }
    final usable = await CustomerMediaInventory(this)
        .analysisReadyMessageIds(customer, executor: db);
    if (knownImages.every((row) =>
        const {'rejected', 'superseded'}.contains(row['state']) ||
        usable.contains(row['message_id']))) {
      final dispositions = await db.query('automation_message_waits',
          columns: ['message_id'],
          where: 'session_id=? AND user_id=? AND content_key LIKE ?',
          whereArgs: [session, customer, '$_imageExpiryPrefix%'],
          limit: 1);
      if (dispositions.isEmpty) return const IncompleteImagePolicyResult();
    }
    // An unclicked answer whose required files disappeared must release its
    // input owner before the existing resend policy can schedule that work.
    await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return;
      await _retireInvalidInputDraft(txn, customer);
    });
    if ((await db.query('pending_customers',
            columns: ['id'],
            where: 'user_id=?',
            whereArgs: [customer],
            limit: 1))
        .isEmpty) {
      await ensurePendingForUnanswered(customer);
    }
    final result =
        await (await history).withCustomerSnapshot(customer, (document) async {
      final messages = (document?['messages'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      return db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, session)) {
          return const IncompleteImagePolicyResult();
        }
        final work = await txn.query('automation_session_messages',
            where: 'session_id=? AND user_id=?',
            whereArgs: [session, customer]);
        final actual = <String, Map<String, dynamic>>{};
        for (final row in work) {
          final message = messages
              .where((m) =>
                  m['direction'] == 'incoming' &&
                  _matchesWorkId(m, {row['message_id']! as String}))
              .firstOrNull;
          if (message == null || row['response_state'] == 'merged') continue;
          final stamp = _originalIncomingTime(customer, row);
          if (stamp == null || !isOnCurrentBusinessDay(stamp)) continue;
          actual[row['message_id']! as String] = message;
        }
        final roots = (await txn.query('customer_media_items',
                where:
                    "customer=? AND canonical_id IS NULL AND kind IN ('image','unknown') AND admission_session_id=? AND identity_ambiguous=0",
                whereArgs: [
              customer,
              session
            ]))
            .where((row) =>
                actual.containsKey(row['message_id']) &&
                _knownImagePolicyRoot(row))
            .toList();
        final ready = await CustomerMediaInventory(this)
            .analysisReadyMessageIds(customer, executor: txn);
        final waits = {
          for (final row in await txn.query('automation_message_waits',
              where: 'session_id=? AND user_id=?',
              whereArgs: [session, customer]))
            row['message_id']: row
        };
        var changed = false;
        final retired = <String>{};
        Future<void> writePolicy(Map row, Map data) async {
          await txn.insert(
              'automation_message_waits',
              {
                'session_id': session,
                'user_id': customer,
                'message_id': row['message_id'],
                'is_media': 1,
                'content_key': '$_imageExpiryPrefix${jsonEncode(data)}',
                'message_revision': row['work_revision'],
                'task_id': 'image-expiry:${row['message_id']}',
                'updated_at_ms': at.millisecondsSinceEpoch,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }

        final policies = <String, Map<String, dynamic>>{};
        for (final root in roots) {
          final id = root['message_id']! as String;
          final row = work.where((r) => r['message_id'] == id).firstOrNull;
          if (row == null || row['input_kind'] != 'media') continue;
          final old = waits[id] == null ? null : _imageExpiry(waits[id]!);
          if (old != null) policies[id] = old;
          if (row['response_state'] != 'pending' || ready.contains(id)) {
            continue;
          }
          final sent = _originalIncomingTime(customer, row)!;
          final newer = work
              .where((other) => actual.containsKey(other['message_id']))
              .map((other) => _originalIncomingTime(customer, other)!)
              .where((stamp) => stamp.isAfter(sent))
              .toList()
            ..sort();
          final decision = IncompleteImagePolicy.decide(
              now: at,
              waitingSince: sent,
              imageSentAt: sent,
              latestIncomingAt: newer.lastOrNull);
          if (decision == IncompleteImageAction.wait) continue;
          final policy = <String, dynamic>{
            ...?old,
            'version': 1,
            'session_id': session,
            'source_message_id': id,
            'receipt_id': root['item_id'],
            'source_kind': _incompleteMediaPolicySourceKind(root),
            'sender_at_ms': sent.millisecondsSinceEpoch,
            'deadline_ms':
                sent.add(IncompleteImagePolicy.timeout).millisecondsSinceEpoch,
            'status': decision == IncompleteImageAction.skip
                ? (_incompleteMediaPolicySourceKind(root) == 'image'
                    ? 'skipped_image'
                    : 'skipped_media')
                : 'resend_due',
          };
          policies[id] = policy;
          retired.add(id);
          if (old == null || old['status'] != policy['status']) {
            await writePolicy(row, policy);
            changed = true;
          }
          if (decision == IncompleteImageAction.skip) {
            final count = await txn.update('automation_session_messages',
                {'response_state': policy['status']},
                where:
                    "session_id=? AND user_id=? AND message_id=? AND response_state='pending'",
                whereArgs: [session, customer, id]);
            changed = count > 0 || changed;
          }
        }

        // A new message invalidates only an unclicked unsolicited request.
        // Actual/unknown native attempts keep their durable reconciliation path.
        final draftRows = await txn.query('generated_drafts',
            where: 'user_id=?', whereArgs: [customer]);
        if (draftRows.isNotEmpty) {
          final draft = draftRows.single;
          final raw = jsonDecode(draft['raw_json']! as String) as Map;
          if (_isImageResendDraft(raw) &&
              !await _imageResendInputsCurrent(txn, customer, draft, raw)) {
            final attempt = draft['attempt_id'];
            final safe = attempt == null ||
                (await txn.query('delivery_attempts',
                        where:
                            "attempt_id=? AND state IN ('not_sent','rejected')",
                        whereArgs: [attempt]))
                    .isNotEmpty;
            if (safe &&
                const {'ready', 'retry'}.contains(draft['delivery_state'])) {
              await txn.delete('generated_drafts',
                  where: 'user_id=? AND task_id=?',
                  whereArgs: [customer, draft['task_id']]);
              changed = true;
            }
          }
        }
        if ((await txn.query('generated_drafts',
                where: 'user_id=?', whereArgs: [customer]))
            .isNotEmpty) {
          return IncompleteImagePolicyResult(
              changed: changed, retiredMessageIds: retired);
        }
        final pending = (await txn.query('pending_customers',
                where: 'user_id=?', whereArgs: [customer]))
            .firstOrNull;
        final controls = await txn.query('conversation_control',
            columns: ['state'], where: 'user_id=?', whereArgs: [customer]);
        if (controls.any((row) => row['state'] != 'ai_active')) {
          return IncompleteImagePolicyResult(
              changed: changed, retiredMessageIds: retired);
        }
        if (pending == null || pending['generation_token'] != null) {
          return IncompleteImagePolicyResult(
              changed: changed, retiredMessageIds: retired);
        }
        Map<String, Object?>? trigger;
        Map<String, dynamic>? sourcePolicy;
        var mode = 'initial';
        for (final row in work.where((r) => r['response_state'] == 'pending')) {
          final id = row['message_id']! as String;
          if (policies[id]?['status'] == 'resend_due') {
            trigger = row;
            sourcePolicy = policies[id];
            break;
          }
          final message = actual[id];
          if (row['input_kind'] != 'text' ||
              message == null ||
              !IncompleteImagePolicy.isSimpleReference(
                  message['body']?.toString() ?? '')) {
            continue;
          }
          final stamp = _originalIncomingTime(customer, row)!;
          final prior = roots.where((r) {
            final imageTime = _originalIncomingTime(
                customer, {'message_id': r['message_id']});
            return imageTime != null && imageTime.isBefore(stamp);
          }).toList()
            ..sort((a, b) => (_originalIncomingTime(
                    customer, {'message_id': a['message_id']})!)
                .compareTo(_originalIncomingTime(
                    customer, {'message_id': b['message_id']})!));
          if (prior.isEmpty) continue;
          final candidate = prior.last;
          final policy = policies[candidate['message_id']];
          if (policy == null ||
              !retiredImageResponseStates.contains(policy['status'])) {
            continue;
          }
          // A genuinely new uploaded image supersedes a stale resend request.
          if (roots.any((r) =>
              _originalIncomingTime(customer, {'message_id': r['message_id']})!
                  .isAfter(_originalIncomingTime(
                      customer, {'message_id': candidate['message_id']})!))) {
            continue;
          }
          trigger = row;
          sourcePolicy = policy;
          mode = 'reference';
          break;
        }
        if (trigger == null || sourcePolicy == null) {
          return IncompleteImagePolicyResult(
              changed: changed, retiredMessageIds: retired);
        }
        final id = trigger['message_id']! as String;
        final message = actual[id]!;
        final task = _taskId();
        final reply = FixedReplies.text(
            sourcePolicy['source_kind'] == 'unknown'
                ? FixedReplies.incompleteMediaResend
                : FixedReplies.incompleteImageResend,
            CustomerLanguageResolver.resolve(messages).language);
        await _bindReplyInputs(txn, customer, task, {id},
            messages: {id: message});
        final window =
            await _snapshotReplyResponseWindow(txn, customer, scope: {id});
        final raw = <String, dynamic>{
          'reply': reply,
          'model': _imageResendModel,
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'reply_purpose': 'substantive',
          'service_session_id': session,
          'service_message_ids': [id],
          'formal_response_message_ids': [id],
          'service_message_revisions': {id: trigger['work_revision']},
          'service_response_window': window,
          'reply_media_dependency_keys': <String, String>{},
          'image_resend_policy': {
            ...sourcePolicy,
            'mode': mode,
            'trigger_message_id': id,
            'task_id': task
          },
        };
        await txn.insert('generated_drafts', {
          'user_id': customer,
          'pending_id': pending['id'],
          'reply': reply,
          'model': _imageResendModel,
          'raw_json': jsonEncode(raw),
          'created_at_ms': at.millisecondsSinceEpoch,
          'delivery_state': 'ready',
          'delivery_attempts': 0,
          'batch_end_message_id': id,
          'task_id': task,
          'queued_at_ms': at.millisecondsSinceEpoch,
        });
        return IncompleteImagePolicyResult(
            changed: true,
            queuedResponse: true,
            retiredMessageIds: {
              ...retired,
              sourcePolicy['source_message_id']! as String
            });
      });
    });
    if (result.changed && session == _automationSessionId) {
      await ensurePendingForUnanswered(customer);
    }
    return result;
  }

  Future<bool> _imageResendInputsCurrent(
      DatabaseExecutor txn, String customer, Map draft, Map raw) async {
    if (!_isImageResendDraft(raw) ||
        raw['service_session_id'] != _automationSessionId) {
      return false;
    }
    final policy = raw['image_resend_policy'] as Map;
    if (policy['session_id'] != _automationSessionId ||
        policy['task_id'] != draft['task_id']) {
      return false;
    }
    final sourceId = policy['source_message_id'];
    final triggerId = policy['trigger_message_id'];
    final waits = await txn.query('automation_message_waits',
        where: 'session_id=? AND user_id=? AND message_id=?',
        whereArgs: [_automationSessionId, customer, sourceId]);
    final stored = waits.isEmpty ? null : _imageExpiry(waits.single);
    if (stored == null ||
        stored['receipt_id'] != policy['receipt_id'] ||
        stored['deadline_ms'] != policy['deadline_ms']) {
      return false;
    }
    final roots = await txn.query('customer_media_items',
        where:
            "customer=? AND item_id=? AND message_id=? AND kind IN ('image','unknown') AND canonical_id IS NULL AND admission_session_id=? AND identity_ambiguous=0",
        whereArgs: [
          customer,
          policy['receipt_id'],
          sourceId,
          _automationSessionId
        ]);
    if (roots.length != 1 || !_knownImagePolicyRoot(roots.single)) return false;
    final work = await txn.query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [_automationSessionId, customer]);
    final trigger = work.where((r) => r['message_id'] == triggerId).firstOrNull;
    if (trigger == null || trigger['response_state'] != 'pending') return false;
    if (policy['mode'] == 'initial') {
      if (sourceId != triggerId || stored['status'] != 'resend_due') {
        return false;
      }
      final sent = _originalIncomingTime(customer, trigger);
      return sent != null &&
          !work.any((r) =>
              r['response_state'] != 'merged' &&
              _originalIncomingTime(customer, r)?.isAfter(sent) == true);
    }
    if (policy['mode'] != 'reference' ||
        trigger['input_kind'] != 'text' ||
        !retiredImageResponseStates.contains(stored['status'])) {
      return false;
    }
    final inputs = await txn.query('automation_reply_inputs',
        where: 'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
        whereArgs: [
          _automationSessionId,
          customer,
          draft['task_id'],
          triggerId
        ]);
    if (inputs.length != 1) return false;
    final input =
        jsonDecode(inputs.single['message_json']?.toString() ?? '{}') as Map;
    if (!IncompleteImagePolicy.referencesPreviousImage(
        input['body']?.toString() ?? '')) {
      return false;
    }
    final sourceAt = _originalIncomingTime(customer, {'message_id': sourceId});
    final otherImages = await txn.query('customer_media_items',
        where:
            "customer=? AND admission_session_id=? AND canonical_id IS NULL AND kind IN ('image','unknown') AND message_id!=?",
        whereArgs: [customer, _automationSessionId, sourceId]);
    return sourceAt != null &&
        !otherImages.any((r) =>
            _originalIncomingTime(customer, {'message_id': r['message_id']})
                ?.isAfter(sourceAt) ==
            true);
  }

  Future<Map<String, Set<String>>> _generationDependencyScope(
      DatabaseExecutor txn, String session, String customer, Map? document,
      {bool receiptFactsWithoutContent = true}) async {
    final work = await txn.rawQuery(
        'SELECT rowid AS received_order,* FROM automation_session_messages '
        'WHERE session_id=? AND user_id=?',
        [session, customer]);
    final messages =
        (document?['messages'] as List? ?? const []).whereType<Map>().toList();
    final inventory = await txn.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final retiredImages =
        await retiredIncompleteImageMessageIds(customer, executor: txn);
    final byReceipt = {
      for (final row in inventory) row['item_id']! as String: row
    };
    Map<String, Object?>? rootFor(String receipt) {
      var row = byReceipt[receipt];
      final seen = <String>{};
      while (row?['canonical_id'] is String) {
        if (!seen.add(row!['item_id']! as String)) return null;
        row = byReceipt[row['canonical_id']];
      }
      if (row == null ||
          retiredImages.contains(row['message_id']) ||
          row['admission_session_id'] != session ||
          row['admission_key'] == null ||
          row['kind'] == 'text' ||
          row['identity_ambiguous'] == 1 ||
          !work.any((w) =>
              w['message_id'] == row!['message_id'] &&
              w['input_kind'] == 'media')) {
        return null;
      }
      return row;
    }

    final scope = <String, Set<String>>{};
    final evidence = await txn.query('automation_message_evidence',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer]);
    for (final edge in evidence) {
      final encoded = edge['evidence_key']! as String;
      if (!encoded.startsWith('{')) continue;
      final data = jsonDecode(encoded) as Map;
      if (data['type'] != 'media_input_dependency' ||
          data['receiptId'] is! String) {
        continue;
      }
      final root = rootFor(data['receiptId']! as String);
      if (root == null) continue;
      final id = edge['message_id']! as String;
      final current = messages
          .where((m) =>
              m['id'] == id ||
              (m['observed_ids'] as List? ?? const []).contains(id))
          .firstOrNull;
      if (current == null ||
          (data['textInputKey'] is String &&
              data['textInputKey'] !=
                  ConversationFileStore.materialInputKey(current))) {
        continue;
      }
      for (final row in work.where((w) =>
          w['input_kind'] == 'media' &&
          _matchesWorkId(current, {w['message_id']! as String}))) {
        scope
            .putIfAbsent(row['message_id']! as String, () => {})
            .add(root['item_id']! as String);
      }
    }
    // Semantic references and capture adjacency remain useful context, but a
    // text message is independently answerable work. Only actual media work
    // may retain a parsing dependency.
    return scope;
  }

  Future<Set<String>> _eligibleGenerationInputs(
      DatabaseExecutor txn, String session, String customer, Map? document,
      {Map<String, Set<String>>? knownDependencies}) async {
    final inventory = CustomerMediaInventory(this);
    final keys =
        await inventory.analyzableEvidenceKeys(customer, executor: txn);
    final ready =
        await inventory.analysisReadyMessageIds(customer, executor: txn);
    final dependencies = knownDependencies ??
        await _generationDependencyScope(txn, session, customer, document);
    final work = await txn.query('automation_session_messages',
        where: "session_id=? AND user_id=? AND response_state='pending'",
        whereArgs: [session, customer]);
    final expiredImageIds =
        await retiredIncompleteImageMessageIds(customer, executor: txn);
    final waits = {
      for (final row in await txn.query('automation_message_waits',
          where: 'session_id=? AND user_id=?', whereArgs: [session, customer]))
        row['message_id']: row
    };
    final eligible = <String>{};
    final generationToken = (await txn.query('pending_customers',
            columns: ['generation_token'],
            where: 'user_id=?',
            whereArgs: [customer]))
        .firstOrNull?['generation_token'];
    final frozenIds = generationToken == null
        ? const <String>{}
        : (await txn.query('automation_reply_inputs',
                columns: ['message_id'],
                where: 'session_id=? AND user_id=? AND owner_id=?',
                whereArgs: [session, customer, generationToken]))
            .map((row) => row['message_id']! as String)
            .toSet();
    // Repair follows each unchanged original message through batch expansion.
    // A later bubble cannot erase an in-flight correction's failure history.
    for (final row in work) {
      final id = row['message_id']! as String;
      if (waits[id] != null && _isUncertainDeliveryWait(waits[id]!)) continue;
      if (row['input_kind'] == 'media' && expiredImageIds.contains(id)) {
        continue;
      }
      final pending = {
        for (final dependency in row['input_kind'] == 'media'
            ? dependencies[id] ?? <String>{}
            : const <String>{})
          if (!ready.contains(dependency)) dependency: keys[dependency] ?? ''
      };
      if (pending.isNotEmpty) {
        await txn.insert(
            'automation_message_waits',
            {
              'session_id': session,
              'user_id': customer,
              'message_id': id,
              'is_media': 0,
              'content_key': jsonEncode(pending),
              'message_revision': row['work_revision'],
              'task_id': 'dependency-preflight:$id',
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        continue;
      }
      var wait = waits[id];
      final repair = wait == null ? null : _automaticReplyRepair(wait);
      if (repair != null) {
        if (!_automaticReplyRepairInputCurrent(repair, id, work, document)) {
          await _clearAutomaticReplyRepairForScope(txn, customer, {id});
          wait = null;
        } else {
          final state =
              (repair['message_states'] as Map?)?[id] ?? repair['state'];
          final knownPending =
              (repair['known_pending_message_ids'] as List? ?? const [])
                  .whereType<String>()
                  .toSet();
          final newReadyInput = work.any((row) {
            final other = row['message_id']! as String;
            final otherWait = waits[other];
            final otherRepair =
                otherWait == null ? null : _automaticReplyRepair(otherWait);
            final otherState =
                (otherRepair?['message_states'] as Map?)?[other] ??
                    otherRepair?['state'];
            if (otherState == 'operator_required' &&
                _automaticReplyRepairInputCurrent(
                    otherRepair!, other, work, document)) {
              return false;
            }
            return !knownPending.contains(other) &&
                (row['input_kind'] != 'media' || ready.contains(other)) &&
                (dependencies[other] ?? const <String>{}).every(ready.contains);
          });
          if (state == 'correction_required' ||
              (newReadyInput && !frozenIds.contains(id))) {
            eligible.add(id);
          }
          continue;
        }
      }
      if (wait != null &&
          (row['input_kind'] == 'text' ||
              wait['task_id']?.toString().startsWith('dependency-preflight:') ==
                  true)) {
        await txn.delete('automation_message_waits',
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [session, customer, id]);
        wait = null;
      }
      if (row['input_kind'] == 'media' && !ready.contains(id)) continue;
      if (wait == null ||
          wait['message_revision'] != row['work_revision'] ||
          _waitDependenciesReady(wait, ready) ||
          _currentWaitKey(keys, wait) != wait['content_key']) {
        eligible.add(id);
      }
    }
    return eligible;
  }

  static const _automaticReplyRepairPrefix = 'answer-repair:';

  Map<String, Object?>? _automaticReplyRepair(Map row) {
    final encoded = row['content_key']?.toString() ?? '';
    if (!encoded.startsWith(_automaticReplyRepairPrefix)) return null;
    try {
      return Map<String, Object?>.from(
          jsonDecode(encoded.substring(_automaticReplyRepairPrefix.length))
              as Map);
    } on FormatException {
      return null;
    }
  }

  bool _automaticReplyRepairInputCurrent(
      Map repair, String id, Iterable<Map> work, Map? document) {
    final revisions = repair['message_revisions'] as Map? ?? const {};
    final keys = repair['material_keys'] as Map? ?? const {};
    if (!revisions.containsKey(id)) return false;
    final row = work.where((row) => row['message_id'] == id).firstOrNull;
    if (row == null ||
        row['response_state'] != 'pending' ||
        row['work_revision'] != revisions[id] ||
        row['input_key'] != keys[id]) {
      return false;
    }
    final message = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((message) => _matchesWorkId(message, {id}))
        .firstOrNull;
    return message != null &&
        ConversationFileStore.materialInputKey(message) == keys[id];
  }

  Future<void> _clearAutomaticReplyRepairForScope(
      DatabaseExecutor txn, String customer, Set<String> scope) async {
    final session = _automationSessionId;
    if (session == null || scope.isEmpty) return;
    await txn.delete('automation_message_waits',
        where: 'session_id=? AND user_id=? AND content_key LIKE ? '
            'AND message_id IN (${List.filled(scope.length, '?').join(',')})',
        whereArgs: [
          session,
          customer,
          '$_automaticReplyRepairPrefix%',
          ...scope
        ]);
  }

  /// Corrective context is read only for the currently frozen request. It
  /// cannot leak an older customer's failed reply or a changed message into
  /// a new task. No receipt, cursor or business ID is changed by this record.
  Future<Map<String, Object?>?> automaticReplyRepairContext(String customer,
      {String? generationToken}) async {
    final session = _automationSessionId;
    if (session == null) return null;
    final db = await database;
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return null;
      final pending = (await txn.query('pending_customers',
              columns: ['generation_token'],
              where: 'user_id=?',
              whereArgs: [customer]))
          .firstOrNull;
      final token = generationToken ?? pending?['generation_token']?.toString();
      if (token == null || token != pending?['generation_token']) return null;
      final input = await txn.rawQuery(
          '''SELECT i.*,m.input_key,m.work_revision,
        m.response_state FROM automation_reply_inputs i
        JOIN automation_session_messages m ON m.session_id=i.session_id
          AND m.user_id=i.user_id AND m.message_id=i.message_id
        WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
          [session, customer, token]);
      if (input.isEmpty ||
          input.any((row) =>
              row['response_state'] != 'pending' ||
              row['message_revision'] != row['work_revision'])) {
        return null;
      }
      final contexts = <Map<String, Object?>>[];
      final revisions = <String, Object?>{};
      final keys = <String, Object?>{};
      final failures = <String, Object?>{};
      final states = <String, Object?>{};
      for (final wait in await txn.query('automation_message_waits',
          where: 'session_id=? AND user_id=? AND content_key LIKE ?',
          whereArgs: [session, customer, '$_automaticReplyRepairPrefix%'],
          orderBy: 'updated_at_ms DESC')) {
        final repair = _automaticReplyRepair(wait);
        if (repair == null) continue;
        final id = wait['message_id']! as String;
        final version = (repair['message_revisions'] as Map?)?[id];
        final key = (repair['material_keys'] as Map?)?[id];
        if (!input.any((row) =>
            row['message_id'] == id &&
            row['message_revision'] == version &&
            row['input_key'] == key)) {
          continue;
        }
        revisions[id] = version;
        keys[id] = key;
        failures[id] = (repair['message_failure_counts'] as Map?)?[id] ??
            repair['failure_count'];
        states[id] = (repair['message_states'] as Map?)?[id] ?? repair['state'];
        contexts.add(repair);
      }
      if (contexts.isNotEmpty) {
        return {
          ...contexts.first,
          'message_ids': revisions.keys.toList(),
          'message_revisions': revisions,
          'material_keys': keys,
          'message_failure_counts': failures,
          'message_states': states,
          'failure_count': failures.values
              .whereType<num>()
              .fold<int>(0, (count, value) => max(count, value.toInt())),
          'state': states.values.every((state) => state == 'operator_required')
              ? 'operator_required'
              : 'correction_required',
        };
      }
      return null;
    });
  }

  /// Explicit operator action reopens only answer repair. Real acquisition
  /// waits and physical send/transfer ownership remain untouched.
  Future<bool> retryAutomaticReplyRepair(String customer) async {
    final session = _automationSessionId;
    if (session == null) return false;
    return (await database).transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return false;
      if ((await txn.query('generated_drafts',
              columns: ['user_id'], where: 'user_id=?', whereArgs: [customer]))
          .isNotEmpty) {
        return false;
      }
      final pending = (await txn.query('pending_customers',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      if (pending == null || pending['generation_token'] != null) return false;
      final deleted = await txn.delete('automation_message_waits',
          where: 'session_id=? AND user_id=? AND content_key LIKE ?',
          whereArgs: [session, customer, '$_automaticReplyRepairPrefix%']);
      if (deleted == 0) return false;
      await txn.update(
          'pending_customers',
          {
            'generation_retry_at_ms': 0,
            'generation_last_error': null,
          },
          where: 'user_id=?',
          whereArgs: [customer]);
      return true;
    });
  }

  Future<AutomaticDraftSaveResult> _recordAutomaticReplyRepair(
      DatabaseExecutor txn,
      String customer,
      String task,
      Set<String> scope,
      Map raw,
      AiDraft draft,
      int now) async {
    final session = _automationSessionId!;
    if ((await retiredIncompleteImageMessageIds(customer, executor: txn))
        .intersection(scope)
        .isNotEmpty) {
      return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
    }
    final input = await txn.query('automation_reply_inputs',
        where: 'session_id=? AND user_id=? AND owner_id=?',
        whereArgs: [session, customer, task]);
    final work = await txn.query('automation_session_messages',
        where: "session_id=? AND user_id=? AND response_state='pending'",
        whereArgs: [session, customer]);
    final orderedIds = scope.toList()..sort();
    final versions = {
      for (final row in input.where((row) => scope.contains(row['message_id'])))
        row['message_id']! as String: row['message_revision'],
    };
    final keys = {
      for (final row in work.where((row) => scope.contains(row['message_id'])))
        row['message_id']! as String: row['input_key'],
    };
    final scopeKey = jsonEncode([
      for (final id in orderedIds) [id, versions[id], keys[id]]
    ]);
    final previousFailures = {for (final id in orderedIds) id: 0};
    for (final wait in await txn.query('automation_message_waits',
        where: 'session_id=? AND user_id=?', whereArgs: [session, customer])) {
      final previous = _automaticReplyRepair(wait);
      if (previous == null) continue;
      for (final id in orderedIds) {
        if ((previous['message_revisions'] as Map?)?[id] != versions[id] ||
            (previous['material_keys'] as Map?)?[id] != keys[id]) {
          continue;
        }
        final count = ((previous['message_failure_counts'] as Map?)?[id] ??
            previous['failure_count']) as num?;
        previousFailures[id] = max(previousFailures[id]!, count?.toInt() ?? 0);
      }
    }
    final counts = {
      for (final entry in previousFailures.entries) entry.key: entry.value + 1
    };
    final states = {
      for (final entry in counts.entries)
        entry.key: entry.value > 1 ? 'operator_required' : 'correction_required'
    };
    final operatorRequired = states.values.contains('operator_required');
    final failures = counts.values.fold<int>(0, max);
    final repair = <String, Object?>{
      'state': states.values.every((state) => state == 'operator_required')
          ? 'operator_required'
          : 'correction_required',
      'failure_count': failures,
      'message_failure_counts': counts,
      'message_states': states,
      'failure_reason': 'status_without_answer',
      'previous_reply': draft.reply,
      'previous_purpose': raw['reply_purpose'],
      'message_ids': orderedIds,
      'message_revisions': versions,
      'material_keys': keys,
      'known_pending_message_ids':
          work.map((row) => row['message_id']).toList(),
      'scope_key': scopeKey,
      'instruction': 'The previous result was only a waiting/review notice, '
          'not an answer. Answer every unresolved message in the frozen batch '
          'or ask a useful clarification. Do not repeat the waiting notice. '
          'A later greeting does not replace an earlier unresolved request.',
    };
    for (final row in input.where((row) => scope.contains(row['message_id']))) {
      final message =
          jsonDecode(row['message_json']?.toString() ?? '{}') as Map;
      await txn.update(
          'automation_reply_inputs',
          {
            'message_json':
                jsonEncode({...message, 'automatic_reply_repair': repair}),
          },
          where: 'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
          whereArgs: [session, customer, task, row['message_id']]);
      await txn.insert(
          'automation_message_waits',
          {
            'session_id': session,
            'user_id': customer,
            'message_id': row['message_id'],
            'is_media': 0,
            'content_key': '$_automaticReplyRepairPrefix${jsonEncode(repair)}',
            'message_revision': row['message_revision'],
            'task_id': task,
            'updated_at_ms': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await txn.update(
        'pending_customers',
        {
          'generation_retry_at_ms': 0,
          'generation_last_error': 'status_without_answer',
        },
        where: 'user_id=?',
        whereArgs: [customer]);
    return AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.needsAnswer,
        requiresOperator: operatorRequired, repairContext: repair);
  }

  /// Recheck only this generation's leased inputs after a visual type hint.
  /// A different customer's work or a later, unfrozen bubble cannot hold up
  /// this reply. Type confirmation does not create or complete business.
  Future<bool> generationInputsAnalysisReady(String customer,
      {required String generationToken}) async {
    if (!await generationInputVersionsCurrent(customer,
        generationToken: generationToken)) {
      return false;
    }
    final owner = _automationSessionId;
    if (owner == null) return true;
    final db = await database;
    final lease = await db.query('pending_customers',
        columns: ['user_id'],
        where: 'user_id=? AND generation_token=?',
        whereArgs: [customer, generationToken]);
    if (lease.isEmpty) return false;
    final input = await db.rawQuery(
        '''SELECT i.*,m.input_kind,m.work_revision,m.response_state
      FROM automation_reply_inputs i JOIN automation_session_messages m
        ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
      WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
        [owner, customer, generationToken]);
    if (input.isEmpty ||
        input.any((row) =>
            row['response_state'] != 'pending' ||
            row['work_revision'] != row['message_revision'])) {
      return false;
    }
    final ready =
        await CustomerMediaInventory(this).analysisReadyMessageIds(customer);
    final legacyDependencies = <String>{};
    for (final row in input) {
      if (row['input_kind'] == 'text') continue;
      final message =
          jsonDecode(row['message_json']?.toString() ?? '{}') as Map;
      final aliases = <String>{
        row['message_id']! as String,
        if (message['id'] is String) message['id']! as String,
        ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
        if (message['media_receipt_id'] is String) ...[
          message['media_receipt_id']! as String,
          'media-pending:${message['media_receipt_id']}',
        ],
      };
      if (row['input_kind'] == 'media' && aliases.intersection(ready).isEmpty) {
        return false;
      }
      if (message['reply_media_input_dependencies']
          case final List dependencies) {
        if (dependencies.whereType<String>().any((id) => !ready.contains(id))) {
          return false;
        }
      } else {
        legacyDependencies.add(row['message_id']! as String);
      }
    }
    if (legacyDependencies.isEmpty) return owner == _automationSessionId;
    final dependencies = await db.query('automation_message_evidence',
        where: 'session_id=? AND user_id=?', whereArgs: [owner, customer]);
    for (final row in dependencies) {
      if (!legacyDependencies.contains(row['message_id'])) continue;
      final encoded = row['evidence_key']! as String;
      if (!encoded.startsWith('{')) continue;
      final dependency = jsonDecode(encoded) as Map;
      if (dependency['type'] == 'media_input_dependency' &&
          !ready.contains(dependency['receiptId']) &&
          !ready.contains('media-pending:${dependency['receiptId']}')) {
        return false;
      }
    }
    return owner == _automationSessionId;
  }

  /// Parsing and CLI work run outside the short commit owner. Only this
  /// lease's actual input can invalidate it; another bubble cannot do so.
  Future<bool> generationInputVersionsCurrent(String customer,
      {required String generationToken}) async {
    final session = _automationSessionId;
    if (session == null) return true;
    final db = await database;
    return (await history).withCustomerSnapshot(customer, (document) async {
      if (session != _automationSessionId) return false;
      final lease = await db.query('pending_customers',
          columns: ['user_id'],
          where: 'user_id=? AND generation_token=?',
          whereArgs: [customer, generationToken]);
      if (lease.isEmpty) return false;
      final rows = await db.rawQuery(
          '''SELECT i.*,m.work_revision,m.response_state
        FROM automation_reply_inputs i JOIN automation_session_messages m
        ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
        WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
          [session, customer, generationToken]);
      return rows.isNotEmpty &&
          rows.every((row) =>
              row['response_state'] == 'pending' &&
              row['work_revision'] == row['message_revision']) &&
          _frozenMaterialCurrent(rows, document);
    });
  }

  bool _frozenMaterialCurrent(Iterable<Map> inputs, Map? document) {
    final current =
        (document?['messages'] as List? ?? const []).whereType<Map>();
    for (final row in inputs) {
      final encoded = row['message_json'];
      if (encoded is! String) continue;
      final frozen = jsonDecode(encoded) as Map;
      final expected = frozen['reply_material_input_key'];
      if (expected is! String) continue; // Previous-version lease.
      final id = frozen['id'] ?? row['message_id'];
      final found = current
          .where((m) =>
              m['id'] == id ||
              (m['observed_ids'] as List? ?? const []).contains(id))
          .firstOrNull;
      if (found == null ||
          ConversationFileStore.materialInputKey(found) != expected) {
        return false;
      }
    }
    return true;
  }

  /// A proven representation of a completed bubble is context, not a new
  /// customer request. Keep all durable aliases consistent without rewriting
  /// a frozen input scope or guessing from clocks/files.
  Future<bool> reconcileProvenMediaAliases(String customer,
      {required String canonicalReceiptId,
      required String duplicateReceiptId,
      required String expectedSessionId}) async {
    if (_automationSessionId != expectedSessionId ||
        canonicalReceiptId == duplicateReceiptId) {
      return false;
    }
    final db = await database;
    final rows = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final byId = {for (final row in rows) row['item_id']! as String: row};
    final canonical = byId[canonicalReceiptId];
    final duplicate = byId[duplicateReceiptId];
    if (canonical == null ||
        duplicate == null ||
        canonical['canonical_id'] != null ||
        canonical['admission_session_id'] != expectedSessionId ||
        duplicate['admission_session_id'] != expectedSessionId ||
        canonical['admission_key'] == null ||
        canonical['message_id'] is! String ||
        duplicate['message_id'] is! String ||
        canonical['kind'] == 'text' ||
        duplicate['kind'] == 'text' ||
        canonical['identity_ambiguous'] == 1 ||
        duplicate['identity_ambiguous'] == 1) {
      return false;
    }
    String? rootOf(Map row) {
      var current = row;
      final seen = <String>{};
      while (current['canonical_id'] is String) {
        if (!seen.add(current['item_id']! as String)) return null;
        final parent = byId[current['canonical_id']];
        if (parent == null) return null;
        current = parent;
      }
      return current['item_id']! as String;
    }

    // Inventory must first persist its exact, physically proved ancestry.
    // This method cannot authorize merging two independent business owners.
    if (rootOf(duplicate) != canonicalReceiptId) return false;
    final mediaIds = (await db.query('automation_session_messages',
            columns: ['message_id'],
            where: "session_id=? AND user_id=? AND input_kind='media'",
            whereArgs: [expectedSessionId, customer]))
        .map((row) => row['message_id']! as String)
        .toSet();
    final family = rows.where((row) => rootOf(row) == canonicalReceiptId);
    final messages = <String>{
      canonical['message_id']! as String,
      for (final row in family) ...{
        if (mediaIds.contains(row['message_id'])) row['message_id']! as String,
        ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
            .whereType<String>()
            .where(mediaIds.contains),
      },
    };
    if (!messages.contains(duplicate['message_id']) ||
        _automationSessionId != expectedSessionId) {
      return false;
    }
    await (await history).consolidateProvenMediaAliases(customer,
        canonicalMessageId: canonical['message_id']! as String,
        messageAliases: messages,
        receiptAliases: family.map((row) => row['item_id']! as String));
    if (_automationSessionId != expectedSessionId) return false;
    // Existing exact native/formal ownership is projected through that proved
    // alias only. Neither an unsent draft nor a holding reply completes work.
    await _reconcileCanonicalMessageWork(customer);
    await ensurePendingForUnanswered(customer);
    return true;
  }

  Future<void> _reconcileCanonicalMessageWork(String customer) async {
    final owner = _automationSessionId;
    if (owner == null) return;
    final db = await database;
    await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) return;
      final work = await txn.query('automation_session_messages',
          where: 'session_id=? AND user_id=?', whereArgs: [owner, customer]);
      final media = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      for (final group in _canonicalMessageGroups(work, media)) {
        if (!group.pending || group.media.isEmpty) continue;
        Map<String, Object?>? proof;
        for (final row in group.work) {
          if (retiredImageResponseStates.contains(row['response_state'])) {
            proof = row;
            break;
          }
          if (row['response_state'] == 'delegated') {
            proof = row;
            break;
          }
          if (row['response_state'] != 'answered' ||
              row['answered_attempt_id'] == null) {
            continue;
          }
          final attempt = (await txn.query('delivery_attempts',
                  where:
                      "attempt_id=? AND user_id=? AND kind IN ('reply','manual_confirmation') AND state IN ('submitted','accepted')",
                  whereArgs: [row['answered_attempt_id'], customer]))
              .firstOrNull;
          if (attempt == null) continue;
          if (!_positiveCompletionMetadata(attempt, owner)) continue;
          final raw = jsonDecode(attempt['raw_json']! as String) as Map;
          if (_formalInputScope(raw, {row['message_id']! as String})
              .isNotEmpty) {
            proof = row;
            break;
          }
        }
        if (proof == null) continue;
        for (final row
            in group.work.where((r) => r['response_state'] == 'pending')) {
          await txn.update(
              'automation_session_messages',
              {
                'response_state': proof['response_state'],
                'answered_task_id': proof['answered_task_id'],
                'answered_attempt_id': proof['answered_attempt_id'],
                'responded_at_ms': proof['responded_at_ms'],
              },
              where:
                  "session_id=? AND user_id=? AND message_id=? AND response_state='pending' AND work_revision=?",
              whereArgs: [
                owner,
                customer,
                row['message_id'],
                row['work_revision']
              ]);
          await txn.delete('automation_message_waits',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [owner, customer, row['message_id']]);
        }
      }
      await _retireInvalidInputDraft(txn, customer);
    });
  }

  /// Business remains pending while media is unavailable. Only usable content
  /// changes (not a timer, alias, crop path or customer-wide revision) wake it.
  Future<Set<String>> _generationPendingSessionIds(String customer) async {
    final owner = _automationSessionId;
    if (owner == null) return _pendingSessionIds(customer);
    await _reconcileCanonicalMessageWork(customer);
    final db = await database;
    return (await history).withCustomerSnapshot(customer, (document) async {
      if (owner != _automationSessionId) return <String>{};
      return db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, owner)) return <String>{};
        return _eligibleGenerationInputs(txn, owner, customer, document);
      });
    });
  }

  /// Classification is explicit for new model output and conservative for old
  /// automatic loading-only output. Manual free-form drafts do not call this.
  Future<AiDraft> prepareAutomaticDraft(String customer, AiDraft draft) async {
    draft = normalizeReplyProgress(draft);
    final input = (await generationMessages(customer))
        .where((message) => message['direction'] == 'incoming')
        .toList();
    final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
    final keys =
        await CustomerMediaInventory(this).analyzableEvidenceKeys(customer);
    final analysisReady =
        await CustomerMediaInventory(this).analysisReadyMessageIds(customer);
    final snapshot = (raw['reply_evidence_key_snapshot'] as Map?)
            ?.map((key, value) => MapEntry('$key', '$value')) ??
        keys;
    final text =
        input.where((message) => !_isMediaReplyInput(message)).toList();
    final receiptOnly = text.isNotEmpty &&
        text.every((message) =>
            isExplicitMediaReceiptQuestion(message['body']?.toString() ?? ''));
    var purpose = replyPurpose(draft);
    if (receiptOnly &&
        (isReceiptFactReply(draft.reply) ||
            draft.model == 'local-media-receipt')) {
      purpose = ReplyPurpose.receipt;
    } else if (isReviewAcknowledgement(raw) ||
        isOnlyReplyProgressNotice(draft.reply) &&
            purpose != ReplyPurpose.mediaStatus) {
      purpose = ReplyPurpose.reviewStatus;
    } else if (purpose == ReplyPurpose.receipt && !receiptOnly) {
      // A normal answer with a mistaken receipt label still answers its
      // inputs. A receipt fact alone was classified as a notice above.
      purpose = ReplyPurpose.substantive;
    } else if ((input.isNotEmpty &&
            text.isEmpty &&
            !input.any((m) => _matchesWorkId(m, analysisReady))) ||
        (isOnlyMediaProgressNotice(draft.reply) &&
            (raw['media_dependent'] == true ||
                input.any(_isMediaReplyInput)))) {
      purpose = ReplyPurpose.mediaStatus;
    }
    final actualDependencies =
        await _scopedMediaDependencyKeys(await database, customer, raw);
    if (purpose == ReplyPurpose.substantive &&
        actualDependencies != null &&
        actualDependencies.keys.any((id) => !analysisReady.contains(id))) {
      // Only the actual media inputs owned by this reply require parsing.
      purpose = ReplyPurpose.mediaStatus;
    }
    final answered = <String>{
      if (purpose != ReplyPurpose.mediaStatus &&
          purpose != ReplyPurpose.reviewStatus)
        for (final message in input)
          if (!ResponseTimingPolicy.isSocialAcknowledgement(draft.reply) ||
              ResponseTimingPolicy.isSocialAcknowledgement(
                  message['body']?.toString() ?? ''))
            if (purpose != ReplyPurpose.receipt || !_isMediaReplyInput(message))
              if (!_isMediaReplyInput(message) ||
                  _matchesWorkId(message, analysisReady)) ...{
                message['id']! as String,
                ...(message['observed_ids'] as List? ?? const [])
                    .whereType<String>(),
              }
    };
    if (answered.isEmpty &&
        input.isNotEmpty &&
        purpose != ReplyPurpose.reviewStatus) {
      purpose = ReplyPurpose.mediaStatus;
    }
    final mixedMedia = input.any(_isMediaReplyInput);
    final waitingTextIds = <String>{
      if (purpose == ReplyPurpose.mediaStatus ||
          purpose == ReplyPurpose.reviewStatus)
        for (final message in text)
          if (purpose == ReplyPurpose.reviewStatus ||
              !mixedMedia ||
              RegExp(r'\b(?:check|watch|review|look at|analy[sz]e|problem|issue|shown|shows?)\b.{0,45}\b(?:video|clip|image|photo|picture)\b|\b(?:this|that|my|attached)\s+(?:video|clip|image|photo|picture)\b|^(?:this|that)\s+(?:problem|issue)\b|(?:这|该|刚发).{0,12}(?:视频|图片|照片|问题|故障)|(?:看|检查|分析).{0,12}(?:视频|图片|照片)',
                      caseSensitive: false)
                  .hasMatch(message['body']?.toString() ?? '')) ...{
            message['id']! as String,
            ...(message['observed_ids'] as List? ?? const [])
                .whereType<String>(),
          }
    };
    return withReplyProgress(draft, {
      'reply_purpose': switch (purpose) {
        ReplyPurpose.substantive => 'substantive',
        ReplyPurpose.mediaStatus => 'media_status',
        ReplyPurpose.receipt => 'receipt',
        ReplyPurpose.reviewStatus => 'review_status',
      },
      'automatic_progress_classified': true,
      if (_automationSessionId != null)
        'reply_media_dependency_keys': actualDependencies ?? <String, String>{},
      if (purpose == ReplyPurpose.receipt) 'review_acknowledgement_only': false,
      'media_wait_text_inputs': purpose == ReplyPurpose.reviewStatus ||
          purpose == ReplyPurpose.mediaStatus && !input.any(_isMediaReplyInput),
      'media_wait_message_ids': waitingTextIds.toList(),
      'formal_response_message_ids': answered.toList(),
      'reply_evidence_key_snapshot': snapshot,
    });
  }

  Future<bool> _waitForInputEvidence(DatabaseExecutor txn, String customer,
      String task, Set<String> ids, Map<String, dynamic> raw) async {
    final session = _automationSessionId;
    if (session == null || ids.isEmpty) return false;
    final keys = (raw['reply_evidence_key_snapshot'] as Map?)
            ?.map((key, value) => MapEntry('$key', '$value')) ??
        const <String, String>{};
    final dependencies = _mediaDependencyKeys(raw);
    final ready = dependencies == null
        ? const <String>{}
        : await CustomerMediaInventory(this)
            .analysisReadyMessageIds(customer, executor: txn);
    final waitingDependencies = dependencies == null
        ? null
        : {
            for (final entry in dependencies.entries)
              if (!ready.contains(entry.key)) entry.key: entry.value,
          };
    var parked = false;
    final input = await txn.rawQuery('''SELECT i.*,m.input_kind
      FROM automation_reply_inputs i JOIN automation_session_messages m
      ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
      WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
        [session, customer, task]);
    for (final row in input) {
      final id = row['message_id']! as String;
      if (!ids.contains(id)) continue;
      if (row['input_kind'] == 'text') {
        await txn.delete('automation_message_waits',
            where: 'session_id=? AND user_id=? AND message_id=? '
                'AND content_key NOT LIKE ?',
            whereArgs: [
              session,
              customer,
              id,
              '$_automaticReplyRepairPrefix%'
            ]);
        continue;
      }
      final existing = await txn.query('automation_message_waits',
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [session, customer, id]);
      if (existing.any((wait) => _imageExpiry(wait) != null)) continue;
      final message = row['message_json'] == null
          ? const <String, dynamic>{}
          : jsonDecode(row['message_json']! as String) as Map;
      final isMedia = isMediaWorkMessage(message);
      // Only an actual unfinished dependency may park work. A loading/review
      // notice after parsing finished is a failed answer, not a future event
      // that this customer must somehow cause by sending another attachment.
      if (waitingDependencies != null && waitingDependencies.isEmpty) {
        await txn.delete('automation_message_waits',
            where: 'session_id=? AND user_id=? AND message_id=? '
                'AND content_key NOT LIKE ?',
            whereArgs: [
              session,
              customer,
              id,
              '$_automaticReplyRepairPrefix%'
            ]);
        continue;
      }
      final textWait = raw['media_wait_message_ids'];
      if (!isMedia &&
          (textWait is List
              ? !textWait.contains(id)
              : raw['media_wait_text_inputs'] != true)) {
        continue;
      }
      await txn.insert(
          'automation_message_waits',
          {
            'session_id': session,
            'user_id': customer,
            'message_id': id,
            'is_media': isMedia ? 1 : 0,
            'content_key': waitingDependencies == null
                ? _contentKey(keys, id, isMedia)
                : _contentKey(waitingDependencies, id, false,
                    dependencyIds: waitingDependencies.keys),
            'message_revision': row['message_revision'],
            'task_id': task,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      parked = true;
      if (isReviewAcknowledgement(raw)) {
        await txn.update(
            'automation_reply_inputs',
            {
              'message_json': jsonEncode({
                ...message,
                'reply_wait_purpose': 'review_status',
              }),
            },
            where: 'session_id=? AND user_id=? AND owner_id=? AND message_id=?',
            whereArgs: [session, customer, task, id]);
      }
    }
    return parked;
  }

  Future<Set<String>> awaitingMediaMessageIds(String customer) async =>
      (await _pendingSessionIds(customer))
          .difference(await _generationPendingSessionIds(customer));

  bool _matchesWorkId(Map message, Set<String> ids) =>
      ids.contains(message['id']) ||
      (message['observed_ids'] as List? ?? const []).any(ids.contains);

  int _messageIndex(Iterable<Map> messages, Object? id) => id is String
      ? messages
          .toList(growable: false)
          .indexWhere((m) => _matchesWorkId(m, {id}))
      : -1;

  List<Map<String, dynamic>> _inMessageOrder(
      List<Map<String, dynamic>> messages) {
    final indexed = messages.indexed.toList();
    DateTime? clock(Map<String, dynamic> message) =>
        DateTime.tryParse(message['sent_at']?.toString() ?? '') ??
        DateTime.tryParse(message['captured_at']?.toString() ?? '');
    indexed.sort((a, b) {
      final left = clock(a.$2);
      final right = clock(b.$2);
      final order = left == null
          ? (right == null ? 0 : 1)
          : right == null
              ? -1
              : left.compareTo(right);
      return order == 0 ? a.$1.compareTo(b.$1) : order;
    });
    return indexed.map((entry) => entry.$2).toList();
  }

  /// Sender time orders the conversation, not the discovery snapshot. A
  /// newly discovered older-clock question must not truncate inputs already
  /// known when that question became the batch anchor.
  Future<List<Map<String, dynamic>>> _inputsThroughGenerationAnchor(
      DatabaseExecutor txn,
      String customer,
      String anchor,
      List<Map<String, dynamic>> messages,
      {Set<String>? eligibleIds}) async {
    final end = messages.where((message) =>
        message['direction'] == 'incoming' &&
        (message['id'] == anchor ||
            (message['observed_ids'] as List? ?? const []).contains(anchor)));
    if (end.isEmpty) return [];
    final pending = await txn.rawQuery(
        '''SELECT rowid AS activation_order,message_id FROM automation_session_messages
      WHERE session_id=? AND user_id=? AND response_state='pending' ORDER BY rowid''',
        [_automationSessionId, customer]);
    final available = pending
        .where((row) =>
            eligibleIds == null || eligibleIds.contains(row['message_id']))
        .toList();
    final exact = available.where((row) => row['message_id'] == anchor);
    final anchors = exact.isNotEmpty
        ? exact
        : available.where(
            (row) => _matchesWorkId(end.first, {row['message_id']! as String}));
    if (anchors.isEmpty) return [];
    final cutoff =
        anchors.map((row) => row['activation_order']! as int).reduce(max);
    final ids = available
        .where((row) => (row['activation_order']! as int) <= cutoff)
        .map((row) => row['message_id']! as String)
        .toSet();
    return messages
        .where((message) =>
            message['direction'] == 'incoming' && _matchesWorkId(message, ids))
        .toList();
  }

  /// Current business is the set of received messages still lacking a formal
  /// response. Sender order and the most recent outgoing bubble are context,
  /// never proof that an unseen/late-discovered question has been answered.
  Future<List<Map<String, dynamic>>> processingMessages(String customer,
      {Map<String, dynamic>? document, bool includeAnswered = false}) async {
    final doc = document ?? await (await history).read(customer);
    final messages = _inMessageOrder((doc?['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList());
    if (_automationSessionId == null) return messages;
    final workRows = await (await database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [_automationSessionId, customer]);
    final work = {for (final r in workRows) r['message_id']! as String: r};
    final pending = workRows
        .where((r) => includeAnswered || r['response_state'] == 'pending')
        .map((r) => r['message_id']! as String)
        .toSet();
    final archived = (await (await database)
            .query('automation_archived_attempts', columns: ['attempt_id']))
        .map((a) => a['attempt_id'])
        .toSet();
    final imageReferenceContexts = await _incompleteImageReferenceContexts(
        await database, customer, messages);
    return messages.where((m) {
      if (m['direction'] == 'incoming') return _matchesWorkId(m, pending);
      if (m['direction'] != 'outgoing' ||
          archived.contains(m['delivery_attempt_id'])) {
        return false;
      }
      final sent = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      return sent != null && !sent.isBefore(_automationSessionStartedAt!);
    }).map((m) {
      if (m['direction'] != 'incoming') return m;
      final matches = work.values
          .where((r) => _matchesWorkId(m, {r['message_id']! as String}))
          .toList();
      final row =
          matches.where((r) => r['response_state'] == 'pending').firstOrNull ??
              matches.firstOrNull;
      return <String, dynamic>{
        ...m,
        if (row != null && imageReferenceContexts[row['message_id']] != null)
          'incomplete_image_resend_required':
              imageReferenceContexts[row['message_id']],
        'reply_input_kind':
            row?['input_kind'] ?? (isMediaWorkMessage(m) ? 'media' : 'text'),
        'reply_work_state': row?['response_state'] ?? 'pending',
        'reply_work_revision': row?['work_revision'] ?? 0,
        'reply_work_revisions': {
          for (final input in matches)
            input['message_id']! as String: input['work_revision']
        },
      };
    }).toList();
  }

  /// Input leased to the actual generation, rather than every question that
  /// happens to sort before its last message when the answer later arrives.
  Future<List<Map<String, dynamic>>> generationMessages(String customer,
      {String? batchEndMessageId, Map<String, dynamic>? document}) async {
    final current = await processingMessages(customer, document: document);
    if (_automationSessionId == null) return current;
    final db = await database;
    return db.transaction((txn) async {
      final pending = (await txn.query('pending_customers',
              columns: ['generation_token'],
              where: 'user_id=?',
              whereArgs: [customer]))
          .firstOrNull;
      final token = pending?['generation_token']?.toString();
      if (token == null && batchEndMessageId == null) {
        return <Map<String, dynamic>>[];
      }
      final owner = token ?? 'unleased:$batchEndMessageId';
      if (token == null) {
        final input = await _inputsThroughGenerationAnchor(
            txn, customer, batchEndMessageId!, current);
        if (input.isEmpty) return <Map<String, dynamic>>[];
        await txn.delete('automation_reply_inputs',
            where: 'session_id=? AND user_id=? AND owner_id=?',
            whereArgs: [_automationSessionId, customer, owner]);
        await _bindReplyInputs(
            txn, customer, owner, input.map((m) => m['id']! as String),
            messages: {for (final m in input) m['id']! as String: m});
      }
      final rows = await txn.rawQuery(
          '''SELECT i.*,m.response_state,m.work_revision,m.input_kind FROM automation_reply_inputs i
        JOIN automation_session_messages m ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
        WHERE i.session_id=? AND i.user_id=? AND i.owner_id=? ORDER BY i.rowid''',
          [_automationSessionId, customer, owner]);
      if (rows.isEmpty ||
          rows.any((r) =>
              r['response_state'] != 'pending' ||
              r['work_revision'] != r['message_revision'])) {
        return <Map<String, dynamic>>[];
      }
      final frozen = <Map<String, dynamic>>[];
      final emitted = <String>{};
      for (final row in rows) {
        final encoded = row['message_json']?.toString();
        final message = encoded == null
            ? current.where((m) => m['id'] == row['message_id']).firstOrNull
            : Map<String, dynamic>.from(jsonDecode(encoded) as Map);
        if (message == null) return <Map<String, dynamic>>[];
        // Proven card aliases retain separate ledger revisions, but one
        // canonical customer message is presented to the generator once.
        if (!emitted.add(message['id']! as String)) continue;
        frozen.add({
          ...message,
          'reply_input_kind': row['input_kind'],
          if (row['input_kind'] == 'text')
            'reply_media_input_dependencies': <String>[],
          'reply_work_state': 'pending',
          'reply_work_revision': row['message_revision']
        });
      }
      if (batchEndMessageId != null &&
          !frozen.any((m) =>
              m['id'] == batchEndMessageId ||
              (m['observed_ids'] as List? ?? const [])
                  .contains(batchEndMessageId))) {
        return <Map<String, dynamic>>[];
      }
      return [...current.where((m) => m['direction'] != 'incoming'), ...frozen];
    });
  }

  Map<String, Object?> _noReplyResponseWindow(String customer) =>
      {'customer': customer, 'identityVerified': false};

  Map<String, Object?>? _verifiedReplyResponseWindow(
      Object? value, String customer) {
    if (value is! Map ||
        value['customer'] != customer ||
        value['identityVerified'] != true ||
        value['cycleId'] is! String ||
        value['startedAtMs'] is! int ||
        value['dueAtMs'] is! int ||
        value['dueAtMs'] !=
            (value['startedAtMs']! as int) + holdingDelay.inMilliseconds) {
      return null;
    }
    return Map<String, Object?>.from(value);
  }

  Map<String, Object?> _responseWindowFromInputs(
      Iterable<Map> inputs, String customer) {
    final windows = <Map<String, Object?>>[];
    for (final input in inputs) {
      final message =
          jsonDecode(input['message_json']?.toString() ?? '{}') as Map;
      final window = _verifiedReplyResponseWindow(
          message['reply_response_window'], customer);
      if (window != null) windows.add(window);
    }
    windows.sort((a, b) =>
        (a['startedAtMs']! as int).compareTo(b['startedAtMs']! as int));
    return windows.firstOrNull ?? _noReplyResponseWindow(customer);
  }

  Future<Map<String, Object?>> _snapshotReplyResponseWindow(
      DatabaseExecutor txn, String customer,
      {Iterable<String>? scope}) async {
    final cycle = (await txn.query('platform_response_cycles',
            where: 'user_id=? AND identity_verified=1', whereArgs: [customer]))
        .firstOrNull;
    if (cycle == null) return _noReplyResponseWindow(customer);
    final start = cycle['started_at_ms']! as int;
    if (_automationSessionId != null && scope != null) {
      final ids = scope.toSet();
      if (ids.isEmpty) return _noReplyResponseWindow(customer);
      final work = await txn.query('automation_session_messages',
          columns: ['activated_at_ms'],
          where:
              'session_id=? AND user_id=? AND message_id IN (${List.filled(ids.length, '?').join(',')})',
          whereArgs: [_automationSessionId, customer, ...ids]);
      // An old media wait cannot borrow a later red cycle after a holding
      // response. Allow only the small AX observation delay for this scope.
      if (work.length != ids.length ||
          work.any((row) => (row['activated_at_ms']! as int) + 2000 < start)) {
        return _noReplyResponseWindow(customer);
      }
    }
    return {
      'customer': customer,
      'identityVerified': true,
      'cycleId': cycle['cycle_id'],
      'startedAtMs': start,
      'dueAtMs': start + holdingDelay.inMilliseconds
    };
  }

  Future<Map<String, Object?>?> _deliveryResponseWindow(
      DatabaseExecutor txn, String customer, Map raw, int generatedAtMs) async {
    if (raw.containsKey('service_response_window')) {
      return _verifiedReplyResponseWindow(
          raw['service_response_window'], customer);
    }
    final live = await _snapshotReplyResponseWindow(txn, customer);
    final window = _verifiedReplyResponseWindow(live, customer);
    // Compatibility for old queued rows has no durable task-cycle proof.
    // A newer live cycle can never reclassify an older generated answer.
    return window != null && generatedAtMs >= (window['startedAtMs']! as int)
        ? window
        : null;
  }

  Future<void> _bindReplyInputs(
      DatabaseExecutor txn, String customer, String owner, Iterable<String> ids,
      {Map<String, int>? revisions,
      Map<String, Map<String, dynamic>>? messages,
      Map<String, Object?>? responseWindow}) async {
    final session = _automationSessionId;
    if (session == null) return;
    final inputs = <String, Map<String, dynamic>?>{};
    for (final id in ids.toSet()) {
      final message = messages?[id];
      for (final alias in <String>{
        id,
        ...(message?['observed_ids'] as List? ?? const []).whereType<String>()
      }) {
        inputs[alias] = message;
      }
    }
    for (final entry in inputs.entries) {
      final id = entry.key;
      final message = entry.value;
      final row = (await txn.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, customer, id]))
          .firstOrNull;
      if (row == null || row['response_state'] != 'pending') continue;
      await txn.insert(
          'automation_reply_inputs',
          {
            'session_id': session,
            'user_id': customer,
            'owner_id': owner,
            'message_id': id,
            'message_revision': revisions?[id] ??
                (message?['reply_work_revisions'] as Map?)?[id] ??
                (message != null && message['id'] == id
                    ? message['reply_work_revision']
                    : null) ??
                row['work_revision'] ??
                0,
            'message_json': message == null
                ? null
                : jsonEncode({
                    ...message,
                    if (responseWindow != null)
                      'reply_response_window': responseWindow,
                  }),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<Set<String>> _replyInputIds(
      DatabaseExecutor txn, String customer, String owner,
      {String? rawJson, bool currentRevisionOnly = false}) async {
    final session = _automationSessionId;
    if (session == null) return {};
    final rows = await txn.rawQuery('''SELECT i.* FROM automation_reply_inputs i
      JOIN automation_session_messages m ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
      WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?
        ${currentRevisionOnly ? "AND m.response_state='pending' AND m.work_revision=i.message_revision" : ""}''',
        [session, customer, owner]);
    if (rows.isNotEmpty) {
      return rows.map((r) => r['message_id']! as String).toSet();
    }
    if (rawJson != null && !currentRevisionOnly) {
      try {
        final raw = jsonDecode(rawJson) as Map;
        if (raw['service_session_id'] == session) {
          return (raw['service_message_ids'] as List? ?? const [])
              .whereType<String>()
              .toSet();
        }
      } catch (_) {/* A malformed draft is quarantined by its normal reader. */}
    }
    return {};
  }

  bool _positiveCompletionMetadata(Map attempt, String session) {
    final raw = jsonDecode(attempt['raw_json']?.toString() ?? '{}') as Map;
    if (raw['service_session_id'] != session) return false;
    if (attempt['kind'] == 'manual_confirmation') {
      return attempt['state'] == 'accepted' &&
          raw['explicit_manual_confirmation'] == true;
    }
    return attempt['kind'] == 'reply' &&
        const {
          'sending',
          'submitted',
          'accepted',
          'superseded_submitted',
          'superseded_accepted'
        }.contains(attempt['state']) &&
        raw['native_confirmed_at_ms'] is num &&
        raw['native_reply_at_ms'] is num;
  }

  /// Native journals are durable send evidence. An OCR body/clock is never
  /// allowed to manufacture this proof, even for a known unsent draft.
  Future<bool> _verifyNativeSubmission(String customer, String attemptId,
      {String? taskId}) async {
    final session = _automationSessionId;
    if (session == null) {
      return true; // Legacy history has no current-run ledger.
    }
    final db = await database;
    final row = (await db.rawQuery('''SELECT a.* FROM delivery_attempts a
      WHERE a.attempt_id=? AND a.user_id=? AND a.kind='reply'
      AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts x WHERE x.attempt_id=a.attempt_id)''',
            [attemptId, customer]))
        .firstOrNull;
    if (row == null || taskId != null && row['task_id'] != taskId) return false;
    if (_positiveCompletionMetadata(row, session)) return true;
    final raw = jsonDecode(row['raw_json']! as String) as Map;
    if (raw['service_session_id'] != session) return false;
    Map receipt;
    try {
      receipt = jsonDecode(await File(p.join(
              (await storageRoot).path, 'delivery_receipts', '$attemptId.json'))
          .readAsString()) as Map;
    } catch (_) {
      return false;
    }
    if (receipt['attemptId'] != attemptId ||
        receipt['customer'] != customer ||
        receipt['state'] != 'submitted') {
      return false;
    }
    final written = (receipt['timeMs'] as num?)?.toInt();
    if (written == null || written < (row['created_at_ms']! as int) - 1000) {
      return false;
    }
    final clicked = receipt['sendClickedAtMs'];
    final valid = clicked is num &&
        clicked.isFinite &&
        clicked >= (row['created_at_ms']! as int) - 1000 &&
        clicked <= written + 1000;
    final at = valid ? clicked.toInt() : written;
    if (session != _automationSessionId) return false;
    await db.rawUpdate("""UPDATE delivery_attempts SET raw_json=?,
      state=CASE
        WHEN state IN ('accepted','superseded_accepted') THEN state
        WHEN state LIKE 'superseded_%' THEN 'superseded_submitted'
        ELSE 'submitted' END
      WHERE attempt_id=? AND user_id=?""", [
      jsonEncode({
        ...raw,
        'native_reply_at_ms': at,
        'native_reply_time_source':
            valid ? 'native_click' : 'native_confirmation',
        'native_confirmed_at_ms': written
      }),
      attemptId,
      customer,
    ]);
    return true;
  }

  Future<void> _completeReplyInputs(
      DatabaseExecutor txn, String customer, String owner,
      {String? attemptId, String? rawJson, String state = 'answered'}) async {
    final session = _automationSessionId;
    if (session == null) return;
    if (state == 'answered') {
      if (attemptId == null) return;
      final proof = (await txn.rawQuery('''SELECT a.* FROM delivery_attempts a
        WHERE a.attempt_id=? AND a.user_id=? AND a.task_id=?
        AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts x WHERE x.attempt_id=a.attempt_id)''',
              [attemptId, customer, owner]))
          .firstOrNull;
      if (proof == null || !_positiveCompletionMetadata(proof, session)) return;
    }
    final scope = await _replyInputIds(txn, customer, owner, rawJson: rawJson);
    final raw = rawJson == null
        ? const <String, dynamic>{}
        : jsonDecode(rawJson) as Map<String, dynamic>;
    final covered = state == 'answered' ? _formalInputScope(raw, scope) : scope;
    if (covered.isEmpty) return;
    final imageResend = state == 'answered' && _isImageResendDraft(raw);
    if (imageResend &&
        (raw['image_resend_policy'] as Map)['mode'] == 'initial') {
      state = 'resend_requested';
    }
    var respondedAt = DateTime.now().millisecondsSinceEpoch;
    if (attemptId != null) {
      final attempt = (await txn.query('delivery_attempts',
              columns: ['raw_json'],
              where: 'attempt_id=? AND user_id=?',
              whereArgs: [attemptId, customer]))
          .firstOrNull;
      if (attempt != null) {
        final metadata = jsonDecode(attempt['raw_json']! as String) as Map;
        if ((metadata['native_reply_at_ms'] ?? metadata['manual_sent_at_ms'])
            case final num time) {
          respondedAt = time.toInt();
        }
      }
    }
    await txn.rawUpdate(
        '''UPDATE automation_session_messages SET
      response_state=?,answered_task_id=?,answered_attempt_id=?,responded_at_ms=?
      WHERE session_id=? AND user_id=? AND response_state='pending'
        AND message_id IN (${List.filled(covered.length, '?').join(',')}) AND EXISTS(
        SELECT 1 FROM automation_reply_inputs i WHERE i.session_id=automation_session_messages.session_id
          AND i.user_id=automation_session_messages.user_id AND i.message_id=automation_session_messages.message_id
          AND i.owner_id=? AND i.message_revision=automation_session_messages.work_revision)''',
        [
          state,
          owner,
          attemptId,
          respondedAt,
          session,
          customer,
          ...covered,
          owner
        ]);
    if (imageResend) {
      final policy = raw['image_resend_policy'] as Map;
      if (policy['session_id'] != session) return;
      final source = policy['source_message_id'];
      final waits = await txn.query('automation_message_waits',
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [session, customer, source]);
      final stored = waits.isEmpty ? null : _imageExpiry(waits.single);
      if (stored == null || stored['receipt_id'] != policy['receipt_id']) {
        return;
      }
      await txn.update(
          'automation_session_messages',
          {
            'response_state': 'resend_requested',
            'answered_task_id': owner,
            'answered_attempt_id': attemptId,
            'responded_at_ms': respondedAt,
          },
          where:
              "session_id=? AND user_id=? AND message_id=? AND response_state IN ('pending','skipped_image','skipped_media','resend_requested')",
          whereArgs: [session, customer, source]);
      await txn.update(
          'automation_message_waits',
          {
            'content_key': '$_imageExpiryPrefix${jsonEncode({
                  ...stored,
                  'status': 'resend_requested'
                })}',
            'updated_at_ms': respondedAt,
          },
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [session, customer, source]);
    }
  }

  Set<String> _formalInputScope(Map raw, Set<String> scope) {
    if (raw['reply_purpose'] == 'media_status' ||
        isReviewAcknowledgement(raw) ||
        _legacyAutomaticMediaStatus(raw)) {
      return {};
    }
    if (raw['formal_response_message_ids'] case final List ids) {
      return scope.intersection(ids.whereType<String>().toSet());
    }
    return scope;
  }

  bool _legacyAutomaticMediaStatus(Map raw) {
    final ids = (raw['service_message_ids'] as List? ?? const [])
        .whereType<String>()
        .toList();
    return raw['reply_purpose'] == null &&
        raw['media_dependent'] == true &&
        raw['model'].toString().startsWith('gpt-') &&
        ids.isNotEmpty &&
        ids.every((id) => id.startsWith('media-pending:')) &&
        (raw['image_descriptions'] as List? ?? const []).isEmpty &&
        isOnlyMediaProgressNotice(raw['reply']?.toString() ?? '');
  }

  Future<void> _reopenRejectedInputs(
      DatabaseExecutor txn, String customer, String attemptId) async {
    if (_automationSessionId == null) return;
    await txn.update(
        'automation_session_messages',
        {
          'response_state': 'pending',
          'answered_task_id': null,
          'answered_attempt_id': null,
          'responded_at_ms': null,
        },
        where:
            "session_id=? AND user_id=? AND response_state='answered' AND answered_attempt_id=?",
        whereArgs: [_automationSessionId, customer, attemptId]);
  }

  Future<bool> isCurrentSessionTicket(int ticketId) async {
    if (_automationSessionId == null) return true;
    return (await (await database).query('automation_session_tickets',
            columns: ['ticket_id'],
            where: 'session_id=? AND ticket_id=?',
            whereArgs: [_automationSessionId, ticketId]))
        .isNotEmpty;
  }

  Future<void> _registerSessionCapture(
      CapturedConversation capture, Iterable<String> inserted,
      {required bool activateReplies,
      Set<String>? activeIncomingIds,
      Map<String, Set<String>> mediaInputDependencies = const {},
      String? dependencyEvidenceId}) async {
    final session = _automationSessionId;
    if (session == null ||
        !activateReplies ||
        capture.capturedAt.isBefore(_automationSessionStartedAt!)) {
      return;
    }
    final customer = capture.customerExternalId ?? capture.customerName;
    final db = await database;
    final formallyAnswered = await _formallyAnsweredIds(customer);
    final ids = <String>{
      ...inserted,
      ...capture.messages.map((m) => m.stableId),
      for (final message in capture.messages)
        if (message.direction == 'incoming' && message.sentAt != null)
          CustomerMessageTime.incomingId(customer, message.sentAt!),
    };
    await (await history).withCustomerSnapshot(customer, (document) async {
      final rows =
          (document?['messages'] as List? ?? const []).whereType<Map>();
      await db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, session)) return;
        final baselines = await txn.query('automation_session_baselines',
            where: 'session_id=? AND user_id=?',
            whereArgs: [session, customer]);
        final known = <String>{
          if (baselines.isNotEmpty)
            ...(jsonDecode(baselines.single['known_ids_json']! as String)
                    as List)
                .whereType<String>(),
        };
        for (final id in ids) {
          final m = rows
              .where((m) =>
                  m['id'] == id ||
                  (m['observed_ids'] as List? ?? const []).contains(id))
              .firstOrNull;
          if (m == null ||
              m['direction'] != 'incoming' ||
              known.contains(id) ||
              known.contains(m['id']) ||
              (m['observed_ids'] as List? ?? const []).any(known.contains)) {
            continue;
          }
          if (m['direction'] == 'incoming' &&
              activeIncomingIds != null &&
              !activeIncomingIds.contains(id) &&
              !(m['observed_ids'] as List? ?? const [])
                  .any(activeIncomingIds.contains)) {
            continue;
          }
          if (isMediaWorkMessage(m) &&
              !await _mediaAdmissionMatches(txn, session, customer, m)) {
            continue;
          }
          final previous = (await txn.query('automation_session_messages',
                  where: 'session_id=? AND user_id=? AND message_id=?',
                  whereArgs: [session, customer, m['id']]))
              .firstOrNull;
          if (previous == null &&
              (ConversationFileStore.incomingTimeKey(customer, m) == null ||
                  !_senderTimeInCurrentSession(
                      DateTime.tryParse(m['sent_at']?.toString() ?? '')))) {
            continue;
          }
          if (previous == null &&
              ConversationFileStore.messageAliases(m)
                  .intersection(formallyAnswered)
                  .isNotEmpty) {
            continue;
          }
          final version = _materialWorkVersion(m, previous);
          if (previous == null) {
            await _newInputResetsGenerationBackoff(txn, customer);
          }
          if (id != m['id']) {
            await txn.rawInsert(
                '''INSERT OR IGNORE INTO automation_message_evidence
            (session_id,user_id,message_id,evidence_key)
            SELECT session_id,user_id,?,evidence_key FROM automation_message_evidence
            WHERE session_id=? AND user_id=? AND message_id=?
              AND evidence_key LIKE '{"type":"media_input_dependency"%' ''',
                [m['id'], session, customer, id]);
          }
          await txn.rawInsert(
              '''INSERT INTO automation_session_messages(
        session_id,user_id,message_id,activated_at_ms,work_revision,input_kind,input_key)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,user_id,message_id) DO UPDATE SET
        response_state=response_state,
        work_revision=excluded.work_revision,input_kind=excluded.input_kind,input_key=excluded.input_key''',
              [
                session,
                customer,
                m['id'],
                capture.capturedAt.millisecondsSinceEpoch,
                version.revision,
                isMediaWorkMessage(m) ? 'media' : 'text',
                version.key,
              ]);
          await _retirePreTransferWork(txn, customer);
          for (final receipt in mediaInputDependencies[id] ??
              mediaInputDependencies[m['id']] ??
              const <String>{}) {
            await _insertMediaInputDependency(txn, session, customer,
                textMessageId: m['id']! as String,
                receiptId: receipt,
                evidenceId: dependencyEvidenceId!,
                textInputKey: version.key);
          }
        }
      });
    });
  }

  /// Restore only an original receipt whose ownership survived independently
  /// in the live timeline and original card observation. This repairs a
  /// partial inventory commit without inventing a card or a completed parse.
  Future<bool> _repairMissingMediaInventoryRoots(
      String customer, String session) async {
    final db = await database;
    return (await history).withCustomerSnapshot(customer, (document) async {
      final messages =
          (document?['messages'] as List? ?? const []).whereType<Map>();
      return db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, session)) return false;
        var changed = false;
        final work = await txn.query('automation_session_messages',
            where:
                "session_id=? AND user_id=? AND response_state='pending' AND input_kind='media'",
            whereArgs: [session, customer]);
        for (final row in work) {
          final id = row['message_id']! as String;
          final message = messages
              .where((m) => m['id'] == id && m['direction'] == 'incoming')
              .firstOrNull;
          if (message == null ||
              !isMediaWorkMessage(message) ||
              !(message['live_observed_session_ids'] as List? ?? const [])
                  .contains(session)) {
            continue;
          }
          final receipt = message['media_receipt_id'];
          final evidence = message['capture_evidence_id'];
          final sent = _originalIncomingTime(customer, row);
          if (receipt is! String ||
              evidence is! String ||
              sent == null ||
              !_senderTimeInCurrentSession(sent) ||
              CustomerMessageTime.incomingId(customer, sent) != id) {
            continue;
          }
          final existing = await txn.query('customer_media_items',
              columns: ['item_id'],
              where:
                  'item_id=? OR (customer=? AND admission_session_id=? AND admission_key=?)',
              whereArgs: [receipt, customer, session, id],
              limit: 1);
          if (existing.isNotEmpty) continue;
          final observations = await txn.query('media_card_observations',
              where:
                  'customer=? AND item_id=? AND evidence_id=? AND observed_ms>=? '
                  'AND (canonical_id IS NULL OR canonical_id=?)',
              whereArgs: [
                customer,
                receipt,
                evidence,
                _automationSessionStartedAt!.millisecondsSinceEpoch,
                receipt
              ],
              orderBy: 'observed_ms ASC',
              limit: 1);
          if (observations.isEmpty) continue;
          final observation = observations.single;
          final Object? region;
          try {
            region = jsonDecode(observation['region_json']! as String);
          } on FormatException {
            continue;
          }
          if (region is! List ||
              region.length != 4 ||
              region.any((value) => value is! num || !value.isFinite)) {
            continue;
          }
          final kind = const {'image', 'video', 'unknown'}
                  .contains(observation['classified_kind'])
              ? observation['classified_kind']! as String
              : 'unknown';
          await txn.insert('customer_media_items', {
            'item_id': receipt,
            'customer': customer,
            'sender_ms': sent.millisecondsSinceEpoch,
            'slot': 0,
            'kind': kind,
            'state': kind == 'unknown' ? 'detected' : 'preview',
            'first_seen_ms': observation['observed_ms'],
            'last_seen_ms': observation['observed_ms'],
            'evidence_id': evidence,
            'message_id': id,
            'visual_fingerprint': observation['fingerprint'],
            'media_json': jsonEncode(message['media'] as List? ?? const []),
            'aliases_json': jsonEncode(
                ConversationFileStore.messageAliases(message).toList()),
            'admission_key': id,
            'admission_session_id': session,
            'admitted_at_ms': row['activated_at_ms'],
          });
          changed = true;
        }
        return changed;
      });
    });
  }

  /// Repairs durable, current-run live observations that were saved before
  /// their processing registration. It never resumes a pre-Start document.
  Future<bool> repairSessionPendingWork(String customer) async {
    final owner = _automationSessionId;
    if (owner == null) return ensurePendingForUnanswered(customer);
    await _repairFrozenTextKinds(customer, owner);
    final repairedInventory =
        await _repairMissingMediaInventoryRoots(customer, owner);
    final document = await (await history).read(customer);
    final messages =
        (document?['messages'] as List? ?? const []).whereType<Map>();
    final known = await _knownSessionBaselineIds(customer);
    final formallyAnswered = await _formallyAnsweredIds(customer);
    final db = await database;
    var changed = repairedInventory;
    // File persistence precedes queue commitment. A crash after the proven
    // text was saved must finish that same correction, never revive its old
    // media wait or create a second incoming record.
    for (final message in messages.where(isClarifiedTextMessage)) {
      final proof = message['message_kind_evidence'] as Map;
      if (proof['sessionId'] != owner) continue;
      final work = (await db.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [owner, customer, message['id']]))
          .firstOrNull;
      if (work == null || work['response_state'] != 'pending') continue;
      final receipt = (await db.query('customer_media_items',
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, proof['receiptId']]))
          .firstOrNull;
      final staleWait = await db.query('automation_message_waits',
          where: 'session_id=? AND user_id=? AND message_id=? AND is_media=1',
          whereArgs: [owner, customer, message['id']]);
      final revision =
          (message['service_evidence_revision'] as num? ?? 0).toInt();
      if (work['input_kind'] != 'text' ||
          (work['work_revision']! as num).toInt() < revision ||
          receipt?['kind'] != 'text' ||
          staleWait.isNotEmpty) {
        if (await _finishTextClarification(customer, message,
            expectedSessionId: owner)) {
          changed = true;
        }
      }
    }
    await (await history).withCustomerSnapshot(customer, (fresh) async {
      final latest = (fresh?['messages'] as List? ?? const []).whereType<Map>();
      await db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, owner)) return;
        for (final m in latest) {
          if (m['direction'] != 'incoming' ||
              !(m['live_observed_session_ids'] as List? ?? const [])
                  .contains(owner) ||
              known.contains(m['id']) ||
              (m['observed_ids'] as List? ?? const []).any(known.contains)) {
            continue;
          }
          if (isMediaWorkMessage(m) &&
              !await _mediaAdmissionMatches(txn, owner, customer, m)) {
            continue;
          }
          final old = (await txn.query('automation_session_messages',
                  where: 'session_id=? AND user_id=? AND message_id=?',
                  whereArgs: [owner, customer, m['id']]))
              .firstOrNull;
          if (old == null &&
              (ConversationFileStore.incomingTimeKey(customer, m) == null ||
                  !_senderTimeInCurrentSession(
                      DateTime.tryParse(m['sent_at']?.toString() ?? '')))) {
            continue;
          }
          if (old == null &&
              ConversationFileStore.messageAliases(m)
                  .intersection(formallyAnswered)
                  .isNotEmpty) {
            continue;
          }
          if (old == null) {
            await _newInputResetsGenerationBackoff(txn, customer);
          }
          final version = _materialWorkVersion(m, old);
          final revision = version.revision;
          final inputKind = isMediaWorkMessage(m) ? 'media' : 'text';
          if (old != null && (old['work_revision']! as int) >= revision) {
            if (old['input_kind'] != inputKind ||
                old['input_key'] != version.key) {
              await txn.update('automation_session_messages',
                  {'input_kind': inputKind, 'input_key': version.key},
                  where: 'session_id=? AND user_id=? AND message_id=?',
                  whereArgs: [owner, customer, m['id']]);
            }
            continue;
          }
          if (const {
            'answered',
            'delegated',
            'skipped_image',
            'skipped_media',
            'resend_requested'
          }.contains(old?['response_state'])) {
            await txn.update('automation_session_messages',
                {'work_revision': revision, 'input_key': version.key},
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [owner, customer, m['id']]);
            continue;
          }
          await txn.rawInsert(
              '''INSERT INTO automation_session_messages(session_id,user_id,message_id,activated_at_ms,work_revision,input_kind,input_key)
          VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,user_id,message_id) DO UPDATE SET response_state='pending',
          answered_task_id=NULL,answered_attempt_id=NULL,responded_at_ms=NULL,work_revision=excluded.work_revision,input_kind=excluded.input_kind,input_key=excluded.input_key''',
              [
                owner,
                customer,
                m['id'],
                DateTime.now().millisecondsSinceEpoch,
                revision,
                inputKind,
                version.key,
              ]);
          changed = true;
        }
        await _retirePreTransferWork(txn, customer);
        await _retireInvalidInputDraft(txn, customer);
      });
    });
    if (owner != _automationSessionId) return false;
    await _reconcileCanonicalMessageWork(customer);
    return await ensurePendingForUnanswered(customer) || changed;
  }

  /// Explicit material upgrades are idempotent. A receipt for an older
  /// revision can never complete the newly discovered evidence.
  Future<bool> reopenMessageForNewEvidence(String customer, String messageId,
      {required String evidenceKey}) async {
    if (_automationSessionId == null || evidenceKey.trim().isEmpty) {
      return false;
    }
    final doc = await (await history).read(customer);
    final message = (doc?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['id'] == messageId ||
            (m['observed_ids'] as List? ?? const []).contains(messageId))
        .firstOrNull;
    final canonical = message?['id']?.toString() ?? messageId;
    final owner = _automationSessionId;
    final db = await database;
    final changed = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) return false;
      final work = (await txn.query('automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [owner, customer, canonical]))
          .firstOrNull;
      if (work == null ||
          const {
            'answered',
            'delegated',
            'skipped_image',
            'skipped_media',
            'resend_requested'
          }.contains(work['response_state'])) {
        return false;
      }
      await txn.insert(
          'automation_message_evidence',
          {
            'session_id': owner,
            'user_id': customer,
            'message_id': canonical,
            'evidence_key': evidenceKey
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      if ((await txn.rawQuery('SELECT changes() AS n')).single['n'] != 1) {
        return false;
      }
      final stored = (work['work_revision'] as num).toInt();
      final documentRevision =
          (message?['service_evidence_revision'] as num?)?.toInt() ?? 0;
      final revision =
          documentRevision > stored ? documentRevision : stored + 1;
      await txn.update(
          'automation_session_messages',
          {
            'response_state': 'pending',
            'work_revision': revision,
            'evidence_key': evidenceKey,
            'answered_task_id': null,
            'answered_attempt_id': null,
            'responded_at_ms': null
          },
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [owner, customer, canonical]);
      await _retireInvalidInputDraft(txn, customer);
      return true;
    });
    if (changed && owner == _automationSessionId) {
      await ensurePendingForUnanswered(customer);
    }
    return changed;
  }

  Future<bool> _draftInputsCurrent(
      DatabaseExecutor txn, String customer, Map<String, Object?> draft) async {
    if (_hasCompletedApiProof(draft)) {
      return _completedDraftCurrent(txn, customer, draft);
    }
    if (_automationSessionId == null) return true;
    final task = draft['task_id']?.toString();
    if (task == null) return false;
    final all = await _replyInputIds(txn, customer, task);
    final current =
        await _replyInputIds(txn, customer, task, currentRevisionOnly: true);
    if (all.isEmpty || all.length != current.length) return false;
    final raw = jsonDecode(draft['raw_json']! as String) as Map;
    if (raw.containsKey('image_resend_policy')) {
      return _imageResendInputsCurrent(txn, customer, draft, raw);
    }
    final inputs = await txn.query('automation_reply_inputs',
        where: 'session_id=? AND user_id=? AND owner_id=?',
        whereArgs: [_automationSessionId, customer, task]);
    return _frozenMaterialCurrent(inputs, await (await history).read(customer));
  }

  Future<bool> _draftMediaInputsReady(
      DatabaseExecutor executor, String customer, Map draft) async {
    if (_hasCompletedApiProof(draft)) {
      return _completedDraftCurrent(executor, customer, draft);
    }
    final session = _automationSessionId;
    final raw = jsonDecode(draft['raw_json']! as String) as Map;
    if (raw.containsKey('image_resend_policy')) {
      return _imageResendInputsCurrent(executor, customer, draft, raw);
    }
    if (session == null || _mediaDependencyKeys(raw) == null) return true;
    final inputs = await executor.rawQuery('''SELECT i.*,m.input_kind
      FROM automation_reply_inputs i JOIN automation_session_messages m
      ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
      WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
        [session, customer, draft['task_id']]);
    if (inputs.isEmpty) return false;
    final media = <Map>[];
    for (final input in inputs) {
      if (input['input_kind'] != 'media') continue;
      final message =
          jsonDecode(input['message_json']?.toString() ?? '{}') as Map;
      media.add({...message, 'message_id': input['message_id']});
    }
    if (media.isEmpty) return true;
    final ready = await CustomerMediaInventory(this)
        .analysisReadyMessageIds(customer, executor: executor);
    return media.every((message) => <Object?>{
          message['message_id'],
          message['id'],
          message['media_receipt_id'],
          ...(message['observed_ids'] as List? ?? const []),
          ...(message['media_receipt_aliases'] as List? ?? const []),
        }.any(ready.contains));
  }

  Future<bool> _retireInvalidInputDraft(
      DatabaseExecutor txn, String customer) async {
    if (_automationSessionId == null) return false;
    final draft = (await txn.query('generated_drafts',
            where: "user_id=? AND delivery_state IN ('ready','retry')",
            whereArgs: [customer]))
        .firstOrNull;
    if (draft == null ||
        await _draftInputsCurrent(txn, customer, draft) &&
            await _draftMediaInputsReady(txn, customer, draft)) {
      return false;
    }
    final attempt = draft['attempt_id'];
    if (attempt != null) {
      final journal = (await txn.query('delivery_attempts',
              where: 'attempt_id=?', whereArgs: [attempt]))
          .firstOrNull;
      if (journal == null ||
          !const {'not_sent', 'rejected'}.contains(journal['state'])) {
        return false;
      }
    }
    await txn.delete('generated_drafts',
        where: 'user_id=? AND task_id=?',
        whereArgs: [customer, draft['task_id']]);
    return true;
  }

  /// Positive proof only: inactive, missing, and human-delegated work do not
  /// imply that the customer's actual question received a formal reply.
  Future<bool> isMessageFormallyAnswered(
      String customer, String messageId) async {
    if (_automationSessionId == null) {
      final doc = await (await history).read(customer);
      final messages = (doc?['messages'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final at = messages.indexWhere((m) =>
          m['id'] == messageId ||
          (m['observed_ids'] as List? ?? const []).contains(messageId));
      return at >= 0 &&
          at <= _answeredIndex(messages, await answeredMessageId(customer));
    }
    final doc = await (await history).read(customer);
    final message = (doc?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['id'] == messageId ||
            (m['observed_ids'] as List? ?? const []).contains(messageId))
        .firstOrNull;
    final ids = <String>{
      messageId,
      ...(message?['observed_ids'] as List? ?? const []).whereType<String>(),
      if (message?['id'] is String) message!['id']! as String
    };
    final rows = await (await database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [_automationSessionId, customer]);
    final matching = rows.where((row) => ids.contains(row['message_id']));
    return matching.any((row) => row['response_state'] == 'answered') &&
        !matching.any((row) => row['response_state'] == 'pending');
  }

  Future<Directory> get storageRoot async =>
      _storageRoot ?? await _resolveDefaultStorageRoot();

  Future<ConversationFileStore> get history async {
    while (true) {
      if (_history case final value?) return value;
      final day = currentBusinessDayKey;
      final root = await storageRoot;
      if (day != currentBusinessDayKey) continue;
      if (_history case final existing?) return existing;
      final value = day == null
          ? ConversationFileStore(root)
          : ConversationFileStore.forDay(root,
              businessDay: day, clock: _businessClock);
      _history = value;
      return value;
    }
  }

  Future<Database> get database => _database != null
      ? Future.value(_database!)
      : (_openingDatabase ??=
          _openDatabase().catchError((Object error, StackTrace stack) {
          _openingDatabase = null;
          Error.throwWithStackTrace(error, stack);
        }));

  /// Recheck before Start as well as during the initial open. This changes no
  /// session, message, queue, draft, or receipt; only the safe v35 schema repair
  /// is permitted, and every incompatibility is returned to the caller.
  Future<void> ensureAutomationSchemaReady() async {
    await _ensureCurrentBusinessSchema(await database);
  }

  Future<Database> _openDatabase() async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(
      p.join((await storageRoot).path, 'jd_automation.sqlite3'),
      options: OpenDatabaseOptions(
        version: databaseSchemaVersion,
        onCreate: _create,
        onUpgrade: _upgrade,
        onOpen: _ensureCurrentBusinessSchema,
      ),
    );
    // Preserve uncertainty across restart. Only operations known not to have
    // clicked may enter ordinary retry; orphan owners become reconciliation work.
    await database.rawUpdate("""UPDATE generated_drafts SET
      delivery_state='delivery_unknown', retry_at_ms=0,
      last_error=COALESCE(last_error,'send_unconfirmed: recovered interrupted attempt')
      WHERE delivery_state IN ('sending','committing','delivery_unknown','retry_existing')""");
    await database.rawUpdate(
        """UPDATE generated_drafts SET delivery_state='retry',retry_at_ms=0
      WHERE delivery_state='failed_offline'""");
    await database.rawUpdate(
        """UPDATE sla_fallbacks SET state='reconciling',updated_at_ms=?
      WHERE state IN ('sending','reserved','delivery_unknown')""",
        [DateTime.now().millisecondsSinceEpoch]);
    await database.update('pending_customers', {'generation_token': null});
    await database.update('delivery_attempts', {'state': 'recovered_waiting'},
        where: "state='sending'");
    if (!_legacyDraftsPurged) {
      // A ledger-owned attempt record is durable audit/reconciliation
      // evidence, not a legacy unsent AI draft. Use this already-open handle;
      // calling this.database here would wait recursively on the same open.
      final attempts = await database.query('delivery_attempts', columns: [
        'attempt_id',
        'task_id',
        'user_id',
        'batch_end_message_id',
        'reply',
      ]);
      await (await history).purgeLegacyUnsentDrafts(ownedDeliveryAttempts: {
        for (final attempt in attempts)
          attempt['attempt_id']! as String: attempt,
      });
      _legacyDraftsPurged = true;
    }
    if (!_reviewControlsSynced) {
      // `human_review_open` was used by older builds to pause AI as soon as a
      // ticket was created. Open tickets are informational: AI remains active
      // until an operator or the explicit transfer flow starts contacting.
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.update(
          'conversation_control',
          {
            'state': 'ai_active',
            'resume_after_message_id': null,
            'updated_at_ms': now,
          },
          where: "state = 'human_review_open'");
      _reviewControlsSynced = true;
    }
    _database = database;
    return database;
  }

  /// The schema must be usable before recovery writes or Start are allowed.
  /// Version callbacks alone cannot repair a same-version interrupted install.
  /// Only the known nullable v35 column is safe to add here; any other missing
  /// business structure is an explicit startup failure, never a capture retry.
  Future<void> _ensureCurrentBusinessSchema(Database db) async {
    const required = <String, Set<String>>{
      'automation_sessions': {'session_id', 'started_at_ms'},
      'automation_session_messages': {
        'session_id',
        'user_id',
        'message_id',
        'activated_at_ms',
        'response_state',
        'answered_task_id',
        'answered_attempt_id',
        'responded_at_ms',
        'work_revision',
        'input_kind',
        'evidence_key',
        'input_key',
      },
      'automation_reply_inputs': {
        'session_id',
        'user_id',
        'owner_id',
        'message_id',
        'message_revision',
        'message_json',
      },
      'automation_message_waits': {
        'session_id',
        'user_id',
        'message_id',
        'is_media',
        'content_key',
        'message_revision',
        'task_id',
        'updated_at_ms',
      },
      'automation_message_evidence': {
        'session_id',
        'user_id',
        'message_id',
        'evidence_key',
      },
      'pending_customers': {
        'id',
        'user_id',
        'display_name',
        'stable_key',
        'newest_message_id',
        'enqueued_at_ms',
        'updated_at_ms',
        'generation_token',
        'generation_attempts',
        'generation_retry_at_ms',
        'generation_last_error',
      },
      'generated_drafts': {
        'user_id',
        'pending_id',
        'reply',
        'model',
        'raw_json',
        'created_at_ms',
        'delivery_state',
        'delivery_attempts',
        'retry_at_ms',
        'last_error',
        'batch_end_message_id',
        'task_id',
        'attempt_id',
        'queued_at_ms',
      },
      'delivery_attempts': {
        'attempt_id',
        'task_id',
        'user_id',
        'pending_id',
        'reply',
        'raw_json',
        'batch_end_message_id',
        'state',
        'created_at_ms',
        'updated_at_ms',
        'error',
        'prior_cursor',
        'receipt_seen_ms',
        'last_checked_ms',
        'kind',
        'input_boundary_id',
      },
    };
    await db.transaction((txn) async {
      final messages =
          await txn.rawQuery('PRAGMA table_info(automation_session_messages)');
      if (messages.isEmpty) {
        throw StateError('database_schema_incompatible: missing table '
            'automation_session_messages; startup cancelled');
      }
      if (!messages.any((row) => row['name'] == 'input_key')) {
        await txn.execute('ALTER TABLE automation_session_messages '
            'ADD COLUMN input_key TEXT');
      }
      for (final table in required.entries) {
        final columns = await txn.rawQuery('PRAGMA table_info(${table.key})');
        final names = columns.map((row) => row['name']).toSet();
        final missing = table.value.difference(names);
        if (columns.isEmpty || missing.isNotEmpty) {
          final detail = columns.isEmpty
              ? 'missing table ${table.key}'
              : '${table.key} missing columns ${(missing.toList()..sort()).join(', ')}';
          throw StateError('database_schema_incompatible: $detail; '
              'startup cancelled without changing customer work');
        }
      }
      final keys = messages.where((row) => (row['pk'] as int) > 0).toList()
        ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
      if (jsonEncode(keys.map((row) => row['name']).toList()) !=
          jsonEncode(['session_id', 'user_id', 'message_id'])) {
        throw StateError('database_schema_incompatible: '
            'automation_session_messages identity key is invalid; startup cancelled');
      }
    });
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_sessions(
      session_id TEXT PRIMARY KEY,started_at_ms INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_work_archive(
      id INTEGER PRIMARY KEY,session_id TEXT NOT NULL,table_name TEXT NOT NULL,
      record_key TEXT NOT NULL,row_json TEXT NOT NULL,archived_at_ms INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_session_baselines(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,known_ids_json TEXT NOT NULL,
      PRIMARY KEY(session_id,user_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS capture_discovery_state(
      session_id TEXT NOT NULL,customer TEXT NOT NULL,evidence_id TEXT NOT NULL,
      kind TEXT NOT NULL,ready INTEGER NOT NULL DEFAULT 0,payload TEXT NOT NULL,
      PRIMARY KEY(session_id,customer))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_session_messages(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,message_id TEXT NOT NULL,activated_at_ms INTEGER NOT NULL,
      PRIMARY KEY(session_id,user_id,message_id))''');
    for (final column in [
      "response_state TEXT NOT NULL DEFAULT 'pending'",
      'answered_task_id TEXT',
      'answered_attempt_id TEXT',
      'responded_at_ms INTEGER',
      'work_revision INTEGER NOT NULL DEFAULT 0',
      "input_kind TEXT NOT NULL DEFAULT 'unknown'",
      'evidence_key TEXT',
      'input_key TEXT'
    ]) {
      await _addColumnIfMissing(db, 'automation_session_messages', column);
    }
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_reply_inputs(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,owner_id TEXT NOT NULL,message_id TEXT NOT NULL,
      message_revision INTEGER NOT NULL DEFAULT 0,message_json TEXT,
      PRIMARY KEY(session_id,user_id,owner_id,message_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_message_evidence(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,message_id TEXT NOT NULL,evidence_key TEXT NOT NULL,
      PRIMARY KEY(session_id,user_id,message_id,evidence_key))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_message_waits(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,message_id TEXT NOT NULL,
      is_media INTEGER NOT NULL,content_key TEXT NOT NULL,message_revision INTEGER NOT NULL,
      task_id TEXT,updated_at_ms INTEGER NOT NULL,
      PRIMARY KEY(session_id,user_id,message_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_archived_attempts(
      attempt_id TEXT PRIMARY KEY,archived_session_id TEXT NOT NULL,state_at_archive TEXT,
      latest_receipt_json TEXT)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS automation_session_tickets(
      session_id TEXT NOT NULL,ticket_id INTEGER NOT NULL,PRIMARY KEY(session_id,ticket_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS handoff_ai_fallbacks(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,request_message_id TEXT NOT NULL,
      ticket_id INTEGER NOT NULL,reason TEXT NOT NULL,unknown_click INTEGER NOT NULL DEFAULT 0,
      created_at_ms INTEGER NOT NULL,yield_count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(session_id,user_id,request_message_id))''');
    await _addColumnIfMissing(
        db, 'handoff_ai_fallbacks', 'yield_count INTEGER NOT NULL DEFAULT 0');
    await db.execute("""CREATE TABLE IF NOT EXISTS platform_response_cycles(
      user_id TEXT PRIMARY KEY, cycle_id TEXT NOT NULL, started_at_ms INTEGER NOT NULL,
      state TEXT NOT NULL, confirmed_at_ms INTEGER, observed_at_ms INTEGER NOT NULL, identity_verified INTEGER NOT NULL DEFAULT 0, confirmed_attempt_id TEXT,
      response_started_ms INTEGER,response_boundary_id TEXT,resume_pending INTEGER NOT NULL DEFAULT 0,resume_since_ms INTEGER)""");
    await _createPendingQueue(db);
    await _createHumanReview(db);
    await _createGeneratedDrafts(db);
    await _createTransferWelcomes(db);
    await _createSlaFallbacks(db);
    await _createAnsweredCursors(db);
    await _createHumanTransferRequests(db);
    await _createChatTransferLogs(db);
    await _createUnavailableConversations(db);
    await _createCaptureEvidence(db);
    await _createSlaDeliveryReceipts(db);
    await _createDeliveryLifecycle(db);
  }

  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 35) {
      await _addColumnIfMissing(
          db, 'automation_session_messages', 'input_key TEXT');
    }
    if (oldVersion < 19) await _createCaptureEvidence(db);
    if (oldVersion < 18) await _createSlaFallbacks(db);
    if (oldVersion < 17) await _createCaptureEvidence(db);
    if (oldVersion < 15) await _createUnavailableConversations(db);
    if (oldVersion < 3) {
      // Preserve legacy tables but stop writing to them.
      await _createPendingQueue(db);
    }
    if (oldVersion < 4) await _createHumanReview(db);
    if (oldVersion < 5) await _createGeneratedDrafts(db);
    if (oldVersion < 6) await _createTransferWelcomes(db);
    if (oldVersion < 7) {
      await _createSlaFallbacks(db);
      await _addColumnIfMissing(db, 'generated_drafts',
          "delivery_state TEXT NOT NULL DEFAULT 'ready'");
      await _addColumnIfMissing(db, 'generated_drafts',
          'delivery_attempts INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(db, 'generated_drafts', 'retry_at_ms INTEGER');
      await _addColumnIfMissing(db, 'generated_drafts', 'last_error TEXT');
      // Protect customers who were already waiting when the app upgraded.
      // Their original queue time is the safest available SLA anchor.
      await db.rawInsert('''INSERT OR IGNORE INTO sla_fallbacks(
        user_id,message_id,due_at_ms,state,sent_at_ms,updated_at_ms)
        SELECT user_id,newest_message_id,enqueued_at_ms + ?,
          'pending',NULL,updated_at_ms FROM pending_customers''',
          [holdingDelay.inMilliseconds]);
    }
    if (oldVersion < 8) {
      await _createAnsweredCursors(db);
      await _addColumnIfMissing(
          db, 'generated_drafts', 'batch_end_message_id TEXT');
    }
    if (oldVersion == 9) {
      // Version 9 stored a 35-second deadline. Restore pending work to the
      // 20-second JD response window while preserving the original anchor.
      await db.rawUpdate('''UPDATE sla_fallbacks
        SET due_at_ms=due_at_ms-15000
        WHERE state='pending' ''');
    }
    if (oldVersion < 11) await _createHumanTransferRequests(db);
    if (oldVersion < 12) await _createChatTransferLogs(db);
    if (oldVersion < 22) await _createDeliveryLifecycle(db);
    if (oldVersion < 21) await _createUnavailableConversations(db);
    if (oldVersion < 20) await _createSlaDeliveryReceipts(db);
    if (oldVersion < 13) {
      await _addColumnIfMissing(
          db, 'human_review_tickets', 'request_message_id TEXT');
      await _addColumnIfMissing(
          db, 'chat_transfer_logs', 'request_message_id TEXT');
    }
    if (oldVersion < 27) {
      for (final column in [
        'preclick_retry_count INTEGER NOT NULL DEFAULT 0',
        'preclick_retry_at_ms INTEGER NOT NULL DEFAULT 0',
        'acknowledged INTEGER NOT NULL DEFAULT 0'
      ]) {
        await _addColumnIfMissing(db, 'chat_transfer_logs', column);
      }
    }
    if (oldVersion < 28) {
      for (final column in [
        'response_started_ms INTEGER',
        'response_boundary_id TEXT',
        'resume_pending INTEGER NOT NULL DEFAULT 0',
        'resume_since_ms INTEGER'
      ]) {
        await _addColumnIfMissing(db, 'platform_response_cycles', column);
      }
      await ensureChatTransferRecoveryColumns(db);
      await db.execute('DROP INDEX IF EXISTS delivery_attempts_reconciliation');
    }
    await _create(db, newVersion);
  }

  Future<void> _createSlaDeliveryReceipts(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS sla_delivery_receipts(
      user_id TEXT NOT NULL, batch_start_message_id TEXT NOT NULL,
      message_id TEXT NOT NULL, sent_at_ms INTEGER NOT NULL,
      PRIMARY KEY(user_id,batch_start_message_id))''');
    // Upgrade without forgetting a holding reply already confirmed by v19.
    await db.rawInsert('''INSERT OR IGNORE INTO sla_delivery_receipts
      SELECT user_id,COALESCE(batch_start_message_id,message_id),message_id,sent_at_ms
      FROM sla_fallbacks WHERE sent_at_ms IS NOT NULL''');
  }

  Future<void> _createDeliveryLifecycle(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS customer_storage_faults(
      user_id TEXT PRIMARY KEY,error TEXT NOT NULL,since_ms INTEGER NOT NULL,last_seen_ms INTEGER NOT NULL)''');
    await _addColumnIfMissing(db, 'pending_customers', 'generation_token TEXT');
    for (final column in [
      'generation_attempts INTEGER NOT NULL DEFAULT 0',
      'generation_retry_at_ms INTEGER NOT NULL DEFAULT 0',
      'generation_last_error TEXT'
    ]) {
      await _addColumnIfMissing(db, 'pending_customers', column);
    }
    for (final column in [
      'task_id TEXT',
      'attempt_id TEXT',
      'queued_at_ms INTEGER'
    ]) {
      await _addColumnIfMissing(db, 'generated_drafts', column);
    }
    await db.execute('''CREATE TABLE IF NOT EXISTS delivery_attempts(
      attempt_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, user_id TEXT NOT NULL,
      pending_id INTEGER NOT NULL, reply TEXT NOT NULL, raw_json TEXT NOT NULL,
      batch_end_message_id TEXT, state TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL, error TEXT, prior_cursor TEXT, receipt_seen_ms INTEGER NOT NULL DEFAULT 0, last_checked_ms INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'reply')''');
    await _addColumnIfMissing(
        db, 'delivery_attempts', 'last_checked_ms INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'delivery_attempts', 'input_boundary_id TEXT');
    await _addColumnIfMissing(
        db, 'sla_fallbacks', 'retry_at_ms INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'sla_fallbacks', 'attempt_id TEXT');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS delivery_attempts_customer ON delivery_attempts(user_id,updated_at_ms)');
    await db.execute(
        "CREATE INDEX IF NOT EXISTS delivery_attempts_reconciliation ON delivery_attempts(last_checked_ms,created_at_ms DESC) WHERE state IN ('sending','recovered_waiting','unknown','submitted','rejected_waiting','superseded_unknown','superseded_submitted')");
  }

  String _taskId() => '${DateTime.now().microsecondsSinceEpoch}-'
      '${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  static const _completedApiProof = '_local_hosted_completed_api';
  static const _completedApiSource = '_local_hosted_completed_source';

  bool _hasCompletedApiProof(Map draft) {
    final encoded = draft['raw_json'];
    if (encoded is! String) return false;
    final raw = jsonDecode(encoded) as Map;
    return raw[_completedApiProof] == true && raw[_completedApiSource] is Map;
  }

  Future<List<Map<String, Object?>>> _completedSourceWork(
      DatabaseExecutor txn, String customer, Map source) async {
    final session = _automationSessionId;
    await _retirePreTransferWork(txn, customer);
    final id = source['id'];
    final revisions = source['reply_work_revisions'];
    final key = source['reply_material_input_key'];
    final kind = source['reply_input_kind'];
    if (session == null ||
        !await _captureSessionMatches(txn, session) ||
        id is! String ||
        source['direction'] != 'incoming' ||
        source['reply_api_customer'] != customer ||
        source['reply_api_session_id'] != session ||
        revisions is! Map ||
        revisions.isEmpty ||
        key is! String ||
        ConversationFileStore.materialInputKey(source) != key ||
        (kind != 'text' && kind != 'media')) {
      return [];
    }
    final aliases = {
      id,
      ...(source['observed_ids'] as List? ?? const []).whereType<String>()
    };
    if (!revisions.keys.every(aliases.contains)) return [];
    final ids = revisions.keys.toList();
    if ((await _uncertainDeliveryHeldIds(txn, customer))
        .intersection(ids.cast<String>().toSet())
        .isNotEmpty) {
      return [];
    }
    final rows = await txn.query('automation_session_messages',
        where:
            'session_id=? AND user_id=? AND message_id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: [session, customer, ...ids]);
    if (rows.length != ids.length ||
        rows.any((row) =>
            row['response_state'] != 'pending' ||
            row['work_revision'] != revisions[row['message_id']] ||
            row['input_key'] != key ||
            row['input_kind'] != kind)) {
      return [];
    }
    return rows;
  }

  Future<bool> _completedDraftCurrent(
      DatabaseExecutor txn, String customer, Map draft) async {
    if (!_hasCompletedApiProof(draft)) return false;
    final raw = jsonDecode(draft['raw_json']! as String) as Map;
    final source = raw[_completedApiSource] as Map;
    final rows = await _completedSourceWork(txn, customer, source);
    if (rows.isEmpty || raw['service_session_id'] != _automationSessionId) {
      return false;
    }
    final ids = rows.map((r) => r['message_id']).toSet();
    final scope = (raw['service_message_ids'] as List? ?? const []).toSet();
    if (ids.length != scope.length || !ids.containsAll(scope)) return false;
    final inputs = await txn.query('automation_reply_inputs',
        where: 'session_id=? AND user_id=? AND owner_id=?',
        whereArgs: [_automationSessionId, customer, draft['task_id']]);
    if (inputs.length != ids.length ||
        inputs.any((i) =>
            !ids.contains(i['message_id']) ||
            i['message_revision'] !=
                (source['reply_work_revisions'] as Map)[i['message_id']])) {
      return false;
    }
    final blocked = await txn.rawQuery(
        '''SELECT user_id FROM unavailable_conversations WHERE user_id=?
      UNION SELECT user_id FROM customer_storage_faults WHERE user_id=?
      UNION SELECT user_id FROM conversation_control WHERE user_id=?
        AND (state='human_contacting' OR state LIKE 'handoff_%')''',
        [customer, customer, customer]);
    return blocked.isEmpty;
  }

  Future<GenerationSnapshot?> beginCompletedApiDelivery(
      {required String customer,
      required int pendingId,
      required Map<String, dynamic> source,
      String? expectedSessionId}) async {
    if (expectedSessionId != null &&
        expectedSessionId != _automationSessionId) {
      return null;
    }
    final db = await database;
    return db.transaction((txn) async {
      final work = await _completedSourceWork(txn, customer, source);
      if (work.isEmpty) return null;
      final pending = await txn.query('pending_customers',
          where: 'id=? AND user_id=? AND generation_token IS NULL',
          whereArgs: [pendingId, customer]);
      final busy = await txn
          .query('generated_drafts', where: 'user_id=?', whereArgs: [customer]);
      final blocked = await txn.rawQuery(
          '''SELECT user_id FROM unavailable_conversations WHERE user_id=?
        UNION SELECT user_id FROM customer_storage_faults WHERE user_id=?
        UNION SELECT user_id FROM conversation_control WHERE user_id=?
          AND (state='human_contacting' OR state LIKE 'handoff_%')''',
          [customer, customer, customer]);
      if (pending.isEmpty || busy.isNotEmpty || blocked.isNotEmpty) return null;
      final task = _taskId();
      final revisions = (source['reply_work_revisions'] as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toInt()));
      final ids = revisions.keys.toSet();
      final scoped = <String, dynamic>{
        ...source,
        'observed_ids': ids.where((id) => id != source['id']).toList()
      };
      await _bindReplyInputs(txn, customer, task, ids,
          revisions: revisions,
          messages: {for (final id in ids) id: scoped},
          responseWindow:
              await _snapshotReplyResponseWindow(txn, customer, scope: ids));
      await txn.update('pending_customers', {'generation_token': task},
          where: 'id=? AND user_id=?', whereArgs: [pendingId, customer]);
      return GenerationSnapshot(task, source['id']! as String);
    });
  }

  Future<AutomaticDraftSaveResult> saveCompletedApiDraft(
      {required int pendingId,
      required String customer,
      required AiDraft draft,
      required Map<String, dynamic> source,
      required String generationToken,
      bool deliverable = true}) async {
    final db = await database;
    final normalized = normalizeReplyProgress(draft);
    return db.transaction((txn) async {
      const stale = AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      final work = await _completedSourceWork(txn, customer, source);
      if (work.isEmpty) return stale;
      final pending = (await txn.query('pending_customers',
              where: 'id=? AND user_id=? AND generation_token=?',
              whereArgs: [pendingId, customer, generationToken]))
          .firstOrNull;
      if (pending == null ||
          (await txn.query('generated_drafts',
                  where: 'user_id=?', whereArgs: [customer]))
              .isNotEmpty) {
        return stale;
      }
      final inputs = await txn.query('automation_reply_inputs',
          where: 'session_id=? AND user_id=? AND owner_id=?',
          whereArgs: [_automationSessionId, customer, generationToken]);
      final scope = work.map((r) => r['message_id']! as String).toSet();
      if (inputs.length != scope.length ||
          inputs.any((i) =>
              !scope.contains(i['message_id']) ||
              i['message_revision'] !=
                  (source['reply_work_revisions'] as Map)[i['message_id']] ||
              ConversationFileStore.materialInputKey(
                      jsonDecode(i['message_json']! as String) as Map) !=
                  source['reply_material_input_key'])) {
        return stale;
      }
      final raw = jsonDecode(normalized.rawJson) as Map<String, dynamic>;
      var purpose = replyPurpose(normalized);
      if (isReviewAcknowledgement(raw) ||
          isOnlyReplyProgressNotice(normalized.reply)) {
        purpose = ReplyPurpose.reviewStatus;
      }
      if (isOnlyMediaProgressNotice(normalized.reply)) {
        purpose = ReplyPurpose.mediaStatus;
      }
      final formal = purpose != ReplyPurpose.reviewStatus &&
          purpose != ReplyPurpose.mediaStatus &&
          !(purpose == ReplyPurpose.receipt &&
              source['reply_input_kind'] == 'media') &&
          (!ResponseTimingPolicy.isSocialAcknowledgement(normalized.reply) ||
              ResponseTimingPolicy.isSocialAcknowledgement(
                  source['body']?.toString() ?? ''));
      raw.addAll({
        _completedApiProof: true,
        _completedApiSource: source,
        'service_session_id': _automationSessionId,
        'service_message_ids': scope.toList(),
        'service_message_revisions': source['reply_work_revisions'],
        'service_response_window': _responseWindowFromInputs(inputs, customer),
        'formal_response_message_ids': formal ? scope.toList() : <String>[],
        'reply_media_dependency_keys': <String, String>{},
        'automatic_progress_classified': true,
        'reply_purpose': switch (purpose) {
          ReplyPurpose.substantive => 'substantive',
          ReplyPurpose.receipt => 'receipt',
          ReplyPurpose.mediaStatus => 'media_status',
          ReplyPurpose.reviewStatus => 'review_status',
        },
      });
      final candidate = <String, Object?>{
        'raw_json': jsonEncode(raw),
        'task_id': generationToken
      };
      if (!await _completedDraftCurrent(txn, customer, candidate)) return stale;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (deliverable && !formal) {
        return _recordAutomaticReplyRepair(
            txn, customer, generationToken, scope, raw, normalized, now);
      }
      await txn.insert('generated_drafts', {
        'user_id': customer,
        'pending_id': pendingId,
        'reply': normalized.reply,
        'model': normalized.model,
        'raw_json': jsonEncode(raw),
        'created_at_ms': now,
        'delivery_state': deliverable ? 'ready' : 'transfer_only',
        'delivery_attempts': 0,
        'retry_at_ms': null,
        'last_error': null,
        'batch_end_message_id': source['id'],
        'task_id': generationToken,
        'queued_at_ms': pending['enqueued_at_ms'],
      });
      await _clearAutomaticReplyRepairForScope(txn, customer, scope);
      return AutomaticDraftSaveResult(deliverable
          ? AutomaticDraftSaveOutcome.ready
          : AutomaticDraftSaveOutcome.transferOnly);
    });
  }

  Future<bool?> isCompletedApiDraftReadyForSend(
      {required String userId, required String reply, String? taskId}) async {
    final db = await database;
    final draft = (await db.query('generated_drafts',
            where:
                "user_id=? AND reply=? AND delivery_state IN ('ready','retry') ${taskId == null ? '' : 'AND task_id=?'}",
            whereArgs: [userId, reply, if (taskId != null) taskId]))
        .firstOrNull;
    if (draft == null) return false;
    if (!_hasCompletedApiProof(draft)) return null;
    return _completedDraftCurrent(db, userId, draft);
  }

  /// Invoke once for a newly completed API result. Other completed messages
  /// can now be collected without inheriting an unrelated job's backoff.
  Future<void> wakeHostedGenerationResult(String customer) async =>
      _newInputResetsGenerationBackoff(await database, customer);

  /// Ready logical messages may be submitted independently of another API job
  /// or this customer's native delivery lease. This does not answer any work.
  Future<Set<String>> eligibleSingleMessageIds(String customer) async =>
      (await _readySingleApiInputs(customer))
          .map((m) => m['id']! as String)
          .toSet();

  Future<Map<String, dynamic>?> freezeReadyApiMessage(
          String customer, String messageId,
          {String? expectedSessionId}) async =>
      (await _readySingleApiInputs(customer,
              messageId: messageId,
              expectedSessionId: expectedSessionId,
              freeze: true))
          .firstOrNull;

  Future<List<Map<String, dynamic>>> _readySingleApiInputs(String customer,
      {String? messageId,
      String? expectedSessionId,
      bool freeze = false}) async {
    final session = expectedSessionId ?? _automationSessionId;
    if (session == null || session != _automationSessionId) return [];
    await repairSessionPendingWork(customer);
    final db = await database;
    return (await history).withCustomerSnapshot(customer, (document) async {
      if (document == null || session != _automationSessionId) return [];
      final observed = await processingMessages(customer,
          document: Map<String, dynamic>.from(document));
      return db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, session)) {
          return <Map<String, dynamic>>[];
        }
        if ((await txn.query('conversation_control',
                where: "user_id=? AND state LIKE 'handoff_%'",
                whereArgs: [customer]))
            .isNotEmpty) {
          return <Map<String, dynamic>>[];
        }
        final dependencies =
            await _generationDependencyScope(txn, session, customer, document);
        final eligible = await _eligibleGenerationInputs(
            txn, session, customer, document,
            knownDependencies: dependencies);
        final work = await txn.query('automation_session_messages',
            where: "session_id=? AND user_id=? AND response_state='pending'",
            whereArgs: [session, customer],
            orderBy: 'rowid ASC');
        final result = <Map<String, dynamic>>[];
        final emitted = <String>{};
        for (final row in work) {
          final id = row['message_id']! as String;
          if (!eligible.contains(id)) continue;
          final message = observed
              .where((m) =>
                  m['direction'] == 'incoming' &&
                  _matchesWorkId(m, {id}) &&
                  (messageId == null || _matchesWorkId(m, {messageId})))
              .firstOrNull;
          if (message == null || !emitted.add(message['id']! as String)) {
            continue;
          }
          final versions = <String, int>{};
          for (final alias in work.where(
              (w) => _matchesWorkId(message, {w['message_id']! as String}))) {
            final version = _materialWorkVersion(message, alias);
            final aliasId = alias['message_id']! as String;
            await txn.update('automation_session_messages',
                {'work_revision': version.revision, 'input_key': version.key},
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [session, customer, aliasId]);
            versions[aliasId] = version.revision;
          }
          result.add({
            ...message,
            'reply_input_kind': row['input_kind'],
            'reply_work_revision': versions[message['id']] ?? versions[id],
            'reply_work_revisions': versions,
            'reply_material_input_key':
                ConversationFileStore.materialInputKey(message),
            'reply_single_message_id': message['id'],
            'reply_api_customer': customer,
            'reply_api_session_id': session,
            'reply_media_input_dependencies': (<String>{
              for (final alias in versions.keys)
                ...(dependencies[alias] ?? const <String>{})
            }.toList()
              ..sort()),
          });
        }
        if (freeze && result.isNotEmpty) {
          await (await history).freezeIncomingSnapshot(customer, document,
              result.map((m) => m['id']! as String).toSet());
        }
        return result;
      });
    });
  }

  Future<String?> beginGeneration(
          {required String customer,
          required int pendingId,
          required String batchEndMessageId,
          String? expectedSessionId,
          bool singleMessage = false}) async =>
      (await beginGenerationSnapshot(
              singleMessage: singleMessage,
              customer: customer,
              pendingId: pendingId,
              batchEndMessageId: batchEndMessageId,
              expectedSessionId: expectedSessionId))
          ?.token;

  Future<GenerationSnapshot?> beginGenerationSnapshot(
          {required String customer,
          required int pendingId,
          required String batchEndMessageId,
          String? expectedSessionId,
          bool singleMessage = false,
          Set<String>? eligibleMessageIds}) =>
      _claimGeneration(
          customer: customer,
          pendingId: pendingId,
          batchEndMessageId: batchEndMessageId,
          expectedSessionId: expectedSessionId,
          singleMessage: singleMessage,
          eligibleMessageIds: eligibleMessageIds);

  /// Called once immediately before a CLI request is submitted. Keep the old
  /// claim when no complete input was added; otherwise replace token, boundary,
  /// revisions and frozen inputs in the same customer-snapshot transaction.
  /// Single-message claims retain their original token and input boundary.
  Future<GenerationSnapshot?> refreezeGenerationBeforeSubmit(
          {required String customer,
          required int pendingId,
          required String generationToken,
          required String batchEndMessageId,
          required String expectedSessionId,
          bool singleMessage = false,
          bool Function()? canCommit}) =>
      _claimGeneration(
          customer: customer,
          pendingId: pendingId,
          batchEndMessageId: batchEndMessageId,
          expectedSessionId: expectedSessionId,
          replacingToken: generationToken,
          singleMessage: singleMessage,
          canCommit: canCommit);

  Future<GenerationSnapshot?> _claimGeneration(
      {required String customer,
      required int pendingId,
      required String batchEndMessageId,
      String? expectedSessionId,
      String? replacingToken,
      bool singleMessage = false,
      Set<String>? eligibleMessageIds,
      bool Function()? canCommit}) async {
    final ownerSession = expectedSessionId ?? _automationSessionId;
    if (ownerSession != _automationSessionId) return null;
    final db = await database;
    final token = _taskId();
    final at = DateTime.now().millisecondsSinceEpoch;
    // Finish any earlier file-to-ledger commit before choosing eligibility.
    // The final short snapshot below closes the remaining update/claim race.
    if (ownerSession != null && ownerSession == _automationSessionId) {
      await repairSessionPendingWork(customer);
    }
    await processingMessages(customer);
    if (ownerSession != null) await _generationPendingSessionIds(customer);
    return (await history).withCustomerSnapshot(customer, (document) async {
      final observed = await processingMessages(customer,
          document:
              document == null ? null : Map<String, dynamic>.from(document));
      try {
        return await db.transaction((txn) async {
          if (!await _captureSessionMatches(txn, ownerSession) ||
              canCommit?.call() == false) {
            return null;
          }
          if (singleMessage && replacingToken != null && ownerSession != null) {
            final lease = await txn.query('pending_customers',
                where: 'id=? AND user_id=? AND generation_token=?',
                whereArgs: [pendingId, customer, replacingToken]);
            final frozen = await txn.rawQuery(
                """SELECT i.*,m.work_revision,m.response_state
              FROM automation_reply_inputs i JOIN automation_session_messages m
              ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
              WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?""",
                [ownerSession, customer, replacingToken]);
            final frozenMessages = frozen
                .map((row) =>
                    jsonDecode(row['message_json']?.toString() ?? '{}') as Map)
                .toList();
            final logicalIds = frozenMessages.map((m) => m['id']).toSet();
            if (lease.isEmpty ||
                frozen.isEmpty ||
                logicalIds.length != 1 ||
                logicalIds.single is! String ||
                frozen.any((row) =>
                    row['response_state'] != 'pending' ||
                    row['message_revision'] != row['work_revision']) ||
                !_frozenMaterialCurrent(frozen, document)) {
              return null;
            }
            return GenerationSnapshot(
                replacingToken,
                (frozenMessages.first['reply_single_message_id'] ??
                    logicalIds.single) as String);
          }
          final dependencyScope = ownerSession == null
              ? const <String, Set<String>>{}
              : await _generationDependencyScope(
                  txn, ownerSession, customer, document);
          final messages = <Map<String, dynamic>>[];
          for (final message in observed) {
            if (ownerSession == null || message['direction'] != 'incoming') {
              messages.add(message);
              continue;
            }
            final ids = {
              message['id'],
              ...(message['observed_ids'] as List? ?? const [])
            };
            final work = await txn.query('automation_session_messages',
                where:
                    "session_id=? AND user_id=? AND response_state='pending'",
                whereArgs: [ownerSession, customer]);
            final versions = <String, int>{};
            for (final row
                in work.where((row) => ids.contains(row['message_id']))) {
              final version = _materialWorkVersion(message, row);
              await txn.update('automation_session_messages',
                  {'work_revision': version.revision, 'input_key': version.key},
                  where: 'session_id=? AND user_id=? AND message_id=?',
                  whereArgs: [ownerSession, customer, row['message_id']]);
              versions[row['message_id']! as String] = version.revision;
            }
            messages.add({
              ...message,
              'reply_work_revision':
                  versions[message['id']] ?? message['reply_work_revision'],
              'reply_work_revisions': versions,
              'reply_material_input_key':
                  ConversationFileStore.materialInputKey(message),
              'reply_media_input_dependencies': (<String>{
                for (final id in versions.keys)
                  ...(dependencyScope[id] ?? const <String>{}),
              }.toList()
                ..sort()),
            });
          }
          final eligibleIds = ownerSession == null
              ? null
              : await _eligibleGenerationInputs(
                  txn, ownerSession, customer, document,
                  knownDependencies: dependencyScope);
          if (eligibleMessageIds != null && eligibleIds != null) {
            eligibleIds.removeWhere((id) => !messages.any((m) =>
                _matchesWorkId(m, {id}) &&
                _matchesWorkId(m, eligibleMessageIds)));
          }
          // A generated answer keeps ownership until its native delivery and
          // exact-input commit finish. Releasing the CLI lease is not releasing
          // that answer's inputs to another generation for the same customer.
          if ((await txn.query('generated_drafts',
                  columns: ['user_id'],
                  where: 'user_id=?',
                  whereArgs: [customer],
                  limit: 1))
              .isNotEmpty) {
            return null;
          }
          var anchor = batchEndMessageId;
          if (singleMessage && ownerSession != null) {
            final oldest = await txn.query('automation_session_messages',
                columns: ['message_id'],
                where:
                    "session_id=? AND user_id=? AND response_state='pending'",
                whereArgs: [ownerSession, customer],
                orderBy: 'rowid ASC');
            final selected = oldest
                .where((row) =>
                    eligibleIds!.contains(row['message_id']) &&
                    messages.any((m) =>
                        m['direction'] == 'incoming' &&
                        _matchesWorkId(m, {row['message_id']! as String})))
                .firstOrNull;
            if (selected == null) return null;
            anchor = selected['message_id']! as String;
          }
          if (replacingToken != null && ownerSession != null) {
            final latest = await txn.query('automation_session_messages',
                columns: ['message_id'],
                where:
                    "session_id=? AND user_id=? AND response_state='pending'",
                whereArgs: [ownerSession, customer],
                orderBy: 'rowid DESC');
            anchor = latest
                    .where((row) => eligibleIds!.contains(row['message_id']))
                    .where((row) => messages.any((message) =>
                        message['direction'] == 'incoming' &&
                        _matchesWorkId(
                            message, {row['message_id']! as String})))
                    .firstOrNull?['message_id']
                    ?.toString() ??
                batchEndMessageId;
          }
          final batchEnd = messages
              .where((message) =>
                  message['direction'] == 'incoming' &&
                  (message['id'] == anchor ||
                      (message['observed_ids'] as List? ?? const [])
                          .contains(anchor)))
              .firstOrNull;
          if (ownerSession != null &&
              (batchEnd == null ||
                  !_matchesWorkId(batchEnd, eligibleIds!) ||
                  !_matchesWorkId(batchEnd,
                      await _pendingSessionIds(customer, executor: txn)))) {
            return null;
          }
          final row = await txn.query('pending_customers',
              where: 'id=? AND user_id=? AND generation_retry_at_ms<=?',
              whereArgs: [pendingId, customer, at]);
          if (row.isEmpty ||
              (ownerSession == null &&
                  row.single['newest_message_id'] != anchor) ||
              (ownerSession != null &&
                  row.single['generation_token'] != replacingToken)) {
            return null;
          }
          if ((await txn.query('conversation_control',
                  where: "user_id=? AND state LIKE 'handoff_%'",
                  whereArgs: [customer]))
              .isNotEmpty) {
            return null;
          }
          final cursor = await txn.query('answered_cursors',
              where: 'user_id=?', whereArgs: [customer]);
          final end = messages.indexOf(batchEnd ?? const {});
          if (end < 0 ||
              end <=
                  _answeredIndex(messages,
                      cursor.firstOrNull?['message_id']?.toString())) {
            return null;
          }
          if (ownerSession != null) {
            // processingMessages was read before this transaction. A preceding
            // answer may have committed in between; never freeze its now-answered
            // inputs into this next question's scope.
            var inputs = await _inputsThroughGenerationAnchor(
                txn, customer, anchor, messages,
                eligibleIds: eligibleIds);
            if (singleMessage) {
              inputs =
                  inputs.where((m) => _matchesWorkId(m, {anchor})).toList();
            }
            if (inputs.isEmpty) return null;
            Map<String, Object?>? inheritedWindow;
            if (replacingToken != null) {
              final frozen = await txn.rawQuery(
                  '''SELECT i.*,m.work_revision,m.response_state
              FROM automation_reply_inputs i JOIN automation_session_messages m
                ON m.session_id=i.session_id AND m.user_id=i.user_id
                  AND m.message_id=i.message_id
              WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
                  [ownerSession, customer, replacingToken]);
              if (frozen.isEmpty ||
                  frozen.any((input) =>
                      input['response_state'] != 'pending' ||
                      input['work_revision'] != input['message_revision']) ||
                  !_frozenMaterialCurrent(frozen, document)) {
                return null;
              }
              inheritedWindow = _responseWindowFromInputs(frozen, customer);
              final oldIds = frozen.map((input) => input['message_id']).toSet();
              final complete = await CustomerMediaInventory(this)
                  .analysisReadyMessageIds(customer, executor: txn);
              final contentScope = await _generationDependencyScope(
                  txn, ownerSession, customer, document,
                  receiptFactsWithoutContent: false);
              bool contentReady(Object? id) =>
                  (contentScope[id] ?? const <String>{})
                      .every(complete.contains);
              if (oldIds.any((id) => !contentReady(id))) {
                return GenerationSnapshot(replacingToken, batchEndMessageId);
              }
              final candidates = await txn.query('automation_session_messages',
                  columns: ['message_id'],
                  where:
                      "session_id=? AND user_id=? AND response_state='pending'",
                  whereArgs: [ownerSession, customer],
                  orderBy: 'rowid ASC');
              final newIds = candidates
                  .where((row) =>
                      eligibleIds!.contains(row['message_id']) &&
                      contentReady(row['message_id']))
                  .where((row) => inputs.any((input) =>
                      _matchesWorkId(input, {row['message_id']! as String})))
                  .map((row) => row['message_id'])
                  .toSet();
              // An expansion may add ready work; it can never silently discard
              // a previously frozen input or overwrite a changed old question.
              if (!newIds.containsAll(oldIds)) return null;
              if (newIds.difference(oldIds).isEmpty) {
                return GenerationSnapshot(replacingToken, batchEndMessageId);
              }
              inputs = inputs
                  .where(
                      (input) => _matchesWorkId(input, newIds.cast<String>()))
                  .toList();
              anchor = candidates.lastWhere((row) =>
                  newIds.contains(row['message_id']))['message_id']! as String;
            }
            if (canCommit?.call() == false) {
              throw const _GenerationClaimAborted();
            }
            if (singleMessage && document != null) {
              await (await history).freezeIncomingSnapshot(customer, document,
                  inputs.map((m) => m['id']! as String).toSet());
            }
            await _bindReplyInputs(
                txn, customer, token, inputs.map((m) => m['id']! as String),
                messages: {for (final m in inputs) m['id']! as String: m},
                responseWindow: inheritedWindow ??
                    await _snapshotReplyResponseWindow(txn, customer,
                        scope: inputs.map((m) => m['id']! as String)));
          }
          if (canCommit?.call() == false) {
            throw const _GenerationClaimAborted();
          }
          final claimed = await txn.rawUpdate(
              'UPDATE pending_customers SET generation_token=?,'
              'generation_attempts=generation_attempts+? '
              'WHERE id=? AND user_id=?'
              '${ownerSession == null ? '' : ' AND generation_token IS ?'}',
              [
                token,
                replacingToken == null ? 1 : 0,
                pendingId,
                customer,
                if (ownerSession != null) replacingToken
              ]);
          return claimed == 1
              ? GenerationSnapshot(token, anchor,
                  expanded: replacingToken != null)
              : null;
        });
      } on _GenerationClaimAborted {
        // A normal null return would commit newly bound input rows. Abort the
        // transaction instead so cancellation leaves the old claim intact.
        return null;
      }
    });
  }

  Future<bool> isBatchUnanswered(String customer, String messageId) async {
    if (!await isCurrentSessionMessage(customer, messageId)) return false;
    final messages = await processingMessages(customer);
    final at = messages.indexWhere(
        (m) => _matchesWorkId(m, {messageId}) && m['direction'] == 'incoming');
    return at >= 0 &&
        at > _answeredIndex(messages, await answeredMessageId(customer));
  }

  Future<DateTime> recordGenerationFailure(String userId, Object error) async {
    final db = await database;
    final rows = await db
        .query('pending_customers', where: 'user_id=?', whereArgs: [userId]);
    final attempts = (rows.firstOrNull?['generation_attempts'] as int?) ?? 0;
    final delay = attempts >= 5 ? 60 : 10;
    final at = DateTime.now().add(Duration(seconds: delay));
    await db.update(
        'pending_customers',
        {
          'generation_token': null,
          'generation_retry_at_ms': at.millisecondsSinceEpoch,
          'generation_last_error': error.toString()
        },
        where: 'user_id=?',
        whereArgs: [userId]);
    RuntimeTrace.record('generation.retry_scheduled', {
      'customer': userId,
      'attempts': attempts,
      'nextActionAtMs': at.millisecondsSinceEpoch,
      'reason': error.runtimeType.toString()
    });
    return at;
  }

  Future<bool> generationDue(String userId) async {
    final due = (await (await database).query('pending_customers',
            columns: ['id'],
            where: 'user_id=? AND generation_retry_at_ms<=?',
            whereArgs: [userId, DateTime.now().millisecondsSinceEpoch],
            limit: 1))
        .isNotEmpty;
    return due &&
        (_automationSessionId == null ||
            (await _generationPendingSessionIds(userId)).isNotEmpty);
  }

  Future<
      List<
          Map<String,
              Object?>>> pendingHealth() async => (await database).rawQuery(
      "SELECT p.user_id,p.enqueued_at_ms,p.generation_attempts,p.generation_retry_at_ms,p.generation_last_error,COALESCE(s.batch_started_at_ms,p.enqueued_at_ms-?) AS waiting_since_ms FROM pending_customers p LEFT JOIN sla_fallbacks s ON s.user_id=p.user_id",
      [holdingDelay.inMilliseconds]);

  Future<Set<String>> mergeMediaCaptionBatch(
      String customer, CapturedConversation? capture) async {
    // A leased flow answers its exact durable input scope. Ordinary captions
    // belong to the next batch; only new evidence on that same message can
    // invalidate the leased revision.
    if (_automationSessionId != null) return {};
    final texts = (capture?.messages ?? const <CapturedMessage>[])
        .where((m) =>
            m.direction == 'incoming' &&
            m.media.isEmpty &&
            m.sentAt != null &&
            m.body.trim().isNotEmpty &&
            TranscriptText.clean(m.body).isNotEmpty)
        .toList();
    if (texts.isEmpty) return {};
    final messages = await processingMessages(customer);
    final boundary =
        _answeredIndex(messages, await answeredMessageId(customer));
    final targets = <String>{};
    for (final m in messages.skip(boundary + 1)) {
      if (m['direction'] != 'incoming' ||
          (m['media'] as List? ?? const []).isEmpty) {
        continue;
      }
      final clock = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (clock == null) continue;
      if (texts.any((t) =>
          !t.sentAt!.isBefore(clock) &&
          t.sentAt!.difference(clock) <= const Duration(seconds: 12))) {
        targets.add(m['id']! as String);
      }
    }
    if (targets.isEmpty) return targets;
    final marks = List.filled(targets.length, '?').join(',');
    final retired = await (await database).rawDelete(
        "DELETE FROM generated_drafts WHERE user_id=? AND batch_end_message_id IN ($marks) AND delivery_state IN ('ready','retry') AND (attempt_id IS NULL OR EXISTS(SELECT 1 FROM delivery_attempts a WHERE a.attempt_id=generated_drafts.attempt_id AND a.state IN ('not_sent','rejected')))",
        [customer, ...targets]);
    RuntimeTrace.record('generation.media_caption_merged', {
      'customer': customer,
      'mediaMessageIds': targets.toList(),
      'captionMessageIds': texts.map((t) => t.stableId).toList(),
      'retiredUnclickedDrafts': retired,
      'clickedOrUnknownPreserved': true
    });
    return targets;
  }

  Future<void> retireMediaPreviews(
      String customer, List<String> previews) async {
    if (previews.isEmpty) return;
    final marks = List.filled(previews.length, '?').join(',');
    final retired = await (await database).rawDelete(
        """DELETE FROM generated_drafts WHERE user_id=? AND batch_end_message_id IN ($marks)
      AND delivery_state IN ('ready','retry') AND (attempt_id IS NULL OR EXISTS(
        SELECT 1 FROM delivery_attempts a WHERE a.attempt_id=generated_drafts.attempt_id AND a.state IN ('not_sent','rejected')))""",
        [customer, ...previews]);
    // Only retire rereads if EVERY still-unanswered incoming is a proven
    // alias of an original already covered by the answered cursor.
    final store = await history;
    final messages =
        ((await store.read(customer))?['messages'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    final cursor = await answeredMessageId(customer);
    final boundary = _answeredIndex(messages, cursor);
    final incoming = messages
        .skip(boundary + 1)
        .where((m) => m['direction'] == 'incoming')
        .toList();
    if (boundary >= 0 &&
        incoming.isNotEmpty &&
        incoming.every((m) => previews.contains(m['id']))) {
      final db = await database;
      final originals = await db.query('customer_media_items',
          where: "customer=? AND state='ready' AND canonical_id IS NULL",
          whereArgs: [customer]);
      final proven = incoming.every((m) => originals.any((r) {
            final originalIndex = _messageIndex(messages, r['message_id']);
            return originalIndex >= 0 &&
                originalIndex <= boundary &&
                (jsonDecode(r['aliases_json']! as String) as List)
                    .contains(m['id']);
          }));
      if (proven) {
        final last = incoming.last['id']! as String;
        final changed = await db.transaction((txn) async {
          final owner = await txn.query('answered_cursors',
              where: 'user_id=?', whereArgs: [customer]);
          if (owner.firstOrNull?['message_id'] != cursor) return false;
          final drafts = await txn.query('generated_drafts',
              where: 'user_id=?', whereArgs: [customer]);
          if (drafts.isNotEmpty) {
            return false; // preserve clicked/uncertain work
          }
          final queued = await txn.query('pending_customers',
              where: 'user_id=?', whereArgs: [customer]);
          if (queued.isNotEmpty && queued.single['newest_message_id'] != last) {
            return false;
          }
          await txn.update('answered_cursors', {'message_id': last},
              where: 'user_id=?', whereArgs: [customer]);
          await txn.delete('pending_customers',
              where: 'user_id=? AND newest_message_id=?',
              whereArgs: [customer, last]);
          return true;
        });
        if (changed) {
          RuntimeTrace.record('delivery.answered_media_alias_retired', {
            'customer': customer,
            'messageId': last,
            'priorCursor': cursor,
            'proof': 'all_pending_are_aliases_of_answered_originals'
          });
        }
      }
    }
    if (retired > 0) await ensurePendingForUnanswered(customer);
    RuntimeTrace.record('delivery.media_preview_retired', {
      'customer': customer,
      'previewMessageIds': previews,
      'retired': retired,
      'sendingOrUnknownPreserved': true
    });
  }

  Future<int> customerMediaRevision(String customer) async {
    final rows = await (await database).query('customer_media_versions',
        where: 'customer=?', whereArgs: [customer]);
    return rows.isEmpty ? 0 : rows.single['revision']! as int;
  }

  Future<bool> mediaContextCurrent(String customer, AiDraft draft) async {
    final raw = jsonDecode(draft.rawJson) as Map;
    if (_mediaDependencyKeys(raw) != null) {
      return _mediaDependencyKeysCurrent(await database, customer, raw);
    }
    return draft.mediaContextRevision == null ||
        draft.mediaContextRevision == await customerMediaRevision(customer);
  }

  /// Only demonstrably unclicked stale work is replaced. Recovery and pending
  /// cursors remain durable; an uncertain click is never regenerated here.
  Future<bool> retireStaleMediaDraft(String customer) async {
    final db = await database;
    final retired = await db.transaction((txn) async {
      final rows = await txn.query('generated_drafts',
          where: "user_id=? AND delivery_state IN ('ready','retry')",
          whereArgs: [customer]);
      if (rows.isEmpty) return false;
      final row = rows.single;
      if (_hasCompletedApiProof(row)) {
        return _retireInvalidInputDraft(txn, customer);
      }
      final AiDraft draft;
      try {
        draft = AiDraft.fromJson(jsonDecode(row['raw_json']! as String),
            mediaBaseUrl: Uri());
      } catch (_) {
        return false;
      } // The delivery reader quarantines malformed payloads.
      final newer = await txn.query('pending_customers',
          where: 'user_id=?', whereArgs: [customer]);
      final obsoleteAck = newer.isNotEmpty &&
          newer.single['newest_message_id'] != row['batch_end_message_id'] &&
          ResponseTimingPolicy.isTrivialAcknowledgement(
              row['reply']! as String);
      final version = await txn.query('customer_media_versions',
          where: 'customer=?', whereArgs: [customer]);
      final current = version.isEmpty ? 0 : version.single['revision'];
      final raw = jsonDecode(row['raw_json']! as String) as Map;
      final staleMedia = _mediaDependencyKeys(raw) != null
          ? !await _mediaDependencyKeysCurrent(txn, customer, raw)
          : draft.mediaContextRevision != null &&
              current != draft.mediaContextRevision;
      final staleInputs = !await _draftInputsCurrent(txn, customer, row);
      if (!staleMedia && !obsoleteAck && !staleInputs) return false;
      final attempt = row['attempt_id'];
      if (attempt != null) {
        final a = await txn.query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt]);
        if (a.isEmpty ||
            !const {'not_sent', 'rejected'}.contains(a.single['state'])) {
          return false;
        }
      }
      await txn.delete('generated_drafts',
          where: 'user_id=? AND created_at_ms=?',
          whereArgs: [customer, row['created_at_ms']]);
      RuntimeTrace.record('delivery.stale_media_draft_retired', {
        'customer': customer,
        'taskId': row['task_id'],
        'snapshotRevision': draft.mediaContextRevision,
        'currentRevision': current,
        'reason': obsoleteAck
            ? 'newer_customer_message_supersedes_ack'
            : 'media_context_changed'
      });
      return true;
    });
    if (retired) await ensurePendingForUnanswered(customer);
    return retired;
  }

  Future<void> abandonGeneration(String customer, String token) async =>
      (await database).update('pending_customers', {'generation_token': null},
          where: 'user_id=? AND generation_token=?',
          whereArgs: [customer, token]);

  Future<void> cancelGenerationLeases() async =>
      (await database).update('pending_customers', {'generation_token': null});

  Future<Set<String>> outstandingCustomers() async {
    final rows =
        await (await database).rawQuery('''SELECT user_id FROM generated_drafts
      UNION SELECT user_id FROM pending_customers UNION SELECT user_id FROM sla_fallbacks
      WHERE state IN ('pending','sending','reconciling')''');
    return rows.map((r) => r['user_id']! as String).toSet();
  }

  static const _uncertainDeliveryHoldTable = 'delivery_unknown_holds';
  static const _uncertainDeliveryHoldPrefix = 'delivery-unknown-hold:';

  bool _isUncertainDeliveryWait(Map row) =>
      row['content_key']?.toString().startsWith(_uncertainDeliveryHoldPrefix) ==
      true;

  Future<Set<String>> _uncertainDeliveryHeldIds(
          DatabaseExecutor db, String customer) async =>
      (await db.query('automation_message_waits',
              where: 'session_id=? AND user_id=? AND content_key LIKE ?',
              whereArgs: [
            _automationSessionId ?? 'legacy',
            customer,
            '$_uncertainDeliveryHoldPrefix%'
          ]))
          .map((row) => row['message_id']! as String)
          .toSet();

  Future<List<Map<String, Object?>>> reconciliationWork() async {
    final db = await database;
    final active = await db.rawQuery(
        """SELECT user_id,delivery_state AS state,created_at_ms AS since_ms,
          task_id,attempt_id,batch_end_message_id,last_error
        FROM generated_drafts WHERE delivery_state IN ('delivery_unknown','quarantined')
        UNION ALL SELECT user_id,state,updated_at_ms AS since_ms,
          NULL,attempt_id,message_id,NULL FROM sla_fallbacks
        WHERE state='reconciling' """);
    final held = await db.rawQuery("""SELECT h.*,a.state AS attempt_state
      FROM automation_work_archive h LEFT JOIN delivery_attempts a
        ON a.attempt_id=h.record_key
      WHERE h.table_name=? AND (a.state IS NULL OR a.state IN
        ('superseded_unknown','superseded_submitted','superseded_not_sent','superseded_rejected'))""",
        [_uncertainDeliveryHoldTable]);
    final result = <Map<String, Object?>>[
      for (final row in active) {...row, 'held': false, 'blocksCustomer': true},
    ];
    for (final row in held) {
      final saved = jsonDecode(row['row_json']! as String) as Map;
      if (!const {'unknown', 'proven_not_sent'}
          .contains(saved['hold_status'])) {
        continue;
      }
      result.add({
        'user_id': saved['user_id'],
        'state': saved['hold_status'] == 'proven_not_sent'
            ? 'proven_not_sent'
            : 'delivery_unknown',
        'since_ms': row['archived_at_ms'],
        'task_id': saved['task_id'],
        'attempt_id': row['record_key'],
        'batch_end_message_id': saved['batch_end_message_id'],
        'message_ids': saved['held_message_ids'],
        'last_error': saved['last_error'],
        'attempt_state': row['attempt_state'],
        'held': true,
        'blocksCustomer': false,
      });
    }
    return result;
  }

  /// Freeze an uncertain reply and its exact source scope without retaining
  /// the customer's single active draft slot. The ledger and native receipt
  /// remain live reconciliation evidence; this is never resend permission.
  Future<bool> isolateUncertainDelivery(String customer) async {
    final db = await database;
    return db.transaction((txn) async {
      final old = (await txn.query('generated_drafts',
              where: "user_id=? AND delivery_state='delivery_unknown'",
              whereArgs: [customer]))
          .firstOrNull;
      if (old == null) return false;
      final attemptId = old['attempt_id']?.toString();
      final attempt = attemptId == null
          ? null
          : (await txn.query('delivery_attempts',
                  where: 'attempt_id=? AND user_id=?',
                  whereArgs: [attemptId, customer]))
              .firstOrNull;
      // A physical insertion with no completed failure/recovery transition
      // still owns the slot, regardless of its source message's age.
      if (attempt != null &&
          !const {'unknown', 'superseded_unknown'}.contains(attempt['state'])) {
        return false;
      }
      final session = _automationSessionId ?? 'legacy';
      final scope = await _replyInputIds(
          txn, customer, old['task_id']?.toString() ?? '',
          rawJson: old['raw_json']?.toString());
      if (scope.isEmpty && old['batch_end_message_id'] is String) {
        scope.add(old['batch_end_message_id']! as String);
      }
      if (scope.isEmpty) return false;
      final key = attemptId ?? 'task:${old['task_id']}';
      final now = DateTime.now().millisecondsSinceEpoch;
      if ((await txn.query('automation_work_archive',
              where: 'table_name=? AND record_key=?',
              whereArgs: [_uncertainDeliveryHoldTable, key]))
          .isEmpty) {
        await txn.insert('automation_work_archive', {
          'session_id': session,
          'table_name': _uncertainDeliveryHoldTable,
          'record_key': key,
          'row_json': jsonEncode({
            ...old,
            'held_message_ids': scope.toList(),
            'hold_status': 'unknown',
            'hold_reason': old['last_error'] ?? 'send_unconfirmed',
          }),
          'archived_at_ms': now,
        });
      }
      final work = await txn.query('automation_session_messages',
          where: 'session_id=? AND user_id=?', whereArgs: [session, customer]);
      for (final id in scope) {
        final source = work.where((row) => row['message_id'] == id).firstOrNull;
        await txn.insert(
            'automation_message_waits',
            {
              'session_id': session,
              'user_id': customer,
              'message_id': id,
              'is_media': source?['input_kind'] == 'media' ? 1 : 0,
              'content_key': '$_uncertainDeliveryHoldPrefix$key',
              'message_revision': source?['work_revision'] ?? 0,
              'task_id': old['task_id'],
              'updated_at_ms': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.delete('generated_drafts',
          where:
              "user_id=? AND task_id=? AND delivery_state='delivery_unknown'",
          whereArgs: [customer, old['task_id']]);
      if (attemptId != null) {
        await txn.update('delivery_attempts', {'state': 'superseded_unknown'},
            where: "attempt_id=? AND state='unknown'", whereArgs: [attemptId]);
      }
      await txn.rawDelete("""DELETE FROM unavailable_conversations
        WHERE user_id=? AND reason=? AND NOT $_activeReceiptReconciliationSql""",
          [customer, _receiptReconciliationSuspension, customer, customer]);
      RuntimeTrace.record('delivery.uncertain_message_isolated', {
        'customer': customer,
        'attemptId': attemptId,
        'taskId': old['task_id'],
        'messageIds': scope.toList(),
        'reason': old['last_error'],
        'blocksCustomer': false,
        'retypingAuthorized': false,
      });
      return true;
    });
  }

  Future<void> _settleUncertainDeliveryHold(
      DatabaseExecutor txn, String attemptId, String status,
      {Map? receipt}) async {
    final holds = await txn.query('automation_work_archive',
        where: 'table_name=? AND record_key=?',
        whereArgs: [_uncertainDeliveryHoldTable, attemptId]);
    for (final hold in holds) {
      final saved = jsonDecode(hold['row_json']! as String) as Map;
      await txn.update(
          'automation_work_archive',
          {
            'row_json': jsonEncode({
              ...saved,
              'hold_status': status,
              if (receipt != null) 'latest_receipt': receipt,
            })
          },
          where: 'id=?',
          whereArgs: [hold['id']]);
      if (status == 'confirmed' || status == 'retry_restored') {
        await txn.delete('automation_message_waits',
            where: 'session_id=? AND user_id=? AND content_key=?',
            whereArgs: [
              hold['session_id'],
              saved['user_id'],
              '$_uncertainDeliveryHoldPrefix$attemptId'
            ]);
      }
    }
  }

  /// A proven no-send may retry the original frozen reply once newer work has
  /// had the slot. Unknown receipts never enter this path.
  Future<void> _restoreKnownUnsentHeldDrafts() async {
    final db = await database;
    final holds = await db.query('automation_work_archive',
        where: 'table_name=? AND session_id=?',
        whereArgs: [
          _uncertainDeliveryHoldTable,
          _automationSessionId ?? 'legacy'
        ],
        orderBy: 'archived_at_ms ASC');
    for (final hold in holds) {
      final saved = Map<String, Object?>.from(
          jsonDecode(hold['row_json']! as String) as Map);
      if (saved['hold_status'] != 'proven_not_sent') continue;
      final customer = saved['user_id']! as String;
      final key = hold['record_key']! as String;
      await db.transaction((txn) async {
        if ((await txn.query('generated_drafts',
                    where: 'user_id=?', whereArgs: [customer]))
                .isNotEmpty ||
            (await txn.query('pending_customers',
                    where: 'user_id=? AND generation_token IS NOT NULL',
                    whereArgs: [customer]))
                .isNotEmpty) {
          return;
        }
        final attempt = (await txn.query('delivery_attempts',
                where:
                    "attempt_id=? AND state IN ('superseded_not_sent','superseded_rejected')",
                whereArgs: [key]))
            .firstOrNull;
        if (attempt == null) return;
        final scope =
            (saved['held_message_ids'] as List).cast<String>().toSet();
        if (_automationSessionId != null) {
          final current = await _replyInputIds(
              txn, customer, saved['task_id']! as String,
              currentRevisionOnly: true);
          if (!current.containsAll(scope)) return;
          final pending = await _pendingSessionIds(customer, executor: txn);
          final heldIds = await _uncertainDeliveryHeldIds(txn, customer);
          // Let already queued/completed work for unrelated sources proceed.
          if (pending.difference(scope).difference(heldIds).isNotEmpty) return;
        }
        final columns =
            (await txn.rawQuery('PRAGMA table_info(generated_drafts)'))
                .map((row) => row['name'])
                .toSet();
        final draft = <String, Object?>{
          for (final entry in saved.entries)
            if (columns.contains(entry.key)) entry.key: entry.value,
          'delivery_state': 'retry',
          'retry_at_ms': DateTime.now().millisecondsSinceEpoch,
          'last_error': 'native_proven_not_sent: restored_original_snapshot',
        };
        await txn.insert('generated_drafts', draft,
            conflictAlgorithm: ConflictAlgorithm.abort);
        await _settleUncertainDeliveryHold(txn, key, 'retry_restored');
      });
    }
  }

  static const _receiptReconciliationSuspension =
      'send_unconfirmed: reconciliation_required';
  static const _activeReceiptReconciliationSql = '''EXISTS(
      SELECT 1 FROM generated_drafts WHERE user_id=?
        AND delivery_state IN ('delivery_unknown','quarantined')
      UNION ALL SELECT 1 FROM sla_fallbacks WHERE user_id=?
        AND state='reconciling')''';

  /// Keep the uncertain physical attempt in the append-only attempt ledger.
  /// A genuinely newer customer turn may get its own draft; this never grants
  /// permission to retype the old reply or overwrite a nonempty composer.
  Future<bool> detachUnknownForNewInput(String customer) async {
    final db = await database;
    final drafts = await db.query('generated_drafts',
        where:
            "user_id=? AND delivery_state='delivery_unknown' AND attempt_id IS NOT NULL",
        whereArgs: [customer]);
    if (drafts.isEmpty) return false;
    final old = drafts.single;
    final attempts = await db.query('delivery_attempts',
        where: "attempt_id=? AND user_id=? AND state='unknown'",
        whereArgs: [old['attempt_id'], customer]);
    if (attempts.length != 1) return false;
    final attemptedAt = attempts.single['created_at_ms']! as int;
    final document = await (await history).read(customer);
    final messages = (document?['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final boundary = _messageIndex(messages, old['batch_end_message_id']);
    if (boundary < 0) return false;
    final original = messages[boundary];
    final originalSent =
        DateTime.tryParse(original['sent_at']?.toString() ?? '');
    final inventory = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    Set<String> aliases(Map row) => {
          if (row['message_id'] is String) row['message_id']! as String,
          ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
              .whereType<String>()
        };
    Map<String, Object?>? mediaRoot(Map message) {
      final ids = {
        if (message['id'] is String) message['id']! as String,
        ...(message['observed_ids'] as List? ?? const []).whereType<String>()
      };
      final roots = <String, Map<String, Object?>>{};
      for (final row in inventory) {
        if (row['item_id'] != message['media_receipt_id'] &&
            aliases(row).intersection(ids).isEmpty) {
          continue;
        }
        Map<String, Object?>? root = row;
        final visited = <String>{};
        while (root?['canonical_id'] != null &&
            visited.add(root!['item_id']! as String)) {
          final canonical = root['canonical_id'];
          root = inventory.where((r) => r['item_id'] == canonical).firstOrNull;
        }
        if (root != null && root['canonical_id'] == null) {
          roots[root['item_id']! as String] = root;
        }
      }
      return roots.length == 1 ? roots.values.single : null;
    }

    bool provenCard(Map<String, Object?>? row) {
      if (row == null ||
          row['identity_ambiguous'] == 1 ||
          !const {'video', 'image'}.contains(row['kind']) ||
          const {'historical', 'rejected', 'superseded'}
              .contains(row['state'])) {
        return false;
      }
      // An owned original, or a nonambiguous preview with an actual visual
      // signature, can establish a distinct card. Clock/slot alone cannot.
      return row['state'] == 'ready' ||
          (aliases(row).isNotEmpty &&
              RegExp(r'^[0-9a-fA-F]{16}$')
                  .hasMatch(row['visual_fingerprint']?.toString() ?? ''));
    }

    final originalMedia = (original['media'] as List? ?? const []).isNotEmpty;
    final originalRoot = mediaRoot(original);
    final newer = messages.skip(boundary + 1).where((m) {
      if (m['direction'] != 'incoming' ||
          m['capture_purpose'] == 'history_only') {
        return false;
      }
      final captured = DateTime.tryParse(m['captured_at']?.toString() ?? '');
      final sent = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (captured == null ||
          captured.millisecondsSinceEpoch < attemptedAt ||
          (originalSent != null &&
              sent != null &&
              sent.isBefore(originalSent))) {
        return false;
      }
      final a = m['media_receipt_id'], b = original['media_receipt_id'];
      if (a != null && a == b) return false;
      if ((m['media'] as List? ?? const []).isNotEmpty) {
        final nextRoot = mediaRoot(m);
        if (!provenCard(nextRoot)) return false;
        if (originalRoot != null &&
            (nextRoot!['item_id'] == originalRoot['item_id'] ||
                aliases(nextRoot)
                    .intersection(aliases(originalRoot))
                    .isNotEmpty)) {
          return false;
        }
        if ((originalMedia || originalRoot != null || b != null) &&
            !provenCard(originalRoot)) {
          return false;
        }
      }
      return true;
    }).firstOrNull;
    if (newer == null) return false;
    return isolateUncertainDelivery(customer);
  }

  /// A native submission may finish while a new calendar session starts.
  /// Select archival history from its immutable original task, never from
  /// whichever day [history] happens to represent after an asynchronous wait.
  Future<ConversationFileStore> _historyForReplyOwner(
      String customer, Map<String, Object?> row) async {
    if (!_currentDayOnly) return history;
    if (row['user_id'] != customer) {
      throw StateError('reply_history_customer_mismatch');
    }
    final prefix = 'incoming-time:${Uri.encodeComponent(customer)}:';
    String? dayOf(Object? id) {
      if (id is! String || !id.startsWith(prefix)) return null;
      final at = DateTime.tryParse(id.substring(prefix.length));
      return at == null ? null : ConversationFileStore.businessDayFor(at);
    }

    final raw = jsonDecode(row['raw_json']?.toString() ?? '{}') as Map;
    var day = dayOf(row['batch_end_message_id']);
    if (day == null) {
      final days = {
        for (final id in (raw['service_message_ids'] as List? ?? const []))
          if (dayOf(id) case final String value) value,
      };
      if (days.length == 1) day = days.single;
    }
    if (day == null && raw['service_session_id'] is String) {
      final session = (await (await database).query('automation_sessions',
              columns: ['started_at_ms'],
              where: 'session_id=?',
              whereArgs: [raw['service_session_id']]))
          .firstOrNull;
      if (session?['started_at_ms'] case final num at) {
        day = ConversationFileStore.businessDayFor(
            DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true));
      }
    }
    if (day == null) {
      if (row['created_at_ms'] case final num at) {
        day = ConversationFileStore.businessDayFor(
            DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true));
      }
    }
    if (day == null) throw StateError('reply_history_task_day_missing');
    return ConversationFileStore.forDay(await storageRoot,
        businessDay: day, clock: _businessClock);
  }

  Future<bool> _recordDetachedSubmission(Map<String, Object?> attempt,
      {CapturedMessage? observed}) async {
    final ownerSession = _automationSessionId;
    final customer = attempt['user_id']! as String;
    final store = await _historyForReplyOwner(customer, attempt);
    final task = attempt['task_id']! as String;
    final id = attempt['attempt_id']! as String;
    if (!await _verifyNativeSubmission(customer, id, taskId: task)) {
      return false;
    }

    final batch = attempt['batch_end_message_id']?.toString();
    if (batch == null || batch.isEmpty) {
      throw StateError('Detached attempt has no frozen input boundary');
    }
    if (observed != null) {
      if (!await store.bindObservedAttempt(
          userId: customer,
          messageId: observed.stableId,
          attemptId: id,
          taskId: task,
          batchEndMessageId: batch)) {
        return false;
      }
    } else {
      await store.appendSentReply(
          userId: customer,
          displayName: customer,
          stableKey: customer,
          draft: AiDraft.fromJson(jsonDecode(attempt['raw_json']! as String),
              mediaBaseUrl: Uri()),
          taskId: task,
          attemptId: id,
          batchEndMessageId: batch);
    }
    final messages =
        ((await store.read(customer))?['messages'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    final index = _messageIndex(messages, batch);
    final db = await database;
    await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession)) return;
      await _completeReplyInputs(txn, customer, task,
          attemptId: id, rawJson: attempt['raw_json']?.toString());
      // A later positive receipt can overtake a proven-no-send restoration.
      // Cancel only that untouched retry; a replacement task or new physical
      // attempt has its own identity and must remain owned by its sender.
      await txn.delete('generated_drafts',
          where:
              "user_id=? AND task_id=? AND attempt_id=? AND delivery_state IN ('ready','retry')",
          whereArgs: [customer, task, id]);
      final cursor = await txn
          .query('answered_cursors', where: 'user_id=?', whereArgs: [customer]);
      final oldIndex = _answeredIndex(
          messages, cursor.firstOrNull?['message_id']?.toString());
      if (index >= 0 && index > oldIndex) {
        await txn.rawInsert(
            'INSERT INTO answered_cursors(user_id,message_id) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET message_id=excluded.message_id',
            [customer, batch]);
      }
      await txn.update(
          'delivery_attempts',
          {
            'state': observed == null
                ? 'superseded_submitted'
                : 'superseded_accepted',
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch
          },
          where: 'attempt_id=?',
          whereArgs: [id]);
    });
    await _settleUncertainDeliveryHold(db, id, 'confirmed');
    RuntimeTrace.record('delivery.detached_attempt_confirmed', {
      'customer': customer,
      'attemptId': id,
      'batchEndMessageId': batch,
      'newerBatchPreserved': true
    });
    return true;
  }

  Future<bool> _confirmDetachedObserved(
      String customer, CapturedMessage observed, DateTime capturedAt) async {
    final db = await database;
    final candidates = await db.query('delivery_attempts',
        where:
            "user_id=? AND state IN ('superseded_unknown','superseded_submitted','superseded_accepted','sending','unknown','submitted','accepted') AND kind='reply'",
        whereArgs: [customer]);
    String clean(String s) => s.replaceAll(RegExp(r'\s+'), '');
    final matches = candidates.where((r) {
      final at = r['created_at_ms']! as int;
      final sent = observed.sentAt!.millisecondsSinceEpoch;
      return clean(observed.body) == clean(r['reply']! as String) &&
          sent >= at - 1000 &&
          sent <= at + 15000 &&
          sent <= capturedAt.millisecondsSinceEpoch + 1000;
    }).toList();
    if (!matches.any((r) => r['state'].toString().startsWith('superseded_'))) {
      return false;
    }
    if (matches.length != 1) {
      final store = await history;
      final document = await store.read(customer);
      final existing = (document?['messages'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((m) =>
              m['id'] == observed.stableId ||
              (m['observed_ids'] as List? ?? const [])
                  .contains(observed.stableId))
          .firstOrNull;
      if (existing?['source'] != 'generated_reply' ||
          existing?['delivery_attempt_id'] == null) {
        await store.confirmObservedOutgoing(
            userId: customer,
            messageId: observed.stableId,
            deliveryStatus: 'ownership_unverified');
      }
      RuntimeTrace.record('delivery.observed_receipt_ambiguous', {
        'customer': customer,
        'messageId': observed.stableId,
        'candidateAttempts': matches.map((m) => m['attempt_id']).toList(),
        'draftsPreserved': true
      });
      return true;
    }
    return _recordDetachedSubmission(matches.single, observed: observed);
  }

  Future<Map<String, String>> beginDeliveryAttempt(
      {required String userId,
      required String reply,
      String? taskId,
      String? expectedResponseCycleId}) async {
    final db = await database;
    final attempt = _taskId();
    final directory =
        Directory(p.join((await storageRoot).path, 'delivery_receipts'));
    await directory.create(recursive: true);
    int? mediaRevision;
    String? scopedGuardPath;
    await db.transaction((txn) async {
      final rows = await txn.query('generated_drafts',
          where:
              "user_id=? AND reply=? AND delivery_state IN ('ready','retry')",
          whereArgs: [userId, reply],
          limit: 1);
      if (rows.isEmpty ||
          (taskId != null && rows.single['task_id'] != taskId)) {
        throw StateError('Delivery task invalidated');
      }
      final row = rows.single;
      if (!await _draftInputsCurrent(txn, userId, row)) {
        throw StateError('reply_inputs_changed_before_insertion');
      }
      if (!await _draftMediaInputsReady(txn, userId, row)) {
        throw StateError('reply_media_inputs_not_ready_before_insertion');
      }
      final raw = jsonDecode(row['raw_json']! as String) as Map;
      if (!_hasCompletedApiProof(row)) {
        final dependencies = await _scopedMediaDependencyKeys(txn, userId, raw);
        final snapshot = AiDraft.fromJson(Map<String, dynamic>.from(raw),
                mediaBaseUrl: Uri())
            .mediaContextRevision;
        if (dependencies != null) {
          if (!await _mediaDependencyKeysCurrent(txn, userId, raw)) {
            throw StateError('media_context_changed_before_insertion');
          }
          if (dependencies.isNotEmpty) {
            mediaRevision = 1;
            final root = await storageRoot;
            await DeliveryContextGuard.publishScoped(root, userId, attempt, 1);
            scopedGuardPath =
                DeliveryContextGuard.scopedFile(root, userId, attempt).path;
          }
        } else if (snapshot != null) {
          final versions = await txn.query('customer_media_versions',
              where: 'customer=?', whereArgs: [userId]);
          final current = versions.isEmpty ? 0 : versions.single['revision'];
          if (snapshot != current) {
            throw StateError('media_context_changed_before_insertion');
          }
          mediaRevision = snapshot;
          await DeliveryContextGuard.publish(
              await storageRoot, userId, snapshot);
        }
      }

      final id = row['task_id']?.toString() ?? _taskId();
      final now = DateTime.now().millisecondsSinceEpoch;
      final cursor = await txn
          .query('answered_cursors', where: 'user_id=?', whereArgs: [userId]);
      final inputBoundary = await txn.query('pending_customers',
          columns: ['newest_message_id'],
          where: 'user_id=?',
          whereArgs: [userId]);
      final responseCycle = expectedResponseCycleId ??
          (await txn.query('platform_response_cycles',
                  columns: ['cycle_id'],
                  where:
                      "user_id=? AND identity_verified=1 AND state='waiting'",
                  whereArgs: [userId]))
              .firstOrNull?['cycle_id'];
      await txn.insert('delivery_attempts', {
        'attempt_id': attempt,
        'task_id': id,
        'user_id': userId,
        'pending_id': row['pending_id'],
        'reply': reply,
        'raw_json':
            jsonEncode({...raw, _nativeResponseCycleKey: responseCycle}),
        'batch_end_message_id': row['batch_end_message_id'],
        'prior_cursor': cursor.firstOrNull?['message_id'],
        'input_boundary_id': inputBoundary.firstOrNull?['newest_message_id'] ??
            row['batch_end_message_id'],
        'state': 'sending',
        'created_at_ms': now,
        'updated_at_ms': now
      });
      await txn.update('generated_drafts',
          {'task_id': id, 'attempt_id': attempt, 'delivery_state': 'sending'},
          where: 'user_id=?', whereArgs: [userId]);
    });
    RuntimeTrace.record('delivery.attempt_started',
        {'customer': userId, 'attemptId': attempt, 'taskId': taskId});
    return {
      'attemptId': attempt,
      'receiptPath': p.join(directory.path, '$attempt.json'),
      if (mediaRevision != null) 'mediaRevision': mediaRevision.toString(),
      if (mediaRevision != null)
        'mediaGuardPath': scopedGuardPath ??
            DeliveryContextGuard.file(await storageRoot, userId).path
    };
  }

  Future<Map<String, String>> beginSlaAttempt(SlaFallbackJob job, String reply,
      {bool yieldToReadyReply = false,
      bool readyReplyMustBeWithinResponseWindow = false}) async {
    final db = await database;
    final attempt = _taskId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final directory =
        Directory(p.join((await storageRoot).path, 'delivery_receipts'));
    await directory.create(recursive: true);
    final created = await db.transaction((txn) async {
      final rows = await txn.query('sla_fallbacks',
          where: "user_id=? AND message_id=? AND state='sending'",
          whereArgs: [job.userId, job.messageId]);
      if (rows.isEmpty) throw StateError('SLA lease invalidated');
      final expectedResponseCycleId =
          job.messageId.startsWith('response-cycle:') ? job.messageId : null;
      final requireWindow = readyReplyMustBeWithinResponseWindow ||
          expectedResponseCycleId != null;
      final responseWindowFilter =
          requireWindow ? ' AND $_replyWithinResponseWindowSql' : '';
      final responseCycleFilter = expectedResponseCycleId == null
          ? ''
          : ' AND $_replyForExpectedResponseCycleSql';
      var deliverableReply = false;
      if (yieldToReadyReply) {
        final candidates = await txn.query('generated_drafts',
            where:
                "user_id=? AND (delivery_state='ready' OR (delivery_state='retry' AND retry_at_ms<=?)) AND $_readyReplyCustomerGuardSql$responseWindowFilter$responseCycleFilter",
            whereArgs: [
              job.userId,
              now,
              if (requireWindow) ...[
                holdingDelay.inMilliseconds,
                holdingDelay.inMilliseconds
              ],
              if (expectedResponseCycleId != null) expectedResponseCycleId,
            ]);
        for (final candidate in candidates) {
          if (await _draftCanSuppressSla(txn, job.userId, candidate)) {
            deliverableReply = true;
            break;
          }
        }
      }
      if (deliverableReply) {
        await txn.update('sla_fallbacks', {'state': 'pending'},
            where: "user_id=? AND message_id=? AND state='sending'",
            whereArgs: [job.userId, job.messageId]);
        return false;
      }
      final inputBoundary = await txn.query('pending_customers',
          columns: ['newest_message_id'],
          where: 'user_id=?',
          whereArgs: [job.userId]);
      final prepared = await txn.query('generated_drafts',
          columns: ['batch_end_message_id'],
          where: 'user_id=?',
          whereArgs: [job.userId]);
      await txn.insert('delivery_attempts', {
        'attempt_id': attempt,
        'task_id': job.batchStartMessageId ?? job.messageId,
        'user_id': job.userId,
        'pending_id': 0,
        'reply': reply,
        'raw_json': '{}',
        'batch_end_message_id': job.messageId,
        'input_boundary_id': inputBoundary.firstOrNull?['newest_message_id'] ??
            prepared.firstOrNull?['batch_end_message_id'],
        'state': 'sending',
        'created_at_ms': now,
        'updated_at_ms': now,
        'kind': 'sla'
      });
      await txn.update('sla_fallbacks', {'attempt_id': attempt},
          where: 'user_id=?', whereArgs: [job.userId]);
      return true;
    });
    if (!created) return {};
    return {
      'attemptId': attempt,
      'receiptPath': p.join(directory.path, '$attempt.json')
    };
  }

  /// A ready-looking row blocked by parsing/material gates cannot also block
  /// the holding response. Recheck inside the SLA reservation transaction;
  /// never call the delivery reader here, since it owns another transaction.
  Future<bool> _draftCanSuppressSla(
      DatabaseExecutor txn, String customer, Map<String, Object?> row) async {
    final AiDraft draft;
    final Map raw;
    try {
      raw = jsonDecode(row['raw_json']! as String) as Map;
      draft =
          AiDraft.fromJson(Map<String, dynamic>.from(raw), mediaBaseUrl: Uri());
    } catch (_) {
      return false;
    }
    if (draft.reply.trim().isEmpty || row['reply'] != draft.reply) return false;
    if (!await _draftInputsCurrent(txn, customer, row) ||
        !await _draftMediaInputsReady(txn, customer, row)) {
      return false;
    }
    if (_mediaDependencyKeys(raw) != null) {
      if (!await _mediaDependencyKeysCurrent(txn, customer, raw)) return false;
    } else if (draft.mediaContextRevision != null) {
      final versions = await txn.query('customer_media_versions',
          where: 'customer=?', whereArgs: [customer]);
      final revision = versions.firstOrNull?['revision'] ?? 0;
      if (draft.mediaContextRevision != revision) return false;
    }
    final pending = (await txn.query('pending_customers',
            columns: ['newest_message_id'],
            where: 'user_id=?',
            whereArgs: [customer]))
        .firstOrNull;
    return pending == null ||
        pending['newest_message_id'] == row['batch_end_message_id'] ||
        !ResponseTimingPolicy.isTrivialAcknowledgement(draft.reply);
  }

  Future<bool> noteObservedRejection(
      {required String customer,
      required String body,
      required String fingerprint,
      required DateTime capturedAt}) async {
    String clean(String text) => text.replaceAll(RegExp(r'\s+'), '');
    if (clean(body).length < 4) return false;
    final rows = await (await database).query('delivery_attempts',
        where:
            "user_id=? AND state IN ('submitted','accepted') AND kind='reply' AND created_at_ms<=?",
        whereArgs: [customer, capturedAt.millisecondsSinceEpoch],
        orderBy: 'created_at_ms DESC',
        limit: 50);
    final matching =
        rows.where((r) => clean(r['reply']! as String) == clean(body)).toList();
    if (matching.length != 1 || matching.single['state'] == 'accepted') {
      return false;
    }
    final row = matching.single;
    final file = File(p.join((await storageRoot).path, 'delivery_receipts',
        '${row['attempt_id']}.json'));
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'attemptId': row['attempt_id'],
          'customer': customer,
          'state': 'late_rejection_uncertain',
          'timeMs': DateTime.now().millisecondsSinceEpoch,
          'error': 'background_failed_bubble_exact_text'
        }),
        flush: true);
    await temp.rename(file.path);
    await (await database).update('delivery_attempts', {'last_checked_ms': 0},
        where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
    await ownFailedOutgoing(customer, fingerprint);
    RuntimeTrace.record('delivery.background_rejection_attributed', {
      'customer': customer,
      'attemptId': row['attempt_id'],
      'fingerprint': fingerprint,
      'attribution': 'unique_submitted_exact_body',
      'action': 'reconcile_without_retyping'
    });
    return true;
  }

  Future<void> recoverDeliveryReceipts() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query('delivery_attempts',
        where:
            "state IN ('sending','recovered_waiting','unknown','submitted','rejected_waiting','superseded_unknown','superseded_submitted','superseded_not_sent','superseded_rejected') AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts archived WHERE archived.attempt_id=delivery_attempts.attempt_id)",
        orderBy: 'last_checked_ms ASC, created_at_ms DESC',
        limit: 100);
    for (final selected in rows) {
      var row = selected;
      try {
        await db.update('delivery_attempts', {'last_checked_ms': now},
            where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
        final file = File(p.join((await storageRoot).path, 'delivery_receipts',
            '${row['attempt_id']}.json'));
        if (!await file.exists()) {
          if (row['state'] == 'recovered_waiting') {
            if (row['kind'] == 'sla') {
              await db.update('sla_fallbacks', {'state': 'pending'},
                  where: 'user_id=? AND attempt_id=?',
                  whereArgs: [row['user_id'], row['attempt_id']]);
            } else {
              await db.update(
                  'generated_drafts',
                  {
                    'delivery_state': 'retry',
                    'retry_at_ms': now,
                    'last_error': 'native_not_started_before_restart'
                  },
                  where: 'user_id=? AND attempt_id=?',
                  whereArgs: [row['user_id'], row['attempt_id']]);
            }
            await db.update('delivery_attempts', {'state': 'not_sent'},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          }
          continue;
        }
        Map<String, dynamic> receipt;
        try {
          receipt =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        // Reading native evidence yields to the drain. It may have detached
        // this attempt during IO, so routing must use current ownership.
        final latest = (await db.query('delivery_attempts',
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]))
            .firstOrNull;
        if (latest == null) continue;
        row = latest;
        if (receipt['attemptId'] != row['attempt_id'] ||
            receipt['customer'] != row['user_id']) {
          continue;
        }
        if ((await db.query('automation_archived_attempts',
                columns: ['attempt_id'],
                where: 'attempt_id=?',
                whereArgs: [row['attempt_id']]))
            .isNotEmpty) {
          await db.update('automation_archived_attempts',
              {'latest_receipt_json': jsonEncode(receipt)},
              where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          await db.update(
              'delivery_attempts', {'receipt_seen_ms': receipt['timeMs'] ?? 0},
              where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          continue;
        }
        if (receipt['state'] == 'unknown' && row['kind'] != 'sla') {
          if (row['state'].toString().startsWith('superseded_')) continue;
          final changed = await db.transaction((txn) async {
            final count = await txn.update(
                'generated_drafts',
                {
                  'delivery_state': 'delivery_unknown',
                  'last_error':
                      'send_unconfirmed: ${receipt['error'] ?? 'native_unknown'}'
                },
                where:
                    "user_id=? AND task_id=? AND attempt_id=? AND delivery_state IN ('sending','retry','ready') AND EXISTS(SELECT 1 FROM delivery_attempts a WHERE a.attempt_id=generated_drafts.attempt_id AND a.state NOT IN ('accepted','submitted') AND a.state NOT LIKE 'superseded_%')",
                whereArgs: [row['user_id'], row['task_id'], row['attempt_id']]);
            await txn.update(
                'delivery_attempts',
                {
                  'state': 'unknown',
                  'receipt_seen_ms': receipt['timeMs'] ?? 0,
                  'updated_at_ms': now
                },
                where:
                    "attempt_id=? AND state NOT IN ('accepted','submitted') AND state NOT LIKE 'superseded_%'",
                whereArgs: [row['attempt_id']]);
            return count;
          });
          if (changed > 0) {
            RuntimeTrace.record('delivery.unknown_recovered', {
              'customer': row['user_id'],
              'attemptId': row['attempt_id'],
              'action': 'reconcile_without_retyping'
            });
          }
          continue;
        }
        if (row['state'] != 'rejected_waiting' &&
            (receipt['timeMs'] as num? ?? 0).toInt() <=
                (row['receipt_seen_ms'] as int? ?? 0)) {
          continue;
        }
        final phase = receipt['state'];
        final user = row['user_id']! as String;
        if (row['state'].toString().startsWith('superseded_')) {
          if (phase == 'submitted') {
            if (await _recordDetachedSubmission(row)) {
              await _settleUncertainDeliveryHold(
                  db, row['attempt_id']! as String, 'confirmed',
                  receipt: receipt);
            }
            await db.update('delivery_attempts',
                {'receipt_seen_ms': receipt['timeMs'] ?? 0},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          } else if (phase == 'not_sent' || phase == 'rejected') {
            if (phase == 'rejected') {
              await (await history).markAttemptRejected(
                  userId: user, attemptId: row['attempt_id']! as String);
            }
            await db.update(
                'delivery_attempts',
                {
                  'state': 'superseded_$phase',
                  'receipt_seen_ms': receipt['timeMs'] ?? 0
                },
                where:
                    "attempt_id=? AND state IN ('superseded_unknown','superseded_submitted','superseded_not_sent','superseded_rejected')",
                whereArgs: [row['attempt_id']]);
            await _settleUncertainDeliveryHold(
                db, row['attempt_id']! as String, 'proven_not_sent',
                receipt: receipt);
            RuntimeTrace.record('delivery.detached_attempt_not_sent', {
              'customer': user,
              'attemptId': row['attempt_id'],
              'phase': phase,
              'newerBatchPreserved': true
            });
          } else if (phase == 'late_rejection_uncertain' ||
              phase == 'unknown') {
            await _settleUncertainDeliveryHold(
                db, row['attempt_id']! as String, 'unknown',
                receipt: receipt);
            await db.update('delivery_attempts',
                {'receipt_seen_ms': receipt['timeMs'] ?? 0},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          }
          continue;
        }
        if (phase == 'submitted') {
          final created = row['created_at_ms']! as int;
          final written = (receipt['timeMs'] as num?)?.toInt() ?? created;
          final nativeClick = receipt['sendClickedAtMs'];
          final validClick = nativeClick is num &&
              nativeClick.isFinite &&
              nativeClick >= created - 1000 &&
              nativeClick <= written + 1000;
          final clickMs =
              validClick ? nativeClick.toInt() : max(created, written);
          await confirmPlatformResponse(
              user, DateTime.fromMillisecondsSinceEpoch(clickMs),
              attemptId: row['attempt_id'] as String,
              timeSource: validClick ? 'native_click' : 'native_confirmation');
          RuntimeTrace.record('delivery.receipt_clock_reconciled', {
            'customer': user,
            'attemptId': row['attempt_id'],
            'source': validClick ? 'native_click' : 'legacy_confirmation',
            'responseStartedMs': clickMs
          });
        }
        if (phase == 'rejected' || phase == 'not_sent') {
          await rejectPlatformResponse(user, row['attempt_id']! as String);
        }
        if (row['kind'] == 'sla') {
          if (phase == 'submitted') {
            await markSlaFallbackSent(
                userId: user,
                messageId: row['batch_end_message_id']! as String,
                batchStartMessageId: row['task_id']! as String,
                reply: row['reply']! as String,
                nativeConfirmed: true);
            await db.update('delivery_attempts',
                {'state': 'submitted', 'receipt_seen_ms': receipt['timeMs']},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          } else if (phase == 'not_sent' ||
              (phase == 'prepared' && row['state'] == 'recovered_waiting')) {
            await db.update('sla_fallbacks', {'state': 'pending'},
                where: 'user_id=? AND attempt_id=?',
                whereArgs: [user, row['attempt_id']]);
            await db.update('delivery_attempts',
                {'state': 'not_sent', 'receipt_seen_ms': receipt['timeMs']},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          } else if (phase == 'late_rejection_uncertain' ||
              phase == 'unknown') {
            await db.update('sla_fallbacks', {'state': 'reconciling'},
                where: "user_id=? AND attempt_id=? AND state!='completed'",
                whereArgs: [user, row['attempt_id']]);
            await db.update('delivery_attempts',
                {'state': 'unknown', 'receipt_seen_ms': receipt['timeMs']},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          } else if (phase == 'rejected') {
            await db.delete('sla_delivery_receipts',
                where: 'user_id=? AND batch_start_message_id=?',
                whereArgs: [user, row['task_id']]);
            await db.update('sla_fallbacks',
                {'state': 'pending', 'retry_at_ms': now + 3000},
                where: "user_id=? AND attempt_id=? AND state!='completed'",
                whereArgs: [user, row['attempt_id']]);
            await db.update('delivery_attempts',
                {'state': 'rejected', 'receipt_seen_ms': receipt['timeMs']},
                where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
          }
          continue;
        }
        final drafts = await db
            .query('generated_drafts', where: 'user_id=?', whereArgs: [user]);
        final current = drafts.firstOrNull;
        if (phase == 'submitted') {
          if (current?['attempt_id'] == row['attempt_id']) {
            await markReplySent(
                userId: user,
                reply: row['reply']! as String,
                expectedTaskId: row['task_id']! as String);
          }
          if (row['state'] != 'submitted') {
            final changed = await db.update('delivery_attempts',
                {'state': 'submitted', 'updated_at_ms': now},
                where: "attempt_id=? AND state NOT LIKE 'superseded_%'",
                whereArgs: [row['attempt_id']]);
            if (changed == 0) continue;
          }
        } else if (phase == 'not_sent' ||
            (phase == 'prepared' && row['state'] == 'recovered_waiting')) {
          if (current?['attempt_id'] == row['attempt_id']) {
            await db.update(
                'generated_drafts',
                {
                  'delivery_state': 'retry',
                  'retry_at_ms': now,
                  'last_error': 'native_not_sent'
                },
                where: 'user_id=? AND task_id=? AND attempt_id=?',
                whereArgs: [user, row['task_id'], row['attempt_id']]);
          }
          final changed = await db.update(
              'delivery_attempts', {'state': 'not_sent', 'updated_at_ms': now},
              where: "attempt_id=? AND state NOT LIKE 'superseded_%'",
              whereArgs: [row['attempt_id']]);
          if (changed == 0) continue;
        } else if (phase == 'rejected' || phase == 'late_rejection_uncertain') {
          if (await isHumanContacting(user)) continue;
          if (current != null && current['task_id'] != row['task_id']) {
            await db.update('delivery_attempts', {'state': 'rejected_waiting'},
                where: "attempt_id=? AND state NOT LIKE 'superseded_%'",
                whereArgs: [row['attempt_id']]);
            continue;
          }
          await (await history).markAttemptRejected(
              userId: user, attemptId: row['attempt_id']! as String);
          final recovered = await db.transaction((txn) async {
            final live = (await txn.query('delivery_attempts',
                    where: 'attempt_id=?', whereArgs: [row['attempt_id']]))
                .firstOrNull;
            if (live == null ||
                live['state'].toString().startsWith('superseded_')) {
              return false;
            }
            final slot = (await txn.query('generated_drafts',
                    where: 'user_id=?', whereArgs: [user]))
                .firstOrNull;
            if (slot != null && slot['task_id'] != row['task_id']) return false;
            await _reopenRejectedInputs(
                txn, user, row['attempt_id']! as String);
            final cursor = await txn.query('answered_cursors',
                where: 'user_id=?', whereArgs: [user]);
            if (cursor.firstOrNull?['message_id'] ==
                row['batch_end_message_id']) {
              if (row['prior_cursor'] == null) {
                await txn.delete('answered_cursors',
                    where: 'user_id=?', whereArgs: [user]);
              } else {
                await txn.update(
                    'answered_cursors', {'message_id': row['prior_cursor']},
                    where: 'user_id=?', whereArgs: [user]);
              }
            }
            await txn.insert(
                'generated_drafts',
                {
                  'user_id': user,
                  'pending_id': row['pending_id'],
                  'reply': row['reply'],
                  'model': 'recovered',
                  'raw_json': row['raw_json'],
                  'created_at_ms': row['created_at_ms'],
                  'task_id': row['task_id'],
                  'attempt_id': row['attempt_id'],
                  'batch_end_message_id': row['batch_end_message_id'],
                  'delivery_state':
                      phase == 'rejected' ? 'retry' : 'delivery_unknown',
                  'retry_at_ms': now + 3000,
                  'last_error': phase == 'rejected'
                      ? 'send_platform_rejected'
                      : 'send_unconfirmed: late rejection needs receipt'
                },
                conflictAlgorithm: ConflictAlgorithm.replace);
            await txn.update(
                'delivery_attempts',
                {
                  'state': phase == 'rejected' ? 'rejected' : 'unknown',
                  'updated_at_ms': now
                },
                where: 'attempt_id=?',
                whereArgs: [row['attempt_id']]);
            return true;
          });
          if (!recovered) continue;
          RuntimeTrace.record('delivery.rejection_recovered', {
            'customer': user,
            'attemptId': row['attempt_id'],
            'phase': phase
          });
        }
        await db.update(
            'delivery_attempts', {'receipt_seen_ms': receipt['timeMs'] ?? 0},
            where: 'attempt_id=?', whereArgs: [row['attempt_id']]);
      } catch (error) {
        if (error is DatabaseException) rethrow;
        try {
          await (await history).lastMessages(row['user_id']! as String);
        } catch (historyError) {
          await _recordHistoryFault(row['user_id']! as String, historyError);
        }
        RuntimeTrace.record('delivery.receipt_recovery_failed', {
          'customer': row['user_id'],
          'attemptId': row['attempt_id'],
          'errorType': error.runtimeType.toString()
        });
      }
    }
    await _restoreKnownUnsentHeldDrafts();
  }

  Future<void> reconcileOrphanSla(String userId) async {
    final db = await database;
    final rows = await db.query('sla_fallbacks',
        where: "user_id=? AND state='reconciling'", whereArgs: [userId]);
    if (rows.isEmpty) return;
    final row = rows.single;
    if ((row['batch_start_message_id'] as String? ?? '')
        .startsWith('response-cycle:')) {
      return;
    }
    final started = (row['batch_started_at_ms'] as int?) ?? 0;
    final messages =
        ((await (await history).read(userId))?['messages'] as List<Object?>? ??
                [])
            .whereType<Map<String, dynamic>>();
    final observed = messages
        .where((m) =>
            m['direction'] == 'outgoing' &&
            isRecoveryReply(m['body']) &&
            m['delivery_status'] == 'sent' &&
            (DateTime.tryParse(m['sent_at']?.toString() ?? '')
                        ?.millisecondsSinceEpoch ??
                    0) >=
                started)
        .firstOrNull;
    if (observed != null) {
      await markSlaFallbackSent(
          userId: userId,
          messageId: row['message_id']! as String,
          batchStartMessageId:
              (row['batch_start_message_id'] ?? row['message_id'])! as String,
          reply: observed['body']! as String,
          nativeConfirmed: true);
    }
  }

  Future<bool> hasReadyDeliveryFor(String customer) async {
    final rows = await (await database).rawQuery(
        "SELECT 1 FROM generated_drafts WHERE user_id=? AND (delivery_state='ready' OR (delivery_state='retry' AND retry_at_ms<=?)) LIMIT 1",
        [customer, DateTime.now().millisecondsSinceEpoch]);
    return rows.isNotEmpty;
  }

  Future<bool> hasReadyDeliveryWork() async {
    final rows = await (await database).rawQuery(
        "SELECT 1 FROM generated_drafts WHERE (delivery_state='ready' OR (delivery_state='retry' AND retry_at_ms<=?)) AND user_id NOT IN(SELECT user_id FROM customer_storage_faults) AND user_id NOT IN(SELECT user_id FROM unavailable_conversations) AND user_id NOT IN(SELECT user_id FROM conversation_control WHERE state='human_contacting' OR state LIKE 'handoff_%') LIMIT 1",
        [DateTime.now().millisecondsSinceEpoch]);
    return rows.isNotEmpty;
  }

  Future<DateTime?> nextDeliveryWakeAt() async {
    final rows = await (await database).rawQuery(
        "SELECT MIN(retry_at_ms) AS at FROM generated_drafts WHERE delivery_state='retry' AND user_id NOT IN(SELECT user_id FROM customer_storage_faults) AND user_id NOT IN(SELECT user_id FROM unavailable_conversations) AND user_id NOT IN(SELECT user_id FROM conversation_control WHERE state='human_contacting' OR state LIKE 'handoff_%')");
    final value = rows.single['at'];
    return value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }

  Future<void> _addColumnIfMissing(
      Database db, String table, String definition) async {
    final column = definition.split(' ').first;
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty) return;
    if (columns.any((row) => row['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $definition');
  }

  Future<void> _createCaptureEvidence(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS capture_session_archive(
      session_id TEXT NOT NULL,table_name TEXT NOT NULL,row_key TEXT NOT NULL,
      payload TEXT NOT NULL,archived_at_ms INTEGER NOT NULL,
      PRIMARY KEY(session_id,table_name,row_key))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS media_inventory_run(
      id INTEGER PRIMARY KEY,started_ms INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS customer_media_items(
      item_id TEXT PRIMARY KEY,customer TEXT NOT NULL,sender_ms INTEGER,slot INTEGER NOT NULL,
      kind TEXT NOT NULL,state TEXT NOT NULL,first_seen_ms INTEGER NOT NULL,last_seen_ms INTEGER NOT NULL,
      evidence_id TEXT,message_id TEXT,visual_fingerprint TEXT,identity_ambiguous INTEGER NOT NULL DEFAULT 0,media_json TEXT NOT NULL,aliases_json TEXT NOT NULL)''');
    await _addColumnIfMissing(db, 'customer_media_items', 'canonical_id TEXT');
    await _addColumnIfMissing(db, 'customer_media_items', 'admission_key TEXT');
    await _addColumnIfMissing(
        db, 'customer_media_items', 'admission_session_id TEXT');
    await _addColumnIfMissing(
        db, 'customer_media_items', 'admitted_at_ms INTEGER');
    await db
        .execute('''CREATE UNIQUE INDEX IF NOT EXISTS customer_media_admission
      ON customer_media_items(customer,admission_session_id,admission_key)
      WHERE admission_key IS NOT NULL AND admission_session_id IS NOT NULL''');

    await db.execute('''CREATE TABLE IF NOT EXISTS customer_media_versions(
      customer TEXT PRIMARY KEY,revision INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS media_card_observations(
      observation_id TEXT PRIMARY KEY,item_id TEXT NOT NULL,customer TEXT NOT NULL,
      evidence_id TEXT NOT NULL,observed_ms INTEGER NOT NULL,region_json TEXT NOT NULL,
      classified_kind TEXT,fingerprint TEXT,classified_ms INTEGER,canonical_id TEXT,preview_path TEXT)''');
    await _addColumnIfMissing(
        db, 'media_card_observations', 'preview_path TEXT');
    await db.execute('''CREATE INDEX IF NOT EXISTS media_card_observations_card
      ON media_card_observations(customer,item_id,evidence_id)''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS customer_media_items_customer ON customer_media_items(customer,sender_ms)');
    await db.execute('''CREATE TABLE IF NOT EXISTS media_capture_audit(
      observation_id TEXT PRIMARY KEY, evidence_id TEXT NOT NULL,
      customer TEXT NOT NULL, state TEXT NOT NULL, details TEXT NOT NULL,
      updated_at_ms INTEGER NOT NULL)''');
    await db.execute('''CREATE INDEX IF NOT EXISTS media_capture_audit_evidence
      ON media_capture_audit(evidence_id,state)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS capture_observations(
      customer TEXT PRIMARY KEY, first_seen_ms INTEGER NOT NULL, state TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS capture_evidence(
      id TEXT PRIMARY KEY, customer TEXT NOT NULL, captured_at_ms INTEGER NOT NULL,
      payload TEXT NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      retry_at_ms INTEGER NOT NULL DEFAULT 0, last_error TEXT)''');
    await _addColumnIfMissing(db, 'capture_evidence',
        'discovery_requires_baseline INTEGER NOT NULL DEFAULT 0');
    await db.execute('''CREATE TABLE IF NOT EXISTS capture_backfill(
      customer TEXT PRIMARY KEY, cutoff_ms INTEGER NOT NULL, pages INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'pending', restore_needed INTEGER NOT NULL DEFAULT 0,
      step_pixels INTEGER NOT NULL DEFAULT 400,
      retry_at_ms INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0)''');
    final backfillColumns =
        (await db.rawQuery('PRAGMA table_info(capture_backfill)'))
            .map((row) => row['name'])
            .toSet();
    for (final column in ['retry_at_ms', 'failures']) {
      if (!backfillColumns.contains(column)) {
        await db.execute(
            'ALTER TABLE capture_backfill ADD COLUMN $column INTEGER NOT NULL DEFAULT 0');
      }
    }
    if (!backfillColumns.contains('page_limit')) {
      await db.execute(
          'ALTER TABLE capture_backfill ADD COLUMN page_limit INTEGER NOT NULL DEFAULT 3');
    }
    if (!backfillColumns.contains('oldest_seen_ms')) {
      await db.execute(
          'ALTER TABLE capture_backfill ADD COLUMN oldest_seen_ms INTEGER');
    }
    await db.execute('''CREATE INDEX IF NOT EXISTS capture_evidence_pending
      ON capture_evidence(state,retry_at_ms,captured_at_ms)''');
    await db
        .execute('''CREATE INDEX IF NOT EXISTS capture_evidence_customer_order
      ON capture_evidence(customer,captured_at_ms,id,state)''');
  }

  Future<void> _createUnavailableConversations(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS unavailable_conversations (
      user_id TEXT PRIMARY KEY, failed_at_ms INTEGER NOT NULL, reason TEXT NOT NULL,
      next_probe_at_ms INTEGER NOT NULL DEFAULT 0,
      probe_attempts INTEGER NOT NULL DEFAULT 0)''');
    await _addColumnIfMissing(db, 'unavailable_conversations',
        'next_probe_at_ms INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'unavailable_conversations',
        'probe_attempts INTEGER NOT NULL DEFAULT 0');
    await db.execute('''CREATE TABLE IF NOT EXISTS draft_owned_failures (
      user_id TEXT NOT NULL, fingerprint TEXT NOT NULL, recorded_at_ms INTEGER NOT NULL,
      PRIMARY KEY(user_id,fingerprint))''');
  }

  /// A suspension is a recoverable lease, never a permanent delivery freeze.
  Future<void> suspendUnavailableConversation(
      String userId, String reason) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final reconciliation = reason == _receiptReconciliationSuspension;
    await (await database).rawInsert(
        '''INSERT INTO unavailable_conversations
      (user_id,failed_at_ms,reason,next_probe_at_ms,probe_attempts)
      SELECT ?,?,?,?,0 WHERE ${reconciliation ? _activeReceiptReconciliationSql : '1'}
      ON CONFLICT(user_id) DO UPDATE SET reason=excluded.reason,
      next_probe_at_ms=MAX(unavailable_conversations.next_probe_at_ms,excluded.next_probe_at_ms)
      ${reconciliation ? 'WHERE unavailable_conversations.reason=excluded.reason' : ''}''',
        [
          userId,
          now,
          reason,
          now + 3000,
          if (reconciliation) ...[userId, userId],
        ]);
  }

  Future<Map<String, Object?>?> claimUnavailableProbe(String userId,
      {DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return (await database).transaction((txn) async {
      final rows = await txn.query('unavailable_conversations',
          where: 'user_id=? AND next_probe_at_ms<=?',
          whereArgs: [userId, at],
          limit: 1);
      if (rows.isEmpty) return null;
      final attempt = (rows.single['probe_attempts'] as int) + 1;
      const seconds = [3, 5, 10, 15];
      final next =
          at + seconds[(attempt - 1).clamp(0, seconds.length - 1)] * 1000;
      await txn.update('unavailable_conversations',
          {'probe_attempts': attempt, 'next_probe_at_ms': next},
          where: 'user_id=?', whereArgs: [userId]);
      final sla = await txn.query('sla_fallbacks',
          columns: ['due_at_ms'], where: 'user_id=?', whereArgs: [userId]);
      return {
        ...rows.single,
        'probe_attempts': attempt,
        'next_probe_at_ms': next,
        'original_deadline_ms': sla.firstOrNull?['batch_started_at_ms'] is int
            ? (sla.first['batch_started_at_ms'] as int) +
                holdingDelay.inMilliseconds
            : sla.firstOrNull?['due_at_ms']
      };
    });
  }

  Future<void> ownFailedOutgoing(String userId, String fingerprint) async {
    await (await database).insert(
        'draft_owned_failures',
        {
          'user_id': userId,
          'fingerprint': fingerprint,
          'recorded_at_ms': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<bool> isDraftOwnedFailure(String userId, String fingerprint) async =>
      (await (await database).query('draft_owned_failures',
              where: 'user_id=? AND fingerprint=?',
              whereArgs: [userId, fingerprint],
              limit: 1))
          .isNotEmpty;

  Future<bool> isConversationUnavailable(String userId) async =>
      (await (await database).query('unavailable_conversations',
              where: 'user_id = ?', whereArgs: [userId], limit: 1))
          .isNotEmpty;

  Future<List<String>> resumeVisibleConversations(Iterable<String> visible,
      {Iterable<String> verifiedActive = const [],
      Iterable<String> deliveryReady = const []}) async {
    final ids = visible.toSet();
    if (ids.isEmpty && verifiedActive.isEmpty && deliveryReady.isEmpty) {
      return const [];
    }
    final db = await database;
    return db.transaction((txn) async {
      final suspended = await txn.query('unavailable_conversations');
      final resumed = suspended
          .where((row) {
            final reason = row['reason']?.toString() ?? '';
            final requiresActive =
                reason.contains('conversation_verification_failed') ||
                    reason.contains('conversation_changed');
            if (reason.contains('customer_not_receiving') ||
                reason.contains('send_platform_rejected')) {
              return deliveryReady.contains(row['user_id']);
            }
            return (requiresActive ? verifiedActive.toSet() : ids)
                .contains(row['user_id']);
          })
          .map((row) => row['user_id']! as String)
          .toList(growable: false);
      for (final id in resumed) {
        await txn.delete('unavailable_conversations',
            where: 'user_id = ?', whereArgs: [id]);
        await txn.update('generated_drafts', {'retry_at_ms': 0},
            where: "user_id = ? AND delivery_state = 'retry'", whereArgs: [id]);
      }
      return resumed;
    });
  }

  Future<void> _createSlaFallbacks(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS sla_fallbacks (
      user_id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL,
      due_at_ms INTEGER NOT NULL,
      state TEXT NOT NULL,
      sent_at_ms INTEGER,
      updated_at_ms INTEGER NOT NULL,
      batch_start_message_id TEXT, batch_started_at_ms INTEGER, batch_clock_verified INTEGER NOT NULL DEFAULT 0
    )''');
    final columns = (await db.rawQuery('PRAGMA table_info(sla_fallbacks)'))
        .map((r) => r['name'])
        .toSet();
    for (final entry in {
      'batch_start_message_id': 'TEXT',
      'batch_started_at_ms': 'INTEGER',
      'batch_clock_verified': 'INTEGER NOT NULL DEFAULT 0'
    }.entries) {
      if (!columns.contains(entry.key)) {
        await db.execute(
            'ALTER TABLE sla_fallbacks ADD COLUMN ${entry.key} ${entry.value}');
      }
    }
    await db.execute('''CREATE INDEX IF NOT EXISTS sla_fallbacks_due
      ON sla_fallbacks(state, due_at_ms)''');
  }

  Future<void> _createTransferWelcomes(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS transfer_welcomes (
      user_id TEXT NOT NULL,
      event_key TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      PRIMARY KEY(user_id, event_key)
    )''');
  }

  Future<bool> hasTransferWelcome(
      {required String userId, required String eventKey}) async {
    final db = await database;
    final rows = await db.query('transfer_welcomes',
        columns: ['user_id'],
        where: 'user_id = ? AND event_key = ?',
        whereArgs: [userId, eventKey],
        limit: 1);
    return rows.isNotEmpty;
  }

  Future<DateTime?> latestTransferNoticeAt(String userId) async {
    final rows = await (await database).query('transfer_welcomes',
        columns: ['created_at_ms'],
        where: 'user_id = ?',
        whereArgs: [userId],
        orderBy: 'created_at_ms DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(
        rows.single['created_at_ms'] as int,
        isUtc: true);
  }

  Future<void> recordTransferWelcome(
      {required String userId, required String eventKey}) async {
    final db = await database;
    await db.insert(
        'transfer_welcomes',
        {
          'user_id': userId,
          'event_key': eventKey,
          'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Atomically reserves a transfer welcome before the send click.
  ///
  /// The exact durable event key prevents a retry after an unconfirmed click.
  /// The UI layer separately suppresses repeated OCR variants while the same
  /// banner remains visible, without blocking a genuinely new transfer.
  Future<bool> reserveTransferWelcome({
    required String userId,
    required String eventKey,
    DateTime? now,
  }) async {
    final db = await database;
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'transfer_welcomes',
        columns: ['user_id'],
        where: 'user_id = ? AND event_key = ?',
        whereArgs: [userId, eventKey],
        limit: 1,
      );
      if (existing.isNotEmpty) return false;
      await txn.insert(
        'transfer_welcomes',
        {
          'user_id': userId,
          'event_key': eventKey,
          'created_at_ms': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return true;
    });
  }

  /// Releases a welcome reservation only when sending failed before JD's Send
  /// control was clicked. Unconfirmed post-click attempts remain reserved to
  /// prevent a duplicate welcome.
  Future<void> releaseTransferWelcomeReservation({
    required String userId,
    required String eventKey,
  }) async {
    final db = await database;
    await db.delete(
      'transfer_welcomes',
      where: 'user_id = ? AND event_key = ?',
      whereArgs: [userId, eventKey],
    );
  }

  Future<void> appendAutomatedNoticeSent(
      {required String userId,
      required String reply,
      String model = 'jd-transfer-welcome-v1'}) async {
    final raw = <String, Object?>{
      'reply': reply,
      'decision': 'draft',
      'confidence': 1.0,
      'used_record_ids': <String>[],
      'required_slots': <String>[],
      'actions': <Object?>[],
      'risk_level': 'low',
      'risk_triggers': <String>[],
      'auto_send_allowed': false,
      'model': model,
      'attachments': <Object?>[],
      'image_descriptions': <Object?>[],
      'human_review_required': false,
      'reason': null,
    };
    await (await history).appendSentReply(
      userId: userId,
      displayName: userId,
      stableKey: userId,
      draft: AiDraft.fromJson(raw, mediaBaseUrl: Uri()),
    );
  }

  Future<void> _createGeneratedDrafts(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS generated_drafts (
      user_id TEXT PRIMARY KEY,
      pending_id INTEGER NOT NULL,
      reply TEXT NOT NULL,
      model TEXT NOT NULL,
      raw_json TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      delivery_state TEXT NOT NULL DEFAULT 'ready',
      delivery_attempts INTEGER NOT NULL DEFAULT 0,
      retry_at_ms INTEGER,
      last_error TEXT,
      batch_end_message_id TEXT
    )''');
  }

  Future<void> _createAnsweredCursors(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS answered_cursors (
      user_id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL
    )''');
  }

  Future<void> _createHumanReview(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS human_review_tickets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      customer_request TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      assigned_to TEXT,
      request_message_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS human_review_queue
      ON human_review_tickets(status, updated_at_ms DESC)''');
    await db.execute('''CREATE TABLE IF NOT EXISTS conversation_control (
      user_id TEXT PRIMARY KEY,
      state TEXT NOT NULL,
      resume_after_message_id TEXT,
      updated_at_ms INTEGER NOT NULL
    )''');
  }

  Future<void> _createChatTransferLogs(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS chat_transfer_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ticket_id INTEGER NOT NULL UNIQUE,
      user_id TEXT NOT NULL,
      source_account TEXT NOT NULL,
      target_account TEXT,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      error TEXT,
      request_message_id TEXT,
      preclick_retry_count INTEGER NOT NULL DEFAULT 0,
      preclick_retry_at_ms INTEGER NOT NULL DEFAULT 0,
      acknowledged INTEGER NOT NULL DEFAULT 0,
      phase TEXT NOT NULL DEFAULT 'legacy',
      attempt_id TEXT,
      transfer_clicked INTEGER NOT NULL DEFAULT 0,
      owner_pid INTEGER,
      journal_seen_ms INTEGER NOT NULL DEFAULT 0,
      attempt_started_at_ms INTEGER,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await _addColumnIfMissing(
        db, 'chat_transfer_logs', 'response_cycle_id TEXT');
    await db.execute('''CREATE INDEX IF NOT EXISTS chat_transfer_log_recent
      ON chat_transfer_logs(updated_at_ms DESC, id DESC)''');
    await db.execute('''CREATE INDEX IF NOT EXISTS chat_transfer_log_target
      ON chat_transfer_logs(status, target_account, updated_at_ms DESC)''');
  }

  /// Schema 28: a retry requires an explicit pre-click phase or a matching
  /// native journal. Status alone cannot distinguish a crash before/after click.
  Future<void> ensureChatTransferRecoveryColumns(Database db) async {
    for (final definition in [
      "phase TEXT NOT NULL DEFAULT 'legacy'",
      'attempt_id TEXT',
      'transfer_clicked INTEGER NOT NULL DEFAULT 0',
      'owner_pid INTEGER',
      'journal_seen_ms INTEGER NOT NULL DEFAULT 0',
      'attempt_started_at_ms INTEGER',
      'response_cycle_id TEXT',
    ]) {
      await _addColumnIfMissing(db, 'chat_transfer_logs', definition);
    }
  }

  Future<void> _createHumanTransferRequests(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS human_transfer_requests (
      user_id TEXT PRIMARY KEY,
      request_count INTEGER NOT NULL,
      first_requested_at_ms INTEGER,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db
        .execute('''CREATE TABLE IF NOT EXISTS human_transfer_request_events (
      user_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      was_repeat INTEGER NOT NULL,
      PRIMARY KEY(user_id, message_id)
    )''');
  }

  /// Legacy observation audit. Always returns false; request counts and local
  /// customer text cannot authorize automatic handoff.
  Future<bool> recordHumanTransferRequest({
    required String userId,
    required String messageId,
    required DateTime requestedAt,
    Iterable<String> messageAliases = const [],
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final identities = {messageId, ...messageAliases};
      final priorEvent = await txn.query('human_transfer_request_events',
          columns: ['was_repeat'],
          where: 'user_id = ? AND message_id IN '
              '(${List.filled(identities.length, '?').join(',')})',
          whereArgs: [userId, ...identities],
          limit: 1);
      if (priorEvent.isNotEmpty) {
        // Canonicalization may discover a new identity for an existing input.
        // Keep the whole identity set in the observation audit.
        for (final identity in identities) {
          await txn.insert(
              'human_transfer_request_events',
              {
                'user_id': userId,
                'message_id': identity,
                'was_repeat': 0,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        return false;
      }

      // Kept only as an idempotent observation audit for legacy callers.
      // Automatic transfer authority comes exclusively from the API action.
      for (final identity in identities) {
        await txn.insert('human_transfer_request_events', {
          'user_id': userId,
          'message_id': identity,
          'was_repeat': 0,
        });
      }
      return false;
    });
  }

  Future<void> _createPendingQueue(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS pending_customers (
      id INTEGER PRIMARY KEY,
      user_id TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      stable_key TEXT NOT NULL,
      newest_message_id TEXT NOT NULL,
      enqueued_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )''');
    await db.execute('''CREATE INDEX IF NOT EXISTS pending_customers_oldest
      ON pending_customers(enqueued_at_ms ASC, id ASC)''');
  }

  Future<int> saveCapture(CapturedConversation capture,
      {bool isCurrentViewport = true,
      bool activateReplies = true,
      Set<String>? activeIncomingIds,
      Map<String, Set<String>> mediaInputDependencies = const {},
      String? dependencyEvidenceId,
      Set<String> manualCoverageExcludedIds = const {}}) async {
    if (mediaInputDependencies.isNotEmpty &&
        (dependencyEvidenceId == null || dependencyEvidenceId.isEmpty)) {
      throw ArgumentError('media_dependency_requires_immutable_evidence');
    }
    final ownerSession = _automationSessionId;
    final store = await history;
    final userId = capture.customerExternalId ?? capture.customerName;
    if (activeIncomingIds != null) {
      final selected = activeIncomingIds;
      activeIncomingIds = {
        ...selected,
        for (final message in capture.messages)
          if (message.direction == 'incoming' &&
              message.sentAt != null &&
              selected.contains(message.stableId))
            CustomerMessageTime.incomingId(userId, message.sentAt!),
      };
    }
    final answeredIds = await _formallyAnsweredIds(userId);
    if (ownerSession != null && activateReplies && activeIncomingIds != null) {
      for (final text in capture.messages.where((m) =>
          m.direction == 'incoming' &&
          m.sentAt != null &&
          m.media.isEmpty &&
          m.mediaReceiptId == null &&
          m.captureEvidenceId != null &&
          m.observationTurnKey?.startsWith('ocr-bubble:') == true &&
          activeIncomingIds!.contains(m.stableId))) {
        final parent =
            await store.incomingMessageIdAtTime(userId, text.sentAt!);
        if (parent == null) continue;
        final document = await store.read(userId);
        final existing = (document?['messages'] as List? ?? const [])
            .whereType<Map>()
            .where((m) => m['id'] == parent)
            .firstOrNull;
        final receipt = existing?['media_receipt_id'];
        if (receipt is! String) continue;
        // These IDs came from the upstream non-media text mask. Time joins
        // that already verified body to its owner; it never turns unmasked
        // photo/video pixels into text, and the old classified-kind gate stays.
        await clarifyUnknownMessageAsText(userId,
            parentMessageId: parent,
            receiptId: receipt,
            text: text,
            evidenceId: text.captureEvidenceId!,
            expectedSessionId: ownerSession);
      }
    }
    final verifiedReceipts = <String>{};
    for (final message in capture.messages) {
      final receipt = message.mediaReceiptId;
      if (receipt != null &&
          message.media.isEmpty &&
          await _receiptHasRealMediaProof(await database, userId, receipt)) {
        verifiedReceipts.add(receipt);
      }
    }
    final result = await store.appendCapture(capture,
        historyOnly: !activateReplies,
        activeIncomingIds: activeIncomingIds,
        formallyAnsweredIds: answeredIds,
        verifiedMediaReceiptIds: verifiedReceipts);
    final db = await database;
    if (ownerSession != _automationSessionId ||
        (_automationSessionStartedAt != null &&
            capture.capturedAt.isBefore(_automationSessionStartedAt!))) {
      return result.changed;
    }
    await _registerSessionCapture(
        capture, [...result.insertedIncomingIds, ...result.insertedOutgoingIds],
        activateReplies: activateReplies,
        activeIncomingIds: activeIncomingIds,
        mediaInputDependencies: mediaInputDependencies,
        dependencyEvidenceId: dependencyEvidenceId);
    final timed = capture.messages
        .where((m) => m.direction == 'incoming' && m.sentAt != null);
    for (final observed in timed) {
      final canonical =
          await store.incomingMessageIdAtTime(userId, observed.sentAt!);
      if (canonical != null) await _synchronizeIncomingTime(userId, canonical);
    }
    for (final observed in capture.messages.where((m) =>
        m.direction == 'outgoing' && m.deliveryConfirmed && m.sentAt != null)) {
      final attempts = await db.query('delivery_attempts',
          where:
              "user_id=? AND state='submitted' AND kind='reply' AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts old WHERE old.attempt_id=delivery_attempts.attempt_id)",
          whereArgs: [userId]);
      for (final attempt in attempts) {
        if (observed.body.replaceAll(RegExp(r'\s+'), '') !=
            (attempt['reply']! as String).replaceAll(RegExp(r'\s+'), '')) {
          continue;
        }
        if (observed.sentAt!.millisecondsSinceEpoch <
            (attempt['created_at_ms']! as int) - 1000) {
          continue;
        }
        await db.update(
            'delivery_attempts',
            {
              'state': 'accepted',
              'updated_at_ms': capture.capturedAt.millisecondsSinceEpoch
            },
            where: 'attempt_id=?',
            whereArgs: [attempt['attempt_id']]);
        await (await history).acceptAttemptReceipt(
            userId: userId, attemptId: attempt['attempt_id']! as String);
        RuntimeTrace.record('delivery.accepted_receipt',
            {'customer': userId, 'attemptId': attempt['attempt_id']});
      }
    }
    var reconciled = false;
    for (final message in capture.messages) {
      if (await confirmObservedGeneratedDraft(
          userId: userId, message: message, capturedAt: capture.capturedAt)) {
        reconciled = true;
        break;
      }
    }
    if (reconciled) {
      if (activateReplies &&
          (ownerSession != null || result.insertedIncomingIds.isNotEmpty)) {
        await _upsertPending(capture, store, ownerSession: ownerSession);
      }
      // This is our older frozen reply, not a manual answer to every newer
      // message. markReplySent advanced only that frozen batch's cursor.
      return result.changed > 0 ? result.changed : 1;
    }
    if (!activateReplies) {
      RuntimeTrace.record('capture.history_only', {
        'customer': userId,
        'inserted': result.changed,
        'reason': 'no_live_signal_or_durable_unanswered_task',
        'receiptReconciliationRetained': true,
      });
      return result.changed;
    }
    // A previously captured bubble can acquire a receipt on a later poll.
    if (result.changed == 0) {
      if (ownerSession != null) {
        await _upsertPending(capture, store, ownerSession: ownerSession);
      }
      return 0;
    }
    RuntimeTrace.record('capture.queue_decision', {
      'customer': userId,
      'incomingIds': result.insertedIncomingIds,
      'outgoingIds': result.insertedOutgoingIds,
      'lastInsertedDirection': result.lastInsertedDirection,
    });
    // OCR is a conversation observation, not proof of a newly sent manual
    // answer. Even a dated outgoing bubble can be old or misspelled; only a
    // native attempt or an explicit operator confirmation owns input coverage.
    if (isCurrentViewport && result.lastInsertedDirection == 'outgoing') {
      final document = await store.read(userId);
      final observed =
          (document?['messages'] as List? ?? const []).whereType<Map>();
      for (final outgoingId in result.insertedOutgoingIds) {
        final row = observed.where((m) => m['id'] == outgoingId).firstOrNull;
        if (const {
          'ownership_unverified',
          'delivery_unknown',
          'rejected',
          'not_sent',
          'unverified_observation'
        }.contains(row?['delivery_status'])) {
          continue;
        }
        await store.confirmObservedOutgoing(
            userId: userId,
            messageId: outgoingId,
            deliveryStatus: 'unverified_observation');
      }
      RuntimeTrace.record('capture.outgoing_not_answer', {
        'customer': userId,
        'incomingIds': result.insertedIncomingIds,
        'outgoingId': result.insertedOutgoingIds.lastOrNull,
        'reason': 'manual_confirmation_required',
      });
    }

    if (result.insertedIncomingIds.isEmpty && ownerSession == null) {
      return result.changed;
    }
    // A reply already generated for a frozen batch remains deliverable. The
    // new message stays pending until that earlier batch has been sent.
    final controls = await db.query('conversation_control',
        where: 'user_id = ?', whereArgs: [userId], limit: 1);
    if (controls.isNotEmpty) {
      final control = controls.first;
      if (control['state'] == 'human_contacting') return result.changed;
      if (control['state'] == 'waiting_for_customer') {
        final livePending = await processingMessages(userId);
        final newestId = livePending
            .where((m) => m['direction'] == 'incoming')
            .lastOrNull?['id'];
        if (newestId == null) return result.changed;
        if (newestId == control['resume_after_message_id']) {
          return result.changed;
        }
        await db.update(
            'conversation_control',
            {
              'state': 'ai_active',
              'resume_after_message_id': null,
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'user_id = ?',
            whereArgs: [userId]);
      }
    }
    await _upsertPending(capture, store, ownerSession: ownerSession);
    if (await isHandoffPending(userId)) {
      final rows = await db.query('human_review_tickets',
          where: "user_id=? AND status='open'",
          whereArgs: [userId],
          orderBy: 'id DESC',
          limit: 1);
      if (rows.isNotEmpty) {
        var context = rows.single['customer_request']! as String;
        final document = await store.read(userId);
        final ids = result.insertedIncomingIds.toSet();
        for (final m
            in (document?['messages'] as List? ?? const []).whereType<Map>()) {
          final body = m['body']?.toString() ?? '';
          if (ids.contains(m['id']) &&
              body.isNotEmpty &&
              !context.contains(body)) {
            context = '$context\n$body';
          }
        }
        await db.update(
            'human_review_tickets',
            {
              'customer_request': context,
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch
            },
            where: 'id=?',
            whereArgs: [rows.single['id']]);
        RuntimeTrace.record('handoff.context_updated', {
          'customer': userId,
          'ticketId': rows.single['id'],
          'newIncomingCount': ids.length,
          'contextChars': context.length
        });
      }
    }
    return result.changed;
  }

  Future<bool> _captureSessionMatches(
      DatabaseExecutor executor, String? ownerSession) async {
    if (ownerSession != _automationSessionId) return false;
    if (ownerSession == null) {
      return true; // Compatibility without explicit Start.
    }
    // beginAutomationSession commits the archive before assigning its memory
    // owner. Check durable ownership inside the same transaction as the write.
    final latest = await executor.rawQuery(
        'SELECT session_id FROM automation_sessions ORDER BY rowid DESC LIMIT 1');
    return latest.firstOrNull?['session_id'] == ownerSession;
  }

  Future<void> _upsertPending(
      CapturedConversation capture, ConversationFileStore store,
      {required String? ownerSession}) async {
    final userId = capture.customerExternalId ?? capture.customerName;
    // A viewport can contain an old image and newly arrived text. The image
    // may be last in the capture list even though it was already stored. Use
    // the actual durable tail so the pending cursor never moves backwards.
    final messages = await processingMessages(userId);
    final newest = messages
        .where((message) =>
            message['direction'] == 'incoming' &&
            message['capture_purpose'] != 'history_only')
        .lastOrNull;
    if (newest == null) {
      if (ownerSession != null) {
        final db = await database;
        await db.transaction((txn) async {
          if (!await _captureSessionMatches(txn, ownerSession)) return;
          await txn.delete('pending_customers',
              where: 'user_id=?', whereArgs: [userId]);
        });
      }
      return;
    }
    final newestId = newest['id']?.toString() ?? '';
    final now = capture.capturedAt.millisecondsSinceEpoch;
    final answeredBoundary =
        _answeredIndex(messages, await answeredMessageId(userId));
    final firstUnanswered = _firstUnansweredForSla(messages, answeredBoundary);
    if (firstUnanswered == null) return;
    // One unanswered batch starts with its first customer message. Later
    // messages update the batch tail but must never restart its SLA clock.
    final slaStartedAt = _slaStartedAt(
      capture.capturedAt,
      DateTime.tryParse(firstUnanswered['sent_at']?.toString() ?? ''),
    );
    if (capture.capturedAt.difference(slaStartedAt) > holdingDelay) {
      RuntimeTrace.record('sla.overdue_at_capture', {
        'customer': userId,
        'batchStartMessageId': firstUnanswered['id'],
        'senderOrFirstSeenAt': slaStartedAt.toUtc().toIso8601String(),
        'capturedAt': capture.capturedAt.toUtc().toIso8601String(),
        'senderToCaptureMs':
            capture.capturedAt.difference(slaStartedAt).inMilliseconds,
        'verifiedSenderClock': firstUnanswered['sent_at'] != null,
      });
    }
    final db = await database;
    await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession)) return;
      await txn.rawInsert('''INSERT INTO pending_customers(
        user_id, display_name, stable_key, newest_message_id, enqueued_at_ms, updated_at_ms)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET
          display_name=excluded.display_name,
          stable_key=excluded.stable_key,
          newest_message_id=excluded.newest_message_id,
          updated_at_ms=excluded.updated_at_ms''', [
        userId,
        capture.customerName,
        capture.stableKey,
        newestId,
        now,
        now,
      ]);
      await _putSlaFallback(txn,
          userId: userId,
          messageId: newestId,
          batchStartId: firstUnanswered['id']?.toString() ?? newestId,
          clockVerified: firstUnanswered['sent_at'] != null,
          startedAt: slaStartedAt,
          now: now);
    });
  }

  /// JD displays message clocks in China Standard Time even when this app is
  /// running in another system timezone. OCR supplies only the displayed
  /// clock, so reconstruct today's Asia/Shanghai instant and accept it only
  /// when it is close to the capture. This avoids both a late SLA timer and an
  /// immediate fallback caused by a wrongly inferred previous-day timestamp.
  Map<String, dynamic>? _firstUnansweredForSla(
      List<Map<String, dynamic>> messages, int boundary) {
    final pending = messages
        .skip(boundary + 1)
        .where((message) =>
            message['direction'] == 'incoming' &&
            message['capture_purpose'] != 'history_only')
        .toList();
    DateTime? lastReplyAt;
    for (final message in messages.where(_isFinalOutgoing)) {
      final sentAt = DateTime.tryParse(message['sent_at']?.toString() ?? '');
      if (sentAt != null &&
          (lastReplyAt == null || sentAt.isAfter(lastReplyAt))) {
        lastReplyAt = sentAt;
      }
    }
    // Late OCR can append an older question after its already-confirmed reply.
    // Keep that question for the final answer, but do not let it backdate a
    // genuinely newer turn's clock. A holding reply never moves this boundary.
    return pending.where((message) {
          final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
          return at == null || lastReplyAt == null || at.isAfter(lastReplyAt);
        }).firstOrNull ??
        pending.firstOrNull;
  }

  DateTime _slaStartedAt(DateTime capturedAt, DateTime? observedSentAt) {
    if (observedSentAt == null) return capturedAt;
    final capturedUtc = capturedAt.toUtc();
    final observedUtc = observedSentAt.toUtc();
    final directAge = capturedUtc.difference(observedUtc);
    if (!directAge.isNegative && directAge <= const Duration(minutes: 10)) {
      return observedUtc;
    }

    const chinaOffset = Duration(hours: 8);
    final chinaCapture = capturedUtc.add(chinaOffset);
    final displayedClock = observedSentAt.toLocal();
    var reconstructed = DateTime.utc(
      chinaCapture.year,
      chinaCapture.month,
      chinaCapture.day,
      displayedClock.hour,
      displayedClock.minute,
      displayedClock.second,
    ).subtract(chinaOffset);
    if (reconstructed.isAfter(capturedUtc.add(const Duration(minutes: 1)))) {
      reconstructed = reconstructed.subtract(const Duration(days: 1));
    }
    final reconstructedAge = capturedUtc.difference(reconstructed);
    return !reconstructedAge.isNegative &&
            reconstructedAge <= const Duration(minutes: 10)
        ? reconstructed
        : capturedAt;
  }

  /// Requeues a durable incoming message only when no generated reply appears
  /// after it. This repairs capture-success/generation-failure without ever
  /// drafting twice for an already answered message.
  Future<bool> ensurePendingForUnanswered(String userId) async {
    final db = await database;
    final drafts = await db.query('generated_drafts',
        columns: ['user_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (drafts.isNotEmpty) return false;
    final controls = await db.query('conversation_control',
        columns: ['state'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (controls.isNotEmpty && controls.first['state'] != 'ai_active') {
      return false;
    }
    final document = await (await history).read(userId);
    if (document == null) return false;
    final messages = await processingMessages(userId, document: document);
    final boundary = _answeredIndex(messages, await answeredMessageId(userId));
    final incomingIndex = messages.lastIndexWhere((message) =>
        message['direction'] == 'incoming' &&
        message['capture_purpose'] != 'history_only');
    if (incomingIndex <= boundary) return false;
    final incoming = messages[incomingIndex];
    final firstUnanswered = _firstUnansweredForSla(messages, boundary);
    if (firstUnanswered == null) return false;
    final capturedAt =
        DateTime.tryParse(incoming['captured_at']?.toString() ?? '') ??
            DateTime.now().toUtc();
    final firstCapturedAt =
        DateTime.tryParse(firstUnanswered['captured_at']?.toString() ?? '') ??
            capturedAt;
    final slaStartedAt = _slaStartedAt(
      firstCapturedAt,
      DateTime.tryParse(firstUnanswered['sent_at']?.toString() ?? ''),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert('''INSERT INTO pending_customers(
      user_id, display_name, stable_key, newest_message_id, enqueued_at_ms, updated_at_ms)
      VALUES(?, ?, ?, ?, ?, ?)
      ON CONFLICT(user_id) DO UPDATE SET
        display_name=excluded.display_name,
        stable_key=excluded.stable_key,
        newest_message_id=excluded.newest_message_id,
        updated_at_ms=excluded.updated_at_ms''', [
      userId,
      document['display_name']?.toString() ?? userId,
      document['stable_key']?.toString() ?? userId,
      incoming['id']?.toString() ?? '',
      capturedAt.millisecondsSinceEpoch + holdingDelay.inMilliseconds,
      now,
    ]);
    await _ensureSlaFallback(
      userId: userId,
      messageId: incoming['id']?.toString() ?? '',
      startedAt: slaStartedAt,
    );
    return true;
  }

  Future<bool> validateCustomerHistory(String userId) async {
    try {
      final store = await history;
      if (await store.read(userId) == null) {
        throw const FormatException('Missing history for customer');
      }
      await store.lastMessages(userId);
      final cleared = await (await database).delete('customer_storage_faults',
          where: 'user_id=?', whereArgs: [userId]);
      if (cleared > 0) {
        RuntimeTrace.record('history.recovered', {'customer': userId});
      }
      return true;
    } catch (error) {
      await _recordHistoryFault(userId, error);
      return false;
    }
  }

  Future<void> recheckHistoryFaults() async {
    final rows = await (await database).query('customer_storage_faults',
        where: 'last_seen_ms<=?',
        whereArgs: [
          DateTime.now()
              .subtract(const Duration(seconds: 5))
              .millisecondsSinceEpoch
        ],
        orderBy: 'last_seen_ms ASC',
        limit: 20);
    for (final row in rows) {
      await validateCustomerHistory(row['user_id']! as String);
    }
  }

  Future<List<Map<String, Object?>>> historyFaults() async =>
      (await database).query('customer_storage_faults');
  Future<bool> hasHistoryFault(String userId) async =>
      (await (await database).query('customer_storage_faults',
              where: 'user_id=?', whereArgs: [userId], limit: 1))
          .isNotEmpty;
  Future<void> _recordHistoryFault(String userId, Object error) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final first = !await hasHistoryFault(userId);
    await (await database).rawInsert(
        "INSERT INTO customer_storage_faults(user_id,error,since_ms,last_seen_ms) VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET error=excluded.error,last_seen_ms=excluded.last_seen_ms",
        [userId, error.toString(), now, now]);
    if (first) {
      RuntimeTrace.record('history.quarantined', {
        'customer': userId,
        'errorType': error.runtimeType.toString(),
        'originalFilePreserved': true
      });
    }
  }

  Future<ConversationSummary?> _conversationFromRow(
      Map<String, Object?> row) async {
    final userId = row['user_id']! as String;
    try {
      final store = await history;
      if (await store.read(userId) == null) {
        throw const FormatException('Missing history for queued customer');
      }
      final messages = await store.lastMessages(userId);
      final cleared = await (await database).delete('customer_storage_faults',
          where: 'user_id=?', whereArgs: [userId]);
      if (cleared > 0) {
        RuntimeTrace.record('history.recovered', {'customer': userId});
      }
      return ConversationSummary(
          id: row['id']! as int,
          userId: userId,
          stableKey: row['stable_key']! as String,
          customerName: row['display_name']! as String,
          lastActivityAt:
              DateTime.fromMillisecondsSinceEpoch(row['updated_at_ms']! as int),
          messages: messages);
    } catch (error) {
      await _recordHistoryFault(userId, error);
      return null;
    }
  }

  Future<ConversationSummary?> conversation(String userId) async {
    final rows = await (await database).query('pending_customers',
        where: 'user_id=?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : _conversationFromRow(rows.single);
  }

  Future<List<ConversationSummary>> conversations() async {
    final rows = await (await database)
        .query('pending_customers', orderBy: 'enqueued_at_ms ASC, id ASC');
    return (await Future.wait(rows.map(_conversationFromRow)))
        .whereType<ConversationSummary>()
        .toList();
  }

  /// Returns true only when SQLite and durable JSON agree that the customer
  /// has a latest incoming message with no later outgoing reply or draft.
  /// Stale queue rows from earlier builds are removed automatically.
  Future<bool> hasPendingUnanswered(String userId) async {
    final db = await database;
    final rows = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    if (rows.isEmpty) return false;
    final messages = await processingMessages(userId);
    final incomingIndex = messages.lastIndexWhere((message) =>
        message['direction'] == 'incoming' &&
        message['capture_purpose'] != 'history_only');
    final boundary = _answeredIndex(messages, await answeredMessageId(userId));
    final latestIncomingId =
        incomingIndex < 0 ? null : messages[incomingIndex]['id']?.toString();
    final queueMatchesLatest =
        rows.first['newest_message_id']?.toString() == latestIncomingId;
    if (_automationSessionId != null &&
        incomingIndex >= 0 &&
        !queueMatchesLatest) {
      await db.update(
          'pending_customers', {'newest_message_id': latestIncomingId},
          where: 'user_id=?', whereArgs: [userId]);
      return true;
    }
    if (incomingIndex <= boundary || !queueMatchesLatest) {
      await db.delete('pending_customers',
          where: 'user_id = ?', whereArgs: [userId]);
      return false;
    }
    return true;
  }

  /// Current-run customer duties, deduplicated only by proven message/card
  /// aliases. A sent holding/receipt does not hide unfinished acquisition.
  Future<Map<String, int>> unansweredWorkCounts() async {
    final owner = _automationSessionId;
    if (owner == null) return {};
    // One read statement gives a coherent snapshot without retaining an
    // asynchronous UI transaction across several query callbacks.
    final rows = await (await database).rawQuery('''
      WITH current_run AS (
        SELECT session_id FROM automation_sessions WHERE session_id=?
          AND rowid=(SELECT MAX(rowid) FROM automation_sessions)
      )
      SELECT 'work' AS record_type,user_id,user_id AS customer,message_id,
        response_state,NULL AS item_id,NULL AS canonical_id,NULL AS kind,
        NULL AS state,NULL AS aliases_json,NULL AS details,input_kind
      FROM automation_session_messages
      WHERE session_id IN (SELECT session_id FROM current_run)
      UNION ALL
      SELECT 'item',NULL,customer,message_id,NULL,item_id,canonical_id,kind,
        state,aliases_json,NULL,NULL
      FROM customer_media_items WHERE customer IN (
        SELECT DISTINCT user_id FROM automation_session_messages
        WHERE session_id IN (SELECT session_id FROM current_run)
          AND response_state!='delegated'
      )
    ''', [owner]);
    if (owner != _automationSessionId) return {};
    final snapshot = (
      work: rows.where((row) => row['record_type'] == 'work').toList(),
      media: rows.where((row) => row['record_type'] == 'item').toList(),
      audit: rows.where((row) => row['record_type'] == 'audit').toList(),
    );
    final customers =
        snapshot.work.map((row) => row['user_id']! as String).toSet();
    final counts = <String, int>{};
    for (final customer in customers) {
      final work = snapshot.work.where((row) => row['user_id'] == customer);
      final media = snapshot.media.where((row) => row['customer'] == customer);
      final duties = _canonicalMessageGroups(work, media)
          .where((group) => group.unanswered);
      final count = duties.length;
      if (count > 0) counts[customer] = count;
    }
    return owner == _automationSessionId ? counts : {};
  }

  /// Read-only projection of this run's incoming bubbles. It shares exactly
  /// the proven-card grouping used by the pending counter, without keeping a
  /// SQLite transaction open while reading the conversation document.
  Future<List<CustomerMessageRecord>> customerMessageRecords(String customer,
      {DatabaseExecutor? executor}) async {
    final owner = _automationSessionId;
    if (owner == null) return [];
    final db = executor ?? await database;
    final work = await db.rawQuery(
        'SELECT rowid AS activation_order,* FROM automation_session_messages WHERE session_id=? AND user_id=? ORDER BY rowid',
        [owner, customer]);
    final media = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final groups = _canonicalMessageGroups(work, media);
    final store = groups.isEmpty ? null : await history;
    final document = executor == null
        ? await store?.read(customer)
        : await store?.readOnly(customer);
    final messages = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) => m['direction'] == 'incoming')
        .toList();
    final attempts = await db.rawQuery('''SELECT a.* FROM delivery_attempts a
      WHERE a.user_id=? AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts x
        WHERE x.attempt_id=a.attempt_id) ORDER BY a.created_at_ms''',
        [customer]);
    final attemptsById = {
      for (final attempt in attempts) attempt['attempt_id']! as String: attempt
    };
    final completedAttempt = <_MessageGroup, String>{};
    final coveredCounts = <String, int>{};
    for (final group in groups) {
      if (group.pending || group.delegated) continue;
      final proofs = group.work
          .where((w) =>
              w['response_state'] == 'answered' &&
              w['answered_attempt_id'] != null)
          .where((w) {
        final attempt = attemptsById[w['answered_attempt_id']];
        return attempt != null && _positiveCompletionMetadata(attempt, owner);
      }).toList()
        ..sort((a, b) => (a['responded_at_ms'] as int? ?? 0)
            .compareTo(b['responded_at_ms'] as int? ?? 0));
      if (proofs.isEmpty) continue;
      final attemptId = proofs.last['answered_attempt_id']! as String;
      completedAttempt[group] = attemptId;
      coveredCounts[attemptId] = (coveredCounts[attemptId] ?? 0) + 1;
    }
    final drafts = await db
        .query('generated_drafts', where: 'user_id=?', whereArgs: [customer]);
    final leases =
        await db.rawQuery('''SELECT i.message_id FROM automation_reply_inputs i
      JOIN pending_customers p ON p.user_id=i.user_id AND p.generation_token=i.owner_id
      WHERE i.session_id=? AND i.user_id=?''', [owner, customer]);
    final reviewing = await db.rawQuery(
        '''SELECT w.message_id,i.message_json FROM automation_message_waits w
      JOIN automation_reply_inputs i ON i.session_id=w.session_id AND i.user_id=w.user_id
        AND i.owner_id=w.task_id AND i.message_id=w.message_id
      WHERE w.session_id=? AND w.user_id=?''', [owner, customer]);
    final reviewIds = reviewing
        .where((r) =>
            (jsonDecode(r['message_json']?.toString() ?? '{}')
                as Map)['reply_wait_purpose'] ==
            'review_status')
        .map((r) => r['message_id']! as String)
        .toSet();
    final expiredImageIds =
        await retiredIncompleteImageMessageIds(customer, executor: db);
    final repairIds = reviewing
        .where((row) {
          final message =
              jsonDecode(row['message_json']?.toString() ?? '{}') as Map;
          final repair = message['automatic_reply_repair'] as Map?;
          return ((repair?['message_states'] as Map?)?[row['message_id']] ??
                  repair?['state']) ==
              'operator_required';
        })
        .map((row) => row['message_id']! as String)
        .toSet();
    reviewIds.addAll(await _uncertainDeliveryHeldIds(db, customer));
    final activeIds = leases.map((r) => r['message_id']! as String).toSet();
    final result = <CustomerMessageRecord>[];
    final activationOrder = <String, int>{};
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    ({DateTime time, String source})? replyTime(Map attempt) {
      final raw = jsonDecode(attempt['raw_json']?.toString() ?? '{}') as Map;
      if (attempt['kind'] == 'manual_confirmation' &&
          raw['explicit_manual_confirmation'] == true &&
          raw['manual_sent_at_ms'] is num) {
        return (
          time: at((raw['manual_sent_at_ms'] as num).toInt()),
          source: 'explicit_manual_confirmation'
        );
      }
      final native = raw['native_reply_at_ms'];
      if (native is num) {
        return (
          time: at(native.toInt()),
          source: raw['native_reply_time_source']?.toString() ??
              'native_confirmation'
        );
      }
      final responded = work
          .where((w) => w['answered_attempt_id'] == attempt['attempt_id'])
          .map((w) => w['responded_at_ms'])
          .whereType<int>()
          .toList();
      if (responded.isNotEmpty) {
        return (time: at(responded.reduce(max)), source: 'ledger_confirmation');
      }
      final receipt = attempt['receipt_seen_ms'];
      if (receipt is int && receipt > 0) {
        return (time: at(receipt), source: 'native_confirmation');
      }
      return null;
    }

    for (final group in groups) {
      final ordered = [
        ...(group.work.isEmpty ? group.associatedWork : group.work)
      ]..sort((a, b) => (a['activation_order'] as int)
          .compareTo(b['activation_order'] as int));
      final root =
          group.media.where((r) => r['canonical_id'] == null).firstOrNull;
      final preferred = root?['message_id']?.toString();
      final stableId = preferred != null &&
              group.ids.contains(preferred) &&
              !work.any((w) =>
                  w['message_id'] == preferred && w['input_kind'] == 'text')
          ? preferred
          : group.work.isEmpty && root != null
              ? 'media-pending:${root['item_id']}'
              : ordered.first['message_id']! as String;
      activationOrder[stableId] =
          ordered.map((row) => row['activation_order']! as int).reduce(min);
      final incoming = messages
          .where((m) =>
              group.ids.contains(m['id']) ||
              (m['observed_ids'] as List? ?? const []).any(group.ids.contains))
          .toList();
      final message = incoming.where((m) => m['id'] == stableId).firstOrNull ??
          incoming.firstOrNull;
      final receivedAt =
          at(ordered.map((r) => r['activated_at_ms']! as int).reduce(min));
      DateTime? repliedAt;
      String? timeSource;
      DateTime? holdingAt;
      for (final attempt in attempts) {
        if (!const {'submitted', 'accepted'}.contains(attempt['state'])) {
          continue;
        }
        final time = replyTime(attempt);
        if (time == null) continue;
        if (attempt['kind'] == 'sla') {
          if (!time.time.isBefore(receivedAt) &&
              (holdingAt == null || time.time.isAfter(holdingAt))) {
            holdingAt = time.time;
          }
          continue;
        }
        final raw = jsonDecode(attempt['raw_json']! as String) as Map;
        final scope = _formalInputScope(raw, {
          ...(raw['service_message_ids'] as List? ?? const [])
              .whereType<String>(),
          if (attempt['batch_end_message_id'] is String)
            attempt['batch_end_message_id']! as String,
        });
        if (scope.intersection(group.ids).isNotEmpty &&
            (repliedAt == null || time.time.isAfter(repliedAt))) {
          repliedAt = time.time;
          timeSource = time.source;
        }
      }
      if (repliedAt == null) {
        final confirmed = group.work
            .where((row) => const {'answered', 'resend_requested'}
                .contains(row['response_state']))
            .map((row) => row['responded_at_ms'])
            .whereType<int>()
            .toList();
        if (confirmed.isNotEmpty) {
          repliedAt = at(confirmed.reduce(max));
          timeSource = 'ledger_confirmation';
        }
      }
      final replyAttemptId = completedAttempt[group];
      if (replyAttemptId != null) {
        final proofTime = replyTime(attemptsById[replyAttemptId]!);
        if (proofTime != null) {
          repliedAt = proofTime.time;
          timeSource = proofTime.source;
        }
      }
      var status = group.delegated
          ? 'delegated'
          : group.pending
              ? 'pending'
              : 'answered';
      if (!group.pending && !group.delegated) {
        if (group.work.any((r) => r['response_state'] == 'resend_requested')) {
          status = 'resend_requested';
        } else if (group.work
            .any((r) => r['response_state'] == 'skipped_image')) {
          status = 'skipped_image';
        } else if (group.work
            .any((r) => r['response_state'] == 'skipped_media')) {
          status = 'skipped_media';
        }
      }
      if (group.pending) {
        final pendingIds = group.work
            .where((r) => r['response_state'] == 'pending')
            .map((r) => r['message_id']! as String)
            .toSet();
        if (pendingIds.isNotEmpty && pendingIds.difference(reviewIds).isEmpty) {
          status = 'awaiting_review';
        }
        if (pendingIds.isNotEmpty && pendingIds.difference(repairIds).isEmpty) {
          status = 'needs_answer';
        }
        if (activeIds.intersection(pendingIds).isNotEmpty) status = 'analyzing';
        for (final draft in drafts) {
          final raw = jsonDecode(draft['raw_json']! as String) as Map;
          final ids = (raw['service_message_ids'] as List? ?? const [])
              .whereType<String>()
              .toSet();
          if (ids.intersection(pendingIds).isEmpty) continue;
          status = const {'sending', 'committing', 'delivery_unknown'}
                  .contains(draft['delivery_state'])
              ? 'sending'
              : 'ready';
        }
        if (group.work.any((r) =>
            r['input_kind'] == 'media' &&
            expiredImageIds.contains(r['message_id']))) {
          status = 'image_resend_pending';
        }
      }
      final mediaKind = root?['kind']?.toString();
      final kind = group.work.isNotEmpty &&
              ordered.every((r) => r['input_kind'] == 'text')
          ? 'text'
          : mediaKind == 'video' || mediaKind == 'image'
              ? mediaKind!
              : 'unknown';
      result.add(CustomerMessageRecord(
          stableId: stableId,
          customerId: customer,
          receivedAt: receivedAt,
          messageAt: DateTime.tryParse(message?['sent_at']?.toString() ?? ''),
          repliedAt: repliedAt,
          replyTimeSource: timeSource,
          holdingAt: holdingAt,
          replyAttemptId: replyAttemptId,
          coveredMessageCount:
              replyAttemptId == null ? null : coveredCounts[replyAttemptId],
          kind: kind,
          body: message?['body']?.toString() ??
              (group.media.isEmpty
                  ? ''
                  : '[Customer sent media; acquisition pending.]'),
          status: status));
    }
    result.sort((a, b) {
      final order =
          (a.messageAt ?? a.receivedAt).compareTo(b.messageAt ?? b.receivedAt);
      if (order != 0) return order;
      final occurrence = (activationOrder[a.stableId] ?? 0)
          .compareTo(activationOrder[b.stableId] ?? 0);
      return occurrence != 0 ? occurrence : a.stableId.compareTo(b.stableId);
    });
    return owner == _automationSessionId ? result : [];
  }

  Future<String?> pendingMessageId(String userId) async {
    final db = await database;
    final rows = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['newest_message_id']?.toString();
  }

  /// The newest discovered input bounds a generation snapshot. Its sender
  /// clock may be older than another pending question's clock.
  Future<String?> generationAnchorMessageId(String userId) async {
    if (_automationSessionId == null) return pendingMessageId(userId);
    final eligible = await _generationPendingSessionIds(userId);
    final rows = await (await database).query('automation_session_messages',
        columns: ['message_id'],
        where: "session_id=? AND user_id=? AND response_state='pending'",
        whereArgs: [_automationSessionId, userId],
        orderBy: 'rowid DESC');
    return rows
        .where((row) => eligible.contains(row['message_id']))
        .firstOrNull?['message_id']
        ?.toString();
  }

  Future<String?> answeredMessageId(String userId) async {
    final rows = await (await database).query('answered_cursors',
        columns: ['message_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['message_id']?.toString();
  }

  int _answeredIndex(List<Map<String, dynamic>> messages, String? cursor) {
    if (_automationSessionId != null) return -1;
    if (cursor != null) {
      final index = _messageIndex(messages, cursor);
      if (index >= 0) return index;
      // Older OCR versions could replace a bubble ID after it had become the
      // answered cursor. Recover from the actual sent-reply boundary instead
      // of treating the entire conversation as unanswered.
    }
    // Existing installations did not have a cursor. Their last delivered or
    // manual reply is the best available boundary until the next send. OCR
    // discovery order can differ from chat order, so match dated seller
    // messages only to customer messages that are not newer than them.
    var boundary = -1;
    for (var outgoingIndex = 0;
        outgoingIndex < messages.length;
        outgoingIndex++) {
      final outgoing = messages[outgoingIndex];
      if (!_isFinalOutgoing(outgoing)) continue;
      if (outgoing['answered_batch_end_id'] case final String end) {
        final frozen = _messageIndex(messages, end);
        if (frozen > boundary) boundary = frozen;
        continue;
      }
      final outgoingSentAt =
          DateTime.tryParse(outgoing['sent_at']?.toString() ?? '');
      if (outgoingSentAt == null) {
        final precedingIncoming = messages
            .take(outgoingIndex)
            .toList(growable: false)
            .lastIndexWhere((message) => message['direction'] == 'incoming');
        if (precedingIncoming > boundary) boundary = precedingIncoming;
        continue;
      }
      for (var incomingIndex = 0;
          incomingIndex < messages.length;
          incomingIndex++) {
        final incoming = messages[incomingIndex];
        if (incoming['direction'] != 'incoming') continue;
        final incomingSentAt =
            DateTime.tryParse(incoming['sent_at']?.toString() ?? '');
        if (incomingSentAt != null &&
            !incomingSentAt.isAfter(outgoingSentAt) &&
            incomingIndex > boundary) {
          boundary = incomingIndex;
        }
      }
    }
    return boundary;
  }

  bool _isFinalOutgoing(Map<String, dynamic> message) =>
      message['direction'] == 'outgoing' &&
      message['source'] != 'sla_fallback' &&
      !isRecoveryReply(message['body']) &&
      message['delivery_status'] != 'rejected' &&
      message['delivery_status'] != 'delivery_unknown' &&
      message['delivery_status'] != 'unverified_observation' &&
      message['delivery_status'] != 'ownership_unverified' &&
      TranscriptText.clean(message['body']?.toString() ?? '').isNotEmpty;

  Future<void> _ensureSlaFallback({
    required String userId,
    required String messageId,
    required DateTime startedAt,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final document = await (await history).read(userId);
    final messages = await processingMessages(userId, document: document);
    final first = _firstUnansweredForSla(
        messages, _answeredIndex(messages, await answeredMessageId(userId)));
    await _putSlaFallback(db,
        userId: userId,
        messageId: messageId,
        batchStartId: first?['id']?.toString() ?? messageId,
        startedAt: startedAt,
        clockVerified: first?['sent_at'] != null,
        now: now);
  }

  /// Sidebar red clock owns the response deadline, independently of OCR/media.
  Future<void> requireFreshPlatformClock() async {
    await (await database).rawUpdate(
        "UPDATE platform_response_cycles SET state='awaiting_observation',resume_pending=1,resume_since_ms=? WHERE state IN ('waiting','awaiting_observation')",
        [DateTime.now().millisecondsSinceEpoch]);
  }

  Future<Map<String, Object?>?> platformResponseCycle(String customer) async {
    final rows = await (await database).query('platform_response_cycles',
        where: 'user_id=?', whereArgs: [customer]);
    return rows.firstOrNull;
  }

  /// Positive new-input evidence, not a missed clear frame, starts the next
  /// response round. Late OCR and revisions of an already known media card
  /// cannot manufacture another holding message.
  Future<({String id, int startedMs})?> _inputAfterConfirmedResponse(
      String customer, Map<String, Object?> cycle) async {
    final responseMs = (cycle['response_started_ms'] as int?) ??
        (cycle['confirmed_at_ms'] as int?);
    if (responseMs == null) return null;
    final messages = await processingMessages(customer);
    final boundary = _messageIndex(messages, cycle['response_boundary_id']);
    final answered =
        _answeredIndex(messages, await answeredMessageId(customer));
    for (var i = max(boundary, answered) + 1; i < messages.length; i++) {
      final m = messages[i];
      if (m['direction'] != 'incoming' ||
          m['capture_purpose'] == 'history_only') {
        continue;
      }
      final captured = DateTime.tryParse(m['captured_at']?.toString() ?? '');
      final sent = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (captured == null || captured.millisecondsSinceEpoch < responseMs) {
        continue;
      }
      if (sent != null &&
          sent.millisecondsSinceEpoch ~/ 1000 < responseMs ~/ 1000) {
        continue;
      }
      if ((m['media'] as List? ?? const []).isNotEmpty) {
        final rows = await (await database).query('customer_media_items',
            where: 'customer=?', whereArgs: [customer]);
        final proven = rows.where((r) {
          final aliases =
              jsonDecode(r['aliases_json']?.toString() ?? '[]') as List;
          return r['canonical_id'] == null &&
              r['identity_ambiguous'] != 1 &&
              (r['message_id'] == m['id'] || aliases.contains(m['id'])) &&
              !aliases.contains(cycle['response_boundary_id']) &&
              (r['first_seen_ms'] as int? ?? 0) >= responseMs;
        }).isNotEmpty;
        if (!proven) continue;
      }
      return (
        id: m['id']! as String,
        startedMs: max(responseMs, (sent ?? captured).millisecondsSinceEpoch)
      );
    }
    return null;
  }

  /// A viewport may resume processing, but only AX badge evidence owns the
  /// deadline. Never replace a red clock with a historical input timestamp.
  Future<bool> refineResumedResponseClock(String customer,
      {required Iterable<String> visibleIncomingIds,
      required DateTime capturedAt}) async {
    await (await database).update(
        'platform_response_cycles', {'resume_pending': 0},
        where:
            "user_id=? AND state='waiting' AND resume_pending=1 AND resume_since_ms<=?",
        whereArgs: [customer, capturedAt.millisecondsSinceEpoch]);
    return false;
  }

  Future<void> observePlatformResponse(String customer,
      {required bool red,
      int? ageSeconds,
      DateTime? observedAt,
      DateTime? startedAt,
      bool clockReset = false,
      String? expectedCycleId,
      bool identityVerified = true}) async {
    final at = observedAt ?? DateTime.now();
    final now = at.millisecondsSinceEpoch;
    final age = ageSeconds != null && ageSeconds >= 0 && ageSeconds <= 600
        ? ageSeconds
        : 0;
    final estimated = startedAt?.millisecondsSinceEpoch ?? now - age * 1000;
    final snapshot = red ? await platformResponseCycle(customer) : null;
    final newInput = red && snapshot?['confirmed_at_ms'] != null
        ? await _inputAfterConfirmedResponse(customer, snapshot!)
        : null;
    await (await database).transaction((txn) async {
      final rows = await txn.query('platform_response_cycles',
          where: 'user_id=?', whereArgs: [customer]);
      final old = rows.firstOrNull;
      if (expectedCycleId != null && old?['cycle_id'] != expectedCycleId) {
        return;
      }
      if (old != null && (old['observed_at_ms']! as int) > now) {
        RuntimeTrace.record('sla.stale_red_observation_ignored', {
          'customer': customer,
          'observedAtMs': now,
          'latestAtMs': old['observed_at_ms']
        });
        return;
      }

      if (!red) {
        if (old == null || old['state'] == 'cleared') return;
        await txn.update('platform_response_cycles',
            {'state': 'cleared', 'observed_at_ms': now},
            where: 'user_id=?', whereArgs: [customer]);
        await txn.update('sla_fallbacks', {'state': 'completed'},
            where: "user_id=? AND batch_start_message_id=? AND state='pending'",
            whereArgs: [customer, old['cycle_id']]);
        await txn.update('sla_fallbacks',
            {'state': 'completed', 'retry_at_ms': 0, 'updated_at_ms': now},
            where:
                'user_id=? AND batch_start_message_id=? AND $_unstartedSlaReservationSql',
            whereArgs: [customer, old['cycle_id']]);
        RuntimeTrace.record('sla.red_clock_cleared', {
          'customer': customer,
          'cycleId': old['cycle_id'],
          'nativeConfirmed': old['confirmed_at_ms'] != null
        });
        return;
      }
      // A stale/briefly missing badge is not a fresh cycle after our send.
      final provenNewInput = newInput != null &&
          old?['confirmed_at_ms'] == snapshot?['confirmed_at_ms'];
      final confirmedStart =
          (old?['response_started_ms'] ?? old?['confirmed_at_ms']) as int?;
      final freshAxRound = ageSeconds != null &&
          confirmedStart != null &&
          estimated > confirmedStart + 2000;
      final sameConfirmed = old?['state'] != 'cleared' &&
          old?['confirmed_at_ms'] != null &&
          !clockReset &&
          !freshAxRound &&
          !provenNewInput;
      if (sameConfirmed) {
        RuntimeTrace.record('sla.red_clock_after_confirmation', {
          'customer': customer,
          'cycleId': old!['cycle_id'],
          'ageSeconds': ageSeconds,
          'action': 'verify_without_blind_resend'
        });
        return;
      }
      final continuing = old != null &&
          (old['state'] == 'waiting' ||
              (old['state'] == 'awaiting_observation' &&
                  (ageSeconds == null ||
                      (estimated - (old['started_at_ms']! as int)).abs() <=
                          2000))) &&
          !clockReset &&
          !freshAxRound &&
          !provenNewInput;
      final start = continuing ? old['started_at_ms']! as int : estimated;
      final cycle = continuing
          ? old['cycle_id']! as String
          : 'response-cycle:$now:$customer';
      await txn.insert(
          'platform_response_cycles',
          {
            'user_id': customer,
            'cycle_id': cycle,
            'started_at_ms': start,
            'state': 'waiting',
            'confirmed_at_ms': null,
            'response_started_ms': null,
            'response_boundary_id': null,
            'resume_pending': provenNewInput || ageSeconds != null
                ? 0
                : old?['resume_pending'] ?? 0,
            'resume_since_ms': old?['resume_since_ms'],
            'observed_at_ms': now,
            'identity_verified':
                identityVerified || old?['identity_verified'] == 1 ? 1 : 0
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _putSlaFallback(txn,
          userId: customer,
          messageId: cycle,
          batchStartId: cycle,
          startedAt: DateTime.fromMillisecondsSinceEpoch(start),
          clockVerified: false,
          now: now,
          verifiedRedObservation: identityVerified);
      if (!continuing || start != old['started_at_ms']) {
        RuntimeTrace.record('sla.red_clock_observed', {
          'customer': customer,
          'cycleId': cycle,
          'ageSeconds': ageSeconds,
          'startedAtMs': start,
          'dueAtMs': start + holdingDelay.inMilliseconds,
          'source':
              ageSeconds == null ? 'red_badge_first_seen' : 'red_badge_elapsed',
          'newCycle': !continuing,
          'newInputId': provenNewInput ? newInput.id : null,
          'freshAxRound': freshAxRound,
        });
      }
    });
  }

  Future<void> rebindPlatformResponse(String observed, String actual) async {
    if (observed == actual) {
      await (await database).update(
          'platform_response_cycles', {'identity_verified': 1},
          where: 'user_id=?', whereArgs: [actual]);
      return;
    }
    final old = await platformResponseCycle(observed);
    if (old == null || old['state'] != 'waiting') return;
    await observePlatformResponse(actual,
        red: true,
        startedAt:
            DateTime.fromMillisecondsSinceEpoch(old['started_at_ms']! as int));
    await observePlatformResponse(observed, red: false);
    RuntimeTrace.record('sla.red_clock_identity_bound',
        {'customer': actual, 'observedIdentity': observed});
  }

  /// A response-cycle ID is not a chat message. Resolve its actual native
  /// or explicitly confirmed manual proof directly, without scanning history.
  Future<bool> hasConfirmedResponseForCycle(SlaFallbackJob job) async {
    final rows = await (await database).rawQuery(
        '''SELECT c.*,a.kind,a.state AS attempt_state,
      a.raw_json,a.created_at_ms FROM platform_response_cycles c
      JOIN delivery_attempts a ON a.attempt_id=c.confirmed_attempt_id AND a.user_id=c.user_id
      WHERE c.user_id=? AND c.cycle_id=? AND c.confirmed_at_ms IS NOT NULL
        AND c.response_started_ms>=c.started_at_ms
        AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts x WHERE x.attempt_id=a.attempt_id)''',
        [job.userId, job.batchStartMessageId ?? job.messageId]);
    if (rows.isEmpty) return false;
    final row = rows.single;
    if (_automationSessionStartedAt != null &&
        (row['created_at_ms']! as int) <
            _automationSessionStartedAt!.millisecondsSinceEpoch) {
      return false;
    }
    final raw = jsonDecode(row['raw_json']! as String) as Map;
    if (row['kind'] == 'manual_confirmation') {
      return raw['service_session_id'] == _automationSessionId &&
          raw['explicit_manual_confirmation'] == true &&
          row['attempt_state'] == 'accepted';
    }
    return const {'reply', 'sla'}.contains(row['kind']) &&
        raw['native_confirmed_at_ms'] is num &&
        raw['native_reply_at_ms'] is num &&
        const {'sending', 'submitted', 'accepted'}
            .contains(row['attempt_state']);
  }

  /// Only an explicit operator action may confirm manual input coverage. OCR
  /// callers must never invoke this method. It freezes the selected current
  /// inputs and records the confirmation in the existing attempt journal.
  Future<bool> confirmManualReplyCoverage(String customer,
      {required Iterable<String> messageIds,
      required DateTime sentAt,
      required String reply,
      String? cycleId}) async {
    final session = _automationSessionId;
    if (session == null || messageIds.isEmpty) return false;
    final doc = await (await history).read(customer);
    final messages = (doc?['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((m) =>
            m['direction'] == 'incoming' &&
            _matchesWorkId(m, messageIds.toSet()))
        .toList();
    if (messages.isEmpty) return false;
    final requested = messageIds.toSet();
    if (requested.any((id) => !messages.any((m) => _matchesWorkId(m, {id})))) {
      return false;
    }
    final ids = <String>{
      for (final m in messages) ...{
        m['id']! as String,
        ...(m['observed_ids'] as List? ?? const []).whereType<String>()
      }
    };
    final task = 'manual-confirmation:${_taskId()}';
    final db = await database;
    final recorded = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return false;
      final work = await txn.query('automation_session_messages',
          where: "session_id=? AND user_id=? AND response_state='pending'",
          whereArgs: [session, customer]);
      final selected =
          work.where((r) => ids.contains(r['message_id'])).toList();
      if (selected.isEmpty ||
          selected.any((r) =>
              (r['activated_at_ms']! as int) > sentAt.millisecondsSinceEpoch)) {
        return false;
      }
      final scope = selected.map((r) => r['message_id']! as String).toSet();
      await _bindReplyInputs(txn, customer, task, scope, messages: {
        for (final m in messages) m['id']! as String: m
      }, revisions: {
        for (final r in selected)
          r['message_id']! as String: r['work_revision']! as int
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      final raw = jsonEncode({
        'service_session_id': session,
        'service_message_ids': scope.toList(),
        'formal_response_message_ids': scope.toList(),
        'reply_purpose': 'substantive',
        'explicit_manual_confirmation': true,
        'manual_sent_at_ms': sentAt.millisecondsSinceEpoch
      });
      await txn.insert('delivery_attempts', {
        'attempt_id': task,
        'task_id': task,
        'user_id': customer,
        'pending_id': 0,
        'reply': reply,
        'raw_json': raw,
        'batch_end_message_id': messages.last['id'],
        'state': 'accepted',
        'kind': 'manual_confirmation',
        'created_at_ms': now,
        'updated_at_ms': now
      });
      await _completeReplyInputs(txn, customer, task,
          attemptId: task, rawJson: raw);
      await _retireInvalidInputDraft(txn, customer);
      final currentCycle = cycleId ??
          (await txn.query('platform_response_cycles',
                  columns: ['cycle_id'],
                  where:
                      "user_id=? AND state IN ('waiting','awaiting_observation')",
                  whereArgs: [customer]))
              .firstOrNull?['cycle_id']
              ?.toString();
      if (currentCycle != null) {
        await txn.update(
            'platform_response_cycles',
            {
              'state': 'sent',
              'confirmed_at_ms': now,
              'confirmed_attempt_id': task,
              'response_started_ms': sentAt.millisecondsSinceEpoch,
              'response_boundary_id': messages.last['id'],
            },
            where:
                "user_id=? AND cycle_id=? AND state IN ('waiting','awaiting_observation') AND started_at_ms<=?",
            whereArgs: [customer, currentCycle, sentAt.millisecondsSinceEpoch]);
      }
      return true;
    });
    if (recorded && session == _automationSessionId) {
      await _reconcileCanonicalMessageWork(customer);
      await ensurePendingForUnanswered(customer);
      if ((await _pendingSessionIds(customer)).isEmpty) {
        await db.delete('pending_customers',
            where: 'user_id=?', whereArgs: [customer]);
      }
    }
    return recorded;
  }

  Future<bool> isPlatformResponsePending(SlaFallbackJob job) async {
    final row = await platformResponseCycle(job.userId);
    return row?['state'] == 'waiting' &&
        row?['identity_verified'] == 1 &&
        row?['cycle_id'] == job.batchStartMessageId;
  }

  Future<void> confirmPlatformResponse(String customer, DateTime sendStarted,
      {String? attemptId,
      String? expectedCycleId,
      String timeSource = 'native_click'}) async {
    if (attemptId != null &&
        (await (await database).query('automation_archived_attempts',
                columns: ['attempt_id'],
                where: 'attempt_id=?',
                whereArgs: [attemptId]))
            .isNotEmpty) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).transaction((txn) async {
      Map<String, Object?>? attempt;
      Map? raw;
      if (attemptId != null) {
        attempt = (await txn.query('delivery_attempts',
                where: 'attempt_id=? AND user_id=?',
                whereArgs: [attemptId, customer]))
            .firstOrNull;
        if (attempt != null) {
          raw = jsonDecode(attempt['raw_json']! as String) as Map;
          final previous = raw['native_reply_time_source'];
          if (previous != 'native_click' || timeSource == 'native_click') {
            await txn.update(
                'delivery_attempts',
                {
                  'raw_json': jsonEncode({
                    ...raw,
                    'native_reply_at_ms': sendStarted.millisecondsSinceEpoch,
                    'native_reply_time_source': timeSource,
                    'native_confirmed_at_ms': now,
                  })
                },
                where: 'attempt_id=? AND user_id=?',
                whereArgs: [attemptId, customer]);
          }
        }
      }
      final rows = await txn.query('platform_response_cycles',
          where:
              "user_id=? AND state IN ('waiting','awaiting_observation') AND started_at_ms<=?",
          whereArgs: [customer, sendStarted.millisecondsSinceEpoch]);
      if (rows.isEmpty) return;
      final cycle = rows.single['cycle_id'];
      if (expectedCycleId != null && cycle != expectedCycleId) return;
      if (raw?.containsKey(_nativeResponseCycleKey) == true &&
          cycle != raw![_nativeResponseCycleKey]) {
        return;
      }
      if (attempt?['kind'] == 'sla' &&
          (attempt!['task_id'] as String).startsWith('response-cycle:') &&
          cycle != attempt['task_id']) {
        return;
      }
      // A legacy confirmation timestamp is only an estimate of the click.
      // It cannot claim a round that started after the attempt was allocated.
      if (timeSource != 'native_click' &&
          attempt != null &&
          (attempt['created_at_ms']! as int) <
              (rows.single['started_at_ms']! as int)) {
        return;
      }
      final pending = await txn.query('pending_customers',
          columns: ['newest_message_id'],
          where: 'user_id=?',
          whereArgs: [customer]);
      await txn.update(
          'platform_response_cycles',
          {
            'state': 'sent',
            'confirmed_at_ms': now,
            'confirmed_attempt_id': attemptId,
            'response_started_ms': sendStarted.millisecondsSinceEpoch,
            'response_boundary_id': attempt != null
                ? attempt['input_boundary_id'] ??
                    (attempt['kind'] == 'reply'
                        ? attempt['batch_end_message_id']
                        : null)
                : pending.firstOrNull?['newest_message_id'],
            'resume_pending': 0,
          },
          where: 'user_id=? AND cycle_id=?',
          whereArgs: [customer, cycle]);
      await txn.update('sla_fallbacks', {'state': 'sent', 'sent_at_ms': now},
          where: 'user_id=? AND batch_start_message_id=?',
          whereArgs: [customer, cycle]);
      RuntimeTrace.record('sla.response_native_confirmed', {
        'customer': customer,
        'cycleId': cycle,
        'redClockVerification': 'await_sidebar_observation',
        'finalAnswerRemainsQueued': true
      });
    });
  }

  /// Only an explicit rejection of our exact confirming attempt rearms SLA.
  Future<void> rejectPlatformResponse(String customer, String attemptId) async {
    await (await database).transaction((txn) async {
      final rows = await txn.query('platform_response_cycles',
          where: "user_id=? AND state='sent' AND confirmed_attempt_id=?",
          whereArgs: [customer, attemptId]);
      if (rows.isEmpty) return;
      final cycle = rows.single['cycle_id'];
      await txn.update(
          'platform_response_cycles',
          {
            'state': 'waiting',
            'confirmed_at_ms': null,
            'confirmed_attempt_id': null
          },
          where: 'user_id=? AND cycle_id=?',
          whereArgs: [customer, cycle]);
      await txn.update('sla_fallbacks',
          {'state': 'pending', 'attempt_id': null, 'retry_at_ms': 0},
          where:
              "user_id=? AND batch_start_message_id=? AND state IN ('sent','completed')",
          whereArgs: [customer, cycle]);
      RuntimeTrace.record('sla.response_rejected_rearmed', {
        'customer': customer,
        'cycleId': cycle,
        'attemptId': attemptId,
        'proof': 'exact_native_rejected_or_not_sent_receipt'
      });
    });
  }

  Future<void> _putSlaFallback(DatabaseExecutor db,
      {required String userId,
      required String messageId,
      required String batchStartId,
      required DateTime startedAt,
      required bool clockVerified,
      required int now,
      bool verifiedRedObservation = false}) async {
    final cycles = await db.query('platform_response_cycles',
        where: 'user_id=?', whereArgs: [userId]);
    if (cycles.isNotEmpty) {
      final cycle = cycles.single;
      if (cycle['state'] != 'waiting') return;
      messageId = cycle['cycle_id']! as String;
      batchStartId = messageId;
      startedAt =
          DateTime.fromMillisecondsSinceEpoch(cycle['started_at_ms']! as int);
      clockVerified = false;
      if (verifiedRedObservation && cycle['identity_verified'] == 1) {
        // A newer AX-verified round can take the one active timer slot. A
        // settled uncertainty stays in the attempt journal; a live send,
        // ambiguous pointer or the same red round retains its reservation.
        final released = await db.rawUpdate('''UPDATE sla_fallbacks
          SET state='completed',retry_at_ms=0,updated_at_ms=?
          WHERE user_id=? AND state IN ('reconciling','delivery_unknown')
            AND COALESCE(batch_start_message_id,message_id)<>?
            AND EXISTS(SELECT 1 FROM delivery_attempts a
              WHERE a.attempt_id=sla_fallbacks.attempt_id
                AND a.user_id=sla_fallbacks.user_id AND a.kind='sla'
                AND a.batch_end_message_id=sla_fallbacks.message_id
                AND a.task_id=COALESCE(sla_fallbacks.batch_start_message_id,sla_fallbacks.message_id)
                AND a.created_at_ms<? AND a.state IN ('unknown','submitted')
                AND NOT EXISTS(SELECT 1 FROM automation_archived_attempts x
                  WHERE x.attempt_id=a.attempt_id))''', [
          now,
          userId,
          batchStartId,
          startedAt.millisecondsSinceEpoch,
        ]);
        if (released == 1) {
          await db.rawDelete('''DELETE FROM unavailable_conversations
            WHERE user_id=? AND reason=? AND NOT $_activeReceiptReconciliationSql''',
              [userId, _receiptReconciliationSuspension, userId, userId]);
          RuntimeTrace.record('sla.previous_receipt_detached', {
            'customer': userId,
            'cycleId': batchStartId,
            'oldReceiptPreserved': true,
          });
        }
      }
    }
    if (batchStartId.startsWith('response-cycle:')) {
      // A pre-native lease from a closed/superseded cycle owns no click. It
      // must not prevent a genuinely new red period from getting its timer.
      // An established attempt remains protected by the occupied-attempt guard.
      await db.update('sla_fallbacks',
          {'state': 'completed', 'retry_at_ms': 0, 'updated_at_ms': now},
          where:
              'user_id=? AND COALESCE(batch_start_message_id,message_id)<>? AND $_unstartedSlaReservationSql',
          whereArgs: [userId, batchStartId]);
    }
    await db.rawInsert("""INSERT INTO sla_fallbacks(
      user_id,message_id,due_at_ms,state,sent_at_ms,updated_at_ms,batch_start_message_id,batch_started_at_ms,batch_clock_verified)
      VALUES(?,?,?,'pending',NULL,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET
      message_id=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.message_id ELSE excluded.message_id END,
      due_at_ms=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.due_at_ms
        WHEN excluded.batch_start_message_id LIKE 'response-cycle:%' THEN excluded.due_at_ms
        WHEN sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
          AND sla_fallbacks.state IN ('pending','reserved','sent')
          THEN MIN(sla_fallbacks.due_at_ms,excluded.due_at_ms) ELSE excluded.due_at_ms END,
      state=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.state
        WHEN sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
          AND sla_fallbacks.state IN ('pending','reserved','sent') THEN sla_fallbacks.state ELSE 'pending' END,
      sent_at_ms=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') OR
        (sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id AND sla_fallbacks.state='sent')
        THEN sla_fallbacks.sent_at_ms ELSE NULL END,
      batch_start_message_id=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.batch_start_message_id ELSE excluded.batch_start_message_id END,
      batch_started_at_ms=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.batch_started_at_ms
        WHEN excluded.batch_start_message_id LIKE 'response-cycle:%' THEN excluded.batch_started_at_ms
        WHEN sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
          THEN MIN(COALESCE(sla_fallbacks.batch_started_at_ms,excluded.batch_started_at_ms),excluded.batch_started_at_ms)
        ELSE excluded.batch_started_at_ms END,
      batch_clock_verified=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') THEN sla_fallbacks.batch_clock_verified
        WHEN sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
          THEN MAX(sla_fallbacks.batch_clock_verified,excluded.batch_clock_verified)
        ELSE excluded.batch_clock_verified END,
      attempt_id=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') OR
        sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
        THEN sla_fallbacks.attempt_id ELSE NULL END,
      retry_at_ms=CASE WHEN sla_fallbacks.state IN ('sending','reserved','reconciling','delivery_unknown') OR
        sla_fallbacks.batch_start_message_id=excluded.batch_start_message_id
        THEN sla_fallbacks.retry_at_ms ELSE 0 END,
      updated_at_ms=excluded.updated_at_ms""", [
      userId,
      messageId,
      startedAt.millisecondsSinceEpoch + holdingDelay.inMilliseconds,
      now,
      batchStartId,
      startedAt.millisecondsSinceEpoch,
      clockVerified ? 1 : 0
    ]);
  }

  Future<SlaFallbackJob?> slaFallbackJob(String userId) async {
    if (await isConversationUnavailable(userId)) return null;
    final db = await database;
    final rows = await db.query(
      'sla_fallbacks',
      where: "user_id = ? AND state = 'pending'",
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isEmpty ? null : SlaFallbackJob.fromRow(rows.first);
  }

  /// Once OCR has created a durable SLA row, that row exclusively owns the
  /// one holding message for this customer turn. Unread-only recovery must
  /// stop at this boundary instead of racing a second UI send.
  Future<bool> hasActiveSlaFallback(String userId,
      {Set<String> excludingMessageIds = const {}}) async {
    final rows = await (await database).query(
      'sla_fallbacks',
      columns: ['message_id'],
      where:
          "user_id = ? AND state IN ('pending','sending','reserved','sent','delivery_unknown','reconciling')",
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isNotEmpty &&
        !excludingMessageIds.contains(rows.single['message_id']);
  }

  /// OCR may finish after the unread sidebar first exposed this message.
  /// Keep the original customer-visible configured deadline when that happens.
  Future<void> capSlaFallbackDue({
    required String userId,
    required DateTime dueAt,
  }) async {
    if (await platformResponseCycle(userId) != null) {
      RuntimeTrace.record('sla.deadline_cap_ignored', {
        'customer': userId,
        'reason': 'red_clock_is_authoritative',
        'observedDeadline': dueAt.toIso8601String()
      });
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final observedStart =
        dueAt.millisecondsSinceEpoch - holdingDelay.inMilliseconds;
    final updated = await (await database).rawUpdate(
        """UPDATE sla_fallbacks SET
      due_at_ms=MIN(due_at_ms,?),updated_at_ms=?,
      batch_started_at_ms=CASE WHEN batch_clock_verified=0
        THEN MIN(COALESCE(batch_started_at_ms,?),?) ELSE batch_started_at_ms END
      WHERE user_id=? AND state='pending'
      AND (batch_clock_verified=0 OR batch_started_at_ms IS NULL OR ? >= batch_started_at_ms-3000)""",
        [
          dueAt.millisecondsSinceEpoch,
          now,
          observedStart,
          observedStart,
          userId,
          observedStart
        ]);
    if (updated == 0) {
      RuntimeTrace.record('sla.deadline_cap_ignored', {
        'customer': userId,
        'observedDeadline': dueAt.toUtc().toIso8601String(),
        'reason': 'stale_observation_or_inactive_batch'
      });
    }
  }

  Future<List<SlaFallbackJob>> pendingSlaFallbackJobs() async {
    final db = await database;
    final rows = await db.query(
      'sla_fallbacks',
      where:
          "state = 'pending' AND user_id NOT IN (SELECT user_id FROM unavailable_conversations)",
      orderBy: 'due_at_ms ASC',
    );
    return rows.map(SlaFallbackJob.fromRow).toList(growable: false);
  }

  /// An unread-only recovery may have already sent the customer's holding
  /// message before OCR could create the normal pending SLA row. Treat that
  /// verified send as the one holding message for this response window.
  Future<void> acknowledgeUncapturedHolding(
      {required String userId, required DateTime sentAt}) async {
    if (await platformResponseCycle(userId) != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await database).transaction((txn) async {
      await txn.update(
          'sla_fallbacks',
          {
            'state': 'sent',
            'sent_at_ms': sentAt.millisecondsSinceEpoch,
            'updated_at_ms': now,
          },
          where:
              "user_id = ? AND state IN ('pending','sending') AND (batch_started_at_ms<=? OR (batch_clock_verified=0 AND batch_start_message_id NOT LIKE 'response-cycle:%'))",
          whereArgs: [userId, sentAt.millisecondsSinceEpoch]);
      await txn.rawInsert('''INSERT OR IGNORE INTO sla_delivery_receipts
        SELECT user_id,COALESCE(batch_start_message_id,message_id),message_id,sent_at_ms
        FROM sla_fallbacks WHERE user_id=? AND state='sent' AND sent_at_ms IS NOT NULL''',
          [userId]);
    });
  }

  Future<DateTime?> confirmedHoldingAfter(
      String userId, DateTime startedAt) async {
    final document = await (await history).read(userId);
    DateTime? latest;
    for (final m
        in (document?['messages'] as List? ?? const []).whereType<Map>()) {
      if (m['direction'] != 'outgoing' ||
          m['source'] != 'sla_fallback' ||
          m['delivery_status'] != 'sent') {
        continue;
      }
      final at = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (at != null &&
          !at.isBefore(startedAt) &&
          (latest == null || at.isAfter(latest))) {
        latest = at;
      }
    }
    return latest;
  }

  /// Recovery notices use the same durable attempt journal as regular SLA
  /// notices. A clicked/uncertain recovery can never fall back to a blind retry.
  Future<SlaFallbackJob?> reserveRecoveryFallback(
      {required String userId,
      required DateTime detectedAt,
      required bool resend}) async {
    final db = await database;
    final id =
        'unread-recovery:${detectedAt.microsecondsSinceEpoch}:${resend ? 'resend' : 'holding'}';
    final job = await db.transaction((txn) async {
      final existing = await txn
          .query('sla_fallbacks', where: 'user_id=?', whereArgs: [userId]);
      if (existing.isNotEmpty &&
          const {
            'pending',
            'sending',
            'reconciling',
            'reserved',
            'delivery_unknown'
          }.contains(existing.single['state'])) {
        return null;
      }
      await _putSlaFallback(txn,
          userId: userId,
          messageId: id,
          batchStartId: id,
          startedAt: detectedAt,
          clockVerified: false,
          now: DateTime.now().millisecondsSinceEpoch);
      final rows = await txn
          .query('sla_fallbacks', where: 'user_id=?', whereArgs: [userId]);
      return SlaFallbackJob.fromRow(rows.single);
    });
    if (job == null ||
        !await reserveSlaFallback(
            userId: userId,
            messageId: job.messageId,
            dueAt: job.dueAt,
            requireDue: true)) {
      return null;
    }
    return job;
  }

  Future<bool> reserveSlaFallback({
    required String userId,
    required String messageId,
    required DateTime dueAt,
    bool requireDue = false,
    DateTime? monotonicDueProof,
    Duration dispatchLead = Duration.zero,
  }) async {
    final current = await slaFallbackJob(userId);
    if (messageId.startsWith('response-cycle:') &&
        (current == null || !await isPlatformResponsePending(current))) {
      return false;
    }
    if (current != null &&
        !messageId.startsWith('response-cycle:') &&
        current.messageId == messageId &&
        current.dueAt == dueAt &&
        current.startedAt != null) {
      final covered = await confirmedHoldingAfter(
          userId,
          current.startedAt!.add(current.hasVerifiedSenderClock
              ? const Duration(seconds: 1)
              : Duration.zero));
      if (covered != null) {
        final changed = await (await database).update('sla_fallbacks',
            {'state': 'sent', 'sent_at_ms': covered.millisecondsSinceEpoch},
            where:
                "user_id=? AND message_id=? AND due_at_ms=? AND state='pending'",
            whereArgs: [userId, messageId, dueAt.millisecondsSinceEpoch]);
        if (changed > 0) {
          RuntimeTrace.record('sla.batch_receipt_rebound', {
            'customer': userId,
            'messageId': messageId,
            'confirmedAt': covered.toUtc().toIso8601String(),
            'proof': 'native_holding_after_batch_interval'
          });
        }
        return false;
      }
    }
    final db = await database;
    return db.transaction((txn) async {
      final duplicate = await txn.rawUpdate(
          '''UPDATE sla_fallbacks SET state='sent',
        sent_at_ms=(SELECT sent_at_ms FROM sla_delivery_receipts r
          WHERE r.user_id=sla_fallbacks.user_id AND
          r.batch_start_message_id=COALESCE(sla_fallbacks.batch_start_message_id,sla_fallbacks.message_id))
        WHERE user_id=? AND state='pending' AND EXISTS(
          SELECT 1 FROM sla_delivery_receipts r WHERE r.user_id=sla_fallbacks.user_id AND
          r.batch_start_message_id=COALESCE(sla_fallbacks.batch_start_message_id,sla_fallbacks.message_id))''',
          [userId]);
      if (duplicate > 0) {
        RuntimeTrace.record('sla.duplicate_suppressed', {
          'customer': userId,
          'messageId': messageId,
          'reason': 'native_confirmed_batch_receipt',
        });
        return false;
      }
      final leases = await txn.query('sla_fallbacks',
          where:
              "user_id=? AND message_id=? AND due_at_ms=? AND state='pending'",
          whereArgs: [userId, messageId, dueAt.millisecondsSinceEpoch]);
      if (leases.isEmpty) return false;
      final pointer = leases.single['attempt_id'];
      if (pointer != null) {
        final previous = await txn.query('delivery_attempts',
            where:
                "attempt_id=? AND user_id=? AND batch_end_message_id=? AND task_id=? AND kind='sla' AND state IN ('not_sent','rejected')",
            whereArgs: [
              pointer,
              userId,
              messageId,
              leases.single['batch_start_message_id'] ?? messageId
            ]);
        // Only positively not-sent attempts can relinquish ownership to a
        // fresh pre-native lease. Missing/foreign/uncertain proof cannot retry.
        if (previous.isEmpty) return false;
        await txn.update('sla_fallbacks', {'attempt_id': null},
            where: 'user_id=? AND message_id=? AND attempt_id=?',
            whereArgs: [userId, messageId, pointer]);
      }
      // Exact deadline is the generation token for a recycled timer row.
      final changed = await txn.update(
          'sla_fallbacks',
          {
            'state': 'sending',
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where:
              "user_id = ? AND message_id = ? AND due_at_ms = ? AND state = 'pending' AND (?=0 OR due_at_ms<=?) AND user_id NOT IN (SELECT user_id FROM unavailable_conversations) AND $_noStartedSlaAttemptSql",
          whereArgs: [
            userId,
            messageId,
            dueAt.millisecondsSinceEpoch,
            requireDue ? 1 : 0,
            (monotonicDueProof ?? DateTime.now())
                .add(dispatchLead.isNegative ? Duration.zero : dispatchLead)
                .millisecondsSinceEpoch
          ]);
      return changed == 1;
    });
  }

  /// Rechecks a reserved holding message immediately before the Send click.
  /// A real or manually observed reply changes this row out of `sending`, so
  /// a timer that was already queued cannot send afterward.
  Future<bool> isSlaFallbackReservedForSend(
      {required String userId, required String messageId}) async {
    final rows = await (await database).query(
      'sla_fallbacks',
      columns: ['user_id'],
      where: "user_id = ? AND message_id = ? AND state = 'sending'",
      whereArgs: [userId, messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> completeSlaForObservedReply(SlaFallbackJob job) async {
    final changed = await (await database).update(
        'sla_fallbacks',
        {
          'state': 'completed',
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where:
            "user_id=? AND message_id=? AND due_at_ms=? AND state IN ('pending','sending')",
        whereArgs: [
          job.userId,
          job.messageId,
          job.dueAt.millisecondsSinceEpoch
        ]);
    return changed > 0;
  }

  // The pointer and journal are checked together so a legacy missing pointer
  // cannot turn a real, possibly clicked attempt into permission to retry.
  static const _noUnresolvedSlaAttemptSql = """NOT EXISTS(
      SELECT 1 FROM delivery_attempts a WHERE a.user_id=sla_fallbacks.user_id
      AND a.kind='sla' AND a.batch_end_message_id=sla_fallbacks.message_id
      AND a.task_id=COALESCE(sla_fallbacks.batch_start_message_id,sla_fallbacks.message_id)
      AND a.state NOT IN ('not_sent','rejected'))""";
  static const _noStartedSlaAttemptSql =
      'attempt_id IS NULL AND $_noUnresolvedSlaAttemptSql';
  static const _unstartedSlaReservationSql =
      "state IN ('sending','reserved','reconciling','delivery_unknown') AND $_noStartedSlaAttemptSql";

  /// Releases only the exact lease that has not established a native attempt.
  /// Closed cycles are retired; a still-current cycle keeps its original clock.
  Future<bool> releaseUnstartedSlaFallback(SlaFallbackJob job,
      {Duration retryDelay = const Duration(seconds: 5)}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (await database).transaction((txn) async {
      final cycles = await txn.query('platform_response_cycles',
          where: 'user_id=?', whereArgs: [job.userId]);
      final current = cycles.firstOrNull;
      final stillPending = current == null
          ? !job.messageId.startsWith('response-cycle:')
          : current['state'] == 'waiting' &&
              current['cycle_id'] == job.batchStartMessageId;
      final changed = await txn.update(
          'sla_fallbacks',
          {
            'state': stillPending ? 'pending' : 'completed',
            'retry_at_ms': stillPending ? now + retryDelay.inMilliseconds : 0,
            'updated_at_ms': now,
          },
          where:
              'user_id=? AND message_id=? AND due_at_ms=? AND COALESCE(batch_start_message_id,message_id)=? AND $_unstartedSlaReservationSql',
          whereArgs: [
            job.userId,
            job.messageId,
            job.dueAt.millisecondsSinceEpoch,
            job.batchStartMessageId ?? job.messageId,
          ]);
      if (changed > 0) {
        RuntimeTrace.record('sla.unstarted_reservation_released', {
          'customer': job.userId,
          'messageId': job.messageId,
          'action':
              stillPending ? 'retry_not_started' : 'retire_inactive_cycle',
          'originalDeadlinePreserved': true,
        });
      }
      return changed > 0;
    });
  }

  Future<void> releaseSlaFallback({
    required String userId,
    required String messageId,
    String? expectedAttemptId,
    bool nativeNotInvoked = false,
    Duration retryDelay = const Duration(seconds: 5),
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await database;
    final rows = await db.query('sla_fallbacks',
        where: "user_id=? AND message_id=? AND state='sending'",
        whereArgs: [userId, messageId]);
    if (rows.isEmpty) return;
    final pointer = rows.single['attempt_id'] as String?;
    if (expectedAttemptId != null && pointer != expectedAttemptId) return;
    var attempt = pointer;
    var committedOldPointer = false;
    if (attempt != null) {
      final owned = await db.query('delivery_attempts',
          where:
              "attempt_id=? AND user_id=? AND batch_end_message_id=? AND task_id=? AND kind='sla'",
          whereArgs: [
            attempt,
            userId,
            messageId,
            rows.single['batch_start_message_id'] ?? messageId
          ]);
      if (owned.isEmpty) {
        final committed = await db.rawQuery('''SELECT 1 FROM delivery_attempts a
          JOIN sla_delivery_receipts r ON r.user_id=a.user_id
          AND r.batch_start_message_id=a.task_id AND r.message_id=a.batch_end_message_id
          WHERE a.attempt_id=? AND a.user_id=? AND a.kind='sla'
          AND (a.task_id<>? OR a.batch_end_message_id<>?)
          AND EXISTS(SELECT 1 FROM sla_fallbacks WHERE user_id=? AND message_id=?
            AND $_noUnresolvedSlaAttemptSql) LIMIT 1''', [
          attempt,
          userId,
          rows.single['batch_start_message_id'] ?? messageId,
          messageId,
          userId,
          messageId,
        ]);
        if (committed.isNotEmpty) {
          // A batch receipt alone could belong to a different attempt in that
          // batch. Detach only this exact pointer's native-confirmed send.
          try {
            final receipt = jsonDecode(await File(p.join(
                    (await storageRoot).path,
                    'delivery_receipts',
                    '$attempt.json'))
                .readAsString()) as Map;
            committedOldPointer = receipt['attemptId'] == attempt &&
                receipt['customer'] == userId &&
                const {'submitted', 'accepted'}.contains(receipt['state']);
          } catch (_) {
            /* Keep missing/uncertain exact-attempt proof in reconciliation. */
          }
        }
        attempt = null;
      }
    }
    var knownNotSent = pointer == null || committedOldPointer;
    var beforeNativeProof = false;
    String? phase;
    if (attempt != null) {
      final file = File(p.join(
          (await storageRoot).path, 'delivery_receipts', '$attempt.json'));
      try {
        final receipt = jsonDecode(await file.readAsString()) as Map;
        if (receipt['attemptId'] == attempt && receipt['customer'] == userId) {
          phase = receipt['state'] as String?;
        }
      } catch (_) {
        /* Missing proof is uncertainty, never permission to retype. */
      }
      knownNotSent = const {'not_sent', 'rejected'}.contains(phase);
      // This proof comes only from Dart's before-native budget guard, paired
      // with its exact allocated attempt. Missing journals alone prove nothing;
      // any existing native journal takes precedence over this caller proof.
      if (!knownNotSent &&
          phase == null &&
          nativeNotInvoked &&
          expectedAttemptId == attempt &&
          !await file.exists()) {
        knownNotSent = true;
        beforeNativeProof = true;
      }
    }
    final changed = await db.transaction((txn) async {
      // Receipt I/O above can yield to a new lease/attempt. Only the original
      // cycle, deadline and attempt pointer may be classified by this release.
      final count = await txn.update(
          'sla_fallbacks',
          {
            'state': knownNotSent ? 'pending' : 'reconciling',
            'retry_at_ms': knownNotSent ? now + retryDelay.inMilliseconds : 0,
            'updated_at_ms': now,
            if (committedOldPointer) 'attempt_id': null,
          },
          where:
              "user_id=? AND message_id=? AND due_at_ms=? AND COALESCE(batch_start_message_id,message_id)=? AND ${pointer == null ? 'attempt_id IS NULL' : 'attempt_id=?'} AND state='sending'${pointer == null ? ' AND $_noStartedSlaAttemptSql' : committedOldPointer ? ' AND $_noUnresolvedSlaAttemptSql' : ''}",
          whereArgs: [
            userId,
            messageId,
            rows.single['due_at_ms'],
            rows.single['batch_start_message_id'] ?? messageId,
            if (pointer != null) pointer,
          ]);
      if (count > 0 && attempt != null) {
        await txn.update(
            'delivery_attempts',
            {
              'state': knownNotSent
                  ? 'not_sent'
                  : phase == 'submitted'
                      ? 'submitted'
                      : 'unknown'
            },
            where: 'attempt_id=?',
            whereArgs: [attempt]);
      }
      return count;
    });
    if (changed == 0) return;
    RuntimeTrace.record('sla.failure_classified', {
      'customer': userId,
      'messageId': messageId,
      'attemptId': attempt,
      'nativePhase': phase,
      if (beforeNativeProof) 'nativeNotInvokedProof': true,
      if (committedOldPointer) 'detachedConfirmedOldCyclePointer': true,
      'action': knownNotSent ? 'retry_not_sent' : 'reconcile_without_retyping',
      'originalDeadlinePreserved': true
    });
  }

  Future<bool> markSlaFallbackSent({
    required String userId,
    required String messageId,
    required String reply,
    String? batchStartMessageId,
    bool nativeConfirmed = false,
  }) async {
    if (nativeConfirmed && batchStartMessageId == null) {
      throw ArgumentError(
          'Native SLA confirmation requires the reserved batch ID');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final recorded = await (await database).transaction((txn) async {
      final rows = await txn.query('sla_fallbacks',
          where: 'user_id = ?', whereArgs: [userId], limit: 1);
      final row = rows.firstOrNull;
      if (!nativeConfirmed &&
          (row == null ||
              row['message_id'] != messageId ||
              row['state'] != 'sending')) {
        return false;
      }
      final batch = batchStartMessageId ??
          row?['batch_start_message_id']?.toString() ??
          messageId;
      if (_automationSessionId != null &&
          row?['batch_start_message_id'] != batch &&
          row?['message_id'] != messageId) {
        final owned = await txn.rawQuery(
            '''SELECT a.attempt_id FROM delivery_attempts a WHERE a.user_id=? AND a.kind='sla'
          AND (a.task_id=? OR a.batch_end_message_id=?) AND NOT EXISTS(
          SELECT 1 FROM automation_archived_attempts old WHERE old.attempt_id=a.attempt_id) LIMIT 1''',
            [userId, batch, messageId]);
        if (owned.isEmpty) return false;
      }
      // Native confirmation survives a concurrent capture recycling/deleting
      // the mutable timer row. Never permit another holding for this batch.
      await txn.rawInsert('''INSERT OR IGNORE INTO sla_delivery_receipts
        (user_id,batch_start_message_id,message_id,sent_at_ms) VALUES(?,?,?,?)''',
          [userId, batch, messageId, now]);
      final changed = await txn.update(
          'sla_fallbacks',
          {
            'state': 'sent',
            'sent_at_ms': now,
            'updated_at_ms': now,
          },
          where:
              'user_id = ? AND COALESCE(batch_start_message_id,message_id) = ?',
          whereArgs: [userId, batch]);
      if (nativeConfirmed) {
        await txn.update('platform_response_cycles',
            {'state': 'sent', 'confirmed_at_ms': now},
            where:
                "user_id=? AND cycle_id=? AND state IN ('waiting','awaiting_observation')",
            whereArgs: [userId, batch]);
      }
      RuntimeTrace.record('sla.receipt_saved', {
        'customer': userId,
        'messageId': messageId,
        'batchStartMessageId': batch,
        'timerRowUpdated': changed == 1,
      });
      return true;
    });
    if (!recorded) return false;
    await (await history).appendSlaFallbackSent(
      userId: userId,
      messageId: messageId,
      reply: reply,
    );
    return true;
  }

  /// Saves the reply for a frozen batch. If later customer evidence arrived
  /// during generation, its pending row remains for the next batch.
  Future<int> saveDraft(
    int pendingId,
    AiDraft draft, {
    String? expectedMessageId,
    String? expectedUserId,
    String? generationToken,
    bool deliverable = true,
  }) async =>
      (await _saveDraft(pendingId, draft,
              expectedMessageId: expectedMessageId,
              expectedUserId: expectedUserId,
              generationToken: generationToken,
              deliverable: deliverable))
          .legacyCount;

  /// Automatic sends require a real queued draft, a concrete dependency, or
  /// an explicit repair task. A status-only result is not a successful save.
  Future<AutomaticDraftSaveResult> saveAutomaticDraft(
    int pendingId,
    AiDraft draft, {
    String? expectedMessageId,
    String? expectedUserId,
    String? generationToken,
    bool deliverable = true,
  }) =>
      _saveDraft(pendingId, draft,
          expectedMessageId: expectedMessageId,
          expectedUserId: expectedUserId,
          generationToken: generationToken,
          deliverable: deliverable,
          automatic: true);

  Future<AutomaticDraftSaveResult> _saveDraft(
    int pendingId,
    AiDraft draft, {
    String? expectedMessageId,
    String? expectedUserId,
    String? generationToken,
    bool deliverable = true,
    bool automatic = false,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final deliveryState = deliverable ? 'ready' : 'transfer_only';
    final ownerSession = _automationSessionId;
    final draftRaw = jsonDecode(draft.rawJson) as Map;
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession)) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }
      final rows = await txn.query('pending_customers',
          where: 'id = ?', whereArgs: [pendingId], limit: 1);
      if (rows.isEmpty) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }
      final row = rows.first;
      final customer = row['user_id']! as String;
      if (!automatic && _mediaDependencyKeys(draftRaw) != null) {
        if (!await _mediaDependencyKeysCurrent(txn, customer, draftRaw)) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
      } else if (!automatic && draft.mediaContextRevision != null) {
        final versions = await txn.query('customer_media_versions',
            where: 'customer=?', whereArgs: [customer]);
        final current = versions.isEmpty ? 0 : versions.single['revision'];
        if (current != draft.mediaContextRevision) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
      }
      final control = await txn.query('conversation_control',
          where:
              "user_id=? AND (state='human_contacting' OR state LIKE 'handoff_%')",
          whereArgs: [customer]);
      if (control.isNotEmpty) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }
      if (expectedUserId != null && customer != expectedUserId) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }
      if (generationToken != null &&
          row['generation_token'] != generationToken) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }
      final heldIds = await _uncertainDeliveryHeldIds(txn, customer);
      if (heldIds.isNotEmpty) {
        final target = expectedMessageId ?? row['newest_message_id'];
        final document = await (await history).read(customer);
        final targetMessage = (document?['messages'] as List? ?? const [])
            .whereType<Map>()
            .where((m) => _matchesWorkId(m, {if (target is String) target}))
            .firstOrNull;
        if (targetMessage != null && _matchesWorkId(targetMessage, heldIds)) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
      }
      if (expectedMessageId != null) {
        final document = await (await history).read(customer);
        final messages = (document?['messages'] as List<Object?>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        final index = messages.indexWhere((m) =>
            (m['id'] == expectedMessageId ||
                (m['observed_ids'] as List? ?? const [])
                    .contains(expectedMessageId)) &&
            m['direction'] == 'incoming');
        final cursor = await txn.query('answered_cursors',
            where: 'user_id=?', whereArgs: [customer]);
        if (index < 0 ||
            (ownerSession != null
                ? !_matchesWorkId(messages[index],
                    await _pendingSessionIds(customer, executor: txn))
                : index <=
                    _answeredIndex(messages,
                        cursor.firstOrNull?['message_id']?.toString()))) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
      }
      if ((await txn.query('generated_drafts',
              where: 'user_id=?', whereArgs: [customer]))
          .isNotEmpty) {
        return const AutomaticDraftSaveResult(AutomaticDraftSaveOutcome.stale);
      }

      final task = generationToken ?? _taskId();
      final pendingIds = ownerSession == null
          ? const <String>{}
          : await _pendingSessionIds(customer, executor: txn);
      Set<String> scope = {};
      if (ownerSession != null) {
        if (generationToken != null) {
          scope = await _replyInputIds(txn, customer, generationToken);
          if (scope.isEmpty) {
            return const AutomaticDraftSaveResult(
                AutomaticDraftSaveOutcome.stale);
          }
          final currentScope = await _replyInputIds(
              txn, customer, generationToken,
              currentRevisionOnly: true);
          if (currentScope.length != scope.length) {
            return const AutomaticDraftSaveResult(
                AutomaticDraftSaveOutcome.stale);
          }
          final inputs = await txn.query('automation_reply_inputs',
              where: 'session_id=? AND user_id=? AND owner_id=?',
              whereArgs: [ownerSession, customer, generationToken]);
          if (!_frozenMaterialCurrent(
              inputs, await (await history).read(customer))) {
            return const AutomaticDraftSaveResult(
                AutomaticDraftSaveOutcome.stale);
          }
        } else {
          final endId = expectedMessageId ?? row['newest_message_id'];
          final snapshot = await txn.query('automation_reply_inputs',
              where: 'session_id=? AND user_id=? AND owner_id=?',
              whereArgs: [ownerSession, customer, 'unleased:$endId']);
          if (snapshot.isNotEmpty) {
            scope = snapshot.map((m) => m['message_id']! as String).toSet();
            final valid = await _replyInputIds(txn, customer, 'unleased:$endId',
                currentRevisionOnly: true);
            if (valid.length != scope.length) {
              return const AutomaticDraftSaveResult(
                  AutomaticDraftSaveOutcome.stale);
            }
            await _bindReplyInputs(txn, customer, task, scope, revisions: {
              for (final m in snapshot)
                m['message_id']! as String:
                    (m['message_revision'] as num).toInt()
            }, messages: {
              for (final m in snapshot)
                if (m['message_json'] != null)
                  m['message_id']! as String: Map<String, dynamic>.from(
                      jsonDecode(m['message_json']! as String) as Map)
            });
          } else {
            final doc = await (await history).read(customer);
            final messages = (doc?['messages'] as List? ?? const [])
                .whereType<Map>()
                .toList();
            final end = _messageIndex(messages, endId);
            if (end < 0) {
              return const AutomaticDraftSaveResult(
                  AutomaticDraftSaveOutcome.stale);
            }
            scope = messages
                .take(end + 1)
                .where((m) =>
                    m['direction'] == 'incoming' &&
                    pendingIds.contains(m['id']))
                .map((m) => m['id']! as String)
                .toSet();
          }
        }
        scope = scope.intersection(pendingIds);
        if ((await _uncertainDeliveryHeldIds(txn, customer))
            .intersection(scope)
            .isNotEmpty) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
        if (scope.isEmpty) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
        if ((await retiredIncompleteImageMessageIds(customer, executor: txn))
            .intersection(scope)
            .isNotEmpty) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
        await _bindReplyInputs(txn, customer, task, scope);
      }
      final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
      raw.remove(_completedApiProof);
      raw.remove(_completedApiSource);
      raw['service_response_window'] = generationToken != null
          ? _responseWindowFromInputs(
              await txn.query('automation_reply_inputs',
                  where: 'session_id=? AND user_id=? AND owner_id=?',
                  whereArgs: [ownerSession, customer, task]),
              customer)
          : await _snapshotReplyResponseWindow(txn, customer, scope: scope);
      if (ownerSession != null) {
        raw['service_session_id'] = ownerSession;
        raw['service_message_ids'] = scope.toList();
        raw['service_message_revisions'] = {
          for (final input in await txn.query('automation_reply_inputs',
              where: 'session_id=? AND user_id=? AND owner_id=?',
              whereArgs: [ownerSession, customer, task]))
            input['message_id']! as String: input['message_revision']
        };
      }
      if (automatic) {
        // Older/custom automatic producers may not supply dependency keys.
        // Only unfinished media actually leased to this request can wait.
        final inventory = CustomerMediaInventory(this);
        final ready =
            await inventory.analysisReadyMessageIds(customer, executor: txn);
        final keys =
            await inventory.analyzableEvidenceKeys(customer, executor: txn);
        final dependencies = <String, String>{
          ...?await _scopedMediaDependencyKeys(txn, customer, raw,
              ownerId: task),
        };
        final inputs = await txn.rawQuery('''SELECT i.*,m.input_kind
          FROM automation_reply_inputs i JOIN automation_session_messages m
          ON m.session_id=i.session_id AND m.user_id=i.user_id AND m.message_id=i.message_id
          WHERE i.session_id=? AND i.user_id=? AND i.owner_id=?''',
            [ownerSession, customer, task]);
        for (final row in inputs) {
          if (row['input_kind'] != 'media') continue;
          final message =
              jsonDecode(row['message_json']?.toString() ?? '{}') as Map;
          final id = row['message_id']! as String;
          if (!_replyMediaAliases(message, messageId: id).any(ready.contains)) {
            dependencies[id] = keys[id] ?? '';
          }
          for (final dependency
              in (message['reply_media_input_dependencies'] as List? ??
                      const [])
                  .whereType<String>()) {
            if (!ready.contains(dependency)) {
              dependencies[dependency] = keys[dependency] ?? '';
            }
          }
        }
        raw['reply_media_dependency_keys'] = dependencies;
        if (!await _mediaDependencyKeysCurrent(txn, customer, raw)) {
          return const AutomaticDraftSaveResult(
              AutomaticDraftSaveOutcome.stale);
        }
      }
      if (automatic && deliverable) {
        final dependencies = _mediaDependencyKeys(raw);
        if (dependencies?.isNotEmpty == true) {
          final ready = await CustomerMediaInventory(this)
              .analysisReadyMessageIds(customer, executor: txn);
          if (dependencies!.keys.any((id) => !ready.contains(id))) {
            // A useful-looking answer cannot override an unfinished actual
            // input dependency, including one discovered after preparation.
            raw['reply_purpose'] = 'media_status';
            raw['formal_response_message_ids'] = <String>[];
            raw['media_wait_text_inputs'] = true;
            raw['media_wait_message_ids'] = scope.toList();
          }
        }
      }
      final formalScope = _formalInputScope(raw, scope);
      if (ownerSession != null &&
          deliverable &&
          (automatic ||
              raw['automatic_progress_classified'] == true ||
              raw['reply_purpose'] == 'media_status')) {
        final parked = await _waitForInputEvidence(
            txn, customer, task, scope.difference(formalScope), raw);
        if (formalScope.isEmpty) {
          // The red-clock SLA owns waiting notices. A real dependency can
          // park work; an answerless result after parsing needs correction.
          if (automatic && !parked) {
            return _recordAutomaticReplyRepair(
                txn, customer, task, scope, raw, draft, now);
          }
          if (_mediaDependencyKeys(raw) != null && !parked) {
            final attempts = (row['generation_attempts'] as num?)?.toInt() ?? 0;
            await txn.update(
                'pending_customers',
                {
                  'generation_retry_at_ms':
                      now + (attempts >= 5 ? 60000 : 10000),
                },
                where: 'id=?',
                whereArgs: [pendingId]);
          }
          return AutomaticDraftSaveResult(parked
              ? AutomaticDraftSaveOutcome.awaitingDependency
              : AutomaticDraftSaveOutcome.needsAnswer);
        }
      }
      final newerBatchPending = ownerSession != null
          ? pendingIds.difference(formalScope).isNotEmpty
          : expectedMessageId != null &&
              row['newest_message_id'] != expectedMessageId;
      await txn.rawInsert('''INSERT INTO generated_drafts(
        user_id,pending_id,reply,model,raw_json,created_at_ms,
        delivery_state,delivery_attempts,retry_at_ms,last_error,batch_end_message_id,task_id,queued_at_ms)
        VALUES(?,?,?,?,?,?,?,0,NULL,NULL,?,?,?) ON CONFLICT(user_id) DO UPDATE SET
        pending_id=excluded.pending_id,reply=excluded.reply,
        model=excluded.model,raw_json=excluded.raw_json,
        created_at_ms=excluded.created_at_ms,
        delivery_state=excluded.delivery_state,
        delivery_attempts=0,retry_at_ms=NULL,last_error=NULL,
        batch_end_message_id=excluded.batch_end_message_id''', [
        row['user_id'],
        pendingId,
        draft.reply,
        draft.model,
        jsonEncode(raw),
        now,
        deliveryState,
        expectedMessageId ?? row['newest_message_id'],
        task,
        row['enqueued_at_ms'],
      ]);
      if (automatic) {
        await _clearAutomaticReplyRepairForScope(
            txn, customer, deliverable ? formalScope : scope);
      }
      if (!newerBatchPending && deliverable) {
        await txn.delete('pending_customers',
            where: 'id = ?', whereArgs: [pendingId]);
      }
      return AutomaticDraftSaveResult(deliverable
          ? AutomaticDraftSaveOutcome.ready
          : AutomaticDraftSaveOutcome.transferOnly);
    });
  }

  Future<StoredDraft?> latestDraft(int pendingId) async => null;

  Future<bool> hasUndeliveredDraft(String userId) async {
    final rows = await (await database).query('generated_drafts',
        columns: ['user_id'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Sends the oldest ready reply without waiting for another customer's
  /// generation. Each customer still has at most one undelivered draft.
  Future<QueuedDelivery?> nextReadyDelivery(
      {String? userId,
      bool onlyWithinResponseWindow = false,
      String? expectedResponseCycleId}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final waitingForMedia = <String>{};
    final requireWindow =
        onlyWithinResponseWindow || expectedResponseCycleId != null;
    final responseCycleFilter = expectedResponseCycleId == null
        ? ''
        : ' AND $_replyForExpectedResponseCycleSql';
    while (true) {
      final exclude = waitingForMedia.isEmpty
          ? ''
          : ' AND user_id NOT IN (${List.filled(waitingForMedia.length, '?').join(',')})';
      final customerFilter = userId == null ? '' : ' AND user_id=?';
      // Transfer-time priority belongs to a reply generated within the
      // original AX red-clock window. A holding send can clear that badge,
      // but cannot move its start forward and promote a late formal answer.
      final responseWindowFilter =
          requireWindow ? ' AND $_replyWithinResponseWindowSql' : '';
      final generated = await db.query('generated_drafts',
          where:
              "(delivery_state='ready' OR (delivery_state='retry' AND retry_at_ms<=?)) AND $_readyReplyCustomerGuardSql$exclude$customerFilter$responseWindowFilter$responseCycleFilter",
          whereArgs: [
            now,
            ...waitingForMedia,
            if (userId != null) userId,
            if (requireWindow) ...[
              holdingDelay.inMilliseconds,
              holdingDelay.inMilliseconds
            ],
            if (expectedResponseCycleId != null) expectedResponseCycleId,
          ],
          orderBy:
              "CASE WHEN EXISTS(SELECT 1 FROM platform_response_cycles c WHERE c.user_id=generated_drafts.user_id AND c.state='waiting' AND c.identity_verified=1) THEN 0 ELSE 1 END, (SELECT started_at_ms FROM platform_response_cycles c WHERE c.user_id=generated_drafts.user_id AND c.state='waiting' AND c.identity_verified=1) ASC, COALESCE(queued_at_ms,created_at_ms) ASC,pending_id ASC",
          limit: 1);
      if (generated.isEmpty) return null;
      final row = generated.single;
      if (!_hasCompletedApiProof(row) && _automationSessionId != null) {
        final session = _automationSessionId!;
        await _repairFrozenTextKinds(row['user_id']! as String, session);
      }
      if (await retireStaleMediaDraft(row['user_id']! as String)) continue;
      try {
        final raw =
            jsonDecode(row['raw_json']! as String) as Map<String, dynamic>;
        final draft = AiDraft.fromJson(raw, mediaBaseUrl: Uri());
        if (draft.reply.trim().isEmpty) {
          throw const FormatException('Empty reply');
        }
        if (!await _draftMediaInputsReady(db, row['user_id']! as String, row)) {
          // Keep this exact generated answer. A kind recheck resolving with
          // the same material makes it eligible again without another CLI.
          waitingForMedia.add(row['user_id']! as String);
          continue;
        }
        final window = await _deliveryResponseWindow(
            db, row['user_id']! as String, raw, row['created_at_ms']! as int);
        return QueuedDelivery(
            pendingId: row['pending_id']! as int,
            userId: row['user_id']! as String,
            draft: draft,
            taskId: row['task_id']?.toString(),
            generatedAt: DateTime.fromMillisecondsSinceEpoch(
                row['created_at_ms']! as int,
                isUtc: true),
            responseWindowCycleId: window?['cycleId'] as String?,
            responseWindowStartedAt: window == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    window['startedAtMs']! as int,
                    isUtc: true),
            responseWindowDueAt: window == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(window['dueAtMs']! as int,
                    isUtc: true));
      } catch (error) {
        await db.update('generated_drafts',
            {'delivery_state': 'quarantined', 'last_error': error.toString()},
            where: 'user_id=?', whereArgs: [row['user_id']]);
        RuntimeTrace.record('delivery.quarantined',
            {'customer': row['user_id'], 'reason': 'invalid_draft_payload'});
      }
    }
  }

  /// Revalidates a queued reply immediately before UI automation types it.
  /// A transfer can delete or suppress a draft after the delivery worker has
  /// already materialized it in memory.
  Future<Map<String, Object?>> deliveryTiming(
      String customer, String? taskId) async {
    final db = await database;
    final row = (await db.query('generated_drafts',
            where: 'user_id=? AND (? IS NULL OR task_id=?)',
            whereArgs: [customer, taskId, taskId]))
        .firstOrNull;
    if (row == null) return {};
    final raw = jsonDecode(row['raw_json']! as String) as Map;
    Map? message;
    if (_hasCompletedApiProof(row)) {
      message = raw[_completedApiSource] as Map;
    } else {
      final document = await (await history).read(customer);
      message = (document?['messages'] as List? ?? const [])
          .whereType<Map>()
          .where((m) =>
              m['id'] == row['batch_end_message_id'] ||
              (m['observed_ids'] as List? ?? const [])
                  .contains(row['batch_end_message_id']))
          .firstOrNull;
    }
    final session = _automationSessionId;
    final task = row['task_id']?.toString();
    final modern = session != null && raw['service_session_id'] == session;
    final receivedByMessage = <String, String>{};
    String? firstObserved;
    if (modern && task != null) {
      final owned = await _replyInputIds(db, customer, task,
          rawJson: row['raw_json']! as String);
      final covered = _formalInputScope(raw, owned);
      if (covered.isNotEmpty) {
        final work = await db.query('automation_session_messages',
            columns: ['message_id', 'activated_at_ms'],
            where:
                'session_id=? AND user_id=? AND message_id IN (${List.filled(covered.length, '?').join(',')})',
            whereArgs: [session, customer, ...covered],
            orderBy: 'activated_at_ms,message_id');
        for (final input in work) {
          receivedByMessage[input['message_id']! as String] =
              DateTime.fromMillisecondsSinceEpoch(
                      input['activated_at_ms']! as int,
                      isUtc: true)
                  .toIso8601String();
        }
        firstObserved = receivedByMessage.values.firstOrNull;
      }
    } else if (!modern) {
      // Compatibility for drafts without a run-owned work ledger. Never use
      // another question's enqueue time or customer-wide earliest observation.
      firstObserved = message?['captured_at']?.toString();
    }
    return {
      'batchEndMessageId': row['batch_end_message_id'],
      'customerMessageAt': message?['sent_at'],
      'firstObservedAt': firstObserved,
      'firstObservedSource':
          modern ? 'message_work_activation' : 'history_first_capture',
      'receivedAtByMessage': receivedByMessage,
      'queuedAtMs': row['queued_at_ms']
    };
  }

  Future<DateTime?> platformDeliveryDeadline(String customer) async {
    final cycle = await platformResponseCycle(customer);
    if (cycle?['state'] != 'waiting' || cycle?['identity_verified'] != 1) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(
        (cycle!['started_at_ms']! as int) + holdingDelay.inMilliseconds);
  }

  // Reserve the next open-and-send slot for an imminent unmet response.
  // A retry that cannot run yet or a persistently unavailable overdue row must
  // not prevent unrelated customers receiving their prepared final answers.
  Future<SlaFallbackJob?> responseSlotOwner(String customer,
      {DateTime? ownDeadline, DateTime? now}) async {
    final at = now ?? DateTime.now();
    for (final job in await pendingSlaFallbackJobs()) {
      if (job.userId == customer || !await isPlatformResponsePending(job)) {
        continue;
      }
      // A failed dispatch keeps its own timer/queue priority, but cannot
      // reserve everyone else's ready-reply slot throughout its retry cycle.
      if (job.retryAt != null) {
        continue;
      }
      if (job.dueAt.isAfter(at.add(const Duration(seconds: 6)))) continue;
      if (at.difference(job.dueAt) > const Duration(seconds: 15)) continue;
      if (ownDeadline == null || job.dueAt.isBefore(ownDeadline)) return job;
    }
    return null;
  }

  Future<DateTime?> deliveryDeadline(String customer, String? taskId) async {
    final info = await deliveryTiming(customer, taskId);
    final at = DateTime.tryParse(info['customerMessageAt']?.toString() ?? '') ??
        DateTime.tryParse(info['firstObservedAt']?.toString() ?? '');
    return at?.add(holdingDelay);
  }

  Future<bool> isGeneratedDraftReadyForSend({
    required String userId,
    required String reply,
    String? taskId,
  }) async {
    final rows = await (await database).query(
      'generated_drafts',
      columns: ['user_id', 'raw_json', 'task_id'],
      where:
          "user_id = ? AND reply = ?${taskId == null ? '' : ' AND task_id=?'} AND delivery_state IN ('ready','retry') AND user_id NOT IN (SELECT user_id FROM unavailable_conversations)",
      whereArgs: [userId, reply, if (taskId != null) taskId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final db = await database;
    if (_hasCompletedApiProof(rows.single)) {
      return _completedDraftCurrent(db, userId, rows.single);
    }
    if (!await _draftInputsCurrent(db, userId, rows.single)) {
      await db.transaction((txn) => _retireInvalidInputDraft(txn, userId));
      await ensurePendingForUnanswered(userId);
      return false;
    }
    return await mediaContextCurrent(
        userId,
        AiDraft.fromJson(jsonDecode(rows.single['raw_json']! as String),
            mediaBaseUrl: Uri()));
  }

  /// Removes an unrecoverable queue item so it cannot permanently block every
  /// later customer. Durable captured conversation history is preserved.
  Future<void> abandonPendingCustomer(String userId) async {
    final db = await database;
    await db
        .delete('pending_customers', where: 'user_id = ?', whereArgs: [userId]);
  }

  /// Automatic sends are never retried after an uncertain click. Discarding
  /// the transient draft advances FIFO delivery without altering JSON history.
  Future<void> discardGeneratedDraft(String userId) async {
    final db = await database;
    await db
        .delete('generated_drafts', where: 'user_id = ?', whereArgs: [userId]);
  }

  /// Removes the non-deliverable draft used only to trigger an automatic
  /// transfer. Advancing its frozen-batch cursor prevents the same request
  /// from being regenerated if the transfer attempt itself fails.
  Future<void> discardTransferOnlyDraft(String userId) async {
    final db = await database;
    final accepted = await db.query('human_review_tickets',
        where: "user_id=? AND status='contacted'",
        whereArgs: [userId],
        orderBy: 'updated_at_ms DESC',
        limit: 1);
    final outstanding = await db.query('human_review_tickets',
        where: "user_id=? AND status IN ('open','contacting')",
        whereArgs: [userId],
        limit: 1);
    if (accepted.isEmpty || outstanding.isNotEmpty) {
      RuntimeTrace.record('handoff.cleanup_blocked',
          {'customer': userId, 'reason': 'handoff_not_confirmed'});
      return;
    }
    await db.transaction((txn) async {
      final rows = await txn.query(
        'generated_drafts',
        columns: ['batch_end_message_id'],
        where: "user_id = ? AND delivery_state = 'transfer_only'",
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final batchEnd = rows.first['batch_end_message_id']?.toString();
      await txn.delete(
        'generated_drafts',
        where: "user_id = ? AND delivery_state = 'transfer_only'",
        whereArgs: [userId],
      );
      if (batchEnd == null ||
          batchEnd.isEmpty ||
          _automationSessionId != null) {
        return;
      }
      await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
        VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
        message_id=excluded.message_id''', [userId, batchEnd]);
      await txn.update(
        'sla_fallbacks',
        {
          'state': 'completed',
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'user_id = ? AND message_id = ?',
        whereArgs: [userId, batchEnd],
      );
    });
  }

  Future<void> markGeneratedDraftDeliveryFailure(
      {required String userId,
      required String error,
      String? taskId,
      Duration retryDelay = const Duration(seconds: 10)}) async {
    final db = await database;
    final rows = await db.query('generated_drafts',
        where: taskId == null ? 'user_id=?' : 'user_id=? AND task_id=?',
        whereArgs: [userId, if (taskId != null) taskId],
        limit: 1);
    if (rows.isEmpty) return;
    final row = rows.single;
    var uncertain = error.contains('send_unconfirmed') ||
        error.contains('send_not_confirmed') ||
        error.contains('send_not_committed');
    final attempt = row['attempt_id']?.toString();
    String? phase;
    if (attempt != null) {
      try {
        final json = jsonDecode(await File(p.join(
                (await storageRoot).path, 'delivery_receipts', '$attempt.json'))
            .readAsString()) as Map;
        if (json['attemptId'] == attempt && json['customer'] == userId) {
          phase = json['state']?.toString();
        }
      } on FileSystemException {
        // A missing pre-click journal cannot authorize any native insertion.
      } on FormatException {
        // Keep the explicit native error classification; do not trust corrupt receipt data.
      }
      if (phase == null) uncertain = true;
      if (phase == 'submitted') {
        await recoverDeliveryReceipts();
        return;
      }
      if (const {
        'unknown',
        'clicked',
        'click_intent',
        'late_rejection_uncertain'
      }.contains(phase)) {
        uncertain = true;
      }
      if (phase == 'not_sent' || phase == 'rejected') uncertain = false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final changed = await txn.update(
          'generated_drafts',
          {
            'delivery_state': uncertain ? 'delivery_unknown' : 'retry',
            'retry_at_ms': now + retryDelay.inMilliseconds,
            'last_error': error,
            'delivery_attempts': (row['delivery_attempts'] as int? ?? 0) + 1
          },
          where:
              "user_id=? AND task_id IS ? AND attempt_id IS ? AND delivery_state!='committing'",
          whereArgs: [userId, row['task_id'], row['attempt_id']]);
      if (changed == 0 || attempt == null) return;
      await txn.update(
          'delivery_attempts',
          {
            'state': uncertain
                ? 'unknown'
                : phase == 'rejected'
                    ? 'rejected'
                    : 'not_sent',
            'error': error,
            'updated_at_ms': now
          },
          where: "attempt_id=? AND state NOT IN ('accepted','submitted')",
          whereArgs: [attempt]);
    });
    RuntimeTrace.record('delivery.failure_classified', {
      'customer': userId,
      'attemptId': attempt,
      'nativePhase': phase,
      'action': uncertain ? 'reconcile_without_retyping' : 'retry_not_sent'
    });
  }

  Future<List<ChatTransferLog>> chatTransferLogs({int limit = 50}) async {
    final rows = await (await database).query(
      'chat_transfer_logs',
      orderBy: 'updated_at_ms DESC, id DESC',
      limit: limit,
    );
    return rows
        .map((row) => ChatTransferLog.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<int> transferAcknowledgement(int logId) async =>
      ((await (await database).query('chat_transfer_logs',
              columns: ['acknowledged'], where: 'id=?', whereArgs: [logId]))
          .single['acknowledged'] as int?) ??
      0;

  Future<void> setTransferAcknowledgement(int logId, int state) async {
    if (!const [0, 1, 2].contains(state)) {
      throw ArgumentError.value(state, 'state');
    }
    await (await database).update(
        'chat_transfer_logs',
        {
          'acknowledged': state,
          if (state == 2) 'phase': 'acknowledging',
          if (state == 1) 'phase': 'acknowledged',
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where: "id=? AND phase!='confirmed' AND status!='transferred'",
        whereArgs: [logId]);
  }

  String? _handoffReplyResumePhase(Object? value) {
    final phase = value?.toString() ?? '';
    for (final prefix in [
      'reply_deferred:',
      'reply_resuming:',
      'open_deferred:',
      'open_resuming:',
    ]) {
      if (!phase.startsWith(prefix)) continue;
      final resume = phase.substring(prefix.length);
      return const {'inspect_accounts', 'acknowledge', 'revalidate_target'}
              .contains(resume)
          ? resume
          : null;
    }
    return null;
  }

  // Session rows count actual failures, including the initial attempt. Legacy
  // rows count reserved retries, so their initial attempt already occupies one
  // slot. Keep that persisted meaning without granting an eleventh attempt.
  int get _handoffFailureLimit =>
      handoffMaxAttempts - (_automationSessionId == null ? 1 : 0);

  bool _handoffAttemptsExhausted(Map<String, Object?> row) =>
      (row['preclick_retry_count'] as int? ?? 0) >= _handoffFailureLimit;

  Duration _handoffRetryDelay(int count) {
    const delays = [30, 60, 180];
    final index = _automationSessionId == null ? count : count - 1;
    return Duration(seconds: delays[index.clamp(0, delays.length - 1)]);
  }

  bool _handoffIsPreclick(Map<String, Object?> row) {
    if (row['transfer_clicked'] == 1 || row['acknowledged'] == 2) return false;
    final phase = row['phase']?.toString() ?? 'legacy';
    if (_handoffReplyResumePhase(phase) != null) {
      return row['attempt_id'] == null &&
          !const {'unconfirmed', 'transferred'}.contains(row['status']);
    }
    if (phase == 'legacy') {
      // These v28 statuses precede transferConversation. A legacy
      // `transferring`/`unconfirmed` result has no such proof.
      return const {'pending', 'ready', 'cancelled', 'failed', 'agents_busy'}
          .contains(row['status']);
    }
    return const {
      'reserved',
      'inspecting',
      'inspect_accounts',
      'ready',
      'acknowledged',
      'revalidate_target',
      'native_prepared',
      'retryable_preclick',
      'cancelled_preclick',
    }.contains(phase);
  }

  bool _legacyHandoffHasNoClickProof(Map<String, Object?> row) {
    if (row['phase'] != 'legacy' ||
        row['status'] != 'failed' ||
        row['transfer_clicked'] == 1 ||
        row['acknowledged'] == 2 ||
        (row['preclick_retry_count'] as int? ?? 0) != 0 ||
        (row['preclick_retry_at_ms'] as int? ?? 0) != 0) {
      return false;
    }
    final error = row['error']?.toString() ?? '';
    return error.contains('transfer_budget_exceeded') &&
        (error.contains('no transfer was clicked') ||
            error.contains('transferClicked: false') ||
            error.contains('"transferClicked":false') ||
            error.contains('"transferClicked": false'));
  }

  Future<File> _chatTransferReceipt(String attemptId) async => File(
      p.join((await storageRoot).path, 'transfer_receipts', '$attemptId.json'));

  /// Prepare a separate one-shot transfer journal before native invocation.
  /// A native call is not authorized until markTransferNativeInvoked succeeds.
  Future<Map<String, String>> beginTransferAttempt({
    required int logId,
    required String customer,
    required String targetAccount,
  }) async {
    if (customer.trim().isEmpty || targetAccount.trim().isEmpty) {
      throw ArgumentError('Transfer customer and target must be explicit');
    }
    final attemptId = _taskId();
    final receipt = await _chatTransferReceipt(attemptId);
    await receipt.parent.create(recursive: true);
    final temp = File('${receipt.path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'attemptId': attemptId,
          'customer': customer,
          'targetAccount': targetAccount,
          'state': 'prepared',
          'transferClicked': false,
          'timeMs': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true);
    await temp.rename(receipt.path);
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('chat_transfer_logs',
          where: 'id=? AND user_id=?', whereArgs: [logId, customer]);
      final control = await txn.query('conversation_control',
          where: _automationSessionId == null
              ? "user_id=? AND state='handoff_pending'"
              : "user_id=? AND state='human_contacting'",
          whereArgs: [customer]);
      final current = _automationSessionId == null ||
          (rows.isNotEmpty &&
              (await txn.rawQuery('''SELECT t.id FROM human_review_tickets t
        JOIN automation_session_tickets s ON s.ticket_id=t.id WHERE s.session_id=? AND t.id=? AND t.status='open' ''',
                      [_automationSessionId, rows.single['ticket_id']]))
                  .isNotEmpty);
      if (rows.length != 1 ||
          !current ||
          (_automationSessionId == null
              ? control.isEmpty
              : control.isNotEmpty) ||
          !_handoffIsPreclick(rows.single) ||
          _handoffAttemptsExhausted(rows.single) ||
          const {'transferred', 'unconfirmed'}
              .contains(rows.single['status']) ||
          (rows.single['target_account'] != null &&
              rows.single['target_account'] != targetAccount)) {
        throw StateError('Transfer selection invalidated before preparation');
      }
      await _bindReplyInputs(txn, customer, 'transfer:$attemptId',
          await _pendingSessionIds(customer, executor: txn));
      final cycle = (await txn.query('platform_response_cycles',
              where: "user_id=? AND state='waiting'", whereArgs: [customer]))
          .firstOrNull;
      await txn.update(
          'chat_transfer_logs',
          {
            'attempt_id': attemptId,
            'response_cycle_id': cycle?['cycle_id'],
            'phase': 'native_prepared',
            'transfer_clicked': 0,
            'owner_pid': pid,
            'target_account': targetAccount,
            'journal_seen_ms': 0,
            'attempt_started_at_ms': DateTime.now().millisecondsSinceEpoch,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id=?',
          whereArgs: [logId]);
    });
    RuntimeTrace.record('handoff.attempt_prepared', {
      'customer': customer,
      'logId': logId,
      'attemptId': attemptId,
      'target': targetAccount,
    });
    return {'attemptId': attemptId, 'receiptPath': receipt.path};
  }

  Future<void> markTransferNativeInvoked(int logId, String attemptId) async {
    final session = _automationSessionId;
    final sessionGuard = session == null
        ? ''
        : " AND EXISTS(SELECT 1 FROM human_review_tickets t JOIN automation_session_tickets s ON s.ticket_id=t.id WHERE t.id=chat_transfer_logs.ticket_id AND s.session_id=? AND t.status='open')";
    final changed = await (await database).update(
        'chat_transfer_logs',
        {
          'phase': 'invoking_native',
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
        },
        where:
            "id=? AND attempt_id=? AND phase='native_prepared' AND transfer_clicked=0 AND acknowledged!=2$sessionGuard",
        whereArgs: [logId, attemptId, if (session != null) session]);
    if (changed != 1) {
      throw StateError('Transfer journal lease invalidated');
    }
  }

  Future<bool> _otherTransferOwnerAlive(Map<String, Object?> row) async {
    final owner = row['owner_pid'] as int?;
    if (owner == null || owner <= 0 || owner == pid) return false;
    try {
      // Signal 0 only checks process existence; it never sends a signal.
      final result = await Process.run('/bin/kill', ['-0', '$owner'],
              environment: const {'LC_ALL': 'C', 'LANG': 'C'})
          .timeout(const Duration(seconds: 1));
      return result.exitCode == 0 ||
          !result.stderr.toString().contains('No such process');
    } catch (_) {
      return true; // inability to prove a foreign owner dead never grants retry
    }
  }

  /// Commit the exact native receipt against its frozen message revisions.
  /// The review ticket is mutable; it cannot veto the completed transfer or
  /// make newer messages part of it.
  Future<bool> settleConfirmedTransfer({
    required int logId,
    required String attemptId,
    DateTime? confirmedAt,
  }) async {
    final session = _automationSessionId;
    if (session == null || attemptId.isEmpty) return false;
    final db = await database;
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return false;
      final log = (await txn.rawQuery('''SELECT l.* FROM chat_transfer_logs l
        JOIN human_review_tickets t ON t.id=l.ticket_id AND t.user_id=l.user_id
        JOIN automation_session_tickets s ON s.ticket_id=t.id
        WHERE l.id=? AND l.attempt_id=? AND l.status='transferred'
          AND l.phase='confirmed' AND l.transfer_clicked=1
          AND s.session_id=? AND t.status!='session_archived' ''',
              [logId, attemptId, session]))
          .firstOrNull;
      if (log == null) return false;
      final settlementKey = '$logId:$attemptId';
      if ((await txn.query('automation_work_archive',
              columns: ['id'],
              where:
                  "session_id=? AND table_name='chat_transfer_settlements' AND record_key=?",
              whereArgs: [session, settlementKey],
              limit: 1))
          .isNotEmpty) {
        return false;
      }
      final customer = log['user_id']! as String;
      final ticketId = log['ticket_id']! as int;
      final ticket = (await txn.query('human_review_tickets',
              where: 'id=?', whereArgs: [ticketId]))
          .single;
      final control = (await txn.query('conversation_control',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      final operatorOwns = control?['state'] == 'human_contacting';
      final newerOwner = (await txn.rawQuery('''SELECT l.id
        FROM chat_transfer_logs l
        JOIN human_review_tickets t ON t.id=l.ticket_id
        JOIN automation_session_tickets s ON s.ticket_id=t.id
        WHERE l.user_id=? AND l.id>? AND s.session_id=?
          AND (t.status IN ('open','contacting') OR l.status='transferred')
        LIMIT 1''', [customer, logId, session])).isNotEmpty;
      final owner = 'transfer:$attemptId';
      final frozenMessageIds = await _replyInputIds(txn, customer, owner);
      final frozen =
          await _replyInputIds(txn, customer, owner, currentRevisionOnly: true);
      final request = ticket['request_message_id']?.toString();
      final originalRequest = log['request_message_id'];
      final now = DateTime.now().millisecondsSinceEpoch;
      var confirmationMs = confirmedAt?.millisecondsSinceEpoch;
      if (confirmationMs == null) {
        try {
          final receipt = jsonDecode(
                  await (await _chatTransferReceipt(attemptId)).readAsString())
              as Map;
          if (receipt['attemptId'] == attemptId &&
              receipt['customer'] == customer &&
              receipt['targetAccount'] == log['target_account'] &&
              receipt['state'] == 'confirmed' &&
              receipt['transferClicked'] == true &&
              receipt['timeMs'] is num &&
              (receipt['timeMs'] as num).isFinite &&
              (receipt['timeMs'] as num) > 0) {
            confirmationMs = (receipt['timeMs'] as num).toInt();
          }
        } catch (_) {
          // A verified synchronous result can settle without its receipt file.
        }
      }
      confirmationMs ??= log['updated_at_ms'] as int? ?? now;

      // Only pending messages at the exact input revision were delegated.
      await _completeReplyInputs(txn, customer, owner,
          attemptId: attemptId, state: 'delegated');
      final completedScope = await _retirePreTransferWork(txn, customer,
          confirmedAtMs: confirmationMs);
      frozenMessageIds.addAll(completedScope);
      frozen.addAll(completedScope);
      await _retireInvalidInputDraft(txn, customer);
      final leased = (await txn.query('pending_customers',
              where: 'user_id=? AND generation_token IS NOT NULL',
              whereArgs: [customer]))
          .firstOrNull;
      if (leased != null &&
          (await _replyInputIds(
                  txn, customer, leased['generation_token']! as String,
                  currentRevisionOnly: true))
              .isEmpty) {
        await txn.update('pending_customers', {'generation_token': null},
            where: 'id=? AND generation_token=?',
            whereArgs: [leased['id'], leased['generation_token']]);
      }

      int? independentTicketId;
      if (ticket['status'] == 'open' &&
          !operatorOwns &&
          request != null &&
          request != originalRequest &&
          !frozen.contains(request)) {
        // Preserve a newer request for review, with no lease or retry state
        // from the physically completed attempt.
        independentTicketId = (await txn.query('human_review_tickets',
                columns: ['id'],
                where:
                    "user_id=? AND id!=? AND request_message_id=? AND status IN ('open','contacting')",
                whereArgs: [customer, ticketId, request],
                limit: 1))
            .firstOrNull?['id'] as int?;
        if (independentTicketId == null) {
          independentTicketId = await txn.insert('human_review_tickets', {
            'user_id': customer,
            'customer_request': ticket['customer_request'],
            'reason': ticket['reason'],
            'status': 'open',
            'request_message_id': request,
            'created_at_ms': ticket['updated_at_ms'] ?? now,
            'updated_at_ms': now,
          });
          await txn.insert('automation_session_tickets',
              {'session_id': session, 'ticket_id': independentTicketId});
          await txn.update(
              'handoff_ai_fallbacks', {'ticket_id': independentTicketId},
              where:
                  'session_id=? AND user_id=? AND request_message_id=? AND ticket_id=?',
              whereArgs: [session, customer, request, ticketId]);
          await txn.insert(
              'handoff_ai_fallbacks',
              {
                'session_id': session,
                'user_id': customer,
                'request_message_id': request,
                'ticket_id': independentTicketId,
                'reason': _postTransferReviewReason,
                'created_at_ms': now,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      if (ticket['status'] != 'contacting' && !operatorOwns) {
        await txn.update(
            'human_review_tickets',
            {
              'status': 'contacted',
              'updated_at_ms': now,
              if (log['target_account'] != null)
                'assigned_to': log['target_account'],
              if (independentTicketId != null)
                'request_message_id': originalRequest,
            },
            where: 'id=?',
            whereArgs: [ticketId]);
      }

      if (!operatorOwns && !newerOwner) {
        final attemptStarted = log['attempt_started_at_ms'] as int?;
        final draft = (await txn.query('generated_drafts',
                where:
                    "user_id=? AND delivery_state='transfer_only' AND attempt_id IS NULL AND created_at_ms<=?",
                whereArgs: [customer, attemptStarted ?? 0]))
            .firstOrNull;
        if (draft != null &&
            frozenMessageIds.contains(draft['batch_end_message_id'])) {
          Map? raw;
          try {
            raw = jsonDecode(draft['raw_json']?.toString() ?? '{}') as Map;
          } on FormatException {
            // Its normal storage reader quarantines malformed drafts.
          } on TypeError {
            // Same for JSON that is not an object.
          }
          if (raw?['service_session_id'] == session) {
            await txn.insert('automation_work_archive', {
              'session_id': session,
              'table_name': 'generated_drafts',
              'record_key': customer,
              'row_json': jsonEncode(draft),
              'archived_at_ms': now,
            });
            await txn.delete('generated_drafts',
                where:
                    "user_id=? AND delivery_state='transfer_only' AND task_id IS ? AND attempt_id IS NULL",
                whereArgs: [customer, draft['task_id']]);
          }
        }
        final remaining = await _pendingSessionIds(customer, executor: txn);
        if (remaining.isEmpty) {
          final retainedDraft = await txn.query('generated_drafts',
              columns: ['user_id'], where: 'user_id=?', whereArgs: [customer]);
          final leasedGeneration = await txn.query('pending_customers',
              columns: ['user_id'],
              where: 'user_id=? AND generation_token IS NOT NULL',
              whereArgs: [customer]);
          // In a session the next newly pending message reopens reception;
          // there is no old message cursor to carry into a return transfer.
          if (retainedDraft.isEmpty && leasedGeneration.isEmpty) {
            await txn.rawInsert('''INSERT INTO conversation_control(
              user_id,state,resume_after_message_id,updated_at_ms)
              VALUES(?,'waiting_for_customer',NULL,?) ON CONFLICT(user_id)
              DO UPDATE SET state='waiting_for_customer',resume_after_message_id=NULL,
                updated_at_ms=excluded.updated_at_ms''', [customer, now]);
            await txn.delete('pending_customers',
                where: 'user_id=?', whereArgs: [customer]);
          }
        } else if (control?['state'] != 'ai_active') {
          await txn.rawInsert('''INSERT INTO conversation_control(
            user_id,state,resume_after_message_id,updated_at_ms)
            VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id)
            DO UPDATE SET state='ai_active',resume_after_message_id=NULL,
              updated_at_ms=excluded.updated_at_ms''', [customer, now]);
        }
      }
      final ownedCycle = log['response_cycle_id'];
      if (!operatorOwns && !newerOwner && ownedCycle != null) {
        final cleared = await txn.update('platform_response_cycles',
            {'state': 'cleared', 'observed_at_ms': now},
            where: "user_id=? AND cycle_id=? AND state='waiting'",
            whereArgs: [customer, ownedCycle]);
        if (cleared != 0) {
          await txn.update(
              'sla_fallbacks', {'state': 'completed', 'updated_at_ms': now},
              where: 'user_id=? AND batch_start_message_id=?',
              whereArgs: [customer, ownedCycle]);
        }
      }
      // Written in the same transaction as the effects. In particular, an
      // operator-owned ticket remains open to the operator without replays.
      await txn.insert('automation_work_archive', {
        'session_id': session,
        'table_name': 'chat_transfer_settlements',
        'record_key': settlementKey,
        'row_json': jsonEncode({
          'logId': logId,
          'customer': customer,
          'confirmed_at_ms': confirmationMs
        }),
        'archived_at_ms': now,
      });
      return true;
    });
  }

  /// Call on Start and maintenance with the current in-flight customer set.
  /// Recovered preparation can retry; click intent/unknown can only reconcile.
  Future<Set<String>> recoverChatTransferAttempts({
    required Set<String> activeCustomers,
  }) async {
    final db = await database;
    final session = _automationSessionId;
    final settled = <String>{};
    final rows = await db.rawQuery('''SELECT l.* FROM chat_transfer_logs l
      JOIN human_review_tickets t ON t.id=l.ticket_id
      WHERE (t.status='open' OR (? IS NOT NULL AND l.attempt_id IS NOT NULL
           AND t.status IN ('contacting','superseded_unconfirmed')
           AND l.status IN ('transferring','unconfirmed','transferred')))
        AND l.status IN ('pending','ready','transferring','cancelled','failed','unconfirmed','transferred')
        AND NOT EXISTS(SELECT 1 FROM automation_work_archive a
          WHERE a.session_id=? AND a.table_name='chat_transfer_settlements'
            AND a.record_key=l.id||':'||l.attempt_id)''', [session, session]);
    for (final row in rows) {
      if (!await isCurrentSessionTicket(row['ticket_id']! as int)) continue;
      final customer = row['user_id']! as String;
      if (activeCustomers.contains(customer) ||
          await _otherTransferOwnerAlive(row)) {
        continue;
      }
      final attemptId = row['attempt_id'] as String?;
      Future<void> settle() async {
        if (session != null && attemptId != null) {
          if (await settleConfirmedTransfer(
              logId: row['id']! as int, attemptId: attemptId)) {
            settled.add(customer);
          }
        } else {
          await markTicketContacted(row['ticket_id']! as int,
              assignedTo: row['target_account'] as String?);
        }
      }

      if (row['phase'] == 'confirmed' || row['status'] == 'transferred') {
        await settle();
        continue;
      }
      final owner = row['owner_pid'] as int?;
      final previousOwnerGone = owner != null && owner > 0 && owner != pid;
      Map<String, dynamic>? receipt;
      if (attemptId != null &&
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(attemptId)) {
        try {
          receipt = jsonDecode(
                  await (await _chatTransferReceipt(attemptId)).readAsString())
              as Map<String, dynamic>;
        } catch (_) {
          // Missing/corrupt native-invocation journals stay uncertain.
        }
      }
      final receiptTime = receipt?['timeMs'];
      final matching = receipt != null &&
          receipt['attemptId'] == attemptId &&
          receipt['customer'] == customer &&
          receipt['targetAccount'] == row['target_account'] &&
          receiptTime is num &&
          receiptTime.isFinite &&
          receiptTime > 0;
      final nativePhase = matching ? receipt['state']?.toString() : null;
      final journalAt = matching ? receiptTime.toInt() : 0;
      final clicked = row['transfer_clicked'] == 1 ||
          (matching && receipt['transferClicked'] == true) ||
          const {'click_intent', 'clicked', 'unknown'}.contains(nativePhase);
      final confirmed = matching &&
          nativePhase == 'confirmed' &&
          receipt['transferClicked'] == true;
      // A normal, already-classified failure keeps the caller's retry policy
      // (including an intentional zero retry_at). Recovery is not a second
      // timer that grants retries to every pre-click error.
      final legacyNoClick = _legacyHandoffHasNoClickProof(row);
      if (row['status'] == 'failed' &&
          _handoffIsPreclick(row) &&
          !confirmed &&
          !legacyNoClick) {
        continue;
      }
      final safe = !clicked &&
          row['acknowledged'] != 2 &&
          (_handoffIsPreclick(row) ||
              (matching &&
                  (nativePhase == 'not_clicked' ||
                      (nativePhase == 'prepared' && previousOwnerGone)) &&
                  receipt['transferClicked'] == false));
      final phase = confirmed
          ? 'confirmed'
          : safe
              ? 'retryable_preclick'
              : row['acknowledged'] == 2
                  ? 'acknowledgement_unknown'
                  : 'unknown';
      final status = confirmed
          ? 'transferred'
          : safe
              ? 'failed'
              : 'unconfirmed';
      final due = safe && !_handoffAttemptsExhausted(row)
          ? ((row['preclick_retry_at_ms'] as int? ?? 0) > 0
              ? row['preclick_retry_at_ms']
              : DateTime.now().millisecondsSinceEpoch)
          : 0;
      if (row['status'] == status &&
          row['phase'] == phase &&
          row['preclick_retry_at_ms'] == due &&
          (row['journal_seen_ms'] as int? ?? 0) >= journalAt) {
        if (confirmed) {
          await settle();
        }
        continue;
      }
      if (activeCustomers.contains(customer)) continue;
      final changed = await db.update(
          'chat_transfer_logs',
          {
            'status': status,
            'phase': phase,
            'transfer_clicked': clicked || confirmed ? 1 : 0,
            'preclick_retry_at_ms': due,
            'journal_seen_ms': journalAt,
            'error': confirmed
                ? null
                : safe
                    ? 'recovered_preclick_transfer'
                    : 'transfer_unconfirmed: recovered $phase',
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where:
              "id=? AND status=? AND phase=? AND COALESCE(attempt_id,'')=? AND updated_at_ms=?",
          whereArgs: [
            row['id'],
            row['status'],
            row['phase'],
            row['attempt_id'] ?? '',
            row['updated_at_ms']
          ]);
      if (changed == 0) continue;
      if (confirmed) {
        await settle();
      }
      RuntimeTrace.record('handoff.recovered', {
        'customer': customer,
        'logId': row['id'],
        'attemptId': attemptId,
        'nativePhase': nativePhase,
        'phase': phase,
        'transferClicked': clicked || confirmed
            ? true
            : safe
                ? false
                : null,
        'retryAtMs': due,
        'legacyNoClickProof': legacyNoClick,
        'handoffCompleted': confirmed,
        'caseResolved': null,
      });
    }
    return settled;
  }

  /// Persist retries only for explicitly proven pre-click failures. A crash,
  /// uncertain click, or uncertain acknowledgement never grants another click.
  Future<DateTime?> schedulePreclickTransferRetry(int logId) async {
    final db = await database;
    final row = (await db
            .query('chat_transfer_logs', where: 'id=?', whereArgs: [logId]))
        .single;
    if (!await isCurrentSessionTicket(row['ticket_id']! as int)) return null;
    final count = row['preclick_retry_count'] as int? ?? 0;
    if (row['status'] != 'failed' ||
        _handoffAttemptsExhausted(row) ||
        !_handoffIsPreclick(row)) {
      return null;
    }
    final due = DateTime.now().add(_handoffRetryDelay(count));
    await db.update('chat_transfer_logs',
        {'preclick_retry_at_ms': due.millisecondsSinceEpoch},
        where: "id=? AND status='failed'", whereArgs: [logId]);
    return due;
  }

  bool _apiTransferDraftMatches(Map<String, Object?> draft, String request) {
    try {
      final raw =
          jsonDecode(draft['raw_json']! as String) as Map<String, dynamic>;
      if (raw['service_session_id'] != _automationSessionId) return false;
      final scope = (raw['service_message_ids'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      if (scope.isEmpty &&
          _automationSessionId == null &&
          draft['batch_end_message_id'] is String) {
        scope.add(draft['batch_end_message_id']! as String);
      }
      return scope.contains(request) &&
          JdV2Payload.requestsTransfer(
              AiDraft.fromJson(raw, mediaBaseUrl: Uri()));
    } on FormatException {
      return false;
    }
  }

  /// Only the exact backend action for this ticket's frozen input can start
  /// automatic native handoff. A durable scoped receipt survives AI fallback.
  Future<bool> isApiTransferTicket(int ticketId) async {
    if (!await isCurrentSessionTicket(ticketId)) return false;
    final db = await database;
    final ticket = (await db.query('human_review_tickets',
            where: "id=? AND status='open'", whereArgs: [ticketId]))
        .firstOrNull;
    final request = ticket?['request_message_id'];
    if (ticket == null || request is! String || request.isEmpty) return false;
    final drafts = await db.query('generated_drafts',
        where: 'user_id=?', whereArgs: [ticket['user_id']]);
    final current = drafts
        .where((draft) => _apiTransferDraftMatches(draft, request))
        .firstOrNull;
    if (current != null) {
      // Tickets created before this authority receipt existed can resume from
      // their exact API draft without losing proof when fallback retires it.
      final prior = await db.query('automation_work_archive',
          columns: ['id'],
          where:
              'session_id=? AND table_name=? AND record_key=? AND row_json=?',
          whereArgs: [
            _automationSessionId ?? 'legacy',
            'api_transfer_authority',
            '$ticketId',
            jsonEncode({...current, 'request_message_id': request})
          ],
          limit: 1);
      if (prior.isEmpty) {
        await db.insert('automation_work_archive', {
          'session_id': _automationSessionId ?? 'legacy',
          'table_name': 'api_transfer_authority',
          'record_key': '$ticketId',
          'row_json': jsonEncode({...current, 'request_message_id': request}),
          'archived_at_ms': DateTime.now().millisecondsSinceEpoch,
        });
      }
      return true;
    }
    final proofs = await db.query('automation_work_archive',
        where: 'session_id=? AND table_name=? AND record_key=?',
        whereArgs: [
          _automationSessionId ?? 'legacy',
          'api_transfer_authority',
          '$ticketId'
        ]);
    return proofs.any((proof) {
      final saved =
          jsonDecode(proof['row_json']! as String) as Map<String, dynamic>;
      return saved['user_id'] == ticket['user_id'] &&
          saved['request_message_id'] == request &&
          _apiTransferDraftMatches(saved, request);
    });
  }

  Future<List<HumanReviewTicket>> duePreclickHandoffs() async {
    final rows = await (await database).query('chat_transfer_logs',
        where:
            "status IN ('failed','deferred') AND preclick_retry_at_ms>0 AND preclick_retry_at_ms<=? AND acknowledged!=2",
        whereArgs: [DateTime.now().millisecondsSinceEpoch]);
    final ids = rows
        .where(
            (row) => _handoffIsPreclick(row) && !_handoffAttemptsExhausted(row))
        .map((r) => r['ticket_id'])
        .toSet();
    // A fresh business request may have an independently verifiable current
    // reception even though an older attempt is unknown. This only schedules
    // a read-only ownership probe; it never authorizes the old transfer again.
    final unstarted = await (await database).rawQuery('''SELECT t.id
      FROM human_review_tickets t JOIN generated_drafts d ON d.user_id=t.user_id
      LEFT JOIN chat_transfer_logs l ON l.ticket_id=t.id
      WHERE t.status='open' AND t.request_message_id IS NOT NULL
        AND d.delivery_state='transfer_only' AND
        (l.id IS NULL OR (l.status='unconfirmed' AND
          COALESCE(l.request_message_id,'')<>t.request_message_id))
        AND NOT EXISTS(SELECT 1 FROM handoff_ai_fallbacks f
          WHERE f.session_id=? AND f.ticket_id=t.id
            AND f.request_message_id=t.request_message_id AND f.reason=?)''',
        [_automationSessionId ?? 'legacy', _postTransferReviewReason]);
    ids.addAll(unstarted.map((r) => r['id']));
    final result = <HumanReviewTicket>[];
    for (final ticket in await humanReviewTickets()) {
      if (ids.contains(ticket.id) && await isApiTransferTicket(ticket.id)) {
        result.add(ticket);
      }
    }
    return result;
  }

  Future<Map<String, Object?>?> handoffServiceStatus(String customer) async {
    final db = await database;
    final ticket = (await db.query('human_review_tickets',
            where: "user_id=? AND status='open'",
            whereArgs: [customer],
            orderBy: 'id DESC',
            limit: 1))
        .firstOrNull;
    if (ticket == null || ticket['request_message_id'] == null) return null;
    final control = (await db.query('conversation_control',
            where: 'user_id=?', whereArgs: [customer]))
        .firstOrNull;
    if (control?['state'] == 'human_contacting') return null;
    final draft = (await db.query('generated_drafts',
            columns: ['delivery_state'],
            where: 'user_id=?',
            whereArgs: [customer]))
        .firstOrNull;
    if (_automationSessionId == null &&
        draft?['delivery_state'] != 'transfer_only' &&
        !(control?['state']?.toString().startsWith('handoff_') ?? false)) {
      return null;
    }
    final log = (await db.query('chat_transfer_logs',
            where: 'ticket_id=?', whereArgs: [ticket['id']]))
        .firstOrNull;
    String reason = 'awaiting_transfer';
    var needsOperator = false;
    var newRequest = false;
    if (log == null &&
        (await db.query('handoff_ai_fallbacks',
                columns: ['ticket_id'],
                where:
                    'session_id=? AND ticket_id=? AND request_message_id=? AND reason=?',
                whereArgs: [
                  _automationSessionId ?? 'legacy',
                  ticket['id'],
                  ticket['request_message_id'],
                  _postTransferReviewReason
                ],
                limit: 1))
            .isNotEmpty) {
      reason = _postTransferReviewReason;
      needsOperator = true;
    }
    if (log != null) {
      newRequest = log['request_message_id'] != ticket['request_message_id'];
      if (log['acknowledged'] == 2) {
        reason = 'acknowledgement_unknown';
        needsOperator = true;
      } else if (log['status'] == 'unconfirmed' || log['phase'] == 'unknown') {
        reason = newRequest
            ? 'new_request_ownership_required'
            : 'previous_transfer_unknown';
        needsOperator = true;
      } else if (_handoffAttemptsExhausted(log) &&
          const {'failed', 'deferred', 'cancelled', 'agents_busy'}
              .contains(log['status'])) {
        reason = 'retry_exhausted';
        needsOperator = true;
      } else if (log['status'] == 'agents_busy') {
        reason = 'no_active_agents';
        needsOperator = true;
      } else if (log['status'] == 'deferred') {
        reason = log['phase']?.toString().startsWith('open_deferred:') == true
            ? 'conversation_open_pending'
            : 'reply_deferred';
      } else if (log['phase'] == 'already_current_agent_review') {
        reason = 'current_agent_review_required';
        needsOperator = true;
      } else if (log['status'] == 'failed' &&
          (log['preclick_retry_at_ms'] as int? ?? 0) == 0) {
        reason = 'preclick_failure_requires_operator';
        needsOperator = true;
      } else if (log['status'] == 'failed') {
        reason = 'retry_scheduled';
      } else if (log['status'] == 'transferred' ||
          log['phase'] == 'confirmed') {
        reason = 'transfer_confirmed';
      }
    }
    return {
      'customer': customer,
      'ticketId': ticket['id'],
      'requestMessageId': ticket['request_message_id'],
      'state': reason,
      'requiresOperator': needsOperator,
      'newRequest': newRequest,
      'logId': log?['id'],
      'transferPhase': log?['phase'],
      'transferStatus': log?['status'],
      'transferClicked': log?['transfer_clicked'],
      'sourceAccount': log?['source_account'],
      'oldRequestMessageId': log?['request_message_id'],
      'retryAtMs': log?['preclick_retry_at_ms'],
      'sinceMs': ticket['created_at_ms'],
      'handoffCompleted': reason == 'transfer_confirmed',
      'businessResponseSent': false,
      'caseResolved': null,
      'holdingDoesNotResolve': true
    };
  }

  Future<void> markTicketHandoffBlocked(int ticketId, String reason) async {
    if (!await isCurrentSessionTicket(ticketId)) return;
    if (_automationSessionId != null) {
      await releaseHandoffForAi(ticketId,
          reason: reason,
          unknownClick: RegExp('unknown|unconfirmed').hasMatch(reason));
      return;
    }
    final db = await database;
    await db.transaction((txn) async {
      final ticket = (await txn.query('human_review_tickets',
              where: "id=? AND status='open'", whereArgs: [ticketId]))
          .firstOrNull;
      if (ticket == null) return;
      final customer = ticket['user_id'];
      final control = (await txn.query('conversation_control',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      if (control?['state'] == 'human_contacting' ||
          control?['state'] == 'handoff_blocked:$reason') {
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.rawInsert(
          '''INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,?,NULL,?) ON CONFLICT(user_id) DO UPDATE SET state=excluded.state,
        resume_after_message_id=NULL,updated_at_ms=excluded.updated_at_ms''',
          [customer, 'handoff_blocked:$reason', now]);
      await txn.update('pending_customers', {'generation_token': null},
          where: 'user_id=?', whereArgs: [customer]);
      RuntimeTrace.record('handoff.business_blocked', {
        'customer': customer,
        'ticketId': ticketId,
        'requestMessageId': ticket['request_message_id'],
        'reason': reason,
        'handoffCompleted': false,
        'businessResponseSent': false,
        'caseResolved': null,
        'draftAndCursorPreserved': true,
        'holdingDoesNotResolve': true
      });
    });
  }

  Future<List<Map<String, Object?>>> blockedHandoffServices() async {
    final db = await database;
    final customers = _automationSessionId == null
        ? await db
            .rawQuery('''SELECT DISTINCT t.user_id FROM human_review_tickets t
      JOIN generated_drafts d ON d.user_id=t.user_id WHERE t.status='open'
      AND d.delivery_state='transfer_only' AND t.request_message_id IS NOT NULL''')
        : await db.rawQuery(
            '''SELECT DISTINCT t.user_id FROM human_review_tickets t
        JOIN automation_session_tickets s ON s.ticket_id=t.id WHERE s.session_id=? AND t.status='open' ''',
            [_automationSessionId]);
    final result = <Map<String, Object?>>[];
    for (final row in customers) {
      final status = await handoffServiceStatus(row['user_id']! as String);
      if (status?['requiresOperator'] == true) result.add(status!);
    }
    return result;
  }

  /// New requests cannot reset old unknown physical attempts. Only a fresh
  /// positive native reception proof plus independently checked source account
  /// may create a separate ticket/log while preserving the old unknown ledger.
  Future<HumanReviewTicket?> startNewHandoffAfterReceptionProof({
    required int ticketId,
    required Map<String, Object?> proof,
    required String sourceAccount,
  }) async {
    final ownerSession = _automationSessionId;
    if (!await isCurrentSessionTicket(ticketId)) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final observed = proof['observedAtMs'];
    if (proof['ownershipProof'] != 'current_enabled_empty_reception_ax' ||
        proof['ready'] != true ||
        proof['ownershipConfirmed'] != true ||
        proof['sourceAccount'] != sourceAccount ||
        sourceAccount.trim().isEmpty ||
        sourceAccount == '当前客服账号' ||
        observed is! num ||
        !observed.isFinite ||
        observed < now - 10000 ||
        observed > now + 1000) {
      return null;
    }
    final db = await database;
    final current = (await db.query('human_review_tickets',
            where: "id=? AND status='open'", whereArgs: [ticketId]))
        .firstOrNull;
    if (current == null) return null;
    final oldLog = (await db.query('chat_transfer_logs',
            where: 'ticket_id=?', whereArgs: [ticketId]))
        .firstOrNull;
    if (oldLog == null || await _otherTransferOwnerAlive(oldLog)) return null;
    final customer = current['user_id']! as String;
    if (proof['currentCustomer'] != customer ||
        proof['activeCustomerId'] != customer) {
      return null;
    }
    final requestMessageId = current['request_message_id']?.toString();
    if (ownerSession != null &&
        (requestMessageId == null ||
            !await isCurrentSessionMessage(customer, requestMessageId))) {
      return null;
    }
    final id = await db.transaction((txn) async {
      if (ownerSession != _automationSessionId ||
          (ownerSession != null &&
              (await txn.query('automation_session_tickets',
                      where: 'session_id=? AND ticket_id=?',
                      whereArgs: [ownerSession, ticketId]))
                  .isEmpty)) {
        return null;
      }
      final ticket = (await txn.query('human_review_tickets',
              where: "id=? AND status='open' AND request_message_id=?",
              whereArgs: [ticketId, current['request_message_id']]))
          .firstOrNull;
      final log = (await txn.query('chat_transfer_logs',
              where: 'id=? AND updated_at_ms=?',
              whereArgs: [oldLog['id'], oldLog['updated_at_ms']]))
          .firstOrNull;
      final control = (await txn.query('conversation_control',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      if (ticket == null ||
          log == null ||
          control?['state'] == 'human_contacting' ||
          log['status'] != 'unconfirmed' ||
          log['acknowledged'] == 2 ||
          log['source_account'] != sourceAccount ||
          ticket['request_message_id'] == null ||
          ticket['request_message_id'] == log['request_message_id']) {
        return null;
      }
      await txn.update('human_review_tickets',
          {'status': 'superseded_unconfirmed', 'updated_at_ms': now},
          where: 'id=?', whereArgs: [ticketId]);
      final newId = await txn.insert('human_review_tickets', {
        'user_id': customer,
        'customer_request': ticket['customer_request'],
        'reason': ticket['reason'],
        'status': 'open',
        'request_message_id': ticket['request_message_id'],
        'created_at_ms': now,
        'updated_at_ms': now
      });
      if (ownerSession != null) {
        await txn.insert('automation_session_tickets',
            {'session_id': ownerSession, 'ticket_id': newId});
      }
      // Reception proof changes native ownership, not the API decision. Bind
      // the same frozen decision to the replacement ticket before fallback can
      // retire its draft, so this request keeps its safe pre-click retries.
      final authorities = await txn.query('automation_work_archive',
          where: 'session_id=? AND table_name=? AND record_key=?',
          whereArgs: [
            ownerSession ?? 'legacy',
            'api_transfer_authority',
            '$ticketId'
          ]);
      for (final authority in authorities) {
        final saved = jsonDecode(authority['row_json']! as String)
            as Map<String, dynamic>;
        if (saved['user_id'] != customer ||
            saved['request_message_id'] != ticket['request_message_id'] ||
            !_apiTransferDraftMatches(
                saved, ticket['request_message_id']! as String)) {
          continue;
        }
        await txn.insert('automation_work_archive', {
          'session_id': ownerSession ?? 'legacy',
          'table_name': 'api_transfer_authority',
          'record_key': '$newId',
          'row_json': authority['row_json'],
          'archived_at_ms': now,
        });
      }
      RuntimeTrace.record('handoff.new_request_reception_reverified', {
        'customer': customer,
        'oldTicketId': ticketId,
        'ticketId': newId,
        'oldLogId': log['id'],
        'oldAttemptId': log['attempt_id'],
        'oldRequestMessageId': log['request_message_id'],
        'requestMessageId': ticket['request_message_id'],
        'sourceAccount': sourceAccount,
        'ownershipProof': proof['ownershipProof'],
        'oldUnknownPreserved': true
      });
      return newId;
    });
    if (id == null || ownerSession != _automationSessionId) return null;
    return (await humanReviewTickets()).where((t) => t.id == id).firstOrNull;
  }

  Future<ChatTransferLog?> reserveChatTransferLog({
    required HumanReviewTicket ticket,
  }) async {
    final ownerSession = _automationSessionId;
    if (!await isCurrentSessionTicket(ticket.id)) return null;
    final db = await database;
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession)) return null;
      final existing = await txn.query(
        'chat_transfer_logs',
        where: 'ticket_id = ?',
        whereArgs: [ticket.id],
        limit: 1,
      );
      final ticketRows = await txn.query(
        'human_review_tickets',
        columns: ['request_message_id', 'status'],
        where: 'id = ?',
        whereArgs: [ticket.id],
        limit: 1,
      );
      if (ticketRows.isEmpty || ticketRows.single['status'] != 'open') {
        return null;
      }
      final requestMessageId = ticketRows.isEmpty
          ? null
          : ticketRows.single['request_message_id']?.toString();
      // Native reservation requires a bound request. Automatic callers also
      // verify the exact API action through isApiTransferTicket.
      if (requestMessageId == null || requestMessageId.isEmpty) return null;
      if ((await txn.query('handoff_ai_fallbacks',
              columns: ['ticket_id'],
              where:
                  'session_id=? AND ticket_id=? AND request_message_id=? AND reason=?',
              whereArgs: [
                ownerSession ?? 'legacy',
                ticket.id,
                requestMessageId,
                _postTransferReviewReason
              ],
              limit: 1))
          .isNotEmpty) {
        return null;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (existing.isNotEmpty) {
        final row = existing.single.cast<String, Object?>();
        if (await _otherTransferOwnerAlive(row)) return null;
        final status = row['status']?.toString();
        if (!const {'failed', 'agents_busy', 'cancelled', 'deferred'}
                .contains(status) ||
            !_handoffIsPreclick(row)) {
          return null;
        }
        // The same request can resume only within its bounded safe pre-click
        // policy. A later request starts its own independent attempt budget.
        if (requestMessageId == row['request_message_id']?.toString()) {
          final due = row['preclick_retry_at_ms'] as int? ?? 0;
          final cancelledBeforeClick = status == 'cancelled';
          final resume = _handoffReplyResumePhase(row['phase']);
          final deferred = status == 'deferred';
          if ((deferred &&
                  (ownerSession == null ||
                      row['owner_pid'] != pid ||
                      resume == null ||
                      row['attempt_id'] != null)) ||
              (!cancelledBeforeClick && status != 'failed' && !deferred) ||
              (!cancelledBeforeClick && due <= 0) ||
              now < due ||
              _handoffAttemptsExhausted(row)) {
            return null;
          }
          await txn.update(
              'chat_transfer_logs',
              {
                'status': 'pending',
                'phase': deferred
                    ? '${row['phase']?.toString().startsWith('open_deferred:') == true ? 'open_resuming' : 'reply_resuming'}:$resume'
                    : 'reserved',
                'attempt_id': null,
                'transfer_clicked': 0,
                'owner_pid': pid,
                'journal_seen_ms': 0,
                'attempt_started_at_ms': null,
                'preclick_retry_at_ms': 0,
                'preclick_retry_count':
                    (row['preclick_retry_count'] as int? ?? 0) +
                        (ownerSession == null ? 1 : 0),
                'updated_at_ms': now,
              },
              where: 'id=?',
              whereArgs: [row['id']]);
          return ChatTransferLog.fromJson({...row, 'status': 'pending'});
        }
        await txn.update(
          'chat_transfer_logs',
          {
            'status': 'pending',
            'phase': 'reserved',
            'attempt_id': null,
            'transfer_clicked': 0,
            'owner_pid': pid,
            'journal_seen_ms': 0,
            'attempt_started_at_ms': null,
            'reason': ticket.reason,
            'target_account': null,
            'error': null,
            'request_message_id': requestMessageId,
            'preclick_retry_count': 0,
            'preclick_retry_at_ms': 0,
            'acknowledged': 0,
            'updated_at_ms': now,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        final refreshed = (await txn.query(
          'chat_transfer_logs',
          where: 'id = ?',
          whereArgs: [row['id']],
          limit: 1,
        ))
            .single;
        return ChatTransferLog.fromJson(refreshed.cast<String, Object?>());
      }
      final id = await txn.insert('chat_transfer_logs', {
        'ticket_id': ticket.id,
        'user_id': ticket.conversationId,
        'source_account': '当前客服账号',
        'reason': ticket.reason,
        'status': 'pending',
        'phase': 'reserved',
        'owner_pid': pid,
        'request_message_id': requestMessageId,
        'created_at_ms': now,
        'updated_at_ms': now,
      });
      final row = (await txn.query(
        'chat_transfer_logs',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      ))
          .single;
      return ChatTransferLog.fromJson(row.cast<String, Object?>());
    });
  }

  Future<void> updateChatTransferLog({
    required int id,
    required String status,
    String? sourceAccount,
    String? targetAccount,
    String? error,
    String? phase,
    bool? transferClicked,
    String? expectedAttemptId,
  }) async {
    await (await database).transaction((txn) async {
      final rows =
          await txn.query('chat_transfer_logs', where: 'id=?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final old = rows.single;
      if (expectedAttemptId != null && old['attempt_id'] != expectedAttemptId) {
        return;
      }
      if ((old['phase'] == 'confirmed' || old['status'] == 'transferred') &&
          status != 'transferred') {
        return;
      }
      final clicked = old['transfer_clicked'] == 1 || transferClicked == true;
      var nextPhase = phase ?? old['phase']?.toString() ?? 'legacy';
      var nextStatus = status;
      if (status == 'transferred') {
        nextPhase = 'confirmed';
      } else if (status == 'unconfirmed') {
        nextPhase = 'unknown';
      } else if (clicked) {
        nextPhase = 'unknown';
        nextStatus = 'unconfirmed';
      } else if (old['acknowledged'] == 2 &&
          const {'failed', 'cancelled', 'unconfirmed'}.contains(status)) {
        nextPhase = 'acknowledgement_unknown';
        nextStatus = 'unconfirmed';
      } else if (phase == null) {
        if (status == 'ready') nextPhase = 'ready';
        if (status == 'transferring') nextPhase = 'revalidate_target';
        if (const {'failed', 'cancelled', 'agents_busy'}.contains(status)) {
          if (_handoffIsPreclick(old)) {
            nextPhase = status == 'cancelled'
                ? 'cancelled_preclick'
                : 'retryable_preclick';
          } else {
            nextPhase = 'unknown';
            nextStatus = 'unconfirmed';
          }
        }
      }
      await txn.update(
          'chat_transfer_logs',
          {
            'status': nextStatus,
            'phase': nextPhase,
            'transfer_clicked': clicked || status == 'transferred' ? 1 : 0,
            if (sourceAccount?.trim().isNotEmpty == true)
              'source_account': sourceAccount!.trim(),
            if (targetAccount?.trim().isNotEmpty == true)
              'target_account': targetAccount!.trim(),
            'error': error,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id=?',
          whereArgs: [id]);
    });
  }

  /// Picks the least-recently used active account. Never-used accounts come
  /// first, and a stable lexical tie-break keeps the choice deterministic.
  Future<String> chooseAutomaticTransferAccount(
      Iterable<String> activeAccounts) async {
    final accounts = activeAccounts
        .map((account) => account.trim())
        .where((account) => account.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (accounts.isEmpty) {
      throw StateError('No active JD transfer account is available.');
    }
    final rows = await (await database).query(
      'chat_transfer_logs',
      columns: ['target_account', 'updated_at_ms'],
      where: "status = 'transferred' AND target_account IS NOT NULL",
      orderBy: 'updated_at_ms DESC',
    );
    final lastUsed = <String, int>{};
    for (final row in rows) {
      final account = row['target_account']?.toString();
      if (account != null) {
        lastUsed.putIfAbsent(
            account, () => (row['updated_at_ms'] as num).toInt());
      }
    }
    accounts.sort((left, right) {
      final leftAt = lastUsed[left];
      final rightAt = lastUsed[right];
      if (leftAt == null && rightAt != null) return -1;
      if (leftAt != null && rightAt == null) return 1;
      final byTime = (leftAt ?? 0).compareTo(rightAt ?? 0);
      return byTime != 0 ? byTime : left.compareTo(right);
    });
    return accounts.first;
  }

  Future<List<HumanReviewTicket>> humanReviewTickets() async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: "status IN ('open','contacting')",
        orderBy: 'updated_at_ms DESC, id DESC');
    return rows
        .map((row) => HumanReviewTicket(
              id: row['id']! as int,
              conversationId: row['user_id']! as String,
              customerRequest: row['customer_request']! as String,
              reason: row['reason']! as String,
              status: row['status']! as String,
              assignedTo: row['assigned_to'] as String?,
            ))
        .toList(growable: false);
  }

  Future<int> improveGenericTicketReasons() async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        columns: ['id', 'user_id', 'reason'],
        where: "status IN ('open','contacting')");
    var updated = 0;
    for (final row in rows) {
      final reason = row['reason']?.toString().trim() ?? '';
      if (reason.isNotEmpty && reason != 'Codex requested human review.') {
        continue;
      }
      final document = await (await history).read(row['user_id']! as String);
      final messages = (document?['messages'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final generated = messages.toList().reversed.firstWhere(
          (item) => item['source'] == 'generated_reply',
          orElse: () => const {});
      final metadata = generated['reply_metadata'];
      if (metadata is! Map<String, dynamic>) continue;
      final raw = metadata['raw_response'];
      if (raw is! Map<String, dynamic>) continue;
      final improved = _reasonFromResponse(raw, metadata);
      updated += await db.update(
          'human_review_tickets',
          {
            'reason': improved,
            'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [row['id']]);
    }
    return updated;
  }

  String _reasonFromResponse(
      Map<String, dynamic> raw, Map<String, dynamic> metadata) {
    final explicit = raw['reason']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty && explicit != 'null') {
      return explicit;
    }
    final triggers = (raw['risk_triggers'] as List<Object?>? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final escalation = (raw['actions'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((item) {
          final type = item['type']?.toString().toLowerCase() ?? '';
          return type.contains('human') ||
              type.contains('escalat') ||
              type.contains('route');
        })
        .map((item) => item['description']?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty);
    final details = <String>{...triggers, ...escalation}.toList();
    final risk = metadata['risk_level']?.toString() ?? 'unknown';
    return details.isEmpty
        ? 'Human review required because this reply was classified as $risk risk.'
        : 'Human review required ($risk risk): ${details.join('. ')}';
  }

  Future<HumanReviewTicket> createHumanReviewTicket({
    required String userId,
    required String customerRequest,
    required String reason,
    String? requestMessageId,
  }) async {
    final session = _automationSessionId;
    if (requestMessageId != null &&
        !await isCurrentSessionMessage(userId, requestMessageId)) {
      throw StateError(
          'Archived session request cannot create a current handoff');
    }
    final db = await database;
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) {
        throw StateError(
            'Archived session request cannot create a current handoff');
      }
      final existing = (await txn.query('human_review_tickets',
              where: "user_id = ? AND status IN ('open','contacting')",
              whereArgs: [userId],
              orderBy: 'id DESC',
              limit: 1))
          .firstOrNull;
      final now = DateTime.now().millisecondsSinceEpoch;
      final int ticketId;
      if (existing == null) {
        ticketId = await txn.insert('human_review_tickets', {
          'user_id': userId,
          'customer_request': customerRequest,
          'reason': reason,
          'status': 'open',
          'request_message_id': requestMessageId,
          'created_at_ms': now,
          'updated_at_ms': now,
        });
        await txn.rawInsert('''INSERT INTO conversation_control(
          user_id,state,resume_after_message_id,updated_at_ms)
          VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id) DO UPDATE SET
          state='ai_active',resume_after_message_id=NULL,
          updated_at_ms=excluded.updated_at_ms''', [userId, now]);
      } else {
        ticketId = existing['id']! as int;
        if (requestMessageId?.isNotEmpty == true) {
          // Reading and updating the ticket share the settlement transaction
          // boundary, so a concurrent new request cannot reopen a closed one.
          await txn.update(
              'human_review_tickets',
              {
                'customer_request': customerRequest,
                'reason': reason,
                if (existing['status'] == 'open') 'assigned_to': null,
                'request_message_id': requestMessageId,
                'updated_at_ms': now,
              },
              where: 'id=?',
              whereArgs: [ticketId]);
        }
      }
      if (session != null) {
        await txn.insert('automation_session_tickets',
            {'session_id': session, 'ticket_id': ticketId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      if (requestMessageId != null) {
        final drafts = await txn
            .query('generated_drafts', where: 'user_id=?', whereArgs: [userId]);
        for (final draft in drafts) {
          if (!_apiTransferDraftMatches(draft, requestMessageId)) continue;
          await txn.insert('automation_work_archive', {
            'session_id': session ?? 'legacy',
            'table_name': 'api_transfer_authority',
            'record_key': '$ticketId',
            'row_json':
                jsonEncode({...draft, 'request_message_id': requestMessageId}),
            'archived_at_ms': now,
          });
        }
      }
      final saved = (await txn.query('human_review_tickets',
              where: 'id=?', whereArgs: [ticketId]))
          .single;
      return HumanReviewTicket(
          id: ticketId,
          conversationId: userId,
          customerRequest: saved['customer_request']! as String,
          reason: saved['reason']! as String,
          status: saved['status']! as String,
          assignedTo: saved['assigned_to'] as String?);
    });
  }

  Future<Map<String, Object?>?> _currentHandoffReplyRow(
    DatabaseExecutor executor, {
    required int ticketId,
    required String sessionId,
  }) async =>
      (await executor.rawQuery('''SELECT l.* FROM chat_transfer_logs l
        JOIN human_review_tickets t ON t.id=l.ticket_id
        JOIN automation_session_tickets s ON s.ticket_id=t.id
        WHERE s.session_id=? AND t.id=? AND t.status='open'
          AND l.user_id=t.user_id AND l.request_message_id=t.request_message_id
          AND NOT EXISTS(SELECT 1 FROM conversation_control c
            WHERE c.user_id=t.user_id AND c.state='human_contacting')''',
              [sessionId, ticketId]))
          .firstOrNull;

  bool _handoffReplyCanContinue(Map<String, Object?> row) =>
      row['owner_pid'] == pid &&
      row['attempt_id'] == null &&
      row['transfer_clicked'] != 1 &&
      row['acknowledged'] != 2 &&
      const {'pending', 'ready', 'transferring', 'failed', 'deferred'}
          .contains(row['status']) &&
      _handoffIsPreclick(row) &&
      !_handoffAttemptsExhausted(row);

  /// A response deadline pauses only this transfer's safe pre-click work.
  /// The checkpoint is usable solely in its current run and exact request.
  Future<Map<String, Object?>?> handoffReplyContinuation(int ticketId) async {
    final session = _automationSessionId;
    if (session == null) return null;
    final db = await database;
    final before = await _currentHandoffReplyRow(db,
        ticketId: ticketId, sessionId: session);
    if (before == null ||
        !_handoffReplyCanContinue(before) ||
        _handoffReplyResumePhase(before['phase']) == null ||
        !await isCurrentSessionMessage(before['user_id']! as String,
            before['request_message_id']! as String)) {
      return null;
    }
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return null;
      final row = await _currentHandoffReplyRow(txn,
          ticketId: ticketId, sessionId: session);
      if (row == null ||
          !_handoffReplyCanContinue(row) ||
          row['request_message_id'] != before['request_message_id']) {
        return null;
      }
      final resume = _handoffReplyResumePhase(row['phase']);
      if (resume == null) return null;
      return <String, Object?>{
        'logId': row['id'],
        'requestMessageId': row['request_message_id'],
        'sourceAccount': row['source_account'],
        'targetAccount': row['target_account'],
        'resumePhase': resume,
      };
    });
  }

  /// A response yield retains only a current, exact-request pre-click
  /// checkpoint. Failed backoff and uncertain physical work do not own it.
  Future<bool> hasResumableHandoffCheckpoint() async {
    final session = _automationSessionId;
    if (session == null) return false;
    final rows = await (await database).query('chat_transfer_logs',
        columns: ['ticket_id'],
        where:
            "phase LIKE 'reply_deferred:%' OR phase LIKE 'reply_resuming:%'");
    for (final row in rows) {
      if (await handoffReplyContinuation(row['ticket_id']! as int) != null &&
          _automationSessionId == session) {
        return true;
      }
    }
    return false;
  }

  /// AX/header settlement is unfinished workflow, not a failed transfer.
  /// Keep the selected target and exact request without claiming the reply
  /// UI slot while waiting. An invoked native transfer is never reset here.
  Future<bool> deferHandoffForOpenRecovery({
    required int logId,
    required int ticketId,
    required String resumePhase,
    required String reason,
  }) async {
    final session = _automationSessionId;
    if (session == null ||
        !const {'inspect_accounts', 'acknowledge', 'revalidate_target'}
            .contains(resumePhase)) {
      return false;
    }
    final db = await database;
    final before = await _currentHandoffReplyRow(db,
        ticketId: ticketId, sessionId: session);
    bool safeOpenBoundary(Map<String, Object?> row) =>
        row['owner_pid'] == pid &&
        row['transfer_clicked'] != 1 &&
        row['acknowledged'] != 2 &&
        const {'pending', 'ready', 'transferring', 'deferred'}
            .contains(row['status']) &&
        _handoffIsPreclick(row) &&
        !_handoffAttemptsExhausted(row) &&
        (row['attempt_id'] == null
            ? row['phase'] != 'native_prepared'
            : row['phase'] == 'native_prepared');
    if (before == null ||
        before['id'] != logId ||
        !safeOpenBoundary(before) ||
        !await isCurrentSessionMessage(before['user_id']! as String,
            before['request_message_id']! as String)) {
      return false;
    }
    if (resumePhase != 'inspect_accounts' &&
        ((before['source_account']?.toString().trim().isEmpty ?? true) ||
            (before['target_account']?.toString().trim().isEmpty ?? true) ||
            before['source_account'] == before['target_account'])) {
      return false;
    }
    final attempt = before['attempt_id'];
    if (attempt != null) {
      if (attempt is! String ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(attempt)) {
        return false;
      }
      Map receipt;
      try {
        receipt = jsonDecode(
            await (await _chatTransferReceipt(attempt)).readAsString()) as Map;
      } catch (_) {
        return false;
      }
      final time = receipt['timeMs'];
      final started = before['attempt_started_at_ms'];
      if (receipt['attemptId'] != attempt ||
          receipt['customer'] != before['user_id'] ||
          receipt['targetAccount'] != before['target_account'] ||
          receipt['state'] != 'prepared' ||
          receipt['transferClicked'] != false ||
          time is! num ||
          !time.isFinite ||
          time <= 0 ||
          started is! num ||
          started <= 0 ||
          time > started) {
        return false;
      }
    }
    final customer = before['user_id']! as String;
    final request = before['request_message_id']! as String;
    final document = await (await history).read(customer);
    final requestMessage = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((message) =>
            message['direction'] == 'incoming' &&
            _matchesWorkId(message, {request}))
        .firstOrNull;
    final requestAliases = <String>{
      request,
      if (requestMessage != null)
        ...ConversationFileStore.messageAliases(requestMessage)
    };
    final deferred = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return false;
      final current = await _currentHandoffReplyRow(txn,
          ticketId: ticketId, sessionId: session);
      if (current == null ||
          current['id'] != logId ||
          !safeOpenBoundary(current) ||
          current['request_message_id'] != before['request_message_id'] ||
          current['attempt_id'] != before['attempt_id'] ||
          current['phase'] != before['phase'] ||
          current['status'] != before['status'] ||
          current['acknowledged'] != before['acknowledged'] ||
          current['source_account'] != before['source_account'] ||
          current['target_account'] != before['target_account']) {
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final prior = (await txn.query('handoff_ai_fallbacks',
              where: 'session_id=? AND user_id=? AND request_message_id=?',
              whereArgs: [session, customer, request]))
          .firstOrNull;
      if (prior?['unknown_click'] == 1) return false;
      await _retireTransferOnlyDecision(txn, customer, requestAliases,
          ownerSession: session, now: now);
      await txn.insert(
          'handoff_ai_fallbacks',
          {
            'session_id': session,
            'user_id': customer,
            'request_message_id': request,
            'ticket_id': ticketId,
            'reason': 'conversation_open_pending',
            'unknown_click': 0,
            'created_at_ms': now,
            'yield_count': prior?['yield_count'] ?? 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.rawInsert(
          "INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms) VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id) DO UPDATE SET state='ai_active',resume_after_message_id=NULL,updated_at_ms=excluded.updated_at_ms",
          [customer, now]);
      await txn.update(
          'chat_transfer_logs',
          {
            'status': 'deferred',
            'phase': 'open_deferred:$resumePhase',
            'error': reason,
            'attempt_id': null,
            'attempt_started_at_ms': null,
            'preclick_retry_at_ms': now + 1000,
            'updated_at_ms': now,
          },
          where: 'id=?',
          whereArgs: [logId]);
      return true;
    });
    if (deferred && _automationSessionId == session) {
      await ensurePendingForUnanswered(customer);
    }
    return deferred;
  }

  Future<bool> deferHandoffForReply({
    required int logId,
    required int ticketId,
    required String resumePhase,
    String? provenNotClickedAttemptId,
  }) async {
    final session = _automationSessionId;
    if (session == null ||
        !const {'inspect_accounts', 'acknowledge', 'revalidate_target'}
            .contains(resumePhase)) {
      return false;
    }
    final db = await database;
    var before = await _currentHandoffReplyRow(db,
        ticketId: ticketId, sessionId: session);
    if (before == null ||
        before['id'] != logId ||
        !await isCurrentSessionMessage(before['user_id']! as String,
            before['request_message_id']! as String)) {
      return false;
    }
    if (resumePhase != 'inspect_accounts' &&
        ((before['source_account']?.toString().trim().isEmpty ?? true) ||
            (before['target_account']?.toString().trim().isEmpty ?? true) ||
            before['source_account'] == before['target_account'])) {
      return false;
    }
    if (provenNotClickedAttemptId != null) {
      if (resumePhase != 'revalidate_target' ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(provenNotClickedAttemptId)) {
        return false;
      }
      bool pendingNativeBoundary(Map<String, Object?> row) =>
          row['owner_pid'] == pid &&
          row['attempt_id'] == provenNotClickedAttemptId &&
          row['transfer_clicked'] != 1 &&
          row['acknowledged'] != 2 &&
          const {'pending', 'ready', 'transferring'}.contains(row['status']) &&
          const {'native_prepared', 'invoking_native'}.contains(row['phase']) &&
          !_handoffAttemptsExhausted(row);
      if (!pendingNativeBoundary(before)) return false;
      Map<String, dynamic> receipt;
      try {
        receipt = jsonDecode(
            await (await _chatTransferReceipt(provenNotClickedAttemptId))
                .readAsString()) as Map<String, dynamic>;
      } catch (_) {
        return false;
      }
      final time = receipt['timeMs'];
      final started = before['attempt_started_at_ms'];
      if (receipt['attemptId'] != provenNotClickedAttemptId ||
          receipt['customer'] != before['user_id'] ||
          receipt['targetAccount'] != before['target_account'] ||
          receipt['state'] != 'not_clicked' ||
          receipt['transferClicked'] != false ||
          time is! num ||
          !time.isFinite ||
          started is! num ||
          time < started ||
          time > DateTime.now().millisecondsSinceEpoch + 1000) {
        return false;
      }
      final proven = before;
      final finished = await db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, session)) return false;
        final row = await _currentHandoffReplyRow(txn,
            ticketId: ticketId, sessionId: session);
        if (row == null ||
            row['id'] != logId ||
            row['request_message_id'] != proven['request_message_id'] ||
            row['source_account'] != proven['source_account'] ||
            row['target_account'] != proven['target_account'] ||
            !pendingNativeBoundary(row)) {
          return false;
        }
        // The native not-clicked receipt is retained unchanged. Only this
        // finished invocation is released; the next try prepares a new ID.
        await txn.update(
            'chat_transfer_logs',
            {
              'status': 'ready',
              'phase': 'revalidate_target',
              'attempt_id': null,
              'attempt_started_at_ms': null,
              'journal_seen_ms': time.toInt(),
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch,
            },
            where: 'id=? AND attempt_id=?',
            whereArgs: [logId, provenNotClickedAttemptId]);
        return true;
      });
      if (!finished) return false;
      before = await _currentHandoffReplyRow(db,
          ticketId: ticketId, sessionId: session);
      if (before == null) return false;
    }
    if (!_handoffReplyCanContinue(before)) return false;
    final checkpointRequest = before['request_message_id'];
    // Keep the existing AI continuation and exact transfer-only retirement
    // behavior. Only the transfer's scheduling/result classification changes.
    if (!await releaseHandoffForAi(ticketId,
        reason: 'handoff_yielded_for_reply')) {
      return false;
    }
    return db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, session)) return false;
      final row = await _currentHandoffReplyRow(txn,
          ticketId: ticketId, sessionId: session);
      if (row == null ||
          row['id'] != logId ||
          row['request_message_id'] != checkpointRequest ||
          !_handoffReplyCanContinue(row)) {
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
          'chat_transfer_logs',
          {
            'status': 'deferred',
            'phase': 'reply_deferred:$resumePhase',
            'error': null,
            'preclick_retry_at_ms': now + 1000,
            'updated_at_ms': now,
          },
          where: 'id=?',
          whereArgs: [logId]);
      return true;
    });
  }

  /// Read the bound original customer message, never the multi-message ticket
  /// summary, which can contain other names or requests from earlier turns.
  Future<String?> handoffRequestText(int ticketId) async {
    if (!await isCurrentSessionTicket(ticketId)) return null;
    final row = (await (await database).query('human_review_tickets',
            where: 'id=?', whereArgs: [ticketId], limit: 1))
        .firstOrNull;
    final request = row?['request_message_id']?.toString();
    if (row == null || request?.isNotEmpty != true) return null;
    final document = await (await history).read(row['user_id']! as String);
    final message = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['direction'] == 'incoming' &&
            _matchesWorkId(m, {request!}) &&
            (m['media'] as List? ?? const []).isEmpty &&
            !const {
              'media',
              'image_ocr',
              'video_subtitle',
              'video_speech',
              'video_transcript',
              'audio_transcript',
              'media_analysis'
            }.contains(m['text_origin']) &&
            !const {
              'image_ocr',
              'video_subtitle',
              'video_transcript',
              'audio_transcript',
              'media_analysis'
            }.contains(m['source']))
        .firstOrNull;
    final body = message?['body']?.toString();
    if (message == null ||
        !RegExp(r'^(?:是|是的|对|对的|确认|确定|要|好的|好|可以|没错|yes|yes please|please do|correct|confirmed|confirm|ok|okay)[。！!,.\s]*$',
                caseSensitive: false)
            .hasMatch((body ?? '')
                .replaceAll(RegExp(r'[，,]'), ' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim())) {
      return body;
    }
    // A confirmed "yes" keeps the original named colleague. Read only the
    // exact originals linked by the immediately preceding sent confirmation;
    // the ticket summary and unrelated names in history grant no target.
    DateTime? time(Map value) => DateTime.tryParse(
        (value['sent_at'] ?? value['captured_at'])?.toString() ?? '');
    final now = time(message);
    if (now == null) return body;
    final historyMessages =
        (document?['messages'] as List? ?? const []).whereType<Map>().toList();
    final previous = historyMessages
        .where((m) =>
            m['direction'] == 'outgoing' &&
            time(m) != null &&
            time(m)!.isBefore(now))
        .toList()
      ..sort((a, b) => time(a)!.compareTo(time(b)!));
    if (previous.isEmpty) return body;
    final confirmation = previous.last;
    final sentAt = time(confirmation)!;
    final raw = (confirmation['reply_metadata'] as Map?)?['raw_response'];
    if (confirmation['source'] != 'generated_reply' ||
        !const {'sent', 'submitted', 'accepted'}
            .contains(confirmation['delivery_status']) ||
        now.difference(sentAt) > const Duration(minutes: 10) ||
        raw is! Map ||
        raw['model'] != 'jd-two-request-handoff-v1' ||
        raw['handoff_intent_confirmation'] != true ||
        !const {'transfer', 'after_sales'}
            .contains(raw['handoff_confirmation_kind']) ||
        raw['service_session_id'] != _automationSessionId) {
      return body;
    }
    final originals = historyMessages.where((m) =>
        m['direction'] == 'incoming' &&
        (m['media'] as List? ?? const []).isEmpty &&
        m['media_receipt_id'] == null &&
        !const {
          'media',
          'image_ocr',
          'video_subtitle',
          'video_speech',
          'video_transcript',
          'audio_transcript',
          'media_analysis'
        }.contains(m['text_origin']) &&
        !const {
          'image_ocr',
          'video_subtitle',
          'video_transcript',
          'audio_transcript',
          'media_analysis'
        }.contains(m['source']));
    if (originals.any((m) =>
        m['id'] != message['id'] &&
        time(m) != null &&
        time(m)!.isAfter(sentAt) &&
        time(m)!.isBefore(now))) {
      return body;
    }
    final ids = (raw['handoff_request_message_ids'] as List? ?? const [])
        .whereType<String>()
        .toSet();
    final named = <String, String>{};
    for (final original in originals) {
      final at = time(original);
      if (at == null ||
          at.isAfter(sentAt) ||
          now.difference(at) > const Duration(minutes: 10) ||
          !_matchesWorkId(original, ids)) {
        continue;
      }
      final text = original['body']?.toString() ?? '';
      final request = NamedAgentRequest.parse(text);
      if (request != null) named[request.target] = text;
    }
    if (named.length > 1) {
      throw StateError('Confirmed transfer names more than one colleague.');
    }
    return named.values.firstOrNull ?? body;
  }

  /// The requested colleague is already the AX-confirmed serving account.
  /// Retire only an unclicked named-transfer decision; every real question
  /// remains pending until a confirmed substantive reply covers it.
  Future<bool> satisfyCurrentAgentHandoff(int ticketId,
      {required String currentServiceAccount,
      required String requestedTarget,
      bool preserveAuthorityReview = false}) async {
    final owner = _automationSessionId;
    if (currentServiceAccount.trim().isEmpty ||
        !await isCurrentSessionTicket(ticketId)) {
      return false;
    }
    final db = await database;
    final ticket = (await db.query('human_review_tickets',
            where: "id=? AND status='open'", whereArgs: [ticketId]))
        .firstOrNull;
    if (ticket == null) return false;
    final text = await handoffRequestText(ticketId);
    final request = text == null ? null : NamedAgentRequest.parse(text);
    if (request == null ||
        request.target != requestedTarget ||
        !request.matchesAccount(currentServiceAccount)) {
      return false;
    }
    // Identity does not grant order/account authority. Such tickets remain
    // review work even when a customer also mentioned the current colleague.
    final authority = RegExp(
        r'(?<![A-Za-z])(?:order|refund|invoice|after.?sales|authority|account (?:change|action))(?![A-Za-z])|订单|退款|退货|发票|售后|权限',
        caseSensitive: false);
    final authorityRequired = authority
            .hasMatch(ticket['reason']?.toString() ?? '') ||
        RegExp(r'退款|退货|修改.{0,8}订单|取消.{0,8}订单|改.{0,8}地址|开.{0,5}发票|\b(?:refund|cancel|change|update).{0,20}(?:order|address)\b',
                caseSensitive: false)
            .hasMatch(text!);
    if (authorityRequired && !preserveAuthorityReview) {
      return false;
    }
    final keepReview = preserveAuthorityReview && authorityRequired;
    final reason = ticket['reason']?.toString() ?? '';
    if (!keepReview &&
        !RegExp(r'explicit.*(?:human|colleague|agent)|named.*(?:agent|transfer)|指定.{0,8}客服|要求.{0,8}(?:转接|客服|人工)|requested.*(?:human|colleague|agent)',
                caseSensitive: false)
            .hasMatch(reason)) {
      return false;
    }
    final customer = ticket['user_id']! as String;
    final requestId = ticket['request_message_id']! as String;
    final document = await (await history).read(customer);
    final source = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) => _matchesWorkId(m, {requestId}))
        .firstOrNull;
    if (source == null) return false;
    final requestAliases = ConversationFileStore.messageAliases(source);
    final beforeLogs = await db.query('chat_transfer_logs',
        where: 'ticket_id=?', whereArgs: [ticketId]);
    for (final log in beforeLogs) {
      if (!_handoffIsPreclick(log) ||
          const {'transferred', 'unconfirmed'}.contains(log['status'])) {
        return false;
      }
      final attempt = log['attempt_id'];
      if (attempt is! String) continue;
      final receipt = await _chatTransferReceipt(attempt);
      if (!await receipt.exists()) return false;
      try {
        final proof = jsonDecode(await receipt.readAsString()) as Map;
        if (proof['attemptId'] != attempt ||
            proof['customer'] != customer ||
            proof['transferClicked'] != false ||
            !const {'prepared', 'preclick_failed', 'cancelled_preclick'}
                .contains(proof['state'])) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }
    final changed = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, owner)) return false;
      final current = (await txn.query('human_review_tickets',
              where: "id=? AND status='open'", whereArgs: [ticketId]))
          .firstOrNull;
      if (current == null ||
          current['user_id'] != customer ||
          current['request_message_id'] != requestId) {
        return false;
      }
      final control = (await txn.query('conversation_control',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      if (control?['state'] == 'human_contacting') return false;
      final logs = (await txn.query('chat_transfer_logs',
              where: 'ticket_id=?', whereArgs: [ticketId]))
          .toList();
      if (logs.length != beforeLogs.length ||
          logs.any((log) => !beforeLogs.any((prior) =>
              prior['id'] == log['id'] &&
              prior['attempt_id'] == log['attempt_id'] &&
              prior['phase'] == log['phase'] &&
              prior['status'] == log['status']))) {
        return false;
      }
      if (logs.any((row) =>
          row['transfer_clicked'] == 1 ||
          row['acknowledged'] == 2 ||
          const {'transferred', 'unconfirmed'}.contains(row['status']) ||
          !_handoffIsPreclick(row))) {
        return false;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final drafts = await txn.query('generated_drafts',
          where: "user_id=? AND delivery_state='transfer_only'",
          whereArgs: [customer]);
      for (final draft in drafts) {
        final raw = jsonDecode(draft['raw_json']?.toString() ?? '{}') as Map;
        final scope = <String>{
          if (draft['batch_end_message_id'] is String)
            draft['batch_end_message_id']! as String,
          ...(raw['service_message_ids'] as List? ?? const [])
              .whereType<String>(),
        };
        if (scope.intersection(requestAliases).isEmpty) continue;
        await txn.insert('automation_work_archive', {
          'session_id': owner ?? 'legacy',
          'table_name': 'generated_drafts',
          'record_key': customer,
          'row_json': jsonEncode(draft),
          'archived_at_ms': now,
        });
        await txn.delete('generated_drafts',
            where:
                "user_id=? AND delivery_state='transfer_only' AND task_id IS ?",
            whereArgs: [customer, draft['task_id']]);
        if (owner != null && draft['task_id'] is String) {
          await txn.delete('automation_message_waits',
              where: 'session_id=? AND user_id=? AND task_id=?',
              whereArgs: [owner, customer, draft['task_id']]);
          await txn.delete('automation_reply_inputs',
              where: 'session_id=? AND user_id=? AND owner_id=?',
              whereArgs: [owner, customer, draft['task_id']]);
        }
      }
      if (keepReview && logs.isEmpty) {
        final id = await txn.insert('chat_transfer_logs', {
          'ticket_id': ticketId,
          'user_id': customer,
          'source_account': currentServiceAccount.trim(),
          'target_account': currentServiceAccount.trim(),
          'reason': reason,
          'status': 'cancelled',
          'phase': 'already_current_agent_review',
          'request_message_id': requestId,
          'transfer_clicked': 0,
          'preclick_retry_at_ms': 0,
          'created_at_ms': now,
          'updated_at_ms': now,
        });
        logs.add({'id': id, 'attempt_id': null});
      }
      for (final log in logs) {
        await txn.update(
            'chat_transfer_logs',
            {
              'status': 'cancelled',
              'phase': keepReview
                  ? 'already_current_agent_review'
                  : 'already_current_agent',
              'source_account': currentServiceAccount.trim(),
              'target_account': currentServiceAccount.trim(),
              'error': null,
              'preclick_retry_at_ms': 0,
              'updated_at_ms': now,
            },
            where: 'id=?',
            whereArgs: [log['id']]);
        if (log['attempt_id'] is String) {
          await txn.delete('automation_reply_inputs',
              where: 'session_id=? AND user_id=? AND owner_id=?',
              whereArgs: [
                owner ?? 'legacy',
                customer,
                'transfer:${log['attempt_id']}'
              ]);
        }
      }
      if (keepReview) {
        await txn.insert(
            'handoff_ai_fallbacks',
            {
              'session_id': owner ?? 'legacy',
              'user_id': customer,
              'request_message_id': requestId,
              'ticket_id': ticketId,
              'reason': 'current_agent_review_required',
              'unknown_click': 0,
              'created_at_ms': now,
              'yield_count': 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await txn.delete('handoff_ai_fallbacks',
            where: 'ticket_id=?', whereArgs: [ticketId]);
      }
      await txn.update(
          'human_review_tickets',
          {
            'status': keepReview ? 'open' : 'current_agent',
            'assigned_to': currentServiceAccount.trim(),
            'updated_at_ms': now,
          },
          where: 'id=?',
          whereArgs: [ticketId]);
      await txn.rawInsert(
          "INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms) VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id) DO UPDATE SET state='ai_active',resume_after_message_id=NULL,updated_at_ms=excluded.updated_at_ms",
          [customer, now]);
      return true;
    });
    if (changed) await ensurePendingForUnanswered(customer);
    return changed;
  }

  Future<bool> isHandoffExecutionCurrent(int ticketId) async {
    if (!await isCurrentSessionTicket(ticketId)) return false;
    final row = (await (await database).query('human_review_tickets',
            where: "id=? AND status='open'", whereArgs: [ticketId]))
        .firstOrNull;
    return row != null && !await isHumanContacting(row['user_id']! as String);
  }

  Future<Map<String, Object?>?> handoffFallbackContext(String customer,
      {String? batchEndMessageId}) async {
    final rows = await (await database).query('handoff_ai_fallbacks',
        where: 'session_id=? AND user_id=?',
        whereArgs: [_automationSessionId ?? 'legacy', customer],
        orderBy: 'created_at_ms DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return {
      'ticketId': row['ticket_id'],
      'requestMessageId': row['request_message_id'],
      'batchEndMessageId': batchEndMessageId,
      'reason': row['reason'],
      'unknownClick': row['unknown_click'] == 1,
      'continueAi': true,
      'continue_ai': true,
      'handoffCompleted': false,
      'caseResolved': null,
      'sameRequestAutoHandoffSuppressed': true
    };
  }

  Future<bool> isHandoffSuppressed(
      String customer, String requestMessageId) async {
    final rows = await (await database).rawQuery(
        '''SELECT f.* FROM handoff_ai_fallbacks f
      JOIN human_review_tickets t ON t.id=f.ticket_id WHERE f.session_id=? AND f.user_id=? AND t.status='open' ''',
        [_automationSessionId ?? 'legacy', customer]);
    if (rows.any((r) => r['request_message_id'] == requestMessageId)) {
      return true;
    }
    final document = await (await history).read(customer);
    final request = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((message) =>
            message['direction'] == 'incoming' &&
            ConversationFileStore.messageAliases(message)
                .contains(requestMessageId))
        .firstOrNull;
    if (request == null) return false;
    final aliases = ConversationFileStore.messageAliases(request);
    return rows.any((row) => aliases.contains(row['request_message_id']));
  }

  /// A transfer-only model decision is internal routing work, not a formal
  /// answer. Retire only the exact request decision; retain every real reply.
  Future<void> _retireTransferOnlyDecision(
      DatabaseExecutor txn, String customer, Set<String> requestAliases,
      {required String? ownerSession, required int now}) async {
    final drafts = await txn.query('generated_drafts',
        where: "user_id=? AND delivery_state='transfer_only'",
        whereArgs: [customer]);
    for (final draft in drafts) {
      // Only the failed decision for this exact task may be retired.
      final raw = jsonDecode(draft['raw_json']?.toString() ?? '{}') as Map;
      final scope = <String>{
        if (draft['batch_end_message_id'] is String)
          draft['batch_end_message_id']! as String,
        ...(raw['service_message_ids'] as List? ?? const [])
            .whereType<String>(),
      };
      if (requestAliases.isEmpty ||
          scope.intersection(requestAliases).isEmpty ||
          raw['service_session_id'] != null &&
              raw['service_session_id'] != ownerSession) {
        continue;
      }
      await txn.insert('automation_work_archive', {
        'session_id': ownerSession ?? 'legacy',
        'table_name': 'generated_drafts',
        'record_key': customer,
        'row_json': jsonEncode(draft),
        'archived_at_ms': now
      });
      await txn.delete('generated_drafts',
          where:
              "user_id=? AND delivery_state='transfer_only' AND task_id IS ?",
          whereArgs: [customer, draft['task_id']]);
    }
  }

  Future<bool> releaseHandoffForAi(int ticketId,
      {required String reason,
      bool unknownClick = false,
      bool countPreclickFailure = false}) async {
    final ownerSession = _automationSessionId;
    if (!await isCurrentSessionTicket(ticketId)) return false;
    final db = await database;
    final row = (await db.query('human_review_tickets',
            where: "id=? AND status='open'", whereArgs: [ticketId]))
        .firstOrNull;
    if (row == null) return false;
    final customer = row['user_id']! as String;
    if (await isHumanContacting(customer)) return false;
    final request = row['request_message_id']?.toString() ?? '';
    final document = await (await history).read(customer);
    final requestMessage = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((message) =>
            message['direction'] == 'incoming' &&
            _matchesWorkId(message, {request}))
        .firstOrNull;
    final requestAliases = <String>{
      if (request.isNotEmpty) request,
      if (requestMessage != null)
        ...ConversationFileStore.messageAliases(requestMessage),
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final released = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession) ||
          (await txn.query('human_review_tickets',
                  where: "id=? AND status='open' AND request_message_id IS ?",
                  whereArgs: [ticketId, row['request_message_id']]))
              .isEmpty) {
        return false;
      }
      final control = (await txn.query('conversation_control',
              where: 'user_id=?', whereArgs: [customer]))
          .firstOrNull;
      if (control?['state'] == 'human_contacting') return false;
      final prior = (await txn.query('handoff_ai_fallbacks',
              where: 'session_id=? AND user_id=? AND request_message_id=?',
              whereArgs: [_automationSessionId ?? 'legacy', customer, request]))
          .firstOrNull;
      final yielded = reason == 'handoff_yielded_for_reply';
      final yields = (prior?['yield_count'] as int? ?? 0) + (yielded ? 1 : 0);
      await txn.insert(
          'handoff_ai_fallbacks',
          {
            'session_id': _automationSessionId ?? 'legacy',
            'user_id': customer,
            'request_message_id': request,
            'ticket_id': ticketId,
            'reason': reason,
            'unknown_click': unknownClick ? 1 : 0,
            'created_at_ms': now,
            'yield_count': yields
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _retireTransferOnlyDecision(txn, customer, requestAliases,
          ownerSession: ownerSession, now: now);
      await txn.rawInsert(
          "INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms) VALUES(?,'ai_active',NULL,?) ON CONFLICT(user_id) DO UPDATE SET state='ai_active',resume_after_message_id=NULL,updated_at_ms=excluded.updated_at_ms",
          [customer, now]);
      final log = (await txn.query('chat_transfer_logs',
              where: 'ticket_id=?', whereArgs: [ticketId]))
          .firstOrNull;
      if (!unknownClick &&
          log != null &&
          log['transfer_clicked'] != 1 &&
          log['acknowledged'] != 2 &&
          log['status'] != 'transferred' &&
          _handoffIsPreclick(log)) {
        final priorCount = log['preclick_retry_count'] as int? ?? 0;
        final count = ownerSession == null
            ? max(0, priorCount - (yielded ? 1 : 0))
            : min(handoffMaxAttempts,
                priorCount + (countPreclickFailure && !yielded ? 1 : 0));
        final retryAt = count < _handoffFailureLimit
            ? now + _handoffRetryDelay(count).inMilliseconds
            : 0;
        await txn.update(
            'chat_transfer_logs',
            {
              'status': 'failed',
              'phase': 'retryable_preclick',
              'error': reason,
              'preclick_retry_count': count,
              'preclick_retry_at_ms': retryAt,
              'updated_at_ms': now
            },
            where: 'id=?',
            whereArgs: [log['id']]);
      }
      return true;
    });
    if (!released) return false;
    await ensurePendingForUnanswered(customer);
    RuntimeTrace.record('handoff.ai_continues', {
      'customer': customer,
      'ticketId': ticketId,
      'reason': reason,
      'unknownClick': unknownClick,
      'pendingTodoPreserved': true,
      'cursorAdvanced': false,
      'continueAi': true
    });
    return true;
  }

  Future<bool> wakeCurrentHandoffAfterIdentity(String customer) async {
    final db = await database;
    final tickets = await db.query('human_review_tickets',
        where: "user_id=? AND status='open'", whereArgs: [customer]);
    var changed = false;
    for (final ticket in tickets) {
      if (!await isCurrentSessionTicket(ticket['id']! as int)) continue;
      final logs = await db.query('chat_transfer_logs',
          where:
              "ticket_id=? AND status='failed' AND transfer_clicked=0 AND acknowledged!=2",
          whereArgs: [ticket['id']]);
      for (final log in logs) {
        final error = log['error']?.toString() ?? '';
        if (!RegExp(r'conversation_not_found|row_resolution|identity_unresolved|reception_not_focused')
                .hasMatch(error) ||
            !_handoffIsPreclick(log)) {
          continue;
        }
        if (_handoffAttemptsExhausted(log)) continue;
        await db.update('chat_transfer_logs',
            {'preclick_retry_at_ms': DateTime.now().millisecondsSinceEpoch},
            where: 'id=?', whereArgs: [log['id']]);
        changed = true;
      }
    }
    return changed;
  }

  Future<bool> isHandoffPending(String userId) async {
    if (_automationSessionId != null) {
      final tickets = await (await database).rawQuery(
          '''SELECT t.id FROM human_review_tickets t
        JOIN automation_session_tickets s ON s.ticket_id=t.id WHERE s.session_id=? AND t.user_id=? AND t.status='open' ''',
          [_automationSessionId, userId]);
      return tickets.isNotEmpty;
    }
    final rows = await (await database).query('conversation_control',
        columns: ['state'], where: 'user_id=?', whereArgs: [userId]);
    return rows.firstOrNull?['state']?.toString().startsWith('handoff_') ??
        false;
  }

  /// Waiting for a transfer is not successful delivery or agent acceptance.
  /// Retain drafts/cursors and keep the red-clock response service running.
  Future<void> markTicketHandoffPending(int ticketId) async {
    if (!await isCurrentSessionTicket(ticketId)) return;
    final db = await database;
    final rows = await db
        .query('human_review_tickets', where: 'id=?', whereArgs: [ticketId]);
    if (rows.isEmpty) return;
    final customer = rows.single['user_id'];
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = await db.transaction((txn) async {
      final current = await txn.query('human_review_tickets',
          where: 'id=? AND status=?', whereArgs: [ticketId, 'open']);
      final control = await txn.query('conversation_control',
          where: "user_id=? AND state='human_contacting'",
          whereArgs: [customer]);
      if (current.isEmpty || control.isNotEmpty) return false;
      await txn.update(
          'human_review_tickets', {'status': 'open', 'updated_at_ms': now},
          where: 'id=?', whereArgs: [ticketId]);
      if (_automationSessionId == null) {
        await txn.update('pending_customers', {'generation_token': null},
            where: 'user_id=?', whereArgs: [customer]);
      }
      final nextControl =
          _automationSessionId == null ? 'handoff_pending' : 'ai_active';
      await txn.rawInsert(
          "INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms) VALUES(?,?,NULL,?) ON CONFLICT(user_id) DO UPDATE SET state=excluded.state,resume_after_message_id=NULL,updated_at_ms=excluded.updated_at_ms",
          [customer, nextControl, now]);
      return true;
    });
    if (!changed) return;
    RuntimeTrace.record('handoff.pending', {
      'customer': customer,
      'ticketId': ticketId,
      'draftAndCursorPreserved': true,
      'holdingActive': true
    });
  }

  Future<void> markTicketContacting(int ticketId) async {
    if (!await isCurrentSessionTicket(ticketId)) return;
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if ((await txn.query('human_review_tickets',
              where: "id=? AND status='open'", whereArgs: [ticketId]))
          .isEmpty) {
        return;
      }
      await txn.update('human_review_tickets',
          {'status': 'contacting', 'updated_at_ms': now},
          where: 'id = ?', whereArgs: [ticketId]);
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'human_contacting',NULL,?) ON CONFLICT(user_id) DO UPDATE SET
        state='human_contacting',resume_after_message_id=NULL,
        updated_at_ms=excluded.updated_at_ms''', [userId, now]);
      await txn.delete('pending_customers',
          where: 'user_id = ?', whereArgs: [userId]);
      await txn.delete('generated_drafts',
          where: 'user_id = ?', whereArgs: [userId]);
      await txn.update(
          'sla_fallbacks',
          {
            'state': 'cancelled',
            'updated_at_ms': now,
          },
          where: 'user_id = ?',
          whereArgs: [userId]);
    });
  }

  /// Transfer and delivery outcomes never suppress later customer messages.
  Future<void> markTicketAwaitingCurrentAgent(int ticketId) async {
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'human_review_tickets',
        {'status': 'open', 'updated_at_ms': now},
        where: 'id = ?',
        whereArgs: [ticketId],
      );
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'ai_active',NULL,?)
        ON CONFLICT(user_id) DO UPDATE SET
        state='ai_active',resume_after_message_id=NULL,
        updated_at_ms=excluded.updated_at_ms''', [userId, now]);
    });
  }

  Future<void> markTicketContacted(int ticketId, {String? assignedTo}) async {
    if (!await isCurrentSessionTicket(ticketId)) return;
    final db = await database;
    final rows = await db.query('human_review_tickets',
        where: 'id = ?', whereArgs: [ticketId], limit: 1);
    if (rows.isEmpty) return;
    final userId = rows.first['user_id']! as String;
    final transfer = (await db.query('chat_transfer_logs',
            where: 'ticket_id=?', whereArgs: [ticketId], limit: 1))
        .firstOrNull;
    if (_automationSessionId != null &&
        transfer?['attempt_id'] is String &&
        (transfer?['phase'] == 'confirmed' ||
            transfer?['status'] == 'transferred')) {
      await settleConfirmedTransfer(
          logId: transfer!['id']! as int,
          attemptId: transfer['attempt_id']! as String);
      return;
    }
    final attemptStarted = transfer?['attempt_started_at_ms'] as int?;
    final completionCutoff =
        attemptStarted ?? transfer?['updated_at_ms'] as int?;
    final cycleSnapshot = (await db.query('platform_response_cycles',
            where: 'user_id=?', whereArgs: [userId], limit: 1))
        .firstOrNull;
    final slaSnapshot = (await db.query('sla_fallbacks',
            where: 'user_id=?', whereArgs: [userId], limit: 1))
        .firstOrNull;
    final draftSnapshot = (await db.query('generated_drafts',
            where: "user_id=? AND delivery_state='transfer_only'",
            whereArgs: [userId],
            limit: 1))
        .firstOrNull;
    final messages = await processingMessages(userId);
    final boundary = messages.reversed
        .where((message) => message['direction'] == 'incoming')
        .map((message) => message['id'] as String?)
        .whereType<String>()
        .firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final current = (await txn.query('human_review_tickets',
              where: 'id=?', whereArgs: [ticketId], limit: 1))
          .firstOrNull;
      final newerTicket = await txn.query('human_review_tickets',
          where: "user_id=? AND id!=? AND status IN ('open','contacting')",
          whereArgs: [userId, ticketId],
          limit: 1);
      if (current == null ||
          current['status'] == 'session_archived' ||
          newerTicket.isNotEmpty ||
          current['request_message_id'] != rows.first['request_message_id'] ||
          (transfer != null &&
              transfer['request_message_id'] !=
                  current['request_message_id'])) {
        RuntimeTrace.record('handoff.completion_deferred', {
          'customer': userId,
          'ticketId': ticketId,
          'reason': 'newer_review_request'
        });
        return;
      }
      await txn.update(
          'human_review_tickets',
          {
            'status': 'contacted',
            'updated_at_ms': now,
            if (assignedTo?.trim().isNotEmpty == true)
              'assigned_to': assignedTo!.trim(),
          },
          where: 'id = ?',
          whereArgs: [ticketId]);
      if (_automationSessionId != null) {
        final confirmed = transfer?['phase'] == 'confirmed' ||
            transfer?['status'] == 'transferred';
        if (confirmed) {
          final attempt = transfer?['attempt_id']?.toString();
          if (attempt != null) {
            await _completeReplyInputs(txn, userId, 'transfer:$attempt',
                attemptId: attempt, state: 'delegated');
          }
          // The human owns only the messages frozen when the handoff began.
          // Newly received questions remain independently runnable.
          final remaining = await _pendingSessionIds(userId, executor: txn);
          await txn.rawInsert(
              '''INSERT INTO conversation_control(user_id,state,resume_after_message_id,updated_at_ms)
            VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET state=excluded.state,
            resume_after_message_id=excluded.resume_after_message_id,updated_at_ms=excluded.updated_at_ms''',
              [
                userId,
                remaining.isEmpty ? 'waiting_for_customer' : 'ai_active',
                boundary,
                now
              ]);
          if (remaining.isEmpty) {
            await txn.delete('pending_customers',
                where: 'user_id=?', whereArgs: [userId]);
          }
          if (draftSnapshot != null &&
              !await _draftInputsCurrent(txn, userId, draftSnapshot)) {
            await txn.delete('generated_drafts',
                where:
                    "user_id=? AND delivery_state='transfer_only' AND task_id IS ?",
                whereArgs: [userId, draftSnapshot['task_id']]);
          }
          final ownedCycle = transfer?['response_cycle_id'];
          if (ownedCycle != null) {
            await txn.update('platform_response_cycles',
                {'state': 'cleared', 'observed_at_ms': now},
                where: "user_id=? AND cycle_id=? AND state='waiting'",
                whereArgs: [userId, ownedCycle]);
            await txn.update(
                'sla_fallbacks', {'state': 'completed', 'updated_at_ms': now},
                where: 'user_id=? AND batch_start_message_id=?',
                whereArgs: [userId, ownedCycle]);
          }
        }
        return;
      }
      await txn.rawInsert('''INSERT INTO conversation_control(
        user_id,state,resume_after_message_id,updated_at_ms)
        VALUES(?,'waiting_for_customer',?,?) ON CONFLICT(user_id) DO UPDATE SET
        state='waiting_for_customer',resume_after_message_id=excluded.resume_after_message_id,
        updated_at_ms=excluded.updated_at_ms''', [userId, boundary, now]);
      final requestId = transfer?['request_message_id']?.toString();
      final requestIndex = _messageIndex(messages, requestId);
      final pending = (await txn.query('pending_customers',
              where: 'user_id=?', whereArgs: [userId], limit: 1))
          .firstOrNull;
      final pendingIndex =
          _messageIndex(messages, pending?['newest_message_id']);
      if (transfer == null ||
          pending == null ||
          (requestIndex >= 0 &&
              pendingIndex >= 0 &&
              pendingIndex <= requestIndex)) {
        await txn.delete('pending_customers',
            where: 'user_id = ?', whereArgs: [userId]);
      }
      // Commit the old decision and its frozen cursor with ticket completion.
      // A crash after this transaction can no longer strand transfer_only.
      final draftEnd = draftSnapshot?['batch_end_message_id']?.toString();
      final draftIndex = _messageIndex(messages, draftEnd);
      if ((transfer?['phase'] == 'confirmed' ||
              transfer?['status'] == 'transferred') &&
          draftSnapshot != null &&
          completionCutoff != null &&
          (draftSnapshot['created_at_ms']! as int) <= completionCutoff &&
          requestIndex >= 0 &&
          draftIndex >= 0 &&
          draftIndex <= requestIndex) {
        final deleted = await txn.delete('generated_drafts',
            where: "user_id=? AND delivery_state='transfer_only' AND "
                "created_at_ms=? AND COALESCE(task_id,'')=? AND batch_end_message_id=?",
            whereArgs: [
              userId,
              draftSnapshot['created_at_ms'],
              draftSnapshot['task_id'] ?? '',
              draftEnd
            ]);
        if (deleted > 0) {
          final cursor = (await txn.query('answered_cursors',
                  where: 'user_id=?', whereArgs: [userId]))
              .firstOrNull;
          final cursorIndex = _messageIndex(messages, cursor?['message_id']);
          if (cursor == null ||
              (cursorIndex >= 0 && cursorIndex < draftIndex)) {
            await txn.rawInsert(
                '''INSERT INTO answered_cursors(user_id,message_id)
              VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET message_id=excluded.message_id''',
                [userId, draftEnd]);
          }
        }
      }
      // A positively confirmed handoff ends this agent's old response duty.
      // Never use it to clear a newer cycle created after the transfer began.
      if (cycleSnapshot != null &&
          (completionCutoff == null ||
              (cycleSnapshot['started_at_ms']! as int) <= completionCutoff)) {
        final cleared = await txn.update('platform_response_cycles',
            {'state': 'cleared', 'observed_at_ms': now},
            where: 'user_id=? AND cycle_id=? AND started_at_ms=?',
            whereArgs: [
              userId,
              cycleSnapshot['cycle_id'],
              cycleSnapshot['started_at_ms'],
            ]);
        if (cleared > 0) {
          await txn.update(
              'sla_fallbacks', {'state': 'completed', 'updated_at_ms': now},
              where: 'user_id=? AND batch_start_message_id=?',
              whereArgs: [userId, cycleSnapshot['cycle_id']]);
        }
      } else if (cycleSnapshot == null && slaSnapshot != null) {
        final batchStarted = slaSnapshot['batch_started_at_ms'] as int?;
        if (completionCutoff == null ||
            (batchStarted != null && batchStarted <= completionCutoff)) {
          await txn.update(
              'sla_fallbacks', {'state': 'completed', 'updated_at_ms': now},
              where:
                  "user_id=? AND message_id=? AND COALESCE(batch_start_message_id,'')=? AND updated_at_ms=?",
              whereArgs: [
                userId,
                slaSnapshot['message_id'],
                slaSnapshot['batch_start_message_id'] ?? '',
                slaSnapshot['updated_at_ms'],
              ]);
        }
      }
    });
  }

  Future<bool> isHumanContacting(String userId) async {
    final db = await database;
    final rows = await db.query('conversation_control',
        columns: ['state'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1);
    return rows.isNotEmpty && rows.first['state'] == 'human_contacting';
  }

  /// A positive receipt on the exact, recent outgoing reply can resolve a
  /// missed Send confirmation. Missing icons and other seller replies cannot.
  Future<bool> confirmObservedGeneratedDraft({
    required String userId,
    required CapturedMessage message,
    required DateTime capturedAt,
  }) async {
    if (message.direction != 'outgoing' ||
        !message.deliveryConfirmed ||
        message.sentAt == null ||
        await isHumanContacting(userId)) {
      return false;
    }
    if (_automationSessionId != null) {
      final archived = await (await database).rawQuery(
          '''SELECT a.* FROM delivery_attempts a
        JOIN automation_archived_attempts s ON s.attempt_id=a.attempt_id WHERE a.user_id=? AND a.kind='reply' ''',
          [userId]);
      final body = message.body.replaceAll(RegExp(r'\s+'), '');
      final clock = message.sentAt!.millisecondsSinceEpoch;
      if (archived.any((a) =>
          body ==
              (a['reply']?.toString() ?? '').replaceAll(RegExp(r'\s+'), '') &&
          clock >= (a['created_at_ms']! as int) - 1000 &&
          clock <= (a['created_at_ms']! as int) + 15000)) {
        await (await history).confirmObservedOutgoing(
            userId: userId,
            messageId: message.stableId,
            deliveryStatus: 'ownership_unverified');
        RuntimeTrace.record('delivery.archived_observation_isolated', {
          'customer': userId,
          'messageId': message.stableId,
          'currentTaskPreserved': true
        });
        return true;
      }
    }
    if (await _confirmDetachedObserved(userId, message, capturedAt)) {
      return true;
    }
    final rows = await (await database).query('generated_drafts',
        where: '''user_id=? AND (
          delivery_state IN ('delivery_unknown','sending') OR
          (delivery_state='retry' AND (last_error LIKE '%send_unconfirmed%' OR last_error LIKE '%send_platform_rejected%')))''',
        whereArgs: [userId],
        limit: 1);
    if (rows.isEmpty) return false;
    final row = rows.single;
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(row['created_at_ms']! as int);
    String normalized(String value) => value.replaceAll(RegExp(r'\s+'), '');
    final reply = row['reply']! as String;
    if (normalized(message.body) != normalized(reply) ||
        message.sentAt!
            .isBefore(createdAt.subtract(const Duration(seconds: 1))) ||
        message.sentAt!.isAfter(capturedAt.add(const Duration(seconds: 1)))) {
      return false;
    }
    // appendCapture already stored this observed message. Do not create a
    // duplicate generated bubble or replace its original timestamp.
    final store = await history;
    final observed = await store.confirmObservedOutgoing(
        userId: userId, messageId: message.stableId);
    final known = row['attempt_id'] != null &&
        await store.acceptAttemptReceipt(
            userId: userId, attemptId: row['attempt_id']! as String);
    if (!observed && !known) return false;
    return markReplySent(
        userId: userId,
        reply: reply,
        recordHistory: false,
        expectedUnconfirmedCreatedAt: row['created_at_ms']! as int,
        expectedTaskId: row['task_id']?.toString());
  }

  Future<bool> markReplySent(
      {required String userId,
      required String reply,
      bool recordHistory = true,
      int? expectedUnconfirmedCreatedAt,
      String? expectedTaskId}) async {
    final ownerSession = _automationSessionId;
    final db = await database;
    final rows = await db.query('generated_drafts',
        where: expectedUnconfirmedCreatedAt == null
            ? 'user_id = ? AND reply = ?'
            : '''user_id = ? AND reply = ? AND created_at_ms=? AND (
                delivery_state IN ('delivery_unknown','sending') OR
                (delivery_state='retry' AND (last_error LIKE '%send_unconfirmed%' OR last_error LIKE '%send_platform_rejected%')))''',
        whereArgs: [
          userId,
          reply,
          if (expectedUnconfirmedCreatedAt != null) expectedUnconfirmedCreatedAt
        ],
        limit: 1);
    if (rows.isEmpty) {
      if (expectedUnconfirmedCreatedAt != null || expectedTaskId != null) {
        return false;
      }
      if (_automationSessionId != null) return false;
      // Compatibility affects only legacy history, never current-run work.
      return (await history).markReplySent(userId: userId, reply: reply);
    }
    final row = rows.first;
    if (expectedTaskId != null && row['task_id'] != expectedTaskId) {
      return false;
    }
    if (_automationSessionId != null &&
        (row['attempt_id'] == null ||
            !await _verifyNativeSubmission(userId, row['attempt_id']! as String,
                taskId: row['task_id']?.toString()))) {
      return false;
    }
    final claimed = await db.update(
        'generated_drafts', {'delivery_state': 'committing'},
        where:
            "user_id=? AND created_at_ms=? AND COALESCE(task_id,'')=? AND delivery_state!='committing'",
        whereArgs: [userId, row['created_at_ms'], row['task_id'] ?? '']);
    if (claimed != 1) {
      // An I/O failure after a native success must be recoverable without a
      // process restart. Only the same durable, positively submitted attempt
      // may re-enter the idempotent local-history commit.
      if (row['delivery_state'] != 'committing' || row['attempt_id'] == null) {
        return false;
      }
      try {
        final receipt = jsonDecode(await File(p.join((await storageRoot).path,
                'delivery_receipts', '${row['attempt_id']}.json'))
            .readAsString()) as Map<String, dynamic>;
        if (receipt['state'] != 'submitted' ||
            receipt['attemptId'] != row['attempt_id'] ||
            receipt['customer'] != userId) {
          return false;
        }
      } catch (_) {
        return false;
      }
      RuntimeTrace.record('delivery.local_commit_resumed', {
        'customer': userId,
        'attemptId': row['attempt_id'],
        'retyping': false
      });
    }
    final raw = jsonDecode(row['raw_json']! as String) as Map<String, dynamic>;
    final completedApi = _hasCompletedApiProof(row);
    final draft = AiDraft.fromJson(raw, mediaBaseUrl: Uri());
    final ownedScope = _automationSessionId == null
        ? const <String>{}
        : await _replyInputIds(db, userId, row['task_id']?.toString() ?? '',
            rawJson: row['raw_json']?.toString(), currentRevisionOnly: true);
    final formalScope = _formalInputScope(raw, ownedScope);
    final batchEnd = row['batch_end_message_id']?.toString();
    final store = await _historyForReplyOwner(userId, row);
    String? remainingNewestMessageId;
    String? remainingFirstMessageId;
    DateTime? remainingFirstAt;
    DateTime? remainingDueAt;
    if (completedApi && ownerSession != null) {
      final remaining = await db.query('automation_session_messages',
          where: "session_id=? AND user_id=? AND response_state='pending' "
              "AND message_id NOT IN (${List.filled(formalScope.length, '?').join(',')})",
          whereArgs: [ownerSession, userId, ...formalScope],
          orderBy: 'rowid ASC');
      if (remaining.isNotEmpty) {
        remainingNewestMessageId = remaining.last['message_id']! as String;
        remainingFirstMessageId = remaining.first['message_id']! as String;
        final prefix = 'incoming-time:${Uri.encodeComponent(userId)}:';
        if (remainingFirstMessageId.startsWith(prefix)) {
          remainingFirstAt = DateTime.tryParse(
              remainingFirstMessageId.substring(prefix.length));
        }
        remainingDueAt = DateTime.now().add(holdingDelay);
      }
    } else if (batchEnd != null && batchEnd.isNotEmpty) {
      final messages =
          await processingMessages(userId, document: await store.read(userId));
      final batchEndIndex = _messageIndex(messages, batchEnd);
      final scope = formalScope;
      if (batchEndIndex >= 0 || _automationSessionId != null) {
        final remainingIncoming = (_automationSessionId == null
                ? messages.skip(batchEndIndex + 1)
                : messages.where((m) => !_matchesWorkId(m, scope)))
            .where((message) =>
                message['direction'] == 'incoming' &&
                message['capture_purpose'] != 'history_only')
            .toList(growable: false);
        if (remainingIncoming.isNotEmpty) {
          remainingNewestMessageId = remainingIncoming.last['id']?.toString();
          remainingFirstMessageId = remainingIncoming.first['id']?.toString();
          remainingFirstAt = DateTime.tryParse(
              remainingIncoming.first['sent_at']?.toString() ?? '');
          // A real reply resets the holding-message clock for any newer frozen
          // batch. The customer has just received service, so no holding reply
          // is due until another full configured window passes without a real reply.
          remainingDueAt = DateTime.now().add(holdingDelay);
        }
      }
    }
    if (recordHistory) {
      try {
        await store.appendSentReply(
          userId: userId,
          displayName: userId,
          stableKey: userId,
          draft: draft,
          taskId: row['task_id']?.toString(),
          attemptId: row['attempt_id']?.toString(),
          batchEndMessageId: batchEnd,
        );
      } catch (error) {
        await db.update(
            'generated_drafts',
            {
              'delivery_state': 'delivery_unknown',
              'last_error': 'send_unconfirmed: local commit failed'
            },
            where:
                "user_id=? AND created_at_ms=? AND COALESCE(task_id,'')=? AND delivery_state='committing'",
            whereArgs: [userId, row['created_at_ms'], row['task_id'] ?? '']);
        rethrow;
      }
    }
    final recorded = await db.transaction((txn) async {
      if (!await _captureSessionMatches(txn, ownerSession)) return false;
      final deleted = await txn.delete('generated_drafts',
          where:
              "user_id=? AND created_at_ms=? AND COALESCE(task_id,'')=? AND delivery_state='committing'",
          whereArgs: [userId, row['created_at_ms'], row['task_id'] ?? '']);
      if (deleted != 1) return false;
      if (raw['automatic_progress_classified'] == true ||
          raw['reply_purpose'] == 'media_status' ||
          _legacyAutomaticMediaStatus(raw)) {
        await _waitForInputEvidence(
            txn,
            userId,
            row['task_id']?.toString() ?? '',
            ownedScope.difference(formalScope),
            raw);
      }
      await _completeReplyInputs(txn, userId, row['task_id']?.toString() ?? '',
          attemptId: row['attempt_id']?.toString(),
          rawJson: row['raw_json']?.toString());
      if (batchEnd != null &&
          batchEnd.isNotEmpty &&
          (_automationSessionId == null || formalScope.isNotEmpty)) {
        await txn.rawInsert('''INSERT INTO answered_cursors(user_id,message_id)
          VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET
          message_id=excluded.message_id''', [userId, batchEnd]);
      }
      if (row['attempt_id'] != null) {
        await txn.update(
            'delivery_attempts',
            {
              'state': 'submitted',
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch
            },
            where: 'attempt_id=?',
            whereArgs: [row['attempt_id']]);
      }
      final updatedAt = DateTime.now().millisecondsSinceEpoch;
      if (remainingNewestMessageId != null && remainingDueAt != null) {
        // A frozen reply can cover an older message while a later customer
        // line remains pending. That remaining batch starts its own SLA at its
        // first unanswered message; it must not inherit the older deadline.
        await txn.rawUpdate(
            '''UPDATE sla_fallbacks SET
          message_id=?, due_at_ms=?,
          state='pending', sent_at_ms=NULL,
          batch_start_message_id=?,batch_started_at_ms=?,batch_clock_verified=?,updated_at_ms=?
          WHERE user_id=? AND COALESCE(batch_start_message_id,message_id) NOT LIKE 'response-cycle:%'
            AND NOT EXISTS(SELECT 1 FROM platform_response_cycles c
              WHERE c.user_id=sla_fallbacks.user_id AND c.state IN ('waiting','awaiting_observation'))''',
            [
              remainingNewestMessageId,
              remainingDueAt.millisecondsSinceEpoch,
              remainingFirstMessageId,
              remainingFirstAt?.millisecondsSinceEpoch ??
                  DateTime.now().millisecondsSinceEpoch,
              remainingFirstAt != null ? 1 : 0,
              updatedAt,
              userId,
            ]);
      } else {
        await txn.update(
          'sla_fallbacks',
          {
            'state': 'completed',
            'updated_at_ms': updatedAt,
          },
          where: 'user_id = ? AND message_id = ?',
          whereArgs: [userId, batchEnd],
        );
      }
      return true;
    });
    if (recorded && completedApi && ownerSession == _automationSessionId) {
      await db.transaction((txn) async {
        if (!await _captureSessionMatches(txn, ownerSession)) return;
        final pending = await txn.query('automation_session_messages',
            columns: ['message_id'],
            where: "session_id=? AND user_id=? AND response_state='pending'",
            whereArgs: [ownerSession, userId],
            orderBy: 'rowid DESC',
            limit: 1);
        if (pending.isEmpty) {
          await txn.delete('pending_customers',
              where: 'user_id=?', whereArgs: [userId]);
        } else {
          await txn.update(
              'pending_customers',
              {
                'newest_message_id': pending.single['message_id'],
                'generation_token': null,
                'generation_retry_at_ms': 0,
                'generation_last_error': null,
              },
              where:
                  'user_id=? AND (generation_token IS NULL OR generation_token=?)',
              whereArgs: [userId, row['task_id']]);
        }
      });
    } else if (recorded && _automationSessionId != null) {
      await _reconcileCanonicalMessageWork(userId);
      await ensurePendingForUnanswered(userId);
      if (!(await _pendingSessionIds(userId)).isNotEmpty) {
        await db.delete('pending_customers',
            where: 'user_id=?', whereArgs: [userId]);
      }
    }
    return recorded;
  }

  Future<void> seedDemoData() async {
    final store = await history;
    final imagePath = await store.saveMedia(
      userId: 'tb32020',
      filename: 'demo_customer_photo.png',
      bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
    );
    final now = DateTime.now();
    final firstDemo = CapturedConversation(
      stableKey: 'demo:tb302030',
      customerName: 'tb302030',
      customerExternalId: 'tb302030',
      capturedAt: now,
      messages: const [
        CapturedMessage(
          stableId: 'demo:tb302030:1',
          direction: 'incoming',
          body: 'Ni ha0?',
          axPath: 'demo',
        ),
      ],
    );
    await saveCapture(firstDemo);
    await _upsertPending(firstDemo, store, ownerSession: _automationSessionId);
    final secondDemo = CapturedConversation(
      stableKey: 'demo:tb32020',
      customerName: 'tb32020',
      customerExternalId: 'tb32020',
      capturedAt: now.add(const Duration(milliseconds: 1)),
      messages: [
        CapturedMessage(
          stableId: 'demo:tb32020:1',
          direction: 'incoming',
          body: 'hello',
          axPath: 'demo',
          media: [
            CapturedMedia(
              type: 'image',
              path: imagePath,
              mimeType: 'image/png',
              originalName: 'demo_customer_photo.png',
              visualFingerprint: 'ffffffffffffffff',
            ),
          ],
        ),
      ],
    );
    await saveCapture(secondDemo);
    await _upsertPending(secondDemo, store, ownerSession: _automationSessionId);
  }

  Future<void> close() async {
    final opening = _openingDatabase;
    if (_database == null && opening != null) {
      try {
        await opening;
      } catch (_) {}
    }
    await _database?.close();
    _database = null;
    _openingDatabase = null;
  }

  Future<Directory> _resolveDefaultStorageRoot() async {
    final configured = Platform.environment['QIANNIU_DATA_DIR'];
    if (configured != null && configured.trim().isNotEmpty) {
      return Directory(configured).absolute;
    }

    // Development builds live below <project>/build/macos/...; walk upward to
    // the Flutter project so `open .../jd_automation.app` still writes here.
    for (final startingPoint in <Directory>[
      if (!AppRuntime.standalone) ...[
        Directory.current,
        File(Platform.resolvedExecutable).parent,
      ],
    ]) {
      var candidate = startingPoint.absolute;
      while (candidate.parent.path != candidate.path) {
        if (await File(p.join(candidate.path, 'pubspec.yaml')).exists()) {
          return Directory(p.join(candidate.path, 'data'));
        }
        candidate = candidate.parent;
      }
    }

    // Packaged installations have no source project. Allow an explicit
    // QIANNIU_DATA_DIR there; otherwise use the normal macOS fallback.
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'data'));
  }
}

class QueuedDelivery {
  const QueuedDelivery({
    required this.pendingId,
    required this.userId,
    required this.draft,
    this.taskId,
    this.generatedAt,
    this.responseWindowCycleId,
    this.responseWindowStartedAt,
    this.responseWindowDueAt,
  });

  final String? taskId;
  final int pendingId;
  final String userId;
  final AiDraft draft;
  final DateTime? generatedAt;
  final String? responseWindowCycleId;
  final DateTime? responseWindowStartedAt;
  final DateTime? responseWindowDueAt;
  bool get wasGeneratedWithinResponseWindow =>
      generatedAt != null &&
      responseWindowStartedAt != null &&
      responseWindowDueAt != null &&
      !generatedAt!.isAfter(responseWindowDueAt!);
}

class SlaFallbackJob {
  const SlaFallbackJob({
    required this.userId,
    required this.messageId,
    required this.dueAt,
    this.retryAt,
    this.batchStartMessageId,
    this.startedAt,
    this.hasVerifiedSenderClock = false,
  });

  factory SlaFallbackJob.fromRow(Map<String, Object?> row) => SlaFallbackJob(
        userId: row['user_id']! as String,
        retryAt: (row['retry_at_ms'] as int? ?? 0) > 0
            ? DateTime.fromMillisecondsSinceEpoch(row['retry_at_ms']! as int)
            : null,
        batchStartMessageId: row['batch_start_message_id'] as String?,
        hasVerifiedSenderClock: row['batch_clock_verified'] == 1,
        startedAt: row['batch_started_at_ms'] is int
            ? DateTime.fromMillisecondsSinceEpoch(
                row['batch_started_at_ms']! as int)
            : null,
        messageId: row['message_id']! as String,
        dueAt: DateTime.fromMillisecondsSinceEpoch(row['due_at_ms']! as int),
      );

  final DateTime? retryAt;
  final String userId;
  final String messageId;
  final DateTime dueAt;
  final DateTime? startedAt;
  final bool hasVerifiedSenderClock;
  final String? batchStartMessageId;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
