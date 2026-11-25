import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/incoming_message_ownership.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

const _customer = 'jd_41aeec7741d05';
const _folder = 'test/fixtures/v47_video_owner_boundary';
typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection view,
  OcrVisualRegion card
});

class _CountingInventory extends CustomerMediaInventory {
  _CountingInventory(super.database);
  int observes = 0;
  @override
  Future<String> observe(
      {required String customer,
      required String evidenceId,
      required DateTime observedAt,
      required DateTime? senderAt,
      required int slot,
      required List<double> region,
      required bool current,
      String? occurrenceKey,
      String? parentReceiptId}) {
    observes++;
    return super.observe(
        customer: customer,
        evidenceId: evidenceId,
        observedAt: observedAt,
        senderAt: senderAt,
        slot: slot,
        region: region,
        current: current,
        occurrenceKey: occurrenceKey,
        parentReceiptId: parentReceiptId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late _CountingInventory inventory;
  late MediaCaptureAudit audit;
  late MediaMessageRegistrar registrar;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v47_unknown_video_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 10, 4, 21, 31));
    inventory = _CountingInventory(db);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<_Frame> frame(String name, {bool omitPlay = false}) async {
    final provenance =
        jsonDecode(await File('$_folder/provenance.json').readAsString())
            as Map;
    final entry = provenance['frames'][name] as Map;
    final png = await File('$_folder/$name.png').readAsBytes();
    final ocr = await File('$_folder/$name.ocr.json').readAsBytes();
    final capture = await File('$_folder/$name.capture.json').readAsBytes();
    expect(sha256.convert(png).toString(), entry['pngSHA256']);
    expect(sha256.convert(ocr).toString(), entry['ocr.jsonSHA256']);
    expect(sha256.convert(capture).toString(), entry['capture.jsonSHA256']);
    final metadata = {
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map),
      'automationSessionId': db.currentAutomationSessionId,
      'imagePath': File('$_folder/$name.png').absolute.path,
      'manifestPath': '${root.path}/$name.json'
    };
    final evidence = ViewportEvidence(metadata);
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    final raw = {
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map),
      'pngBase64': base64Encode(png),
      if (omitPlay) 'unboundMediaRegions': <Object>[]
    };
    await File('${evidence.manifestPath}.ocr.json')
        .writeAsString(jsonEncode(raw));
    await CaptureEvidenceStore(db).record(evidence);
    final view = OcrInspection.fromMap(raw);
    final card = const OcrImageCandidateSelector()
        .select(view, _customer, includeTextDense: true)
        .firstWhere((r) => r.width > .15 && r.x < .3);
    return (evidence: evidence, view: view, card: card);
  }

  Future<MediaMessageRegistration> register(_Frame f) => registrar.register(
      evidence: f.evidence,
      inspection: f.view,
      cards: [f.card],
      visibleText:
          const OcrCaptureExtractor().extract(f.view)?.messages ?? const [],
      frontier: f.evidence.metadata['admissionFrontier'] as Map?,
      registerOnly: true);
  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer]);
  Future<List<Map<String, Object?>>> owners() async =>
      (await db.database).query('customer_media_items',
          where:
              'customer=? AND admission_session_id=? AND canonical_id IS NULL',
          whereArgs: [_customer, db.currentAutomationSessionId]);

  Future<({MediaParent parent, String holderObservation, String videoReceipt})>
      shippedUnknown(_Frame f) async {
    final physical = IncomingMessageOwnership.inspect(f.view, _customer, f.card,
        physicalCards: [f.card])!;
    final block = physical.bodyRegion;
    final holder = await audit.discover(f.evidence, block,
        inspection: f.view, physicalCards: [block]);
    final occurrence = 'bubble:$holder';
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: f.evidence.id,
        observedAt: f.evidence.capturedAt,
        senderAt: physical.sentAt,
        slot: 0,
        region: [block.x, block.y, block.width, block.height],
        current: true,
        occurrenceKey: occurrence);
    await audit.rememberLiveArrival(holder,
        evidence: f.evidence,
        occurrenceKey: occurrence,
        arrivalKey: f.evidence.metadata['unreadArrivalKey']! as String,
        senderAt: physical.sentAt,
        slot: 0);
    final admission = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: f.evidence.id,
        occurrenceKey: occurrence,
        receivedAt: f.evidence.capturedAt,
        senderAt: physical.sentAt,
        messageId: 'shipped-unknown14');
    await audit.bindParent(holder,
        receiptId: receipt, messageId: admission.messageId);
    final observation = await audit.discover(f.evidence, f.card,
        inspection: f.view, physicalCards: [f.card]);
    final videoReceipt = await inventory.observe(
        customer: _customer,
        evidenceId: f.evidence.id,
        observedAt: f.evidence.capturedAt,
        senderAt: null,
        slot: 0,
        region: [f.card.x, f.card.y, f.card.width, f.card.height],
        current: true);
    await inventory.classify(videoReceipt, 'video');
    await audit.finish(observation, 'video_preview_only', {
      'mediaReceiptId': videoReceipt,
      'kind': 'video',
      'verifiedOriginalPath': File('$_folder/second.original').absolute.path,
      'reason': 'pixel_matched_same_chat_video_companion'
    });
    final parent = (await inventory.resolveParent(_customer,
        receiptId: receipt, requireCurrentSession: true))!;
    final snapshot = {
      'holderReceipt': receipt,
      'videoReceipt': videoReceipt,
      'holderProof': physical.toMap(),
      'inspectionAgain': IncomingMessageOwnership.inspect(
          f.view, _customer, block,
          physicalCards: [f.card])?.toMap(),
      'items': await (await db.database).query('customer_media_items'),
      'work': await work(),
      'audit': await (await db.database).query('media_capture_audit'),
    };
    expect(videoReceipt, isNot(receipt), reason: jsonEncode(snapshot));
    expect(
        (await (await db.database).query('customer_media_items',
                where: 'item_id=?', whereArgs: [receipt]))
            .single['kind'],
        'unknown',
        reason: jsonEncode(snapshot));
    expect(
        physical.sameBlockAs(IncomingMessageOwnership.inspect(
            f.view, _customer, block,
            physicalCards: [f.card])!),
        true,
        reason: jsonEncode(snapshot));
    return (
      parent: parent,
      holderObservation: holder,
      videoReceipt: videoReceipt
    );
  }

  test(
      'actual wide unknown14 and overlapping native video are one atomic owner with its original retained',
      () async {
    final f = await frame('d3e2');
    final old = await shippedUnknown(f);
    final before = (await work()).single;
    final result = await register(f);
    expect(result.parents[f.card]!.messageId, old.parent.messageId);
    expect(result.parents[f.card]!.receiptId, old.parent.receiptId);
    expect(result.originEvidenceIds, contains(f.evidence.id));
    expect(result.createdAdmissions, isEmpty);
    expect(await owners(), hasLength(1));
    expect(await work(), hasLength(1));
    expect((await work()).single['activated_at_ms'], before['activated_at_ms']);
    expect((await work()).single['response_state'], 'pending');
    expect((await owners()).single['kind'], 'video');
    expect(await inventory.analysisReadyMessageIds(_customer), isEmpty,
        reason:
            'Binding and an original path are not a complete video analysis.');
    final resolved = await inventory.resolveParent(_customer,
        receiptId: old.videoReceipt, requireCurrentSession: true);
    expect(resolved!.messageId, old.parent.messageId);
    for (final row in await (await db.database).query('media_capture_audit')) {
      final details = jsonDecode(row['details']! as String) as Map;
      expect(details['parentMessageId'], old.parent.messageId);
      expect(details['mediaReceiptId'], old.parent.receiptId);
    }
    final count = inventory.observes;
    for (var i = 0; i < 5; i++) {
      final recovered =
          await registrar.recoverPendingAdmissions(customer: _customer);
      expect(recovered.createdAdmissions, isEmpty);
      expect(recovered.originEvidenceIds, contains(f.evidence.id));
    }
    expect(inventory.observes, count,
        reason:
            'An exact pending owner may resume but must not re-register on every poll.');
    expect(await work(), hasLength(1));
  });

  test(
      'actual weak first header refines its clock before parsing and independent same-file second send stays separate',
      () async {
    final firstFrame = await frame('cc8e');
    final first = (await register(firstFrame)).parents.values.single;
    final before = (await work()).single;
    final initial = (await (await db.history).read(_customer))!;
    expect(
        (initial['messages'] as List)
            .whereType<Map>()
            .singleWhere((m) => m['id'] == first.messageId)['sent_at'],
        isNull);
    final clear = await frame('ea6e');
    final refined = (await register(clear)).parents.values.single;
    expect(refined.messageId, first.messageId);
    expect(await work(), hasLength(1));
    expect((await work()).single['activated_at_ms'], before['activated_at_ms']);
    expect((await work()).single['response_state'], 'pending');
    final document = (await (await db.history).read(_customer))!;
    final message = (document['messages'] as List)
        .whereType<Map>()
        .singleWhere((m) => m['id'] == first.messageId);
    expect(message['sent_at'], '2026-11-10T04:26:14.000Z');
    expect(message['body'], '[Customer sent media; acquisition pending.]');
    expect((await owners()).single['sender_ms'],
        DateTime.utc(2026, 11, 10, 4, 26, 14).millisecondsSinceEpoch);
    expect(await inventory.analysisReadyMessageIds(_customer), isEmpty);
    final second = (await register(await frame('d3e2'))).parents.values.single;
    expect(second.messageId, isNot(first.messageId));
    expect(await owners(), hasLength(2));
    expect(await work(), hasLength(2));
    expect(sha256.convert(await File('$_folder/first.original').readAsBytes()),
        sha256.convert(await File('$_folder/second.original').readAsBytes()));
    final later = await register(await frame('f126'));
    expect(later.parents.values.single.messageId, second.messageId);
    expect(await work(), hasLength(2));
  });

  test(
      'an unreadable first timestamp cannot borrow the later independent same-file video sender pixels',
      () async {
    final low = await frame('cc8e');
    final first = (await register(low)).parents.values.single;
    final secondFrame = await frame('d3e2');
    final second = await register(secondFrame);
    // A missing first clock may defer the independent second admission until
    // its frontier can be proved; it must never erase this distinct sender.
    expect(second.parents.values.map((p) => p.messageId),
        isNot(contains(first.messageId)));
    final rows = await (await db.database).query('media_capture_audit',
        where: 'evidence_id=?', whereArgs: [secondFrame.evidence.id]);
    expect(
        (jsonDecode(rows.single['details']! as String)
            as Map)['observationGroupId'],
        isNot((await (await db.database).query('media_capture_audit',
                where: 'evidence_id=?', whereArgs: [low.evidence.id]))
            .single['observation_id']));
    expect(sha256.convert(await File('$_folder/first.original').readAsBytes()),
        sha256.convert(await File('$_folder/second.original').readAsBytes()));
  });

  test(
      'overlapping late calls cannot readmit the shipped unknown video or create a second pending item',
      () async {
    final f = await frame('d3e2');
    final old = await shippedUnknown(f);
    final results = await Future.wait(
        [register(f), register(f), register(await frame('f126'))]);
    expect(results.map((r) => r.parents.values.single.messageId),
        everyElement(old.parent.messageId));
    expect(await owners(), hasLength(1));
    expect(await work(), hasLength(1));
    expect((await work()).single['response_state'], 'pending');
  });

  test('unknown-to-video proof cannot cross customer or a new Start', () async {
    final f = await frame('d3e2');
    await shippedUnknown(f);
    final id = await audit.discover(f.evidence, f.card,
        inspection: f.view, physicalCards: [f.card]);
    expect(
        await audit.proveUnknownVideoOwner(f.evidence, f.view, f.card, id,
            physicalCards: [f.card]),
        true);
    expect(
        await inventory.bindUnknownVideoOwner('jd_other',
            proofObservationId: id,
            expectedSessionId: db.currentAutomationSessionId!),
        isNull);
    final session = db.currentAutomationSessionId!;
    await db.beginAutomationSession(startedAt: DateTime.utc(2026, 11, 10, 5));
    expect(
        await inventory.bindUnknownVideoOwner(_customer,
            proofObservationId: id, expectedSessionId: session),
        isNull);
    expect(
        await inventory.bindUnknownVideoOwner(_customer,
            proofObservationId: id,
            expectedSessionId: db.currentAutomationSessionId!),
        isNull);
  });

  test(
      'holder overflow beyond five-decimal serialization cannot borrow a video',
      () async {
    final f = await frame('d3e2');
    final old = await shippedUnknown(f);
    final sql = await db.database;
    final row = (await sql.query('media_capture_audit',
            where: 'observation_id=?', whereArgs: [old.holderObservation]))
        .single;
    final details = jsonDecode(row['details']! as String) as Map;
    final box = (details['region'] as List).cast<num>().toList();
    box[3] = box[3] + .00003;
    await sql.update(
        'media_capture_audit',
        {
          'details': jsonEncode({...details, 'region': box})
        },
        where: 'observation_id=?',
        whereArgs: [old.holderObservation]);
    final id = await audit.discover(f.evidence, f.card,
        inspection: f.view, physicalCards: [f.card]);
    expect(
        await audit.proveUnknownVideoOwner(f.evidence, f.view, f.card, id,
            physicalCards: [f.card]),
        false);
    expect((await owners()).single['kind'], 'unknown');
    expect(await work(), hasLength(1));
    expect((await work()).single['response_state'], 'pending');
  });

  test(
      'two physical play cards in one sender block cannot consume a broad holder',
      () async {
    final f = await frame('d3e2');
    await shippedUnknown(f);
    final raw =
        jsonDecode(await File('$_folder/d3e2.ocr.json').readAsString()) as Map;
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'pngBase64': base64Encode(f.view.image),
      'unboundMediaRegions': [
        ...(raw['unboundMediaRegions'] as List),
        {
          'x': .28,
          'y': .742,
          'width': .10,
          'height': .045,
          'confidence': 1.0,
          'proof': 'explicit_play_overlay'
        }
      ]
    });
    final id = await audit.discover(f.evidence, f.card,
        inspection: view, physicalCards: [f.card]);
    expect(
        await audit.proveUnknownVideoOwner(f.evidence, view, f.card, id,
            physicalCards: [f.card]),
        false);
    expect((await owners()).single['kind'], 'unknown');
    expect((await work()).single['response_state'], 'pending');
  });

  test(
      'a missing first play detector keeps a deferred arrival then a strong later same-card proof admits without a new red mark',
      () async {
    final first = await frame('cc8e', omitPlay: true);
    final deferred = await register(first);
    expect(deferred.parents, isEmpty);
    expect(await work(), isEmpty);
    final rows = await (await db.database).query('media_capture_audit',
        where: 'evidence_id=?', whereArgs: [first.evidence.id]);
    final candidate = jsonDecode(rows.single['details']! as String) as Map;
    expect(candidate['deferredLiveArrivalCandidate'], isA<Map>());
    expect(candidate['liveArrivalProof'], isNull);
    final clear = await frame('ea6e');
    expect(clear.evidence.metadata['unreadArrivalKey'], isNull);
    final registration = await register(clear);
    expect(registration.parents, hasLength(1));
    expect(await work(), hasLength(1));
    expect((await work()).single['activated_at_ms'],
        first.evidence.capturedAt.millisecondsSinceEpoch);
    expect(registration.originEvidenceIds, contains(first.evidence.id));
    expect((await work()).single['response_state'], 'pending');
  });
}
