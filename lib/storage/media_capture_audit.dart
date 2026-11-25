import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import '../capture/media_card_occurrence.dart';
import '../capture/incoming_message_ownership.dart';
import '../capture/live_media_admission.dart';
import '../capture/ocr_capture_extractor.dart';
import '../capture/ocr_chat_layout.dart';
import '../capture/viewport_evidence.dart';
import '../platform/macos_capture_adapter.dart';
import '../runtime/runtime_trace.dart';
import 'capture_database.dart';
import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import 'media_visual_matcher.dart';
import 'customer_media_inventory.dart';

/// Local visual observations, NOT JD message IDs. This ledger cannot count
/// messages which never appeared in a captured frame.
class MediaCaptureAudit {
  MediaCaptureAudit(this.database, {this.record = RuntimeTrace.record});
  final CaptureDatabase database;
  final void Function(String, Map<String, Object?>) record;
  static const unresolved = [
    'unbound',
    'discovered',
    'unverified',
    'image_partial',
    'video_preview_only',
    'failed'
  ];
  static const states = [
    ...unresolved,
    'image_saved',
    'video_frames_saved',
    'reused',
    'baseline',
    'rejected_text'
  ];

  Future<String> discover(ViewportEvidence evidence, OcrVisualRegion region,
      {OcrInspection? inspection,
      Iterable<OcrVisualRegion>? physicalCards}) async {
    final box = [region.x, region.y, region.width, region.height]
        .map((v) => double.parse(v.toStringAsFixed(5)))
        .toList();
    final id =
        sha256.convert(utf8.encode(jsonEncode([evidence.id, box]))).toString();
    final ownership = inspection == null
        ? null
        : IncomingMessageOwnership.inspect(
            inspection, evidence.customer, region,
            physicalCards: physicalCards);
    final details = <String, Object?>{
      'observationId': id,
      'observationGroupId': id,
      'idSource': 'local_visual_observation',
      'platformMessageId': null,
      'customer': evidence.customer,
      'evidenceId': evidence.id,
      'region': box,
      'capturedAt': evidence.capturedAt.toUtc().toIso8601String(),
      'automationSessionId': evidence.metadata['automationSessionId'],
      'sourceImagePath': evidence.imagePath,
      'transcript': evidence.metadata['chatRegion'],
      if (ownership != null) 'incomingMediaOwnership': ownership.toMap(),
      if (inspection != null)
        'occurrenceContext': MediaCardOccurrenceContext.inspect(
                inspection, evidence.customer, region,
                physicalCards: physicalCards)
            .toMap(),
    };
    await (await database.database).rawInsert(
        '''INSERT OR IGNORE INTO media_capture_audit
      (observation_id,evidence_id,customer,state,details,updated_at_ms) VALUES(?,?,?,?,?,?)''',
        [
          id,
          evidence.id,
          evidence.customer,
          'discovered',
          jsonEncode(details),
          DateTime.now().millisecondsSinceEpoch
        ]);
    record('media.observation_discovered', details);
    return id;
  }

  Future<String> discoverUnbound(
      ViewportEvidence evidence, OcrVisualRegion region,
      {bool current = true,
      String? receiptId,
      OcrInspection? inspection,
      Iterable<OcrVisualRegion>? physicalCards}) async {
    final id = await discover(evidence, region,
        inspection: inspection, physicalCards: physicalCards);
    final rows = await (await database.database).query('media_capture_audit',
        where: 'observation_id=?', whereArgs: [id]);
    if (rows.single['state'] == 'discovered') {
      final details = jsonDecode(rows.single['details']! as String) as Map;
      await finish(id, current ? 'unbound' : 'baseline', {
        'senderClock': null,
        'attributionPending': true,
        'kind': 'video',
        'reason': 'explicit_play_overlay_without_visible_sender_header',
        'observationGroupId': details['observationGroupId'] ?? id,
        if (receiptId != null) 'mediaReceiptId': receiptId,
      });
    }
    return id;
  }

  /// Save only a crop of immutable evidence. This does not inspect/download
  /// the JD cache, assign a clock, activate history, or declare an original.
  Future<Uint8List?> frozenCardPreview(
      ViewportEvidence evidence, OcrVisualRegion region) async {
    try {
      return await _decodeFrozenCard(evidence, region);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _decodeFrozenCard(
      ViewportEvidence evidence, OcrVisualRegion region) async {
    final codec = await ui
        .instantiateImageCodec(await File(evidence.imagePath).readAsBytes());
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final left = (region.x * image.width).floor().clamp(0, image.width - 1);
      final top = (region.y * image.height).floor().clamp(0, image.height - 1);
      final width =
          (region.width * image.width).ceil().clamp(1, image.width - left);
      final height =
          (region.height * image.height).ceil().clamp(1, image.height - top);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
          image,
          ui.Rect.fromLTWH(left.toDouble(), top.toDouble(), width.toDouble(),
              height.toDouble()),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint());
      final picture = recorder.endRecording();
      final crop = await picture.toImage(width, height);
      picture.dispose();
      final bytes = await crop.toByteData(format: ui.ImageByteFormat.png);
      crop.dispose();
      return bytes?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Upgrade legacy unclocked owners only from an explicit immutable sender
  /// block or an already readable incoming clock. Asset similarity is not a
  /// business-identity fallback for the timestamp workflow.
  Future<MediaParent?> _legacyParentAtTimestamp(
      ViewportEvidence evidence,
      OcrInspection inspection,
      OcrVisualRegion region,
      Map own,
      DateTime senderAt) async {
    final inventory = CustomerMediaInventory(database);
    final session = database.currentAutomationSessionId;
    if (session == null) return null;
    final db = await database.database;
    final candidates = await db.query('customer_media_items',
        where: 'customer=? AND admission_session_id=? '
            'AND canonical_id IS NULL AND message_id IS NOT NULL '
            'AND sender_ms IS NULL AND identity_ambiguous=0 AND kind!=?',
        whereArgs: [evidence.customer, session, 'text']);
    if (candidates.isEmpty) return null;
    final candidateReceipts =
        candidates.map((row) => row['item_id']! as String).toSet();
    final exact = <String>{
      if (own['mediaReceiptId'] is String &&
          candidateReceipts.contains(own['mediaReceiptId']))
        own['mediaReceiptId']! as String,
    };
    final clock =
        const OcrCaptureExtractor().mediaClockForRegion(inspection, region);
    final rows = await db.query('media_capture_audit',
        where: 'customer=? AND state!=?',
        whereArgs: [evidence.customer, 'session_archived']);
    for (final row in rows) {
      final prior = jsonDecode(row['details']! as String) as Map;
      final receipt = prior['mediaReceiptId'];
      if (prior['automationSessionId'] != session ||
          !candidateReceipts.contains(receipt)) {
        continue;
      }
      final ownership = prior['incomingMediaOwnership'] as Map?;
      final context = prior['occurrenceContext'] as Map?;
      final headerBox = ownership?['headerRegion'] as List?;
      final priorTop = headerBox != null && headerBox.length == 4
          ? (headerBox[1] as num).toDouble()
          : (context?['headerTop'] as num?)?.toDouble();
      final sameImmutableBlock = prior['evidenceId'] == evidence.id &&
          priorTop != null &&
          clock.headerTop != null &&
          (priorTop - clock.headerTop!).abs() < .00002;
      var rawHeader = context?['customerVerified'] == true &&
              context?['headerKey']?.toString().startsWith(
                      'incoming:${evidence.customer.toLowerCase()}:') ==
                  true
          ? context!['headerKey']?.toString()
          : null;
      if (ownership?['exactCustomerHeader'] == true &&
          (ownership?['headerConfidence'] as num? ?? 0) >= .45) {
        rawHeader = ownership?['headerText']?.toString();
      }
      final rawClock = rawHeader == null
          ? null
          : RegExp(
                  r'(?<![0-9])([01]?\d|2[0-3])[:：]([0-5]\d)[:：]([0-5]\d)(?![0-9])')
              .firstMatch(rawHeader);
      final captured = DateTime.tryParse(prior['capturedAt']?.toString() ?? '');
      DateTime? priorAt;
      if (rawClock != null && captured != null) {
        final calendar = captured.toUtc().add(const Duration(hours: 8));
        priorAt = DateTime.utc(
                calendar.year,
                calendar.month,
                calendar.day,
                int.parse(rawClock[1]!),
                int.parse(rawClock[2]!),
                int.parse(rawClock[3]!))
            .subtract(const Duration(hours: 8));
        if (priorAt.difference(captured.toUtc()) > const Duration(minutes: 1)) {
          priorAt = priorAt.subtract(const Duration(days: 1));
        }
      }
      if (sameImmutableBlock ||
          (priorAt != null &&
              CustomerMessageTime.sameSecond(priorAt, senderAt))) {
        exact.add(receipt! as String);
      }
    }
    for (final receipt in exact) {
      final parent = await inventory.resolveParent(evidence.customer,
          receiptId: receipt, requireCurrentSession: true);
      if (parent != null) {
        await inventory.refineParentClock(evidence.customer,
            parent: parent, senderAt: senderAt);
      }
    }
    return inventory.findTimeParent(evidence.customer, senderAt);
  }

  /// Group only a proven continuation of the same visible card. An unrelated
  /// older ready video, a clock guess or a matching asset hash cannot close it.
  Future<Map<OcrVisualRegion, (MediaParent, DateTime, String)>>
      clippedPendingCards(
          ViewportEvidence evidence, OcrInspection inspection) async {
    final session = database.currentAutomationSessionId;
    if (session == null ||
        evidence.metadata['automationSessionId'] != session ||
        inspection.activeCustomerId != evidence.customer) return {};
    final inventory = CustomerMediaInventory(database);
    final pending = {
      for (final item in await inventory.pendingMediaForTask(evidence.customer))
        if (item['identityAmbiguous'] != true &&
            const {'image', 'video', 'unknown'}.contains(item['kind']) &&
            item['senderAt'] is DateTime)
          item['receiptId'] as String: item,
    };
    if (pending.isEmpty) return {};
    final db = await database.database;
    final rows = await db.query('media_capture_audit',
        where: 'customer=? AND state!=?',
        whereArgs: [evidence.customer, 'session_archived'],
        orderBy: 'updated_at_ms DESC',
        limit: 160);
    final projections =
        <String, (OcrVisualRegion, MediaParent, DateTime, String)>{};
    final ambiguous = <String>{};
    for (final row in rows) {
      final previous = jsonDecode(row['details']! as String) as Map;
      final receipt = previous['mediaReceiptId'];
      final item = pending[receipt];
      final context = previous['occurrenceContext'];
      final geometry = previous['region'];
      final captured = DateTime.tryParse('${previous['capturedAt']}');
      if (item == null ||
          context is! Map ||
          geometry is! List ||
          geometry.length != 4 ||
          geometry.any((v) => v is! num) ||
          context['headerKey'] == null ||
          context['cardCount'] != 1 ||
          previous['automationSessionId'] != session ||
          captured == null ||
          !captured.isBefore(evidence.capturedAt)) continue;
      final old = geometry.cast<num>().map((n) => n.toDouble()).toList();
      final part = MediaCardOccurrenceContext.fromMap(context)
          .projectClippedCard(
              inspection,
              OcrVisualRegion(
                  x: old[0],
                  y: old[1],
                  width: old[2],
                  height: old[3],
                  confidence: 1));
      if (part == null) continue;
      final oldProjection = projections[receipt];
      if (oldProjection != null) {
        final prior = oldProjection.$1;
        if ((prior.y + prior.height - part.y - part.height).abs() > .018 ||
            (prior.x - part.x).abs() > .012 ||
            (prior.width - part.width).abs() > .022) {
          ambiguous.add(receipt as String);
        }
        continue;
      }
      final parent = await inventory.resolveParent(evidence.customer,
          receiptId: receipt as String, requireCurrentSession: true);
      if (parent == null ||
          await database.isMessageFormallyAnswered(
              evidence.customer, parent.messageId)) continue;
      projections[receipt] =
          (part, parent, item['senderAt'] as DateTime, item['kind'] as String);
    }
    final matches = projections.entries
        .where((entry) => !ambiguous.contains(entry.key))
        .map((entry) => entry.value);
    return {
      for (final entry in matches)
        if (!matches.any((other) =>
            other.$2.receiptId != entry.$2.receiptId &&
            (other.$1.x - entry.$1.x).abs() < .045))
          entry.$1: (entry.$2, entry.$3, entry.$4),
    };
  }

  Future<Map<String, Object?>> groupUnbound(
      ViewportEvidence evidence, OcrVisualRegion region, String id,
      {OcrInspection? inspection,
      Iterable<OcrVisualRegion>? physicalCards}) async {
    final session = database.currentAutomationSessionId;
    if (session != null &&
        evidence.metadata['automationSessionId'] != session) {
      return const {};
    }
    final db = await database.database;
    final current = (await db.query('media_capture_audit',
            where: 'observation_id=?', whereArgs: [id]))
        .single;
    final own = Map<String, Object?>.from(
        jsonDecode(current['details']! as String) as Map);
    own.putIfAbsent('observationGroupId', () => id);
    final senderClock = inspection == null
        ? null
        : const OcrCaptureExtractor()
            .mediaClockForRegion(inspection, region)
            .sentAt;
    if (senderClock != null) {
      final key =
          CustomerMessageTime.occurrenceKey(evidence.customer, senderClock);
      own['messageTimeKey'] = key;
      own['observationGroupId'] = key;
      own['senderClock'] =
          CustomerMessageTime.second(senderClock).toIso8601String();
      if (own['mediaReceiptId'] case final String previousReceipt) {
        final previousClock = await CustomerMediaInventory(database)
            .recordedSenderTime(evidence.customer, previousReceipt);
        if (previousClock != null &&
            !CustomerMessageTime.sameSecond(previousClock, senderClock)) {
          // A stale physical association cannot move an established message
          // to another timestamp when the current header becomes readable.
          own.remove('parentMessageId');
          own.remove('resolvedMessageId');
          own.remove('mediaReceiptId');
          own['attributionPending'] = true;
        }
      }
      final timedParent = await CustomerMediaInventory(database)
              .findTimeParent(evidence.customer, senderClock) ??
          await _legacyParentAtTimestamp(
              evidence, inspection!, region, own, senderClock);
      final startedAt = database.automationSessionStartedAt;
      if (startedAt != null &&
          CustomerMessageTime.second(senderClock)
              .isBefore(CustomerMessageTime.second(startedAt)) &&
          timedParent?.isCurrentSession != true) {
        final oldProof = own.remove('liveArrivalProof');
        if (oldProof != null) own['historicalArrivalObservation'] = oldProof;
        await db.update('media_capture_audit',
            {'details': jsonEncode(own), 'state': 'baseline'},
            where: 'observation_id=?', whereArgs: [id]);
        return {...own, 'state': 'baseline'};
      }
      if (timedParent != null) {
        own.addAll({
          'parentMessageId': timedParent.messageId,
          'mediaReceiptId': timedParent.receiptId,
          'attributionPending': false,
        });
        await db.update('media_capture_audit', {'details': jsonEncode(own)},
            where: 'observation_id=?', whereArgs: [id]);
        return own;
      }
      // Keep the original live-arrival proof when this second is observed in
      // another frame. Physical representation IDs cannot create new business.
      final timed = await db.query('media_capture_audit',
          where: 'customer=? AND observation_id!=? AND state!=?',
          whereArgs: [evidence.customer, id, 'session_archived']);
      for (final row in timed) {
        final prior = jsonDecode(row['details']! as String) as Map;
        final proof = prior['liveArrivalProof'];
        if (prior['automationSessionId'] == session &&
            prior['messageTimeKey'] == key &&
            proof is Map &&
            proof['sessionId'] == session) {
          own['liveArrivalProof'] = {
            ...proof,
            'observationGroupId': key,
            'occurrenceKey': key,
            'senderAt':
                CustomerMessageTime.second(senderClock).toIso8601String()
          };
          break;
        }
      }
      // A readable message time establishes its business record. The old
      // cross-frame/pixel matcher below is only for unclocked observations;
      // it must not delay this record or replace the timestamp by an asset ID.
      final ownership = IncomingMessageOwnership.inspect(
          inspection!, evidence.customer, region,
          physicalCards: physicalCards);
      if (ownership != null) own['incomingMediaOwnership'] = ownership.toMap();
      own['occurrenceContext'] = MediaCardOccurrenceContext.inspect(
              inspection, evidence.customer, region,
              physicalCards: physicalCards)
          .toMap();
      if (own.remove('ownershipAmbiguous') == true) {
        own['assetAttributionAmbiguous'] = true;
      }
      own.remove('candidateParentIds');
      final authorized = LiveMediaArrival.admitsCurrentTimestamp(
          evidence: evidence,
          inspection: inspection,
          senderAt: senderClock,
          sessionStartedAt: database.automationSessionStartedAt);
      final state = authorized && current['state'] == 'baseline'
          ? 'discovered'
          : current['state'];
      await db.update(
          'media_capture_audit',
          {
            'details': jsonEncode(own),
            if (state != current['state']) 'state': state
          },
          where: 'observation_id=?',
          whereArgs: [id]);
      return {...own, 'state': state};
    }
    if (inspection != null) {
      final ownership = IncomingMessageOwnership.inspect(
          inspection, evidence.customer, region,
          physicalCards: physicalCards);
      if (ownership != null) own['incomingMediaOwnership'] = ownership.toMap();
      own['occurrenceContext'] = MediaCardOccurrenceContext.inspect(
              inspection, evidence.customer, region,
              physicalCards: physicalCards)
          .toMap();
    }
    final ownContext = own['occurrenceContext'] is Map
        ? MediaCardOccurrenceContext.fromMap(own['occurrenceContext']! as Map)
        : null;
    if (ownContext?.hasVerifiedIncomingCard == true) {
      own['cardOccurrenceProven'] = true;
    }
    if ((own['occurrenceContext'] as Map?)?['explicitVideo'] == true ||
        await _hasVideoOwner(own, evidence.customer, session)) {
      own['videoOccurrenceProven'] = true;
    }
    // Persist identity even while no owner exists yet. A following immutable
    // frame can then reuse this group during registration, before acquisition
    // or original-video processing finishes.
    await db.update('media_capture_audit', {'details': jsonEncode(own)},
        where: 'observation_id=?', whereArgs: [id]);
    // Repair legacy mixed tuples from the exact inventory parent before a
    // terminal capture state can hide an unfinished loading obligation.
    final pendingImageOwner = await _restoreImageOwner(own, evidence.customer);
    await db.update(
        'media_capture_audit',
        {
          'details': jsonEncode(own),
          if (pendingImageOwner) 'state': 'image_partial'
        },
        where: 'observation_id=?',
        whereArgs: [id]);
    var pendingOwnedObservation = false;
    if (own['parentMessageId'] is String &&
        await database.isCurrentSessionMessage(
            evidence.customer, own['parentMessageId']! as String)) {
      if (own['mediaReceiptId'] case final String receipt) {
        // A receipt can finish after this observation was bound. Its retry
        // must see that exact parent's durable files instead of staying in
        // the early pending-parent return for the rest of the session.
        await resolveStoredReceipt(evidence.customer, receipt);
        final refreshed = (await db.query('media_capture_audit',
                where: 'observation_id=?', whereArgs: [id]))
            .single;
        final refreshedDetails = {
          ...Map<String, Object?>.from(
              jsonDecode(refreshed['details']! as String) as Map),
          'state': refreshed['state'],
        };
        if (!unresolved.contains(refreshed['state']) && !pendingImageOwner) {
          return refreshedDetails;
        }
        own.addAll(refreshedDetails);
        pendingOwnedObservation = true;
      }
      if (!pendingOwnedObservation) return own;
    }
    if (!pendingOwnedObservation &&
        !const {...unresolved, 'baseline'}.contains(current['state'])) {
      return own;
    }
    final preview = await frozenCardPreview(evidence, region);
    if (preview == null) return own;
    final previewPath = await (await database.history).saveMedia(
        userId: evidence.customer,
        filename: 'observed_card.png',
        bytes: preview);
    own['previewPath'] = previewPath;
    own.remove('ownershipAmbiguous');
    own.remove('candidateParentIds');
    final uncertainParents = <String>{};
    final chat = evidence.metadata['chatRegion'] as Map?;
    if (chat != null) {
      final rows = await db.query('media_capture_audit',
          where: 'customer=? AND observation_id!=? AND state!=?',
          whereArgs: [evidence.customer, id, 'session_archived'],
          orderBy: 'updated_at_ms DESC');
      for (final row in rows) {
        final previous = jsonDecode(row['details']! as String) as Map;
        final previousParent =
            previous['parentMessageId'] ?? previous['resolvedMessageId'];
        if (senderClock != null) {
          var priorClock = DateTime.tryParse(
              previous['senderClock']?.toString() ??
                  (previous['incomingMediaOwnership'] as Map?)?['senderAt']
                      ?.toString() ??
                  '');
          if (priorClock == null && previous['mediaReceiptId'] is String) {
            priorClock = await CustomerMediaInventory(database)
                .recordedSenderTime(
                    evidence.customer, previous['mediaReceiptId']! as String);
          }
          if (priorClock != null &&
              CustomerMessageTime.second(priorClock) !=
                  CustomerMessageTime.second(senderClock)) {
            continue;
          }
        }
        if (pendingOwnedObservation &&
            previousParent == own['parentMessageId']) {
          continue;
        }
        // Two simultaneously visible cards are two occurrences, even when
        // their pixels and displayed sender seconds are identical.
        if (previous['evidenceId'] == evidence.id) continue;
        if (previous['automationSessionId'] !=
                evidence.metadata['automationSessionId'] ||
            previous['previewPath'] is! String ||
            previous['sourceImagePath'] is! String ||
            previous['region'] is! List) {
          continue;
        }
        final oldRegion = (previous['region'] as List)
            .cast<num>()
            .map((n) => n.toDouble())
            .toList();
        if (oldRegion.length != 4) {
          continue;
        }
        final oldContext = previous['occurrenceContext'] is Map
            ? MediaCardOccurrenceContext.fromMap(
                previous['occurrenceContext']! as Map)
            : null;
        final physicalCurrent = own['incomingMediaOwnership'] is Map
            ? IncomingMessageOwnershipEvidence.fromMap(
                own['incomingMediaOwnership']! as Map)
            : null;
        final physicalPrevious = previous['incomingMediaOwnership'] is Map
            ? IncomingMessageOwnershipEvidence.fromMap(
                previous['incomingMediaOwnership'] as Map)
            : null;
        final ownershipVideoContinuation = physicalCurrent != null &&
            physicalPrevious != null &&
            await _physicalOwnershipContinuation(
                previous, physicalPrevious, own, physicalCurrent,
                currentFrame: await File(evidence.imagePath).readAsBytes(),
                chat: chat);
        final deferred = previous['deferredLiveArrivalCandidate'];
        if (inspection != null &&
            own['parentMessageId'] == null &&
            deferred is Map &&
            (evidence.metadata['unreadArrivalKey'] == null ||
                evidence.metadata['unreadArrivalKey'] ==
                    deferred['unreadArrivalKey']) &&
            await _deferredCardContinuation(
                previous,
                await File(evidence.imagePath).readAsBytes(),
                inspection,
                region,
                chat)) {
          own['observationGroupId'] =
              previous['observationGroupId'] ?? row['observation_id'];
          own['deferredLiveArrivalCandidate'] = deferred;
          own['deferredCandidateContinuationProven'] = true;
          own['deferredCandidateProofObservationId'] = row['observation_id'];
          own['physicalGroupLink'] = {
            'observationId': row['observation_id'],
            'evidenceId': previous['evidenceId'],
            'proof': 'same_sender_glyphs_preceding_pixels_and_physical_card'
          };
          await db.update('media_capture_audit', {'details': jsonEncode(own)},
              where: 'observation_id=?', whereArgs: [id]);
          return own;
        }
        // Asset resemblance cannot make two independently sent bubbles share
        // business ownership. Do this before either visual continuation path.
        if (ownContext != null &&
            oldContext != null &&
            ownContext.conflictsWith(oldContext) &&
            !ownershipVideoContinuation) {
          continue;
        }
        final imageLayout = ownContext != null &&
            oldContext != null &&
            _sameImageLayoutCandidate(oldContext, ownContext);
        final videoProof = own['videoOccurrenceProven'] == true ||
            (previous['occurrenceContext'] as Map?)?['explicitVideo'] == true ||
            await _hasVideoOwner(previous, evidence.customer, session);
        // Native inner crops can move sideways inside one physical image.
        // Preserve the existing video guard; only exact image sender-block
        // candidates proceed to sender/preceding-pixel proof at another ROI x.
        if ((oldRegion[0] - region.x).abs() > .015 &&
            (videoProof || !imageLayout)) {
          continue;
        }
        final videoContinuation = ownContext != null &&
            oldContext != null &&
            ownContext.continuesVideo(oldContext,
                verifiedVideoParent: videoProof);
        if (ownContext != null &&
            oldContext != null &&
            ownContext.toMap()['headerKey'] != null &&
            oldContext.toMap()['headerKey'] != null &&
            ownContext.toMap()['headerKey'] !=
                oldContext.toMap()['headerKey'] &&
            !ownContext.sameSingleIncomingVideoBlock(oldContext,
                verifiedSameSenderGlyphs: true) &&
            !ownContext.sameIncomingImageBlock(oldContext) &&
            !ownershipVideoContinuation) {
          // Different known blocks cannot be joined by old asset pixels.
          // Reject them before decoding full-size historical screenshots.
          continue;
        }
        final oldPreview = File(previous['previewPath']! as String),
            oldFrame = File(previous['sourceImagePath']! as String);
        if (!await oldPreview.exists() || !await oldFrame.exists()) continue;
        final oldBytes = await oldPreview.readAsBytes();
        final oldFrameBytes = await oldFrame.readAsBytes();
        final currentFrameBytes = await File(evidence.imagePath).readAsBytes();
        var verifiedSameSenderGlyphs = false;
        if (!ownershipVideoContinuation &&
            ownContext != null &&
            oldContext != null &&
            ownContext.toMap()['headerKey'] != null &&
            oldContext.toMap()['headerKey'] != null &&
            ownContext.toMap()['headerKey'] !=
                oldContext.toMap()['headerKey']) {
          verifiedSameSenderGlyphs = await _identicalSenderGlyphs(
              oldFrameBytes,
              currentFrameBytes,
              oldContext,
              ownContext,
              evidence.metadata['chatRegion']! as Map);
          // A timestamp digit actually changed in the pixels. Neither asset
          // similarity nor a mostly equal frame may erase that distinct send.
          if (!verifiedSameSenderGlyphs) continue;
        }
        final currentRegion = [region.x, region.y, region.width, region.height];
        final transcript = [
          (chat['left'] as num).toDouble(),
          (chat['top'] as num).toDouble(),
          (chat['right'] as num).toDouble(),
          (chat['bottom'] as num).toDouble()
        ];
        final physicalVideoContinuation = ownershipVideoContinuation ||
            (!videoContinuation || pendingOwnedObservation) &&
                videoProof &&
                ownContext != null &&
                oldContext != null &&
                ownContext.sameSingleIncomingVideoBlock(oldContext,
                    verifiedSameSenderGlyphs: verifiedSameSenderGlyphs) &&
                await _samePhysicalVideoCard(
                    oldFrameBytes,
                    currentFrameBytes,
                    oldRegion,
                    currentRegion,
                    oldContext,
                    ownContext,
                    transcript);
        // OCR may lose the preceding header/prose when it reaches the top
        // edge. Verify the actual sender glyphs, translated photograph and
        // preceding bubble pixels before recovering its existing owner.
        // Matching timestamps and matching image files alone are insufficient.
        final imageTranslation = !videoProof &&
                ownContext != null &&
                oldContext != null &&
                imageLayout
            ? await _imageSenderTranslation(
                oldFrameBytes, currentFrameBytes, oldContext, ownContext, chat)
            : null;
        final physicalImageContinuation = imageTranslation != null &&
            ownContext != null &&
            oldContext != null &&
            await _alignedCardPixels(oldFrameBytes, currentFrameBytes,
                oldRegion, currentRegion, oldContext, ownContext,
                verifiedHeaderShift: imageTranslation) &&
            await _alignedPrecedingInk(
                oldFrameBytes, currentFrameBytes, oldContext, ownContext, chat,
                headerShift: imageTranslation);
        // An unresolved image block can gain its content while OCR loses
        // its borders. Exact sender and preceding pixels must move together;
        // later text below that card is outside this immutable prefix proof.
        final oldLoading =
            imageTranslation != null && await _loadingImagePixels(oldBytes);
        final ownLoading =
            imageTranslation != null && await _loadingImagePixels(preview);
        final loadingOwnerAllowed = (oldLoading &&
                await _loadingOwnerMayContinue(
                    previous, evidence.customer, session)) ||
            (ownLoading &&
                await _loadingOwnerMayContinue(
                    own, evidence.customer, session));
        final physicalLoadingImageContinuation = imageTranslation != null &&
            ownContext != null &&
            oldContext != null &&
            imageLayout &&
            loadingOwnerAllowed &&
            (oldContext.toMap()['precedingKey'] != null &&
                oldContext.toMap()['precedingKey'] ==
                    ownContext.toMap()['precedingKey']) &&
            await _alignedPrecedingInk(
                oldFrameBytes, currentFrameBytes, oldContext, ownContext, chat,
                headerShift: imageTranslation);
        final imageContinuation = !videoContinuation &&
            ownContext != null &&
            oldContext != null &&
            ownContext.sameIncomingImageBlock(oldContext) &&
            ((await MediaVisualMatcher.correspondenceScore(oldBytes, preview) ??
                        double.infinity) <=
                    .018 ||
                await _alignedCardPixels(oldFrameBytes, currentFrameBytes,
                    oldRegion, currentRegion, oldContext, ownContext));
        final continuation = physicalVideoContinuation ||
            physicalImageContinuation ||
            physicalLoadingImageContinuation ||
            videoContinuation ||
            imageContinuation ||
            await MediaVisualMatcher.frozenCardContinuation(
                previousCard: oldBytes,
                currentCard: preview,
                previousFrame: oldFrameBytes,
                currentFrame: currentFrameBytes,
                previousRegion: oldRegion,
                currentRegion: currentRegion,
                transcript: transcript);
        if (!continuation &&
            !await MediaVisualMatcher.loadingCardTransition(
                previousCard: oldBytes,
                currentCard: preview,
                previousFrame: oldFrameBytes,
                currentFrame: currentFrameBytes,
                previousRegion: oldRegion,
                currentRegion: currentRegion,
                transcript: transcript)) {
          if (!pendingOwnedObservation &&
              videoProof &&
              ownContext != null &&
              oldContext != null &&
              ownContext.sameSingleIncomingVideoBlock(oldContext) &&
              previousParent is String &&
              await database.isCurrentSessionMessage(
                  evidence.customer, previousParent)) {
            uncertainParents.add(previousParent);
          }
          continue;
        }
        if (pendingOwnedObservation &&
            previousParent is String &&
            previousParent != own['parentMessageId']) {
          // Repair two already admitted roots only with immutable physical
          // evidence, never with the legacy pixel/clock fallback alone.
          if ((!physicalVideoContinuation &&
                  !physicalLoadingImageContinuation) ||
              previous['mediaReceiptId'] is! String) {
            continue;
          }
          own['sameBubbleOwnerProof'] = {
            'kind': ownershipVideoContinuation
                ? 'same_physical_video_ownership_pixels'
                : physicalVideoContinuation
                    ? 'same_physical_video_sender_block'
                    : 'same_physical_image_loading_sender_block',
            if (ownershipVideoContinuation) ...{
              'verifiedPhysicalPixels': true,
              'physicalOwnerships': [
                physicalCurrent.toMap(),
                physicalPrevious.toMap()
              ],
            },
            if (physicalLoadingImageContinuation) ...{
              'loadingObservationId': oldLoading ? row['observation_id'] : id,
              'verifiedLoadingPixels': true,
              'verifiedSenderTranslation': imageTranslation,
              'verifiedPrecedingPixels': true,
            },
            'verifiedSameSenderGlyphs': verifiedSameSenderGlyphs,
            'observationIds': [id, row['observation_id']],
            'evidenceIds': [evidence.id, previous['evidenceId']],
            'ownerReceipts': [
              own['mediaReceiptId'],
              previous['mediaReceiptId']
            ],
            'ownerMessages': [own['parentMessageId'], previousParent],
          };
          await db.update('media_capture_audit', {'details': jsonEncode(own)},
              where: 'observation_id=?', whereArgs: [id]);
          return own;
        }
        if (!pendingOwnedObservation || previousParent != null) {
          own['observationGroupId'] =
              previous['observationGroupId'] ?? row['observation_id'];
        }
        own['physicalGroupLink'] = {
          'observationId': row['observation_id'],
          'evidenceId': previous['evidenceId'],
          'proof': physicalImageContinuation
              ? 'same_image_sender_and_preceding_bubble_pixels'
              : physicalLoadingImageContinuation
                  ? 'same_image_loading_sender_and_preceding_pixels'
                  : imageContinuation
                      ? 'same_image_sender_block_and_pixels'
                      : videoContinuation
                          ? 'same_video_sender_block'
                          : 'same_immutable_card_pixels',
        };
        // A later crop may be processed after newer text has moved the live
        // frontier. Keep the original, card-specific admission proof; this
        // correspondence does not create a new arrival or infer one by clock.
        if (previous['deferredLiveArrivalCandidate'] is Map &&
            (physicalVideoContinuation || physicalImageContinuation)) {
          own['deferredLiveArrivalCandidate'] =
              previous['deferredLiveArrivalCandidate'];
          own['deferredCandidateContinuationProven'] = true;
          own['deferredCandidateProofObservationId'] = row['observation_id'];
        }
        if (previous['liveArrivalProof'] is Map &&
            own['liveArrivalProof'] == null) {
          own['liveArrivalProof'] = previous['liveArrivalProof'];
        }
        if (videoProof) own['videoOccurrenceProven'] = true;
        if (previous['cardOccurrenceProven'] == true) {
          own['cardOccurrenceProven'] = true;
        }
        if (physicalVideoContinuation) {
          own['representationOwnershipProof'] =
              'same_physical_video_sender_block';
        } else if (videoContinuation) {
          own['representationOwnershipProof'] = 'same_video_sender_block';
        } else if (imageContinuation ||
            physicalImageContinuation ||
            physicalLoadingImageContinuation) {
          own['representationOwnershipProof'] = physicalImageContinuation
              ? 'same_image_sender_and_preceding_bubble_pixels'
              : physicalLoadingImageContinuation
                  ? 'same_image_loading_sender_and_preceding_pixels'
                  : 'same_image_sender_block_and_pixels';
        }
        // An unowned match is already a stable bubble identity. Do not wait
        // until a later capture resolves a parent to publish that identity.
        await db.update('media_capture_audit', {'details': jsonEncode(own)},
            where: 'observation_id=?', whereArgs: [id]);
        // A resolved observation normally also has parentMessageId. Resolve
        // it before the pending-parent branch; otherwise a proved old card is
        // rebound but stays unbound forever and is rescanned each cycle.
        final resolved = previous['resolvedMessageId'] as String?;
        final persisted = resolved != null &&
            await database.isCurrentSessionMessage(evidence.customer, resolved);
        if (row['state'] == 'baseline' || persisted) {
          final resolvedDetails = <String, Object?>{
            ...own,
            if (previous['parentMessageId'] != null)
              'parentMessageId': previous['parentMessageId'],
            if (previous['mediaReceiptId'] != null)
              'mediaReceiptId': previous['mediaReceiptId'],
            if (resolved != null) 'resolvedMessageId': resolved,
            'attributionPending': false,
            'reason': 'same_immutable_card_occurrence',
          };
          final state = row['state']! as String;
          await finish(id, state, resolvedDetails);
          await _resolveProvenGroup(evidence.customer,
              group: own['observationGroupId'],
              state: state,
              details: resolvedDetails,
              session: session);
          return {...resolvedDetails, 'state': state};
        }
        final parent = previous['parentMessageId'] as String?;
        if (parent != null &&
            await database.isCurrentSessionMessage(evidence.customer, parent)) {
          await finish(id, current['state']! as String, {
            ...own,
            'parentMessageId': parent,
            'mediaReceiptId': previous['mediaReceiptId'],
            'attributionPending': false,
            'reason': 'same_immutable_card_occurrence',
          });
          return {
            ...own,
            'parentMessageId': parent,
            'mediaReceiptId': previous['mediaReceiptId'],
          };
        }
        // Another unowned crop is only a correspondence link. Continue to a
        // stored parent instead of allowing the newest unbound row to hide it.
      }
    }
    if (database.currentAutomationSessionId != session) return own;
    if (uncertainParents.isNotEmpty) {
      own['ownershipAmbiguous'] = true;
      own['candidateParentIds'] = uncertainParents.toList();
    }
    await db.update('media_capture_audit', {'details': jsonEncode(own)},
        where: 'observation_id=?', whereArgs: [id]);
    return own;
  }

  /// A broad untyped message is a business duty, not a second attachment.
  /// Only one real play card within that exact incoming block may refine it.
  /// Unlike generic card matching, this deliberately supports two nested ROIs
  /// from the same immutable frame, while rejecting two physical cards.
  Future<bool> proveUnknownVideoOwner(ViewportEvidence evidence,
      OcrInspection inspection, OcrVisualRegion region, String observationId,
      {required Iterable<OcrVisualRegion> physicalCards}) async {
    final session = database.currentAutomationSessionId;
    if (session == null ||
        evidence.metadata['automationSessionId'] != session ||
        inspection.activeCustomerId != evidence.customer) {
      return false;
    }
    final typed = IncomingMessageOwnership.inspect(
        inspection, evidence.customer, region,
        physicalCards: physicalCards);
    if (typed == null ||
        !typed.ownsMedia ||
        !typed.explicitVideo ||
        !typed.uniquePhysicalCard) {
      return false;
    }
    final db = await database.database;
    final rows = await db.query('media_capture_audit',
        where:
            'customer=? AND state NOT IN (\'baseline\',\'session_archived\')',
        whereArgs: [evidence.customer]);
    final ownRow =
        rows.where((r) => r['observation_id'] == observationId).firstOrNull;
    if (ownRow == null) return false;
    final own = Map<String, Object?>.from(
        jsonDecode(ownRow['details']! as String) as Map);
    final matches = <({
      Map row,
      Map<String, Object?> details,
      IncomingMessageOwnershipEvidence ownership,
      bool sameFrame
    })>[];
    for (final row in rows) {
      if (row['observation_id'] == observationId) continue;
      final holder = Map<String, Object?>.from(
          jsonDecode(row['details']! as String) as Map);
      if (holder['automationSessionId'] != session ||
          holder['parentMessageId'] is! String ||
          holder['mediaReceiptId'] is! String ||
          holder['region'] is! List) {
        continue;
      }
      final pending = await db.rawQuery(
          '''SELECT m.item_id FROM customer_media_items m
        JOIN automation_session_messages w ON w.session_id=m.admission_session_id
          AND w.user_id=m.customer AND w.message_id=m.message_id
        WHERE m.customer=? AND m.item_id=? AND m.message_id=?
          AND m.admission_session_id=? AND m.canonical_id IS NULL
          AND m.identity_ambiguous=0 AND m.kind='unknown' AND m.media_json='[]'
          AND w.response_state='pending' ''',
          [
            evidence.customer,
            holder['mediaReceiptId'],
            holder['parentMessageId'],
            session
          ]);
      if (pending.length != 1) continue;
      final box = (holder['region'] as List).cast<num>();
      if (box.length != 4) continue;
      final holderRegion = OcrVisualRegion(
          x: box[0].toDouble(),
          y: box[1].toDouble(),
          width: box[2].toDouble(),
          height: box[3].toDouble(),
          confidence: 0);
      final sameFrame = holder['evidenceId'] == evidence.id;
      final original = sameFrame
          ? inspection
          : await _ownershipInspection(holder, evidence.customer, session);
      if (original == null) continue;
      final probe = _storedHolderProbe(original, holderRegion);
      if (probe == null) continue;
      final other = IncomingMessageOwnership.inspect(
          original, evidence.customer, probe,
          physicalCards: sameFrame ? physicalCards : [probe]);
      if (other == null ||
          !other.uniquePhysicalCard ||
          !other.explicitVideo ||
          !_sameRegion(holderRegion, other.bodyRegion, tolerance: .000011)) {
        continue;
      }
      // A genuine media card's parent cannot be stolen by a broad placeholder.
      if (own['parentMessageId'] is String &&
          own['parentMessageId'] != holder['parentMessageId']) {
        continue;
      }
      final proved = sameFrame
          ? typed.sameBlockAs(other)
          : await _physicalOwnershipContinuation(holder, other, own, typed,
              currentFrame: inspection.image,
              chat: evidence.metadata['chatRegion'] as Map?);
      if (!proved) continue;
      matches.add(
          (row: row, details: holder, ownership: other, sameFrame: sameFrame));
    }
    if (matches.map((m) => m.details['parentMessageId']).toSet().length != 1) {
      return false;
    }
    final match = matches.first;
    own['incomingMediaOwnership'] = typed.toMap();
    own['unknownMediaOwnerProof'] = {
      'version': 1,
      'kind': 'one_physical_video_refines_unknown_block',
      'customer': evidence.customer,
      'sessionId': session,
      'typedObservationId': observationId,
      'holderObservationId': match.row['observation_id'],
      'typedEvidenceId': evidence.id,
      'holderEvidenceId': match.details['evidenceId'],
      'ownerReceiptId': match.details['mediaReceiptId'],
      'ownerMessageId': match.details['parentMessageId'],
      'typedOwnership': typed.toMap(),
      'holderOwnership': match.ownership.toMap(),
      'sameFrozenBlock': match.sameFrame,
      'verifiedPhysicalPixels': !match.sameFrame,
    };
    await db.update('media_capture_audit', {'details': jsonEncode(own)},
        where: 'observation_id=?', whereArgs: [observationId]);
    return database.currentAutomationSessionId == session;
  }

  // Audit ROIs are independently quantized to five decimal places. Their
  // summed far edge can exceed the original chat boundary by at most one
  // quantum. Restore only that serialization error for a fresh proof probe;
  // preserve the durable ROI and require the exact sender body's geometry
  // again afterwards. A genuinely out-of-chat holder remains ineligible.
  OcrVisualRegion? _storedHolderProbe(
      OcrInspection inspection, OcrVisualRegion stored) {
    final layout = OcrChatLayout(inspection);
    const quantum = .000010000001;
    var left = stored.x, top = stored.y;
    var right = stored.x + stored.width, bottom = stored.y + stored.height;
    if (left < layout.left) {
      if (layout.left - left > quantum) return null;
      left = layout.left;
    }
    if (top < layout.top) {
      if (layout.top - top > quantum) return null;
      top = layout.top;
    }
    if (right > layout.right) {
      if (right - layout.right > quantum) return null;
      right = layout.right;
    }
    if (bottom > layout.bottom) {
      if (bottom - layout.bottom > quantum) return null;
      bottom = layout.bottom;
    }
    if (right <= left || bottom <= top) return null;
    return OcrVisualRegion(
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
        confidence: stored.confidence);
  }

  bool _sameRegion(OcrVisualRegion a, OcrVisualRegion b,
          {double tolerance = .000001}) =>
      (a.x - b.x).abs() <= tolerance &&
      (a.y - b.y).abs() <= tolerance &&
      (a.width - b.width).abs() <= tolerance &&
      (a.height - b.height).abs() <= tolerance;

  Future<OcrInspection?> _ownershipInspection(
      Map details, String customer, String session) async {
    final row = (await (await database.database).query('capture_evidence',
            where: 'id=? AND customer=? AND state!=?',
            whereArgs: [details['evidenceId'], customer, 'session_archived']))
        .firstOrNull;
    if (row == null) return null;
    final frame = ViewportEvidence.fromJson(row['payload']! as String);
    if (frame.metadata['automationSessionId'] != session) return null;
    try {
      final raw = jsonDecode(
          await File('${frame.manifestPath}.ocr.json').readAsString()) as Map;
      if (raw['evidenceId'] != frame.id ||
          raw['activeCustomerId'] != customer ||
          raw['capturedAtMs'] != frame.capturedAt.millisecondsSinceEpoch) {
        return null;
      }
      return OcrInspection.fromMap({
        ...Map<String, Object?>.from(raw),
        'pngBase64': base64Encode(await File(frame.imagePath).readAsBytes())
      });
    } on FileSystemException {
      return null;
    }
  }

  /// Same pixels, not the OCR spelling/time, can connect a provisional sender
  /// to its later readable form. Content alignment locates the real header band
  /// even when the earlier OCR box was tall/cropped. A changed timestamp glyph
  /// or a different neighbouring bubble must fail this comparison.
  Future<bool> _physicalOwnershipContinuation(
      Map oldDetails,
      IncomingMessageOwnershipEvidence old,
      Map currentDetails,
      IncomingMessageOwnershipEvidence current,
      {required Uint8List currentFrame,
      required Map? chat}) async {
    if (chat == null ||
        old.customer != current.customer ||
        !old.uniquePhysicalCard ||
        !current.uniquePhysicalCard ||
        (!old.exactCustomerHeader && !current.exactCustomerHeader)) {
      return false;
    }
    if (old.exactCustomerHeader &&
        current.exactCustomerHeader &&
        old.sentAt != current.sentAt) {
      return false;
    }
    MediaCardOccurrenceContext? exactBlockContext(
        Map details, IncomingMessageOwnershipEvidence ownership) {
      final value = details['occurrenceContext'];
      if (!ownership.exactCustomerHeader || value is! Map) return null;
      final top = (value['headerTop'] as num?)?.toDouble();
      final bottom = (value['headerBottom'] as num?)?.toDouble();
      if (value['headerKey'] is! String ||
          !(value['headerKey'] as String)
              .startsWith('incoming:${ownership.customer}:') ||
          top == null ||
          bottom == null ||
          (top - ownership.header.y).abs() > .000011 ||
          (bottom - ownership.header.y - ownership.header.height).abs() >
              .000011) {
        return null;
      }
      return MediaCardOccurrenceContext.fromMap(value);
    }

    final previousBlock = exactBlockContext(oldDetails, old);
    final currentBlock = exactBlockContext(currentDetails, current);
    // The same file and sender-second can be sent in two visible blocks.
    // Their explicit neighbouring-header/divider conflict outranks matching
    // pixels. A provisional OCR box which accidentally points at an older
    // text header cannot impose that older block on the physical play card.
    if (previousBlock != null &&
        currentBlock != null &&
        currentBlock.conflictsWith(previousBlock)) {
      return false;
    }
    final path = oldDetails['sourceImagePath'];
    if (path is! String || !await File(path).exists()) return false;
    final previousFrame = await File(path).readAsBytes();
    Future<({int width, int height, Uint8List pixels})> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        return (
          width: image.width,
          height: image.height,
          pixels:
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
        );
      } finally {
        image.dispose();
      }
    }

    final a = await decode(previousFrame), b = await decode(currentFrame);
    if (a.width != b.width || a.height != b.height) return false;
    final nominal =
        ((current.mediaContentRegion.y - old.mediaContentRegion.y) * a.height)
            .round();
    final reference = current.exactCustomerHeader ? current.header : old.header;
    bool ink(Uint8List pixels, int i) =>
        math.min(pixels[i], math.min(pixels[i + 1], pixels[i + 2])) < 150;
    Map<String, Object?> context(IncomingMessageOwnershipEvidence proof) => {
          'headerTop': proof.header.y,
          'headerBottom': proof.header.y + proof.header.height
        };
    final oldContext = MediaCardOccurrenceContext.fromMap(context(old));
    final newContext = MediaCardOccurrenceContext.fromMap(context(current));
    for (var dy = nominal - 2; dy <= nominal + 2; dy++) {
      final top = (reference.y * a.height).floor() -
          3 +
          (current.exactCustomerHeader ? 0 : dy);
      final bottom = ((reference.y + reference.height) * a.height).ceil() +
          3 +
          (current.exactCustomerHeader ? 0 : dy);
      if (top < 0 ||
          top - dy < 0 ||
          bottom > a.height ||
          bottom - dy > a.height) {
        continue;
      }
      var count = 0, different = false;
      for (var y = top; y < bottom && !different; y++) {
        for (var x = (reference.x * a.width).floor() - 3;
            x < ((reference.x + reference.width) * a.width).ceil() + 3;
            x++) {
          if (x < 0 || x >= a.width) {
            different = true;
            break;
          }
          final ai = ((y - dy) * a.width + x) * 4, bi = (y * b.width + x) * 4;
          final oldInk = ink(a.pixels, ai), newInk = ink(b.pixels, bi);
          if (oldInk || newInk) count++;
          if (oldInk != newInk &&
              !_sameSubpixelEdge(a.pixels, ai, b.pixels, bi)) {
            different = true;
            break;
          }
        }
      }
      if (different || count < 50) continue;
      final ar = old.mediaContentRegion, br = current.mediaContentRegion;
      if (await _alignedCardPixels(
              previousFrame,
              currentFrame,
              [ar.x, ar.y, ar.width, ar.height],
              [br.x, br.y, br.width, br.height],
              oldContext,
              newContext,
              verifiedHeaderShift: dy) &&
          await _alignedPrecedingInk(
              previousFrame, currentFrame, oldContext, newContext, chat,
              headerShift: dy)) {
        return true;
      }
    }
    return false;
  }

  // A foreground threshold may cross at an antialiased glyph edge when the
  // translucent watermark changes tint. Compare that individual pixel's RGB,
  // never a whole-header average: an added/removed timestamp stroke remains a
  // hard conflict. The recorded cc8e/ea6e header differs at just two such edges
  // (maximum channel deltas 9 and 10), while its actual ink is unchanged.
  bool _sameSubpixelEdge(Uint8List a, int ai, Uint8List b, int bi) {
    for (var channel = 0; channel < 3; channel++) {
      if ((a[ai + channel] - b[bi + channel]).abs() > 12) return false;
    }
    return true;
  }

  Future<bool> _deferredCardContinuation(Map previous, Uint8List currentFrame,
      OcrInspection inspection, OcrVisualRegion region, Map chat) async {
    final candidate = previous['deferredLiveArrivalCandidate'];
    if (candidate is! Map ||
        candidate['admissionGranted'] != false ||
        candidate['sessionId'] != database.currentAutomationSessionId ||
        previous['parentMessageId'] != null ||
        previous['sourceImagePath'] is! String ||
        previous['region'] is! List) {
      return false;
    }
    final clock =
        const OcrCaptureExtractor().mediaClockForRegion(inspection, region);
    if (clock.source != 'ocr_media_sender_header' ||
        clock.sentAt == null ||
        clock.headerTop == null ||
        clock.headerBottom == null) {
      return false;
    }
    final path = File(previous['sourceImagePath']! as String);
    if (!await path.exists()) return false;
    final oldFrame = await path.readAsBytes();
    final oldBox = (previous['region'] as List)
        .cast<num>()
        .map((n) => n.toDouble())
        .toList();
    if (oldBox.length != 4) return false;
    final oldCodec = await ui.instantiateImageCodec(oldFrame);
    final oldImage = (await oldCodec.getNextFrame()).image;
    oldCodec.dispose();
    final height = oldImage.height;
    oldImage.dispose();
    final nominal = ((region.y - oldBox[1]) * height).round();
    final next = MediaCardOccurrenceContext.fromMap(
        {'headerTop': clock.headerTop, 'headerBottom': clock.headerBottom});
    final currentBox = [region.x, region.y, region.width, region.height];
    final oldPreview = previous['previewPath'] is String &&
            await File(previous['previewPath']! as String).exists()
        ? await File(previous['previewPath']! as String).readAsBytes()
        : null;
    // Do not derive occurrence identity from card resemblance. The actual
    // current sender glyphs and preceding message pixels must align first.
    for (var dy = nominal - 12; dy <= nominal + 12; dy++) {
      final before = MediaCardOccurrenceContext.fromMap({
        'headerTop': clock.headerTop! - dy / height,
        'headerBottom': clock.headerBottom! - dy / height
      });
      if (!await _identicalSenderGlyphs(
          oldFrame, currentFrame, before, next, chat)) {
        continue;
      }
      if (!await _alignedPrecedingInk(
          oldFrame, currentFrame, before, next, chat,
          headerShift: dy)) {
        continue;
      }
      if (await _alignedCardPixels(
          oldFrame, currentFrame, oldBox, currentBox, before, next,
          verifiedHeaderShift: dy)) {
        return true;
      }
      if (oldPreview != null && await _loadingImagePixels(oldPreview)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _loadingImagePixels(Uint8List preview) async {
    if (await MediaVisualMatcher.isLoadingCover(preview)) return true;
    // A fallback includes the narrow white photo placeholder, grey transcript
    // and sometimes the emoji toolbar. Its centre is therefore not the image.
    // Require a sizeable genuinely white panel near the bubble's left edge;
    // JD's grey empty transcript cannot satisfy this test. This is only loading
    // evidence: exact sender/preceding pixels and the unfinished parent checks
    // still have to prove the physical occurrence separately.
    final codec = await ui.instantiateImageCodec(preview);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    try {
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final pixels =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final width = image.width, height = image.height;
      final windowWidth = math.max(32, (width * .075).ceil());
      final windowHeight = math.max(48, (height * .28).ceil());
      if (windowWidth > width || windowHeight > height) return false;
      final stride = width + 1;
      final integral = Uint32List((height + 1) * stride);
      for (var y = 0; y < height; y++) {
        var count = 0;
        for (var x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          final low =
              math.min(pixels[i], math.min(pixels[i + 1], pixels[i + 2]));
          final high =
              math.max(pixels[i], math.max(pixels[i + 1], pixels[i + 2]));
          if (low >= 248 && high - low <= 4) count++;
          integral[(y + 1) * stride + x + 1] =
              integral[y * stride + x + 1] + count;
        }
      }
      final right = math.min(width - windowWidth, (width * .30).floor());
      final bottom = math.min(height - windowHeight, (height * .5).floor());
      final area = windowWidth * windowHeight;
      for (var y = 0; y <= bottom; y += 2) {
        for (var x = 0; x <= right; x += 2) {
          final white =
              integral[(y + windowHeight) * stride + x + windowWidth] -
                  integral[y * stride + x + windowWidth] -
                  integral[(y + windowHeight) * stride + x] +
                  integral[y * stride + x];
          if (white / area >= .995) return true;
        }
      }
      return false;
    } finally {
      image.dispose();
    }
  }

  Future<bool> _restoreImageOwner(
      Map<String, Object?> details, String customer) async {
    final parent = details['parentMessageId'];
    final session = database.currentAutomationSessionId;
    if (parent is! String || session == null) return false;
    final db = await database.database;
    final row = (await db.query('customer_media_items',
            where: 'customer=? AND message_id=? AND admission_session_id=?',
            whereArgs: [customer, parent, session]))
        .firstOrNull;
    if (row == null || row['kind'] == 'video' || row['kind'] == 'text') {
      return false;
    }
    final owner = await CustomerMediaInventory(database).resolveParent(customer,
        receiptId: row['item_id']! as String, requireCurrentSession: true);
    if (owner == null) return false;
    final mismatched = details['mediaReceiptId'] != owner.receiptId ||
        details['parentMessageId'] != owner.messageId;
    if (mismatched) {
      details['legacyOwnerTuple'] = {
        'parentMessageId': details['parentMessageId'],
        'mediaReceiptId': details['mediaReceiptId'],
        'observationGroupId': details['observationGroupId'],
      };
      details['parentMessageId'] = owner.messageId;
      details['mediaReceiptId'] = owner.receiptId;
      if (owner.admissionKey?.startsWith('bubble:') == true) {
        details['observationGroupId'] = owner.admissionKey!.substring(7);
        if (details['liveArrivalProof'] case final Map arrival) {
          details['originalLiveArrivalProof'] ??= arrival;
          details['liveArrivalProof'] = {
            ...arrival,
            'observationGroupId': owner.admissionKey!.substring(7),
            'occurrenceKey': owner.admissionKey,
          };
        }
      }
    }
    final pending = await _loadingOwnerMayContinue(details, customer, session);
    if (mismatched && pending) {
      details.remove('resolvedMessageId');
      details['captureResolved'] = false;
      details['state'] = 'image_partial';
    }
    return pending && row['state'] != 'ready';
  }

  Future<bool> _loadingOwnerMayContinue(
      Map details, String customer, String? session) async {
    final parent = details['parentMessageId'] ?? details['resolvedMessageId'];
    // An unowned immutable loading card still needs the normal AX/frontier
    // admission proof. Correspondence alone never admits it.
    if (parent == null) return true;
    if (parent is! String || session == null) return false;
    final rows = await (await database.database).rawQuery('''
      SELECT m.state,m.kind,w.response_state FROM customer_media_items m
      JOIN automation_session_messages w ON w.session_id=m.admission_session_id
        AND w.user_id=m.customer AND w.message_id=m.message_id
      WHERE m.customer=? AND m.message_id=? AND m.admission_session_id=?
        AND m.canonical_id IS NULL AND m.identity_ambiguous=0''',
        [customer, parent, session]);
    return rows.length == 1 &&
        rows.single['kind'] != 'video' &&
        rows.single['kind'] != 'text' &&
        rows.single['state'] != 'ready' &&
        rows.single['response_state'] != 'answered';
  }

  bool _sameImageLayoutCandidate(
      MediaCardOccurrenceContext previous, MediaCardOccurrenceContext current) {
    final a = previous.toMap(), b = current.toMap();
    if (!previous.hasVerifiedIncomingCard ||
        !current.hasVerifiedIncomingCard ||
        current.conflictsWith(previous) ||
        a['headerKey'] != b['headerKey'] ||
        a['headerCount'] != 1 ||
        b['headerCount'] != 1 ||
        a['cardCount'] != 1 ||
        b['cardCount'] != 1 ||
        a['cardSlot'] != 0 ||
        b['cardSlot'] != 0) {
      return false;
    }
    return a['precedingKey'] == null ||
        b['precedingKey'] == null ||
        a['precedingKey'] == b['precedingKey'];
  }

  Future<bool> _alignedPrecedingInk(
      Uint8List oldFrame,
      Uint8List newFrame,
      MediaCardOccurrenceContext oldContext,
      MediaCardOccurrenceContext newContext,
      Map chat,
      {required int headerShift}) async {
    Future<({int width, int height, Uint8List pixels})> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        return (
          width: image.width,
          height: image.height,
          pixels:
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
        );
      } finally {
        image.dispose();
      }
    }

    final a = await decode(oldFrame), b = await decode(newFrame);
    if (a.width != b.width || a.height != b.height) return false;
    final oldTop = (oldContext.toMap()['headerTop'] as num?)?.toDouble();
    final newTop = (newContext.toMap()['headerTop'] as num?)?.toDouble();
    if (oldTop == null || newTop == null) return false;
    final nominal = headerShift;
    final chatTop = ((chat['top']! as num) * a.height).ceil();
    final bottom = (newTop * a.height).floor() - 5;
    final left = ((chat['left']! as num) * a.width).ceil();
    final right = ((chat['right']! as num) * a.width).floor();
    bool ink(Uint8List pixels, int offset) =>
        math.min(
            pixels[offset], math.min(pixels[offset + 1], pixels[offset + 2])) <
        150;
    for (var dy = nominal - 2; dy <= nominal + 2; dy++) {
      final top = math.max(
          math.max(chatTop, chatTop + dy), bottom - (a.height * .13).round());
      if (bottom - top < a.height * .025) continue;
      final lines = <(int, int)>[];
      for (var y = top; y < bottom; y++) {
        var union = 0, same = 0;
        for (var x = left; x < right; x++) {
          final old = ink(a.pixels, ((y - dy) * a.width + x) * 4);
          final current = ink(b.pixels, (y * a.width + x) * 4);
          if (old || current) union++;
          if (old && current) same++;
        }
        lines.add((union, same));
      }
      // A clipped preceding header need not survive in full. A complete
      // ink-bearing neighbouring line must still move with this same block.
      final window = (a.height * .02).round();
      for (var start = 0; start + window <= lines.length; start++) {
        final slice = lines.skip(start).take(window);
        final union = slice.fold(0, (n, line) => n + line.$1);
        final same = slice.fold(0, (n, line) => n + line.$2);
        if (union >= 80 && same / union >= .96) return true;
      }
    }
    return false;
  }

  Future<bool> _identicalSenderGlyphs(
      Uint8List oldFrame,
      Uint8List newFrame,
      MediaCardOccurrenceContext oldContext,
      MediaCardOccurrenceContext newContext,
      Map chat) async {
    Future<({int width, int height, Uint8List pixels})> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          return (
            width: image.width,
            height: image.height,
            pixels:
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
          );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }

    final a = await decode(oldFrame), b = await decode(newFrame);
    if (a.width != b.width || a.height != b.height) {
      return false;
    }
    final old = oldContext.toMap(), next = newContext.toMap();
    final ta = (old['headerTop'] as num?)?.toDouble();
    final tb = (next['headerTop'] as num?)?.toDouble();
    final ba = (old['headerBottom'] as num?)?.toDouble();
    final bb = (next['headerBottom'] as num?)?.toDouble();
    if (ta == null || tb == null || ba == null || bb == null) {
      return false;
    }
    final width = a.width, height = a.height;
    final nominal = ((tb - ta) * height).round();
    bool ink(Uint8List pixels, int offset) =>
        math.min(
            pixels[offset], math.min(pixels[offset + 1], pixels[offset + 2])) <
        150;
    for (final dy in [nominal, nominal - 1, nominal + 1]) {
      final top = math.min(ta * height + dy, tb * height).floor() - 3;
      final bottom = math.max(ba * height + dy, bb * height).ceil() + 3;
      if (top < 0 || top - dy < 0 || bottom > height || bottom - dy > height) {
        continue;
      }
      var count = 0, different = false;
      for (var y = top; y < bottom && !different; y++) {
        for (var x = ((chat['left'] as num) * width).ceil();
            x < (chat['right'] as num) * width;
            x++) {
          final ai = ((y - dy) * width + x) * 4;
          final bi = (y * width + x) * 4;
          final oldInk = ink(a.pixels, ai);
          final newInk = ink(b.pixels, bi);
          if (oldInk || newInk) count++;
          if (oldInk != newInk &&
              !_sameSubpixelEdge(a.pixels, ai, b.pixels, bi)) {
            different = true;
            break;
          }
        }
      }
      if (!different && count >= 50) {
        return true;
      }
    }
    return false;
  }

  Future<int?> _imageSenderTranslation(
      Uint8List oldFrame,
      Uint8List newFrame,
      MediaCardOccurrenceContext oldContext,
      MediaCardOccurrenceContext newContext,
      Map chat) async {
    Future<({int width, int height, Uint8List pixels})> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          return (
            width: image.width,
            height: image.height,
            pixels:
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
          );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }

    final a = await decode(oldFrame), b = await decode(newFrame);
    if (a.width != b.width || a.height != b.height) {
      return null;
    }
    final old = oldContext.toMap(), next = newContext.toMap();
    final ta = (old['headerTop'] as num?)?.toDouble();
    final tb = (next['headerTop'] as num?)?.toDouble();
    final ba = (old['headerBottom'] as num?)?.toDouble();
    final bb = (next['headerBottom'] as num?)?.toDouble();
    if (ta == null || tb == null || ba == null || bb == null) {
      return null;
    }
    final width = a.width, height = a.height;
    final nominal = ((tb - ta) * height).round();
    bool ink(Uint8List pixels, int offset) =>
        math.min(
            pixels[offset], math.min(pixels[offset + 1], pixels[offset + 2])) <
        150;
    for (var dy = nominal - 12; dy <= nominal + 12; dy++) {
      final top = math.min(ta * height + dy, tb * height).floor() - 3;
      final bottom = math.max(ba * height + dy, bb * height).ceil() + 3;
      if (top < 0 || top - dy < 0 || bottom > height || bottom - dy > height) {
        continue;
      }
      var count = 0, different = false;
      for (var y = top; y < bottom && !different; y++) {
        for (var x = ((chat['left'] as num) * width).ceil();
            x < (chat['right'] as num) * width;
            x++) {
          final oldInk = ink(a.pixels, ((y - dy) * width + x) * 4);
          final newInk = ink(b.pixels, (y * width + x) * 4);
          if (oldInk || newInk) count++;
          if (oldInk != newInk) {
            final oldOffset = ((y - dy) * width + x) * 4;
            final newOffset = (y * width + x) * 4;
            final oldEdge = math.min(a.pixels[oldOffset],
                math.min(a.pixels[oldOffset + 1], a.pixels[oldOffset + 2]));
            final newEdge = math.min(b.pixels[newOffset],
                math.min(b.pixels[newOffset + 1], b.pixels[newOffset + 2]));
            // Pale moving watermarks alter antialiased glyph-edge colours.
            // Only near-threshold weak edges may vary slightly. Added or
            // removed dark glyph strokes (including a changed digit) fail.
            final weakEdge = oldEdge >= 134 &&
                oldEdge <= 166 &&
                newEdge >= 134 &&
                newEdge <= 166 &&
                List.generate(
                    3,
                    (channel) => (a.pixels[oldOffset + channel] -
                            b.pixels[newOffset + channel])
                        .abs()).every((d) => d <= 16);
            if (!weakEdge) {
              different = true;
              break;
            }
          }
        }
      }
      if (!different && count >= 50) {
        return dy;
      }
    }
    return null;
  }

  /// Align the whole sender block, then compare its immutable prefix outside
  /// the union of both card proposals. An inner loading crop and full loaded
  /// crop may have different tops; their overlapping physical interval stays
  /// in the same block. New messages/dividers are rejected before this proof.
  Future<bool> _samePhysicalVideoCard(
      Uint8List oldFrame,
      Uint8List newFrame,
      List<double> oldRegion,
      List<double> newRegion,
      MediaCardOccurrenceContext oldContext,
      MediaCardOccurrenceContext newContext,
      List<double> chat) async {
    Future<({int width, int height, Uint8List pixels})> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          return (
            width: image.width,
            height: image.height,
            pixels:
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
          );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }

    final a = await decode(oldFrame), b = await decode(newFrame);
    if (a.width != b.width || a.height != b.height) {
      return false;
    }
    final old = oldContext.toMap(), next = newContext.toMap();
    final headerA = (old['headerTop'] as num?)?.toDouble();
    final headerB = (next['headerTop'] as num?)?.toDouble();
    if (headerA == null || headerB == null) {
      return false;
    }
    final width = a.width, height = a.height;
    final nominal = ((headerB - headerA) * height).round();
    final left = (chat[0] * width).ceil(), right = (chat[2] * width).floor();
    final scopeTop = (chat[1] * height).ceil();
    for (final dy in [
      nominal,
      nominal - 1,
      nominal + 1,
      nominal - 2,
      nominal + 2
    ]) {
      final oldTop = oldRegion[1] * height + dy;
      final oldBottom = (oldRegion[1] + oldRegion[3]) * height + dy;
      final newTop = newRegion[1] * height;
      final newBottom = (newRegion[1] + newRegion[3]) * height;
      final horizontal =
          math.min(oldRegion[0] + oldRegion[2], newRegion[0] + newRegion[2]) -
              math.max(oldRegion[0], newRegion[0]);
      final vertical =
          math.min(oldBottom, newBottom) - math.max(oldTop, newTop);
      if (horizontal <= 0 ||
          vertical <= 0 ||
          horizontal / math.min(oldRegion[2], newRegion[2]) < .90 ||
          vertical / math.min(oldRegion[3] * height, newRegion[3] * height) <
              .80) {
        continue;
      }
      final maskLeft =
          (math.min(oldRegion[0], newRegion[0]) * width).floor() - 3;
      final maskRight =
          (math.max(oldRegion[0] + oldRegion[2], newRegion[0] + newRegion[2]) *
                      width)
                  .ceil() +
              3;
      // Acquisition may omit a blank strip of a loading card. Exclude that
      // strip too, below the independently read sender header, not its pixels.
      final senderBottom = math.max(
          (old['headerBottom'] as num).toDouble() * height + dy,
          (next['headerBottom'] as num).toDouble() * height);
      final maskTop =
          math.min(math.min(oldTop, newTop), senderBottom + 3).floor();
      final maskBottom = math.max(oldBottom, newBottom).ceil() + 3;
      var compared = 0, ink = 0, different = 0;
      var error = 0;
      for (var y = scopeTop;
          y < math.min(maskBottom, (chat[3] * height).floor());
          y++) {
        final oy = y - dy;
        if (oy < scopeTop || oy >= a.height) {
          continue;
        }
        for (var x = left; x < right; x++) {
          if (x >= maskLeft && x < maskRight && y >= maskTop) {
            continue;
          }
          final oldPixel = (oy * width + x) * 4;
          final newPixel = (y * width + x) * 4;
          bool foreground(Uint8List pixels, int offset) =>
              math.min(pixels[offset],
                  math.min(pixels[offset + 1], pixels[offset + 2])) <
              150;
          final oldInk = foreground(a.pixels, oldPixel),
              newInk = foreground(b.pixels, newPixel);
          compared++;
          if (oldInk || newInk) {
            ink++;
            if (oldInk != newInk) different++;
            for (var c = 0; c < 3; c++) {
              error += (a.pixels[oldPixel + c] - b.pixels[newPixel + c]).abs();
            }
          }
        }
      }
      if (compared >= 1000 &&
          ink >= 200 &&
          different <= math.max(2, (ink * .01).floor()) &&
          error / (ink * 3 * 255) <= .025) {
        return true;
      }
    }
    return false;
  }

  /// Detector boxes can jitter in size while the actual photograph moves
  /// unchanged with its sender block. Compare overlapping original pixels at
  /// that block's translation, without rescaling the two detector crops.
  /// The caller separately proves the sender block and adjoining prose. This
  /// is never an asset-hash or clock-only message equivalence.
  Future<bool> _alignedCardPixels(
      Uint8List previousFrame,
      Uint8List currentFrame,
      List<double> previousRegion,
      List<double> currentRegion,
      MediaCardOccurrenceContext previousContext,
      MediaCardOccurrenceContext currentContext,
      {int? verifiedHeaderShift}) async {
    Future<({int width, int height, Uint8List pixels})?> decode(
        Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          return data == null
              ? null
              : (
                  width: image.width,
                  height: image.height,
                  pixels: data.buffer
                      .asUint8List(data.offsetInBytes, data.lengthInBytes)
                );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }

    final before = await decode(previousFrame),
        after = await decode(currentFrame);
    if (before == null ||
        after == null ||
        before.width != after.width ||
        before.height != after.height) {
      return false;
    }
    final oldHeader =
        (previousContext.toMap()['headerTop'] as num?)?.toDouble();
    final newHeader = (currentContext.toMap()['headerTop'] as num?)?.toDouble();
    if (oldHeader == null || newHeader == null) {
      return false;
    }
    final width = before.width, height = before.height;
    final expectedX = ((currentRegion[0] - previousRegion[0]) * width).round();
    final expectedY =
        verifiedHeaderShift ?? ((newHeader - oldHeader) * height).round();
    final smallerArea = math.min(previousRegion[2] * previousRegion[3],
            currentRegion[2] * currentRegion[3]) *
        width *
        height;
    for (var dy = expectedY - 3; dy <= expectedY + 3; dy++) {
      for (var dx = expectedX - 3; dx <= expectedX + 3; dx++) {
        final left = math.max((previousRegion[0] * width).ceil() + dx,
            (currentRegion[0] * width).ceil());
        final right = math.min(
            ((previousRegion[0] + previousRegion[2]) * width).floor() + dx,
            ((currentRegion[0] + currentRegion[2]) * width).floor());
        final top = math.max((previousRegion[1] * height).ceil() + dy,
            (currentRegion[1] * height).ceil());
        final bottom = math.min(
            ((previousRegion[1] + previousRegion[3]) * height).floor() + dy,
            ((currentRegion[1] + currentRegion[3]) * height).floor());
        if (left < 0 ||
            top < 0 ||
            right > width ||
            bottom > height ||
            left - dx < 0 ||
            top - dy < 0 ||
            right - dx > width ||
            bottom - dy > height ||
            (right - left) * (bottom - top) < smallerArea * .80) {
          continue;
        }
        var count = 0;
        var error = 0.0, sum = 0.0, squares = 0.0;
        for (var y = top; y < bottom; y += 2) {
          for (var x = left; x < right; x += 2) {
            final old = ((y - dy) * width + x - dx) * 4;
            final next = (y * width + x) * 4;
            var value = 0.0;
            for (var channel = 0; channel < 3; channel++) {
              final pixel = before.pixels[old + channel];
              error += (pixel - after.pixels[next + channel]).abs();
              value += pixel / 3;
            }
            count++;
            sum += value;
            squares += value * value;
          }
        }
        // Match the existing full-frame card comparison's 80% overlap and
        // .025 pixel error; flat loading covers cannot prove this identity.
        if (count >= 1000 &&
            error / (count * 3 * 255) <= .025 &&
            squares / count - math.pow(sum / count, 2) >= 200) {
          return true;
        }
      }
    }
    return false;
  }

  Future<bool> _hasVideoOwner(
      Map details, String customer, String? session) async {
    if (details['videoOccurrenceProven'] == true ||
        details['playbackOverlayDetected'] == true ||
        details['kind'] == 'video') {
      return true;
    }
    final parent = details['parentMessageId'] ?? details['resolvedMessageId'];
    if (parent is! String) return false;
    return (await (await database.database).query('customer_media_items',
            columns: ['item_id'],
            where: 'customer=? AND message_id=? AND kind=?'
                '${session == null ? '' : ' AND admission_session_id=?'}',
            whereArgs: [
              customer,
              parent,
              'video',
              if (session != null) session
            ],
            limit: 1))
        .isNotEmpty;
  }

  Future<void> _resolveProvenGroup(String customer,
      {required Object? group,
      required String state,
      required Map<String, Object?> details,
      required String? session}) async {
    if (group == null || unresolved.contains(state)) return;
    final rows = await (await database.database).query('media_capture_audit',
        where: 'customer=?', whereArgs: [customer]);
    for (final row in rows) {
      if (!unresolved.contains(row['state'])) continue;
      final previous = jsonDecode(row['details']! as String) as Map;
      if (previous['automationSessionId'] != session ||
          previous['observationGroupId'] != group ||
          (previous['parentMessageId'] != null &&
              previous['parentMessageId'] != details['parentMessageId'])) {
        continue;
      }
      await finish(row['observation_id']! as String, state, {
        if (details['parentMessageId'] != null)
          'parentMessageId': details['parentMessageId'],
        if (details['resolvedMessageId'] != null)
          'resolvedMessageId': details['resolvedMessageId'],
        if (details['mediaReceiptId'] != null)
          'mediaReceiptId': details['mediaReceiptId'],
        'attributionPending': false,
        'reason': 'same_immutable_card_occurrence',
      });
    }
  }

  Future<void> bindParent(String observationId,
      {required String receiptId, required String messageId}) async {
    final row = (await (await database.database).query('media_capture_audit',
            where: 'observation_id=?', whereArgs: [observationId]))
        .firstOrNull;
    if (row == null) return;
    await finish(observationId, row['state']! as String, {
      'mediaReceiptId': receiptId,
      'parentMessageId': messageId,
      'attributionPending': false,
    });
  }

  /// Geometry groups track assets only. A known JD second identifies the
  /// business record, including all previews/originals of that same message.
  Future<Set<String>> bindMessageTime(String observationId,
      {required DateTime senderAt, MediaParent? parent}) async {
    final db = await database.database;
    final own = await _details(observationId);
    final session = database.currentAutomationSessionId;
    if (own == null ||
        session == null ||
        own['automationSessionId'] != session) {
      return {};
    }
    final customer = own['customer']! as String;
    if (parent != null) {
      final known = await CustomerMediaInventory(database)
          .recordedSenderTime(customer, parent.receiptId);
      if (known != null && !CustomerMessageTime.sameSecond(known, senderAt)) {
        return {};
      }
    }
    final key = CustomerMessageTime.occurrenceKey(customer, senderAt);
    final oldGroup = own['observationGroupId'];
    final rows = await db.query('media_capture_audit',
        where: 'customer=? AND state!=?',
        whereArgs: [customer, 'session_archived']);
    final origins = <String>{};
    for (final row in rows) {
      final details = Map<String, Object?>.from(
          jsonDecode(row['details']! as String) as Map);
      if (details['automationSessionId'] != session) continue;
      final at = DateTime.tryParse(details['senderClock']?.toString() ?? '');
      final sameTime = details['messageTimeKey'] == key ||
          (at != null &&
              CustomerMessageTime.second(at) ==
                  CustomerMessageTime.second(senderAt));
      if (at != null && !CustomerMessageTime.sameSecond(at, senderAt)) {
        continue;
      }
      final sameParent = parent != null &&
          (details['parentMessageId'] == parent.messageId ||
              details['mediaReceiptId'] == parent.receiptId);
      if (row['observation_id'] != observationId &&
          !sameTime &&
          !sameParent &&
          !(details['observationGroupId'] == oldGroup && at == null)) {
        continue;
      }
      details.addAll({
        'messageTimeKey': key,
        'observationGroupId': key,
        'senderClock': CustomerMessageTime.second(senderAt).toIso8601String(),
        if (parent != null) ...{
          'parentMessageId': parent.messageId,
          'mediaReceiptId': parent.receiptId,
          'attributionPending': false,
        },
      });
      if (details['liveArrivalProof'] case final Map proof) {
        details['liveArrivalProof'] = {
          ...proof,
          'observationGroupId': key,
          'occurrenceKey': key,
          'senderAt': CustomerMessageTime.second(senderAt).toIso8601String()
        };
      }
      await db.update('media_capture_audit', {'details': jsonEncode(details)},
          where: 'observation_id=?', whereArgs: [row['observation_id']]);
      origins.add(row['evidence_id']! as String);
    }
    return origins;
  }

  /// Persist the result of LiveMediaArrival's guarded, frozen-frame check
  /// before optional observation/admission writes. A group identifies one
  /// physical bubble; it never grants admission without this original proof.
  Future<void> rememberLiveArrival(String observationId,
      {required ViewportEvidence evidence,
      required String occurrenceKey,
      required String arrivalKey,
      required DateTime? senderAt,
      required int slot}) async {
    final session = database.currentAutomationSessionId;
    if (session == null ||
        evidence.metadata['automationSessionId'] != session ||
        evidence.metadata['replyActivationAllowed'] != true) {
      throw StateError('media_arrival_proof_session_changed');
    }
    final db = await database.database;
    final row = (await db.query('media_capture_audit',
            where: 'observation_id=? AND evidence_id=? AND customer=?',
            whereArgs: [observationId, evidence.id, evidence.customer]))
        .single;
    final details = jsonDecode(row['details']! as String) as Map;
    if (details['automationSessionId'] != session ||
        row['state'] == 'baseline' ||
        details['ownershipAmbiguous'] == true) {
      throw StateError('media_arrival_proof_not_current_card');
    }
    if (details['liveArrivalProof'] is Map) return;
    await finish(observationId, row['state']! as String, {
      'liveArrivalProof': {
        'version': 1,
        'sessionId': session,
        'customer': evidence.customer,
        'evidenceId': evidence.id,
        'observationId': observationId,
        'observationGroupId': details['observationGroupId'] ?? observationId,
        'occurrenceKey': occurrenceKey,
        'arrivalKey': arrivalKey,
        'unreadArrivalKey': evidence.metadata['unreadArrivalKey'],
        'admissionFrontier': evidence.metadata['admissionFrontier'],
        'capturedAt': evidence.capturedAt.toUtc().toIso8601String(),
        'senderAt': senderAt?.toUtc().toIso8601String(),
        'region': details['region'],
        'slot': slot,
      },
    });
  }

  Future<void> rememberDeferredCandidate(
      String observationId, Map<String, Object?> candidate) async {
    final session = database.currentAutomationSessionId;
    final details = await _details(observationId);
    if (session == null ||
        details == null ||
        details['automationSessionId'] != session ||
        candidate['sessionId'] != session ||
        candidate['customer'] != details['customer'] ||
        candidate['evidenceId'] != details['evidenceId'] ||
        candidate['admissionGranted'] != false ||
        details['parentMessageId'] != null ||
        details['liveArrivalProof'] != null ||
        details['deferredLiveArrivalCandidate'] != null) {
      return;
    }
    await finish(observationId, details['state']?.toString() ?? 'discovered',
        {'deferredLiveArrivalCandidate': candidate});
  }

  Future<void> promoteDeferredCandidate(String observationId,
      {required OcrMediaClockEvidence clock}) async {
    final session = database.currentAutomationSessionId;
    final details = await _details(observationId);
    final candidate = details?['deferredLiveArrivalCandidate'];
    if (session == null ||
        details == null ||
        details['automationSessionId'] != session ||
        details['deferredCandidateContinuationProven'] != true ||
        candidate is! Map ||
        candidate['sessionId'] != session ||
        candidate['customer'] != details['customer'] ||
        candidate['admissionGranted'] != false ||
        candidate['region'] is! List ||
        candidate['evidenceId'] == details['evidenceId'] ||
        details['liveArrivalProof'] != null ||
        clock.source != 'ocr_media_sender_header' ||
        clock.sentAt == null) {
      return;
    }
    await finish(observationId, details['state']?.toString() ?? 'discovered', {
      'liveArrivalProof': {
        'version': 1,
        'sessionId': session,
        'customer': details['customer'],
        'evidenceId': candidate['evidenceId'],
        'observationId': candidate['observationId'],
        'observationGroupId': details['observationGroupId'],
        'occurrenceKey': 'bubble:${details['observationGroupId']}',
        'arrivalKey': candidate['unreadArrivalKey'],
        'unreadArrivalKey': candidate['unreadArrivalKey'],
        'admissionFrontier': candidate['frontier'],
        'capturedAt': candidate['capturedAt'],
        'senderAt': clock.sentAt!.toUtc().toIso8601String(),
        'region': candidate['region'],
        'slot': 0,
        'senderAtEvidenceId': details['evidenceId'],
        'continuationObservationId':
            details['deferredCandidateProofObservationId'],
      }
    });
  }

  /// Return null only when a newly proved representation still needs binding.
  /// An already coherent group can resume acquisition without rewriting its
  /// inventory or emitting another card_registered event on every maintenance.
  Future<Set<String>?> boundArrivalGroupOrigins(String observationId,
      {required String receiptId, required String messageId}) async {
    final own = await _details(observationId);
    final session = database.currentAutomationSessionId;
    if (own == null ||
        session == null ||
        own['automationSessionId'] != session) {
      return null;
    }
    final rows = await (await database.database).query('media_capture_audit',
        where:
            'customer=? AND state NOT IN (\'baseline\',\'session_archived\')',
        whereArgs: [own['customer']]);
    final origins = <String>{};
    for (final row in rows) {
      final value = jsonDecode(row['details']! as String) as Map;
      if (value['automationSessionId'] != session ||
          value['observationGroupId'] != own['observationGroupId'] ||
          value['ownershipAmbiguous'] == true) {
        continue;
      }
      final parent = value['parentMessageId'];
      if (parent != null && parent != messageId) continue;
      if (parent != messageId ||
          value['mediaReceiptId'] != receiptId ||
          value['attributionPending'] == true) {
        return null;
      }
      origins.add(row['evidence_id']! as String);
    }
    return origins.isEmpty ? null : origins;
  }

  /// Bind every immutable representation already proved to be this bubble,
  /// including an earlier loading frame with a pinned original. No clocks or
  /// matching files participate in this ownership projection.
  Future<Set<String>> bindArrivalGroup(String observationId,
      {required String receiptId, required String messageId}) async {
    final session = database.currentAutomationSessionId;
    if (session == null ||
        !await database.isCurrentSessionMessage(
            (await _details(observationId))?['customer']?.toString() ?? '',
            messageId)) {
      return {};
    }
    final own = await _details(observationId);
    if (own == null || own['automationSessionId'] != session) return {};
    final origins = <String>{};
    for (final row in await (await database.database).query(
        'media_capture_audit',
        where:
            'customer=? AND state NOT IN (\'baseline\',\'session_archived\')',
        whereArgs: [own['customer']])) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['automationSessionId'] != session ||
          details['observationGroupId'] != own['observationGroupId'] ||
          details['ownershipAmbiguous'] == true ||
          (details['parentMessageId'] != null &&
              details['parentMessageId'] != messageId)) {
        continue;
      }
      if (details['parentMessageId'] != messageId ||
          details['mediaReceiptId'] != receiptId ||
          details['attributionPending'] == true) {
        await bindParent(row['observation_id']! as String,
            receiptId: receiptId, messageId: messageId);
      }
      origins.add(row['evidence_id']! as String);
    }
    return origins;
  }

  Future<Map<String, dynamic>?> _details(String observationId) async {
    final row = (await (await database.database).query('media_capture_audit',
            columns: ['details'],
            where: 'observation_id=?',
            whereArgs: [observationId]))
        .firstOrNull;
    return row == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(row['details']! as String) as Map);
  }

  Future<Map<String, Object?>?> liveArrivalProofFor(
      String observationId) async {
    final details = await _details(observationId);
    final proof = details?['liveArrivalProof'];
    if (details?['automationSessionId'] !=
            database.currentAutomationSessionId ||
        proof is! Map ||
        proof['sessionId'] != database.currentAutomationSessionId ||
        proof['customer'] != details?['customer'] ||
        proof['observationGroupId'] != details?['observationGroupId']) {
      return null;
    }
    return Map<String, Object?>.from(proof);
  }

  /// A loaded image can use an original pinned by its own earlier loading
  /// representation. Exact physical links and a current business parent are
  /// mandatory; a shared file, fingerprint, sender clock or nearby frame is
  /// never enough. The caller must first obtain a native IMAGE verdict.
  Future<Map<String, Object?>?> inheritedImagePin(ViewportEvidence evidence,
      {required String receiptId}) async {
    final session = database.currentAutomationSessionId;
    if (session == null ||
        evidence.metadata['automationSessionId'] != session) {
      return null;
    }
    final db = await database.database;
    var rootId = receiptId;
    final visited = <String>{};
    Map<String, Object?>? root;
    while (visited.add(rootId)) {
      root = (await db.query('customer_media_items',
              where: 'customer=? AND item_id=?',
              whereArgs: [evidence.customer, rootId]))
          .firstOrNull;
      if (root == null) return null;
      if (root['canonical_id'] == null) break;
      rootId = root['canonical_id']! as String;
    }
    if (root == null ||
        root['canonical_id'] != null ||
        root['admission_key'] == null ||
        root['admission_session_id'] != session ||
        root['message_id'] is! String ||
        const {'video', 'text'}.contains(root['kind']) ||
        !await database.isCurrentSessionMessage(
            evidence.customer, root['message_id']! as String)) {
      return null;
    }
    final rows = await db.query('media_capture_audit',
        where:
            'customer=? AND state NOT IN (\'baseline\',\'session_archived\')',
        whereArgs: [evidence.customer]);
    final owned = <String, Map>{};
    for (final row in rows) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['automationSessionId'] == session &&
          details['customer'] == evidence.customer &&
          details['parentMessageId'] == root['message_id'] &&
          details['mediaReceiptId'] == rootId &&
          details['ownershipAmbiguous'] != true &&
          details['videoOccurrenceProven'] != true) {
        owned[row['observation_id']! as String] = details;
      }
    }
    final current = owned.entries
        .where((entry) => entry.value['evidenceId'] == evidence.id)
        .toList();
    for (final observation in current) {
      final group = observation.value['observationGroupId'];
      if (group is! String) continue;
      final members = Map<String, Map>.fromEntries(owned.entries
          .where((entry) => entry.value['observationGroupId'] == group));
      final connected = <String>{observation.key};
      var advanced = true;
      while (advanced) {
        advanced = false;
        for (final entry in members.entries) {
          final link = entry.value['physicalGroupLink'];
          if (link is! Map ||
              !const {
                'same_image_sender_and_preceding_bubble_pixels',
                'same_image_loading_sender_and_preceding_pixels',
                'same_image_sender_block_and_pixels',
                'same_immutable_card_pixels'
              }.contains(link['proof'])) {
            continue;
          }
          final ancestor = link['observationId'];
          if (ancestor is! String ||
              !members.containsKey(ancestor) ||
              members[ancestor]!['evidenceId'] != link['evidenceId']) {
            continue;
          }
          if (connected.contains(entry.key) || connected.contains(ancestor)) {
            advanced = connected.add(entry.key) || advanced;
            advanced = connected.add(ancestor) || advanced;
          }
        }
      }
      for (final id in connected) {
        final origin = members[id]!['evidenceId'];
        if (origin is! String || origin == evidence.id) continue;
        final row = (await db.query('capture_evidence',
                columns: ['payload'],
                where: 'id=? AND customer=? AND state!=?',
                whereArgs: [origin, evidence.customer, 'session_archived']))
            .firstOrNull;
        if (row == null) continue;
        final frame = ViewportEvidence.fromJson(row['payload']! as String);
        final pin = frame.pinnedMedia;
        if (frame.id != origin ||
            frame.customer != evidence.customer ||
            frame.metadata['automationSessionId'] != session ||
            pin?['kind'] != 'image' ||
            pin?['evidenceFile'] is! String ||
            !await File(pin!['evidenceFile']! as String).exists()) {
          continue;
        }
        if (database.currentAutomationSessionId != session) return null;
        return {...pin, 'originEvidenceId': origin};
      }
    }
    return null;
  }

  /// Recoverable registration gaps, not arbitrary old media observations.
  /// Only a current-run, specific frozen arrival proof is actionable. Return
  /// one group once; an already admitted owner is never counted as a new gap.
  Future<List<Map<String, Object?>>> pendingAdmissionGaps(
          {String? customer}) async =>
      _pendingArrivals(customer: customer, excludeRegistered: true);

  Future<List<Map<String, Object?>>> pendingAdmissionRecoveries(
          {String? customer}) async =>
      _pendingArrivals(customer: customer, excludeRegistered: false);

  bool _belongsToRetiredImage(Map details, Set<String> retired) =>
      retired.contains(details['parentMessageId']) ||
      retired.contains(details['resolvedMessageId']) ||
      retired.contains(details['messageTimeKey']) ||
      retired.contains(details['observationGroupId']);

  Future<List<Map<String, Object?>>> _pendingArrivals(
      {String? customer, required bool excludeRegistered}) async {
    final session = database.currentAutomationSessionId;
    if (session == null) return [];
    final db = await database.database;
    final rows = await db.query('media_capture_audit',
        where: customer == null ? null : 'customer=?',
        whereArgs: customer == null ? null : [customer],
        orderBy: 'updated_at_ms ASC, observation_id ASC');
    final seen = <String>{};
    final result = <Map<String, Object?>>[];
    final readyByCustomer = <String, Set<String>>{};
    final retiredByCustomer = <String, Set<String>>{};
    for (final row in rows) {
      if (!unresolved.contains(row['state'])) continue;
      final details = jsonDecode(row['details']! as String) as Map;
      final owner = row['customer']! as String;
      final retired = retiredByCustomer[owner] ??=
          await database.retiredIncompleteImageMessageIds(owner);
      if (_belongsToRetiredImage(details, retired)) continue;
      final proof = details['liveArrivalProof'];
      if (details['automationSessionId'] != session ||
          details['ownershipAmbiguous'] == true ||
          proof is! Map ||
          proof['version'] != 1 ||
          proof['sessionId'] != session ||
          proof['customer'] != row['customer'] ||
          proof['observationGroupId'] != details['observationGroupId'] ||
          proof['occurrenceKey'] is! String ||
          proof['arrivalKey'] is! String ||
          proof['region'] is! List ||
          DateTime.tryParse(proof['capturedAt']?.toString() ?? '') == null) {
        continue;
      }
      final parent = details['parentMessageId'] ?? details['resolvedMessageId'];
      if (excludeRegistered &&
          parent is String &&
          await database.isCurrentSessionMessage(
              row['customer']! as String, parent)) {
        continue;
      }
      final registered = await db.rawQuery(
          '''SELECT m.message_id,w.response_state
        FROM customer_media_items m JOIN automation_session_messages w
          ON w.session_id=m.admission_session_id AND w.user_id=m.customer
            AND w.message_id=m.message_id
        WHERE m.customer=? AND m.admission_session_id=? AND m.admission_key=?
          AND m.canonical_id IS NULL''',
          [row['customer'], session, proof['occurrenceKey']]);
      if (registered.isNotEmpty &&
          registered.every((item) => retired.contains(item['message_id']))) {
        continue;
      }
      if (excludeRegistered && registered.isNotEmpty) continue;
      if (!excludeRegistered && registered.isNotEmpty) {
        final ready = readyByCustomer[row['customer']! as String] ??=
            await CustomerMediaInventory(database)
                .analysisReadyMessageIds(row['customer']! as String);
        if (registered.every((owner) =>
            owner['response_state'] != 'pending' ||
            ready.contains(owner['message_id']))) {
          continue;
        }
      }
      final group = '${row['customer']}\u001f${proof['observationGroupId']}';
      if (!seen.add(group)) continue;
      result.add({
        'customer': row['customer'],
        'observationId': row['observation_id'],
        'observationGroupId': proof['observationGroupId'],
        'evidenceId': proof['evidenceId'],
        'capturedAt': proof['capturedAt'],
        'observedAt': proof['capturedAt'],
        'typeHint':
            details['videoOccurrenceProven'] == true ? 'video' : 'unknown',
        'liveArrivalProof': Map<String, Object?>.from(proof),
      });
    }
    return result;
  }

  /// A resolved text placeholder has no media acquisition left to perform.
  /// Only observations explicitly owned by that same current parent close.
  Future<void> confirmTextParent(String customer,
      {required String parentMessageId,
      required String receiptId,
      required String expectedSessionId}) async {
    if (database.currentAutomationSessionId != expectedSessionId) return;
    final db = await database.database;
    final corrected = await db.rawQuery('''SELECT 1 FROM customer_media_items m
      JOIN automation_session_messages w ON w.session_id=m.admission_session_id
        AND w.user_id=m.customer AND w.message_id=m.message_id
      WHERE m.customer=? AND m.item_id=? AND m.message_id=?
        AND m.admission_session_id=? AND m.kind='text' AND w.input_kind='text' ''',
        [customer, receiptId, parentMessageId, expectedSessionId]);
    if (corrected.isEmpty) return;
    final rows = await db.query('media_capture_audit',
        where: "customer=? AND state NOT IN ('baseline','session_archived')",
        whereArgs: [customer]);
    for (final row in rows) {
      if (database.currentAutomationSessionId != expectedSessionId) return;
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['automationSessionId'] != expectedSessionId) continue;
      final parent = details['parentMessageId'] ?? details['resolvedMessageId'];
      final receipt = details['mediaReceiptId'];
      if ((parent != null && parent != parentMessageId) ||
          (receipt != null && receipt != receiptId) ||
          (parent != parentMessageId && receipt != receiptId)) {
        continue;
      }
      await finish(row['observation_id']! as String, 'rejected_text', {
        'parentMessageId': parentMessageId,
        'resolvedMessageId': parentMessageId,
        'mediaReceiptId': receiptId,
        'kind': 'text',
        'attributionPending': false,
        'reason': 'same_bubble_clarified_as_customer_text',
      });
    }
  }

  Future<bool> captureResolved(String id) async =>
      (await (await database.database).query('media_capture_audit',
              columns: ['state'], where: 'observation_id=?', whereArgs: [id]))
          .any((row) => !unresolved.contains(row['state']));

  /// Background capture observations, not evidence of additional incoming
  /// messages. A reply may depend only on a separately identified parent.
  Future<List<Map<String, Object?>>> pendingUnboundForCustomer(
      String customer) async {
    final session = database.currentAutomationSessionId;
    final rows = await (await database.database).query('media_capture_audit',
        where: "customer=? AND state='unbound'",
        whereArgs: [customer],
        orderBy: 'updated_at_ms ASC, observation_id ASC');
    return [
      for (final row in rows)
        if (jsonDecode(row['details']! as String) case final Map details)
          if (session == null || details['automationSessionId'] == session)
            {
              ...details.map((key, value) => MapEntry('$key', value)),
              'state': 'unbound',
              'observedAt': details['capturedAt'],
              'originalVerified': false,
              'visualAnalysisAvailable': false,
            }
    ];
  }

  Future<void> finish(
      String id, String state, Map<String, Object?> fields) async {
    if (!states.contains(state)) throw ArgumentError.value(state);
    final db = await database.database;
    final rows = await db.query('media_capture_audit',
        where: 'observation_id=?', whereArgs: [id]);
    if (rows.isEmpty) throw StateError('media_observation_missing');
    if (rows.single['state'] == 'session_archived') return;
    final previous =
        jsonDecode(rows.single['details']! as String) as Map<String, dynamic>;
    // Older observation JSON may omit customer. The durable row key owns
    // this observation and is authoritative for the exact-parent check.
    final customer = rows.single['customer']! as String;
    if (database.currentAutomationSessionId != null &&
        previous['automationSessionId'] !=
            database.currentAutomationSessionId) {
      return;
    }
    if (previous['reason'] == 'same_bubble_clarified_as_customer_text' &&
        previous['resolvedMessageId'] != null) {
      if (state != 'rejected_text' ||
          fields['reason'] != previous['reason'] ||
          fields['resolvedMessageId'] != previous['resolvedMessageId']) {
        record('media.observation_recheck_ignored', {
          'customer': previous['customer'],
          'observationId': id,
          'reason': 'placeholder_already_clarified_as_text',
        });
      }
      return;
    }
    // Capture progress cannot transfer an admitted business obligation. The
    // inventory's proved canonical chain must already authorize that transfer.
    final previousParent = previous['parentMessageId'];
    final requestedReceipt = fields['mediaReceiptId'];
    if (previousParent is String &&
        requestedReceipt is String &&
        database.currentAutomationSessionId != null) {
      final requested = await CustomerMediaInventory(database).resolveParent(
          customer,
          receiptId: requestedReceipt,
          requireCurrentSession: true);
      final oldRows = await db.query('customer_media_items',
          where: 'customer=? AND message_id=? AND admission_session_id=?',
          whereArgs: [
            customer,
            previousParent,
            database.currentAutomationSessionId
          ]);
      if (oldRows.isNotEmpty &&
          requested == null &&
          requestedReceipt != previous['mediaReceiptId']) {
        return;
      }
      if (oldRows.isNotEmpty && requested != null) {
        final old = await CustomerMediaInventory(database).resolveParent(
            customer,
            receiptId: oldRows.first['item_id']! as String,
            requireCurrentSession: true);
        if (old != null && old.receiptId != requested.receiptId) return;
        fields = {...fields, 'parentMessageId': requested.messageId};
      }
    }
    // A copied asset or a heuristic match without a business parent cannot
    // resolve a current incoming observation. Retain it for exact admission
    // and acquisition recovery instead of making a missing message disappear.
    if (database.currentAutomationSessionId != null &&
        const {'reused', 'image_saved', 'video_frames_saved'}.contains(state)) {
      final parent = fields['parentMessageId'] ??
          fields['resolvedMessageId'] ??
          previous['parentMessageId'] ??
          previous['resolvedMessageId'];
      if (parent is! String ||
          !await database.isCurrentSessionMessage(customer, parent)) {
        fields = {
          ...fields,
          'unownedCaptureState': state,
          'attributionPending': true,
          'reason': 'no_current_business_parent',
        }..remove('resolvedMessageId');
        state = 'unbound';
      }
    }
    if (((previous['resolvedMessageId'] != null &&
                fields['modelVideoHint'] != true) ||
            rows.single['state'] == 'video_frames_saved') &&
        unresolved.contains(state)) {
      record('media.observation_recheck_ignored', {
        'customer': previous['customer'],
        'observationId': id,
        'reason': 'verified_original_already_persisted'
      });
      return;
    }
    if (previous['modelVideoHint'] == true && state != 'video_frames_saved') {
      state = 'video_preview_only';
    }
    final details = {
      ...previous,
      ...fields,
      'customer': customer,
      'state': state,
      'captureResolved': !unresolved.contains(state),
      'analysisComplete': false
    };
    await db.update(
        'media_capture_audit',
        {
          'state': state,
          'details': jsonEncode(details),
          'updated_at_ms': DateTime.now().millisecondsSinceEpoch
        },
        where: 'observation_id=?',
        whereArgs: [id]);
    record('media.observation_finished', details);
  }

  Future<Set<String>> noteVideoHint(String customer, String path,
      {String? evidenceId, String? receiptId}) async {
    final file = File(path);
    if (!await file.exists()) return {};
    final digest = sha256.convert(await file.readAsBytes()).toString();
    final rows = await (await database.database).query('media_capture_audit',
        where: 'customer=?', whereArgs: [customer]);
    final evidenceIds = <String>{};
    var matchedObservations = 0;
    for (final row in rows) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (row['state'] == 'session_archived') continue;
      if (evidenceId != null && row['evidence_id'] != evidenceId) continue;
      if (receiptId != null && details['mediaReceiptId'] != receiptId) continue;
      if (details['contentSha256'] != digest ||
          row['state'] == 'video_frames_saved') {
        continue;
      }
      await finish(row['observation_id']! as String, 'video_preview_only', {
        'modelVideoHint': true,
        'reason': 'model_play_indicator_not_original_video',
        'hintIsProofOfVideoMessage': false,
      });
      await (await database.database).update(
          'capture_evidence', {'state': 'partial'},
          where: "id=? AND state='processed'", whereArgs: [row['evidence_id']]);
      matchedObservations++;
      evidenceIds.add(row['evidence_id']! as String);
    }
    record('media.video_hint_detected', {
      'customer': customer,
      'contentSha256': digest,
      'matchedObservationCount': matchedObservations,
      'matchedEvidenceCount': evidenceIds.length,
      'hintIsProofOfVideoMessage': false
    });
    return evidenceIds;
  }

  /// Durable observations remain queryable after their cards scroll offscreen.
  Future<List<Map<String, Object?>>> pendingForCustomer(String customer,
      {required DateTime before,
      Set<String>? evidenceIds,
      Set<String>? messageIds,
      Set<String>? receiptIds}) async {
    final rows = await (await database.database).query('media_capture_audit',
        where: 'customer=?',
        whereArgs: [customer],
        orderBy: 'updated_at_ms DESC');
    final result = <Map<String, Object?>>[];
    final seen = <String>{};
    final retired = await database.retiredIncompleteImageMessageIds(customer);
    for (final row in rows) {
      if (evidenceIds != null && !evidenceIds.contains(row['evidence_id'])) {
        continue;
      }
      if (!unresolved.contains(row['state'])) continue;
      final details = jsonDecode(row['details']! as String) as Map;
      if (_belongsToRetiredImage(details, retired)) continue;
      if (messageIds != null || receiptIds != null) {
        final owned =
            messageIds?.contains(details['parentMessageId']) == true ||
                messageIds?.contains(details['resolvedMessageId']) == true ||
                receiptIds?.contains(details['mediaReceiptId']) == true;
        if (!owned) continue;
      }
      if (database.currentAutomationSessionId != null &&
          details['automationSessionId'] !=
              database.currentAutomationSessionId) {
        continue;
      }
      final at = DateTime.tryParse(
          (details['senderClock'] ?? details['capturedAt'])?.toString() ?? '');
      if (at == null ||
          (database.currentAutomationSessionId == null &&
              (at.isAfter(before) ||
                  at.isBefore(before.subtract(const Duration(minutes: 10)))))) {
        continue;
      }
      final key =
          details['senderClock']?.toString() ?? row['evidence_id'].toString();
      if (!seen.add(key)) continue;
      result.add({
        'observationId': row['observation_id'],
        'evidenceId': row['evidence_id'],
        'state': row['state'],
        if (row['state'] == 'unbound') ...{
          'attributionPending': true,
          'region': details['region'],
          'reason': details['reason'],
        },
        'observedAt': at.toUtc().toIso8601String(),
        'originalVerified': false,
        'visualAnalysisAvailable': false
      });
      if (result.length >= 6) break;
    }
    return result;
  }

  Future<void> resolveStoredReceipt(String customer, String receipt) async {
    final document = await (await database.history).read(customer);
    for (final message
        in (document?['messages'] as List? ?? const []).whereType<Map>()) {
      if (message['direction'] != 'incoming' ||
          !(message['media_receipt_id'] == receipt ||
              (message['media_receipt_aliases'] as List? ?? const [])
                  .contains(receipt))) {
        continue;
      }
      final id = message['id']?.toString();
      if (id == null || !await database.isCurrentSessionMessage(customer, id)) {
        continue;
      }
      await resolveCaptured(CapturedConversation(
          stableKey: document!['stable_key']?.toString() ?? customer,
          customerName: customer,
          customerExternalId: customer,
          capturedAt: DateTime.now(),
          messages: [
            CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: message['body']?.toString() ?? '',
              sender: customer,
              sentAt: DateTime.tryParse(message['sent_at']?.toString() ?? ''),
              axPath: 'persisted-media-receipt',
              mediaReceiptId: receipt,
              media: (message['media'] as List? ?? const [])
                  .whereType<Map>()
                  .map((media) =>
                      CapturedMedia.fromMap(Map<Object?, Object?>.from(media)))
                  .toList(),
            )
          ]));
    }
  }

  Future<void> resolveCaptured(CapturedConversation? capture) async {
    if (capture == null) return;
    final customer = capture.customerExternalId ?? capture.customerName;
    final db = await database.database;
    for (final message in capture.messages) {
      if (message.direction != 'incoming') continue;
      final video = message.media.any((m) => m.type == 'video');
      if (video &&
          !message.media.any((m) => m.captureSource == 'jd_video_frame_1fps')) {
        continue;
      }
      final original = video ||
          message.media.any((m) =>
              m.type == 'image' &&
              !m.isPartial &&
              m.captureSource == 'jd_image_cache');
      if (!original) continue;
      final rows = await db.query('media_capture_audit',
          where: 'customer=?', whereArgs: [customer]);
      final provenGroups = <Object?>{
        for (final row in rows)
          if (jsonDecode(row['details']! as String) case final Map details)
            if (details['mediaReceiptId'] == message.mediaReceiptId &&
                details['resolvedMessageId'] == message.stableId &&
                details['observationGroupId'] != null)
              details['observationGroupId'],
      };
      for (final row in rows) {
        if (!unresolved.contains(row['state'])) continue;
        final d = jsonDecode(row['details']! as String) as Map;
        if (d['parentMessageId'] != null &&
            d['parentMessageId'] != message.stableId) {
          continue;
        }
        final at = DateTime.tryParse(d['senderClock']?.toString() ?? '');
        final linked = message.mediaReceiptId != null &&
            (d['mediaReceiptId'] == message.mediaReceiptId ||
                provenGroups.contains(d['observationGroupId']));
        if (!linked &&
            (d['mediaReceiptId'] != null ||
                row['state'] == 'unbound' ||
                at == null ||
                message.sentAt == null ||
                at.toUtc() != message.sentAt!.toUtc())) {
          continue;
        }
        if (!video && (d['kind'] == 'video' || d['modelVideoHint'] == true)) {
          continue;
        }
        await finish(row['observation_id']! as String,
            video ? 'video_frames_saved' : 'image_saved', {
          'resolvedMessageId': message.stableId,
          'mediaReceiptId': message.mediaReceiptId,
          'attributionPending': false,
          'reason': linked
              ? 'exact_media_receipt_original_persisted'
              : 'same_customer_exact_sender_clock_original_persisted'
        });
      }
    }
  }

  Future<Map<String, int>> stateCounts(String evidenceId) async {
    final rows = await (await database.database).rawQuery(
        'SELECT state,COUNT(*) AS count FROM media_capture_audit WHERE evidence_id=? GROUP BY state',
        [evidenceId]);
    return {
      for (final row in rows) row['state']! as String: row['count']! as int
    };
  }

  Future<int> unresolvedCount(String evidenceId) async {
    final rows = await (await database.database).query('media_capture_audit',
        columns: ['state'], where: 'evidence_id=?', whereArgs: [evidenceId]);
    return rows.where((r) => unresolved.contains(r['state'])).length;
  }
}
