import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

import 'support/legacy_media_owner.dart';

const _customer = 'jd_timestamp_media';
const _card =
    OcrVisualRegion(x: .28, y: .35, width: .2, height: .2, confidence: 1);
final _sent = DateTime.utc(2026, 11, 10, 4, 0, 5);

class _NoPhysicalBusinessGate extends MediaCaptureAudit {
  _NoPhysicalBusinessGate(super.database);
  bool denyPhysical = true;
  int physicalCalls = 0;

  @override
  Future<Uint8List?> frozenCardPreview(
      ViewportEvidence evidence, OcrVisualRegion region) async {
    physicalCalls++;
    if (denyPhysical) throw StateError('physical pixels delayed business');
    return null;
  }

  @override
  Future<bool> proveUnknownVideoOwner(ViewportEvidence evidence,
      OcrInspection inspection, OcrVisualRegion region, String observationId,
      {required Iterable<OcrVisualRegion> physicalCards}) async {
    if (denyPhysical) throw StateError('old video repair delayed business');
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late _NoPhysicalBusinessGate audit;
  late MediaMessageRegistrar registrar;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v49_timestamp_media_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: _sent.subtract(const Duration(seconds: 2)));
    inventory = CustomerMediaInventory(db);
    audit = _NoPhysicalBusinessGate(db);
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  ViewportEvidence evidence(String id, {int second = 5}) => ViewportEvidence({
        'evidenceId': id,
        'customer': _customer,
        'capturedAtMs':
            _sent.add(Duration(seconds: second)).millisecondsSinceEpoch,
        'automationSessionId': db.currentAutomationSessionId,
        'automationSessionStartedAtMs':
            _sent.subtract(const Duration(seconds: 2)).millisecondsSinceEpoch,
        'replyActivationAllowed': true,
        'capturePurpose': 'live_signal',
        'navigationCutoffSource': 'current_viewport',
        'verifiedLiveBottom': true,
        'discoveryAnchorId': id,
        'unreadArrivalKey': 'current-AX-arrival',
        'manifestPath': '/synthetic/$id.json',
        'imagePath': '/synthetic/$id.png',
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
      });
  OcrInspection view({double confidence = 1, int second = 5}) =>
      OcrInspection.fromMap({
        'windowId': 1,
        'activeCustomerId': _customer,
        'capturedAtMs':
            _sent.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
        'observations': [
          {
            'text': '$_customer 12:00:${second.toString().padLeft(2, '0')}',
            'confidence': confidence,
            'x': .27,
            'y': .3,
            'width': .3,
            'height': .02,
          }
        ],
        'unboundMediaRegions': [
          {
            'x': .28,
            'y': .35,
            'width': .2,
            'height': .2,
            'confidence': 1,
            'proof': 'explicit_play_overlay'
          }
        ],
      });
  Future<List<Map>> incoming() async =>
      ((await (await db.history).read(_customer))?['messages'] as List? ??
              const [])
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();

  test('complete time creates one owner without old physical matching',
      () async {
    final frame = evidence('complete');
    const nested =
        OcrVisualRegion(x: .29, y: .36, width: .18, height: .18, confidence: 1);
    final registered = await registrar.register(
        evidence: frame,
        inspection: view(),
        cards: [_card, nested],
        visibleText: [],
        frontier: null,
        registerOnly: true,
        nextMessageId: () => throw StateError('random owner requested'));
    final id = CustomerMessageTime.incomingId(_customer, _sent);
    expect(registered.parents.values.map((p) => p.messageId).toSet(), {id});
    expect(await incoming(), hasLength(1));
    expect((await db.customerMessageRecords(_customer)), hasLength(1));
    expect(audit.physicalCalls, 0);
    expect(registered.createdAdmissions, hasLength(1));
  });

  test('unclocked arrival stays evidence rather than a random business owner',
      () async {
    audit.denyPhysical = false;
    final frame = evidence('weak-clock');
    final weak = view(confidence: .3);
    expect(const OcrCaptureExtractor().mediaClockForRegion(weak, _card).sentAt,
        isNull);
    final registered = await registrar.register(
        evidence: frame,
        inspection: weak,
        cards: [_card],
        visibleText: [],
        frontier: null,
        registerOnly: true,
        nextMessageId: () => throw StateError('random owner requested'));
    expect(registered.createdAdmissions, isEmpty);
    expect(await incoming(), isEmpty);
    final pending = await audit.pendingAdmissionRecoveries(customer: _customer);
    expect(pending, isNotEmpty);
    final recovered =
        await registrar.recoverPendingAdmissions(customer: _customer);
    expect(recovered.createdAdmissions, isEmpty);
    expect(await incoming(), isEmpty);
    expect(await audit.pendingAdmissionRecoveries(customer: _customer),
        isNotEmpty);
    await expectLater(
        db.admitMediaMessage(_customer,
            receiptId: registered.receipts[_card]!,
            evidenceId: frame.id,
            occurrenceKey: 'must-not-create-random-business',
            receivedAt: frame.capturedAt,
            messageId: 'random-owner'),
        throwsStateError);
  });

  test('same immutable sender block refines a legacy parent before admission',
      () async {
    final frame = evidence('legacy-frame');
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: frame.id,
        observedAt: frame.capturedAt,
        senderAt: null,
        slot: 0,
        region: [.28, .35, .2, .2],
        current: true,
        occurrenceKey: 'legacy-unclocked-block');
    await seedLegacyClocklessMediaOwner(db,
        customer: _customer,
        receiptId: receipt,
        messageId: 'legacy-parent',
        evidenceId: frame.id,
        occurrenceKey: 'legacy-unclocked-block',
        receivedAt: frame.capturedAt);
    final observation = await audit.discover(frame, _card, inspection: view());
    await audit.finish(observation, 'unbound', {
      'mediaReceiptId': receipt,
      'parentMessageId': 'legacy-parent',
      'senderClock': null,
    });
    final registered = await registrar.register(
        evidence: frame,
        inspection: view(),
        cards: [_card],
        visibleText: [],
        frontier: null,
        registerOnly: true);
    expect(registered.parents[_card]!.messageId, 'legacy-parent');
    expect(registered.createdAdmissions, isEmpty);
    expect(await incoming(), hasLength(1));
    expect(await db.incomingMessageIdAtTime(_customer, _sent), 'legacy-parent');
    expect(audit.physicalCalls, 0);
  });

  test(
      'a formerly unreadable pre-Start clock cannot promote its old arrival proof',
      () async {
    audit.denyPhysical = false;
    final frame = evidence('old-clock-becomes-readable');
    await registrar.register(
        evidence: frame,
        inspection: view(confidence: .3, second: 1),
        cards: [_card],
        visibleText: [],
        frontier: null,
        registerOnly: true);
    expect(await audit.pendingAdmissionRecoveries(customer: _customer),
        isNotEmpty);
    audit.denyPhysical = true;
    await registrar.register(
        evidence: frame,
        inspection: view(second: 1),
        cards: [_card],
        visibleText: [],
        frontier: null,
        registerOnly: true);
    await registrar.recoverPendingAdmissions(customer: _customer);
    expect(await incoming(), isEmpty);
    expect(
        await audit.pendingAdmissionRecoveries(customer: _customer), isEmpty);
  });

  test('old explicit receipt cannot override a different message second',
      () async {
    final oldReceipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'old',
        observedAt: _sent,
        senderAt: _sent,
        slot: 0,
        region: [.28, .35, .2, .2],
        current: true);
    final old = await db.admitMediaMessage(_customer,
        receiptId: oldReceipt,
        evidenceId: 'old',
        occurrenceKey: 'old',
        receivedAt: _sent,
        senderAt: _sent);
    final oldParent = (await inventory.resolveParent(_customer,
        receiptId: old.receiptId, requireCurrentSession: true))!;
    final next = _sent.add(const Duration(seconds: 1));
    final newReceipt = await inventory.observe(
        customer: _customer,
        evidenceId: 'new',
        observedAt: next,
        senderAt: next,
        slot: 0,
        region: [.28, .35, .2, .2],
        current: true,
        parentReceiptId: oldReceipt);
    expect(newReceipt, isNot(oldReceipt));
    final frame = evidence('new');
    final observation =
        await audit.discover(frame, _card, inspection: view(second: 6));
    expect(
        await audit.bindMessageTime(observation,
            senderAt: next, parent: oldParent),
        isEmpty);
    expect(await inventory.recordedSenderTime(_customer, oldReceipt), _sent);
  });
}
