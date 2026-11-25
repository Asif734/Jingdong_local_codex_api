import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';

class JdV2PreparedPayload {
  const JdV2PreparedPayload({required this.request, required this.files});
  final Map<String, dynamic> request;
  final List<Map<String, String>> files;
}

/// Freezes source receipts without inventing timestamps or shortening questions.
class JdV2Payload {
  static Future<JdV2PreparedPayload> prepare({
    required String customer,
    required String historyVersion,
    required String idempotencyKey,
    required String instructions,
    required List<Map<String, dynamic>> messages,
    required Set<String> targetMessageIds,
    Set<String> referencedMediaIds = const {},
  }) async {
    if ([customer, historyVersion, idempotencyKey, instructions]
        .any((s) => s.trim().isEmpty)) {
      throw StateError('jd_v2_missing_request_identity_or_instructions');
    }
    if (utf8.encode(instructions).length > 16384) {
      throw StateError('jd_v2_instructions_too_large');
    }
    if (targetMessageIds.isEmpty || targetMessageIds.length > 100) {
      throw StateError('jd_v2_invalid_targets');
    }
    final byId = <String, Map<String, dynamic>>{};
    for (final source in messages) {
      final owner =
          source['customerUid'] ?? source['customer_id'] ?? source['user_id'];
      if (owner != null && owner != customer) {
        throw StateError('jd_v2_customer_mismatch');
      }
      final id = (source['id'] ?? source['stableId'])?.toString() ?? '';
      if (id.isEmpty || byId.containsKey(id)) {
        throw StateError('jd_v2_missing_or_duplicate_source_id');
      }
      byId[id] = source['reply_input_kind'] == 'text'
          ? {...source, 'media': <Object?>[]}
          : source;
    }
    for (final id in targetMessageIds) {
      if (!byId.containsKey(id) || _role(byId[id]!) != 'customer') {
        throw StateError('jd_v2_target_not_customer_in_request');
      }
    }
    // Keep every target, then fill remaining capacity with the newest context.
    final selectedIds = {...targetMessageIds};
    // Explicit local references need their owning historical event in the batch.
    for (final entry in byId.entries) {
      if ((entry.value['media'] as List? ?? const []).whereType<Map>().any(
              (m) => referencedMediaIds
                  .contains((m['id'] ?? m['media_id'])?.toString())) ||
          (entry.value['mediaIds'] as List? ?? const [])
              .any(referencedMediaIds.contains)) {
        selectedIds.add(entry.key);
      }
    }
    if (selectedIds.length > 100) {
      throw StateError('jd_v2_required_context_limit');
    }
    for (final id in byId.keys.toList().reversed) {
      if (selectedIds.length >= 100) break;
      selectedIds.add(id);
    }
    final events = <Map<String, dynamic>>[];
    final manifest = <Map<String, dynamic>>[];
    final files = <Map<String, String>>[];
    final uploaded = <String>{};
    final retained = {...referencedMediaIds};
    var totalBytes = 0;
    for (final entry
        in byId.entries.where((e) => selectedIds.contains(e.key))) {
      final id = entry.key;
      final source = entry.value;
      var text = (source['body'] ?? source['text'] ?? '').toString();
      if (text.length > 10000) {
        throw StateError('jd_v2_message_too_large');
      }
      final time = _sourceTime(source);
      if (time == null) throw StateError('jd_v2_missing_source_time');
      final mediaIds = <String>[];
      final media = (source['media'] as List? ?? const []).whereType<Map>();
      final target = targetMessageIds.contains(id);
      if (target ||
          media.any((m) => referencedMediaIds
              .contains((m['id'] ?? m['media_id'])?.toString())) ||
          (entry.value['mediaIds'] as List? ?? const [])
              .any(referencedMediaIds.contains)) {
        await _verifySamples(media);
      }
      final rawMediaIds =
          (source['mediaIds'] as List? ?? const []).whereType<String>();
      mediaIds.addAll(rawMediaIds.where(referencedMediaIds.contains));
      for (final raw in media) {
        final item = Map<String, dynamic>.from(raw);
        final localId = (item['id'] ?? item['media_id'])?.toString();
        final explicitlySelected =
            localId != null && referencedMediaIds.contains(localId);
        if (!target && !explicitlySelected && referencedMediaIds.isEmpty) {
          continue;
        }
        if (item['is_partial'] == true ||
            item['isPartial'] == true ||
            item['is_loading_preview'] == true ||
            item['isLoadingPreview'] == true) {
          // A local preview identifier was never retained by the hosted API.
          if (explicitlySelected) retained.remove(localId);
          // Never substitute a screenshot of a loading/partial preview.
          continue;
        }
        final path = _localPath(item['path']);
        final capture =
            (item['capture_source'] ?? item['captureSource'] ?? '').toString();
        final type = item['type']?.toString() ?? '';
        final frame =
            capture == 'jd_video_frame_1fps' || item['kind'] == 'frame';
        final image = capture == 'jd_image_cache' ||
            capture == 'jd-image-cache' ||
            item['kind'] == 'image' && item['complete'] == true;
        if (!frame && !image || type == 'video') {
          if (explicitlySelected) retained.remove(localId);
          continue;
        }
        if (path.isEmpty || !await File(path).exists()) {
          if (target || explicitlySelected) {
            throw StateError('jd_v2_media_missing');
          }
          continue;
        }
        final timestamp = frame ? await _frameTimestamp(item, path) : null;
        final file = File(path);
        final bytes = await file.length();
        if (bytes == 0 || bytes > 20 * 1024 * 1024) {
          if (!target && !explicitlySelected) continue;
          throw StateError('jd_v2_visual_size_limit');
        }
        final contentHash =
            (await sha256.bind(file.openRead()).first).toString();
        final mediaId = 'jd-${sha256.convert(utf8.encode(jsonEncode([
              id,
              contentHash,
              timestamp ?? (frame ? p.basename(path) : null)
            ])))}';
        if (!target &&
            !explicitlySelected &&
            !referencedMediaIds.contains(mediaId)) {
          continue;
        }
        if (referencedMediaIds.contains(mediaId)) {
          mediaIds.add(mediaId);
          continue;
        }
        if (explicitlySelected) {
          retained.remove(localId);
          mediaIds.remove(localId);
        }
        mediaIds.add(mediaId);
        if (!uploaded.add(mediaId)) continue;
        final mime = _mime(path);
        if (mime == null) throw StateError('jd_v2_unsupported_visual_format');
        totalBytes += bytes;
        if (files.length >= 50 || totalBytes > 50 * 1024 * 1024) {
          throw StateError('jd_v2_visual_batch_limit');
        }
        manifest.add({
          'id': mediaId,
          'messageId': id,
          'kind': frame ? 'frame' : 'image',
          if (timestamp != null) 'timestampMs': timestamp
        });
        files.add({'id': mediaId, 'path': path, 'mimeType': mime});
      }
      // A current visual receipt must have complete source images/samples.
      if (target &&
          (media.isNotEmpty || source['reply_input_kind'] == 'media') &&
          mediaIds.isEmpty) {
        throw StateError('jd_v2_media_not_ready');
      }
      // Speech is derived evidence attached to this receipt, never another
      // customer message or a replacement for the captured source text.
      if (target || mediaIds.isNotEmpty) {
        final speech = _verifiedTranscripts(media);
        if (speech.isNotEmpty) {
          text +=
              '\n\n[Derived media transcript: recognized attachment speech; '
              'not an original customer chat message]\n${speech.join('\n')}';
        }
      }
      if (text.length > 10000) throw StateError('jd_v2_message_too_large');
      events.add({
        'id': id,
        'role': _role(source),
        'text': text,
        'occurredAt': time.toUtc().toIso8601String(),
        'mediaIds': mediaIds.toSet().toList()
      });
    }
    final request = <String, dynamic>{
      'storeId': 'jd-grozziie',
      'customerUid': customer,
      'historyVersion': historyVersion,
      'idempotencyKey': idempotencyKey,
      'replyInstructions': instructions,
      'messages': events,
      'targetMessageIds':
          events.map((e) => e['id']).where(targetMessageIds.contains).toList(),
      'referencedMediaIds': retained.toList()..sort(),
      'media': manifest,
    };
    final requiredEventIds = <String>{
      ...targetMessageIds,
      for (final m in manifest) m['messageId'] as String,
      for (final event in events)
        if ((event['mediaIds'] as List).any(referencedMediaIds.contains))
          event['id'] as String,
    };
    // Context is optional; remove whole oldest events until the frozen request
    // fits. Questions and explicitly selected visuals are never shortened.
    while (utf8.encode(jsonEncode(request)).length > 200000) {
      final oldestOptional =
          events.indexWhere((e) => !requiredEventIds.contains(e['id']));
      if (oldestOptional < 0) throw StateError('jd_v2_request_too_large');
      final removed = events.removeAt(oldestOptional);
      final removedMedia = manifest
          .where((m) => m['messageId'] == removed['id'])
          .map((m) => m['id'])
          .toSet();
      manifest.removeWhere((m) => removedMedia.contains(m['id']));
      files.removeWhere((f) => removedMedia.contains(f['id']));
    }
    return JdV2PreparedPayload(request: request, files: files);
  }

  static List<String> _verifiedTranscripts(Iterable<Map> media) {
    final bracket = RegExp(
        r'\[(?:Video speech transcript|Speech transcript|语音转写|语音识别结果)(?:\s*\([^\]\r\n]*\))?\s*[:：]\s*[^\]]+\]',
        caseSensitive: false);
    return <String>{
      for (final item in media)
        if ((item['type'] == 'video' || item['type'] == 'audio') &&
            item['is_partial'] != true &&
            item['isPartial'] != true &&
            item['is_loading_preview'] != true &&
            item['isLoadingPreview'] != true)
          ...bracket
              .allMatches(item['description']?.toString() ?? '')
              .map((match) => match.group(0)!),
    }.toList();
  }

  static String _role(Map<String, dynamic> source) {
    if ((source['source'] ?? '').toString().contains('sla')) return 'notice';
    final role = source['role'] ?? source['direction'];
    return switch (role) {
      'incoming' || 'customer' => 'customer',
      'outgoing' || 'service' => 'service',
      _ => 'notice',
    };
  }

  static DateTime? _sourceTime(Map<String, dynamic> source) {
    final raw = source['sent_at'] ??
        source['occurredAt'] ??
        source['sentAt'] ??
        source['sentAtMs'];
    if (raw is DateTime) return raw;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    if (raw is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(raw)) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  static Future<void> _verifySamples(Iterable<Map> media) async {
    if (media.any((m) =>
        (m['capture_source'] == 'jd_video_frame_1fps' ||
            m['captureSource'] == 'jd_video_frame_1fps' ||
            m['kind'] == 'frame') &&
        (m['is_partial'] == true ||
            m['isPartial'] == true ||
            m['is_loading_preview'] == true ||
            m['isLoadingPreview'] == true))) {
      throw StateError('jd_v2_incomplete_video_samples');
    }
    final framePaths = media
        .where((m) =>
            m['capture_source'] == 'jd_video_frame_1fps' ||
            m['captureSource'] == 'jd_video_frame_1fps' ||
            m['kind'] == 'frame')
        .map((m) => _localPath(m['path']))
        .toSet();
    for (final directory in framePaths.map(p.dirname).toSet()) {
      final manifest = File(p.join(directory, 'sampling.json'));
      if (!await manifest.exists()) continue;
      final dynamic decoded;
      try {
        decoded = jsonDecode(await manifest.readAsString());
      } on FormatException {
        throw StateError('jd_v2_invalid_sampling_manifest');
      }
      if (decoded is! Map ||
          decoded['frames'] is! List ||
          decoded['fullRange'] == false) {
        throw StateError('jd_v2_incomplete_video_samples');
      }
      for (final frame in decoded['frames'] as List) {
        if (frame is! Map || frame['name'] is! String) {
          throw StateError('jd_v2_incomplete_video_samples');
        }
        final path = p.join(directory, frame['name'] as String);
        if (!framePaths.contains(path) ||
            !await File(path).exists() ||
            frame['bytes'] is num &&
                await File(path).length() != frame['bytes']) {
          throw StateError('jd_v2_incomplete_video_samples');
        }
      }
    }
  }

  static String _localPath(dynamic value) {
    final path = value?.toString() ?? '';
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'file') {
      try {
        return uri!.toFilePath();
      } on UnsupportedError {
        return '';
      }
    }
    return uri != null && uri.hasScheme ? '' : path;
  }

  static String? _mime(String path) =>
      switch (p.extension(path).toLowerCase()) {
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.webp' => 'image/webp',
        _ => null,
      };

  static Future<int?> _frameTimestamp(
      Map<String, dynamic> item, String path) async {
    int? valid(dynamic v) =>
        v is num && v.isFinite && v >= 0 ? v.round() : null;
    final direct = valid(item['timestampMs'] ?? item['timestamp_ms']);
    if (direct != null) return direct;
    final sampling = File(p.join(p.dirname(path), 'sampling.json'));
    if (await sampling.exists()) {
      try {
        final data = jsonDecode(await sampling.readAsString());
        for (final f
            in (data['frames'] as List? ?? const []).whereType<Map>()) {
          if (f['name'] == p.basename(path) || f['path'] == path) {
            final explicit = valid(f['timestampMs'] ?? f['timestamp_ms']);
            if (explicit != null) return explicit;
          }
        }
      } on FormatException {
        /* An absent timestamp is safer than an invented one. */
      }
    }
    final named = RegExp(r'(?:timestamp|time|t)[_-](\d+)ms(?:\.|_)')
        .firstMatch(p.basename(path));
    return named == null ? null : int.tryParse(named.group(1)!);
  }

  /// The immutable backend action is the sole automatic handoff trigger.
  static bool requestsTransfer(AiDraft draft) {
    try {
      final raw = jsonDecode(draft.rawJson);
      if (raw is! Map) return false;
      final receipt = raw['jd_v2'];
      if (receipt is! Map) return false;
      final reply = receipt['reply'];
      return reply is Map && reply['action'] == 'reply_then_transfer';
    } on FormatException {
      return false;
    }
  }

  /// Only reply_text is customer-facing; server reasoning stays in rawJson.
  static AiDraft toDraft(Map<String, dynamic> reply,
      {required Map<String, dynamic> receiptMetadata}) {
    const fields = [
      'action',
      'reply_text',
      'transfer_reason',
      'product_id',
      'product_query',
      'sku_label',
      'reason'
    ];
    final rawSeven = {for (final key in fields) key: reply[key]};
    final action = reply['action']?.toString().trim().toLowerCase() ?? '';
    final text =
        reply['reply_text'] is String ? reply['reply_text'] as String : '';
    final supported = const {
      'reply',
      'reply_text',
      'answer',
      'ask',
      'ask_clarification',
      'clarify'
    }.contains(action);
    final transfer = reply['action'] == 'reply_then_transfer';
    final review = !supported || text.trim().isEmpty;
    final trigger =
        transfer ? 'service_colleague_required' : 'jd_v2_unsupported_action';
    final actions = <String>[
      if (review) 'Operator review required for hosted action: $action',
      if (!supported &&
          !transfer &&
          (reply['product_id'] != null || reply['product_query'] != null))
        'Review the requested product action in the JD operator interface.',
    ];
    final raw = <String, dynamic>{
      ...rawSeven,
      'decision': review
          ? 'human_review_required'
          : (action.startsWith('ask') || action == 'clarify'
              ? 'ask_clarification'
              : 'draft'),
      'reply': text,
      'model': 'jd-hosted-v2',
      'confidence': supported && !review ? 1.0 : 0.0,
      'risk_level': review ? 'high' : 'low',
      'used_record_ids': <String>[],
      'actions': [
        for (final action in actions) {'description': action}
      ],
      'attachments': <Object?>[],
      'human_review_required': review,
      'risk_triggers': review ? [trigger] : <String>[],
      'jd_v2': {...receiptMetadata, 'reply': rawSeven},
    };
    return AiDraft(
        reply: text,
        decision: raw['decision'] as String,
        confidence: supported && !review ? 1 : 0,
        riskLevel: review ? 'high' : 'low',
        model: 'jd-hosted-v2',
        usedRecordIds: const [],
        actions: actions,
        attachments: const [],
        rawJson: jsonEncode(raw));
  }
}
