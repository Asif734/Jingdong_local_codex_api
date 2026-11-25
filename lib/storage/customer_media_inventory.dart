import '../runtime/delivery_context_guard.dart';
import '../capture/media_card_occurrence.dart';
import '../capture/incoming_message_ownership.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show ConflictAlgorithm, DatabaseExecutor;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import '../capture/media_timeline_progress.dart';
import '../domain/reply_progress.dart';
import '../runtime/runtime_trace.dart';
import 'capture_database.dart';
import 'conversation_file_store.dart';
import 'media_visual_matcher.dart';

/// Local card receipts, not platform IDs or a license to guess cache ownership.
/// A preview, original and sampled frames are revisions of one card receipt.
class MediaParent {
  const MediaParent(
      {required this.receiptId,
      required this.messageId,
      required this.admissionKey,
      required this.admissionSessionId,
      required this.receivedAt,
      required this.isCurrentSession});
  final String receiptId;
  final String messageId;
  final String? admissionKey;
  final String? admissionSessionId;
  final DateTime? receivedAt;
  final bool isCurrentSession;
}

/// A receipt answer and the exact identified cards that support its facts.
/// Acquisition gaps qualify uncertainty without becoming a referenced card.
class MediaReceiptFact {
  const MediaReceiptFact(this.reply, this.items);
  final String reply;
  final List<Map<String, dynamic>> items;
}

class CustomerMediaInventory {
  CustomerMediaInventory(this.database,
      {this.beforeClassificationCommitForTesting});
  final CaptureDatabase database;

  @visibleForTesting
  final Future<void> Function(String itemId)?
      beforeClassificationCommitForTesting;

  /// The daily hot path selects original message ownership before loading
  /// payloads. A cache representation seen today cannot redate an old root.
  /// Explicit canonical descendants are material of that selected receipt,
  /// including older observations; they are never separate daily messages.
  Future<List<Map<String, Object?>>> _hotRows(String customer,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await database.database;
    final day = database.currentBusinessDayKey;
    if (day == null) {
      return db.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
    }
    final start =
        DateTime.parse('${day}T00:00:00+08:00').millisecondsSinceEpoch;
    final end = start + const Duration(days: 1).inMilliseconds;
    final prefix = 'incoming-time:${Uri.encodeComponent(customer)}:';
    final length = prefix.length + 20;
    // Sender times use the existing (customer,sender_ms) index. Only legacy
    // unclocked roots need their small identity metadata checked in SQLite;
    // unrelated historical media_json/aliases never enter the Dart hot loop.
    return db.rawQuery('''WITH RECURSIVE unclocked(item_id,message_ms) AS (
      SELECT item_id,COALESCE(
        CASE WHEN substr(message_id,1,?)=? AND length(message_id)=?
          THEN CAST(strftime('%s',substr(message_id,-20)) AS INTEGER)*1000 END,
        (SELECT MIN(CAST(strftime('%s',substr(value,-20)) AS INTEGER)*1000)
          FROM json_each(CASE WHEN json_valid(aliases_json)
            THEN aliases_json ELSE '[]' END)
          WHERE type='text' AND substr(value,1,?)=? AND length(value)=?),
        first_seen_ms)
      FROM customer_media_items
      WHERE customer=? AND canonical_id IS NULL AND sender_ms IS NULL
    ), roots(item_id,message_ms) AS (
      SELECT item_id,sender_ms FROM customer_media_items
        WHERE customer=? AND canonical_id IS NULL AND sender_ms>=? AND sender_ms<?
      UNION SELECT item_id,message_ms FROM unclocked WHERE message_ms>=? AND message_ms<?
    ), family(item_id,message_ms) AS (
      SELECT item_id,message_ms FROM roots
      UNION SELECT child.item_id,parent.message_ms FROM customer_media_items child
        JOIN family parent ON child.canonical_id=parent.item_id
        WHERE child.customer=?
    ) SELECT media.*,selected.message_ms AS business_day_message_ms
      FROM customer_media_items media
      JOIN family selected ON selected.item_id=media.item_id
      WHERE media.customer=? ORDER BY media.first_seen_ms,media.item_id''', [
      prefix.length,
      prefix,
      length,
      prefix.length,
      prefix,
      length,
      customer,
      customer,
      start,
      end,
      start,
      end,
      customer,
      customer,
    ]);
  }

  bool _messageInBusinessDay(String customer, Map message) {
    final day = database.currentBusinessDayKey;
    if (day == null) return true;
    var stamp = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    if (stamp == null) {
      final prefix = 'incoming-time:${Uri.encodeComponent(customer)}:';
      final keys = <Object?>{
        message['customer_message_time_key'],
        message['id'],
        ...(message['observed_ids'] as List? ?? const []),
      };
      for (final key in keys.whereType<String>()) {
        if (!key.startsWith(prefix)) continue;
        stamp = DateTime.tryParse(key.substring(prefix.length));
        if (stamp != null) break;
      }
    }
    stamp ??= DateTime.tryParse(message['captured_at']?.toString() ?? '');
    return stamp != null && ConversationFileStore.businessDayFor(stamp) == day;
  }

  /// Successful audio conclusions, including a genuine absence of speech.
  /// Retryable permission, timeout and decoder errors are not conclusions.
  static bool hasTerminalVideoAudio(Iterable<Map> media) => media.any((m) {
        if (m['type'] != 'video' && m['type'] != 'audio') return false;
        final text = m['description']?.toString() ?? '';
        return RegExp(r'\[Video speech transcript(?: \([^\]]*\))?:',
                    caseSensitive: false)
                .hasMatch(text) ||
            text.contains('[Video audio: no audio stream]') ||
            text.contains(
                '[Video audio: an audio stream exists, but no meaningful audible content was detected]') ||
            text.contains(
                '[Video audio: audible content exists, but no speech was recognized]');
      });

  /// Parsed metadata is not usable media when its local image has disappeared.
  /// Video originals/audio may be removed after all frames and terminal audio
  /// facts have been extracted; the image inputs still supplied to analysis
  /// must remain readable, nonempty local files.
  static Future<bool> analysisFilesPresent(
      String kind, Iterable<Map> payload) async {
    final media = payload.toList();
    final video = kind == 'video' ||
        media.any((item) =>
            item['type'] == 'video' ||
            item['capture_source'] == 'jd_video_frame_1fps');
    final images = media.where((item) =>
        item['type'] == 'image' &&
        (video ||
            item['is_partial'] != true &&
                item['is_loading_preview'] != true &&
                !const {
                  'jd_video_cover',
                  'verified_media_preview',
                  'jd_video_preview',
                  'jd_video_frame_1fps',
                }.contains(item['capture_source'])));
    if (images.isEmpty) return false;
    for (final image in images) {
      final path = image['path']?.toString() ?? '';
      if (!await localFileReadableNonempty(path)) return false;
    }
    return true;
  }

  static Future<bool> localFileReadableNonempty(String path) async {
    if (path.isEmpty) return false;
    RandomAccessFile? opened;
    try {
      final uri = Uri.tryParse(path);
      if (uri == null || uri.hasScheme && uri.scheme != 'file') return false;
      final file = uri.scheme == 'file' ? File.fromUri(uri) : File(path);
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.file) {
        return false;
      }
      opened = await file.open();
      return await opened.length() > 0 && await opened.readByte() >= 0;
    } on FileSystemException {
      return false;
    } on ArgumentError {
      return false;
    } finally {
      await opened?.close();
    }
  }

  /// Formal-reply eligibility for a received media message. Progress remains
  /// on its original receipt; intermediate covers/frames are not new messages.
  Future<Set<String>> analysisReadyMessageIds(String customer,
      {DatabaseExecutor? executor}) async {
    final rows = await _hotRows(customer, executor: executor);
    final groups = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final root = _provenRoot(row, rows);
      if (root != null) {
        groups.putIfAbsent(root['item_id']! as String, () => []).add(row);
      }
    }
    final ready = <String>{};
    for (final family in groups.values) {
      if (!_compatibleFamily(family)) continue;
      final root = family.firstWhere((r) => r['canonical_id'] == null);
      if ((database.currentAutomationSessionId != null &&
              root['message_id'] == null) ||
          root['kind'] == 'text' ||
          root['identity_ambiguous'] == 1 ||
          root['state'] == 'awaiting_kind') {
        continue;
      }
      final media =
          ConversationFileStore.mergeProvenMediaPayloads(family.map(_payload))
              .media;
      if (media.any((m) => m['type_verification'] == 'pending')) continue;
      final isVideo =
          root['kind'] == 'video' || media.any((m) => m['type'] == 'video');
      final available = isVideo
          ? media.any((m) => m['type'] == 'video') &&
              media.any((m) => ConversationFileStore.mediaRoles(m)
                  .contains('first_frame')) &&
              media.any((m) =>
                  ConversationFileStore.mediaRoles(m).contains('last_frame')) &&
              media.any((m) =>
                  m['is_loading_preview'] != true &&
                  ConversationFileStore.mediaRoles(m)
                      .contains('video_cover')) &&
              hasTerminalVideoAudio(media)
          : media.any((m) =>
              m['type'] == 'image' &&
              m['is_partial'] != true &&
              m['is_loading_preview'] != true &&
              !const {
                'jd_video_cover',
                'verified_media_preview',
                'jd_video_preview',
                'jd_video_frame_1fps'
              }.contains(m['capture_source']));
      if (!available ||
          !await analysisFilesPresent(root['kind']! as String, media)) {
        continue;
      }
      for (final row in family) {
        ready.add(row['item_id']! as String);
        if (row['message_id'] is String) {
          ready.add(row['message_id']! as String);
        }
        ready.addAll(
            (jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
                .whereType<String>());
      }
    }
    return ready;
  }

  /// AI's description is only a request to recheck a currently owned image
  /// card. It does not prove the customer sent a video, and creates no input.
  Future<bool> markMediaTypeVerificationPending(String customer,
      {required String messageId,
      String? receiptId,
      required String imagePath}) async {
    final session = database.currentAutomationSessionId;
    if (session == null || imagePath.isEmpty) return false;
    final db = await database.database;
    final result = await db.transaction((txn) async {
      final rows = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final candidates =
          rows.where((r) => r['canonical_id'] == null).where((r) {
        final keys = _receiptKeys(r, rows);
        return keys.contains(messageId) &&
            (receiptId == null || keys.contains(receiptId));
      }).toList();
      if (candidates.length != 1) return (blocked: false, changed: false);
      final root = candidates.single;
      final family = rows
          .where((r) => _provenRoot(r, rows)?['item_id'] == root['item_id'])
          .toList();
      if (!_compatibleFamily(family)) return (blocked: false, changed: false);
      final keys = _receiptKeys(root, rows);
      final live = await txn.query('automation_session_messages',
          columns: ['message_id'],
          where:
              "session_id=? AND user_id=? AND response_state NOT IN ('answered','delegated')",
          whereArgs: [session, customer]);
      if (!live.any((r) => keys.contains(r['message_id']))) {
        return (blocked: false, changed: false);
      }
      final merged =
          ConversationFileStore.mergeProvenMediaPayloads(family.map(_payload))
              .media;
      if (root['kind'] == 'video' || merged.any((m) => m['type'] == 'video')) {
        return (blocked: false, changed: false);
      }
      final images = merged
          .where((m) =>
              m['type'] == 'image' &&
              m['path'] == imagePath &&
              !const {
                'jd_video_cover',
                'jd_video_preview',
                'verified_media_preview',
                'jd_video_frame_1fps'
              }.contains(m['capture_source']))
          .toList();
      if (images.isEmpty ||
          images.any((m) => m['type_verification'] == 'image_confirmed')) {
        return (blocked: false, changed: false);
      }
      var changed = root['state'] != 'awaiting_kind';
      for (final row in family) {
        final media = _payload(row);
        var updated = false;
        for (final image in media) {
          if (image['type'] == 'image' &&
              image['path'] == imagePath &&
              image['type_verification'] != 'pending') {
            image['type_verification'] = 'pending';
            updated = true;
          }
        }
        if (updated) {
          await txn.update(
              'customer_media_items', {'media_json': jsonEncode(media)},
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, row['item_id']]);
          changed = true;
        }
      }
      await txn.update('customer_media_items', {'state': 'awaiting_kind'},
          where: 'customer=? AND item_id=?',
          whereArgs: [customer, root['item_id']]);
      return (blocked: true, changed: changed);
    });
    if (result.changed) {
      await _bump(customer, invalidatedInputs: {messageId});
    }
    return result.blocked;
  }

  /// Resolve only a native-rechecked, exact receipt. A cached still image
  /// (including a photo of a video player) is not a video merely because AI
  /// described a play icon. Its successful native verdict is reused per file.
  Future<bool> resolveMediaTypeVerification(String customer,
      {required String receiptId,
      required String nativeKind,
      required String? captureSource,
      required bool playbackOverlayDetected,
      bool hasVideoObject = false,
      bool hasImageBytes = false,
      bool verifiedOriginal = false}) async {
    final image = MediaTimelineProgress.isVerifiedImageOriginal(
        nativeKind: nativeKind,
        captureSource: captureSource,
        hasImageBytes: hasImageBytes,
        playbackOverlayDetected: playbackOverlayDetected,
        hasVideoPayload: hasVideoObject,
        verifiedOriginal: verifiedOriginal);
    final video =
        nativeKind == 'video' && (hasVideoObject || playbackOverlayDetected);
    if (!image && !video) return false;
    final session = database.currentAutomationSessionId;
    if (session == null) return false;
    final db = await database.database;
    final changed = await db.transaction((txn) async {
      final rows = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final receipt = rows.where((r) => r['item_id'] == receiptId).firstOrNull;
      final root = receipt == null ? null : _provenRoot(receipt, rows);
      if (root == null) return false;
      final family = rows
          .where((r) => _provenRoot(r, rows)?['item_id'] == root['item_id'])
          .toList();
      if (!_compatibleFamily(family)) return false;
      final keys = _receiptKeys(root, rows);
      final live = await txn.query('automation_session_messages',
          columns: ['message_id'],
          where: 'session_id=? AND user_id=?',
          whereArgs: [session, customer]);
      if (!live.any((r) => keys.contains(r['message_id']))) return false;
      var updated = false;
      for (final row in family) {
        final media = _payload(row);
        var rowChanged = false;
        for (final file in media) {
          if (file['type_verification'] != 'pending') continue;
          file['type_verification'] =
              image ? 'image_confirmed' : 'video_confirmed';
          if (video) {
            file['capture_source'] = 'verified_media_preview';
            file['is_partial'] = true;
          }
          rowChanged = true;
        }
        if (rowChanged) {
          await txn.update(
              'customer_media_items', {'media_json': jsonEncode(media)},
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, row['item_id']]);
          updated = true;
        }
      }
      if (!updated) return false;
      // Reconciliation outside the transaction promotes the strongest proven
      // payload. A native video preview stays pending until all parsing ends.
      await txn.update(
          'customer_media_items',
          {
            'kind': video ? 'video' : 'image',
            'state': video ? 'preview' : 'ready'
          },
          where: 'customer=? AND item_id=?',
          whereArgs: [customer, root['item_id']]);
      return true;
    });
    if (changed) {
      await reconcileProvenMediaAliases(customer: customer);
      await _bump(customer);
    }
    return changed;
  }

  Future<Set<String>> typeVerificationEvidenceIds(String customer,
      {required String receiptId}) async {
    final db = await database.database;
    final rows = await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final receipt = rows.where((r) => r['item_id'] == receiptId).firstOrNull;
    final root = receipt == null ? null : _provenRoot(receipt, rows);
    if (root == null) return {};
    final ids = rows
        .where((r) => _provenRoot(r, rows)?['item_id'] == root['item_id'])
        .map((r) => r['item_id'])
        .toList();
    if (ids.isEmpty) return {};
    final observations = await db.query('media_card_observations',
        columns: ['evidence_id'],
        where:
            'customer=? AND canonical_id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: [customer, ...ids]);
    final result = <String>{};
    for (final id in observations
        .map((r) => r['evidence_id'])
        .whereType<String>()
        .toSet()) {
      final saved = (await db.query('capture_evidence',
              columns: ['payload'],
              where: 'id=? AND customer=?',
              whereArgs: [id, customer]))
          .firstOrNull;
      if (saved == null) continue;
      final payload = jsonDecode(saved['payload']! as String) as Map;
      if (payload['automationSessionId'] ==
          database.currentAutomationSessionId) {
        result.add(id);
      }
    }
    return result;
  }

  /// A capture/cache operation must carry this existing business parent.
  /// Observations without an admitted parent are not incoming messages.
  Future<MediaParent?> resolveParent(String customer,
      {required String receiptId, bool requireCurrentSession = false}) async {
    final rows = await (await database.database).query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final observed = rows.where((r) => r['item_id'] == receiptId).firstOrNull;
    final root = observed == null ? null : _provenRoot(observed, rows);
    if (root == null ||
        root['kind'] == 'text' ||
        root['identity_ambiguous'] == 1 ||
        root['message_id'] is! String) {
      return null;
    }
    final family = rows
        .where((r) => _provenRoot(r, rows)?['item_id'] == root['item_id'])
        .toList();
    if (!_compatibleFamily(family)) return null;
    final current = root['admission_key'] != null &&
        root['admission_session_id'] == database.currentAutomationSessionId;
    if (requireCurrentSession && !current) return null;
    return MediaParent(
        receiptId: root['item_id']! as String,
        messageId: root['message_id']! as String,
        admissionKey: root['admission_key'] as String?,
        admissionSessionId: root['admission_session_id'] as String?,
        receivedAt: root['admitted_at_ms'] is int
            ? DateTime.fromMillisecondsSinceEpoch(
                root['admitted_at_ms']! as int,
                isUtc: true)
            : null,
        isCurrentSession: current);
  }

  /// Business identity is customer + JD sender date/second. An answered or
  /// prior-session owner is still returned for deduplication, never activated.
  Future<MediaParent?> findTimeParent(
      String customer, DateTime senderAt) async {
    final second = CustomerMessageTime.second(senderAt).millisecondsSinceEpoch;
    final key = CustomerMessageTime.occurrenceKey(customer, senderAt);
    final rows = await (await database.database).query('customer_media_items',
        where: 'customer=? AND canonical_id IS NULL AND message_id IS NOT NULL '
            'AND identity_ambiguous=0 AND kind!=? '
            'AND (admission_key=? OR (sender_ms>=? AND sender_ms<?))',
        whereArgs: [customer, 'text', key, second, second + 1000],
        orderBy: 'admitted_at_ms ASC,first_seen_ms ASC');
    if (rows.isEmpty) return null;
    final indexed = await database.incomingMessageIdAtTime(customer, senderAt);
    final indexedRows = indexed == null
        ? const <Map<String, Object?>>[]
        : rows.where((row) => row['message_id'] == indexed).toList();
    // The timeline may already own this second as text or an answered prior
    // record. Its database identity wins over a newer temporary media item.
    if (indexed != null && indexedRows.isEmpty) return null;
    final current = rows.where((row) =>
        row['admission_session_id'] == database.currentAutomationSessionId);
    final chosen = indexedRows.firstOrNull ?? current.firstOrNull ?? rows.first;
    return resolveParent(customer, receiptId: chosen['item_id']! as String);
  }

  Future<DateTime?> recordedSenderTime(
      String customer, String receiptId) async {
    final rows = await (await database.database).query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    final row = rows.where((row) => row['item_id'] == receiptId).firstOrNull;
    final root = row == null ? null : _provenRoot(row, rows);
    final value = root?['sender_ms'];
    if (value is num) {
      return CustomerMessageTime.second(
          DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true));
    }
    // A legacy inventory row may have missed a clock already persisted on its
    // message. It is not an unclocked owner that a later header may reassign.
    if (root?['message_id'] is! String) return null;
    final messageId = root!['message_id']! as String;
    final document = await (await database.history).read(customer);
    final message = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) =>
            m['direction'] == 'incoming' &&
            (m['id'] == messageId ||
                (m['observed_ids'] as List? ?? const []).contains(messageId)))
        .firstOrNull;
    final clock = DateTime.tryParse(message?['sent_at']?.toString() ?? '');
    return clock == null ? null : CustomerMessageTime.second(clock);
  }

  static bool _differentSenderSeconds(Map a, Map b) =>
      a['sender_ms'] is num &&
      b['sender_ms'] is num &&
      (a['sender_ms'] as num).toInt() ~/ 1000 !=
          (b['sender_ms'] as num).toInt() ~/ 1000;

  /// Complete an already received untyped duty with its one proven video
  /// representation. Unadmitted observations may acquire that exact parent;
  /// independently admitted messages can never enter this transaction.
  Future<({MediaParent parent, Set<String> originEvidenceIds})?>
      bindUnknownVideoOwner(String customer,
          {required String proofObservationId,
          required String expectedSessionId}) async {
    if (database.currentAutomationSessionId != expectedSessionId) return null;
    final db = await database.database;
    final result = await db.transaction((txn) async {
      if (database.currentAutomationSessionId != expectedSessionId) return null;
      final auditRows = await txn.query('media_capture_audit',
          where:
              'customer=? AND state NOT IN (\'baseline\',\'session_archived\')',
          whereArgs: [customer]);
      final typedRow = auditRows
          .where((r) => r['observation_id'] == proofObservationId)
          .firstOrNull;
      if (typedRow == null) return null;
      final typed = Map<String, Object?>.from(
          jsonDecode(typedRow['details']! as String) as Map);
      final proof = typed['unknownMediaOwnerProof'];
      if (typed['automationSessionId'] != expectedSessionId ||
          proof is! Map ||
          proof['kind'] != 'one_physical_video_refines_unknown_block' ||
          proof['sessionId'] != expectedSessionId ||
          proof['customer'] != customer ||
          proof['typedObservationId'] != proofObservationId ||
          proof['typedOwnership'] is! Map ||
          proof['holderOwnership'] is! Map ||
          (proof['sameFrozenBlock'] != true &&
              proof['verifiedPhysicalPixels'] != true)) {
        return null;
      }
      final holderRow = auditRows
          .where((r) => r['observation_id'] == proof['holderObservationId'])
          .firstOrNull;
      if (holderRow == null) return null;
      final holder = jsonDecode(holderRow['details']! as String) as Map;
      if (holder['automationSessionId'] != expectedSessionId ||
          holder['parentMessageId'] != proof['ownerMessageId'] ||
          holder['mediaReceiptId'] != proof['ownerReceiptId'] ||
          holder['evidenceId'] != proof['holderEvidenceId'] ||
          typed['evidenceId'] != proof['typedEvidenceId']) {
        return null;
      }
      final a = IncomingMessageOwnershipEvidence.fromMap(
          proof['typedOwnership'] as Map);
      final b = IncomingMessageOwnershipEvidence.fromMap(
          proof['holderOwnership'] as Map);
      if (a.customer != customer ||
          b.customer != customer ||
          !a.uniquePhysicalCard ||
          !b.uniquePhysicalCard ||
          !a.explicitVideo ||
          !b.explicitVideo) {
        return null;
      }
      if (proof['sameFrozenBlock'] == true) {
        if (typed['evidenceId'] != holder['evidenceId']) return null;
        for (final key in [
          'headerRegion',
          'bodyRegion',
          'mediaContentRegion',
          'headerText',
          'headerOrdinal'
        ]) {
          if (jsonEncode((proof['typedOwnership'] as Map)[key]) !=
              jsonEncode((proof['holderOwnership'] as Map)[key])) {
            return null;
          }
        }
      }
      final items = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final requested = items
          .where((r) => r['item_id'] == proof['ownerReceiptId'])
          .firstOrNull;
      final owner = requested == null ? null : _provenRoot(requested, items);
      if (owner == null ||
          owner['admission_session_id'] != expectedSessionId ||
          owner['message_id'] != proof['ownerMessageId'] ||
          owner['identity_ambiguous'] == 1 ||
          owner['kind'] == 'text' ||
          owner['admission_key'] is! String) {
        return null;
      }
      final alreadyBound =
          (typed['unknownMediaOwnerBinding'] as Map?)?['ownerReceiptId'] ==
              owner['item_id'];
      if (!alreadyBound &&
          (owner['kind'] != 'unknown' || _payload(owner).isNotEmpty)) {
        return null;
      }
      final work = await txn.query('automation_session_messages',
          where: 'session_id=? AND user_id=? AND message_id=?',
          whereArgs: [expectedSessionId, customer, owner['message_id']]);
      if (work.length != 1 || work.single['response_state'] != 'pending') {
        return null;
      }
      final typedGroup = typed['observationGroupId'];
      final familyAudit = <Map<String, Object?>>[];
      for (final row in auditRows) {
        final details = jsonDecode(row['details']! as String) as Map;
        if (details['automationSessionId'] != expectedSessionId) continue;
        if (row['observation_id'] == proofObservationId ||
            (typedGroup != null &&
                details['observationGroupId'] == typedGroup)) {
          final parent = details['parentMessageId'];
          if (parent != null && parent != owner['message_id']) return null;
          familyAudit.add(row);
        }
      }
      final sourceIds = <String>{
        for (final row in familyAudit)
          if (jsonDecode(row['details']! as String) case final Map value)
            if (value['mediaReceiptId'] is String)
              value['mediaReceiptId']! as String,
      }..remove(owner['item_id']);
      final sourceRoots = <Map<String, Object?>>[];
      for (final receipt in sourceIds) {
        final raw = items.where((r) => r['item_id'] == receipt).firstOrNull;
        if (raw == null) continue;
        final root = _provenRoot(raw, items);
        if (root == null) return null;
        if (root['item_id'] == owner['item_id']) continue;
        if (root['admission_key'] != null ||
            root['admission_session_id'] != null ||
            root['message_id'] != null ||
            root['identity_ambiguous'] == 1 ||
            root['kind'] == 'text') {
          return null;
        }
        if (sourceRoots.every((r) => r['item_id'] != root['item_id'])) {
          sourceRoots.add(root);
        }
      }
      final sourceFamilies = items
          .where((r) => sourceRoots.any(
              (root) => _provenRoot(r, items)?['item_id'] == root['item_id']))
          .toList();
      final merged = ConversationFileStore.mergeProvenMediaPayloads(
          [_payload(owner), ...sourceFamilies.map(_payload)]);
      final phase = _payloadState(merged.media, 'video');
      await txn.update(
          'customer_media_items',
          {
            'kind': 'video',
            'state': phase.state,
            'media_json': jsonEncode(merged.media),
            if (owner['sender_ms'] == null && a.sentAt != null)
              'sender_ms': a.sentAt!.millisecondsSinceEpoch
          },
          where: 'customer=? AND item_id=?',
          whereArgs: [customer, owner['item_id']]);
      for (final source in sourceFamilies) {
        await txn.update('customer_media_items',
            {'canonical_id': owner['item_id'], 'state': 'superseded'},
            where: 'customer=? AND item_id=?',
            whereArgs: [customer, source['item_id']]);
        await txn.update(
            'media_card_observations', {'canonical_id': owner['item_id']},
            where: 'customer=? AND (item_id=? OR canonical_id=?)',
            whereArgs: [customer, source['item_id'], source['item_id']]);
      }
      // A new exact observation goes straight to the existing business root;
      // no temporary second customer_media_item/admission is necessary.
      final box = (typed['region']! as List)
          .cast<num>()
          .map((n) => n.toDouble())
          .toList();
      await txn.rawInsert('''INSERT INTO media_card_observations
        (observation_id,item_id,customer,evidence_id,observed_ms,region_json,canonical_id)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(observation_id) DO UPDATE SET
        item_id=excluded.item_id,canonical_id=excluded.canonical_id''', [
        _observationKey(customer, typed['evidenceId']! as String, box),
        owner['item_id'],
        customer,
        typed['evidenceId'],
        DateTime.parse(typed['capturedAt']! as String).millisecondsSinceEpoch,
        jsonEncode(box),
        owner['item_id']
      ]);
      final canonicalGroup =
          (owner['admission_key']! as String).startsWith('bubble:')
              ? (owner['admission_key']! as String).substring(7)
              : holder['observationGroupId'];
      final origins = <String>{};
      for (final row in [...familyAudit, holderRow]) {
        final details = Map<String, Object?>.from(
            jsonDecode(row['details']! as String) as Map);
        details.addAll({
          'parentMessageId': owner['message_id'],
          'mediaReceiptId': owner['item_id'],
          'observationGroupId': canonicalGroup,
          'attributionPending': false,
          'videoOccurrenceProven': true,
          'kind': 'video',
          'unknownMediaOwnerBinding': {
            'ownerReceiptId': owner['item_id'],
            'ownerMessageId': owner['message_id'],
            'proofObservationId': proofObservationId
          }
        });
        if (details['liveArrivalProof'] case final Map arrival) {
          details['originalLiveArrivalProof'] ??= arrival;
          details['liveArrivalProof'] = {
            ...arrival,
            'observationGroupId': canonicalGroup,
            'occurrenceKey': owner['admission_key']
          };
        }
        await txn.update(
            'media_capture_audit', {'details': jsonEncode(details)},
            where: 'observation_id=?', whereArgs: [row['observation_id']]);
        origins.add(row['evidence_id']! as String);
      }
      return (
        receipt: owner['item_id']! as String,
        message: owner['message_id']! as String,
        origins: origins,
        changed: !alreadyBound
      );
    });
    if (result == null ||
        database.currentAutomationSessionId != expectedSessionId) {
      return null;
    }
    if (result.changed) {
      await _bump(customer, invalidatedInputs: {result.message});
    }
    final parent = await resolveParent(customer,
        receiptId: result.receipt, requireCurrentSession: true);
    return parent == null
        ? null
        : (parent: parent, originEvidenceIds: result.origins);
  }

  /// A readable header enriches an already proven received card; it is never
  /// a new admission and cannot rewrite a known sender clock or receive time.
  Future<bool> refineParentClock(String customer,
      {required MediaParent parent, required DateTime senderAt}) async {
    if (!parent.isCurrentSession ||
        parent.admissionSessionId != database.currentAutomationSessionId) {
      return false;
    }
    final db = await database.database;
    final rows = await db.query('customer_media_items',
        where:
            'customer=? AND item_id=? AND message_id=? AND admission_session_id=? AND canonical_id IS NULL',
        whereArgs: [
          customer,
          parent.receiptId,
          parent.messageId,
          parent.admissionSessionId
        ]);
    if (rows.length != 1 ||
        rows.single['kind'] == 'text' ||
        rows.single['identity_ambiguous'] == 1) {
      return false;
    }
    senderAt = CustomerMessageTime.second(senderAt);
    final known = rows.single['sender_ms'];
    if (known is num &&
        known.toInt() ~/ 1000 != senderAt.millisecondsSinceEpoch ~/ 1000) {
      return false;
    }
    if (known == null) {
      final persisted = await recordedSenderTime(customer, parent.receiptId);
      if (persisted != null &&
          !CustomerMessageTime.sameSecond(persisted, senderAt)) {
        return false;
      }
    }
    final indexed = await database.bindIncomingMessageTime(
        customer, parent.messageId, senderAt);
    if (indexed == null) return false;
    await db.update(
        'customer_media_items', {'sender_ms': senderAt.millisecondsSinceEpoch},
        where: 'customer=? AND item_id=? AND sender_ms IS NULL',
        whereArgs: [customer, parent.receiptId]);
    // Existing FileStore identity requires the exact receipt-bearing media
    // message. It fills only a null clock and preserves body/assets/receivedAt.
    await (await database.history)
        .refineMediaClock(customer, indexed, senderAt);
    return database.currentAutomationSessionId == parent.admissionSessionId;
  }

  Future<bool> hasExactBoundObservation(String customer,
      {required String evidenceId,
      required List<double> region,
      required MediaParent parent}) async {
    final rows = await (await database.database).query(
        'media_card_observations',
        where: 'observation_id=? AND customer=? AND evidence_id=?',
        whereArgs: [
          _observationKey(customer, evidenceId, region),
          customer,
          evidenceId
        ]);
    if (rows.length != 1) return false;
    final receipt = rows.single['canonical_id'] ?? rows.single['item_id'];
    if (receipt is! String) return false;
    final resolved = await resolveParent(customer,
        receiptId: receipt, requireCurrentSession: true);
    return resolved?.receiptId == parent.receiptId &&
        resolved?.messageId == parent.messageId;
  }

  /// Only the immutable-frame audit can authorize joining two admissions.
  /// Reusing files, sender seconds or viewport ordinals cannot call this path.
  /// DB reply coverage is reconciled separately after this short transaction.
  Future<({String canonicalReceiptId, String duplicateReceiptId})?>
      bindProvenBubbleOwners(String customer,
          {required String proofObservationId,
          required String expectedSessionId}) async {
    if (database.currentAutomationSessionId != expectedSessionId) return null;
    final db = await database.database;
    return db.transaction((txn) async {
      if (database.currentAutomationSessionId != expectedSessionId) return null;
      final observation = (await txn.query('media_capture_audit',
              where: 'customer=? AND observation_id=? AND state!=?',
              whereArgs: [customer, proofObservationId, 'session_archived']))
          .firstOrNull;
      if (observation == null) return null;
      final details = jsonDecode(observation['details']! as String) as Map;
      final proof = details['sameBubbleOwnerProof'];
      if (details['automationSessionId'] != expectedSessionId ||
          proof is! Map) {
        return null;
      }
      final imageProof =
          proof['kind'] == 'same_physical_image_loading_sender_block';
      final physicalVideoProof =
          proof['kind'] == 'same_physical_video_ownership_pixels';
      if (!imageProof &&
          !physicalVideoProof &&
          proof['kind'] != 'same_physical_video_sender_block') {
        return null;
      }
      final receipts = (proof['ownerReceipts'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      final observationIds = (proof['observationIds'] as List? ?? const [])
          .whereType<String>()
          .toList();
      final evidenceIds = (proof['evidenceIds'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      if (receipts.length != 2 ||
          observationIds.length != 2 ||
          evidenceIds.length != 2 ||
          !observationIds.contains(proofObservationId)) {
        return null;
      }
      final evidence = <Map>[];
      for (final id in observationIds) {
        final row = (await txn.query('media_capture_audit',
                where: 'customer=? AND observation_id=? AND state!=?',
                whereArgs: [customer, id, 'session_archived']))
            .firstOrNull;
        if (row == null) return null;
        final value = jsonDecode(row['details']! as String) as Map;
        if (value['automationSessionId'] != expectedSessionId ||
            value['occurrenceContext'] is! Map ||
            !evidenceIds.contains(value['evidenceId'])) {
          return null;
        }
        evidence.add(value);
      }
      final first = MediaCardOccurrenceContext.fromMap(
          evidence[0]['occurrenceContext'] as Map);
      final second = MediaCardOccurrenceContext.fromMap(
          evidence[1]['occurrenceContext'] as Map);
      if (imageProof) {
        final a = first.toMap(), b = second.toMap();
        if (!first.hasVerifiedIncomingCard ||
            !second.hasVerifiedIncomingCard ||
            first.conflictsWith(second) ||
            a['headerKey'] != b['headerKey'] ||
            a['headerCount'] != 1 ||
            b['headerCount'] != 1 ||
            a['cardCount'] != 1 ||
            b['cardCount'] != 1 ||
            a['cardSlot'] != 0 ||
            b['cardSlot'] != 0 ||
            a['precedingKey'] == null ||
            a['precedingKey'] != b['precedingKey'] ||
            proof['verifiedLoadingPixels'] != true ||
            proof['verifiedSenderTranslation'] is! int ||
            proof['verifiedPrecedingPixels'] != true ||
            !observationIds.contains(proof['loadingObservationId'])) {
          return null;
        }
      } else if (physicalVideoProof) {
        final values = (proof['physicalOwnerships'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        if (values.length != 2 || proof['verifiedPhysicalPixels'] != true) {
          return null;
        }
        final a = IncomingMessageOwnershipEvidence.fromMap(values[0]);
        final b = IncomingMessageOwnershipEvidence.fromMap(values[1]);
        if (a.customer != customer ||
            b.customer != customer ||
            !a.uniquePhysicalCard ||
            !b.uniquePhysicalCard ||
            (!a.exactCustomerHeader && !b.exactCustomerHeader) ||
            (a.exactCustomerHeader &&
                b.exactCustomerHeader &&
                a.sentAt != b.sentAt)) {
          return null;
        }
      } else if (!first.sameSingleIncomingVideoBlock(second,
          verifiedSameSenderGlyphs:
              proof['verifiedSameSenderGlyphs'] == true)) {
        return null;
      }
      final rows = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final requested = receipts
          .map((id) => rows.where((r) => r['item_id'] == id).firstOrNull)
          .toList();
      if (requested.any((r) =>
          r == null ||
          r['admission_session_id'] != expectedSessionId ||
          r['message_id'] is! String ||
          r['kind'] == 'text' ||
          r['identity_ambiguous'] == 1)) {
        return null;
      }
      final roots = requested.map((r) => _provenRoot(r!, rows)).toList();
      if (roots.any((r) => r == null)) return null;
      if (_differentSenderSeconds(roots[0]!, roots[1]!)) return null;
      final sameRoot = roots[0]!['item_id'] == roots[1]!['item_id'];
      if (imageProof && !sameRoot) {
        // Only an unfinished loading obligation may be repaired. An already
        // ready/answered independent send is never collapsed by this proof.
        final loadingIndex =
            observationIds.indexOf(proof['loadingObservationId']! as String);
        final loadingParent = evidence[loadingIndex]['parentMessageId'];
        final loading = requested
            .where((r) => r!['message_id'] == loadingParent)
            .firstOrNull;
        final pending = loading == null
            ? const <Map<String, Object?>>[]
            : await txn.query('automation_session_messages',
                where: 'session_id=? AND user_id=? AND message_id=?',
                whereArgs: [expectedSessionId, customer, loadingParent]);
        if (loading == null ||
            loading['kind'] == 'video' ||
            loading['state'] == 'ready' ||
            pending.length != 1 ||
            pending.single['response_state'] == 'answered') {
          return null;
        }
      }
      final ordered = roots.cast<Map<String, Object?>>()
        ..sort((a, b) => (a['admitted_at_ms']! as int)
            .compareTo(b['admitted_at_ms']! as int));
      final canonical = ordered.first;
      final duplicateId = sameRoot
          ? receipts.firstWhere((id) => id != canonical['item_id'])
          : ordered.last['item_id']! as String;
      final canonicalId = canonical['item_id']! as String;
      final families = rows
          .where((r) => ordered.any(
              (root) => _provenRoot(r, rows)?['item_id'] == root['item_id']))
          .toList();
      final familyIds = families.map((r) => r['item_id']).toSet();
      final familyMessages =
          families.map((r) => r['message_id']).whereType<String>().toSet();
      final merged = ConversationFileStore.mergeProvenMediaPayloads(
          families.map(_payload));
      final phase = _payloadState(merged.media, canonical['kind']! as String);
      final aliases = <String>{
        for (final row in families) ...{
          if (row['message_id'] is String) row['message_id']! as String,
          ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
              .whereType<String>()
        }
      };
      await txn.update(
          'customer_media_items',
          {
            'media_json': jsonEncode(merged.media),
            'kind': phase.kind,
            'state': phase.state,
            'aliases_json': jsonEncode(aliases.toList()),
            'first_seen_ms': families
                .map((r) => r['first_seen_ms']! as int)
                .reduce((a, b) => a < b ? a : b),
            'last_seen_ms': families
                .map((r) => r['last_seen_ms']! as int)
                .reduce((a, b) => a > b ? a : b),
          },
          where: 'customer=? AND item_id=?',
          whereArgs: [customer, canonicalId]);
      for (final row in families.where((r) => r['item_id'] != canonicalId)) {
        await txn.update(
            'customer_media_items',
            {
              'canonical_id': canonicalId,
              'state': 'superseded',
              'admission_key': null,
            },
            where: 'customer=? AND item_id=?',
            whereArgs: [customer, row['item_id']]);
        await txn.update(
            'media_card_observations', {'canonical_id': canonicalId},
            where: 'customer=? AND (item_id=? OR canonical_id=?)',
            whereArgs: [customer, row['item_id'], row['item_id']]);
      }
      final current = await txn.query('media_capture_audit',
          where: 'customer=? AND state!=?',
          whereArgs: [customer, 'session_archived']);
      final admissionKey = canonical['admission_key'] as String?;
      String? canonicalGroup = admissionKey?.startsWith('bubble:') == true
          ? admissionKey!.substring(7)
          : null;
      canonicalGroup ??= evidence
          .where((e) => e['parentMessageId'] == canonical['message_id'])
          .firstOrNull?['observationGroupId'] as String?;
      // The inventory ancestry, all owner tuples and the recovery journal
      // commit together. No observer can see a new receipt with an old parent.
      for (final row in current) {
        final value = Map<String, Object?>.from(
            jsonDecode(row['details']! as String) as Map);
        if (value['automationSessionId'] != expectedSessionId ||
            (!familyIds.contains(value['mediaReceiptId']) &&
                !familyMessages.contains(value['parentMessageId']))) {
          continue;
        }
        value['mediaReceiptId'] = canonicalId;
        value['parentMessageId'] = canonical['message_id'];
        if (value['resolvedMessageId'] != null) {
          value['resolvedMessageId'] = canonical['message_id'];
        }
        if (canonicalGroup != null) {
          value['observationGroupId'] = canonicalGroup;
        }
        if (value['liveArrivalProof'] case final Map arrival) {
          value['originalLiveArrivalProof'] ??= arrival;
          value['liveArrivalProof'] = {
            ...arrival,
            if (canonicalGroup != null) 'observationGroupId': canonicalGroup,
            if (admissionKey != null) 'occurrenceKey': admissionKey,
          };
        }
        value['attributionPending'] = false;
        if (row['observation_id'] == proofObservationId) {
          value['sameBubbleOwnerRepair'] = {
            'phase': 'inventory_committed',
            'sessionId': expectedSessionId,
            'customer': customer,
            'canonicalReceiptId': canonicalId,
            'duplicateReceiptId': duplicateId,
          };
        }
        await txn.update('media_capture_audit', {'details': jsonEncode(value)},
            where: 'observation_id=?', whereArgs: [row['observation_id']]);
      }
      return (canonicalReceiptId: canonicalId, duplicateReceiptId: duplicateId);
    });
  }

  static List<Map<String, Object?>> _payload(Map row) =>
      (jsonDecode(row['media_json']?.toString() ?? '[]') as List)
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList();

  static bool _compatibleProvenRows(Map a, Map b) {
    if (a['customer'] != b['customer'] || _differentSenderSeconds(a, b)) {
      return false;
    }
    if (a['admission_key'] != null && b['admission_key'] != null) {
      return a['admission_key'] == b['admission_key'] &&
          a['admission_session_id'] == b['admission_session_id'];
    }
    // Explicit DB admission/parent links are stronger than an observation's
    // estimated clock or its viewport-relative ordinal.
    if (a['canonical_id'] == b['item_id'] ||
        b['canonical_id'] == a['item_id']) {
      return true;
    }
    if (a['sender_ms'] != null && b['sender_ms'] != null) {
      return a['sender_ms'] == b['sender_ms'] && a['slot'] == b['slot'];
    }
    return true;
  }

  static bool _compatibleFamily(List<Map<String, Object?>> family) {
    final clocked = family.where((r) => r['sender_ms'] != null).toList();
    final admitted = family.where((r) => r['admission_key'] != null).toList();
    final oneCustomer = family.map((r) => r['customer']).toSet().length == 1;
    if (admitted.isNotEmpty) {
      return oneCustomer &&
          admitted
                  .map((r) =>
                      '${r['admission_session_id']}:${r['admission_key']}')
                  .toSet()
                  .length ==
              1;
    }
    return oneCustomer &&
        clocked.map((r) => r['sender_ms']).toSet().length <= 1 &&
        clocked.map((r) => r['slot']).toSet().length <= 1;
  }

  static Map<String, Object?>? _provenRoot(
      Map<String, Object?> row, List<Map<String, Object?>> rows) {
    var current = row;
    final seen = <String>{};
    while (current['canonical_id'] != null) {
      if (!seen.add(current['item_id']! as String)) return null;
      final next = rows
          .where((r) => r['item_id'] == current['canonical_id'])
          .firstOrNull;
      if (next == null || !_compatibleProvenRows(row, next)) return null;
      current = next;
    }
    return current;
  }

  static ({String kind, String state}) _payloadState(
      List<Map<String, Object?>> media, String previousKind) {
    final video = media.any((m) => m['type'] == 'video');
    if (!video && media.any((m) => m['type_verification'] == 'pending')) {
      return (
        kind: previousKind == 'video' ? 'video' : 'image',
        state: 'awaiting_kind'
      );
    }
    final frames =
        media.any((m) => m['capture_source'] == 'jd_video_frame_1fps');
    final image = media.any((m) =>
        m['type'] == 'image' &&
        m['is_partial'] != true &&
        m['is_loading_preview'] != true &&
        !const {
          'verified_media_preview',
          'jd_video_preview',
          'jd_video_cover',
          'jd_video_frame_1fps'
        }.contains(m['capture_source']));
    final preview = media.any((m) => const {
          'verified_media_preview',
          'jd_video_preview',
          'jd_video_cover'
        }.contains(m['capture_source']));
    final kind = video
        ? 'video'
        : image
            ? 'image'
            : preview || previousKind == 'video'
                ? 'video'
                : 'image';
    return (
      kind: kind,
      state: video && frames || !video && image ? 'ready' : 'preview'
    );
  }

  /// Repair only existing explicit, compatible canonical edges. No new card
  /// association, queue entry or current-session activation is inferred here.
  Future<void> reconcileProvenMediaAliases({String? customer}) async {
    final db = await database.database;
    // Older versions retained a same-file cover interpretation only in
    // history alternates. Read that exact message's role proof before the
    // short SQL transaction; never infer occurrence identity from its bytes.
    final before = await db.query('customer_media_items',
        where: customer == null ? null : 'customer=?',
        whereArgs: customer == null ? null : [customer]);
    final roleHistory = <String, List<Map>>{};
    final roleCustomers = before
        .where((r) =>
            r['canonical_id'] == null &&
            r['message_id'] is String &&
            _payload(r).any((m) => m['type'] == 'video') &&
            !_payload(r).any((m) =>
                ConversationFileStore.mediaRoles(m).contains('video_cover')))
        .map((r) => r['customer']! as String)
        .toSet();
    for (final owner in roleCustomers) {
      final document = await (await database.history).read(owner);
      roleHistory[owner] = (document?['messages'] as List? ?? const [])
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();
    }
    final historyUpdates = <({
      String customer,
      String message,
      Set<String> aliases,
      List<String> receipts
    })>[];
    await db.transaction((txn) async {
      final rows = await txn.query('customer_media_items',
          where: customer == null ? null : 'customer=?',
          whereArgs: customer == null ? null : [customer]);
      final groups = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final root = _provenRoot(row, rows);
        if (root == null) continue;
        groups.putIfAbsent(root['item_id']! as String, () => []).add(row);
      }
      for (final family in groups.values) {
        if (!_compatibleFamily(family)) continue;
        final root = family.firstWhere((r) => r['canonical_id'] == null);
        final ordered = [
          root,
          ...family.where((r) => r['item_id'] != root['item_id'])
        ];
        final owned = ordered.expand(_payload).toList();
        final physical =
            owned.map((m) => '${m['type']}\u001f${m['path']}').toSet();
        final messageKeys = ordered
            .expand((r) => <String>{
                  if (r['message_id'] is String) r['message_id']! as String,
                  ...(jsonDecode(r['aliases_json']?.toString() ?? '[]') as List)
                      .whereType<String>(),
                })
            .toSet();
        final roleProof = (roleHistory[root['customer']] ?? const <Map>[])
            .where((m) =>
                messageKeys.contains(m['id']) ||
                (m['observed_ids'] as List? ?? const [])
                    .any(messageKeys.contains))
            .expand((m) =>
                (m['media_alternates'] as List? ?? const []).whereType<Map>())
            .where((m) =>
                physical.contains('${m['type']}\u001f${m['path']}') &&
                ConversationFileStore.mediaRoles(m).contains('video_cover') &&
                m['is_loading_preview'] != true)
            .toList();
        final merged = ConversationFileStore.mergeProvenMediaPayloads(
            [...ordered.map(_payload), roleProof]);
        if (merged.media.isEmpty) continue;
        final state = _payloadState(merged.media, root['kind']! as String);
        final aliases = <String>{
          for (final row in ordered) ...{
            if (row['message_id'] is String) row['message_id']! as String,
            ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
                .whereType<String>(),
          },
        };
        final canonicalMessage = root['message_id'] as String? ??
            ordered.map((r) => r['message_id']).whereType<String>().firstOrNull;
        final encoded = jsonEncode(merged.media);
        final encodedAliases = jsonEncode(aliases.toList());
        if (root['media_json'] == encoded &&
            root['kind'] == state.kind &&
            root['state'] == state.state &&
            root['message_id'] == canonicalMessage &&
            root['aliases_json'] == encodedAliases) {
          continue;
        }
        await txn.update(
            'customer_media_items',
            {
              'kind': state.kind,
              'state': state.state,
              'media_json': encoded,
              'aliases_json': encodedAliases,
              if (canonicalMessage != null) 'message_id': canonicalMessage,
              'first_seen_ms': ordered
                  .map((r) => r['first_seen_ms']! as int)
                  .reduce((a, b) => a < b ? a : b),
              'last_seen_ms': ordered
                  .map((r) => r['last_seen_ms']! as int)
                  .reduce((a, b) => a > b ? a : b),
            },
            where: 'item_id=? AND customer=?',
            whereArgs: [root['item_id'], root['customer']]);
        if (canonicalMessage != null &&
            (family.length > 1 || roleProof.isNotEmpty)) {
          historyUpdates.add((
            customer: root['customer']! as String,
            message: canonicalMessage,
            aliases: aliases,
            receipts: family.map((r) => r['item_id']! as String).toList()
          ));
        }
      }
    });
    // File serialization is outside SQLite: no nested DB access or file I/O
    // holds the short monotonic payload transaction.
    for (final update in historyUpdates) {
      await (await database.history).consolidateProvenMediaAliases(
          update.customer,
          canonicalMessageId: update.message,
          messageAliases: update.aliases,
          receiptAliases: update.receipts);
    }
  }

  /// Content progress for already proven receipts, independent from response
  /// status. Loading/cover/alias churn cannot wake a waiting reply repeatedly.
  Future<Map<String, String>> analyzableEvidenceKeys(String customer,
      {DatabaseExecutor? executor}) async {
    final rows = await _hotRows(customer, executor: executor);
    final result = <String, String>{};
    final families = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final root = _provenRoot(row, rows);
      if (root != null) {
        families.putIfAbsent(root['item_id']! as String, () => []).add(row);
      }
    }
    for (final family in families.values) {
      if (!_compatibleFamily(family)) continue;
      final root = family.firstWhere((r) => r['canonical_id'] == null);
      if (database.currentAutomationSessionId != null &&
          root['message_id'] == null) {
        continue;
      }
      final media =
          ConversationFileStore.mergeProvenMediaPayloads(family.map(_payload))
              .media;
      final key = analyzablePayloadKey(root['kind']! as String, media,
          receiptId: root['item_id']! as String);
      if (key == null) continue;
      for (final row in family) {
        for (final alias in <String>{
          row['item_id']! as String,
          'media-pending:${row['item_id']}',
          if (row['message_id'] is String) row['message_id']! as String,
          ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
              .whereType<String>(),
        }) {
          result[alias] = key;
        }
      }
    }
    return result;
  }

  /// The same content key for inventory and the actual frozen payload supplied
  /// to generation. Reading a newer SQL row must never stamp an older image
  /// set with the newer row's version.
  static String? analyzablePayloadKey(String kind, Iterable<Map> payload,
      {required String receiptId}) {
    final media = payload.toList();
    final video = kind == 'video' ||
        media.any((m) =>
            m['type'] == 'video' ||
            m['capture_source'] == 'jd_video_frame_1fps');
    if (video) {
      final frames = media
          .where((m) => m['capture_source'] == 'jd_video_frame_1fps')
          .map((m) => m['path']! as String)
          .toSet()
          .toList()
        ..sort();
      final speech = media
          .where((m) => m['type'] == 'audio' || m['type'] == 'video')
          .map((m) => m['description']?.toString() ?? '')
          .expand((text) => RegExp(
                  r'\[(?:Video speech transcript|Speech transcript|语音转写|语音识别结果)(?:\s*\([^\]\r\n]*\))?\s*[:：]\s*[^\]]+\]',
                  caseSensitive: false)
              .allMatches(text)
              .map((match) => match.group(0)!))
          .toSet()
          .toList()
        ..sort();
      return frames.isNotEmpty || speech.isNotEmpty
          ? _hash(['video', frames, speech])
          : null;
    }
    final originals = media
        .where((m) =>
            m['type'] == 'image' &&
            m['is_partial'] != true &&
            m['capture_source'] == 'jd_image_cache')
        .map((m) => m['path']! as String)
        .toSet()
        .toList()
      ..sort();
    if (originals.isNotEmpty) return _hash(['image_original', originals]);
    if (media.any((m) =>
        m['type'] == 'image' &&
        m['is_loading_preview'] != true &&
        !const {'verified_media_preview', 'jd_video_preview'}
            .contains(m['capture_source']))) {
      return _hash(['still_preview', receiptId]);
    }
    return null;
  }

  /// Late speech belongs to one already observed current-session card, not to
  /// every resend of the same file. Only its proven canonical family and exact
  /// owned video path can receive the description; this creates no work item.
  Future<int> updateProvenVideoDescription(
      String customer, String path, String description,
      {required String messageId, String? receiptId}) async {
    final session = database.currentAutomationSessionId;
    if (session == null || description.trim().isEmpty) return 0;
    final db = await database.database;
    final result = await db.transaction((txn) async {
      final rows = await txn.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final roots = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final root = _provenRoot(row, rows);
        if (root != null) {
          roots.putIfAbsent(root['item_id']! as String, () => []).add(row);
        }
      }
      final live = await txn.query('automation_session_messages',
          columns: ['message_id'],
          where: 'session_id=? AND user_id=?',
          whereArgs: [session, customer]);
      final liveIds = live.map((r) => r['message_id']).toSet();
      final owners = roots.values.where((family) {
        if (!_compatibleFamily(family)) return false;
        final keys = <String>{
          for (final row in family) ...{
            row['item_id']! as String,
            'media-pending:${row['item_id']}',
            if (row['message_id'] is String) row['message_id']! as String,
            ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
                .whereType<String>(),
          },
        };
        return keys.contains(messageId) &&
            (receiptId == null || keys.contains(receiptId)) &&
            keys.any(liveIds.contains);
      }).toList();
      if (owners.length != 1) return 0;
      var updated = 0;
      for (final row in owners.single) {
        final media = _payload(row);
        var changed = false;
        for (final file in media) {
          if (file['type'] != 'video' || file['path'] != path) continue;
          final previous = file['description']?.toString() ?? '';
          if (previous.contains(description)) continue;
          file['description'] =
              previous.isEmpty || description.contains(previous)
                  ? description
                  : '$previous\n$description';
          changed = true;
        }
        if (changed) {
          updated += await txn.update(
              'customer_media_items', {'media_json': jsonEncode(media)},
              where: 'item_id=? AND customer=?',
              whereArgs: [row['item_id'], customer]);
        }
      }
      return updated;
    });
    if (result > 0) await _invalidateScopedDeliveryContexts(customer);
    return result;
  }

  static String _observationKey(
          String customer, String evidenceId, List<double> region) =>
      _hash([
        customer,
        evidenceId,
        region.map((v) => double.parse(v.toStringAsFixed(5))).toList()
      ]);
  static String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static bool isReference(String text) => RegExp(
          r'视频|图片|照片|发.{0,8}(?:个|段|张)|收到|看到|看得到|上一个|前一个|上一段|上一张|前一段|前一张|之前|last (?:one|clip)|video|image|photo|picture|received?|did you get|frames?|previous|earlier|sent (?:it|two|one)|see (?:it|them)|(?:check|look at|review|watch) (?:this|that|it)|看看这个|看一下这个',
          caseSensitive: false)
      .hasMatch(text);

  static Set<String> _requestedMediaKinds(String question) => {
        if (RegExp(r'video|clip|frames?|视频|上一段|前一段', caseSensitive: false)
            .hasMatch(question))
          'video',
        if (RegExp(r'image|photo|picture|图片|照片|上一张|前一张', caseSensitive: false)
            .hasMatch(question))
          'image',
      };

  static bool _isReceiptCountQuestion(String question) => RegExp(
          r'how many.{0,30}(?:video|clip|image|photo|picture|attachment|media)|(?:几(?:个|段|张|条)|多少).{0,8}(?:视频|图片|照片|附件)|(?:视频|图片|照片|附件).{0,12}(?:几(?:个|段|张|条)|多少)',
          caseSensitive: false)
      .hasMatch(question);

  static bool _hasExplicitReceiptPosition(String question) =>
      RegExp(r'第一个|第一段|第一张|上一个|上一段|上一张|前一个|first |previous|earlier',
              caseSensitive: false)
          .hasMatch(question);

  /// Resolve a conversational reference among already identified cards. This
  /// selects supporting context, never whether a real question deserves work.
  /// Unknown capture observations cannot participate in this selection.
  static List<Map<String, dynamic>> referencedItems(
      String question, List<Map<String, dynamic>> items) {
    final kinds = _requestedMediaKinds(question);
    final selected = items
        .where((item) =>
            kinds.isEmpty ||
            kinds.contains(item['kind']) ||
            item['kind'] == 'unknown')
        .toList();
    if (selected.isEmpty) return const [];
    if (_isReceiptCountQuestion(question) ||
        RegExp(r'比较|对比|两(?:个|段|张)|compare|both|two ', caseSensitive: false)
            .hasMatch(question)) {
      return selected;
    }
    if (RegExp(r'第一个|第一段|第一张|first (?:one|video|image|photo|picture)',
            caseSensitive: false)
        .hasMatch(question)) {
      return [selected.first];
    }
    final previous =
        RegExp(r'上一个|上一段|上一张|前一个|previous|earlier', caseSensitive: false)
            .hasMatch(question);
    return [
      selected[previous && selected.length > 1
          ? selected.length - 2
          : selected.length - 1]
    ];
  }

  /// Receipt facts use the requested type and referenced physical messages.
  /// An unowned acquisition gap can qualify uncertainty, never prove a receipt,
  /// increment a count, or declare that its content has been analysed.
  static String? receiptReply(String question, List<Map<String, dynamic>> items,
          {required bool english,
          List<Map<String, Object?>> pendingObservations = const []}) =>
      receiptFact(question, items,
              english: english, pendingObservations: pendingObservations)
          ?.reply;

  static MediaReceiptFact? receiptFact(
      String question, List<Map<String, dynamic>> items,
      {required bool english,
      List<Map<String, Object?>> pendingObservations = const []}) {
    final selected = referencedItems(question, items);
    if (RegExp(r'how many frames?|几帧|多少帧', caseSensitive: false)
        .hasMatch(question)) {
      final clips = selected
          .where((m) => m['kind'] == 'video' || m['kind'] == 'unknown')
          .toList();
      if (clips.isEmpty) return null;
      final clip = clips.last;
      final frames = (clip['availableMedia'] as List? ?? const [])
          .whereType<Map>()
          .where((a) => a['capture_source'] == 'jd_video_frame_1fps')
          .map((a) => a['path'])
          .toSet()
          .length;
      if (frames == 0) {
        return MediaReceiptFact(
            english
                ? 'I can see the media message, but its video frames are not available yet, so I cannot verify its frame count.'
                : '已看到这条媒体消息，但暂时还没有可分析的视频帧，无法核实帧数。',
            [clip]);
      }
      return MediaReceiptFact(
          english
              ? 'There are $frames sampled frames available for analysis. This is not the total frame count of the original video.'
              : '目前有$frames张抽取帧可供分析，这不是原视频的总帧数。',
          [clip]);
    }
    final countQuestion = _isReceiptCountQuestion(question);
    if (!isExplicitMediaReceiptQuestion(question)) return null;
    final requested = _requestedMediaKinds(question);
    final requestedEnglish = requested.length == 1 ? requested.single : 'media';
    final requestedChinese = requested.length == 1
        ? (requested.single == 'image' ? '图片' : '视频')
        : '附件';
    final known = selected
        .where((m) =>
            const {'video', 'image'}.contains(m['kind']) &&
            m['identityAmbiguous'] != true)
        .toList();
    final uncertain = selected.length - known.length;
    final knownTimes = known
        .map((m) => DateTime.tryParse(
            (m['receivedAt'] ?? m['senderAt'])?.toString() ?? ''))
        .whereType<DateTime>()
        .toList()
      ..sort();
    final recentGap = pendingObservations.any((observation) {
      final kind = observation['typeHint'];
      if (requested.isNotEmpty &&
          kind != null &&
          kind != 'unknown' &&
          !requested.contains(kind)) {
        return false;
      }
      final at = DateTime.tryParse(observation['observedAt']?.toString() ?? '');
      return knownTimes.isEmpty || at == null || !at.isBefore(knownTimes.last);
    });
    final newerUnconfirmedReference =
        !countQuestion && !_hasExplicitReceiptPosition(question) && recentGap;
    if (known.isEmpty || newerUnconfirmedReference) {
      final unresolved = uncertain > 0 || recentGap;
      final reply = english
          ? (unresolved
              ? 'A media message is still being checked; its type and content are not yet confirmed, so I cannot confirm receipt of the $requestedEnglish you are asking about yet.'
              : 'I cannot confirm receipt of the $requestedEnglish you are asking about yet.')
          : (unresolved
              ? '有附件的类型和内容仍在读取确认中，暂时还无法确认它就是您问的$requestedChinese。'
              : '暂时还无法确认您问的$requestedChinese是否收到。');
      return MediaReceiptFact(
          reply, newerUnconfirmedReference ? const [] : selected);
    }
    final parts = <String>[];
    for (final kind in ['image', 'video']) {
      final sameKind = known.where((m) => m['kind'] == kind).toList();
      if (sameKind.isEmpty) continue;
      final ready = sameKind
          .where((m) =>
              m['analysisAvailable'] == true && m['originalVerified'] == true)
          .length;
      final pending = sameKind.length - ready;
      if (english) {
        final noun = sameKind.length == 1 ? '$kind message' : '$kind messages';
        final availability = pending == 0
            ? 'The $kind content is available for analysis.'
            : '$ready ${ready == 1 ? '$kind is' : '${kind}s are'} available for analysis; the content is not yet available for $pending ${pending == 1 ? kind : '${kind}s'}.';
        parts.add('I can see ${sameKind.length} $noun. $availability');
      } else {
        final noun = kind == 'image' ? '图片' : '视频';
        parts.add('已看到您发来的${sameKind.length}条$noun消息。');
        parts.add(pending == 0
            ? '$noun内容已获取，可以继续分析。'
            : '其中$ready条$noun内容已获取，另外$pending条的内容尚未读取完整。');
      }
    }
    if (uncertain > 0) {
      parts.add(english
          ? 'Additional media has not yet been confirmed by type, so it is not included in that count.'
          : '另有附件的类型仍在确认，尚未计入上述数量。');
    }
    if (recentGap && countQuestion) {
      parts.add(english
          ? 'A newer attachment is still being checked, so this confirmed count may not yet be complete.'
          : '还有较新的附件仍在读取确认，上述已确认数量可能尚不完整。');
    }
    return MediaReceiptFact(parts.join(english ? ' ' : ''), selected);
  }

  Future<void> beginRun(DateTime at) async {
    await (await database.database).rawInsert(
        'INSERT OR REPLACE INTO media_inventory_run(id,started_ms) VALUES(1,?)',
        [at.millisecondsSinceEpoch]);
  }

  Future<String> observe(
      {required String customer,
      required String evidenceId,
      required DateTime observedAt,
      required DateTime? senderAt,
      required int slot,
      required List<double> region,
      required bool current,
      String? occurrenceKey,
      String? parentReceiptId}) async {
    final session = database.currentAutomationSessionId;
    if (parentReceiptId != null && senderAt != null) {
      final previous = await recordedSenderTime(customer, parentReceiptId);
      if (previous != null &&
          !CustomerMessageTime.sameSecond(previous, senderAt)) {
        parentReceiptId = null;
      }
    }
    if (parentReceiptId != null) {
      final rows = await (await database.database).query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final previous =
          rows.where((row) => row['item_id'] == parentReceiptId).firstOrNull;
      final corrected = previous == null ? null : _provenRoot(previous, rows);
      if (corrected?['kind'] == 'text' &&
          corrected?['admission_session_id'] == session) {
        // A result already tied to this bubble keeps the terminal text
        // identity. It cannot manufacture another unbound media candidate.
        return corrected!['item_id']! as String;
      }
    }
    final parent = parentReceiptId == null
        ? senderAt == null
            ? null
            : await findTimeParent(customer, senderAt)
        : await resolveParent(customer, receiptId: parentReceiptId);
    final second =
        senderAt == null ? null : CustomerMessageTime.second(senderAt);
    final key = parent?.receiptId ??
        (second != null
            ? _hash([
                customer,
                'sender-second',
                CustomerMessageTime.occurrenceKey(customer, second)
              ])
            : _hash(session == null
                ? [
                    customer,
                    senderAt?.toUtc().toIso8601String() ?? evidenceId,
                    slot
                  ]
                : occurrenceKey != null && current
                    ? [customer, session, 'arrival', occurrenceKey]
                    : [
                        customer,
                        'observation',
                        evidenceId,
                        region
                            .map((v) => double.parse(v.toStringAsFixed(5)))
                            .toList()
                      ]));
    final db = await database.database;
    await db.rawInsert(
        '''INSERT INTO customer_media_items
      (item_id,customer,sender_ms,slot,kind,state,first_seen_ms,last_seen_ms,evidence_id,media_json,aliases_json)
      VALUES(?,?,?,?,'unknown',?,?,?,?,'[]','[]') ON CONFLICT(item_id) DO UPDATE SET
      last_seen_ms=MAX(last_seen_ms,excluded.last_seen_ms),evidence_id=excluded.evidence_id''',
        [
          key,
          customer,
          second?.millisecondsSinceEpoch,
          second == null ? slot : 0,
          current ? 'detected' : 'historical',
          observedAt.millisecondsSinceEpoch,
          observedAt.millisecondsSinceEpoch,
          evidenceId
        ]);
    await db.rawInsert(
        '''INSERT INTO media_card_observations
      (observation_id,item_id,customer,evidence_id,observed_ms,region_json)
      VALUES(?,?,?,?,?,?) ON CONFLICT(observation_id) DO UPDATE SET
      item_id=excluded.item_id,observed_ms=MAX(observed_ms,excluded.observed_ms)''',
        [
          _observationKey(customer, evidenceId, region),
          key,
          customer,
          evidenceId,
          observedAt.millisecondsSinceEpoch,
          jsonEncode(region)
        ]);
    RuntimeTrace.record('media.card_registered', {
      'customer': customer,
      'mediaItemId': key,
      'evidenceId': evidenceId,
      'senderClock': senderAt?.toUtc().toIso8601String(),
      'slot': slot,
      'region': region,
      'eligibleForAcquisition': current,
      'idSource': 'local_customer_clock_card_slot'
    });
    return key;
  }

  Future<String> classify(String itemId, String kind,
      {String? fingerprint,
      Uint8List? previewBytes,
      String? evidenceId,
      List<double>? region}) async {
    if (!const {'video', 'image'}.contains(kind)) return itemId;
    final db = await database.database;
    var target = itemId;
    final row = (await db.query('customer_media_items',
            where: 'item_id=?', whereArgs: [itemId]))
        .firstOrNull;
    if (row == null) return itemId;
    if (row['kind'] == 'text') return itemId;
    final observationId = evidenceId != null && region != null
        ? _observationKey(row['customer']! as String, evidenceId, region)
        : null;
    final priorObservation = observationId == null
        ? null
        : (await db.query('media_card_observations',
                where: 'observation_id=? AND customer=?',
                whereArgs: [observationId, row['customer']]))
            .firstOrNull;
    if (observationId != null && previewBytes != null) {
      final path = await (await database.history).saveMedia(
          userId: row['customer']! as String,
          filename: 'card_observation.png',
          bytes: previewBytes);
      await db.update('media_card_observations', {'preview_path': path},
          where: 'observation_id=? AND customer=?',
          whereArgs: [observationId, row['customer']]);
    }
    Future<bool> classificationAllowed(
        DatabaseExecutor executor, String value) async {
      final current = await executor.query('customer_media_items',
          where: 'customer=?', whereArgs: [row['customer']]);
      for (final id in {itemId, value}) {
        final item = current.where((item) => item['item_id'] == id).firstOrNull;
        if (item == null || item['kind'] == 'text') return false;
        final root = _provenRoot(item, current);
        if (root == null || root['kind'] == 'text') return false;
      }
      return true;
    }

    Future<bool> finishIn(DatabaseExecutor executor, String value) async {
      if (!await classificationAllowed(executor, value)) return false;
      if (observationId != null) {
        await executor.update(
            'media_card_observations',
            {
              'classified_kind': kind,
              'fingerprint': fingerprint,
              'classified_ms': DateTime.now().millisecondsSinceEpoch,
              'canonical_id': value
            },
            where: 'observation_id=? AND customer=?',
            whereArgs: [observationId, row['customer']]);
      }
      return true;
    }

    Future<String> finish(String value) async {
      await db.transaction((txn) => finishIn(txn, value));
      return value;
    }

    Future<void> bindProven(String rootId,
        {Set<String> provenAliases = const {}}) async {
      final roots = await db.query('customer_media_items',
          where: 'item_id=? AND customer=?',
          whereArgs: [rootId, row['customer']]);
      if (roots.isEmpty) return;
      final aliases =
          (jsonDecode(roots.single['aliases_json']! as String) as List).toSet();
      if (roots.single['message_id'] is String) {
        aliases.add(roots.single['message_id']);
      }
      final retiredReceipts = <String>{rootId};
      for (final previous in {
        itemId,
        if (fingerprint != null) _hash([itemId, fingerprint]),
        ...provenAliases,
      }) {
        if (previous == rootId) continue;
        final old = await db.query('customer_media_items',
            where: "item_id=? AND customer=? AND kind!='text'",
            whereArgs: [previous, row['customer']]);
        if (old.isEmpty) continue;
        if (!_compatibleProvenRows(old.single, roots.single)) continue;
        retiredReceipts.add(previous);
        aliases
            .addAll(jsonDecode(old.single['aliases_json']! as String) as List);
        if (old.single['message_id'] is String) {
          aliases.add(old.single['message_id']);
        }
        await db.update(
            'customer_media_items',
            {
              'canonical_id': rootId,
              'state': 'superseded',
              'identity_ambiguous': 0
            },
            where: 'item_id=? AND customer=?',
            whereArgs: [previous, row['customer']]);
        // Only the exact proven fork is retired, not other same-second cards.
        await db.update('media_card_observations', {'canonical_id': rootId},
            where: 'customer=? AND canonical_id=?',
            whereArgs: [row['customer'], previous]);
      }
      await db.update(
          'customer_media_items',
          {
            'aliases_json': jsonEncode(aliases.toList()),
            'identity_ambiguous': 0
          },
          where: "item_id=? AND customer=? AND kind!='text'",
          whereArgs: [rootId, row['customer']]);
      await reconcileProvenMediaAliases(customer: row['customer']! as String);
      final canonicalMessage = roots.single['message_id'] as String?;
      if (canonicalMessage != null) {
        await (await database.history).consolidateProvenMediaAliases(
            row['customer']! as String,
            canonicalMessageId: canonicalMessage,
            messageAliases: aliases.whereType<String>(),
            receiptAliases: retiredReceipts);
      }
      await database.inheritSessionBaseline(row['customer']! as String,
          ancestorIds: {
            'media-pending:$itemId',
            'media-pending:$rootId',
            if (row['message_id'] is String) row['message_id']! as String,
            ...aliases.whereType<String>(),
          },
          aliasIds: aliases.whereType<String>());
      final synchronized = (await db.query('customer_media_items',
              where: 'item_id=? AND customer=?',
              whereArgs: [rootId, row['customer']]))
          .single;
      if (kind == 'video' && synchronized['kind'] != 'video') {
        final applied = await db.transaction((txn) async {
          if (!await classificationAllowed(txn, rootId)) return false;
          final changed = await txn.update(
              'customer_media_items', {'kind': 'video', 'state': 'pending'},
              where: "item_id=? AND customer=? AND kind!='text'",
              whereArgs: [rootId, row['customer']]);
          return changed > 0 && await finishIn(txn, rootId);
        });
        if (!applied) return;
        final taskAliases = aliases.whereType<String>().toSet();
        final relevant =
            await _changesAffectCurrentTask(row['customer']! as String, [
          (
            aliases: taskAliases,
            senderAt: roots.single['sender_ms'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    roots.single['sender_ms']! as int)
          )
        ]);
        if (relevant) await _bump(row['customer']! as String);
        RuntimeTrace.record('media.card_type_corrected', {
          'customer': row['customer'],
          'mediaItemId': rootId,
          'previousKind': roots.single['kind'],
          'kind': 'video',
          'state': 'pending',
          'semanticRevisionPublished': relevant,
          'proof': 'verified_card_representation',
          'coverOnlyDraftInvalidated': relevant
        });
      }
    }

    final businessParent = _provenRoot(
        row,
        await db.query('customer_media_items',
            where: 'customer=?', whereArgs: [row['customer']]));
    final beforeCommit = beforeClassificationCommitForTesting;
    if (beforeCommit != null) await beforeCommit(itemId);
    if (businessParent?['admission_key'] != null &&
        businessParent?['message_id'] is String) {
      // The caller is processing an explicitly bound received occurrence.
      // Decoding, loading and changed crops can refine its type, never create
      // another business ID or retire a different admitted bubble by pixels.
      var parentId = businessParent!['item_id']! as String;
      Map<String, Object?>? classifiedParent;
      List<Map<String, Object?>> classifiedFamily = const [];
      final applied = await db.transaction((txn) async {
        final current = await txn.query('customer_media_items',
            where: 'customer=?', whereArgs: [row['customer']]);
        final source =
            current.where((item) => item['item_id'] == itemId).firstOrNull;
        if (source == null || source['kind'] == 'text') return false;
        final parent = _provenRoot(source, current);
        if (parent == null ||
            parent['kind'] == 'text' ||
            parent['admission_key'] == null ||
            parent['message_id'] is! String) {
          return false;
        }
        parentId = parent['item_id']! as String;
        final changed = await txn.rawUpdate("""UPDATE customer_media_items SET
        kind=CASE WHEN kind='video' THEN kind ELSE ? END,
        state=CASE WHEN ?='video' AND kind!='video' THEN 'preview' ELSE state END,
        visual_fingerprint=COALESCE(?,visual_fingerprint) WHERE item_id=? AND customer=? AND kind!='text'""",
            [kind, kind, fingerprint, parentId, row['customer']]);
        if (changed == 0 || !await finishIn(txn, parentId)) return false;
        classifiedParent = parent;
        classifiedFamily = current;
        return true;
      });
      if (!applied) return parentId;
      if (kind == 'video' && classifiedParent!['kind'] != 'video') {
        final relevant =
            await _changesAffectCurrentTask(row['customer']! as String, [
          (
            aliases: _receiptKeys(classifiedParent!, classifiedFamily),
            senderAt: classifiedParent!['sender_ms'] is int
                ? DateTime.fromMillisecondsSinceEpoch(
                    classifiedParent!['sender_ms']! as int)
                : null
          )
        ]);
        if (relevant) await _bump(row['customer']! as String);
      }
      return parentId;
    }
    if (priorObservation?['classified_ms'] != null &&
        priorObservation?['canonical_id'] is String) {
      final priorId = priorObservation!['canonical_id']! as String;
      final roots = await db.query('customer_media_items',
          where: 'item_id=? AND customer=? AND identity_ambiguous=0',
          whereArgs: [priorId, row['customer']]);
      if (roots.length == 1) {
        final rootId = (roots.single['canonical_id'] ?? priorId) as String;
        await bindProven(rootId);
        RuntimeTrace.record('media.card_representation_bound', {
          'customer': row['customer'],
          'mediaItemId': itemId,
          'canonicalReceiptId': rootId,
          'evidenceId': evidenceId,
          'proof': 'same_frozen_frame_card_rectangle',
          'newContextRevision': false
        });
        return finish(rootId);
      }
    }
    final proven =
        await _provenExistingCard(row, kind, previewBytes, evidenceId, region);
    if (proven != null) {
      await bindProven(proven.rootId, provenAliases: proven.provenIds);
      if (previewBytes != null &&
          !await MediaVisualMatcher.isLoadingCover(previewBytes)) {
        await db.update(
            'customer_media_items', {'visual_fingerprint': fingerprint},
            where: "item_id=? AND customer=? AND kind!='text'",
            whereArgs: [proven.rootId, row['customer']]);
      }
      RuntimeTrace.record('media.card_representation_bound', {
        'customer': row['customer'],
        'mediaItemId': itemId,
        'canonicalReceiptId': proven.rootId,
        'evidenceId': evidenceId,
        'proof': 'unique_card_geometry_and_pixel_correspondence',
        'newContextRevision': false
      });
      return finish(proven.rootId);
    }
    final previous = row['visual_fingerprint'] as String?;
    final distance = fingerprintDistance(previous, fingerprint);
    if (row['canonical_id'] is String &&
        (fingerprint == null ||
            previous == null ||
            distance == 0 ||
            (distance != null && distance <= 4))) {
      return finish(row['canonical_id']! as String);
    }
    if (previous != null &&
        fingerprint != null &&
        previous != fingerprint &&
        (distance == null || distance > 4)) {
      // Scrolling can change a same-second card's visible ordinal. Do not
      // upgrade a different thumbnail solely because its clock/slot matches.
      target = _hash([itemId, fingerprint]);
      final copy = {
        ...row,
        'item_id': target,
        'canonical_id': null,
        'first_seen_ms': row['last_seen_ms'],
        'kind': kind,
        'state': 'pending',
        'message_id': null,
        if (row.containsKey('admission_key')) 'admission_key': null,
        if (row.containsKey('admission_session_id'))
          'admission_session_id': null,
        if (row.containsKey('admitted_at_ms')) 'admitted_at_ms': null,
        'media_json': '[]',
        'aliases_json': '[]',
        'visual_fingerprint': fingerprint,
        'identity_ambiguous': 1
      };
      if (row['canonical_id'] == null && row['state'] != 'ready') {
        await db.rawUpdate(
            'UPDATE customer_media_items SET identity_ambiguous=1 WHERE item_id=?',
            [itemId]);
      }
      await db.insert('customer_media_items', copy,
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await database
          .inheritSessionBaseline(row['customer']! as String, ancestorIds: {
        'media-pending:$itemId',
        if (row['message_id'] is String) row['message_id']! as String,
        ...(jsonDecode(row['aliases_json']! as String) as List)
            .whereType<String>(),
      }, aliasIds: {
        'media-pending:$target'
      });
      RuntimeTrace.record('media.card_binding_ambiguous', {
        'customer': row['customer'],
        'mediaItemId': itemId,
        'retainedItemId': target,
        'reason': 'same_clock_slot_different_thumbnail',
        'exactCountSuppressed': true
      });
    }
    if (distance != null && distance > 0 && distance <= 4) {
      RuntimeTrace.record('media.thumbnail_render_changed', {
        'customer': row['customer'],
        'mediaItemId': itemId,
        'distanceBits': distance,
        'newCardCreated': false
      });
    }
    await db.transaction((txn) async {
      if (!await classificationAllowed(txn, target)) return;
      await txn.rawUpdate("""UPDATE customer_media_items SET
      kind=CASE WHEN kind='video' THEN kind ELSE ? END,
      state=CASE WHEN ?='video' AND kind!='video' THEN 'pending' WHEN state='ready' THEN state ELSE 'pending' END,
      visual_fingerprint=COALESCE(visual_fingerprint,?) WHERE item_id=? AND kind!='text'""",
          [kind, kind, fingerprint, target]);
      await finishIn(txn, target);
    });
    return target;
  }

  /// Bind only a loading/loaded revision whose immutable transcript prefix
  /// proves the same visible card. A clock or a low-information hash alone
  /// cannot supply this proof.
  Future<bool> _provenLoadingCard(Map<String, Object?> row, String kind,
      Uint8List bytes, String evidenceId, List<double> region,
      {bool requireLoading = true, bool verifiedSenderClock = false}) async {
    final session = database.currentAutomationSessionId;
    if (session == null || (requireLoading && row['sender_ms'] == null)) {
      return false;
    }
    final db = await database.database;
    Future<Map<String, dynamic>?> frame(String id) async {
      final stored = (await db.query('capture_evidence',
              where: 'id=? AND customer=?', whereArgs: [id, row['customer']]))
          .firstOrNull;
      if (stored == null) return null;
      final payload = Map<String, dynamic>.from(
          jsonDecode(stored['payload']! as String) as Map);
      return payload['automationSessionId'] == session ? payload : null;
    }

    final current = await frame(evidenceId);
    if (current == null || current['chatRegion'] is! Map) return false;
    final older = await db.query('media_card_observations',
        where:
            'customer=? AND canonical_id=? AND classified_kind=? AND evidence_id!=?',
        whereArgs: [row['customer'], row['item_id'], kind, evidenceId],
        orderBy: 'observed_ms DESC');
    if (older.isEmpty) return false;
    for (final prior in older.take(8)) {
      final previous = await frame(prior['evidence_id']! as String);
      if (previous == null ||
          previous['chatRegion'] is! Map ||
          (previous['capturedAtMs'] as num) >
              (current['capturedAtMs'] as num)) {
        continue;
      }
      final oldRegion = (jsonDecode(prior['region_json']! as String) as List)
          .map((v) => (v as num).toDouble())
          .toList();
      final chat = Map<String, dynamic>.from(current['chatRegion'] as Map);
      final oldChat = Map<String, dynamic>.from(previous['chatRegion'] as Map);
      for (final key in ['left', 'top', 'right', 'bottom']) {
        if (chat[key] != oldChat[key] || chat[key] is! num) return false;
      }
      final oldPath = prior['preview_path']?.toString();
      final oldFrame = previous['imagePath']?.toString();
      final newFrame = current['imagePath']?.toString();
      if (oldPath == null ||
          oldFrame == null ||
          newFrame == null ||
          !await File(oldPath).exists() ||
          !await File(oldFrame).exists() ||
          !await File(newFrame).exists()) {
        continue;
      }
      final cardArgs = (
        oldCard: await File(oldPath).readAsBytes(),
        oldFrame: await File(oldFrame).readAsBytes(),
        newFrame: await File(newFrame).readAsBytes(),
        transcript: [
          for (final key in ['left', 'top', 'right', 'bottom'])
            (chat[key] as num).toDouble()
        ]
      );
      if (requireLoading
          ? await MediaVisualMatcher.loadingCardTransition(
              previousCard: cardArgs.oldCard,
              currentCard: bytes,
              previousFrame: cardArgs.oldFrame,
              currentFrame: cardArgs.newFrame,
              previousRegion: oldRegion,
              currentRegion: region,
              transcript: cardArgs.transcript)
          : await MediaVisualMatcher.frozenCardContinuation(
              previousCard: cardArgs.oldCard,
              currentCard: bytes,
              previousFrame: cardArgs.oldFrame,
              currentFrame: cardArgs.newFrame,
              previousRegion: oldRegion,
              currentRegion: region,
              transcript: cardArgs.transcript,
              verifiedSenderClock: verifiedSenderClock)) {
        return true;
      }
    }
    return false;
  }

  Future<({String rootId, Set<String> provenIds})?> _provenExistingCard(
      Map<String, Object?> observation,
      String kind,
      Uint8List? bytes,
      String? evidenceId,
      List<double>? region) async {
    if (bytes == null ||
        evidenceId == null ||
        region == null ||
        region.length != 4) {
      return null;
    }
    final db = await database.database;
    final customer = observation['customer']! as String;
    final candidates = await db.query('customer_media_items',
        where: """customer=? AND canonical_id IS NULL
            AND state IN ('ready','pending','preview','awaiting_kind')
            AND (message_id IS NOT NULL OR item_id=?)
            AND kind IN ('video','image')
            AND ((sender_ms=? AND slot=?)
              OR (?=1 AND slot=?) OR EXISTS (
              SELECT 1 FROM media_card_observations AS observed
              WHERE observed.customer=customer_media_items.customer
                AND observed.canonical_id=customer_media_items.item_id
                AND observed.evidence_id=?))""",
        whereArgs: [
          customer,
          observation['item_id'],
          observation['sender_ms'] ?? -1,
          observation['slot'],
          observation['sender_ms'] == null ? 1 : 0,
          observation['slot'],
          evidenceId
        ]);
    final matches = <String>{};
    for (final candidate in candidates) {
      final observations = await db.query('media_card_observations',
          where: 'customer=? AND canonical_id=? AND classified_ms IS NOT NULL',
          whereArgs: [customer, candidate['item_id']],
          orderBy: 'observed_ms DESC');
      bool geometryProven(Map<String, Object?> old) {
        final r =
            (jsonDecode(old['region_json']! as String) as List).cast<num>();
        if (r.length != 4 ||
            region[2] <= 0 ||
            region[3] <= 0 ||
            r[2] <= 0 ||
            r[3] <= 0) {
          return false;
        }
        if (old['evidence_id'] == evidenceId) {
          final left = region[0] > r[0] ? region[0] : r[0];
          final top = region[1] > r[1] ? region[1] : r[1];
          final right = region[0] + region[2] < r[0] + r[2]
              ? region[0] + region[2]
              : r[0] + r[2];
          final bottom = region[1] + region[3] < r[1] + r[3]
              ? region[1] + region[3]
              : r[1] + r[3];
          final smaller = region[2] * region[3] < r[2] * r[3]
              ? region[2] * region[3]
              : r[2] * r[3];
          return right > left &&
              bottom > top &&
              (right - left) * (bottom - top) / smaller >= .90;
        }
        // A clock is only a candidate filter. Cross-frame binding additionally
        // needs the same card slot, consistent geometry and strict pixels.
        if ((observation['sender_ms'] != null &&
                candidate['sender_ms'] != observation['sender_ms']) ||
            candidate['slot'] != observation['slot']) {
          return false;
        }
        final widthRatio = region[2] / r[2], heightRatio = region[3] / r[3];
        return widthRatio >= .50 &&
            widthRatio <= 2.0 &&
            heightRatio >= .65 &&
            heightRatio <= 1.50 &&
            (region[0] - r[0]).abs() <= .04;
      }

      // The loading cover has no visual identity. Require the same card's
      // moving transcript context before treating its loaded pixels as an
      // upgrade. This also recovers a clipped/headerless video representation.
      final candidateKind = candidate['kind']! as String;
      if (await _provenLoadingCard(
          candidate, candidateKind, bytes, evidenceId, region,
          requireLoading: true)) {
        matches.add(candidate['item_id']! as String);
        continue;
      }
      if (observation['sender_ms'] == null ||
          candidate['sender_ms'] == null ||
          candidateKind != kind) {
        if (await _provenLoadingCard(
            candidate, candidateKind, bytes, evidenceId, region,
            requireLoading: false,
            verifiedSenderClock: candidate['sender_ms'] != null &&
                candidate['sender_ms'] == observation['sender_ms'] &&
                candidate['slot'] == observation['slot'])) {
          matches.add(candidate['item_id']! as String);
        }
        continue;
      }
      if (!observations.any(geometryProven)) continue;
      // The actual frozen card cover is the primary comparison. Decoded
      // video samples can show an unrelated part of the same clip, and must
      // never exhaust the comparison budget before its saved cover is read.
      final media = _payload(candidate);
      final paths = <String>{
        ...observations
            .where(geometryProven)
            .map((o) => o['preview_path'])
            .whereType<String>()
            .take(4),
        ...media
            .where((m) =>
                m['type'] == 'image' &&
                m['capture_source'] != 'jd_video_frame_1fps')
            .map((m) => m['path'])
            .whereType<String>()
            .take(4),
        ...media
            .where((m) => m['capture_source'] == 'jd_video_frame_1fps')
            .map((m) => m['path'])
            .whereType<String>()
            .take(4),
      };
      for (final path in paths) {
        final file = File(path);
        if (!await file.exists()) continue;
        final score = await MediaVisualMatcher.correspondenceScore(
            bytes, await file.readAsBytes(),
            ignorePlayOverlay: kind == 'video');
        if (score != null && score <= .018) {
          matches.add(candidate['item_id']! as String);
          break;
        }
      }
    }
    if (matches.isEmpty) return null;
    final proven = candidates
        .where((candidate) => matches.contains(candidate['item_id']))
        .toList();
    // Several local forks can carry the exact same original. They converge
    // only within this known sender-clock/card occurrence, with concrete
    // geometry and pixels above; equal file content at another clock/slot is
    // still another customer message.
    if (!_compatibleFamily(proven)) return null;
    proven.sort((a, b) {
      final order =
          (a['first_seen_ms']! as int).compareTo(b['first_seen_ms']! as int);
      return order != 0
          ? order
          : (a['item_id']! as String).compareTo(b['item_id']! as String);
    });
    return (rootId: proven.first['item_id']! as String, provenIds: matches);
  }

  Future<void> rejectCandidate(String itemId) async {
    await (await database.database).rawUpdate(
        "UPDATE customer_media_items SET state='rejected' WHERE item_id=? AND canonical_id IS NULL AND message_id IS NULL AND state NOT IN ('ready','preview')",
        [itemId]);
  }

  static int? fingerprintDistance(String? a, String? b) {
    if (a == null || b == null || a.length != 16 || b.length != 16) return null;
    final x = BigInt.tryParse(a, radix: 16), y = BigInt.tryParse(b, radix: 16);
    if (x == null || y == null) return null;
    var v = x ^ y, n = 0;
    while (v > BigInt.zero) {
      n += (v & BigInt.one).toInt();
      v = v >> 1;
    }
    return n;
  }

  /// Only one frozen, sender-owned card may authorize a cache representation.
  /// No clock-only matching across frames or different card slots.
  Future<String?> uniqueObservedReceipt(
      {required String customer,
      required String evidenceId,
      required DateTime? senderAt,
      bool nativePinnedOwner = false}) async {
    if (senderAt == null) return null;
    final rows = await (await database.database).query('customer_media_items',
        where:
            "customer=? AND (evidence_id=? OR (?=1 AND evidence_id IS NOT NULL)) AND sender_ms=? AND state!='rejected' AND identity_ambiguous=0",
        whereArgs: [
          customer,
          evidenceId,
          nativePinnedOwner ? 1 : 0,
          senderAt.millisecondsSinceEpoch
        ]);
    final roots = rows.map((r) => r['canonical_id'] ?? r['item_id']).toSet();
    return roots.length == 1 ? rows.first['item_id'] as String : null;
  }

  Future<String?> bodyState(
      {required String customer,
      required String evidenceId,
      required DateTime? senderAt}) async {
    final rows = await (await database.database).query('customer_media_items',
        where:
            "customer=? AND state!='rejected' AND (evidence_id=? OR (? IS NOT NULL AND sender_ms=?))",
        whereArgs: [
          customer,
          evidenceId,
          senderAt?.millisecondsSinceEpoch,
          senderAt?.millisecondsSinceEpoch
        ]);
    if (rows.isEmpty) return null;
    if (rows.any((r) => r['state'] == 'ready' || r['state'] == 'superseded')) {
      return 'media_available';
    }
    if (rows.any((r) => r['state'] == 'failed')) {
      return 'media_acquisition_failed';
    }
    return 'media_pending';
  }

  Future<int> revision(String customer) async {
    final row = await (await database.database).query('customer_media_versions',
        where: 'customer=?', whereArgs: [customer]);
    return row.isEmpty ? 0 : row.single['revision']! as int;
  }

  static Set<String> _messageKeys(Map message) => {
        if (message['id'] is String) message['id'] as String,
        ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
        if (message['media_receipt_id'] is String)
          message['media_receipt_id'] as String,
      };

  /// Follow only explicit receipt links. Clocks, screenshot age and matching
  /// file names never establish that two customers' cards are the same card.
  static Set<String> _receiptKeys(
      Map<String, Object?> row, List<Map<String, Object?>> rows) {
    String? rootOf(Map<String, Object?> candidate) {
      final visited = <String>{};
      var current = candidate;
      while (visited.add(current['item_id']! as String)) {
        final next = current['canonical_id'];
        if (next == null) return current['item_id']! as String;
        final linked = rows.where((r) => r['item_id'] == next).firstOrNull;
        if (linked == null) return null;
        current = linked;
      }
      return null;
    }

    final root = rootOf(row);
    if (root == null) return {};
    return {
      for (final candidate in rows.where((r) => rootOf(r) == root)) ...{
        candidate['item_id']! as String,
        'media-pending:${candidate['item_id']}',
        if (candidate['message_id'] is String)
          candidate['message_id']! as String,
        ...(jsonDecode(candidate['aliases_json']?.toString() ?? '[]') as List)
            .whereType<String>(),
      }
    };
  }

  /// Acquisition is a separate duty from answering a receipt/clarification.
  /// An answered placeholder stays here until its exact card is ready or the
  /// frozen message has actually been delegated to a human.
  Future<List<Map<String, Object?>>> pendingMediaForTask(
      String customer) async {
    final db = await database.database;
    final rows = database.currentBusinessDayKey == null
        ? await db.query('customer_media_items',
            where: 'customer=?',
            whereArgs: [customer],
            orderBy: 'first_seen_ms')
        : await _hotRows(customer, executor: db);
    final session = database.currentAutomationSessionId;
    final retiredImages =
        await database.retiredIncompleteImageMessageIds(customer, executor: db);
    final current = session == null
        ? null
        : await database.processingMessages(customer, includeAnswered: true);
    final keys = current
        ?.where((m) =>
            m['direction'] == 'incoming' &&
            m['capture_purpose'] != 'history_only' &&
            m['reply_work_state'] != 'delegated')
        .expand(_messageKeys)
        .toSet();
    final run = session == null
        ? await db.query('media_inventory_run', where: 'id=1')
        : const <Map<String, Object?>>[];
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      if (row['canonical_id'] != null ||
          !const {'video', 'image', 'unknown'}.contains(row['kind']) ||
          const {'rejected', 'superseded'}.contains(row['state'])) {
        continue;
      }
      if (row['state'] == 'ready') {
        final family = rows.where(
            (item) => _provenRoot(item, rows)?['item_id'] == row['item_id']);
        final media =
            ConversationFileStore.mergeProvenMediaPayloads(family.map(_payload))
                .media;
        if (await analysisFilesPresent(row['kind']! as String, media)) continue;
      }
      final aliases = _receiptKeys(row, rows);
      if (aliases.intersection(retiredImages).isNotEmpty) continue;
      if (keys != null) {
        if (keys.intersection(aliases).isEmpty) continue;
      } else if (row['state'] == 'historical' ||
          (run.isNotEmpty &&
              (row['first_seen_ms']! as int) <
                  (run.single['started_ms']! as int))) {
        continue;
      }
      final firstSeen = DateTime.fromMillisecondsSinceEpoch(
          row['first_seen_ms']! as int,
          isUtc: true);
      result.add({
        'receiptId': row['item_id'],
        'kind': row['kind'],
        'messageId': row['message_id'],
        'aliases': aliases.toList(),
        'firstSeen': firstSeen,
        'firstSeenAt': firstSeen,
        'senderAt': row['sender_ms'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['sender_ms']! as int,
                isUtc: true),
        'evidenceId': row['evidence_id'],
        'identityAmbiguous': row['identity_ambiguous'] == 1,
      });
    }
    return result;
  }

  /// A cover-only answer does not complete acquisition of this run's real
  /// video. Keep its frozen card in the acquisition window until ready; old
  /// historical or ambiguous observations cannot reopen that window.
  Future<DateTime?> acquisitionFloor(String customer) async {
    if (database.currentAutomationSessionId != null) {
      final pending = await pendingMediaForTask(customer);
      final times = pending
          .map((r) => (r['senderAt'] ?? r['firstSeenAt'])! as DateTime)
          .toList()
        ..sort();
      return times.firstOrNull;
    }
    final db = await database.database;
    final run = await db.query('media_inventory_run', where: 'id=1');
    if (run.isEmpty) return null;
    final rows = await db.query('customer_media_items',
        where:
            "customer=? AND canonical_id IS NULL AND kind='video' AND state IN ('detected','pending','preview') AND identity_ambiguous=0",
        whereArgs: [customer]);
    if (rows.isEmpty) return null;
    final pending = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id=?',
        whereArgs: [customer]);
    final drafts = await db.query('generated_drafts',
        columns: ['batch_end_message_id'],
        where: 'user_id=?',
        whereArgs: [customer]);
    final ends = {
      ...pending.map((r) => r['newest_message_id']),
      ...drafts.map((r) => r['batch_end_message_id'])
    }.whereType<String>().toSet();
    final document = await (await database.history).read(customer);
    final messages =
        await database.processingMessages(customer, document: document);
    final answered = await database.answeredMessageId(customer);
    final cursor = messages.indexWhere((m) => m['id'] == answered);
    final endIndexes = messages
        .asMap()
        .entries
        .where((e) => ends.contains(e.value['id']))
        .map((e) => e.key)
        .toList()
      ..sort();
    final last = endIndexes.isEmpty ? -1 : endIndexes.last;
    final liveTaskAliases = messages
        .asMap()
        .entries
        .where((e) =>
            e.key > cursor &&
            e.key <= last &&
            e.value['direction'] == 'incoming' &&
            e.value['capture_purpose'] != 'history_only')
        .expand((e) => <Object?>[
              e.value['id'],
              ...(e.value['observed_ids'] as List? ?? const [])
            ])
        .toSet();
    final times = rows
        .where((row) {
          if (database.currentAutomationSessionId != null) {
            final aliases = <Object?>{
              row['message_id'],
              ...(jsonDecode(row['aliases_json']! as String) as List)
            };
            return aliases.intersection(liveTaskAliases).isNotEmpty;
          }
          if ((row['first_seen_ms']! as int) >=
              (run.single['started_ms']! as int)) {
            return true;
          }
          final aliases = <Object?>{
            row['message_id'],
            ...(jsonDecode(row['aliases_json']! as String) as List)
          };
          return aliases.intersection(liveTaskAliases).isNotEmpty;
        })
        .map((r) => (r['sender_ms'] ?? r['first_seen_ms']) as int)
        .toList()
      ..sort();
    return times.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(times.first, isUtc: true);
  }

  Future<void> _invalidateScopedDeliveryContexts(String customer,
      {DatabaseExecutor? executor,
      Set<String> invalidatedInputs = const {}}) async {
    final db = executor ?? await database.database;
    final current = await analyzableEvidenceKeys(customer, executor: db);
    final attempts = await db.query('delivery_attempts',
        columns: ['attempt_id', 'raw_json'],
        where: "user_id=? AND state='sending'",
        whereArgs: [customer]);
    for (final attempt in attempts) {
      final encoded = attempt['raw_json'];
      if (encoded is! String) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(encoded);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final dependencies = decoded['reply_media_dependency_keys'];
      if (dependencies is! Map || dependencies.isEmpty) continue;
      if (dependencies.entries.any((entry) =>
          invalidatedInputs.contains(entry.key) ||
          (current[entry.key] ?? '') != entry.value)) {
        // A task token is monotonic: a later reappearance of the old assets
        // must not make an already invalidated insertion safe again.
        await DeliveryContextGuard.publishScoped(await database.storageRoot,
            customer, attempt['attempt_id']! as String, 2);
      }
    }
  }

  Future<void> _bump(String customer,
      {Set<String> invalidatedInputs = const {}}) async {
    final db = await database.database;
    final root = await database.storageRoot;
    await db.transaction((txn) async {
      await _invalidateScopedDeliveryContexts(customer,
          executor: txn, invalidatedInputs: invalidatedInputs);
      final row = await txn.query('customer_media_versions',
          where: 'customer=?', whereArgs: [customer]);
      final next = (row.isEmpty ? 0 : row.single['revision']! as int) + 1;
      await DeliveryContextGuard.publish(root, customer, next);
      await txn.rawInsert(
          'INSERT INTO customer_media_versions(customer,revision) VALUES(?,?) ON CONFLICT(customer) DO UPDATE SET revision=excluded.revision',
          [customer, next]);
    });
  }

  /// A matching clock/slot is a locator, not proof that two thumbnails are
  /// one card. Explicit receipt/alias linkage or a matching visual signature
  /// is required before one representation may hide another.
  static bool _sameCardAssociation(
      Map<String, Object?> a, Map<String, Object?> b) {
    if (a['customer'] != b['customer'] || _differentSenderSeconds(a, b)) {
      return false;
    }
    Set<String> aliases(Map<String, Object?> row) => {
          if (row['message_id'] is String) row['message_id']! as String,
          ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
              .whereType<String>(),
        };
    final admittedA = a['admission_key'] != null;
    final admittedB = b['admission_key'] != null;
    if (admittedA && admittedB) {
      // The same sender-second is indexed upstream. Asset comparison must
      // not independently authorize another business-record relationship.
      return a['admission_key'] == b['admission_key'] &&
          a['admission_session_id'] == b['admission_session_id'];
    }
    final explicit = a['item_id'] == b['item_id'] ||
        a['canonical_id'] == b['item_id'] ||
        b['canonical_id'] == a['item_id'] ||
        aliases(a).intersection(aliases(b)).isNotEmpty;
    if (explicit) return true;
    // An unadmitted observation may attach by an existing parent/alias proof,
    // but a fingerprint can never grant it another admission's identity.
    if (admittedA || admittedB) return false;
    if (a['identity_ambiguous'] == 1 || b['identity_ambiguous'] == 1) {
      return false;
    }
    final distance = fingerprintDistance(
        a['visual_fingerprint'] as String?, b['visual_fingerprint'] as String?);
    return distance != null && distance <= 4;
  }

  /// Only actual changes in the current task's media context publish a new
  /// guard revision. Backfill still persists originals and can upgrade the
  /// current preview through its aliases, without retiring unrelated answers.
  Future<bool> _changesAffectCurrentTask(String customer,
      List<({Set<String> aliases, DateTime? senderAt})> changes) async {
    final db = await database.database;
    if (database.currentAutomationSessionId != null) {
      final pending = await db.query('pending_customers',
          where: 'user_id=?', whereArgs: [customer]);
      final drafts = await db
          .query('generated_drafts', where: 'user_id=?', whereArgs: [customer]);
      if (pending.isEmpty && drafts.isEmpty) return false;
      final task = await _currentTaskMessages(customer);
      final keys = task.expand(_messageKeys).toSet();
      for (final draft in drafts) {
        final encoded = draft['raw_json'];
        if (encoded is! String) continue;
        final Object? raw;
        try {
          raw = jsonDecode(encoded);
        } on FormatException {
          continue;
        }
        if (raw is! Map) continue;
        final dependencies = raw['reply_media_dependency_keys'];
        if (dependencies is Map) {
          keys.addAll(dependencies.keys.whereType<String>());
        }
      }
      final changed = changes.expand((c) => c.aliases).toSet();
      if (keys.intersection(changed).isNotEmpty) return true;
      final rows = await db.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      return rows.where((r) => r['canonical_id'] == null).any((r) {
        final aliases = _receiptKeys(r, rows);
        return aliases.intersection(keys).isNotEmpty &&
            aliases.intersection(changed).isNotEmpty;
      });
    }
    final pending = await db.query('pending_customers',
        columns: ['newest_message_id'],
        where: 'user_id=?',
        whereArgs: [customer]);
    final drafts = await db.query('generated_drafts',
        columns: ['batch_end_message_id'],
        where: 'user_id=?',
        whereArgs: [customer]);
    final ends = {
      ...pending.map((r) => r['newest_message_id']),
      ...drafts.map((r) => r['batch_end_message_id'])
    }.whereType<String>().toSet();
    if (ends.isEmpty) return false;
    if (changes.any((c) => c.aliases.intersection(ends).isNotEmpty)) {
      return true;
    }
    final document = await (await database.history).read(customer);
    final messages =
        await database.processingMessages(customer, document: document);
    final boundaries = messages.where((m) => ends.contains(m['id'])).toList();
    final times = boundaries
        .map((m) =>
            DateTime.tryParse(m['sent_at']?.toString() ?? '') ??
            (m['capture_purpose'] == 'history_only'
                ? null
                : DateTime.tryParse(m['captured_at']?.toString() ?? '')))
        .whereType<DateTime>()
        .toList();
    if (times.isEmpty) return false;
    final before = times.reduce((a, b) => a.isAfter(b) ? a : b);
    final observations = boundaries
        .map((m) => DateTime.tryParse(m['captured_at']?.toString() ?? ''))
        .whereType<DateTime>()
        .toList();
    final observedBefore = observations.isEmpty
        ? before
        : observations.reduce((a, b) => a.isAfter(b) ? a : b);
    final run = await db.query('media_inventory_run', where: 'id=1');
    final fallback = before.subtract(const Duration(minutes: 30));
    final start = run.isEmpty
        ? fallback.millisecondsSinceEpoch
        : run.single['started_ms']! as int;
    final rows = await db.query('customer_media_items',
        where:
            "customer=? AND canonical_id IS NULL AND kind!='unknown' AND state!='rejected'",
        whereArgs: [customer]);
    bool withinContext(Map<String, Object?> row, int floor) {
      final firstSeen = row['first_seen_ms']! as int;
      final time = (row['sender_ms'] ?? firstSeen) as int;
      return time >= floor - 999 &&
          time <= before.millisecondsSinceEpoch + 999 &&
          firstSeen <= observedBefore.millisecondsSinceEpoch;
    }

    var contextRows = rows.where((row) => withinContext(row, start)).toList();
    if (contextRows.isEmpty && run.isNotEmpty) {
      contextRows = rows
          .where((row) => withinContext(row, fallback.millisecondsSinceEpoch))
          .toList();
    }
    // Use the same sender/first-seen freeze as context(). A late original keeps
    // its proven preview's first-seen time, so an earlier, even unclocked card
    // can still invalidate the answer to a later question. A newly discovered
    // unrelated historical image cannot enter that frozen context retroactively.
    final changedAliases = changes.expand((c) => c.aliases).toSet();
    return contextRows.any((row) => {
          if (row['message_id'] is String) row['message_id']! as String,
          ...(jsonDecode(row['aliases_json']?.toString() ?? '[]') as List)
              .whereType<String>()
        }.intersection(changedAliases).isNotEmpty);
  }

  /// A verified original message is canonical; UI thumbnails are observations.
  /// Ownership remains the native capture pipeline's responsibility. Clock-only
  /// history bootstrap cannot consume an unrelated pending preview.
  Future<List<String>> persist(CapturedConversation? capture,
      {bool verifiedAnchor = false,
      bool notify = true,
      bool currentTaskOnly = false}) async {
    if (capture == null) return [];
    final customer = capture.customerExternalId ?? capture.customerName;
    await reconcileProvenMediaAliases(customer: customer);
    final upgraded = <String>{};
    var changed = false;
    final changes = <({Set<String> aliases, DateTime? senderAt})>[];
    final db = await database.database;
    Future<Map<String, Object?>?>? acceptedImageDocument;
    for (final message in capture.messages) {
      if (message.direction != 'incoming') continue;
      final rows = await db.query('customer_media_items',
          where: 'customer=?', whereArgs: [customer]);
      final requested = message.mediaReceiptId ??
          (message.stableId.startsWith('media-pending:')
              ? message.stableId.substring('media-pending:'.length)
              : _hash([customer, 'history', message.stableId]));
      final old = rows.where((r) => r['item_id'] == requested).firstOrNull;
      var bound = old;
      final visited = <String>{};
      while (bound?['canonical_id'] != null &&
          visited.add(bound!['item_id']! as String)) {
        final next = bound['canonical_id'];
        bound = rows.where((r) => r['item_id'] == next).firstOrNull;
      }
      if (bound?['canonical_id'] != null) bound = null;
      if (bound?['kind'] == 'text') continue;
      final sessionMode = database.currentAutomationSessionId != null;
      if (sessionMode && bound?['message_id'] == null) {
        // Keep acquired files/phase progress on the observation. Only the DB's
        // explicit live-arrival admission may assign a business message ID.
        // A cache hit or a headerless backfill is never that admission proof.
        if (bound != null && message.media.isNotEmpty) {
          final family = rows
              .where(
                  (r) => _provenRoot(r, rows)?['item_id'] == bound!['item_id'])
              .toList();
          final merged = ConversationFileStore.mergeProvenMediaPayloads(
              [...family.map(_payload), message.media.map((m) => m.toJson())]);
          final phase = _payloadState(merged.media, bound['kind']! as String);
          await db.update(
              'customer_media_items',
              {
                'kind': phase.kind,
                'state': phase.state,
                'media_json': jsonEncode(merged.media)
              },
              where: 'customer=? AND item_id=?',
              whereArgs: [customer, bound['item_id']]);
        }
        continue;
      }
      if (message.media.isEmpty) {
        // This is a received card awaiting files, not an invented file
        // attachment. Only an existing receipt owned by this customer binds it.
        if (message.stableId != 'media-pending:$requested' ||
            bound == null ||
            !const {'video', 'image', 'unknown'}.contains(bound['kind']) ||
            bound['state'] == 'rejected') {
          continue;
        }
        final aliases = <String>{
          ...(jsonDecode(bound['aliases_json']! as String) as List)
              .whereType<String>(),
          message.stableId,
        };
        final canonicalMessageId = bound['message_id'] ?? message.stableId;
        final representationChanged = bound['message_id'] !=
                canonicalMessageId ||
            aliases.length !=
                (jsonDecode(bound['aliases_json']! as String) as List).length;
        await db.update(
            'customer_media_items',
            {
              'message_id': canonicalMessageId,
              'aliases_json': jsonEncode(aliases.toList()),
            },
            where: 'customer=? AND item_id=?',
            whereArgs: [customer, bound['item_id']]);
        if (representationChanged) {
          changed = true;
          changes.add((aliases: aliases, senderAt: message.sentAt));
        }
        if (bound['state'] == 'ready' &&
            canonicalMessageId != message.stableId) {
          upgraded.add(message.stableId);
        }
        continue;
      }
      final video = message.media.any((m) => m.type == 'video');
      final frames = message.media
          .where((m) => m.captureSource == 'jd_video_frame_1fps')
          .length;
      final isPreview = message.media.any((m) => const {
            'jd_video_preview',
            'jd_video_cover',
            'verified_media_preview'
          }.contains(m.captureSource));
      final kind =
          video || old?['kind'] == 'video' || isPreview ? 'video' : 'image';
      final ready = video
          ? frames > 0
          : kind == 'image' &&
              message.media.any((m) => m.type == 'image' && !m.isPartial);
      // Reverse-order arrival: a reread thumbnail cannot downgrade an
      // already verified original from the same customer/clock/card slot.
      if (!ready &&
          kind == 'video' &&
          verifiedAnchor &&
          old != null &&
          message.sentAt != null) {
        final originals = rows
            .where((r) =>
                r['kind'] == 'video' &&
                r['state'] == 'ready' &&
                r['canonical_id'] == null &&
                r['sender_ms'] == message.sentAt!.millisecondsSinceEpoch &&
                r['slot'] == old['slot'] &&
                _sameCardAssociation(r, old))
            .toList();
        if (originals.length == 1) {
          final original = originals.single;
          final aliases = <String>{
            message.stableId,
            ...(jsonDecode(original['aliases_json']! as String) as List)
                .cast<String>(),
            ...(jsonDecode(old['aliases_json']! as String) as List)
                .cast<String>()
          };
          await db.transaction((txn) async {
            await txn.update('customer_media_items',
                {'aliases_json': jsonEncode(aliases.toList())},
                where: 'item_id=? AND customer=?',
                whereArgs: [original['item_id'], customer]);
            if (old['item_id'] != original['item_id']) {
              await txn.update('customer_media_items',
                  {'state': 'superseded', 'canonical_id': original['item_id']},
                  where: 'item_id=? AND customer=?',
                  whereArgs: [old['item_id'], customer]);
            }
          });
          upgraded.add(message.stableId);
          RuntimeTrace.record('media.late_preview_bound', {
            'customer': customer,
            'messageId': message.stableId,
            'canonicalMessageId': original['message_id'],
            'slot': old['slot'],
            'proof': 'verified_receipt_alias_or_visual_association',
            'readyPreserved': true
          });
          continue;
        }
      }
      final sameMessage =
          rows.where((r) => r['message_id'] == message.stableId).toList();
      final placeholder = <Map<String, Object?>>[
        if (bound != null) bound,
        ...sameMessage.where((r) => r['canonical_id'] == null)
      ]
          .where((r) =>
              r['message_id']?.toString().startsWith('media-pending:') == true)
          .firstOrNull;
      final knownBoundAliases = bound == null
          ? const <String>{}
          : <String>{
              if (bound['message_id'] is String) bound['message_id']! as String,
              ...(jsonDecode(bound['aliases_json']?.toString() ?? '[]') as List)
                  .whereType<String>(),
            };
      // A recycled anchor cannot fuse a second independently verified video
      // with a ready original. Durable pending business IDs and actual known
      // source aliases retain their existing identity; a new original source
      // at a non-placeholder root keeps the original distinct-source contract.
      final explicitBound = sessionMode && bound?['message_id'] is String
          ? bound
          : old?['canonical_id'] != null &&
                  (!video ||
                      !ready ||
                      bound?['message_id']
                              ?.toString()
                              .startsWith('media-pending:') ==
                          true ||
                      knownBoundAliases.contains(message.stableId))
              ? bound
              : null;
      final canonicalMessageId = explicitBound?['message_id'] as String? ??
          placeholder?['message_id'] as String? ??
          message.stableId;
      // Existing canonical proof preserves the business ID even when its
      // original arrives through a child whose target is not ready yet.
      final canonical = explicitBound?['item_id'] as String? ??
          placeholder?['item_id'] as String? ??
          (video && ready
              ? _hash([customer, 'original', message.stableId])
              : (sameMessage
                      .where((r) => r['canonical_id'] == null)
                      .firstOrNull?['item_id'] as String? ??
                  requested));
      final established =
          rows.where((r) => r['item_id'] == canonical).firstOrNull;
      final establishedAliases = established == null
          ? const <String>{}
          : (jsonDecode(established['aliases_json']! as String) as List)
              .whereType<String>()
              .toSet();
      final aliases = <String>{message.stableId, canonicalMessageId};
      final consumed = <Map<String, Object?>>[
        ...sameMessage,
        if (explicitBound != null)
          ...rows.where((r) => _provenRoot(r, rows)?['item_id'] == canonical),
        if (established != null && !sameMessage.contains(established))
          established,
      ];
      if (video &&
          ready &&
          old != null &&
          old['canonical_id'] == null &&
          (old['state'] != 'ready' ||
              (verifiedAnchor &&
                  old['kind'] == 'image' &&
                  old['identity_ambiguous'] == 0))) {
        consumed.add(old);
      }
      if (old != null &&
          old['message_id'] == message.stableId &&
          !consumed.contains(old)) {
        consumed.add(old);
      }
      if (video && ready) {
        final clock = message.sentAt?.millisecondsSinceEpoch;
        final slot = old?['slot'];
        final group = rows
            .where((r) =>
                clock != null &&
                r['sender_ms'] == clock &&
                (slot == null || r['slot'] == slot))
            .toList();
        final otherOriginals = group
            .where((r) =>
                r['kind'] == 'video' &&
                r['state'] == 'ready' &&
                r['message_id'] != message.stableId &&
                r['canonical_id'] == null)
            .toList();
        final explicitSameReceipt = old != null &&
            (old['state'] != 'ready' ||
                (verifiedAnchor &&
                    old['kind'] == 'image' &&
                    old['identity_ambiguous'] == 0)) &&
            old['canonical_id'] == null;
        final mayBindRelated = verifiedAnchor &&
            old != null &&
            clock != null &&
            slot != null &&
            otherOriginals.isEmpty;
        for (final row in group) {
          final pendingVideo = row['kind'] == 'video' &&
              row['state'] != 'ready' &&
              row['state'] != 'superseded';
          if (pendingVideo &&
              ((explicitSameReceipt && row['item_id'] == requested) ||
                  (mayBindRelated && _sameCardAssociation(row, old)))) {
            if (!consumed.contains(row)) consumed.add(row);
          }
        }
      } else if (old != null &&
          old['canonical_id'] == null &&
          old['state'] != 'ready') {
        if (!consumed.contains(old)) consumed.add(old);
      }
      for (final row in consumed) {
        aliases.addAll((jsonDecode(row['aliases_json']! as String) as List)
            .cast<String>());
        if (video &&
            ready &&
            row['message_id'] != message.stableId &&
            !canonicalMessageId.startsWith('media-pending:')) {
          upgraded.addAll((jsonDecode(row['aliases_json']! as String) as List)
              .cast<String>()
              .where((id) =>
                  id != canonicalMessageId &&
                  !establishedAliases.contains(id)));
        }
      }
      // The image-upgrade owner may already have promoted clearer pending
      // pixels in the same file record. Equal-quality partials otherwise keep
      // the first old crop forever. Follow only that exact accepted primary,
      // never a new receipt, an uncommitted crop, video material or an answered
      // question. Old files remain in the history's material alternates.
      List<Map> acceptedImage = const [];
      if (verifiedAnchor &&
          sessionMode &&
          bound?['message_id'] == message.stableId &&
          bound?['kind'] == 'image' &&
          message.media.length == 1 &&
          message.media.single.type == 'image' &&
          message.media.single.isPartial &&
          !message.media.single.isLoadingPreview &&
          !const {
            'verified_media_preview',
            'jd_video_preview',
            'jd_video_cover',
            'jd_video_frame_1fps'
          }.contains(message.media.single.captureSource) &&
          established != null &&
          _payload(established).isNotEmpty &&
          _payload(established).every((media) =>
              media['type'] == 'image' && media['is_partial'] == true) &&
          !_payload(established)
              .any((media) => media['path'] == message.media.single.path) &&
          !await database.isMessageFormallyAnswered(
              customer, message.stableId)) {
        acceptedImageDocument ??= (await database.history).read(customer);
        final document = await acceptedImageDocument;
        final accepted = (document?['messages'] as List? ?? const [])
            .whereType<Map>()
            .where((row) =>
                row['id'] == message.stableId && row['direction'] == 'incoming')
            .firstOrNull;
        final primary =
            (accepted?['media'] as List? ?? const []).whereType<Map>().toList();
        if (primary.length == 1 &&
            primary.single['type'] == 'image' &&
            primary.single['path'] == message.media.single.path &&
            ConversationFileStore.materialInputKey({'media': primary}) ==
                ConversationFileStore.materialInputKey({
                  'media': message.media.map((media) => media.toJson()).toList()
                })) {
          acceptedImage = primary;
        }
      }
      final merged = ConversationFileStore.mergeProvenMediaPayloads([
        if (acceptedImage.isNotEmpty) acceptedImage,
        if (established != null) _payload(established),
        ...consumed.map(_payload),
        message.media.map((m) => m.toJson()),
      ]);
      final mergedState = _payloadState(merged.media, kind);
      final encoded = jsonEncode(merged.media);
      final inputChanged = established == null ||
          established['kind'] != mergedState.kind ||
          ConversationFileStore.materialInputKey({
                'media': _payload(established),
              }) !=
              ConversationFileStore.materialInputKey({'media': merged.media});
      changed |= inputChanged;
      if (inputChanged) {
        changes.add((aliases: aliases, senderAt: message.sentAt));
      }
      final firstSeen = [
        capture.capturedAt.millisecondsSinceEpoch,
        ...consumed.map((r) => r['first_seen_ms']! as int)
      ]..sort();
      final persisted = await db.transaction((txn) async {
        final current = (await txn.query('customer_media_items',
                columns: ['kind'],
                where: 'customer=? AND item_id=?',
                whereArgs: [customer, canonical]))
            .firstOrNull;
        if (current?['kind'] == 'text') return false;
        await txn.rawInsert(
            """INSERT INTO customer_media_items
          (item_id,customer,sender_ms,slot,kind,state,first_seen_ms,last_seen_ms,message_id,media_json,aliases_json,canonical_id,identity_ambiguous,visual_fingerprint)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL,?,?) ON CONFLICT(item_id) DO UPDATE SET
          kind=excluded.kind,state=excluded.state,message_id=excluded.message_id,media_json=excluded.media_json,
          aliases_json=excluded.aliases_json,canonical_id=NULL,identity_ambiguous=excluded.identity_ambiguous,
          visual_fingerprint=COALESCE(customer_media_items.visual_fingerprint,excluded.visual_fingerprint)""",
            [
              canonical,
              customer,
              message.sentAt?.millisecondsSinceEpoch,
              old?['slot'] ?? 0,
              mergedState.kind,
              mergedState.state,
              firstSeen.first,
              capture.capturedAt.millisecondsSinceEpoch,
              canonicalMessageId,
              encoded,
              jsonEncode(aliases.toList()),
              video && ready && verifiedAnchor
                  ? 0
                  : old?['identity_ambiguous'] ?? 0,
              old?['visual_fingerprint'] ?? established?['visual_fingerprint'],
            ]);
        for (final row in consumed) {
          if (row['item_id'] == canonical) continue;
          await txn.update('customer_media_items',
              {'state': 'superseded', 'canonical_id': canonical},
              where: 'item_id=? AND customer=?',
              whereArgs: [row['item_id'], customer]);
        }
        for (final previous in {
          requested,
          ...consumed.map((r) => r['item_id']).whereType<String>()
        }) {
          await txn.update(
              'media_card_observations', {'canonical_id': canonical},
              where: 'customer=? AND canonical_id=?',
              whereArgs: [customer, previous]);
        }
        return true;
      });
      if (!persisted) continue;
      RuntimeTrace.record('media.item_revision', {
        'customer': customer,
        'mediaItemId': canonical,
        'kind': mergedState.kind,
        'state': mergedState.state,
        'messageId': message.stableId,
        'aliases': aliases.toList(),
        'frameCount': merged.media
            .where((m) => m['capture_source'] == 'jd_video_frame_1fps')
            .length,
        'supersededReceipts': consumed
            .where((r) => r['item_id'] != canonical)
            .map((r) => r['item_id'])
            .toList(),
        'binding': video && ready
            ? 'verified_original_message_and_owned_anchor'
            : 'observed_representation'
      });
    }
    if (changed && notify) {
      // Exact native send guards remain correct even when this acquisition
      // only enriches a referenced historical card, outside current inputs.
      await _invalidateScopedDeliveryContexts(customer);
      if (!currentTaskOnly ||
          await _changesAffectCurrentTask(customer, changes)) {
        await _bump(customer);
      } else {
        RuntimeTrace.record('media.revision_notification_deferred', {
          'customer': customer,
          'reason': 'history_outside_current_task',
          'changedMessageIds':
              changes.expand((c) => c.aliases).toSet().toList(),
          'originalsPersisted': true,
        });
      }
    }
    return upgraded.toList();
  }

  /// Repair exact duplicate originals from v22 without claiming any unresolved
  /// cache file belongs to a customer. History supplies already-owned media.
  Future<void> repairKnownOriginals(String customer,
      {required DateTime before}) async {
    final document = await (await database.history).read(customer);
    for (final m
        in (document?['messages'] as List? ?? const []).whereType<Map>()) {
      if (m['direction'] != 'incoming' ||
          !(m['media'] as List? ?? const [])
              .whereType<Map>()
              .any((a) => a['type'] == 'video')) {
        continue;
      }
      final clock = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (clock == null ||
          clock.isAfter(before) ||
          clock.isBefore(before.subtract(const Duration(minutes: 30)))) {
        continue;
      }
      final known = await (await database.database).query(
          'customer_media_items',
          where: 'customer=? AND message_id=? AND canonical_id IS NULL',
          whereArgs: [customer, m['id']]);
      final canonical = _hash([customer, 'original', m['id']]);
      if (known.length == 1 && known.single['item_id'] == canonical) continue;
      await persist(
          CapturedConversation(
              stableKey: customer,
              customerName: customer,
              customerExternalId: customer,
              capturedAt:
                  DateTime.tryParse(m['captured_at']?.toString() ?? '') ??
                      DateTime.now(),
              messages: [
                CapturedMessage(
                    stableId: m['id']! as String,
                    direction: 'incoming',
                    body: m['body']?.toString() ?? '',
                    axPath: 'owned_history',
                    sentAt: DateTime.tryParse(m['sent_at']?.toString() ?? ''),
                    mediaReceiptId: m['media_receipt_id'] as String?,
                    media: (m['media'] as List)
                        .whereType<Map<Object?, Object?>>()
                        .map(CapturedMedia.fromMap)
                        .toList())
              ]),
          notify: false);
    }
  }

  Future<Duration> previewWait(
      String customer, String messageId, DateTime now) async {
    // A pending original is represented honestly in the answer and retained
    // for acquisition. Its age must neither block nor expire this business.
    if (database.currentAutomationSessionId != null) return Duration.zero;
    final document = await (await database.history).read(customer);
    final messages =
        await database.processingMessages(customer, document: document);
    final end = messages.indexWhere((m) => m['id'] == messageId);
    final answered = await database.answeredMessageId(customer);
    final cursor = messages.indexWhere((m) => m['id'] == answered);
    for (final row in await (await database.database).query(
        'customer_media_items',
        where:
            "customer=? AND kind='video' AND state NOT IN ('ready','superseded')",
        whereArgs: [customer])) {
      final aliases = jsonDecode(row['aliases_json']! as String) as List;
      final inBatch = end >= 0 &&
          messages.asMap().entries.any((e) =>
              e.key > cursor &&
              e.key <= end &&
              aliases.contains(e.value['id']));
      if (!aliases.contains(messageId) && !inBatch) continue;
      final until =
          DateTime.fromMillisecondsSinceEpoch(row['first_seen_ms']! as int)
              .add(const Duration(seconds: 8));
      if (until.isAfter(now)) return until.difference(now);
    }
    return Duration.zero;
  }

  Future<List<Map<String, dynamic>>> _currentTaskMessages(String customer,
      {String? messageId}) async {
    final db = await database.database;
    final pending = await db
        .query('pending_customers', where: 'user_id=?', whereArgs: [customer]);
    final drafts = await db
        .query('generated_drafts', where: 'user_id=?', whereArgs: [customer]);
    final owners = <String>{
      ...pending.map((r) => r['generation_token']).whereType<String>(),
      ...drafts.map((r) => r['task_id']).whereType<String>(),
      if (messageId != null) 'unleased:$messageId',
    };
    final frozen = owners.isEmpty
        ? const <Map<String, Object?>>[]
        : await db.query('automation_reply_inputs',
            where:
                'session_id=? AND user_id=? AND owner_id IN (${List.filled(owners.length, '?').join(',')})',
            whereArgs: [
                database.currentAutomationSessionId,
                customer,
                ...owners
              ]);
    final current = await database.processingMessages(customer);
    if (frozen.isEmpty) return current;
    final result = <Map<String, dynamic>>[];
    for (final input in frozen) {
      final encoded = input['message_json']?.toString();
      final message = encoded == null
          ? current
              .where((m) => _messageKeys(m).contains(input['message_id']))
              .firstOrNull
          : Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      if (message != null) result.add(message);
    }
    return result;
  }

  Future<Map<String, Object?>?> pendingVideoForTask(
      String customer, String messageId) async {
    if (database.currentAutomationSessionId != null) {
      final task = await _currentTaskMessages(customer, messageId: messageId);
      final keys = task.expand(_messageKeys).toSet();
      if (!keys.contains(messageId)) return null;
      return (await pendingMediaForTask(customer))
          .where((r) =>
              r['kind'] == 'video' &&
              (r['aliases']! as List<String>).any(keys.contains))
          .firstOrNull;
    }
    final document = await (await database.history).read(customer);
    final messages =
        await database.processingMessages(customer, document: document);
    final end = messages.indexWhere((m) => m['id'] == messageId);
    if (end < 0) return null;
    final answered = await database.answeredMessageId(customer);
    final cursor = messages.indexWhere((m) => m['id'] == answered);
    final aliasesInTask = messages
        .asMap()
        .entries
        .where((e) =>
            e.key > cursor &&
            e.key <= end &&
            e.value['direction'] == 'incoming' &&
            e.value['capture_purpose'] != 'history_only')
        .expand((e) => <Object?>[
              e.value['id'],
              ...(e.value['observed_ids'] as List? ?? const [])
            ])
        .toSet();
    final rows = await (await database.database).query('customer_media_items',
        where:
            "customer=? AND canonical_id IS NULL AND kind='video' AND state IN ('detected','pending','preview') AND identity_ambiguous=0",
        whereArgs: [customer],
        orderBy: 'first_seen_ms ASC');
    for (final row in rows) {
      final aliases = <Object?>{
        row['message_id'],
        ...(jsonDecode(row['aliases_json']! as String) as List)
      };
      if (aliases.intersection(aliasesInTask).isEmpty) continue;
      return {
        'receiptId': row['item_id'],
        'messageId': row['message_id'],
        'firstSeenAt':
            DateTime.fromMillisecondsSinceEpoch(row['first_seen_ms']! as int),
        'senderAt': row['sender_ms'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['sender_ms']! as int)
      };
    }
    return null;
  }

  Future<void> refineClock(
      String customer, String messageId, DateTime clock) async {
    final db = await database.database;
    for (final row in await db.query('customer_media_items',
        where: 'customer=?', whereArgs: [customer])) {
      if ((jsonDecode(row['aliases_json']! as String) as List)
          .contains(messageId)) {
        await db.update(
            'customer_media_items', {'sender_ms': clock.millisecondsSinceEpoch},
            where: 'item_id=? AND customer=?',
            whereArgs: [row['item_id'], customer]);
      }
    }
    RuntimeTrace.record('media.clock_refined', {
      'customer': customer,
      'messageId': messageId,
      'senderAt': clock.toUtc().toIso8601String(),
      'proof': 'canonical_message_anchor_clock_refinement'
    });
  }

  /// A canonical binding is stronger than its displayed clock or file hash.
  /// Ambiguous observations never authorize changing another bubble's ID.
  Future<String?> canonicalMessageId(String itemId,
      {required String customer}) async {
    final rows = await (await database.database).query('customer_media_items',
        where: 'customer=?', whereArgs: [customer]);
    var row = rows.where((r) => r['item_id'] == itemId).firstOrNull;
    final visited = <String>{};
    while (row != null && visited.add(row['item_id']! as String)) {
      if (row['identity_ambiguous'] == 1) return null;
      if (row['canonical_id'] == null) return row['message_id'] as String?;
      row = rows.where((r) => r['item_id'] == row!['canonical_id']).firstOrNull;
    }
    return null;
  }

  Future<String?> canonicalMessage(String customer, String messageId) async {
    for (final row in await (await database.database).query(
        'customer_media_items',
        where: "customer=? AND state='ready' AND canonical_id IS NULL",
        whereArgs: [customer])) {
      if ((jsonDecode(row['aliases_json']! as String) as List)
          .contains(messageId)) {
        return row['message_id'] as String?;
      }
    }
    return null;
  }

  /// History bootstrap is for existing installations/tests. Current-run card
  /// receipts remain authoritative for count, including unresolved originals.
  Future<List<Map<String, dynamic>>> context(String customer,
      {required List<Map<String, dynamic>> history,
      required DateTime before,
      DateTime? observedBefore,
      bool allowHistorical = true}) async {
    final daily = database.currentBusinessDayKey != null;
    if (daily) {
      history = history
          .where((message) => _messageInBusinessDay(customer, message))
          .toList();
    }
    final flowSession = database.currentAutomationSessionId != null;
    if (!flowSession) await repairKnownOriginals(customer, before: before);
    final db = await database.database;
    final run = await db.query('media_inventory_run', where: 'id=1');
    final start = run.isEmpty
        ? before.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch
        : run.single['started_ms']! as int;
    for (final m in history) {
      if (m['direction'] != 'incoming' ||
          (m['media'] as List? ?? const []).isEmpty) {
        continue;
      }
      final time = DateTime.tryParse(m['sent_at']?.toString() ?? '');
      if (!flowSession &&
          (time == null ||
              time.isBefore(before.subtract(const Duration(minutes: 30))) ||
              time.isAfter(before))) {
        continue;
      }
      final id = m['media_receipt_id']?.toString() ??
          _hash([customer, 'history', m['id']]);
      final exists = await db.query('customer_media_items',
          columns: ['item_id'],
          where: 'customer=? AND (item_id=? OR message_id=?)',
          whereArgs: [customer, id, m['id']]);
      if (exists.isNotEmpty) continue;
      await persist(
          CapturedConversation(
              stableKey: customer,
              customerName: customer,
              customerExternalId: customer,
              capturedAt:
                  DateTime.tryParse(m['captured_at']?.toString() ?? '') ??
                      time ??
                      before,
              messages: [
                CapturedMessage(
                    stableId: m['id']! as String,
                    direction: 'incoming',
                    body: m['body']?.toString() ?? '',
                    sentAt: time,
                    axPath: 'history',
                    mediaReceiptId: id,
                    media: (m['media'] as List)
                        .whereType<Map>()
                        .map((a) => CapturedMedia(
                            type: a['type']?.toString() ?? 'image',
                            path: a['path']?.toString() ?? '',
                            captureSource: a['capture_source']?.toString(),
                            isPartial: a['is_partial'] == true,
                            description: a['description']?.toString()))
                        .toList())
              ]),
          notify: false);
    }
    final dailyRows = daily ? await _hotRows(customer, executor: db) : null;
    var rows = dailyRows != null
        ? dailyRows
            .where((row) =>
                row['canonical_id'] == null &&
                row['kind'] != 'text' &&
                (flowSession || row['kind'] != 'unknown') &&
                row['state'] != 'rejected')
            .toList()
        : await db.query('customer_media_items',
            where: flowSession
                ? "customer=? AND canonical_id IS NULL AND kind!='text' AND state!='rejected'"
                : "customer=? AND canonical_id IS NULL AND kind NOT IN ('unknown','text') AND state!='rejected' AND (sender_ms>=? OR (sender_ms IS NULL AND first_seen_ms>=?)) AND COALESCE(sender_ms,first_seen_ms)<=? AND first_seen_ms<=?",
            whereArgs: flowSession
                ? [customer]
                : [
                    customer,
                    start - 999,
                    start,
                    before.millisecondsSinceEpoch + 999,
                    (observedBefore ?? before).millisecondsSinceEpoch
                  ],
            orderBy: 'COALESCE(sender_ms,first_seen_ms) ASC,slot ASC');
    if (daily) {
      rows.sort((a, b) {
        final order = (a['business_day_message_ms']! as int)
            .compareTo(b['business_day_message_ms']! as int);
        return order != 0
            ? order
            : (a['slot']! as int).compareTo(b['slot']! as int);
      });
    }
    final allRows = dailyRows ??
        (flowSession
            ? await db.query('customer_media_items',
                where: 'customer=?', whereArgs: [customer])
            : rows);
    final retiredImages =
        await database.retiredIncompleteImageMessageIds(customer, executor: db);
    rows = rows
        .where((row) =>
            _receiptKeys(row, allRows).intersection(retiredImages).isEmpty)
        .toList();
    if (flowSession) {
      final frozenKeys = history
          .where((m) => m['direction'] == 'incoming')
          .expand(_messageKeys)
          .toSet();
      Set<String>? currentKeys;
      if (!allowHistorical) {
        currentKeys =
            (await database.processingMessages(customer, includeAnswered: true))
                .where((m) =>
                    m['direction'] == 'incoming' &&
                    m['reply_work_state'] != 'delegated')
                .expand(_messageKeys)
                .toSet();
      }
      rows = rows.where((row) {
        final aliases = _receiptKeys(row, allRows);
        return aliases.intersection(frozenKeys).isNotEmpty &&
            (currentKeys == null ||
                aliases.intersection(currentKeys).isNotEmpty);
      }).toList();
    }
    if (!daily &&
        !flowSession &&
        rows.isEmpty &&
        run.isNotEmpty &&
        allowHistorical) {
      rows = await db.query('customer_media_items',
          where:
              "customer=? AND canonical_id IS NULL AND kind NOT IN ('unknown','text') AND state!='rejected' AND COALESCE(sender_ms,first_seen_ms)>=? AND COALESCE(sender_ms,first_seen_ms)<=? AND first_seen_ms<=?",
          whereArgs: [
            customer,
            before.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch,
            before.millisecondsSinceEpoch + 999,
            (observedBefore ?? before).millisecondsSinceEpoch
          ],
          orderBy: 'COALESCE(sender_ms,first_seen_ms),slot');
    }
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = row['message_id'] as String?;
      // Never leak a future batch: resolved files must occur in frozen history.
      final rowKeys = _receiptKeys(row, allRows);
      final frozen = flowSession
          ? history
              .where((m) =>
                  m['direction'] == 'incoming' &&
                  _messageKeys(m).intersection(rowKeys).isNotEmpty)
              .firstOrNull
          : id == null
              ? null
              : history.where((m) => m['id'] == id).firstOrNull;
      final available =
          frozen != null && const {'ready', 'preview'}.contains(row['state']);
      final media =
          available ? (frozen['media'] as List? ?? const []) : const [];
      final readable = <Map<String, dynamic>>[];
      for (final a in media.whereType<Map>()) {
        if (a['path'] is String &&
            await localFileReadableNonempty(a['path']! as String)) {
          readable.add(a.cast<String, dynamic>());
        }
      }
      final analysisAvailable = row['kind'] == 'video'
          ? readable.any((m) => m['capture_source'] == 'jd_video_frame_1fps')
          : readable.any((m) => m['type'] == 'image');
      final observation = await db.query('media_card_observations',
          columns: ['evidence_id'],
          where: 'customer=? AND (canonical_id=? OR item_id=?)',
          whereArgs: [customer, row['item_id'], row['item_id']],
          orderBy: 'observed_ms DESC',
          limit: 1);
      result.add({
        'mediaItemId': row['item_id'],
        'evidenceId':
            observation.firstOrNull?['evidence_id'] ?? row['evidence_id'],
        'kind': row['kind'],
        'state': row['state'] == 'ready' && !analysisAvailable
            ? 'awaiting_available_files'
            : row['state'],
        'analysisAvailable': analysisAvailable,
        'identityAmbiguous':
            row['identity_ambiguous'] == 1 || row['sender_ms'] == null,
        'receivedAt': DateTime.fromMillisecondsSinceEpoch(
                (row['admitted_at_ms'] ?? row['first_seen_ms'])! as int,
                isUtc: true)
            .toIso8601String(),
        'senderAt': DateTime.fromMillisecondsSinceEpoch(
                (row['business_day_message_ms'] ??
                    row['sender_ms'] ??
                    row['first_seen_ms'])! as int,
                isUtc: true)
            .toIso8601String(),
        'messageId': id,
        'messageAliases': jsonDecode(row['aliases_json']! as String),
        'availableMedia': readable,
        'detected': true,
        'clockIdentified': row['sender_ms'] != null,
        'originalVerified': available &&
            readable.any((a) =>
                a['type'] == 'video' ||
                (a['type'] == 'image' &&
                    a['is_partial'] != true &&
                    a['is_loading_preview'] != true &&
                    const {'jd_image_cache', 'jd-image-cache'}
                        .contains(a['capture_source'])))
      });
    }
    return result;
  }
}
