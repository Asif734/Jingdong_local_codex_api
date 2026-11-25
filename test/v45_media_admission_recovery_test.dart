import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/message_record.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

class _InterruptedAdmission extends CaptureDatabase {
  _InterruptedAdmission(Directory root) : super(storageRoot: root);
  var failNextAdmission = true;

  @override
  Future<MediaMessageAdmission> admitMediaMessage(String customer,
      {required String receiptId,
      required String evidenceId,
      required String occurrenceKey,
      required DateTime receivedAt,
      DateTime? senderAt,
      String? messageId}) {
    if (failNextAdmission) {
      failNextAdmission = false;
      throw StateError('injected_interrupt_after_frozen_arrival');
    }
    return super.admitMediaMessage(customer,
        receiptId: receiptId,
        evidenceId: evidenceId,
        occurrenceKey: occurrenceKey,
        receivedAt: receivedAt,
        senderAt: senderAt,
        messageId: messageId);
  }
}

class _InterruptedBindingAudit extends MediaCaptureAudit {
  _InterruptedBindingAudit(super.database) : super(record: (_, __) {});
  var failNextBinding = true;
  @override
  Future<Set<String>> bindArrivalGroup(String observationId,
      {required String receiptId, required String messageId}) {
    if (failNextBinding) {
      failNextBinding = false;
      throw StateError('injected_interrupt_after_admission_before_binding');
    }
    return super.bindArrivalGroup(observationId,
        receiptId: receiptId, messageId: messageId);
  }
}

class _InterruptedResumeStore extends CaptureEvidenceStore {
  _InterruptedResumeStore(super.database);
  var failNextResume = false;
  @override
  Future<int> resumeAdmittedMediaEvidence(Set<String> evidenceIds) async {
    if (failNextResume) {
      failNextResume = false;
      throw StateError('injected_interrupt_after_binding_before_resume');
    }
    return super.resumeAdmittedMediaEvidence(evidenceIds);
  }
}

void main() {
  late Directory root;
  late _InterruptedAdmission db;
  late _InterruptedResumeStore store;
  late MediaCaptureAudit audit;
  late MediaMessageRegistrar registrar;
  final at = DateTime.utc(2026, 11, 9, 8);
  const customer = 'jd_recovery_buyer';
  const card =
      OcrVisualRegion(x: .28, y: .36, width: .3, height: .2, confidence: 1);
  late ViewportEvidence evidence;
  late OcrInspection inspection;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v45_admission_recovery_');
    db = _InterruptedAdmission(root);
    final session = await db.beginAutomationSession(startedAt: at);
    store = _InterruptedResumeStore(db);
    await store.beginSession(sessionId: session, startedAt: at);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, audit: audit);
    final image = File('${root.path}/first.png');
    await image.writeAsBytes([1, 2, 3]);
    evidence = ViewportEvidence({
      'evidenceId': 'frozen-first-arrival',
      'customer': customer,
      'imagePath': image.path,
      'manifestPath': '${root.path}/first.json',
      'capturedAtMs': at.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
      'automationSessionId': session,
      'replyActivationAllowed': true,
      'unreadArrivalKey': 'ax-current-customer-cycle',
      'capturePurpose': 'live_signal',
      'admissionFrontier': {
        'id': 'previous-customer-text',
        'direction': 'incoming',
        'body': 'previous problem',
        'sent_at': at.subtract(const Duration(seconds: 2)).toIso8601String(),
      },
      'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
    });
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    await store.record(evidence);
    inspection = OcrInspection(
        image: Uint8List(0),
        imageWidth: 100,
        imageHeight: 100,
        windowTitle: 'frozen sender block',
        recognizedText: '',
        observations: const [
          OcrObservation(
              text: '$customer 16:00:01',
              x: .27,
              y: .32,
              width: .23,
              height: .02,
              confidence: 1)
        ],
        capturedAt: evidence.capturedAt,
        activeCustomerId: customer,
        visualRegions: const [card]);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> interrupt() async {
    await expectLater(
        registrar.register(
            evidence: evidence,
            inspection: inspection,
            cards: const [card],
            visibleText: const [],
            frontier: evidence.metadata['admissionFrontier'] as Map,
            registerOnly: true),
        throwsStateError);
  }

  test('frozen card arrival survives an interrupted admission and newer text',
      () async {
    await interrupt();
    expect(await db.unansweredWorkCounts(), isEmpty);
    final gaps = await audit.pendingAdmissionGaps(customer: customer);
    expect(gaps, hasLength(1));
    expect(gaps.single['evidenceId'], evidence.id);
    expect(gaps.single['observedAt'], evidence.capturedAt.toIso8601String());

    // A genuine later text advances the live frontier while the old card is
    // no longer visible. Recovery consumes its own original proof, not this
    // newer text, an OCR clock or a guessed cache asset.
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: at.add(const Duration(seconds: 10)),
        messages: [
          CapturedMessage(
              stableId: 'later-real-text',
              direction: 'incoming',
              body: 'did you get my picture?',
              sender: customer,
              sentAt: at.add(const Duration(seconds: 9)),
              axPath: 'fixture')
        ]));
    final recovery =
        await registrar.recoverPendingAdmissions(customer: customer);
    expect(recovery.createdAdmissions, hasLength(1));
    expect(recovery.parents, hasLength(1));
    expect(recovery.originEvidenceIds, {evidence.id});
    expect(await audit.pendingAdmissionGaps(customer: customer), isEmpty);
    final parent = recovery.parents.single;
    expect(
        await db.isCurrentSessionMessage(customer, parent.messageId), isTrue);
    expect(await audit.captureResolved(gaps.single['observationId']! as String),
        isFalse);
    final again = await registrar.recoverPendingAdmissions(customer: customer);
    expect(again.createdAdmissions, isEmpty);
    expect(again.originEvidenceIds, {evidence.id},
        reason:
            'Bound but incomplete owners remain discoverable until resume succeeds.');
    final rows = await (await db.database).query('customer_media_items',
        where: 'customer=? AND admission_key IS NOT NULL',
        whereArgs: [customer]);
    expect(rows, hasLength(1));
    expect(rows.single['admitted_at_ms'],
        evidence.capturedAt.millisecondsSinceEpoch);
  });

  test(
      'recovery wakes the exact waiting frame once and the real consumer claims it',
      () async {
    await interrupt();
    await (await db.database).update(
        'capture_evidence', {'state': 'media_waiting'},
        where: 'id=?', whereArgs: [evidence.id]);
    final recovered =
        await registrar.recoverPendingAdmissions(customer: customer);
    expect(await store.resumeAdmittedMediaEvidence(recovered.originEvidenceIds),
        1);
    expect(await store.resumeAdmittedMediaEvidence(recovered.originEvidenceIds),
        0);
    final claimed = await store.claim(mediaOnly: true);
    expect(claimed?.id, evidence.id);
    expect(await store.claim(mediaOnly: true), isNull);
  });

  test(
      'admitted owner survives a binding failure and global maintenance discovers it',
      () async {
    db.failNextAdmission = false;
    final interruptedAudit = _InterruptedBindingAudit(db);
    final interruptedRegistrar =
        MediaMessageRegistrar(db, audit: interruptedAudit);
    await expectLater(
        interruptedRegistrar.register(
            evidence: evidence,
            inspection: inspection,
            cards: const [card],
            visibleText: const [],
            frontier: evidence.metadata['admissionFrontier'] as Map,
            registerOnly: true),
        throwsStateError);
    expect(await audit.pendingAdmissionGaps(), isEmpty,
        reason: 'A real admitted owner must never be counted twice by the UI.');
    expect(await audit.pendingAdmissionRecoveries(), hasLength(1),
        reason: 'Global maintenance must still see its unfinished binding.');
    final restored =
        await registrar.recoverPendingAdmissions(customer: customer);
    expect(restored.createdAdmissions, isEmpty);
    expect(restored.parents, hasLength(1));
    expect(restored.originEvidenceIds, {evidence.id});
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, customer]);
    expect(work, hasLength(1));
    expect(work.single['response_state'], 'pending');
    expect(work.single['answered_attempt_id'], isNull);
  });

  test(
      'a failed resume is consumed again but ready media and answered work retire recovery',
      () async {
    db.failNextAdmission = false;
    final registered = await registrar.register(
        evidence: evidence,
        inspection: inspection,
        cards: const [card],
        visibleText: const [],
        frontier: evidence.metadata['admissionFrontier'] as Map,
        registerOnly: true);
    final parent = registered.parents.values.single;
    await (await db.database).update(
        'capture_evidence', {'state': 'media_waiting'},
        where: 'id=?', whereArgs: [evidence.id]);
    store.failNextResume = true;
    await expectLater(
        store.resumeAdmittedMediaEvidence(registered.originEvidenceIds),
        throwsStateError);
    expect(await audit.pendingAdmissionGaps(), isEmpty);
    expect(await audit.pendingAdmissionRecoveries(), hasLength(1));
    final retry = await registrar.recoverPendingAdmissions(customer: customer);
    expect(retry.createdAdmissions, isEmpty);
    expect(retry.originEvidenceIds, {evidence.id});
    expect(await store.resumeAdmittedMediaEvidence(retry.originEvidenceIds), 1);
    expect(await store.resumeAdmittedMediaEvidence(retry.originEvidenceIds), 0);
    final inventory = CustomerMediaInventory(db);
    await inventory.classify(parent.receiptId, 'image',
        evidenceId: evidence.id);
    final complete = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: evidence.capturedAt,
        messages: [
          CapturedMessage(
              stableId: parent.messageId,
              direction: 'incoming',
              sender: customer,
              body: '[Customer sent an image]',
              axPath: 'fixture-complete-original',
              mediaReceiptId: parent.receiptId,
              media: [
                CapturedMedia(
                    type: 'image',
                    path: evidence.imagePath,
                    captureSource: 'jd_image_cache')
              ])
        ]);
    await db.saveCapture(complete);
    await inventory.persist(complete,
        verifiedAnchor: true, currentTaskOnly: true);
    expect(await inventory.analysisReadyMessageIds(customer),
        contains(parent.messageId));
    expect(await audit.pendingAdmissionRecoveries(), isEmpty,
        reason: 'An original ready for generation must not be reacquired.');
    expect(await store.resumeAdmittedMediaEvidence({evidence.id}), 0);
    // A pending opaque placeholder may still be unresolved in audit after a
    // real native reply. The exact work state also retires recovery.
    await (await db.database).update(
        'automation_session_messages', {'response_state': 'answered'},
        where: 'message_id=?', whereArgs: [parent.messageId]);
    expect(await audit.pendingAdmissionRecoveries(), isEmpty);
  });

  test(
      'orphan reused is unresolved and cannot manufacture visible business gaps',
      () async {
    final id = await audit.discover(evidence, card, inspection: inspection);
    await audit
        .finish(id, 'reused', {'reason': 'asset_matched_without_parent'});
    expect(await audit.captureResolved(id), isFalse);
    expect((await audit.stateCounts(evidence.id))['unbound'], 1);
    expect(await audit.pendingAdmissionGaps(customer: customer), isEmpty,
        reason:
            'an unproved observation must not count as a new customer message');
  });

  test(
      'sparse legacy details use the row customer and cannot borrow a foreign parent',
      () async {
    db.failNextAdmission = false;
    final registered = await registrar.register(
        evidence: evidence,
        inspection: inspection,
        cards: const [card],
        visibleText: const [],
        frontier: evidence.metadata['admissionFrontier'] as Map,
        registerOnly: true);
    final parent = registered.parents.values.single;
    final foreign = ViewportEvidence({
      ...evidence.metadata,
      'evidenceId': 'different-customer-observation',
      'customer': 'different-customer'
    });
    final observation = await audit.discover(foreign, card);
    final sql = await db.database;
    final row = (await sql.query('media_capture_audit',
            where: 'observation_id=?', whereArgs: [observation]))
        .single;
    final sparse = jsonDecode(row['details']! as String) as Map;
    sparse.remove('customer');
    await sql.update('media_capture_audit', {'details': jsonEncode(sparse)},
        where: 'observation_id=?', whereArgs: [observation]);
    await audit.finish(observation, 'reused', {
      'parentMessageId': parent.messageId,
      'mediaReceiptId': parent.receiptId,
    });
    expect(await audit.captureResolved(observation), isFalse);
    final saved = (await sql.query('media_capture_audit',
            where: 'observation_id=?', whereArgs: [observation]))
        .single;
    expect(saved['state'], 'unbound');
    expect((jsonDecode(saved['details']! as String) as Map)['customer'],
        'different-customer');
  });

  test('Stop or a new session cannot consume the old frozen admission proof',
      () async {
    await interrupt();
    await expectLater(
        registrar.recoverPendingAdmissions(
            customer: customer,
            checkCurrent: () => throw StateError('stopped')),
        throwsStateError);
    expect(await audit.pendingAdmissionGaps(customer: customer), hasLength(1));
    await db.beginAutomationSession(
        startedAt: at.add(const Duration(minutes: 5)));
    expect(await audit.pendingAdmissionGaps(customer: customer), isEmpty);
    expect(
        (await registrar.recoverPendingAdmissions(customer: customer))
            .createdAdmissions,
        isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });
}
