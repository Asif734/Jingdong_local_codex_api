import 'dart:async';
import 'dart:convert';

import '../capture/incoming_message_blocks.dart';
import '../capture/live_media_admission.dart';
import '../capture/ocr_capture_extractor.dart';
import '../capture/viewport_evidence.dart';
import '../domain/capture_models.dart';
import '../domain/customer_message_time.dart';
import '../domain/message_record.dart';
import '../platform/macos_capture_adapter.dart';
import 'capture_database.dart';
import 'customer_media_inventory.dart';
import 'media_capture_audit.dart';

class MediaMessageRegistration {
  MediaMessageRegistration({
    required this.receipts,
    required this.parents,
    required this.groups,
    required this.observationIds,
    required this.clocks,
    required this.occurrences,
    required this.createdAdmissions,
    required this.originEvidenceIds,
  });

  final Map<OcrVisualRegion, String> receipts;
  final Map<OcrVisualRegion, MediaParent> parents;
  final Map<OcrVisualRegion, Map<String, Object?>> groups;
  final Map<OcrVisualRegion, String> observationIds;
  final Map<OcrVisualRegion, OcrMediaClockEvidence> clocks;
  final Map<OcrVisualRegion, String> occurrences;
  final List<MediaMessageAdmission> createdAdmissions;
  final Set<String> originEvidenceIds;
}

class MediaAdmissionRecovery {
  MediaAdmissionRecovery(
      {required this.createdAdmissions,
      required this.parents,
      required this.originEvidenceIds});
  final List<MediaMessageAdmission> createdAdmissions;
  final List<MediaParent> parents;
  final Set<String> originEvidenceIds;
}

/// One timestamp owner from discovery through business admission. Unclocked
/// observations retain their source evidence until a complete sender time is
/// readable. Video acquisition/decoding never runs here.
class MediaMessageRegistrar {
  MediaMessageRegistrar(this.database,
      {MediaCaptureAudit? audit, CustomerMediaInventory? inventory})
      : audit = audit ?? MediaCaptureAudit(database),
        inventory = inventory ?? CustomerMediaInventory(database);

  final CaptureDatabase database;
  final MediaCaptureAudit audit;
  final CustomerMediaInventory inventory;

  // Different registrar instances for one DB still share the same owner.
  // This lock does not hold an SQLite transaction or the JD UI queue.
  static final _owners =
      Expando<Map<String, Future<void>>>('media_registration');

  Future<T> _owned<T>(
      String session, String customer, Future<T> Function() run) {
    final owners = _owners[database] ??= {};
    final key = '$session\u001f$customer';
    final result = (owners[key] ?? Future<void>.value()).then((_) => run());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    owners[key] = tail;
    unawaited(tail.then((_) {
      if (identical(owners[key], tail)) owners.remove(key);
    }));
    return result;
  }

  /// Quiet maintenance must discover a committed owner repair even after all
  /// captures have finished and there is no new card/admission gap to replay.
  /// This reads only durable journals; it performs no UI or recognition work.
  Future<Set<String>> pendingOwnerRepairCustomers() async {
    final session = database.currentAutomationSessionId;
    if (session == null) return {};
    final rows = await (await database.database).query('media_capture_audit',
        columns: ['customer', 'details'],
        where: 'state!=? AND details LIKE ?',
        whereArgs: ['session_archived', '%"sameBubbleOwnerRepair"%']);
    if (database.currentAutomationSessionId != session) return {};
    final customers = <String>{};
    for (final row in rows) {
      final customer = row['customer'];
      final details = jsonDecode(row['details']! as String) as Map;
      final repair = details['sameBubbleOwnerRepair'];
      if (customer is! String ||
          customer.isEmpty ||
          details['customer'] != customer ||
          details['automationSessionId'] != session ||
          repair is! Map ||
          repair['sessionId'] != session ||
          repair['customer'] != customer ||
          repair['phase'] != 'inventory_committed' ||
          repair['canonicalReceiptId'] is! String ||
          repair['duplicateReceiptId'] is! String ||
          repair['canonicalReceiptId'] == repair['duplicateReceiptId']) {
        continue;
      }
      customers.add(customer);
    }
    return customers;
  }

  Future<MediaAdmissionRecovery> recoverPendingAdmissions(
      {required String customer, void Function()? checkCurrent}) {
    final session = database.currentAutomationSessionId;
    if (session == null) {
      return Future.value(MediaAdmissionRecovery(
          createdAdmissions: [], parents: [], originEvidenceIds: {}));
    }
    return _owned(session, customer, () async {
      void check() {
        checkCurrent?.call();
        if (database.currentAutomationSessionId != session) {
          throw StateError('media_registration_session_changed');
        }
      }

      check();
      await _reconcileOwnerRepairs(customer, session, check);
      check();
      final created = <MediaMessageAdmission>[];
      final parents = <MediaParent>[];
      final origins = <String>{};
      final gaps = await audit.pendingAdmissionRecoveries(customer: customer);
      check();
      for (final gap in gaps) {
        final proof = gap['liveArrivalProof']! as Map;
        final region = (proof['region']! as List).cast<num>();
        final senderAt = DateTime.tryParse(proof['senderAt']?.toString() ?? '');
        final timedParent = senderAt == null
            ? null
            : await inventory.findTimeParent(customer, senderAt);
        final existing = timedParent == null
            ? (await (await database.database).query('customer_media_items',
                    where:
                        'customer=? AND admission_session_id=? AND admission_key=? AND canonical_id IS NULL',
                    whereArgs: [customer, session, proof['occurrenceKey']]))
                .firstOrNull
            : {'item_id': timedParent.receiptId};
        check();
        if (existing != null) {
          final parent = timedParent ??
              await inventory.resolveParent(customer,
                  receiptId: existing['item_id']! as String,
                  requireCurrentSession: true);
          check();
          if (parent != null) {
            final bound = await audit.boundArrivalGroupOrigins(
                gap['observationId']! as String,
                receiptId: parent.receiptId,
                messageId: parent.messageId);
            check();
            parents.add(parent);
            origins.addAll(bound ??
                await audit.bindArrivalGroup(gap['observationId']! as String,
                    receiptId: parent.receiptId, messageId: parent.messageId));
            check();
            continue;
          }
        }
        if (senderAt == null) {
          // Retain the arrival/evidence obligation, but never manufacture a
          // random message owner before the customer's unique time is known.
          continue;
        }
        final startedAt = database.automationSessionStartedAt;
        final observedAt = DateTime.parse(proof['capturedAt']! as String);
        if (startedAt == null ||
            CustomerMessageTime.second(senderAt)
                .isBefore(CustomerMessageTime.second(startedAt)) ||
            senderAt.isAfter(observedAt.add(const Duration(seconds: 1)))) {
          // A formerly unclocked proof cannot admit old history merely by
          // learning its sender clock later. Existing owners above still
          // retain their ordinary enrichment/receipt reconciliation path.
          continue;
        }
        var receipt = await inventory.observe(
            customer: customer,
            evidenceId: proof['evidenceId']! as String,
            observedAt: DateTime.parse(proof['capturedAt']! as String),
            senderAt: DateTime.tryParse(proof['senderAt']?.toString() ?? ''),
            slot: (proof['slot']! as num).toInt(),
            region: region.map((v) => v.toDouble()).toList(),
            current: true,
            occurrenceKey: proof['occurrenceKey']! as String);
        check();
        var parent = await inventory.resolveParent(customer,
            receiptId: receipt, requireCurrentSession: true);
        check();
        if (parent == null) {
          final admission = await database.admitMediaMessage(customer,
              receiptId: receipt,
              evidenceId: proof['evidenceId']! as String,
              occurrenceKey:
                  CustomerMessageTime.occurrenceKey(customer, senderAt),
              receivedAt: DateTime.parse(proof['capturedAt']! as String),
              senderAt: senderAt,
              messageId: CustomerMessageTime.incomingId(customer, senderAt));
          check();
          receipt = admission.receiptId;
          if (admission.created) created.add(admission);
          parent = await inventory.resolveParent(customer,
              receiptId: receipt, requireCurrentSession: true);
          check();
        }
        if (parent == null) {
          throw StateError('media_registration_parent_not_persisted');
        }
        parents.add(parent);
        origins.addAll(await audit.bindArrivalGroup(
            gap['observationId']! as String,
            receiptId: parent.receiptId,
            messageId: parent.messageId));
        check();
      }
      return MediaAdmissionRecovery(
          createdAdmissions: created,
          parents: parents,
          originEvidenceIds: origins);
    });
  }

  Future<void> _reconcileOwnerRepairs(
      String customer, String session, void Function() check) async {
    final db = await database.database;
    check();
    final rows = await db.query('media_capture_audit',
        where: 'customer=? AND state!=?',
        whereArgs: [customer, 'session_archived']);
    check();
    for (final row in rows) {
      final details = jsonDecode(row['details']! as String) as Map;
      final repair = details['sameBubbleOwnerRepair'];
      if (details['automationSessionId'] != session ||
          repair is! Map ||
          repair['sessionId'] != session ||
          repair['customer'] != customer ||
          repair['phase'] != 'inventory_committed') {
        continue;
      }
      final canonical = repair['canonicalReceiptId'];
      final duplicate = repair['duplicateReceiptId'];
      if (canonical is! String || duplicate is! String) continue;
      // File consolidation and exact formal-receipt projection are deliberately
      // outside the inventory SQL transaction. The journal makes that boundary
      // restartable without inventing a native send or an answered flag.
      final reconciled = await database.reconcileProvenMediaAliases(customer,
          canonicalReceiptId: canonical,
          duplicateReceiptId: duplicate,
          expectedSessionId: session);
      check();
      if (!reconciled) continue;
      final latest = (await db.query('media_capture_audit',
              where: 'observation_id=?', whereArgs: [row['observation_id']]))
          .single;
      final current = jsonDecode(latest['details']! as String) as Map;
      final marker = current['sameBubbleOwnerRepair'];
      if (marker is! Map ||
          marker['canonicalReceiptId'] != canonical ||
          marker['duplicateReceiptId'] != duplicate ||
          marker['sessionId'] != session) {
        continue;
      }
      await db.update(
          'media_capture_audit',
          {
            'details': jsonEncode({
              ...current,
              'sameBubbleOwnerRepair': {...marker, 'phase': 'reconciled'}
            })
          },
          where: 'observation_id=?',
          whereArgs: [row['observation_id']]);
      check();
    }
  }

  Future<MediaMessageRegistration> register({
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required Iterable<OcrVisualRegion> cards,
    required Iterable<CapturedMessage> visibleText,
    Iterable<OcrVisualRegion> unknownBodyRegions = const [],
    Map? frontier,
    required bool registerOnly,
    // Legacy callers may supply this, but business IDs always use sender time.
    String Function()? nextMessageId,
    void Function()? checkCurrent,
  }) {
    final session = database.currentAutomationSessionId;
    if (session == null) {
      return Future.error(
          StateError('media_registration_requires_current_session'));
    }
    final regions = cards.toList(growable: false);
    final unknown = unknownBodyRegions.toList(growable: false);
    final text = visibleText.toList(growable: false);
    return _owned(
        session,
        evidence.customer,
        () => _register(
            session: session,
            evidence: evidence,
            inspection: inspection,
            cards: regions,
            unknownBodyRegions: unknown,
            visibleText: text,
            frontier: frontier,
            registerOnly: registerOnly,
            checkCurrent: checkCurrent));
  }

  void _check(
      String session, ViewportEvidence evidence, OcrInspection inspection) {
    if (database.currentAutomationSessionId != session ||
        evidence.metadata['automationSessionId'] != session) {
      throw StateError('media_registration_session_changed');
    }
    if (inspection.activeCustomerId != evidence.customer) {
      throw StateError('media_registration_customer_mismatch');
    }
  }

  Future<MediaMessageRegistration> _register({
    required String session,
    required ViewportEvidence evidence,
    required OcrInspection inspection,
    required List<OcrVisualRegion> cards,
    required List<OcrVisualRegion> unknownBodyRegions,
    required List<CapturedMessage> visibleText,
    required Map? frontier,
    required bool registerOnly,
    required void Function()? checkCurrent,
  }) async {
    void check() {
      checkCurrent?.call();
      _check(session, evidence, inspection);
    }

    check();
    final customer = evidence.customer;
    await _reconcileOwnerRepairs(customer, session, check);
    check();
    final receipts = <OcrVisualRegion, String>{};
    final parents = <OcrVisualRegion, MediaParent>{};
    final groups = <OcrVisualRegion, Map<String, Object?>>{};
    final observations = <OcrVisualRegion, String>{};
    final clocks = <OcrVisualRegion, OcrMediaClockEvidence>{};
    final occurrences = <OcrVisualRegion, String>{};
    final created = <MediaMessageAdmission>[];
    final origins = <String>{};
    for (final region in cards) {
      final clock =
          const OcrCaptureExtractor().mediaClockForRegion(inspection, region);
      final observation = await audit.discover(evidence, region,
          inspection: inspection, physicalCards: cards);
      check();
      var group = await audit.groupUnbound(evidence, region, observation,
          inspection: inspection, physicalCards: cards);
      check();
      if (clock.sentAt == null &&
          await audit.proveUnknownVideoOwner(
              evidence, inspection, region, observation,
              physicalCards: cards)) {
        check();
        final binding = await inventory.bindUnknownVideoOwner(customer,
            proofObservationId: observation, expectedSessionId: session);
        check();
        if (binding != null) {
          origins.addAll(binding.originEvidenceIds);
          group = await audit.groupUnbound(evidence, region, observation,
              inspection: inspection, physicalCards: cards);
          check();
        }
      }
      if (clock.sentAt == null &&
          group['sameBubbleOwnerProof'] is Map &&
          (group['sameBubbleOwnerRepair'] as Map?)?['phase'] != 'reconciled') {
        final owners = await inventory.bindProvenBubbleOwners(customer,
            proofObservationId: observation, expectedSessionId: session);
        check();
        if (owners != null) {
          await _reconcileOwnerRepairs(customer, session, check);
          check();
          group = await audit.groupUnbound(evidence, region, observation,
              inspection: inspection, physicalCards: cards);
          check();
        }
      }
      observations[region] = observation;
      groups[region] = group;
      clocks[region] = clock;
      if (group['mediaReceiptId'] case final String receipt) {
        final parent = await inventory.resolveParent(customer,
            receiptId: receipt, requireCurrentSession: true);
        check();
        if (parent != null) parents[region] = parent;
      }
    }
    bool sameRegion(OcrVisualRegion a, OcrVisualRegion b) =>
        (a.x - b.x).abs() < .000001 &&
        (a.y - b.y).abs() < .000001 &&
        (a.width - b.width).abs() < .000001 &&
        (a.height - b.height).abs() < .000001;
    final requestedUnknown = cards
        .where((card) =>
            unknownBodyRegions.any((region) => sameRegion(card, region)))
        .toSet();
    final arrivals = registerOnly
        ? LiveMediaArrival.infer(
            evidence: evidence,
            inspection: inspection,
            cards: cards.where((card) =>
                !requestedUnknown.contains(card) &&
                groups[card]?['state'] != 'baseline' &&
                groups[card]?['ownershipAmbiguous'] != true),
            headers: clocks,
            knownParents: {
              for (final entry in parents.entries)
                entry.key: entry.value.messageId
            },
            visibleText: visibleText,
            sessionStartedAt: database.automationSessionStartedAt,
            frontier: frontier)
        : <OcrVisualRegion, String>{};
    final provedUnknown = <OcrVisualRegion>{};
    final startedAt = database.automationSessionStartedAt;
    if (registerOnly && unknownBodyRegions.isNotEmpty && startedAt != null) {
      final requested = requestedUnknown.where((card) =>
          groups[card]?['state'] != 'baseline' &&
          groups[card]?['ownershipAmbiguous'] != true);
      // Revalidate inside the same discovery/admission critical section. The
      // UI's earlier proposal is not itself proof of a current incoming duty.
      final validated = UnknownIncomingBlocks.locate(
          evidence: evidence,
          inspection: inspection,
          messages: visibleText,
          sessionId: session,
          sessionStartedAt: startedAt,
          mediaRegions: cards.where((card) => !requested.contains(card)),
          knownMediaParents: {
            for (final entry in parents.entries)
              if (!requested.contains(entry.key))
                entry.key: entry.value.messageId
          },
          frontier: frontier);
      for (final card in requested) {
        final matching =
            validated.where((block) => sameRegion(card, block.region));
        if (matching.isEmpty) continue;
        final block = matching.first;
        provedUnknown.add(card);
        clocks[card] = OcrMediaClockEvidence(
            source: 'ocr_media_sender_header',
            sentAt: block.sentAt,
            headerTop: block.header.y,
            headerBottom: block.header.y + block.header.height,
            confidence: block.header.confidence);
        final groupId = groups[card]?['observationGroupId']?.toString() ??
            observations[card]!;
        arrivals.putIfAbsent(card,
            () => 'frontier:${frontier?['id']}:incoming-unknown:$groupId');
      }
    }
    if (registerOnly && startedAt != null) {
      final deferred = LiveMediaArrival.deferredCandidates(
          evidence: evidence,
          inspection: inspection,
          cards: cards.where((card) =>
              !requestedUnknown.contains(card) &&
              !parents.containsKey(card) &&
              !arrivals.containsKey(card)),
          knownParents: {
            for (final e in parents.entries) e.key: e.value.messageId
          },
          sessionId: session,
          sessionStartedAt: startedAt,
          frontier: frontier);
      for (final entry in deferred.entries) {
        await audit.rememberDeferredCandidate(observations[entry.key]!,
            {...entry.value, 'observationId': observations[entry.key]});
        check();
      }
    }
    final slots = <String, int>{};
    for (final region in cards) {
      check();
      final clock = clocks[region]!.sentAt == null
          ? null
          : CustomerMessageTime.second(clocks[region]!.sentAt!);
      final weakReceipt = parents[region]?.receiptId;
      final weakScreenshot = weakReceipt != null &&
          await database.isWeakScreenshotTextCandidate(customer, weakReceipt);
      check();
      if ((requestedUnknown.contains(region) || weakScreenshot) &&
          clock != null) {
        final text = await database.preserveConfirmedTextAtTime(customer,
            senderAt: clock,
            evidenceId: evidence.id,
            expectedSessionId: session,
            receiptId: parents[region]?.receiptId);
        check();
        if (text != null) {
          await audit.finish(observations[region]!, 'rejected_text', {
            'reason': 'confirmed_customer_text_preserved',
            'resolvedMessageId': text,
            'attributionPending': false,
          });
          check();
          parents.remove(region);
          continue;
        }
      }
      final clockKey = clock?.toUtc().toIso8601String() ?? 'unclocked';
      final slot = clock != null
          ? 0
          : slots.update(clockKey, (value) => value + 1, ifAbsent: () => 0);
      final group = groups[region]!;
      final groupId =
          group['observationGroupId']?.toString() ?? observations[region]!;
      if (registerOnly &&
          clock != null &&
          clocks[region]!.source == 'ocr_media_sender_header' &&
          LiveMediaArrival.admitsCurrentTimestamp(
              evidence: evidence,
              inspection: inspection,
              senderAt: clock,
              sessionStartedAt: database.automationSessionStartedAt)) {
        arrivals[region] = CustomerMessageTime.occurrenceKey(customer, clock);
      }
      // The displayed date/second is the customer's unique message key.
      // Loading covers, crop shapes and repeated frames only enrich it.
      final occurrence = clock != null
          ? CustomerMessageTime.occurrenceKey(customer, clock)
          : provedUnknown.contains(region) ||
                  group['videoOccurrenceProven'] == true ||
                  group['cardOccurrenceProven'] == true
              ? 'bubble:$groupId'
              : arrivals[region];
      if (occurrence != null) occurrences[region] = occurrence;
      var parent = clock == null
          ? parents[region]
          : await inventory.findTimeParent(customer, clock) ?? parents[region];
      check();
      if (clock != null) {
        origins.addAll(await audit.bindMessageTime(observations[region]!,
            senderAt: clock, parent: parent));
        check();
      }
      if (parent == null && registerOnly) {
        await audit.promoteDeferredCandidate(observations[region]!,
            clock: clocks[region]!);
        check();
      }
      if (parent == null &&
          registerOnly &&
          arrivals[region] != null &&
          occurrence != null) {
        await audit.rememberLiveArrival(observations[region]!,
            evidence: evidence,
            occurrenceKey: occurrence,
            arrivalKey: arrivals[region]!,
            senderAt: clock,
            slot: slot);
        check();
      }
      final proof = registerOnly
          ? await audit.liveArrivalProofFor(observations[region]!)
          : null;
      check();
      final provedOccurrence = clock != null
          ? CustomerMessageTime.occurrenceKey(customer, clock)
          : proof?['occurrenceKey']?.toString() ?? occurrence;
      final exactBound = parent != null &&
          await inventory.hasExactBoundObservation(customer,
              evidenceId: evidence.id,
              region: [region.x, region.y, region.width, region.height],
              parent: parent);
      check();
      var receipt = exactBound
          ? parent.receiptId
          : await inventory.observe(
              customer: customer,
              evidenceId: evidence.id,
              observedAt: inspection.capturedAt,
              senderAt: clock,
              slot: slot,
              region: [region.x, region.y, region.width, region.height],
              current: evidence.metadata['replyActivationAllowed'] == true,
              occurrenceKey: provedOccurrence,
              parentReceiptId: parent?.receiptId);
      check();
      parent ??= await inventory.resolveParent(customer,
          receiptId: receipt, requireCurrentSession: true);
      check();
      final existingTimeMessage = clock == null
          ? null
          : await database.incomingMessageIdAtTime(customer, clock);
      check();
      final timestampEligible = clock != null &&
          LiveMediaArrival.admitsCurrentTimestamp(
              evidence: evidence,
              inspection: inspection,
              senderAt: clock,
              sessionStartedAt: database.automationSessionStartedAt);
      // New work needs a live-arrival proof. A previously recorded second is
      // only enriched, including an answered record with no fresh red mark.
      if (parent == null &&
          registerOnly &&
          clock != null &&
          (timestampEligible || existingTimeMessage != null) &&
          (proof != null || existingTimeMessage != null) &&
          provedOccurrence != null) {
        final admission = await database.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: proof?['evidenceId'] as String? ?? evidence.id,
            occurrenceKey: provedOccurrence,
            receivedAt: proof?['capturedAt'] == null
                ? evidence.capturedAt
                : DateTime.parse(proof!['capturedAt']! as String),
            senderAt: clock,
            messageId: CustomerMessageTime.incomingId(customer, clock));
        check();
        receipt = admission.receiptId;
        parent = await inventory.resolveParent(customer, receiptId: receipt);
        check();
        if (parent == null) {
          throw StateError('media_registration_parent_not_persisted');
        }
        if (admission.created) created.add(admission);
      }
      if (parent != null &&
          clock != null &&
          clocks[region]!.source == 'ocr_media_sender_header' &&
          group['verifiedSenderAt'] != clock.toUtc().toIso8601String()) {
        if (await inventory.refineParentClock(customer,
            parent: parent, senderAt: clock)) {
          check();
          parent = await inventory.resolveParent(customer,
              receiptId: parent.receiptId);
          check();
          await audit.finish(
              observations[region]!,
              group['state']?.toString() ?? 'discovered',
              {'verifiedSenderAt': clock.toUtc().toIso8601String()});
          check();
        }
      }
      if (parent != null) {
        if (clock != null) {
          origins.addAll(await audit.bindMessageTime(observations[region]!,
              senderAt: clock, parent: parent));
          check();
        }
        receipt = parent.receiptId;
        parents[region] = parent;
        if (groups[region]?['parentMessageId'] != parent.messageId) {
          origins.addAll(await audit.bindArrivalGroup(observations[region]!,
              receiptId: receipt, messageId: parent.messageId));
        } else if (!exactBound) {
          await audit.bindParent(observations[region]!,
              receiptId: receipt, messageId: parent.messageId);
        }
        check();
        groups[region] = {
          ...group,
          'parentMessageId': parent.messageId,
          'mediaReceiptId': receipt,
          'attributionPending': false,
        };
      }
      receipts[region] = receipt;
    }
    return MediaMessageRegistration(
        receipts: receipts,
        parents: parents,
        groups: groups,
        observationIds: observations,
        clocks: clocks,
        occurrences: occurrences,
        createdAdmissions: created,
        originEvidenceIds: origins);
  }
}
