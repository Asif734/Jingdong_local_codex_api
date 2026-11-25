import '../capture/transcript_text.dart';
import '../capture/ocr_text_refinement.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import '../domain/reply_progress.dart';
import '../runtime/runtime_trace.dart';

class ConversationFileStore {
  /// Legacy all-history storage remains available for existing import tools
  /// and fixtures. The running service explicitly chooses [forDay].
  ConversationFileStore(this.rootDirectory, {DateTime Function()? clock})
      : _businessDay = null,
        _clock = clock ?? DateTime.now;

  /// A service run owns one JD calendar day. It never silently moves an old
  /// in-flight receipt into tomorrow's conversation when the clock changes.
  ConversationFileStore.forDay(this.rootDirectory,
      {required String businessDay, DateTime Function()? clock})
      : _businessDay = businessDay,
        _clock = clock ?? DateTime.now {
    final parsed = DateTime.tryParse('${businessDay}T00:00:00Z');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDay) ||
        parsed == null ||
        parsed.toIso8601String().substring(0, 10) != businessDay) {
      throw ArgumentError.value(businessDay, 'businessDay');
    }
  }

  static String businessDayFor(DateTime value) => value
      .toUtc()
      .add(const Duration(hours: 8))
      .toIso8601String()
      .substring(0, 10);

  final String? _businessDay;
  final DateTime Function() _clock;
  String? get businessDay => _businessDay;
  String get currentBusinessDay => _businessDay ?? businessDayFor(_clock());

  static Set<String> messageAliases(Map message) => {
        if (message['id'] is String) message['id']! as String,
        ...(message['observed_ids'] as List? ?? const []).whereType<String>(),
      };

  /// An actual time-bound customer utterance outranks a later empty visual
  /// guess. Pixel payloads and verified media evidence use their normal path.
  static bool isConfirmedCustomerText(Map message, {String? customer}) {
    if (message['direction'] != 'incoming' ||
        message['text_origin'] != 'customer_text' ||
        message['media_receipt_id'] != null ||
        (message['media'] as List? ?? const []).isNotEmpty ||
        (message['media_alternates'] as List? ?? const []).isNotEmpty ||
        message['body']?.toString().trim().isEmpty != false ||
        message['body'].toString().startsWith('[Customer sent')) {
      return false;
    }
    if (customer != null &&
        message['sender'] != null &&
        message['sender'] != customer) {
      return false;
    }
    final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    return at != null &&
        (customer == null ||
            message['customer_message_time_key'] == null ||
            message['customer_message_time_key'] ==
                CustomerMessageTime.incomingId(customer, at));
  }

  /// A clipped UI screenshot is a reversible representation, not an original
  /// customer attachment. The caller must separately prove its exact bubble.
  static bool isWeakScreenshotPayload(Map media) =>
      media['type'] == 'image' &&
      media['is_partial'] == true &&
      media['capture_source'] == 'verified_chat_viewport_fallback' &&
      media['is_loading_preview'] != true &&
      (media['media_roles'] as List? ?? const []).isEmpty;

  static String? incomingTimeKey(String customer, Map message) {
    if (message['direction'] != 'incoming') return null;
    final indexed = message['customer_message_time_key'];
    return indexed is String && CustomerMessageTime.isTimeId(indexed)
        ? indexed
        : CustomerMessageTime.forMessage(customer, message);
  }

  static bool _incomingTimeConflicts(
      String customer, Map existing, CapturedMessage observation) {
    if (observation.direction != 'incoming' || observation.sentAt == null) {
      return false;
    }
    final previous = incomingTimeKey(customer, existing);
    return previous != null &&
        previous !=
            CustomerMessageTime.incomingId(customer, observation.sentAt!);
  }

  static bool _atTime(String customer, Map message, String key) {
    if (message['direction'] != 'incoming') return false;
    final indexed = message['customer_message_time_key'];
    if (indexed is String) return indexed == key;
    final clock = CustomerMessageTime.forMessage(customer, message);
    return clock != null ? clock == key : messageAliases(message).contains(key);
  }

  Future<String?> incomingMessageIdAtTime(String customer, DateTime senderAt) =>
      _serialized(customer, () async {
        final document = await read(customer);
        final key = CustomerMessageTime.incomingId(customer, senderAt);
        return (document?['messages'] as List? ?? const [])
            .whereType<Map>()
            .where((message) => _atTime(customer, message, key))
            .firstOrNull?['id']
            ?.toString();
      });

  /// A clock refines the identity of the existing duty. It does not create a
  /// second message or replace an ID already used by a draft/native receipt.
  Future<String?> bindIncomingMessageTime(
          String customer, String messageId, DateTime senderAt) =>
      _serialized(customer, () async {
        if (_businessDay != null && businessDayFor(senderAt) != _businessDay) {
          return null;
        }
        final document = await read(customer);
        if (document == null) return null;
        final messages =
            (document['messages'] as List).cast<Map<String, Object?>>();
        final key = CustomerMessageTime.incomingId(customer, senderAt);
        final parent = messages
            .where((message) =>
                message['direction'] == 'incoming' &&
                messageAliases(message).contains(messageId))
            .firstOrNull;
        final canonical = parent ??
            messages.where((m) => _atTime(customer, m, key)).firstOrNull;
        if (canonical == null) return null;
        final old = incomingTimeKey(customer, canonical);
        if (old != null && old != key) {
          throw StateError('incoming_message_time_conflict');
        }
        canonical['sent_at'] =
            CustomerMessageTime.second(senderAt).toIso8601String();
        _mergeTimeRecords(customer, messages, canonical, key);
        await _write(document, customer);
        return canonical['id']! as String;
      });

  static bool _hasFormalReply(
      Iterable<Map> messages, Map incoming, Set<String> verifiedAnsweredIds) {
    final ids = messageAliases(incoming);
    if (ids.intersection(verifiedAnsweredIds).isNotEmpty) return true;
    return messages.any((reply) {
      if (reply['direction'] != 'outgoing' ||
          reply['source'] != 'generated_reply' ||
          reply['delivery_status'] != 'sent') {
        return false;
      }
      final raw = (reply['reply_metadata'] as Map?)?['raw_response'];
      if (raw is Map &&
          (raw['reply_purpose'] == 'media_status' ||
              raw['reply_purpose'] == 'review_status')) {
        return false;
      }
      final scope = raw is Map ? raw['formal_response_message_ids'] : null;
      return scope is List
          ? scope.any(ids.contains)
          : ids.contains(reply['answered_batch_end_id']);
    });
  }

  /// Time is the business key under the shop's one-customer/one-second
  /// contract. Legacy IDs remain aliases, so old draft and receipt ownership
  /// remains reviewable rather than being silently discarded.
  static void _mergeTimeRecords(
      String customer,
      List<Map<String, Object?>> messages,
      Map<String, Object?> canonical,
      String key) {
    final matching = messages
        .where((m) => _atTime(customer, m, key) || identical(m, canonical))
        .toList();
    canonical['customer_message_time_key'] = key;
    canonical['observed_ids'] = {
      key,
      for (final message in matching) ...messageAliases(message),
    }.where((id) => id != canonical['id']).toList();
    canonical['media_receipt_aliases'] = {
      for (final message in matching) ...{
        if (message['media_receipt_id'] is String)
          message['media_receipt_id']! as String,
        ...(message['media_receipt_aliases'] as List? ?? const [])
            .whereType<String>(),
      }
    }.toList();
    canonical['media_receipt_id'] ??=
        (canonical['media_receipt_aliases'] as List).firstOrNull;
    if (matching.length < 2) return;
    if (canonical['service_input_frozen'] == true) {
      messages
          .removeWhere((m) => !identical(m, canonical) && matching.contains(m));
      return;
    }
    final before =
        (canonical['media'] as List? ?? const []).whereType<Map>().toList();
    final merged = mergeProvenMediaPayloads([
      for (final message in matching)
        (message['media'] as List? ?? const []).whereType<Map>(),
      for (final message in matching)
        (message['media_alternates'] as List? ?? const []).whereType<Map>(),
    ]);
    canonical['media'] = merged.media;
    canonical['media_alternates'] = merged.alternates;
    if (materialInputKey({'media': before}) !=
        materialInputKey({'media': merged.media})) {
      canonical['service_evidence_revision'] =
          (canonical['service_evidence_revision'] as num? ?? 0).toInt() + 1;
    }
    bool substantive(Map message) =>
        (message['body']?.toString().trim() ?? '').isNotEmpty &&
        !(message['body']?.toString().startsWith('[Customer sent') ?? false);
    if (!substantive(canonical)) {
      final text = matching.where(substantive).firstOrNull;
      if (text != null) {
        canonical['body'] = text['body'];
        canonical['text_origin'] = text['text_origin'];
      }
    }
    for (final field in ['captured_at', 'activated_at']) {
      final dates = matching
          .map((m) => DateTime.tryParse(m[field]?.toString() ?? ''))
          .whereType<DateTime>()
          .toList()
        ..sort();
      if (dates.isNotEmpty) {
        canonical[field] = dates.first.toUtc().toIso8601String();
      }
    }
    canonical['live_observed_session_ids'] = {
      for (final message in matching)
        ...(message['live_observed_session_ids'] as List? ?? const [])
            .whereType<String>()
    }.toList();
    final duplicates = matching.where((m) => !identical(m, canonical)).toSet();
    canonical['time_observation_alternates'] = [
      ...(canonical['time_observation_alternates'] as List? ?? const []),
      ...duplicates
    ];
    messages.removeWhere(duplicates.contains);
  }

  /// Only customer input belongs in this key. Image descriptions, capture
  /// coordinates and presentation roles are outputs/locators of the same
  /// material; writing them cannot invalidate the generation that used it.
  static String materialInputKey(Map message) {
    final media = (message['media'] as List? ?? const []).whereType<Map>();
    final hasVideo = media.any((item) => item['type'] == 'video');
    final files = <String, List<Object?>>{};
    for (final item in media) {
      final type = item['type']?.toString() ?? '';
      final path = item['path']?.toString() ?? '';
      if (type.isEmpty || path.isEmpty) continue;
      // Once the original video and its timeline exist, recapturing its card
      // cover is presentation evidence, not a different customer input.
      if (hasVideo &&
          type == 'image' &&
          item['capture_source'] != 'jd_video_frame_1fps') {
        continue;
      }
      final description = item['description']?.toString() ?? '';
      final speech = type == 'audio' || type == 'video'
          ? (<String>{
              ...RegExp(
                      r'\[(?:Video speech transcript|Speech transcript)(?: \([^\]]*\))?:[^\]]*\]',
                      caseSensitive: false)
                  .allMatches(description)
                  .map((match) => match.group(0)!),
              for (final terminal in const [
                '[Video audio: no audio stream]',
                '[Video audio: an audio stream exists, but no meaningful audible content was detected]',
                '[Video audio: audible content exists, but no speech was recognized]',
              ])
                if (description.contains(terminal)) terminal,
            }.toList()
            ..sort())
          : <String>[];
      files['$type\u001f$path'] = [
        type,
        path,
        item['is_partial'] == true,
        item['is_loading_preview'] == true,
        item['type_verification'] == 'pending',
        speech.isEmpty ? null : speech,
      ];
    }
    final ordered = files.keys.toList()..sort();
    return sha256
        .convert(utf8.encode(jsonEncode([
          isClarifiedTextMessage(message)
              ? 'text'
              : files.isEmpty
                  ? 'text'
                  : 'media',
          files.isEmpty ? message['body']?.toString().trim() ?? '' : null,
          for (final key in ordered) files[key],
        ])))
        .toString();
  }

  static bool _previewMedia(Map media) =>
      media['is_partial'] == true ||
      media['is_loading_preview'] == true ||
      const {'jd_video_preview', 'verified_media_preview', 'jd_video_cover'}
          .contains(media['capture_source']);

  /// A physical file may serve several analysis roles (for example the
  /// decoded first frame is also the reconstructed cover). Source labels do
  /// not make it another customer message or another physical attachment.
  static Set<String> mediaRoles(Map media) => {
        ...(media['media_roles'] as List? ?? const []).whereType<String>(),
        if (media['type'] == 'video') 'video_original',
        if (media['type'] == 'audio') 'audio',
        if (media['capture_source'] == 'jd_video_frame_1fps') ...{
          'video_frame',
          if (media['original_name'] == 'video_frame_00s.jpg' ||
              RegExp(r'/frames_[^/]+_(?:t0_v2|full_v3)/frame_00\.jpg$')
                  .hasMatch(media['path']?.toString() ?? ''))
            'first_frame',
          if (media['original_name'] == 'video_frame_tail.jpg' ||
              RegExp(r'/frames_[^/]+_full_v3/frame_tail\.jpg$')
                  .hasMatch(media['path']?.toString() ?? ''))
            'last_frame',
        },
        if (const {
          'jd_video_cover',
          'verified_media_preview',
          'jd_video_preview'
        }.contains(media['capture_source']))
          'video_cover',
      };

  static String _mediaVariantKey(Map media) => jsonEncode([
        media['type'],
        media['path'],
        media['capture_source'],
        media['is_partial'] == true,
        media['is_loading_preview'] == true,
      ]);

  /// Quality within an already proven message identity. This does not prove
  /// that two files, clocks, customers or card slots are the same message.
  static int mediaPayloadQuality(Iterable<Map> payload) {
    final media = payload.toList();
    final frames = media
        .where((m) => m['capture_source'] == 'jd_video_frame_1fps')
        .map((m) => m['path'])
        .toSet()
        .length;
    if (media.any((m) => m['type'] == 'video')) {
      return 10000 +
          frames * 10 +
          (media.any((m) => m['type'] == 'audio') ? 1 : 0);
    }
    if (frames > 0) return 9000 + frames * 10;
    if (media.any((m) => const {
          'jd_video_preview',
          'verified_media_preview',
          'jd_video_cover'
        }.contains(m['capture_source']))) {
      return media.every((m) => m['is_loading_preview'] == true) ? 4000 : 5000;
    }
    if (media.any((m) =>
        m['type'] == 'image' &&
        !_previewMedia(m) &&
        m['capture_source'] != 'jd_video_frame_1fps')) {
      return 3000;
    }
    return media.isEmpty
        ? 0
        : media.every((m) => m['is_loading_preview'] == true)
            ? 100
            : 200;
  }

  /// Preserve all original/frame/audio paths from explicitly proven aliases.
  /// Superseded partial crops stay in alternates, so a late preview cannot
  /// replace a ready original or silently discard audio added after its frames.
  static ({
    List<Map<String, Object?>> media,
    List<Map<String, Object?>> alternates
  }) mergeProvenMediaPayloads(Iterable<Iterable<Map>> representations) {
    final files = <String, Map<String, Object?>>{};
    final semanticAlternates = <String, Map<String, Object?>>{};
    for (final payload in representations) {
      for (final raw in payload) {
        if (raw['path'] is! String || raw['type'] is! String) continue;
        final next = Map<String, Object?>.from(raw);
        final key = '${next['type']}\u001f${next['path']}';
        final previous = files[key];
        if (previous == null) {
          files[key] = next;
          continue;
        }
        final preferNext =
            mediaPayloadQuality([next]) > mediaPayloadQuality([previous]);
        if (_mediaVariantKey(previous) != _mediaVariantKey(next)) {
          // The same JPEG can first be an ordinary cached image, then a
          // verified video preview. Preserve both observations as evidence,
          // while keeping only the stronger interpretation active.
          final superseded = preferNext ? previous : next;
          final variant = _mediaVariantKey(superseded);
          final prior = semanticAlternates[variant];
          if (prior == null ||
              (superseded['description']?.toString().length ?? 0) >
                  (prior['description']?.toString().length ?? 0)) {
            semanticAlternates[variant] = superseded;
          }
        }
        final merged = <String, Object?>{...(preferNext ? next : previous)};
        final roles = {...mediaRoles(previous), ...mediaRoles(next)};
        if (roles.contains('video_cover') && roles.contains('video_frame') ||
            previous['media_roles'] is List ||
            next['media_roles'] is List) {
          merged['media_roles'] = roles.toList()..sort();
        }
        for (final entry in (preferNext ? previous : next).entries) {
          if (const {
            'capture_source',
            'is_partial',
            'is_loading_preview',
            'media_roles'
          }.contains(entry.key)) {
            continue;
          }
          if (entry.value != null &&
              (merged[entry.key] == null || merged[entry.key] == '')) {
            merged[entry.key] = entry.value;
          }
        }
        final oldDescription = previous['description']?.toString() ?? '';
        final newDescription = next['description']?.toString() ?? '';
        if (newDescription.length > oldDescription.length) {
          merged['description'] = newDescription;
        }
        files[key] = merged;
      }
    }
    final actualVideo = files.values.any((m) =>
        m['type'] == 'video' || m['capture_source'] == 'jd_video_frame_1fps');
    final explicitPreviews = files.values
        .where((m) => mediaRoles(m).contains('video_cover'))
        .toList();
    final originals = files.values
        .where((m) =>
            m['type'] == 'image' &&
            !_previewMedia(m) &&
            m['capture_source'] != 'jd_video_frame_1fps')
        .toList();
    final preferred = <Map<String, Object?>>[];
    if (actualVideo) {
      preferred.addAll(files.values.where((m) =>
          m['type'] == 'video' ||
          m['type'] == 'audio' ||
          m['capture_source'] == 'jd_video_frame_1fps'));
      // The real first-view cover is evidence from this same received video,
      // alongside motion samples. Preserve one loaded cover for analysis; a
      // gray/loading observation never displaces it or becomes another input.
      final covers = explicitPreviews
          .where((m) => m['type'] == 'image' && m['is_loading_preview'] != true)
          .toList()
        ..sort((a, b) => (b['capture_source'] == 'jd_video_cover' ? 1 : 0)
            .compareTo(a['capture_source'] == 'jd_video_cover' ? 1 : 0));
      if (covers.isNotEmpty && !preferred.contains(covers.first)) {
        preferred.add(covers.first);
      }
    } else if (explicitPreviews.isNotEmpty) {
      // An explicit play observation corrects an ordinary cache image that
      // was actually a video cover. Keep one best cover active; old gray cards
      // remain evidence in alternates rather than becoming extra attachments.
      final loaded =
          explicitPreviews.where((m) => m['is_loading_preview'] != true);
      preferred.add(loaded.firstOrNull ?? explicitPreviews.first);
    } else if (originals.isNotEmpty) {
      preferred.addAll(originals);
    } else if (files.isNotEmpty) {
      final candidates = files.values.toList()
        ..sort((a, b) =>
            mediaPayloadQuality([b]).compareTo(mediaPayloadQuality([a])));
      preferred.add(candidates.first);
    }
    preferred.addAll(files.values
        .where((m) => m['type'] == 'audio' && !preferred.contains(m)));
    final activeVariants = preferred.map(_mediaVariantKey).toSet();
    final alternates = <String, Map<String, Object?>>{};
    for (final media in [
      ...files.values.where((m) => !preferred.contains(m)),
      ...semanticAlternates.values,
    ]) {
      final key = _mediaVariantKey(media);
      if (!activeVariants.contains(key)) alternates[key] = media;
    }
    return (
      media: preferred,
      alternates: alternates.values.toList(),
    );
  }

  final Directory rootDirectory;
  static final Map<String, Future<void>> _writeTails = {};
  static final Map<String, Future<void>> _dailyInitializations = {};
  static final Map<String, Future<void>> _dayPreparations = {};
  static final Object _serializationOwner = Object();
  static int _temporarySequence = 0;

  String get _storageKey => p.normalize(p.absolute(rootDirectory.path));

  /// Warm the daily baseline once, before the service starts. Each old
  /// document is decoded once and reused for its daily copy. Original root
  /// documents, including their old delivery records, are never renamed or
  /// rewritten. Empty copies also prevent repeated whole-history reads.
  Future<void> prepareDay() async {
    await conversationsDirectory.create(recursive: true);
    if (_businessDay == null) return;
    final marker = File(p.join(conversationsDirectory.path, '.prepared-v1'));
    if (await marker.exists()) return;
    final key = '$_storageKey\u0000$_businessDay';
    final existing = _dayPreparations[key];
    if (existing != null) return existing;
    final preparation = _prepareDay(marker);
    _dayPreparations[key] = preparation;
    try {
      await preparation;
    } finally {
      if (identical(_dayPreparations[key], preparation)) {
        _dayPreparations.remove(key);
      }
    }
  }

  Future<void> _prepareDay(File marker) async {
    if (await marker.exists()) return;
    await for (final source in rootDirectory.list()) {
      if (source is! File || p.extension(source.path) != '.json') continue;
      Map<String, Object?> document;
      try {
        final decoded = jsonDecode(await source.readAsString());
        if (decoded is! Map<String, dynamic> ||
            decoded['user_id'] is! String ||
            decoded['messages'] is! List) {
          continue;
        }
        document = decoded.cast<String, Object?>();
      } on FormatException {
        // Normal per-customer reads still surface and isolate this damage.
        continue;
      }
      final customer = document['user_id']! as String;
      final names = {
        '${safeUserId(customer)}.json',
        '${_legacySafeUserId(customer)}.json',
      };
      if (customer.trim().isEmpty || !names.contains(p.basename(source.path))) {
        continue;
      }
      final canonicalName = '${safeUserId(customer)}.json';
      if (p.basename(source.path) != canonicalName &&
          await File(p.join(rootDirectory.path, canonicalName)).exists()) {
        continue;
      }
      await _ensureDailyInitialized(customer, sourceDocument: document);
    }
    await _atomicWrite(marker, _businessDay!);
  }

  Future<void> _ensureDailyInitialized(String userId,
      {Map<String, Object?>? sourceDocument}) async {
    final destination = _conversationFile(userId);
    if (await destination.exists()) return;
    final key = '$_storageKey\u0000$_businessDay\u0000$userId';
    final existing = _dailyInitializations[key];
    if (existing != null) return existing;
    final initialization = _initializeDaily(userId, sourceDocument);
    _dailyInitializations[key] = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_dailyInitializations[key], initialization)) {
        _dailyInitializations.remove(key);
      }
    }
  }

  Future<void> _initializeDaily(
      String userId, Map<String, Object?>? sourceDocument) async {
    final destination = _conversationFile(userId);
    if (await destination.exists()) return;
    final original =
        sourceDocument ?? await _readLegacy(userId, migrate: false);
    if (original == null) return;
    _verifyOwner(original, userId);
    final document = <String, Object?>{
      ...original,
      'history_business_day': _businessDay,
      'messages': [
        for (final message in (original['messages'] as List? ?? const []))
          if (message is Map && _messageDay(userId, message) == _businessDay)
            message,
      ],
    };
    await destination.parent.create(recursive: true);
    await _atomicWrite(
        destination, const JsonEncoder.withIndent('  ').convert(document));
  }

  String? _messageDay(String userId, Map message) {
    if (message['direction'] == 'outgoing') {
      // A click can finish after midnight. Its exact task binding owns the
      // history partition; the later confirmation clock grants no new-day
      // business and must not become tomorrow's assistant context.
      final boundary = _incomingTimeKeyAt(userId,
          message['answered_batch_end_id'] ?? message['sla_message_id']);
      if (boundary != null) return businessDayFor(boundary);
      final raw = (message['reply_metadata'] as Map?)?['raw_response'];
      if (raw is Map) {
        final days = {
          for (final id in (raw['service_message_ids'] as List? ?? const []))
            if (_incomingTimeKeyAt(userId, id) case final DateTime at)
              businessDayFor(at),
        };
        if (days.length == 1) return days.single;
      }
    }
    var at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    if (at == null) {
      final key = message['customer_message_time_key'] ?? message['id'];
      at = _incomingTimeKeyAt(userId, key);
    }
    if (at == null &&
        message['direction'] == 'incoming' &&
        message['capture_purpose'] == 'history_only') {
      // A backfill observation dates the screenshot, not the old utterance.
      // Its original evidence remains in the untouched all-history archive.
      return null;
    }
    at ??= DateTime.tryParse(message['captured_at']?.toString() ?? '');
    return at == null ? null : businessDayFor(at);
  }

  DateTime? _incomingTimeKeyAt(String userId, Object? value) {
    final prefix = 'incoming-time:${Uri.encodeComponent(userId)}:';
    return value is String && value.startsWith(prefix)
        ? DateTime.tryParse(value.substring(prefix.length))
        : null;
  }

  /// Hold only the short persistence/claim commit, never parsing or CLI work.
  /// All writers of this customer's file use the same serialization owner.
  Future<T> withCustomerSnapshot<T>(String userId,
          Future<T> Function(Map<String, Object?>? document) action) =>
      _serialized(userId, () async => action(await read(userId)));

  /// Caller must hold [withCustomerSnapshot]. Persist before exposing a claim
  /// so a retry or process restart cannot submit different bytes for this ID.
  Future<void> freezeIncomingSnapshot(
      String userId, Map<String, Object?> document, Set<String> ids) async {
    var changed = false;
    for (final message
        in (document['messages'] as List? ?? const []).whereType<Map>()) {
      if (message['direction'] == 'incoming' &&
          messageAliases(message).intersection(ids).isNotEmpty &&
          message['service_input_frozen'] != true) {
        message['service_input_frozen'] = true;
        changed = true;
      }
    }
    if (changed) await _write(document, userId);
  }

  Directory get conversationsDirectory => _businessDay == null
      ? rootDirectory
      : Directory(p.join(rootDirectory.path, 'daily_history', _businessDay));
  Directory get mediaDirectory =>
      Directory(p.join(rootDirectory.path, 'media'));

  Future<CaptureAppendResult> appendCapture(CapturedConversation capture,
      {bool historyOnly = false,
      Set<String>? activeIncomingIds,
      Set<String> formallyAnsweredIds = const {},
      Set<String> verifiedMediaReceiptIds = const {}}) {
    final userId = capture.customerExternalId ?? capture.customerName;
    return _serialized(userId, () async {
      final document = await _readOrCreate(
        userId: userId,
        displayName: capture.customerName,
        stableKey: capture.stableKey,
      );
      final messages =
          (document['messages'] as List<Object?>).cast<Map<String, Object?>>();
      final knownIds = messages
          .expand((item) =>
              [item['id'], ...(item['observed_ids'] as List<Object?>? ?? [])])
          .whereType<String>()
          .toSet();
      var inserted = 0;
      var metadataChanged = false;
      var stableIdRereads = 0;
      bool belongsToOtherTime(Map existing, CapturedMessage observation) =>
          _incomingTimeConflicts(userId, existing, observation);
      bool conflictingId(CapturedMessage observation) => messages.any((m) =>
          messageAliases(m).contains(observation.stableId) &&
          belongsToOtherTime(m, observation));
      bool conflictingReceipt(CapturedMessage observation) =>
          observation.mediaReceiptId != null &&
          messages.any((m) =>
              (m['media_receipt_id'] == observation.mediaReceiptId ||
                  (m['media_receipt_aliases'] as List? ?? const [])
                      .contains(observation.mediaReceiptId)) &&
              belongsToOtherTime(m, observation));
      final insertedIncomingIds = <String>[];
      final insertedOutgoingIds = <String>[];
      String? lastInsertedDirection;
      bool selectedIncoming(Map<String, Object?> record,
              [String? observationId]) =>
          !historyOnly &&
          (capture.automationSessionId == null ||
              incomingTimeKey(userId, record) != null ||
              record['media_receipt_id'] != null) &&
          (activeIncomingIds == null ||
              activeIncomingIds.contains(observationId) ||
              activeIncomingIds.contains(record['id']) ||
              (record['observed_ids'] as List? ?? const [])
                  .any(activeIncomingIds.contains));

      void observeSession(Map<String, Object?> record,
          [String? observationId]) {
        final session = capture.automationSessionId;
        if (session == null || record['direction'] != 'incoming') return;
        if (record['observed_session_id'] != session) {
          record['observed_session_id'] = session;
          metadataChanged = true;
        }
        if (selectedIncoming(record, observationId)) {
          final observed = <String>{
            ...(record['live_observed_session_ids'] as List? ?? const [])
                .whereType<String>(),
            session,
          };
          if ((record['live_observed_session_ids'] as List? ?? const [])
                  .length !=
              observed.length) {
            record['live_observed_session_ids'] = observed.toList();
            metadataChanged = true;
          }
        }
      }

      void advanceEvidence(Map<String, Object?> record) {
        record['service_evidence_revision'] =
            (record['service_evidence_revision'] as int? ?? 0) + 1;
        metadataChanged = true;
      }

      void refineIncomingText(
          Map<String, Object?> record, CapturedMessage observation) {
        if (record['direction'] != 'incoming' ||
            observation.direction != 'incoming' ||
            observation.media.isNotEmpty ||
            observation.mediaReceiptId != null ||
            _hasCapturedMedia(record) ||
            observation.body.trim().isEmpty ||
            _hasFormalReply(messages, record, formallyAnsweredIds)) {
          return;
        }
        final previous = record['body']?.toString() ?? '';
        if (!record.containsKey('text_source_evidence_id')) {
          // Legacy capture_evidence_id could refer to the latest frame while
          // observation_turn_key still names the first. That mixed pair is
          // not exact proof of the canonical text's immutable source.
          record['text_source_evidence_id'] = null;
          record['text_source_observation_turn_key'] = null;
          metadataChanged = true;
        }
        final change = OcrTextRefinement.classify(previous, observation.body);
        if (change == OcrTextChange.identical) return;
        final variants = (record['ocr_variants'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, Object?>.from(item))
            .toList();
        void retain(String body, String? evidenceId, Object? observedAt) {
          if (variants.any((item) => item['body'] == body)) return;
          variants.add({
            'body': body,
            'observed_at': observedAt,
            if (evidenceId != null) 'capture_evidence_id': evidenceId,
          });
        }

        retain(previous, record['capture_evidence_id'] as String?,
            record['last_observed_at'] ?? record['captured_at']);
        retain(observation.body, observation.captureEvidenceId,
            capture.capturedAt.toUtc().toIso8601String());
        record['ocr_variants'] = variants;
        metadataChanged = true;
        final latest = DateTime.tryParse(
            (record['last_observed_at'] ?? record['captured_at'])?.toString() ??
                '');
        // A delayed old frame may enrich aliases/evidence, never undo a newer
        // accepted reading or restart its already running generation.
        if (latest != null && capture.capturedAt.isBefore(latest)) return;
        if (change == OcrTextChange.equivalent) return;
        final sourceEvidence = record['text_source_evidence_id'];
        final sourceTurn = record['text_source_observation_turn_key'];
        final exactFrozenCorrection = sourceEvidence is String &&
            sourceEvidence.isNotEmpty &&
            sourceEvidence == observation.captureEvidenceId &&
            sourceTurn is String &&
            sourceTurn.startsWith('ocr-bubble:') &&
            sourceTurn == observation.observationTurnKey;
        if (!exactFrozenCorrection &&
            OcrTextRefinement.isViewportFragment(previous, observation.body)) {
          // Same-clock/content matching is only a locator. The later frame
          // may have lost the beginning/end as chat scrolled; keep the full
          // question and its ready/in-flight answer. Exact same immutable
          // pixels may still prove a genuine shorter OCR correction.
          return;
        }
        record['body'] = observation.body;
        record['text_source_evidence_id'] = observation.captureEvidenceId;
        record['text_source_observation_turn_key'] =
            observation.observationTurnKey;
        if (observation.sender != null) record['sender'] = observation.sender;
        if (observation.sentAt != null) {
          record['sent_at'] = observation.sentAt!.toUtc().toIso8601String();
        }
        advanceEvidence(record);
        // This changes the already registered input's version, not the count
        // of newly received business messages. Current-run ledger registration
        // still commits its material key even when append.changed stays zero.
      }

      bool pendingMedia(Map<String, Object?> record) =>
          record['id']?.toString().startsWith('media-pending:') == true;

      // Every successful deduplication path has the same activation contract:
      // a live observation promotes the canonical record without replacing its
      // durable ID (which may already be a queue or delivery cursor).
      void mergeObservation(
          Map<String, Object?> existing, CapturedMessage observation) {
        if (belongsToOtherTime(existing, observation)) return;
        if (existing['service_input_frozen'] == true) {
          observeSession(existing, observation.stableId);
          knownIds.add(observation.stableId);
          return;
        }
        final sameTime = observation.sentAt != null &&
            _atTime(userId, existing,
                CustomerMessageTime.incomingId(userId, observation.sentAt!));
        if (sameTime &&
            isConfirmedCustomerText(existing, customer: userId) &&
            observation.media.isEmpty &&
            observation.mediaReceiptId != null &&
            !verifiedMediaReceiptIds.contains(observation.mediaReceiptId)) {
          RuntimeTrace.record('capture.unknown_kind_ignored', {
            'customer': userId,
            'messageId': existing['id'],
            'receiptId': observation.mediaReceiptId,
            'reason': 'confirmed_customer_text_has_no_media_upgrade',
          });
          return;
        }
        if (isClarifiedTextMessage(existing) &&
            (observation.mediaReceiptId != null ||
                observation.media.isNotEmpty)) {
          // A native crop already in flight may finish after this empty
          // placeholder was proved to be prose. It cannot change its type back.
          return;
        }
        if (sameTime &&
            observation.media.isEmpty &&
            observation.mediaReceiptId == null &&
            observation.body.trim().isNotEmpty &&
            (existing['body']?.toString().startsWith('[Customer sent') ??
                false) &&
            !_hasFormalReply(messages, existing, formallyAnsweredIds)) {
          existing['body'] = observation.body;
          existing['text_origin'] = 'customer_text';
          if (observation.captureEvidenceId != null) {
            existing['text_source_evidence_id'] = observation.captureEvidenceId;
          }
          if (observation.observationTurnKey != null) {
            existing['text_source_observation_turn_key'] =
                observation.observationTurnKey;
          }
          advanceEvidence(existing);
        }
        refineIncomingText(existing, observation);
        final latestObserved = DateTime.tryParse(
            (existing['last_observed_at'] ?? existing['captured_at'])
                    ?.toString() ??
                '');
        if (latestObserved == null ||
            capture.capturedAt.isAfter(latestObserved)) {
          existing['last_observed_at'] =
              capture.capturedAt.toUtc().toIso8601String();
          metadataChanged = true;
        }
        observeSession(existing, observation.stableId);
        if (observation.captureEvidenceId != null &&
            existing['capture_evidence_id'] != observation.captureEvidenceId) {
          existing['capture_evidence_id'] = observation.captureEvidenceId;
          metadataChanged = true;
        }
        if (existing['id'] != observation.stableId &&
            !conflictingId(observation)) {
          final aliases = <Object?>{
            ...(existing['observed_ids'] as List? ?? []),
            observation.stableId
          };
          if ((existing['observed_ids'] as List? ?? []).length !=
              aliases.length) {
            existing['observed_ids'] = aliases.toList();
            metadataChanged = true;
          }
        }
        knownIds.add(observation.stableId);
        if (observation.mediaReceiptId != null &&
            !conflictingReceipt(observation)) {
          final receipts = <String>{
            if (existing['media_receipt_id'] is String)
              existing['media_receipt_id']! as String,
            ...(existing['media_receipt_aliases'] as List? ?? const [])
                .whereType<String>(),
            observation.mediaReceiptId!,
          };
          existing['media_receipt_id'] ??= observation.mediaReceiptId;
          existing['media_receipt_aliases'] = receipts.toList();
          metadataChanged = true;
        }
        if (!conflictingReceipt(observation) &&
            observation.media.isNotEmpty &&
            existing['direction'] == 'incoming') {
          final before = (existing['media'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final after = observation.media;
          final oldVideo = before.any((m) => m['type'] == 'video');
          final newVideo = after.any((m) => m.type == 'video');
          bool previewSource(String? s) => const {
                'jd_video_preview',
                'verified_media_preview',
                'jd_video_cover'
              }.contains(s);
          final newPreview = after.any((m) => previewSource(m.captureSource));
          final oldFrames = before
              .where((m) => m['capture_source'] == 'jd_video_frame_1fps')
              .map((m) => m['path'])
              .toSet();
          final newFrames = after
              .where((m) => m.captureSource == 'jd_video_frame_1fps')
              .map((m) => m.path)
              .toSet();
          final oldAlternates =
              (existing['media_alternates'] as List? ?? const [])
                  .whereType<Map>()
                  .toList();
          final merged = mergeProvenMediaPayloads([
            before,
            oldAlternates,
            after.map((m) => m.toJson()),
          ]);
          final primaryChanged = jsonEncode(before) != jsonEncode(merged.media);
          final alternatesChanged =
              jsonEncode(oldAlternates) != jsonEncode(merged.alternates);
          if (primaryChanged || alternatesChanged) {
            existing['media_alternates'] = merged.alternates;
            existing['media'] = merged.media;
            if (mediaPayloadQuality(after.map((m) => m.toJson())) >
                mediaPayloadQuality(before)) {
              existing['body'] = observation.body;
            }
            existing['text_origin'] = 'media';
            if (primaryChanged &&
                materialInputKey({'media': before}) !=
                    materialInputKey({'media': merged.media})) {
              advanceEvidence(existing);
            }
            metadataChanged = true;
            if (primaryChanged) {
              RuntimeTrace.record('media.canonical_representation_enriched', {
                'customer': userId,
                'messageId': existing['id'],
                'oldVideo': oldVideo,
                'newVideo': newVideo,
                'newPreview': newPreview,
                'oldFrames': oldFrames.length,
                'newFrames': newFrames.length,
                'canonicalIdPreserved': true
              });
            }
          }
          if (observation.mediaReceiptId != null) {
            final receipts = <Object?>{
              existing['media_receipt_id'],
              ...(existing['media_receipt_aliases'] as List? ?? const []),
              observation.mediaReceiptId
            }..remove(null);
            if ((existing['media_receipt_aliases'] as List? ?? const [])
                    .length !=
                receipts.length) {
              existing['media_receipt_aliases'] = receipts.toList();
              existing['media_receipt_id'] ??= observation.mediaReceiptId;
              metadataChanged = true;
            }
          }
        }
        if (_hasFormalReply(messages, existing, formallyAnsweredIds) ||
            !selectedIncoming(existing, observation.stableId) ||
            observation.direction != 'incoming' ||
            existing['capture_purpose'] != 'history_only') {
          return;
        }
        existing['capture_purpose'] = 'live_signal';
        existing['activated_at'] = capture.capturedAt.toUtc().toIso8601String();
        if (observation.media.isEmpty && observation.body.trim().isNotEmpty) {
          if (observation.sender != null) {
            existing['sender'] = observation.sender;
          }
        }
        if (observation.sentAt != null) {
          existing['sent_at'] = observation.sentAt!.toUtc().toIso8601String();
        }
        final canonicalId = existing['id']! as String;
        if (!insertedIncomingIds.contains(canonicalId)) {
          inserted++;
          insertedIncomingIds.add(canonicalId);
        }
        lastInsertedDirection = 'incoming';
        metadataChanged = true;
        RuntimeTrace.record('capture.history_promoted', {
          'customer': userId,
          'canonicalMessageId': canonicalId,
          'observedMessageId': observation.stableId,
          'source': 'live_observation_of_canonical_bubble',
        });
      }

      for (var index = 0; index < capture.messages.length; index++) {
        final message = capture.messages[index];
        void decision(String outcome, String reason,
            {Map<String, Object?> extra = const {}}) {
          RuntimeTrace.record('capture.message_decision', {
            'customer': userId,
            'messageId': message.stableId,
            'direction': message.direction,
            'senderAt': message.sentAt?.toUtc().toIso8601String(),
            'capturedAt': capture.capturedAt.toUtc().toIso8601String(),
            'bodyChars': message.body.length,
            'bodyHash': sha256.convert(utf8.encode(message.body)).toString(),
            'mediaCount': message.media.length,
            'outcome': outcome,
            'reason': reason,
            ...extra
          });
        }

        if (_businessDay != null &&
            businessDayFor(message.sentAt ?? capture.capturedAt) !=
                _businessDay) {
          decision('ignored', 'outside_current_business_day');
          continue;
        }

        if (message.direction == 'incoming' && message.sentAt != null) {
          final timeKey =
              CustomerMessageTime.incomingId(userId, message.sentAt!);
          final timed = messages
              .where((record) => _atTime(userId, record, timeKey))
              .toList();
          final receiptParent = message.mediaReceiptId == null
              ? null
              : messages
                  .where((record) =>
                      record['direction'] == 'incoming' &&
                      !belongsToOtherTime(record, message) &&
                      (record['media_receipt_id'] == message.mediaReceiptId ||
                          (record['media_receipt_aliases'] as List? ?? const [])
                              .contains(message.mediaReceiptId)))
                  .firstOrNull;
          final canonical = receiptParent ?? timed.firstOrNull;
          if (canonical != null) {
            canonical['sent_at'] ??=
                CustomerMessageTime.second(message.sentAt!).toIso8601String();
            _mergeTimeRecords(userId, messages, canonical, timeKey);
            mergeObservation(canonical, message);
            knownIds.add(timeKey);
            metadataChanged = true;
            decision('merged', 'same_customer_sender_second',
                extra: {'existingId': canonical['id']});
            continue;
          }
        }

        if (message.direction == 'incoming' &&
            message.mediaReceiptId != null &&
            messages.any((record) =>
                isClarifiedTextMessage(record) &&
                !belongsToOtherTime(record, message) &&
                (record['message_kind_evidence'] as Map)['receiptId'] ==
                    message.mediaReceiptId)) {
          decision('merged', 'late_media_observation_of_clarified_text');
          continue;
        }
        if (message.direction == 'incoming' && message.mediaReceiptId != null) {
          final receipt = message.mediaReceiptId!;
          final candidates = messages
              .where((existing) =>
                  existing['direction'] == 'incoming' &&
                  !belongsToOtherTime(existing, message) &&
                  (pendingMedia(existing) ||
                      message.stableId.startsWith('media-pending:')) &&
                  (existing['media_receipt_id'] == receipt ||
                      (existing['media_receipt_aliases'] as List? ?? const [])
                          .contains(receipt)))
              .toList();
          if (candidates.length == 1) {
            mergeObservation(candidates.single, message);
            continue;
          }
        }
        if (message.observationTurnKey?.startsWith('ocr-bubble:') == true) {
          final sameObservation = messages
              .where((item) =>
                  item['direction'] == message.direction &&
                  !belongsToOtherTime(item, message) &&
                  item['observation_turn_key'] == message.observationTurnKey &&
                  (message.direction != 'incoming' ||
                      message.sentAt == null ||
                      item['sent_at'] == null ||
                      _sameIncomingBubbleTime(item['sent_at'], message.sentAt)))
              .firstOrNull;
          if (sameObservation != null &&
              sameObservation['id'] != message.stableId) {
            if (message.direction == 'incoming' && message.sentAt != null) {
              sameObservation['sent_at'] ??=
                  CustomerMessageTime.second(message.sentAt!).toIso8601String();
              _mergeTimeRecords(userId, messages, sameObservation,
                  CustomerMessageTime.incomingId(userId, message.sentAt!));
            }
            mergeObservation(sameObservation, message);
            decision('merged', 'same_saved_frame_bubble_clock_refined', extra: {
              'existingId': sameObservation['id'],
              'observedSenderAt': message.sentAt?.toUtc().toIso8601String()
            });
            continue;
          }
        }
        if (!knownIds.add(message.stableId)) {
          final existing = messages
              .where((item) =>
                  !belongsToOtherTime(item, message) &&
                  (item['id'] == message.stableId ||
                      (item['observed_ids'] as List? ?? [])
                          .contains(message.stableId)))
              .firstOrNull;
          if (existing != null) {
            stableIdRereads++;
            mergeObservation(existing, message);
            continue;
          }
        }
        var ownershipUnverified = false;
        if (message.direction == 'outgoing') {
          final nearby = messages.reversed
              .where((item) =>
                  item['direction'] == 'outgoing' &&
                  (item['source'] == 'generated_reply' ||
                      item['source'] == 'sla_fallback') &&
                  _sameBubbleTime(item['sent_at'], message.sentAt))
              .toList();
          bool crossesNewTurn(Map<String, Object?> item) {
            final boundary = messages.indexWhere((m) => messageAliases(m)
                .contains(item['answered_batch_end_id'] ?? item['id']));
            if (boundary < 0 || message.sentAt == null) return false;
            return messages.skip(boundary + 1).any((m) =>
                m['direction'] == 'incoming' &&
                DateTime.tryParse(m['sent_at']?.toString() ?? '')
                        ?.isAfter(message.sentAt!) ==
                    false);
          }

          bool definitelyNewTurn(Map<String, Object?> item) {
            final stored = DateTime.tryParse(item['sent_at']?.toString() ?? '');
            if (stored == null || message.sentAt == null) return false;
            final boundary = messages.indexWhere((m) => messageAliases(m)
                .contains(item['answered_batch_end_id'] ?? item['id']));
            return boundary >= 0 &&
                messages.skip(boundary + 1).any((m) {
                  final at = DateTime.tryParse(m['sent_at']?.toString() ?? '');
                  return m['direction'] == 'incoming' &&
                      at != null &&
                      at.isAfter(stored) &&
                      message.sentAt!.isAfter(at);
                });
          }

          final matching = nearby
              .where((item) =>
                  !crossesNewTurn(item) &&
                  (item['body']?.toString() ?? '')
                          .replaceAll(RegExp(r'\s+'), '') ==
                      message.body.replaceAll(RegExp(r'\s+'), ''))
              .firstOrNull;
          if (matching != null) {
            final observedIds =
                (matching['observed_ids'] as List<Object?>? ?? [])
                    .whereType<String>()
                    .toSet();
            if (observedIds.add(message.stableId)) {
              matching['observed_ids'] = observedIds.toList();
              metadataChanged = true;
            }
            if (message.deliveryConfirmed &&
                matching['delivery_status'] != 'sent') {
              matching['delivery_status'] = 'sent';
              matching['receipt_observed_at'] =
                  capture.capturedAt.toUtc().toIso8601String();
              inserted++;
            }
            decision('merged', 'same_automated_body_and_clock',
                extra: {'existingId': matching['id']});
            continue;
          }
          // Similar wording is retained as a separate observation, but cannot
          // impersonate a manual answer and cancel a newer frozen question.
          ownershipUnverified = messages.any((item) {
            if (item['direction'] != 'outgoing' ||
                !const {'generated_reply', 'sla_fallback'}
                    .contains(item['source']) ||
                !_sameReply(item['body']?.toString() ?? '', message.body) ||
                definitelyNewTurn(item)) {
              return false;
            }
            final stored = DateTime.tryParse(item['sent_at']?.toString() ?? '');
            return message.sentAt == null ||
                stored == null ||
                message.sentAt!
                    .isBefore(stored.subtract(const Duration(seconds: 3))) ||
                _sameBubbleTime(item['sent_at'], message.sentAt);
          });
        }
        if (message.direction == 'outgoing' &&
            TranscriptText.hasDeliveryRejection(message.body)) {
          ownershipUnverified = true;
        }
        final contextOnly = historyOnly ||
            (message.direction == 'incoming' &&
                message.sentAt == null &&
                capture.automationSessionId != null) ||
            (message.direction == 'incoming' &&
                activeIncomingIds != null &&
                !activeIncomingIds.contains(message.stableId));
        decision('inserted', 'new_message_or_distinct_sender_clock');
        final timeKey =
            message.direction == 'incoming' && message.sentAt != null
                ? CustomerMessageTime.incomingId(userId, message.sentAt!)
                : null;
        final recordId = timeKey ?? message.stableId;
        knownIds.add(recordId);
        final record = <String, Object?>{
          'id': recordId,
          if (timeKey != null) ...{
            'customer_message_time_key': timeKey,
            if (message.stableId != recordId && !conflictingId(message))
              'observed_ids': [message.stableId],
          },
          'direction': message.direction,
          'body': message.body,
          'sender': message.sender,
          'sent_at': message.sentAt?.toUtc().toIso8601String(),
          'captured_at': capture.capturedAt.toUtc().toIso8601String(),
          'last_observed_at': capture.capturedAt.toUtc().toIso8601String(),
          'source': 'jd_automation',
          if (message.direction == 'incoming') 'service_evidence_revision': 0,
          if (contextOnly) 'capture_purpose': 'history_only',
          if (message.mediaReceiptId != null && !conflictingReceipt(message))
            'media_receipt_id': message.mediaReceiptId,
          if (message.captureEvidenceId != null)
            'capture_evidence_id': message.captureEvidenceId,
          if (message.direction == 'incoming' &&
              message.media.isEmpty &&
              message.mediaReceiptId == null) ...{
            'text_source_evidence_id': message.captureEvidenceId,
            'text_source_observation_turn_key': message.observationTurnKey,
          },
          if (message.direction == 'incoming')
            'text_origin': message.media.isEmpty &&
                    !message.stableId.startsWith('media-pending:')
                ? 'customer_text'
                : 'media',
          if (message.observationTurnKey != null)
            'observation_turn_key': message.observationTurnKey,
          if (message.deliveryConfirmed) 'delivery_status': 'sent',
          if (message.direction == 'outgoing' &&
              !message.deliveryConfirmed &&
              message.sentAt == null)
            'delivery_status': 'unverified_observation',
          'media': [
            if (!conflictingReceipt(message))
              for (final media in message.media) media.toJson()
          ],
          if (ownershipUnverified) 'delivery_status': 'ownership_unverified',
        };
        observeSession(record, message.stableId);
        if (contextOnly) {
          // Backfill enriches context at its chronological position. It must
          // never become the newest live question just because OCR ran later.
          final position = message.sentAt == null
              ? 0
              : messages.indexWhere((m) {
                  final at = DateTime.tryParse(m['sent_at']?.toString() ?? '');
                  return at != null && at.isAfter(message.sentAt!);
                });
          messages.insert(position < 0 ? messages.length : position, record);
        } else {
          messages.add(record);
        }
        inserted++;
        lastInsertedDirection = message.direction;
        if (message.direction == 'incoming') {
          insertedIncomingIds.add(recordId);
        } else if (message.direction == 'outgoing') {
          insertedOutgoingIds.add(message.stableId);
        }
      }
      if (inserted > 0 || metadataChanged) await _write(document, userId);
      RuntimeTrace.record('capture.append_result', {
        'customer': userId,
        'capturedAt': capture.capturedAt.toUtc().toIso8601String(),
        'receivedMessageCount': capture.messages.length,
        'stableIdRereads': stableIdRereads,
        'changed': inserted,
        'insertedIncomingIds': insertedIncomingIds,
        'insertedOutgoingIds': insertedOutgoingIds,
        'lastInsertedDirection': lastInsertedDirection
      });
      return CaptureAppendResult(
        changed: inserted,
        insertedIncomingIds: insertedIncomingIds,
        insertedOutgoingIds: insertedOutgoingIds,
        lastInsertedDirection: lastInsertedDirection,
      );
    });
  }

  /// The caller has already proved that an empty, admitted placeholder and
  /// this OCR text are the same bubble. Keep its business ID and first receive
  /// time; an already-saved, history-only OCR row becomes an alias, not a
  /// second incoming message. No clock/body similarity matching happens here.
  Future<Map<String, Object?>?> clarifyUnknownMessageAsText(String userId,
          {required String parentMessageId,
          required String receiptId,
          required CapturedMessage text,
          required String sessionId,
          required String evidenceId,
          String? expectedMaterialKey,
          bool allowWeakScreenshot = false,
          required int minimumRevision}) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return null;
        final messages =
            (document['messages'] as List).cast<Map<String, Object?>>();
        final parent = messages
            .where((message) =>
                message['id'] == parentMessageId &&
                message['direction'] == 'incoming')
            .firstOrNull;
        if (parent == null ||
            parent['service_input_frozen'] == true ||
            text.direction != 'incoming' ||
            text.body.trim().isEmpty ||
            text.media.isNotEmpty ||
            text.mediaReceiptId != null ||
            (!allowWeakScreenshot &&
                ((parent['media'] as List? ?? const []).isNotEmpty ||
                    (parent['media_alternates'] as List? ?? const [])
                        .isNotEmpty))) {
          return null;
        }
        final detached = <Map>[
          ...(parent['media'] as List? ?? const []).whereType<Map>(),
          ...(parent['media_alternates'] as List? ?? const []).whereType<Map>(),
        ];
        if (allowWeakScreenshot &&
            (text.sentAt == null ||
                text.sender != userId ||
                text.captureEvidenceId != evidenceId ||
                detached.any((media) => !isWeakScreenshotPayload(media)))) {
          return null;
        }
        // Frozen-text restoration may race a newer full OCR reading. Its
        // caller must re-read rather than overwrite that newer material.
        if (expectedMaterialKey != null &&
            materialInputKey(parent) != expectedMaterialKey) {
          return null;
        }
        if (isClarifiedTextMessage(parent)) {
          final proof = parent['message_kind_evidence'] as Map;
          return proof['sessionId'] == sessionId &&
                  proof['receiptId'] == receiptId &&
                  (text.stableId == parentMessageId ||
                      (parent['observed_ids'] as List? ?? const [])
                          .contains(text.stableId))
              ? Map<String, Object?>.from(parent)
              : null;
        }
        if (parent['media_receipt_id'] != receiptId ||
            !(parent['live_observed_session_ids'] as List? ?? const [])
                .contains(sessionId)) {
          return null;
        }
        final oldClock = DateTime.tryParse(parent['sent_at']?.toString() ?? '');
        if (oldClock != null &&
            text.sentAt != null &&
            (allowWeakScreenshot
                ? !CustomerMessageTime.sameSecond(oldClock, text.sentAt!)
                : oldClock.toUtc() != text.sentAt!.toUtc())) {
          return null;
        }
        final duplicate = messages
            .where((message) =>
                message['id'] == text.stableId &&
                message['id'] != parentMessageId)
            .firstOrNull;
        if (duplicate != null &&
            (duplicate['direction'] != 'incoming' ||
                (duplicate['media'] as List? ?? const []).isNotEmpty ||
                duplicate['media_receipt_id'] != null)) {
          return null;
        }
        final aliases = <String>{
          ...(parent['observed_ids'] as List? ?? const []).whereType<String>(),
          text.stableId,
          if (duplicate != null)
            ...(duplicate['observed_ids'] as List? ?? const [])
                .whereType<String>(),
        }..remove(parentMessageId);
        parent['message_kind_evidence'] = {
          'source': 'proven_unknown_bubble_text',
          'sessionId': sessionId,
          'parentMessageId': parentMessageId,
          'receiptId': receiptId,
          'observationId': text.stableId,
          'evidenceId': evidenceId,
          if (allowWeakScreenshot) 'weakScreenshot': true,
        };
        final previousTextOrigin = parent['text_origin'];
        parent['message_kind'] = 'text';
        parent['text_origin'] = 'customer_text';
        // A delayed correction cannot restore an obsolete frozen reading over
        // text which a newer capture already accepted for this same bubble.
        final currentBody = parent['body']?.toString() ?? '';
        final currentText = allowWeakScreenshot &&
            previousTextOrigin == 'customer_text' &&
            currentBody.trim().isNotEmpty &&
            !currentBody.startsWith('[Customer sent');
        parent['body'] = currentText ? currentBody : text.body;
        if (!currentText) {
          parent['text_source_evidence_id'] = evidenceId;
          parent['text_source_observation_turn_key'] = text.observationTurnKey;
        }
        if (detached.isNotEmpty) {
          parent['clarified_screenshot_media'] = detached;
          parent['media'] = <Map>[];
          parent.remove('media_alternates');
        }
        parent['observed_ids'] = aliases.toList();
        parent['clarified_media_receipt_id'] =
            parent.remove('media_receipt_id');
        if (parent.containsKey('media_receipt_aliases')) {
          parent['clarified_media_receipt_aliases'] =
              parent.remove('media_receipt_aliases');
        }
        parent['capture_purpose'] = 'live_signal';
        parent['observed_session_id'] = sessionId;
        parent['live_observed_session_ids'] = {
          ...(parent['live_observed_session_ids'] as List? ?? const [])
              .whereType<String>(),
          sessionId,
        }.toList();
        final revision =
            (parent['service_evidence_revision'] as num? ?? 0).toInt() + 1;
        parent['service_evidence_revision'] =
            revision > minimumRevision ? revision : minimumRevision;
        if (parent['sent_at'] == null && text.sentAt != null) {
          parent['sent_at'] = text.sentAt!.toUtc().toIso8601String();
        }
        if (text.sender != null) parent['sender'] = text.sender;
        if (text.observationTurnKey != null) {
          parent['observation_turn_key'] = text.observationTurnKey;
        }
        // Preserve captured_at, activated_at and capture_evidence_id. The
        // clarification's evidence is recorded in the provenance above.
        if (duplicate != null) messages.remove(duplicate);
        await _write(document, userId);
        return Map<String, Object?>.from(parent);
      });

  /// Fill a previously unknown sender clock without replacing the durable
  /// media ID used by pending replies and reconciliation.
  /// Consolidate only aliases established by the media inventory's geometric
  /// and pixel proof. Raw observations remain attached; business IDs stay in
  /// observed_ids so pending/in-flight reply ledgers can still reconcile them.
  Future<void> consolidateProvenMediaAliases(String userId,
          {required String canonicalMessageId,
          required Iterable<String> messageAliases,
          required Iterable<String> receiptAliases}) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return;
        final messages =
            (document['messages'] as List).cast<Map<String, Object?>>();
        final ids = {canonicalMessageId, ...messageAliases};
        final receipts = receiptAliases.toSet();
        final matches = messages.where((m) {
          if (m['direction'] != 'incoming') return false;
          return ids.contains(m['id']) ||
              (m['observed_ids'] as List? ?? const []).any(ids.contains) ||
              receipts.contains(m['media_receipt_id']) ||
              (m['media_receipt_aliases'] as List? ?? const [])
                  .any(receipts.contains);
        }).toList();
        final canonical =
            matches.where((m) => m['id'] == canonicalMessageId).firstOrNull;
        if (canonical == null) return;
        final times = matches
            .map((m) => incomingTimeKey(userId, m))
            .whereType<String>()
            .toSet();
        if (times.length > 1) {
          throw StateError('proven_media_alias_sender_clock_conflict');
        }
        final clocks = matches
            .map((m) => DateTime.tryParse(m['sent_at']?.toString() ?? ''))
            .whereType<DateTime>()
            .map(CustomerMessageTime.second)
            .toList();
        int quality(Map<String, Object?> message) => mediaPayloadQuality(
            (message['media'] as List? ?? const []).whereType<Map>());
        final ordered = [...matches]
          ..sort((a, b) => quality(b).compareTo(quality(a)));
        final best = ordered.first;
        final previous =
            (canonical['media'] as List? ?? const []).whereType<Map>().toList();
        final merged = mergeProvenMediaPayloads([
          previous,
          for (final message in ordered)
            (message['media'] as List? ?? const []).whereType<Map>(),
          for (final message in ordered)
            (message['media_alternates'] as List? ?? const []).whereType<Map>(),
        ]);
        if (quality(best) > quality(canonical)) {
          canonical['body'] = best['body'];
        }
        if (jsonEncode(previous) != jsonEncode(merged.media)) {
          canonical['media'] = merged.media;
          canonical['text_origin'] = 'media';
          if (materialInputKey({'media': previous}) !=
              materialInputKey({'media': merged.media})) {
            canonical['service_evidence_revision'] =
                (canonical['service_evidence_revision'] as int? ?? 0) + 1;
          }
        }
        canonical['media_alternates'] = merged.alternates;
        canonical['observed_ids'] = {
          ...ids,
          for (final m in matches) ...{
            m['id'],
            ...(m['observed_ids'] as List? ?? const []),
          }
        }.whereType<String>().where((id) => id != canonical['id']).toList();
        canonical['media_receipt_aliases'] = {
          ...receipts,
          for (final m in matches) ...{
            m['media_receipt_id'],
            ...(m['media_receipt_aliases'] as List? ?? const []),
          }
        }.whereType<String>().toList();
        canonical['live_observed_session_ids'] = {
          for (final m in matches)
            ...(m['live_observed_session_ids'] as List? ?? const []),
        }.whereType<String>().toList();
        if (canonical['sent_at'] == null && clocks.isNotEmpty) {
          canonical['sent_at'] = clocks.first.toIso8601String();
        }
        final duplicates =
            matches.where((m) => !identical(m, canonical)).toSet();
        if (duplicates.isNotEmpty) {
          canonical['media_observation_alternates'] = [
            ...(canonical['media_observation_alternates'] as List? ?? const []),
            ...duplicates,
          ];
          messages.removeWhere(duplicates.contains);
        }
        await _write(document, userId);
      });

  Future<void> refineMediaClock(
          String userId, String messageId, DateTime sentAt,
          {bool verifiedCardCorrection = false}) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return;
        final messages =
            (document['messages'] as List).cast<Map<String, Object?>>();
        for (final message in messages) {
          if (message['id'] == messageId &&
              message['direction'] == 'incoming' &&
              _hasCapturedMedia(message)) {
            final key = CustomerMessageTime.incomingId(userId, sentAt);
            final previousKey = incomingTimeKey(userId, message);
            if (previousKey != null && previousKey != key) return;
            final previous = message['sent_at'];
            message['sent_at'] =
                CustomerMessageTime.second(sentAt).toIso8601String();
            _mergeTimeRecords(userId, messages, message, key);
            await _write(document, userId);
            RuntimeTrace.record('media.sender_clock_corrected', {
              'customer': userId,
              'messageId': messageId,
              'previousSenderAt': previous,
              'senderAt': message['sent_at'],
              'proof': verifiedCardCorrection
                  ? 'verified_same_card_anchor'
                  : 'previously_unknown_clock',
              'canonicalIdPreserved': true
            });
            return;
          }
        }
      });

  /// Adds factual visual descriptions to already captured media without
  /// writing an unsent customer reply into conversation history.
  Future<int> updateMediaDescriptions(
          String userId, Map<String, String> descriptions) =>
      _serialized(userId, () async {
        if (descriptions.isEmpty) return 0;
        final document = await read(userId);
        if (document == null) return 0;
        var changed = 0;
        final messages = document['messages'] as List<Object?>? ?? const [];
        for (final message in messages.whereType<Map<String, dynamic>>()) {
          final inputBefore = materialInputKey(message);
          final mediaItems = message['media'] as List<Object?>? ?? const [];
          for (final media in mediaItems.whereType<Map<String, dynamic>>()) {
            final path = media['path']?.toString();
            final description = path == null ? null : descriptions[path];
            if (description == null || media['description'] == description) {
              continue;
            }
            media['description'] = description;
            changed++;
          }
          if (materialInputKey(message) != inputBefore) {
            message['service_evidence_revision'] =
                (message['service_evidence_revision'] as num? ?? 0).toInt() + 1;
          }
        }
        if (changed > 0) await _write(document, userId);
        return changed;
      });

  Future<bool> hasSimilarImageFingerprint(String userId, String fingerprint,
      {int maximumDistance = 8,
      Set<String>? captureSources,
      DateTime? capturedAfter}) async {
    if (fingerprint.isEmpty) return false;
    final target = BigInt.tryParse(fingerprint, radix: 16);
    if (target == null) return false;
    final document = await read(userId);
    final messages = document?['messages'] as List<Object?>? ?? const [];
    for (final message in messages.whereType<Map<String, dynamic>>()) {
      if (capturedAfter != null) {
        final capturedAt =
            DateTime.tryParse(message['captured_at']?.toString() ?? '');
        if (capturedAt == null || capturedAt.isBefore(capturedAfter)) {
          continue;
        }
      }
      final mediaItems = message['media'] as List<Object?>? ?? const [];
      for (final media in mediaItems.whereType<Map<String, dynamic>>()) {
        if (captureSources != null &&
            !captureSources.contains(media['capture_source']?.toString())) {
          continue;
        }
        final known = BigInt.tryParse(
            media['visual_fingerprint']?.toString() ?? '',
            radix: 16);
        if (known == null) continue;
        var difference = target ^ known;
        var distance = 0;
        while (difference > BigInt.zero && distance <= maximumDistance) {
          difference &= difference - BigInt.one;
          distance++;
        }
        if (distance <= maximumDistance) return true;
      }
    }
    return false;
  }

  /// Records the one-time SLA acknowledgement without marking the customer's
  /// request answered. The final generated reply remains independently queued.
  Future<void> appendSlaFallbackSent({
    required String userId,
    required String messageId,
    required String reply,
  }) =>
      _serialized(userId, () async {
        final document = await _readOrCreate(
          userId: userId,
          displayName: userId,
          stableKey: userId,
        );
        final messages = (document['messages'] as List<Object?>)
            .cast<Map<String, Object?>>();
        if (messages.any((message) =>
            message['source'] == 'sla_fallback' &&
            message['sla_message_id'] == messageId)) {
          return;
        }
        final now = _clock().toUtc();
        messages.add({
          'id':
              'sla:${sha256.convert(utf8.encode('$userId\u001f$messageId\u001f$reply'))}',
          'direction': 'outgoing',
          'body': reply,
          'sender': 'jd-sla-fallback-v1',
          'sent_at': now.toIso8601String(),
          'captured_at': now.toIso8601String(),
          'source': 'sla_fallback',
          'sla_message_id': messageId,
          'delivery_status': 'sent',
          'media': <Object?>[],
        });
        await _write(document, userId);
      });

  /// Appends a generated reply only after Qianniu confirms the send action.
  /// Unsent drafts intentionally never become conversation history.
  Future<bool> acceptAttemptReceipt(
          {required String userId, required String attemptId}) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        var found = false;
        for (final m in (document['messages'] as List).whereType<Map>()) {
          if (m['delivery_attempt_id'] == attemptId) {
            m['delivery_status'] = 'sent';
            found = true;
          }
        }
        if (found) await _write(document, userId);
        return found;
      });

  Future<void> markAttemptRejected(
          {required String userId, required String attemptId}) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return;
        for (final m in (document['messages'] as List).whereType<Map>()) {
          if (m['delivery_attempt_id'] == attemptId) {
            m['delivery_status'] = 'rejected';
          }
        }
        await _write(document, userId);
      });

  Future<void> appendSentReply({
    required String userId,
    required String displayName,
    required String stableKey,
    required AiDraft draft,
    String? taskId,
    String? attemptId,
    String? batchEndMessageId,
  }) =>
      _serialized(userId, () async {
        final document = await _readOrCreate(
          userId: userId,
          displayName: displayName,
          stableKey: stableKey,
        );
        if (attemptId != null &&
            (document['messages'] as List)
                .whereType<Map>()
                .any((m) => m['delivery_attempt_id'] == attemptId)) {
          return;
        }
        final now = _clock().toUtc();
        final replyId =
            'assistant:${sha256.convert(utf8.encode('$userId\u001f${now.toIso8601String()}\u001f${draft.reply}'))}';
        (document['messages'] as List<Object?>).add({
          'id': replyId,
          'direction': 'outgoing',
          'body': draft.reply,
          'sender': draft.model,
          'sent_at': now.toIso8601String(),
          'captured_at': now.toIso8601String(),
          'source': 'generated_reply',
          if (taskId != null) 'delivery_task_id': taskId,
          if (attemptId != null) 'delivery_attempt_id': attemptId,
          if (batchEndMessageId != null)
            'answered_batch_end_id': batchEndMessageId,
          'delivery_status': attemptId == null ? 'sent' : 'submitted',
          'media': [
            for (final attachment in draft.attachments)
              {
                'type': attachment.kind,
                'path': attachment.url.toString(),
                'media_id': attachment.mediaId,
                'caption': attachment.caption,
              }
          ],
          'reply_metadata': {
            'decision': draft.decision,
            'confidence': draft.confidence,
            'risk_level': draft.riskLevel,
            'model': draft.model,
            'used_record_ids': draft.usedRecordIds,
            'actions': draft.actions,
            'raw_response': jsonDecode(draft.rawJson),
          },
        });
        await _write(document, userId);
      });

  /// Removes legacy unsent generated replies written by older builds.
  /// Incoming messages, OCR-observed seller messages, and confirmed generated
  /// sends are preserved. An exact ledger-owned attempt record is also retained
  /// for audit/reconciliation; retaining it does not confirm its delivery.
  Future<int> purgeLegacyUnsentDrafts({
    Map<String, Map<String, Object?>> ownedDeliveryAttempts = const {},
  }) async {
    if (_businessDay != null) {
      return _purgeDailyUnsentDrafts(ownedDeliveryAttempts);
    }
    return _serialized('*maintenance*', () async {
      if (!await conversationsDirectory.exists()) return 0;
      var removed = 0;
      await for (final entity in conversationsDirectory.list()) {
        if (entity is! File || p.extension(entity.path) != '.json') continue;
        Map<String, Object?> document;
        try {
          document =
              (jsonDecode(await entity.readAsString()) as Map<String, dynamic>)
                  .cast<String, Object?>();
        } catch (_) {
          continue;
        }
        final userId = document['user_id']?.toString();
        if (userId != null && userId.isNotEmpty) {
          final customerNamedFile = _conversationFile(userId);
          if (p.absolute(entity.path) != p.absolute(customerNamedFile.path) &&
              !await customerNamedFile.exists()) {
            try {
              await entity.rename(customerNamedFile.path);
            } on FileSystemException {
              // Keep the original file intact if a rename is unavailable.
            }
          }
        }
        final rawMessages = document['messages'];
        if (rawMessages is! List<Object?>) continue;
        final retained = rawMessages.where((item) {
          if (item is! Map<String, dynamic>) return true;
          final attempt = ownedDeliveryAttempts[item['delivery_attempt_id']];
          final ledgerOwned = attempt != null &&
              attempt['attempt_id'] == item['delivery_attempt_id'] &&
              userId != null &&
              attempt['user_id'] == userId &&
              item['delivery_task_id'] is String &&
              (item['delivery_task_id']! as String).isNotEmpty &&
              attempt['task_id'] == item['delivery_task_id'] &&
              attempt['batch_end_message_id'] ==
                  item['answered_batch_end_id'] &&
              attempt['reply'] == item['body'];
          final unsentDraft = item['source'] == 'generated_reply' &&
              item['delivery_status'] != 'sent' &&
              !ledgerOwned;
          if (unsentDraft) removed++;
          return !unsentDraft;
        }).toList(growable: true);
        if (retained.length == rawMessages.length) continue;
        document['messages'] = retained;
        if (userId != null && userId.isNotEmpty) {
          await _write(document, userId);
        }
      }
      return removed;
    });
  }

  Future<int> _purgeDailyUnsentDrafts(
      Map<String, Map<String, Object?>> ownedDeliveryAttempts) async {
    await prepareDay();
    var removed = 0;
    await for (final entity in conversationsDirectory.list()) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      String? userId;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map && decoded['user_id'] is String) {
          userId = decoded['user_id']! as String;
        }
      } on FormatException {
        continue;
      }
      if (userId == null ||
          p.basename(entity.path) != '${safeUserId(userId)}.json') {
        continue;
      }
      final customer = userId;
      removed += await _serialized(customer, () async {
        final document = await read(customer);
        if (document == null) return 0;
        final rawMessages = document['messages'];
        if (rawMessages is! List) return 0;
        final retained = rawMessages.where((item) {
          if (item is! Map) return true;
          final attempt = ownedDeliveryAttempts[item['delivery_attempt_id']];
          final ledgerOwned = attempt != null &&
              attempt['attempt_id'] == item['delivery_attempt_id'] &&
              attempt['user_id'] == customer &&
              item['delivery_task_id'] is String &&
              (item['delivery_task_id']! as String).isNotEmpty &&
              attempt['task_id'] == item['delivery_task_id'] &&
              attempt['batch_end_message_id'] ==
                  item['answered_batch_end_id'] &&
              attempt['reply'] == item['body'];
          return !(item['source'] == 'generated_reply' &&
              item['delivery_status'] != 'sent' &&
              !ledgerOwned);
        }).toList();
        final count = rawMessages.length - retained.length;
        if (count > 0) {
          document['messages'] = retained;
          await _write(document, customer);
        }
        return count;
      });
    }
    return removed;
  }

  /// Attaches a separately verified send attempt to an already observed bubble.
  /// The database validates unique text/clock ownership first; this operation
  /// changes delivery metadata only and never creates or retimes a message.
  Future<bool> bindObservedAttempt({
    required String userId,
    required String messageId,
    required String attemptId,
    required String taskId,
    required String batchEndMessageId,
  }) =>
      _serialized(userId, () async {
        if ([messageId, attemptId, taskId, batchEndMessageId]
            .any((value) => value.isEmpty)) {
          return false;
        }
        final document = await read(userId);
        if (document == null) return false;
        final matches = (document['messages'] as List<Object?>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((item) =>
                item['direction'] == 'outgoing' &&
                (item['id'] == messageId ||
                    (item['observed_ids'] as List<Object?>? ?? const [])
                        .contains(messageId)))
            .toList();
        if (matches.length != 1) return false;
        final message = matches.single;
        final previousAttempt = message['delivery_attempt_id'];
        if (previousAttempt != null && previousAttempt != attemptId) {
          return false;
        }
        if (message['delivery_task_id'] != null &&
            message['delivery_task_id'] != taskId) {
          return false;
        }
        if (message['answered_batch_end_id'] != null &&
            message['answered_batch_end_id'] != batchEndMessageId) {
          return false;
        }
        final observedSource = const {'jd_automation', 'qianniu_capture'}
            .contains(message['source']);
        final alreadyBound = message['source'] == 'generated_reply' &&
            previousAttempt == attemptId;
        if (!observedSource && !alreadyBound) return false;
        if (alreadyBound &&
            message['delivery_status'] == 'sent' &&
            message['delivery_task_id'] == taskId &&
            message['answered_batch_end_id'] == batchEndMessageId) {
          return true;
        }
        message['source'] = 'generated_reply';
        message['delivery_attempt_id'] = attemptId;
        message['delivery_task_id'] = taskId;
        message['answered_batch_end_id'] = batchEndMessageId;
        message['delivery_status'] = 'sent';
        await _write(document, userId);
        RuntimeTrace.record('delivery.observed_receipt_bound', {
          'customer': userId,
          'messageId': message['id'],
          'observedMessageId': messageId,
          'attemptId': attemptId,
          'taskId': taskId,
          'batchEndMessageId': batchEndMessageId,
        });
        return true;
      });

  Future<bool> confirmObservedOutgoing({
    required String userId,
    required String messageId,
    String deliveryStatus = 'sent',
  }) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        final message = (document['messages'] as List<Object?>)
            .whereType<Map<String, dynamic>>()
            .where((item) =>
                (item['id'] == messageId ||
                    (item['observed_ids'] as List<Object?>? ?? [])
                        .contains(messageId)) &&
                item['direction'] == 'outgoing')
            .firstOrNull;
        if (message == null) return false;
        message['delivery_status'] = deliveryStatus;
        await _write(document, userId);
        return true;
      });

  Future<bool> markReplySent({
    required String userId,
    required String reply,
  }) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        final messages = (document['messages'] as List<Object?>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
        for (final message in messages.reversed) {
          if (message['source'] == 'generated_reply' &&
              message['body'] == reply &&
              message['delivery_status'] != 'sent') {
            final now = _clock().toUtc().toIso8601String();
            message['delivery_status'] = 'sent';
            message['sent_at'] = now;
            await _write(document, userId);
            return true;
          }
        }
        return false;
      });

  Future<List<StoredMessage>> lastMessages(String userId,
      {int limit = 20}) async {
    final document = await read(userId);
    if (document == null) return const [];
    final messages = (document['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
    final selected = messages.length <= limit
        ? messages
        : messages.sublist(messages.length - limit);
    return selected.map((message) {
      final capturedAt =
          DateTime.tryParse(message['captured_at'] as String? ?? '');
      return StoredMessage(
        stableId: message['id'] as String? ?? '',
        direction: message['direction'] as String? ?? 'unknown',
        body: message['body'] as String? ?? '',
        capturedAt:
            capturedAt?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    }).toList(growable: false);
  }

  /// Inspect existing history without migrating names or initializing a day.
  Future<Map<String, Object?>?> readOnly(String userId) =>
      _readDocument(userId, readOnly: true);

  Future<Map<String, Object?>?> read(String userId) =>
      _readDocument(userId, readOnly: false);

  Future<Map<String, Object?>?> _readDocument(String userId,
      {required bool readOnly}) async {
    if (_businessDay == null) return _readLegacy(userId, migrate: !readOnly);
    if (!readOnly) await _ensureDailyInitialized(userId);
    final file = _conversationFile(userId);
    if (!await file.exists()) return null;
    final document =
        (jsonDecode(await file.readAsString()) as Map<String, dynamic>)
            .cast<String, Object?>();
    _verifyOwner(document, userId);
    if (document['history_business_day'] != _businessDay) {
      throw StateError('history_business_day_mismatch: expected $_businessDay');
    }
    return document;
  }

  void _verifyOwner(Map document, String userId) {
    // APFS can resolve differently cased/normalized names to one file.
    if (document['user_id'] != userId) {
      RuntimeTrace.record('history.customer_identity_mismatch', {
        'customer': userId,
        'storedCustomer': document['user_id'],
        'action': 'preserve_file_and_block_foreign_context'
      });
      throw StateError('history_customer_identity_mismatch: expected $userId, '
          'stored ${document['user_id']}');
    }
  }

  Future<Map<String, Object?>?> _readLegacy(String userId,
      {required bool migrate}) async {
    final destination =
        File(p.join(rootDirectory.path, '${safeUserId(userId)}.json'));
    var file = destination;
    var legacyName = false;
    if (!await file.exists()) {
      file = _legacyConversationFile(userId);
      if (!await file.exists()) return null;
      legacyName = true;
    }
    final document =
        (jsonDecode(await file.readAsString()) as Map<String, dynamic>)
            .cast<String, Object?>();
    _verifyOwner(document, userId);
    if (migrate && legacyName) {
      await rootDirectory.create(recursive: true);
      try {
        await file.rename(destination.path);
      } on FileSystemException {
        // Keep read access to the already verified legacy document.
      }
    }
    return document;
  }

  /// Replace a proven thumbnail representation without changing its durable
  /// message/queue cursor. Never downgrade a complete original to a crop.
  Future<bool> promoteMedia(
          String userId, String messageId, CapturedMessage original) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        final row = (document['messages'] as List<Object?>)
            .whereType<Map<String, dynamic>>()
            .where((m) => m['id'] == messageId && m['direction'] == 'incoming')
            .firstOrNull;
        if (row == null ||
            row['service_input_frozen'] == true ||
            isClarifiedTextMessage(row)) {
          return false;
        }
        final previous =
            (row['media'] as List<Object?>? ?? const []).whereType<Map>();
        if (!original.media.any((m) => m.type == 'video') &&
            previous
                .any((m) => m['type'] == 'image' && m['is_partial'] != true)) {
          return false;
        }
        row['media_alternates'] = [
          ...(row['media_alternates'] as List<Object?>? ?? const []),
          ...previous
        ];
        row['media'] = original.media.map((m) => m.toJson()).toList();
        row['body'] = original.body;
        row['text_origin'] = 'media';
        if (materialInputKey({'media': previous.toList()}) !=
            materialInputKey(row)) {
          row['service_evidence_revision'] =
              (row['service_evidence_revision'] as num? ?? 0).toInt() + 1;
        }
        await _write(document, userId);
        return true;
      });

  Future<String> saveMedia({
    required String userId,
    required String filename,
    required List<int> bytes,
  }) =>
      _serialized(userId, () async {
        final directory =
            Directory(p.join(mediaDirectory.path, safeUserId(userId)));
        await directory.create(recursive: true);
        final extension = p.extension(filename).toLowerCase();
        final safeExtension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
            ? extension
            : '.bin';
        final digest = sha256.convert(bytes).toString().substring(0, 16);
        final path = p.join(directory.path, '$digest$safeExtension');
        final file = File(path);
        if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
        return path;
      });

  String safeUserId(String userId) {
    final trimmed = userId.trim();
    if (trimmed.isEmpty) {
      return 'user_${sha256.convert(utf8.encode(userId))}';
    }
    var safe = trimmed.replaceAll(RegExp(r'[/\\:\x00-\x1f\x7f]'), '_');
    final changed = safe != trimmed;
    if (utf8.encode(safe).length > 180) {
      safe = String.fromCharCodes(safe.runes.take(48));
    }
    if (changed || safe != trimmed) {
      final suffix =
          sha256.convert(utf8.encode(trimmed)).toString().substring(0, 10);
      safe = '${safe}_$suffix';
    }
    return safe;
  }

  String _legacySafeUserId(String userId) {
    final trimmed = userId.trim();
    if (RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(trimmed)) return trimmed;
    return 'user_${sha256.convert(utf8.encode(trimmed))}';
  }

  String _ocrCanonical(String value) => TranscriptText.clean(value)
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'''[.,!?;:'"`~，。！？；：“”‘’（）()\[\]{}、]'''), '');

  bool _sameReply(String generated, String observed) {
    final left = _ocrCanonical(generated);
    final right = _ocrCanonical(observed);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final shorter = left.length < right.length ? left : right;
    final longer = left.length < right.length ? right : left;
    if (shorter.length >= 15 && longer.contains(shorter)) return true;

    Set<String> words(String value) => RegExp(r'[a-z0-9]+|[\u3400-\u9fff]')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .toSet();
    final generatedWords = words(generated);
    final observedWords = words(observed);
    final smallerWords = generatedWords.length < observedWords.length
        ? generatedWords
        : observedWords;
    if (smallerWords.length < 6) return false;
    final overlap = generatedWords.intersection(observedWords).length;
    return overlap >= 6 && overlap / smallerWords.length >= 0.75;
  }

  bool _sameBubbleTime(Object? storedValue, DateTime? observed) {
    if (observed == null) return false;
    final stored = DateTime.tryParse(storedValue?.toString() ?? '');
    if (stored == null) return false;
    return stored.toUtc().difference(observed.toUtc()).abs() <=
        const Duration(seconds: 3);
  }

  bool _sameIncomingBubbleTime(Object? storedValue, DateTime? observed) {
    if (observed == null) return false;
    final stored = DateTime.tryParse(storedValue?.toString() ?? '');
    if (stored == null) return false;
    // JD timestamps identify the bubble to the second. Nearby timestamps are
    // commonly separate rapid messages and must remain separate.
    return CustomerMessageTime.sameSecond(stored, observed);
  }

  Future<Map<String, Object?>> _readOrCreate({
    required String userId,
    required String displayName,
    required String stableKey,
  }) async {
    final existing = await read(userId);
    if (existing != null) {
      existing['display_name'] = displayName;
      existing['stable_key'] = stableKey;
      return existing;
    }
    return {
      'schema_version': 1,
      'user_id': userId,
      'display_name': displayName,
      'stable_key': stableKey,
      'created_at': _clock().toUtc().toIso8601String(),
      'updated_at': _clock().toUtc().toIso8601String(),
      'messages': <Object?>[],
    };
  }

  Future<void> _write(Map<String, Object?> document, String userId) async {
    _verifyOwner(document, userId);
    if (_businessDay != null) {
      final existingDay = document['history_business_day'];
      if (existingDay != null && existingDay != _businessDay) {
        throw StateError(
            'history_business_day_mismatch: expected $_businessDay');
      }
      document['history_business_day'] = _businessDay;
    }
    await conversationsDirectory.create(recursive: true);
    document['updated_at'] = _clock().toUtc().toIso8601String();
    await _atomicWrite(_conversationFile(userId),
        const JsonEncoder.withIndent('  ').convert(document));
  }

  Future<void> _atomicWrite(File destination, String contents) async {
    final temporary = File('${destination.path}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.${_temporarySequence++}.tmp');
    try {
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _conversationFile(String userId) =>
      File(p.join(conversationsDirectory.path, '${safeUserId(userId)}.json'));

  File _legacyConversationFile(String userId) =>
      File(p.join(rootDirectory.path, '${_legacySafeUserId(userId)}.json'));

  Future<T> _serialized<T>(String userId, Future<T> Function() action) {
    final key = '$_storageKey\u0000$userId';
    if (Zone.current[_serializationOwner] == key) return action();
    final completer = Completer<T>();
    final previous = _writeTails[key] ?? Future<void>.value();
    final tail = previous.then((_) async {
      try {
        completer.complete(
            await runZoned(action, zoneValues: {_serializationOwner: key}));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _writeTails[key] = tail;
    unawaited(tail.then((_) {
      if (identical(_writeTails[key], tail)) _writeTails.remove(key);
    }));
    return completer.future;
  }
}

class CaptureAppendResult {
  const CaptureAppendResult({
    required this.changed,
    required this.insertedIncomingIds,
    required this.insertedOutgoingIds,
    required this.lastInsertedDirection,
  });

  final int changed;
  final List<String> insertedIncomingIds;
  final List<String> insertedOutgoingIds;
  final String? lastInsertedDirection;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

// OCR text refinements must never merge distinct attachments merely because
// they share a placeholder/caption or a one-second sender clock.
bool _hasCapturedMedia(Map<String, Object?> message) =>
    message['media_receipt_id'] != null ||
    message['text_origin'] == 'media' ||
    message['media'] is List && (message['media']! as List).isNotEmpty;
