import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import '../capture/viewport_evidence.dart';
import 'capture_database.dart';
import 'customer_media_inventory.dart';
import '../runtime/runtime_trace.dart';

class DiscoveryCaptureResult {
  const DiscoveryCaptureResult(this.evidence, this.inserted);
  final ViewportEvidence evidence;
  final bool inserted;
}

/// Durable raw evidence is separate from extracted messages and sent receipts.
class CaptureEvidenceStore {
  CaptureEvidenceStore(this.database, {this.now = DateTime.now});
  final DateTime Function() now;
  final CaptureDatabase database;
  String? _sessionId;
  DateTime? _sessionStartedAt;
  final _headerRecoveryClaims = <String>{};
  final _verifiedMediaOcr = <String>{};
  Future<void>? _pruning;
  static int _claimSequence = 0;
  static final _lastMediaCustomers =
      Expando<Map<String, String>>('media_customer_fairness');

  static int _activationRevision(ViewportEvidence evidence) =>
      (evidence.metadata['captureActivationRevision'] as num?)?.toInt() ?? 0;

  static int _claimRevision(ViewportEvidence evidence) =>
      (evidence.metadata['captureClaimActivationRevision'] as num?)?.toInt() ??
      0;

  bool _ownsClaim(ViewportEvidence stored, ViewportEvidence callback,
      {bool released = false}) {
    final token = callback.metadata['captureClaimToken'];
    if (token == null) {
      // Legacy callers without Start still use complete(rawFrame). Current
      // workers must carry their claim: a raw producer owns no active lease.
      return stored.metadata['captureClaimToken'] == null || _sessionId == null;
    }
    if (released && stored.metadata['captureCompletedClaimToken'] == token) {
      return true;
    }
    return stored.metadata['captureClaimToken'] == token &&
        _claimRevision(stored) == _claimRevision(callback);
  }

  Map<String, Object?> _releaseClaim(ViewportEvidence stored,
      {bool replayOcr = false}) {
    final values = {...stored.metadata};
    final token = values.remove('captureClaimToken');
    values.remove('captureClaimActivationRevision');
    if (token != null) values['captureCompletedClaimToken'] = token;
    values['captureReplayOcr'] = replayOcr;
    return values;
  }

  bool isCurrent(ViewportEvidence evidence) =>
      _sessionId == null ||
      (evidence.metadata['automationSessionId'] == _sessionId &&
          !evidence.capturedAt.isBefore(_sessionStartedAt!));

  Future<void> beginSession(
      {required String sessionId, required DateTime startedAt}) async {
    _sessionId = sessionId;
    _sessionStartedAt = startedAt.toUtc();
    _headerRecoveryClaims.clear();
    _verifiedMediaOcr.clear();
    final db = await database.database;
    await db.transaction((txn) async {
      for (final spec in <(String, String, String)>[
        (
          'capture_evidence',
          'id',
          "state NOT IN ('processed','session_archived')"
        ),
        ('capture_observations', 'customer', "state!='session_archived'"),
        ('capture_backfill', 'customer', "state!='session_archived'"),
        (
          'media_capture_audit',
          'observation_id',
          "state IN ('unbound','discovered','unverified','image_partial','video_preview_only','failed')"
        ),
      ]) {
        final rows = await txn.query(spec.$1, where: spec.$3);
        for (final row in rows) {
          await txn.rawInsert(
              'INSERT OR IGNORE INTO capture_session_archive(session_id,table_name,row_key,payload,archived_at_ms) VALUES(?,?,?,?,?)',
              [
                sessionId,
                spec.$1,
                row[spec.$2].toString(),
                jsonEncode(row),
                startedAt.millisecondsSinceEpoch
              ]);
        }
        await txn.update(
            spec.$1,
            {
              'state': 'session_archived',
              if (spec.$1 == 'capture_backfill') 'restore_needed': 0
            },
            where: spec.$3);
      }
    });
    RuntimeTrace.record('evidence.session_started', {
      'sessionId': sessionId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'oldWorkResumed': false
    });
  }

  Future<void> observe(String customer, DateTime at) async {
    final db = await database.database;
    await db.rawInsert(
        '''INSERT INTO capture_observations(customer, first_seen_ms, state)
      VALUES(?,?,'observed') ON CONFLICT(customer) DO UPDATE SET
      first_seen_ms=CASE WHEN state IN ('processed','session_archived') THEN excluded.first_seen_ms
        ELSE MIN(first_seen_ms,excluded.first_seen_ms) END,
      attempts=CASE WHEN state IN ('processed','session_archived') THEN 0 ELSE attempts END,
      state=CASE WHEN state IN ('processed','session_archived') THEN 'observed' ELSE state END''',
        [customer, at.millisecondsSinceEpoch]);
  }

  Future<void> rebindObservation(String observed, String verified) async {
    if (observed == verified) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn.query('capture_observations',
          where: 'customer=?', whereArgs: [observed], limit: 1);
      if (rows.isEmpty) return;
      await txn.rawInsert(
          '''INSERT INTO capture_observations(customer,first_seen_ms,state)
        VALUES(?,?,'observed') ON CONFLICT(customer) DO UPDATE SET
        first_seen_ms=MIN(first_seen_ms,excluded.first_seen_ms)''',
          [verified, rows.single['first_seen_ms']]);
      await txn.delete('capture_observations',
          where: 'customer=?', whereArgs: [observed]);
    });
  }

  Future<bool> record(ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) {
      RuntimeTrace.record('evidence.previous_session_ignored', {
        'sessionId': _sessionId,
        'evidenceId': evidence.id,
        'customer': evidence.customer,
        'payloadSession': evidence.metadata['automationSessionId']
      });
      return false;
    }
    if (!await evidence.filesExist()) {
      throw StateError('Evidence files are missing.');
    }
    final db = await database.database;
    return db.transaction((txn) => _record(txn, evidence));
  }

  /// Admit a changed, AX-owned active frame independently of platform SLA
  /// badges. The first passive frame is frozen once as a baseline; its queued
  /// successors cannot overtake the baseline's successful extraction.
  Future<DiscoveryCaptureResult> discoveryCapture(ViewportEvidence evidence,
      {required bool hasLiveWork,
      required bool hasPendingWork,
      required bool acquisition}) async {
    if (!isCurrent(evidence)) return DiscoveryCaptureResult(evidence, false);
    if (!await evidence.filesExist()) {
      throw StateError('Evidence files are missing.');
    }
    final db = await database.database;
    return db.transaction((txn) async {
      if (!isCurrent(evidence)) return DiscoveryCaptureResult(evidence, false);
      final session = _sessionId;
      Map<String, Object?>? anchor;
      if (session != null && evidence.metadata['historyCutoffMs'] == null) {
        anchor = (await txn.query('capture_discovery_state',
                where: 'session_id=? AND customer=?',
                whereArgs: [session, evidence.customer]))
            .firstOrNull;
        if (anchor == null) {
          final prior = await txn.query('capture_evidence',
              where: "customer=? AND state IN ('processed','partial')",
              whereArgs: [evidence.customer],
              orderBy: 'captured_at_ms');
          final processed = prior.where((row) {
            final frame = ViewportEvidence.fromJson(row['payload']! as String);
            return isCurrent(frame) &&
                frame.metadata['replyActivationAllowed'] == true &&
                frame.metadata['historyCutoffMs'] == null;
          }).firstOrNull;
          final known = processed == null
              ? null
              : ViewportEvidence.fromJson(processed['payload']! as String);
          final hasWork = hasLiveWork || hasPendingWork || acquisition;
          anchor = {
            'session_id': session,
            'customer': evidence.customer,
            'evidence_id': known?.id ?? evidence.id,
            'kind': known != null || hasWork ? 'live' : 'baseline',
            'ready': known == null ? 0 : 1,
            'payload': (known ?? evidence).toJson(),
          };
          await txn.insert('capture_discovery_state', anchor);
        }
      }
      final baseline = anchor?['kind'] == 'baseline' &&
          anchor?['evidence_id'] == evidence.id &&
          !hasLiveWork &&
          !hasPendingWork &&
          !acquisition;
      final purpose = evidence.metadata['historyCutoffMs'] != null
          ? 'history_backfill'
          : baseline
              ? 'discovery_baseline'
              : hasLiveWork
                  ? 'live_signal'
                  : hasPendingWork
                      ? 'durable_unanswered'
                      : acquisition
                          ? 'media_acquisition'
                          : 'active_discovery';
      final tagged = ViewportEvidence({
        ...evidence.metadata,
        'capturePurpose': purpose,
        'replyActivationAllowed': evidence.metadata['historyCutoffMs'] != null
            ? hasLiveWork || hasPendingWork || acquisition
            : !baseline,
        if (anchor != null) 'discoveryAnchorId': anchor['evidence_id'],
        if (acquisition) 'mediaAcquisitionPending': true,
      });
      var inserted = await _record(txn, tagged);
      if (!inserted && acquisition) {
        final row = (await txn.query('capture_evidence',
                where: 'id=?', whereArgs: [tagged.id]))
            .firstOrNull;
        if (row != null &&
            const {'processed', 'partial', 'failed'}.contains(row['state']) &&
            (row['retry_at_ms']! as int) <= now().millisecondsSinceEpoch) {
          final old = ViewportEvidence.fromJson(row['payload']! as String);
          if (isCurrent(old) &&
              old.customer == tagged.customer &&
              old.capturedAt == tagged.capturedAt) {
            await txn.update(
                'capture_evidence',
                {
                  'payload': ViewportEvidence({
                    ...tagged.metadata,
                    if (old.pinnedMedia != null && tagged.pinnedMedia == null)
                      'pinnedMedia': old.pinnedMedia,
                  }).toJson(),
                  'state': 'captured',
                  'retry_at_ms': 0,
                  'last_error': null,
                  'discovery_requires_baseline': 0,
                },
                where: 'id=?',
                whereArgs: [tagged.id]);
            inserted = true;
          }
        }
      }
      return DiscoveryCaptureResult(tagged, inserted);
    });
  }

  Future<bool> _record(DatabaseExecutor txn, ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) return false;
    // A coverage anchor is navigation metadata, not new chat pixels. Retain
    // every saved file, but give identical backfill pixels and ownership one
    // extraction owner even if a caller supplies a different page anchor.
    if (evidence.metadata['chatContentSHA256'] case final String hash
        when hash.isNotEmpty && evidence.metadata['historyCutoffMs'] != null) {
      final prior = await txn.query('capture_evidence',
          where: "customer=? AND state!='session_archived'",
          whereArgs: [evidence.customer]);
      for (final row in prior) {
        final previous = ViewportEvidence.fromJson(row['payload']! as String);
        if (previous.id != evidence.id &&
            isCurrent(previous) &&
            previous.metadata['historyCutoffMs'] != null &&
            previous.metadata['chatContentSHA256'] == hash &&
            _sameBackfillOwnership(previous, evidence)) {
          return false;
        }
      }
    }
    await txn.rawInsert('''INSERT OR IGNORE INTO capture_evidence(
      id,customer,captured_at_ms,payload,state,attempts,retry_at_ms,discovery_requires_baseline)
      VALUES(?,?,?,?,'captured',0,0,?)''', [
      evidence.id,
      evidence.customer,
      evidence.capturedAt.millisecondsSinceEpoch,
      evidence.toJson(),
      evidence.metadata['capturePurpose'] == 'active_discovery' ? 1 : 0,
    ]);
    final changed =
        (await txn.rawQuery('SELECT changes() AS n')).single['n'] == 1;
    var promoted = false;
    if (!changed && _sessionId != null) {
      final rows = await txn.query('capture_evidence',
          where: 'id=?', whereArgs: [evidence.id], limit: 1);
      if (rows.isNotEmpty && rows.single['state'] != 'session_archived') {
        final previous =
            ViewportEvidence.fromJson(rows.single['payload']! as String);
        // The immutable frame can precede its AX signal. Upgrade only a
        // frame deliberately skipped in this run, never a completed live
        // extraction, backfill, or a frame retained from an earlier run.
        final strongPurpose = const {
          'live_signal',
          'durable_unanswered',
          'media_acquisition'
        }.contains(evidence.metadata['capturePurpose']);
        final strongUpgrade = strongPurpose &&
            const {'active_discovery', 'discovery_baseline'}
                .contains(previous.metadata['capturePurpose']) &&
            const {
              'captured',
              'processing',
              'media_processing',
              'retry',
              'failed'
            }.contains(rows.single['state']);
        final skippedUpgrade =
            previous.metadata['replyActivationAllowed'] == false &&
                const {'history_only', 'arrival_observation'}
                    .contains(previous.metadata['capturePurpose']);
        if (isCurrent(previous) &&
            previous.customer == evidence.customer &&
            previous.capturedAt == evidence.capturedAt &&
            (skippedUpgrade || strongUpgrade) &&
            previous.metadata['historyCutoffMs'] == null &&
            (evidence.metadata['replyActivationAllowed'] == true ||
                evidence.metadata['capturePurpose'] == 'discovery_baseline') &&
            const {
              'live_signal',
              'durable_unanswered',
              'active_discovery',
              'media_acquisition',
              'discovery_baseline'
            }.contains(evidence.metadata['capturePurpose']) &&
            evidence.metadata['historyCutoffMs'] == null) {
          final processing = const {'processing', 'media_processing'}
              .contains(rows.single['state']);
          final activated = ViewportEvidence({
            ...previous.metadata,
            ...evidence.metadata,
            'captureActivationRevision': _activationRevision(previous) + 1,
            if (processing) ...{
              'captureClaimToken': previous.metadata['captureClaimToken'],
              'captureClaimActivationRevision': _claimRevision(previous),
            } else ...{
              'captureClaimToken': null,
              'captureClaimActivationRevision': null,
              'captureReplayOcr': true,
            },
            if (previous.pinnedMedia != null && evidence.pinnedMedia == null)
              'pinnedMedia': previous.pinnedMedia,
          });
          await txn.update(
              'capture_evidence',
              {
                'payload': activated.toJson(),
                'state': processing ? rows.single['state'] : 'captured',
                'attempts': 0,
                'retry_at_ms': 0,
                'last_error': null,
                'discovery_requires_baseline':
                    evidence.metadata['capturePurpose'] == 'active_discovery'
                        ? 1
                        : 0,
              },
              where: 'id=?',
              whereArgs: [evidence.id]);
          if (strongUpgrade &&
              previous.metadata['capturePurpose'] == 'discovery_baseline') {
            await txn.update('capture_discovery_state', {'kind': 'live'},
                where: 'session_id=? AND customer=? AND evidence_id=?',
                whereArgs: [_sessionId, evidence.customer, evidence.id]);
          }
          promoted = true;
          RuntimeTrace.record('evidence.live_signal_promoted', {
            'sessionId': _sessionId,
            'customer': evidence.customer,
            'evidenceId': evidence.id,
            'previousState': rows.single['state'],
            'capturePurpose': evidence.metadata['capturePurpose'],
            'capturedAtPreserved': true,
          });
        }
      }
    }
    await txn.update('capture_observations', {'state': 'captured'},
        where: promoted
            ? "customer=? AND state!='session_archived'"
            : "customer=? AND state='observed'",
        whereArgs: [evidence.customer]);
    return changed || promoted;
  }

  Future<void> pin(ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn
          .query('capture_evidence', where: 'id=?', whereArgs: [evidence.id]);
      if (rows.isEmpty) return;
      if (!isCurrent(evidence) || rows.single['state'] == 'session_archived') {
        return;
      }
      final previous =
          ViewportEvidence.fromJson(rows.single['payload']! as String);
      if (previous.customer != evidence.customer) {
        throw StateError('pin_customer_mismatch');
      }
      if (evidence.metadata['captureClaimToken'] != null &&
          !_ownsClaim(previous, evidence)) {
        return;
      }
      if (_activationAdvanced(previous, evidence)) return;
      if (await _isObsoleteBaseline(txn, evidence)) return;
      final newlyAvailable =
          previous.pinnedMedia == null && evidence.pinnedMedia != null;
      await txn.update(
          'capture_evidence',
          {
            'payload': ViewportEvidence({
              ...previous.metadata,
              ...evidence.metadata,
              if (previous.metadata['captureClaimToken'] != null) ...{
                'captureClaimToken': previous.metadata['captureClaimToken'],
                'captureClaimActivationRevision': _claimRevision(previous),
              },
              if (previous.metadata['mediaCoverageCutoffMs'] case final num at)
                'mediaCoverageCutoffMs': at,
              if (previous.metadata['mediaTypeRecheckRequested'] == true)
                'mediaTypeRecheckRequested': true,
            }).toJson(),
            if (newlyAvailable &&
                const ['processed', 'partial', 'failed']
                    .contains(rows.single['state'])) ...{
              'state': 'captured',
              'retry_at_ms': 0
            }
          },
          where: 'id=?',
          whereArgs: [evidence.id]);
    });
  }

  Future<ViewportEvidence?> lookup(String id) async {
    final rows = await (await database.database)
        .query('capture_evidence', where: 'id=?', whereArgs: [id], limit: 1);
    return rows.isEmpty
        ? null
        : ViewportEvidence.fromJson(rows.single['payload']! as String);
  }

  /// Reuse immutable OCR while the one extraction owner adopts a newer AX
  /// activation. The token is unchanged; only this owner can acknowledge the
  /// latest activation revision before registration and completion.
  Future<ViewportEvidence?> refreshClaim(ViewportEvidence claim) async {
    if (!isCurrent(claim) ||
        (database.currentAutomationSessionId != null &&
            _sessionId != database.currentAutomationSessionId)) {
      return null;
    }
    final db = await database.database;
    return db.transaction((txn) async {
      final row = (await txn
              .query('capture_evidence', where: 'id=?', whereArgs: [claim.id]))
          .firstOrNull;
      if (row == null ||
          !const {'processing', 'media_processing'}.contains(row['state'])) {
        return null;
      }
      final stored = ViewportEvidence.fromJson(row['payload']! as String);
      if (!isCurrent(stored) ||
          stored.customer != claim.customer ||
          stored.capturedAt != claim.capturedAt ||
          !_ownsClaim(stored, claim)) {
        return null;
      }
      final refreshed = ViewportEvidence({
        ...stored.metadata,
        'captureClaimActivationRevision': _activationRevision(stored),
      });
      await txn.update('capture_evidence', {'payload': refreshed.toJson()},
          where: 'id=?', whereArgs: [claim.id]);
      return refreshed;
    });
  }

  Future<bool> hasDiscoveryAnchor(String customer) async =>
      (await (await database.database).query('capture_discovery_state',
              columns: ['customer'],
              where: 'session_id=? AND customer=?',
              whereArgs: [_sessionId, customer],
              limit: 1))
          .isNotEmpty;

  Future<String?> baselineEvidenceId(String customer) async =>
      (await (await database.database).query('capture_discovery_state',
              columns: ['evidence_id'],
              where:
                  "session_id=? AND customer=? AND kind='baseline' AND ready=1",
              whereArgs: [_sessionId, customer],
              limit: 1))
          .firstOrNull?['evidence_id'] as String?;

  Future<void> waitForMediaProgress(ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final row = (await txn.query('capture_evidence',
              where: 'id=?', whereArgs: [evidence.id]))
          .firstOrNull;
      if (row == null) return;
      final stored = ViewportEvidence.fromJson(row['payload']! as String);
      if (!isCurrent(stored) || !_ownsClaim(stored, evidence, released: true)) {
        return;
      }
      await txn.update(
          'capture_evidence', {'state': 'media_waiting', 'retry_at_ms': 0},
          where: "id=? AND state IN ('partial','processed')",
          whereArgs: [evidence.id]);
    });
  }

  Future<int> wakeMediaForProgress(String customer,
      {required String progressKey, Set<String>? ownerKeys}) async {
    final db = await database.database;
    return db.transaction((txn) => _wakeMediaForProgress(txn, customer,
        progressKey: progressKey, ownerKeys: ownerKeys));
  }

  /// A cache copy belongs to this frame, and can wake only the exact admitted
  /// parents proved by that frame. A pin arriving before admission stays saved;
  /// registration will schedule it without waking unrelated customer work.
  Future<int> wakePinnedMedia(ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) return 0;
    final db = await database.database;
    return db.transaction((txn) async {
      final row = (await txn.query('capture_evidence',
              where: "id=? AND state!='session_archived'",
              whereArgs: [evidence.id]))
          .firstOrNull;
      if (row == null) return 0;
      final stored = ViewportEvidence.fromJson(row['payload']! as String);
      if (!isCurrent(stored) || stored.pinnedMedia == null) return 0;
      final owners = await _admittedMediaOwners(txn, stored);
      if (owners.isEmpty) return 0;
      return _wakeMediaForProgress(txn, stored.customer,
          progressKey: 'pin:${stored.id}:${stored.pinnedMedia!['cacheKey']}',
          ownerKeys: owners);
    });
  }

  Future<int> _wakeMediaForProgress(DatabaseExecutor txn, String customer,
      {required String progressKey, Set<String>? ownerKeys}) async {
    var changed = 0;
    for (final row in await txn.query('capture_evidence',
        where: "customer=? AND state='media_waiting'", whereArgs: [customer])) {
      final evidence = ViewportEvidence.fromJson(row['payload']! as String);
      if (!isCurrent(evidence) ||
          evidence.metadata['mediaWakeProgressKey'] == progressKey) {
        continue;
      }
      if (ownerKeys != null) {
        final observations = await txn.query('media_capture_audit',
            columns: ['details'],
            where: 'evidence_id=?',
            whereArgs: [evidence.id]);
        final owned = observations.any((observation) {
          final details = jsonDecode(observation['details']! as String) as Map;
          return ownerKeys.contains(details['mediaReceiptId']) ||
              ownerKeys.contains(details['parentMessageId']) ||
              ownerKeys.contains(details['resolvedMessageId']) ||
              // An ambiguous correspondence grants only a new verification
              // attempt when that exact candidate progresses. It is never
              // admission evidence or an acquisition scheduling owner.
              ((_sessionId == null ||
                      details['automationSessionId'] == _sessionId) &&
                  (details['candidateParentIds'] as List? ?? const [])
                      .whereType<String>()
                      .any(ownerKeys.contains));
        });
        if (!owned) continue;
      }
      changed += await txn.update(
          'capture_evidence',
          {
            'state': 'media_retry',
            'retry_at_ms': 0,
            'payload': ViewportEvidence({
              ...evidence.metadata,
              'mediaWakeProgressKey': progressKey,
            }).toJson(),
          },
          where: 'id=?',
          whereArgs: [row['id']]);
    }
    return changed;
  }

  Future<List<String>> waitingMediaCustomers() async =>
      (await (await database.database).rawQuery(
              "SELECT DISTINCT customer FROM capture_evidence WHERE state='media_waiting'"))
          .map((row) => row['customer']! as String)
          .toList();

  /// Resume only immutable frames newly bound to a real unfinished owner.
  /// This consumes registration recovery; a passive old screenshot or a
  /// completed image never re-enters acquisition just because it exists.
  Future<int> resumeAdmittedMediaEvidence(Set<String> evidenceIds) async {
    if (evidenceIds.isEmpty ||
        _sessionId == null ||
        _sessionId != database.currentAutomationSessionId) {
      return 0;
    }
    final db = await database.database;
    return db.transaction((txn) async {
      var resumed = 0;
      final readyByCustomer = <String, Set<String>>{};
      for (final id in evidenceIds) {
        final row = (await txn
                .query('capture_evidence', where: 'id=?', whereArgs: [id]))
            .firstOrNull;
        if (row == null ||
            !const {
              'processed',
              'partial',
              'media_waiting',
              'media_retry',
              'retry'
            }.contains(row['state'])) {
          continue;
        }
        final evidence = ViewportEvidence.fromJson(row['payload']! as String);
        if (!isCurrent(evidence)) continue;
        final owners = await _admittedMediaOwners(txn, evidence);
        final ready = readyByCustomer[evidence.customer] ??=
            await CustomerMediaInventory(database)
                .analysisReadyMessageIds(evidence.customer, executor: txn);
        owners.removeAll(ready);
        if (owners.isEmpty) continue;
        final key = await _mediaResumeKey(txn, evidence, owners);
        if (evidence.metadata['admissionResumeKey'] == key) continue;
        resumed += await txn.update(
            'capture_evidence',
            {
              'state': 'media_retry',
              'retry_at_ms': 0,
              'payload': ViewportEvidence({
                ...evidence.metadata,
                'admissionResumeKey': key,
              }).toJson(),
            },
            where: 'id=? AND state=?',
            whereArgs: [id, row['state']]);
      }
      return resumed;
    });
  }

  /// Admission and material acquisition are separate commits. The same
  /// business owner may later gain its real media rectangle or verified file.
  /// Wake that stage once, without reopening unchanged successful recognition
  /// on every maintenance tick. Transient processing states/timestamps are not
  /// material progress, and an unowned neighbouring card supplies no wake.
  Future<String> _mediaResumeKey(DatabaseExecutor txn,
      ViewportEvidence evidence, Set<String> owners) async {
    final material = <String>[];
    for (final row in await txn.query('media_capture_audit',
        columns: ['observation_id', 'details'],
        where: "customer=? AND evidence_id=? AND state!='session_archived'",
        whereArgs: [evidence.customer, evidence.id])) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['automationSessionId'] != _sessionId) continue;
      final parent = details['parentMessageId'] ?? details['resolvedMessageId'];
      if (!owners.contains(parent)) continue;
      material.add(jsonEncode([
        row['observation_id'],
        parent,
        details['observationGroupId'],
        details['mediaReceiptId'],
        details['kind'],
        details['verifiedOriginalPath'],
        details['representationOwnershipProof'],
      ]));
    }
    material.sort();
    return 'admitted:$_sessionId:${(owners.toList()..sort()).join('|')}:'
        'material:${sha256.convert(utf8.encode(jsonEncode(material)))}';
  }

  Future<void> retireResolvedMedia(String customer) async {
    await (await database.database).rawUpdate('''UPDATE capture_evidence
      SET state='processed',retry_at_ms=0
      WHERE customer=? AND state IN ('media_waiting','media_retry')
      AND EXISTS(SELECT 1 FROM media_capture_audit a
        WHERE a.evidence_id=capture_evidence.id)
      AND NOT EXISTS(SELECT 1 FROM media_capture_audit a
        WHERE a.evidence_id=capture_evidence.id AND a.state IN
          ('unbound','discovered','unverified','image_partial','video_preview_only','failed'))''',
        [customer]);
  }

  /// Admission is durable before optional media enrichment starts. Retrying a
  /// saved frame reuses this exact bubble proof rather than a newer frontier.
  Future<void> rememberTextInputs(
      ViewportEvidence evidence, Set<String> messageIds) async {
    if (!isCurrent(evidence) || messageIds.isEmpty) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn.query('capture_evidence',
          where: "id=? AND state!='session_archived'",
          whereArgs: [evidence.id]);
      if (rows.isEmpty || !isCurrent(evidence)) return;
      final stored =
          ViewportEvidence.fromJson(rows.single['payload']! as String);
      if (!isCurrent(stored) || stored.customer != evidence.customer) return;
      await txn.update(
          'capture_evidence',
          {
            'payload': ViewportEvidence({
              ...stored.metadata,
              'admittedTextInputIds': [
                ...{
                  ...(stored.metadata['admittedTextInputIds'] as List? ??
                          const [])
                      .whereType<String>(),
                  ...messageIds,
                }
              ],
            }).toJson(),
          },
          where: 'id=?',
          whereArgs: [evidence.id]);
    });
  }

  Future<bool> _hasSavedMediaOcr(ViewportEvidence evidence) async {
    final path = '${evidence.manifestPath}.ocr.json';
    final file = File(path);
    if (!await file.exists()) return false;
    final key = '${evidence.id}\u001f${evidence.customer}\u001f$path';
    if (_verifiedMediaOcr.contains(key)) return true;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map ||
          raw['evidenceId'] != evidence.id ||
          raw['customer'] != evidence.customer ||
          raw['activeCustomerId'] != evidence.customer ||
          raw['capturedAtMs'] != evidence.capturedAt.millisecondsSinceEpoch ||
          raw['observations'] is! List ||
          raw['visualRegions'] is! List) {
        return false;
      }
      final expectedHash = evidence.metadata['pngSHA256'];
      if (expectedHash is String &&
          expectedHash.isNotEmpty &&
          raw['sourcePngSHA256'] != expectedHash) {
        return false;
      }
      _verifiedMediaOcr.add(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Only a real, pending, current-session admission supplies scheduling
  /// ownership. A clock, cache file, acquisition hint or unbound observation
  /// cannot bypass the screenshot registration boundary.
  Future<Set<String>> _admittedMediaOwners(
      DatabaseExecutor txn, ViewportEvidence evidence) async {
    final session = _sessionId;
    if (session == null ||
        session != database.currentAutomationSessionId ||
        !isCurrent(evidence) ||
        evidence.metadata['capturePurpose'] == 'discovery_baseline') {
      return {};
    }
    final requested = <String>{};
    for (final row in await txn.query('media_capture_audit',
        columns: ['details'],
        where: "customer=? AND evidence_id=? AND state!='session_archived'",
        whereArgs: [evidence.customer, evidence.id])) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['automationSessionId'] != session) continue;
      for (final key in [
        'parentMessageId',
        'resolvedMessageId',
        'mediaReceiptId'
      ]) {
        if (details[key] is String) requested.add(details[key]! as String);
      }
    }
    if (requested.isEmpty) return {};
    final roots = await txn.rawQuery('''SELECT m.item_id,m.message_id
      FROM customer_media_items m JOIN automation_session_messages w
        ON w.session_id=m.admission_session_id AND w.user_id=m.customer
          AND w.message_id=m.message_id
      WHERE m.customer=? AND m.admission_session_id=?
        AND m.admission_key IS NOT NULL AND m.canonical_id IS NULL
        AND w.response_state='pending' AND w.input_kind IN ('media','unknown')''',
        [evidence.customer, session]);
    final allowed = evidence.metadata['acquisitionOnly'] == true
        ? (evidence.metadata['acquisitionInputKeys'] as List? ?? const [])
            .whereType<String>()
            .toSet()
        : null;
    final aliases = await txn.query('customer_media_items',
        columns: ['item_id', 'canonical_id'],
        where: 'customer=?',
        whereArgs: [evidence.customer]);
    final owners = <String>{};
    for (final root in roots) {
      final keys = <String>{
        root['item_id']! as String,
        root['message_id']! as String,
      };
      var changed = true;
      while (changed) {
        changed = false;
        for (final alias in aliases) {
          if (keys.contains(alias['canonical_id']) &&
              keys.add(alias['item_id']! as String)) {
            changed = true;
          }
        }
      }
      if (keys.intersection(requested).isNotEmpty &&
          (allowed == null || keys.intersection(allowed).isNotEmpty)) {
        owners.add(root['message_id']! as String);
      }
    }
    return owners;
  }

  Future<Set<String>> dueMediaCustomers() async =>
      (await (await database.database).rawQuery(
              "SELECT DISTINCT customer FROM capture_evidence "
              "WHERE state='media_retry' AND retry_at_ms<=?",
              [now().millisecondsSinceEpoch]))
          .map((row) => row['customer']! as String)
          .toSet();

  Future<Set<String>> dueRegistrationCustomers() async =>
      (await (await database.database).rawQuery(
              "SELECT DISTINCT customer FROM capture_evidence "
              "WHERE state='captured' OR (state='retry' AND retry_at_ms<=?)",
              [now().millisecondsSinceEpoch]))
          .map((row) => row['customer']! as String)
          .toSet();

  Future<ViewportEvidence?> claim(
      {bool? mediaOnly,
      bool liveRegistrationOnly = false,
      String? mediaCustomer,
      String? registrationCustomer}) async {
    assert(mediaCustomer == null || mediaOnly == true);
    assert(registrationCustomer == null || mediaOnly == false);
    final selectedCustomer = mediaCustomer ?? registrationCustomer;
    if (mediaOnly == true && liveRegistrationOnly) return null;
    final db = await database.database;
    if (database.currentAutomationSessionId != null &&
        _sessionId != null &&
        _sessionId != database.currentAutomationSessionId) {
      return null;
    }
    // Read immutable files outside the SQLite transaction. Foreground text
    // registration never waits for this media-only preparation.
    final savedMediaOcr = <String>{};
    if (mediaOnly != false && _sessionId != null) {
      for (final row in await db.query('capture_evidence',
          columns: ['payload'],
          where:
              "state='media_retry'${mediaCustomer == null ? '' : ' AND customer=?'}",
          whereArgs: mediaCustomer == null ? null : [mediaCustomer])) {
        final evidence = ViewportEvidence.fromJson(row['payload']! as String);
        if (isCurrent(evidence) && await _hasSavedMediaOcr(evidence)) {
          savedMediaOcr.add(evidence.id);
        }
      }
    }
    final sessionMatch = _sessionId == null ? 'IS NULL' : '=?';
    return db.transaction((txn) async {
      if (database.currentAutomationSessionId != null &&
          _sessionId != null &&
          _sessionId != database.currentAutomationSessionId) {
        return null;
      }
      final rows = await txn.query('capture_evidence',
          where:
              """(state='captured' OR (state IN ('retry','media_retry') AND retry_at_ms<=?))
          ${mediaOnly == true ? "AND state='media_retry'" : mediaOnly == false ? "AND state!='media_retry'" : ''}
          ${selectedCustomer == null ? '' : 'AND customer=?'}
          AND NOT EXISTS (SELECT 1 FROM capture_discovery_state AS discovery
            WHERE discovery.session_id $sessionMatch AND discovery.customer=capture_evidence.customer
              AND discovery.ready=0 AND capture_evidence.discovery_requires_baseline=1
              AND discovery.evidence_id!=capture_evidence.id)""",
          whereArgs: [
            now().millisecondsSinceEpoch,
            if (selectedCustomer != null) selectedCustomer,
            if (_sessionId != null) _sessionId,
          ],
          orderBy:
              "CASE WHEN state='media_retry' THEN 1 ELSE 0 END, captured_at_ms ASC, id ASC");
      final discovery = {
        for (final anchor in await txn.query('capture_discovery_state',
            where: 'session_id $sessionMatch',
            whereArgs: _sessionId == null ? null : [_sessionId]))
          anchor['customer']: anchor,
      };
      bool liveRegistration(Map<String, Object?> row) {
        if (row['state'] == 'media_retry') return false;
        final frame = ViewportEvidence.fromJson(row['payload']! as String);
        final frontier = frame.metadata['admissionFrontier'];
        final hasFrozenFrontier = frontier is Map && frontier['id'] is String;
        // An AX-identified current viewport can contain new messages even
        // when the sidebar supplies no second unread-arrival event.
        if (_sessionId != null &&
            _sessionId == database.currentAutomationSessionId &&
            isCurrent(frame) &&
            frame.metadata['capturePurpose'] == 'durable_unanswered' &&
            frame.metadata['replyActivationAllowed'] == true &&
            frame.metadata['captureRequestedBackfill'] == false &&
            frame.metadata['historyCutoffMs'] == null &&
            frame.metadata['acquisitionOnly'] != true &&
            !frame.customer.startsWith('pending-row:') &&
            hasFrozenFrontier) {
          return true;
        }
        // Only a producer-frozen, AX-owned boundary permits overtaking. A
        // baseline still has its own mandatory discovery reservation above.
        final verifiedArrival = isCurrent(frame) &&
            frame.metadata['replyActivationAllowed'] == true &&
            frame.metadata['unreadArrivalKey'] is String &&
            frame.metadata['captureRequestedBackfill'] == false;
        if (!verifiedArrival) return false;
        if (hasFrozenFrontier) {
          return true;
        }
        // The first AX arrival has no older text frontier yet. Only its own
        // durable live discovery reservation can use the fresh-live slot;
        // a passive baseline or historical viewport cannot claim this role.
        final anchor = discovery[frame.customer];
        return _sessionId != null &&
            _sessionId == database.currentAutomationSessionId &&
            frame.metadata['historyCutoffMs'] == null &&
            frame.metadata['admissionFrontier'] == null &&
            (frame.metadata['unreadArrivalKey']! as String).isNotEmpty &&
            !frame.customer.startsWith('pending-row:') &&
            anchor?['kind'] == 'live' &&
            anchor?['evidence_id'] == frame.id;
      }

      final candidates = [
        ...rows.where(liveRegistration),
        ...rows.where((row) => !liveRegistration(row)),
      ];
      final mediaOwnersById = <String, Set<String>>{};
      for (final row in rows.where((row) => row['state'] == 'media_retry')) {
        mediaOwnersById[row['id']! as String] = await _admittedMediaOwners(
            txn, ViewportEvidence.fromJson(row['payload']! as String));
      }
      final mediaCustomers = _lastMediaCustomers[database] ??= {};
      final fairnessSession = _sessionId ?? 'legacy';
      if (mediaOnly == true) {
        final order = {
          for (var i = 0; i < candidates.length; i++) candidates[i]['id']: i,
        };
        int priority(Map row) {
          final owners = mediaOwnersById[row['id']] ?? const <String>{};
          if (owners.isEmpty) return 2;
          return savedMediaOcr.contains(row['id']) ? 0 : 1;
        }

        candidates.sort((a, b) {
          final type = priority(a).compareTo(priority(b));
          if (type != 0) return type;
          final last = mediaCustomers[fairnessSession];
          final customer = (a['customer'] == last ? 1 : 0)
              .compareTo(b['customer'] == last ? 1 : 0);
          return customer != 0
              ? customer
              : order[a['id']]!.compareTo(order[b['id']]!);
        });
      }
      final activeMediaCustomers = <String>{};
      final activeOwners = <String, Set<String>>{};
      final activeUnboundCustomers = <String>{};
      if (mediaOnly != false) {
        for (final active in await txn.query('capture_evidence',
            columns: ['payload'],
            where:
                "state='media_processing'${mediaCustomer == null ? '' : ' AND customer=?'}",
            whereArgs: mediaCustomer == null ? null : [mediaCustomer])) {
          final frame = ViewportEvidence.fromJson(active['payload']! as String);
          if (!isCurrent(frame)) continue;
          activeMediaCustomers.add(frame.customer);
          final frozen = frame.metadata['mediaClaimOwners'];
          final owners = frozen is List
              ? frozen.whereType<String>().toSet()
              : await _admittedMediaOwners(txn, frame);
          if (owners.isEmpty) activeUnboundCustomers.add(frame.customer);
          (activeOwners[frame.customer] ??= {}).addAll(owners);
        }
      }
      for (final row in candidates) {
        if (liveRegistrationOnly && !liveRegistration(row)) continue;
        final evidence = ViewportEvidence.fromJson(row['payload']! as String);
        if (!isCurrent(evidence)) {
          await txn.update('capture_evidence', {'state': 'session_archived'},
              where: 'id=?', whereArgs: [row['id']]);
          continue;
        }
        final mediaOwners = mediaOwnersById[row['id']] ?? const <String>{};
        // Split distinct confirmed owners, but serialize uncertain
        // captures and overlapping views of the same media message.
        if (row['state'] == 'media_retry' &&
            (activeUnboundCustomers.contains(evidence.customer) ||
                (mediaOwners.isEmpty &&
                    activeMediaCustomers.contains(evidence.customer)) ||
                mediaOwners
                    .any((activeOwners[evidence.customer] ?? {}).contains))) {
          continue;
        }
        final registeredMedia =
            savedMediaOcr.contains(evidence.id) && mediaOwners.isNotEmpty;
        if (!liveRegistration(row) && !registeredMedia) {
          final earlier =
              await txn.rawQuery("""SELECT 1 FROM capture_evidence AS earlier
            WHERE earlier.customer=?
              AND (earlier.captured_at_ms<? OR
                (earlier.captured_at_ms=? AND earlier.id<?))
              AND earlier.state IN ('captured','processing','retry')
              AND NOT EXISTS (SELECT 1 FROM capture_discovery_state AS blocked
                WHERE blocked.session_id $sessionMatch AND blocked.customer=earlier.customer
                  AND blocked.ready=0 AND blocked.evidence_id!=earlier.id
                  AND earlier.discovery_requires_baseline=1)
              AND NOT EXISTS (SELECT 1 FROM capture_discovery_state AS bypass
                WHERE bypass.session_id $sessionMatch AND bypass.customer=earlier.customer
                  AND bypass.ready=0 AND ?=0 AND ?!=bypass.evidence_id
                  AND (earlier.id=bypass.evidence_id OR earlier.discovery_requires_baseline=1))
            LIMIT 1""", [
            row['customer'],
            row['captured_at_ms'],
            row['captured_at_ms'],
            row['id'],
            if (_sessionId != null) _sessionId,
            if (_sessionId != null) _sessionId,
            row['discovery_requires_baseline'],
            row['id'],
          ]);
          if (earlier.isNotEmpty) continue;
        }
        final claimed = ViewportEvidence({
          ...evidence.metadata,
          'captureClaimToken':
              '${_sessionId ?? 'legacy'}:${DateTime.now().microsecondsSinceEpoch}:${++_claimSequence}',
          'captureClaimActivationRevision': _activationRevision(evidence),
          if (row['state'] == 'media_retry')
            'mediaClaimOwners': mediaOwners.toList(),
        });
        await txn.update(
            'capture_evidence',
            {
              'payload': claimed.toJson(),
              'state': row['state'] == 'media_retry'
                  ? 'media_processing'
                  : 'processing',
            },
            where: 'id=? AND state=?',
            whereArgs: [row['id'], row['state']]);
        if (row['state'] == 'media_retry') {
          mediaCustomers[fairnessSession] = evidence.customer;
        }
        return claimed;
      }
      return null;
    });
  }

  Future<void> complete(ViewportEvidence evidence,
      {bool partial = false}) async {
    if (!isCurrent(evidence)) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn
          .query('capture_evidence', where: 'id=?', whereArgs: [evidence.id]);
      if (!isCurrent(evidence) ||
          rows.isEmpty ||
          rows.firstOrNull?['state'] == 'session_archived') {
        return;
      }
      final stored =
          ViewportEvidence.fromJson(rows.single['payload']! as String);
      if (!_ownsClaim(stored, evidence)) return;
      if (_activationRevision(stored) > _claimRevision(evidence)) {
        await txn.update(
            'capture_evidence',
            {
              'state': 'captured',
              'retry_at_ms': 0,
              'payload':
                  ViewportEvidence(_releaseClaim(stored, replayOcr: true))
                      .toJson(),
            },
            where: 'id=?',
            whereArgs: [evidence.id]);
        return;
      }
      if (rows.isNotEmpty &&
          _activationAdvanced(
              ViewportEvidence.fromJson(rows.single['payload']! as String),
              evidence)) {
        return;
      }
      if (await _isObsoleteBaseline(txn, evidence)) {
        await txn.update(
            'capture_evidence',
            {
              'state': 'processed',
              'payload': ViewportEvidence(_releaseClaim(stored)).toJson(),
            },
            where: "id=? AND state!='session_archived'",
            whereArgs: [evidence.id]);
        return;
      }
      if (evidence.metadata['capturePurpose'] == 'discovery_baseline') {
        final baseline = await txn.query('capture_discovery_state',
            where: 'session_id=? AND customer=? AND evidence_id=?',
            whereArgs: [_sessionId, evidence.customer, evidence.id]);
        if (baseline.firstOrNull?['ready'] != 1) return;
      }
      if (rows.isNotEmpty &&
          evidence.pinnedMedia == null &&
          ViewportEvidence.fromJson(rows.single['payload']! as String)
                  .pinnedMedia !=
              null) {
        // A download can finish after the worker's last read. Its final
        // completion must not overwrite the newly available original's job.
        await txn.update(
            'capture_evidence',
            {
              'state': 'captured',
              'retry_at_ms': 0,
              'payload':
                  ViewportEvidence(_releaseClaim(stored, replayOcr: true))
                      .toJson(),
            },
            where: 'id=?',
            whereArgs: [evidence.id]);
        return;
      }
      final storedMetadata = rows.isEmpty
          ? evidence.metadata
          : ViewportEvidence.fromJson(rows.single['payload']! as String)
              .metadata;
      final recheck = storedMetadata['mediaTypeRecheckRequested'] == true;
      await txn.update(
          'capture_evidence',
          {
            'payload': ViewportEvidence({
              ..._releaseClaim(stored),
              if (recheck) 'mediaTypeRecheckRequested': false,
            }).toJson(),
            'state': recheck
                ? 'media_retry'
                : partial
                    ? 'partial'
                    : 'processed',
            if (recheck) ...{
              'retry_at_ms': 0,
            } else if (evidence.metadata['mediaAcquisitionPending'] == true)
              'retry_at_ms':
                  now().add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          },
          where: 'id=?',
          whereArgs: [evidence.id]);
      await txn.update('capture_discovery_state', {'ready': 1},
          where: 'session_id=? AND customer=? AND evidence_id=? AND kind=?',
          whereArgs: [_sessionId, evidence.customer, evidence.id, 'live']);
      if (const {'live_signal', 'durable_unanswered', 'media_acquisition'}
          .contains(evidence.metadata['capturePurpose'])) {
        final obsolete = (await txn.query('capture_discovery_state',
                where:
                    'session_id=? AND customer=? AND ready=0 AND evidence_id!=?',
                whereArgs: [_sessionId, evidence.customer, evidence.id]))
            .firstOrNull;
        if (obsolete != null) {
          await txn.update(
              'capture_discovery_state',
              {
                'ready': 1,
                'kind': 'live',
                'evidence_id': evidence.id,
                'payload': evidence.toJson(),
              },
              where: 'session_id=? AND customer=?',
              whereArgs: [_sessionId, evidence.customer]);
          await txn.update('capture_evidence', {'state': 'processed'},
              where: "id=? AND state!='session_archived'",
              whereArgs: [obsolete['evidence_id']]);
        }
      }
      final pending = await txn.query('capture_evidence',
          columns: ['id'],
          where:
              "customer=? AND state NOT IN ('processed','partial','failed','session_archived')",
          whereArgs: [evidence.customer],
          limit: 1);
      if (pending.isEmpty) {
        await txn.update('capture_observations', {'state': 'processed'},
            where: 'customer=?', whereArgs: [evidence.customer]);
      }
    });
  }

  /// A model hint can request bounded offline re-extraction; it cannot put a
  /// live UI/OCR dependency back into the formal send path.
  Future<bool> retryMedia(String id,
      {Duration delay = const Duration(seconds: 5),
      bool background = false}) async {
    final evidence = await lookup(id);
    if (evidence == null || !isCurrent(evidence)) return false;
    return await (await database.database).rawUpdate(
            """UPDATE capture_evidence
        SET state=?, attempts=attempts+1, retry_at_ms=?
        WHERE id=? AND state IN ('processed','partial') ${background ? '' : 'AND attempts<3'}""",
            [
              background ? 'media_retry' : 'retry',
              now().add(delay).millisecondsSinceEpoch,
              id
            ]) >
        0;
  }

  Future<bool> requestMediaTypeRecheck(String id,
      {Set<String> acquisitionOwnerKeys = const {}}) async {
    final db = await database.database;
    return db.transaction((txn) async {
      final row = (await txn.query('capture_evidence',
              where: 'id=?', whereArgs: [id], limit: 1))
          .firstOrNull;
      if (row == null || row['state'] == 'session_archived') return false;
      final evidence = ViewportEvidence.fromJson(row['payload']! as String);
      if (!isCurrent(evidence)) return false;
      final processing =
          const {'processing', 'media_processing'}.contains(row['state']);
      await txn.update(
          'capture_evidence',
          {
            'payload': ViewportEvidence({
              ...evidence.metadata,
              'mediaTypeRecheckRequested': processing,
              if (evidence.metadata['acquisitionOnly'] == true &&
                  acquisitionOwnerKeys.isNotEmpty)
                'acquisitionInputKeys': {
                  ...(evidence.metadata['acquisitionInputKeys'] as List? ??
                          const [])
                      .whereType<String>(),
                  ...acquisitionOwnerKeys,
                }.toList(),
            }).toJson(),
            if (!processing) 'state': 'media_retry',
            if (!processing) 'retry_at_ms': 0,
          },
          where: 'id=?',
          whereArgs: [id]);
      return true;
    });
  }

  Future<void> fail(ViewportEvidence evidence, Object error) async {
    if (!isCurrent(evidence)) return;
    final db = await database.database;
    await db.transaction((txn) async {
      final rows = await txn.query('capture_evidence',
          where: 'id=?', whereArgs: [evidence.id], limit: 1);
      if (!isCurrent(evidence) ||
          rows.isEmpty ||
          rows.single['state'] == 'session_archived') {
        return;
      }
      final stored =
          ViewportEvidence.fromJson(rows.single['payload']! as String);
      if (!_ownsClaim(stored, evidence)) return;
      if (_activationRevision(stored) > _claimRevision(evidence)) {
        await txn.update(
            'capture_evidence',
            {
              'state': 'captured',
              'retry_at_ms': 0,
              'payload':
                  ViewportEvidence(_releaseClaim(stored, replayOcr: true))
                      .toJson(),
            },
            where: 'id=?',
            whereArgs: [evidence.id]);
        return;
      }
      if (_activationAdvanced(stored, evidence)) return;
      if (await _isObsoleteBaseline(txn, evidence)) return;
      final anchor = await txn.query('capture_discovery_state',
          where: 'session_id=? AND customer=? AND evidence_id=? AND ready=0',
          whereArgs: [_sessionId, evidence.customer, evidence.id]);
      final retained = anchor.isNotEmpty ||
          evidence.metadata['mediaAcquisitionPending'] == true ||
          evidence.metadata['capturePurpose'] == 'active_discovery';
      final backgroundCapture = const {'active_discovery', 'media_acquisition'}
              .contains(evidence.metadata['capturePurpose']) ||
          evidence.metadata['mediaAcquisitionPending'] == true ||
          rows.single['state'] == 'media_processing';
      await txn.rawUpdate(
          '''UPDATE capture_evidence SET
      attempts=attempts+1,state=CASE WHEN ?=1 THEN 'media_retry' WHEN ?=1 THEN 'retry' WHEN attempts>=2 THEN 'failed' ELSE 'retry' END,
      retry_at_ms=?,last_error=?,payload=? WHERE id=? AND state!='session_archived' ''',
          [
            backgroundCapture ? 1 : 0,
            retained ? 1 : 0,
            now().add(const Duration(seconds: 5)).millisecondsSinceEpoch,
            error.runtimeType.toString(),
            ViewportEvidence(_releaseClaim(stored)).toJson(),
            evidence.id
          ]);
    });
  }

  bool _activationAdvanced(
          ViewportEvidence stored, ViewportEvidence callback) =>
      (stored.metadata['replyActivationAllowed'] == true &&
          callback.metadata['replyActivationAllowed'] != true) ||
      (stored.metadata['capturePurpose'] == 'discovery_baseline' &&
          callback.metadata['capturePurpose'] == 'history_only') ||
      (const {'live_signal', 'durable_unanswered', 'media_acquisition'}
              .contains(stored.metadata['capturePurpose']) &&
          const {'active_discovery', 'discovery_baseline'}
              .contains(callback.metadata['capturePurpose']));

  Future<bool> _isObsoleteBaseline(
      DatabaseExecutor executor, ViewportEvidence evidence) async {
    if (evidence.metadata['capturePurpose'] != 'discovery_baseline') {
      return false;
    }
    final anchor = (await executor.query('capture_discovery_state',
            where: 'session_id=? AND customer=?',
            whereArgs: [_sessionId, evidence.customer]))
        .firstOrNull;
    return anchor?['ready'] == 1 && anchor?['evidence_id'] != evidence.id;
  }

  Future<void> recover(Directory directory) async {
    if (_sessionId != null) return;
    final db = await database.database;
    await db.rawUpdate(
        "UPDATE capture_evidence SET state=CASE WHEN state='media_processing' THEN 'media_retry' ELSE 'captured' END WHERE state IN ('processing','media_processing')");
    if (!await directory.exists()) return;
    await for (final file in directory.list()) {
      if (file is! File ||
          !file.path.endsWith('.json') ||
          file.path.endsWith('.ocr.json')) {
        continue;
      }
      try {
        final data = Map<String, Object?>.from(
            jsonDecode(await file.readAsString()) as Map);
        data['manifestPath'] = file.path;
        final id = data['evidenceId']?.toString() ?? '';
        if (id.isEmpty || p.basename(id) != id) continue;
        data['imagePath'] = p.join(file.parent.path, '$id.png');
        final existing = await lookup(id);
        if (existing?.pinnedMedia case final pinned?) {
          final updated = {...pinned};
          if (pinned['evidenceFile'] is String) {
            updated['evidenceFile'] = p.join(file.parent.path,
                p.basename(pinned['evidenceFile']! as String));
          }
          data['pinnedMedia'] = updated;
        }
        final evidence = ViewportEvidence(data);
        // An interrupted write is recoverable only when both artifacts exist.
        if (await evidence.filesExist()) {
          await record(evidence);
          await db.update('capture_evidence', {'payload': evidence.toJson()},
              where: 'id=?', whereArgs: [id]);
        }
      } catch (_) {/* Partial manifests never become customer messages. */}
    }
  }

  Future<Set<String>> awaitingFrameCustomers() async =>
      (await (await database.database).query('capture_observations',
              columns: ['customer'], where: "state='observed'"))
          .map((r) => r['customer']! as String)
          .toSet();
  Future<DateTime?> firstObserved(String customer) async {
    final rows = await (await database.database).query('capture_observations',
        where: 'customer=?', whereArgs: [customer], limit: 1);
    return rows.isEmpty || rows.single['state'] == 'session_archived'
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            rows.single['first_seen_ms']! as int,
            isUtc: true);
  }

  static bool _sameBackfillOwnership(
      ViewportEvidence first, ViewportEvidence second) {
    for (final key in [
      'replyActivationAllowed',
      'acquisitionOnly',
      'mediaAcquisitionPending'
    ]) {
      if ((first.metadata[key] == true) != (second.metadata[key] == true)) {
        return false;
      }
    }
    Set<String> keys(ViewportEvidence frame) =>
        (frame.metadata['acquisitionInputKeys'] as List? ?? const [])
            .whereType<String>()
            .toSet();
    final a = keys(first), b = keys(second);
    return a.length == b.length && a.containsAll(b);
  }

  /// Header OCR can explain a gap, but cannot create a new arrival or move
  /// its clock backwards. Recovery belongs to one current AX signal or one
  /// explicitly associated unfinished parent, not to a newly captured ID.
  Future<({DateTime at, String key})?> _headerRecovery(
      ViewportEvidence evidence, DateTime? senderAt) async {
    if (!isCurrent(evidence) ||
        evidence.metadata['historyCutoffMs'] != null ||
        evidence.metadata['replyActivationAllowed'] != true ||
        evidence.metadata['acquisitionOnly'] == true ||
        senderAt == null) {
      return null;
    }
    final db = await database.database;
    final document = await (await database.history).read(evidence.customer);
    final messages =
        (document?['messages'] as List? ?? const []).whereType<Map>();
    final explicit = await currentAcquisitionOwnerKeys(evidence);
    if (explicit.isNotEmpty && _sessionId != null) {
      final pending = await db.query('automation_session_messages',
          where: "session_id=? AND user_id=? AND response_state='pending'",
          whereArgs: [_sessionId, evidence.customer]);
      for (final row in pending) {
        final message = messages
            .where((m) =>
                m['id'] == row['message_id'] &&
                DateTime.tryParse(m['sent_at']?.toString() ?? '') == senderAt &&
                (explicit.contains(m['id']) ||
                    (m['observed_ids'] as List? ?? const [])
                        .any(explicit.contains)))
            .firstOrNull;
        if (message == null) continue;
        return (
          at: DateTime.fromMillisecondsSinceEpoch(
              row['activated_at_ms']! as int,
              isUtc: true),
          key: '$_sessionId:${evidence.customer}:owner:${row['message_id']}'
        );
      }
    }
    final arrival = evidence.metadata['unreadArrivalKey'];
    if (arrival is! String || arrival.isEmpty) return null;
    // A known body keeps its existing pending/answered state. Seeing its
    // header in a different viewport does not start another recovery.
    if (messages.any((message) =>
        message['direction'] == 'incoming' &&
        DateTime.tryParse(message['sent_at']?.toString() ?? '') == senderAt &&
        ((message['body']?.toString().trim().isNotEmpty ?? false) ||
            (message['media'] as List? ?? const []).isNotEmpty))) {
      return null;
    }
    final trustedTimes = messages
        .where((message) =>
            (message['direction'] == 'incoming' &&
                _sessionId != null &&
                (message['live_observed_session_ids'] as List? ?? const [])
                    .contains(_sessionId)) ||
            (message['direction'] == 'outgoing' &&
                message['delivery_attempt_id'] != null &&
                const {'sent', 'accepted'}
                    .contains(message['delivery_status'])))
        .map((message) =>
            DateTime.tryParse(message['sent_at']?.toString() ?? ''))
        .whereType<DateTime>();
    if (trustedTimes.any(senderAt.isBefore)) return null;
    final cycle = (await db.query('platform_response_cycles',
            where: "user_id=? AND state='waiting' AND identity_verified=1",
            whereArgs: [evidence.customer]))
        .firstOrNull;
    if (cycle == null) return null;
    final started = cycle['started_at_ms']! as int;
    if (evidence.capturedAt.millisecondsSinceEpoch < started) return null;
    return (
      at: DateTime.fromMillisecondsSinceEpoch(started, isUtc: true),
      key:
          '$_sessionId:${evidence.customer}:arrival:${cycle['cycle_id']}:$arrival'
    );
  }

  Future<bool> needsHeaderRecovery(
          ViewportEvidence evidence, DateTime? senderAt) async =>
      await _headerRecovery(evidence, senderAt) != null;

  Future<DateTime?> claimHeaderRecoveryAnchor(
      ViewportEvidence evidence, DateTime? senderAt) async {
    final recovery = await _headerRecovery(evidence, senderAt);
    if (recovery == null ||
        !isCurrent(evidence) ||
        !_headerRecoveryClaims.add(recovery.key)) {
      return null;
    }
    return recovery.at;
  }

  /// Limit a coverage wake to parents explicitly associated with this page.
  /// Neither an old title nor a customer-wide list grants such ownership.
  Future<Set<String>> currentAcquisitionOwnerKeys(
      ViewportEvidence evidence) async {
    if (!isCurrent(evidence)) return {};
    final db = await database.database;
    final requested = <String>{
      ...(evidence.metadata['acquisitionInputKeys'] as List? ?? const [])
          .whereType<String>(),
    };
    for (final row in await db.query('media_capture_audit',
        columns: ['details'],
        where: 'customer=? AND evidence_id=?',
        whereArgs: [evidence.customer, evidence.id])) {
      final details = jsonDecode(row['details']! as String) as Map;
      for (final key in [
        'parentMessageId',
        'resolvedMessageId',
        'mediaReceiptId'
      ]) {
        if (details[key] is String) requested.add(details[key]! as String);
      }
    }
    if (requested.isEmpty) return {};
    if (_sessionId == null) return requested;
    final pending = (await db.query('automation_session_messages',
            columns: ['message_id'],
            where: "session_id=? AND user_id=? AND response_state='pending' "
                "AND input_kind IN ('media','unknown')",
            whereArgs: [_sessionId, evidence.customer]))
        .map((row) => row['message_id']! as String)
        .toSet();
    final result = <String>{...requested.intersection(pending)};
    final items = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [evidence.customer]);
    for (final root in items.where((row) =>
        row['canonical_id'] == null &&
        row['admission_session_id'] == _sessionId &&
        pending.contains(row['message_id']))) {
      final keys = <String>{
        root['item_id']! as String,
        root['message_id']! as String
      };
      var changed = true;
      while (changed) {
        changed = false;
        for (final row in items) {
          if (keys.contains(row['item_id']) ||
              keys.contains(row['canonical_id'])) {
            final before = keys.length;
            keys.add(row['item_id']! as String);
            if (row['message_id'] is String) {
              keys.add(row['message_id']! as String);
            }
            keys.addAll((jsonDecode(row['aliases_json']! as String) as List)
                .whereType<String>());
            changed = changed || before != keys.length;
          }
        }
      }
      if (keys.intersection(requested).isNotEmpty) result.addAll(keys);
    }
    return result;
  }

  /// Re-extracting a saved page must retain the original coverage duty. The
  /// time that page happened to be captured cannot create a new history job.
  Future<DateTime> backfillCutoffFor(ViewportEvidence evidence,
      {DateTime? currentSignalAt}) async {
    final cutoff = evidence.metadata['historyCutoffMs'];
    if (cutoff is num) {
      return DateTime.fromMillisecondsSinceEpoch(cutoff.toInt(), isUtc: true);
    }
    final db = await database.database;
    return db.transaction((txn) async {
      final row = (await txn.query('capture_evidence',
              where: 'id=?', whereArgs: [evidence.id], limit: 1))
          .firstOrNull;
      final stored = row == null
          ? evidence
          : ViewportEvidence.fromJson(row['payload']! as String);
      if (stored.metadata['mediaCoverageCutoffMs'] case final num frozen) {
        return DateTime.fromMillisecondsSinceEpoch(frozen.toInt(), isUtc: true);
      }
      // Prefer this exact observation's proven card family, not another
      // message's customer-wide recovery clock. Different bubbles retain
      // their own first-seen anchors, even when their sender clocks coincide.
      final observed = await txn.query('media_capture_audit',
          where: 'customer=? AND evidence_id=?',
          whereArgs: [evidence.customer, evidence.id]);
      final items = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [evidence.customer]);
      final firstSeen = <int>[];
      for (final observation in observed) {
        final details = jsonDecode(observation['details']! as String) as Map;
        final receipt = details['mediaReceiptId'];
        if (receipt is String) {
          var item = items.where((r) => r['item_id'] == receipt).firstOrNull;
          final visited = <String>{};
          while (item?['canonical_id'] != null &&
              visited.add(item!['item_id']! as String)) {
            item = items
                .where((r) => r['item_id'] == item?['canonical_id'])
                .firstOrNull;
          }
          if (item != null) firstSeen.add(item['first_seen_ms']! as int);
        }
        final group = details['observationGroupId'];
        if (group is String) {
          final anchor = (await txn.query('media_capture_audit',
                  where: 'observation_id=? AND customer=?',
                  whereArgs: [group, evidence.customer],
                  limit: 1))
              .firstOrNull;
          if (anchor != null) {
            final value = jsonDecode(anchor['details']! as String) as Map;
            final at = DateTime.tryParse(value['capturedAt']?.toString() ?? '');
            if (at != null) firstSeen.add(at.millisecondsSinceEpoch);
          }
        }
      }
      firstSeen.sort();
      final chosen = firstSeen.isNotEmpty
          ? DateTime.fromMillisecondsSinceEpoch(firstSeen.first, isUtc: true)
          : currentSignalAt ?? evidence.capturedAt;
      if (row != null &&
          isCurrent(stored) &&
          row['state'] != 'session_archived') {
        await txn.update(
            'capture_evidence',
            {
              'payload': ViewportEvidence({
                ...stored.metadata,
                'mediaCoverageCutoffMs': chosen.millisecondsSinceEpoch,
              }).toJson()
            },
            where: 'id=?',
            whereArgs: [evidence.id]);
      }
      return chosen;
    });
  }

  Future<void> requestBackfill(String customer, DateTime cutoff,
      {int stepPixels = 400, bool reopenCovered = false}) async {
    if (_sessionStartedAt != null && cutoff.isBefore(_sessionStartedAt!)) {
      return;
    }
    await (await database.database).rawInsert(
        '''INSERT INTO capture_backfill(customer,cutoff_ms,step_pixels)
      VALUES(?,?,?) ON CONFLICT(customer) DO UPDATE SET cutoff_ms=excluded.cutoff_ms,pages=0,page_limit=3,oldest_seen_ms=NULL,state='pending',retry_at_ms=0,failures=0,step_pixels=excluded.step_pixels
      WHERE capture_backfill.state='session_archived' OR excluded.cutoff_ms > capture_backfill.cutoff_ms + 3000''',
        [customer, cutoff.millisecondsSinceEpoch, stepPixels]);
    if (reopenCovered) {
      // Reuse the remaining progress window; a repeat request earns no pages.
      await (await database.database).rawUpdate("""UPDATE capture_backfill
        SET state='pending' WHERE customer=? AND cutoff_ms=? AND state='covered' AND pages<page_limit""",
          [customer, cutoff.millisecondsSinceEpoch]);
    }
  }

  Future<List<Map<String, Object?>>> pendingBackfills() async =>
      (await database.database).query('capture_backfill',
          where: "state='pending' AND pages<page_limit AND retry_at_ms<=?",
          whereArgs: [now().millisecondsSinceEpoch],
          orderBy: 'retry_at_ms ASC, customer ASC');
  Future<void> deferBackfill(String customer) async =>
      (await database.database).rawUpdate("""UPDATE capture_backfill
        SET retry_at_ms=?+CASE failures WHEN 0 THEN 10000 WHEN 1 THEN 30000
          WHEN 2 THEN 60000 ELSE 300000 END,failures=failures+1 WHERE customer=?""",
          [now().millisecondsSinceEpoch, customer]);
  Future<List<Map<String, Object?>>> dueRestorations() async =>
      (await database.database).query('capture_backfill',
          where: 'restore_needed=1 AND retry_at_ms<=?',
          whereArgs: [now().millisecondsSinceEpoch]);

  Future<void> backfillAttempt(String customer, {DateTime? cutoff}) async =>
      (await database.database).rawUpdate(
          "UPDATE capture_backfill SET pages=pages+1,retry_at_ms=MAX(retry_at_ms,?),state=CASE WHEN state='covered' THEN state WHEN pages+1>=page_limit THEN 'exhausted' ELSE state END WHERE customer=? AND (? IS NULL OR cutoff_ms=?)",
          [
            now().millisecondsSinceEpoch,
            customer,
            cutoff?.millisecondsSinceEpoch,
            cutoff?.millisecondsSinceEpoch
          ]);

  /// Only older verified sender clocks earn more history pages. A repeated
  /// frame/clock cannot reopen an exhausted job. Each no-progress window is
  /// bounded, while real progress may continue until the requested boundary.
  Future<bool> reportBackfillProgress(
      String customer, DateTime cutoff, DateTime oldest) async {
    if (!oldest.isAfter(cutoff.add(const Duration(seconds: 3)))) return false;
    final changed =
        await (await database.database).rawUpdate("""UPDATE capture_backfill
      SET oldest_seen_ms=?,page_limit=MAX(page_limit,pages+3),
      state=CASE WHEN state='exhausted' THEN 'pending' ELSE state END
      WHERE customer=? AND cutoff_ms=? AND state!='covered'
      AND (oldest_seen_ms IS NULL OR ?<oldest_seen_ms-3000)""", [
      oldest.millisecondsSinceEpoch,
      customer,
      cutoff.millisecondsSinceEpoch,
      oldest.millisecondsSinceEpoch
    ]);
    return changed > 0;
  }

  Future<bool> covered(String customer, {DateTime? cutoff}) async =>
      await (await database.database).update(
          'capture_backfill', {'state': 'covered'},
          where: cutoff == null
              ? "customer=? AND state!='covered'"
              : "customer=? AND cutoff_ms=? AND state!='covered'",
          whereArgs: [
            customer,
            if (cutoff != null) cutoff.millisecondsSinceEpoch,
          ]) >
      0;

  Future<Map<String, int>> restoreCutoffs() async => {
        for (final row in await (await database.database)
            .query('capture_backfill', where: 'restore_needed=1'))
          row['customer']! as String: row['cutoff_ms']! as int,
      };
  Future<void> setRestore(String customer, bool needed) async =>
      (await database.database).update(
          'capture_backfill', {'restore_needed': needed ? 1 : 0},
          where: 'customer=?', whereArgs: [customer]);
  Future<String?> coverageState(String customer) async {
    final rows = await (await database.database).query('capture_backfill',
        where: 'customer=?', whereArgs: [customer], limit: 1);
    return rows.isEmpty ? null : rows.single['state']! as String;
  }

  Future<void> captureFailed(String customer) async =>
      (await database.database).rawUpdate(
          "UPDATE capture_observations SET attempts=attempts+1,state=CASE WHEN attempts>=2 THEN 'capture_failed' ELSE state END WHERE customer=?",
          [customer]);
  Future<Set<String>> failedCaptures() async => (await (await database.database)
          .query('capture_observations', where: "state='capture_failed'"))
      .map((r) => r['customer']! as String)
      .toSet();

  /// Both extraction workers share this retention pass. Cleanup never owns a
  /// business task and therefore cannot fail a message-processing drain.
  Future<void> pruneProcessed({int keep = 200}) {
    final running = _pruning;
    if (running != null) return running;
    final future = _pruneProcessed(keep: keep).catchError((Object _) {});
    _pruning = future;
    unawaited(future.then<void>((_) {
      if (identical(_pruning, future)) _pruning = null;
    }));
    return future;
  }

  Future<({Set<String> ids, Set<String> paths})> _retainedEvidence() async {
    final db = await database.database;
    final ids = <String>{};
    final paths = <String>{};
    for (final row in await db.query('capture_evidence',
        where: "state!='processed' AND state!='session_archived'")) {
      final evidence = ViewportEvidence.fromJson(row['payload']! as String);
      ids.add(evidence.id);
      paths.addAll([
        evidence.imagePath,
        evidence.manifestPath,
        '${evidence.manifestPath}.ocr.json',
        if (evidence.pinnedMedia?['evidenceFile'] is String)
          evidence.pinnedMedia!['evidenceFile']! as String,
      ]);
    }
    for (final row in await db.query('capture_discovery_state',
        columns: ['evidence_id'],
        where: _sessionId == null ? null : 'session_id=?',
        whereArgs: _sessionId == null ? null : [_sessionId])) {
      ids.add(row['evidence_id']! as String);
    }
    final work = await db.query('automation_session_messages',
        where: _sessionId == null
            ? "response_state='pending'"
            : "session_id=? AND response_state='pending'",
        whereArgs: _sessionId == null ? null : [_sessionId]);
    final byCustomer = <String, Set<String>>{};
    for (final row in work) {
      byCustomer
          .putIfAbsent(row['user_id']! as String, () => {})
          .add(row['message_id']! as String);
    }
    if (_sessionId == null) {
      for (final row in await db.query('pending_customers')) {
        byCustomer
            .putIfAbsent(row['user_id']! as String, () => {})
            .add(row['newest_message_id']! as String);
      }
    }
    final store = await database.history;
    for (final entry in byCustomer.entries) {
      final document = await store.read(entry.key);
      for (final message
          in (document?['messages'] as List? ?? const []).whereType<Map>()) {
        if (entry.value.contains(message['id']) ||
            (message['observed_ids'] as List? ?? const [])
                .any(entry.value.contains)) {
          if (message['capture_evidence_id'] is String) {
            ids.add(message['capture_evidence_id']! as String);
          }
        }
      }
      for (final row in await db.query('customer_media_items',
          where: 'customer=?', whereArgs: [entry.key])) {
        if (entry.value.contains(row['message_id']) ||
            (jsonDecode(row['aliases_json']! as String) as List)
                .any(entry.value.contains)) {
          if (row['evidence_id'] is String) {
            ids.add(row['evidence_id']! as String);
          }
        }
      }
      for (final row in await db.query('media_capture_audit',
          where: 'customer=?', whereArgs: [entry.key])) {
        final details = jsonDecode(row['details']! as String) as Map;
        if (entry.value.contains(details['parentMessageId']) ||
            entry.value.contains(details['resolvedMessageId'])) {
          ids.add(row['evidence_id']! as String);
        }
      }
    }
    return (ids: ids, paths: paths);
  }

  Future<void> _pruneProcessed({required int keep}) async {
    final db = await database.database;
    final rows = await db.query('capture_evidence',
        where: "state='processed'",
        orderBy: 'captured_at_ms DESC',
        offset: keep);
    if (rows.isEmpty) return;
    final retained = await _retainedEvidence();
    for (final row in rows) {
      final evidence = ViewportEvidence.fromJson(row['payload']! as String);
      if (retained.ids.contains(evidence.id)) continue;
      // Only files owned by this evidence cache are eligible for retention.
      final base = p.dirname(evidence.manifestPath);
      final ownedPaths = [
        evidence.imagePath,
        evidence.manifestPath,
        '${evidence.manifestPath}.ocr.json',
        if (evidence.pinnedMedia?['evidenceFile'] is String)
          evidence.pinnedMedia!['evidenceFile']! as String
      ].where((path) =>
          p.dirname(path) == base && p.basename(path).startsWith(evidence.id));
      if (ownedPaths.any(retained.paths.contains)) continue;
      // Claim only a still-completed frame. Active/retry frames and unresolved
      // observations remain durable even if another worker changed them after
      // the retention list was read.
      final claimed = await db.rawUpdate(
          '''UPDATE capture_evidence SET state='pruning'
        WHERE id=? AND state='processed' AND NOT EXISTS(
          SELECT 1 FROM media_capture_audit a WHERE a.evidence_id=capture_evidence.id
          AND a.state IN ('unbound','discovered','unverified','image_partial','video_preview_only','failed'))''',
          [evidence.id]);
      if (claimed != 1) continue;
      var removed = true;
      for (final path in ownedPaths) {
        try {
          await File(path).delete();
        } on FileSystemException catch (error) {
          // A second cleaner or an earlier partial pass may already have
          // removed it. Other I/O errors retain the row for a later attempt.
          if (error.osError?.errorCode != 2) {
            removed = false;
            break;
          }
        }
      }
      if (removed) {
        await db.delete('capture_evidence',
            where: "id=? AND state='pruning'", whereArgs: [evidence.id]);
      } else {
        await db.update('capture_evidence', {'state': 'processed'},
            where: "id=? AND state='pruning'", whereArgs: [evidence.id]);
      }
    }
  }
}
