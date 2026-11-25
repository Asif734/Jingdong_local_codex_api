import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

const _fixtures = 'test/fixtures/v46_admitted_loading_images';
const _customer = 'jd_5f2331ef08167';
typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection inspection,
  OcrVisualRegion region,
  String name
});

class _CrashAfterOwnerCommit extends CustomerMediaInventory {
  _CrashAfterOwnerCommit(super.database);
  bool crash = true;
  @override
  Future<({String canonicalReceiptId, String duplicateReceiptId})?>
      bindProvenBubbleOwners(String customer,
          {required String proofObservationId,
          required String expectedSessionId}) async {
    final result = await super.bindProvenBubbleOwners(customer,
        proofObservationId: proofObservationId,
        expectedSessionId: expectedSessionId);
    if (result != null && crash) {
      crash = false;
      throw StateError('fixture_crash_after_atomic_inventory_commit');
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late MediaCaptureAudit audit;
  late MediaMessageRegistrar registrar;
  const channel = MethodChannel('v46-loading-image-native');
  final sends = <String>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v46_loading_image_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 10, 2, 13));
    inventory = CustomerMediaInventory(db);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
    sends.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['expectedCustomer'], _customer);
      if (call.method == 'openConversation') {
        return {'opened': true, 'customer': _customer};
      }
      if (call.method != 'sendDraftOnce') throw StateError(call.method);
      sends.add(args['reply'] as String);
      final at = DateTime.now().millisecondsSinceEpoch;
      await File(args['receiptPath'] as String).writeAsString(jsonEncode({
        'attemptId': args['attemptId'],
        'customer': _customer,
        'state': 'submitted',
        'sendClickedAtMs': at,
        'timeMs': at
      }));
      return {
        'sent': true,
        'customer': _customer,
        'activeCustomerId': _customer,
        'sendClickedAtMs': at
      };
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
    await root.delete(recursive: true);
  });
  Future<_Frame> frame(String name,
      {String suffix = '', bool newArrival = false}) async {
    final manifest =
        jsonDecode(await File('$_fixtures/provenance.json').readAsString())
            as Map;
    final info = manifest['frames'][name] as Map;
    final bytes = await File('$_fixtures/$name.png').readAsBytes();
    final ocr = await File('$_fixtures/$name.ocr.json').readAsBytes();
    final cap = await File('$_fixtures/$name.capture.json').readAsBytes();
    expect(sha256.convert(bytes).toString(), info['pngSHA256']);
    expect(sha256.convert(ocr).toString(), info['ocrSHA256']);
    expect(sha256.convert(cap).toString(), info['captureSHA256']);
    final metadata =
        Map<String, Object?>.from(jsonDecode(utf8.decode(cap)) as Map);
    final id = '${metadata['evidenceId']}$suffix';
    metadata.addAll({
      'automationSessionId': db.currentAutomationSessionId,
      'imagePath': File('$_fixtures/$name.png').absolute.path,
      'evidenceId': id,
      'manifestPath': '${root.path}/$id.json'
    });
    if (newArrival) {
      // Simulate the actual first-read AX signal of the independent resend;
      // the recorded late reread had already advanced its frontier to itself.
      metadata['unreadArrivalKey'] = 'arrival:independent-resend';
      metadata['admissionFrontier'] = null;
    }
    if (metadata['pinnedMedia'] case final Map pin) {
      metadata['pinnedMedia'] = {
        ...pin,
        'evidenceFile': File('$_fixtures/$name.original').absolute.path
      };
    }
    final evidence = ViewportEvidence(metadata);
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map),
      'pngBase64': base64Encode(bytes)
    });
    const selector = OcrImageCandidateSelector();
    final extraction = const OcrCaptureExtractor().analyze(view);
    final incoming = extraction.capture?.messages
            .where((m) => m.direction == 'incoming')
            .map((m) => m.body) ??
        const <String>[];
    var cards = selector.select(view, _customer,
        includeTextDense: true,
        allowUnlabeledLatestImage: true,
        customerText: incoming);
    cards = selector.recoverCustomerBlocks(view, _customer,
        owned: cards, hasPinnedImage: evidence.pinnedMedia?['kind'] == 'image');
    if (cards.isEmpty && !extraction.latestIncomingHasText) {
      final fallback = selector.fallbackLatestCustomerBlock(view, _customer);
      if (fallback != null) cards = [fallback];
    }
    expect(cards, hasLength(1), reason: '$name actual selector proposal');
    final clock =
        const OcrCaptureExtractor().mediaClockForRegion(view, cards.single);
    expect(clock.source, 'ocr_media_sender_header',
        reason: '$name ${jsonEncode({
              'region': [
                cards.single.x,
                cards.single.y,
                cards.single.width,
                cards.single.height
              ],
              'clockSource': clock.source,
              'headerTop': clock.headerTop,
              'headerBottom': clock.headerBottom
            })}');
    return (
      evidence: evidence,
      inspection: view,
      region: cards.single,
      name: name
    );
  }

  Future<MediaMessageRegistration> register(_Frame frame) async {
    final result = await registrar.register(
        evidence: frame.evidence,
        inspection: frame.inspection,
        cards: [frame.region],
        visibleText:
            const OcrCaptureExtractor().extract(frame.inspection)?.messages ??
                const [],
        frontier: frame.evidence.metadata['admissionFrontier'] as Map?,
        registerOnly: true);
    expect(result.parents, isNotEmpty,
        reason: jsonEncode({
          'frame': frame.name,
          'clock': result.clocks[frame.region]?.sentAt?.toIso8601String(),
          'groups': result.groups.values.toList(),
          'occurrences': result.occurrences.values.toList(),
          'receipts': result.receipts.values.toList()
        }));
    return result;
  }

  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer]);
  Future<
      List<
          Map<String, Object?>>> owners() async => (await db.database).query(
      'customer_media_items',
      where:
          'customer=? AND admission_session_id=? AND message_id IS NOT NULL AND canonical_id IS NULL',
      whereArgs: [_customer, db.currentAutomationSessionId]);
  Future<void> complete(MediaParent parent, _Frame loaded) async {
    final pin = loaded.evidence.pinnedMedia!;
    final bytes = await File(pin['evidenceFile']! as String).readAsBytes();
    final manifest =
        jsonDecode(await File('$_fixtures/provenance.json').readAsString())
            as Map;
    expect(sha256.convert(bytes).toString(),
        manifest['frames'][loaded.name]['originalSHA256']);
    final path = await (await db.history).saveMedia(
        userId: _customer, filename: 'recorded-original.jpeg', bytes: bytes);
    await inventory.classify(parent.receiptId, 'image');
    final capture = CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: loaded.evidence.capturedAt,
        messages: [
          CapturedMessage(
              stableId: parent.messageId,
              direction: 'incoming',
              sender: _customer,
              body: '[Customer sent an image; original copied from JD cache]',
              sentAt: const OcrCaptureExtractor()
                  .mediaClockForRegion(loaded.inspection, loaded.region)
                  .sentAt,
              axPath: 'verified-recorded-cache-original',
              mediaReceiptId: parent.receiptId,
              media: [
                CapturedMedia(
                    type: 'image',
                    path: path,
                    mimeType: 'image/jpeg',
                    captureSource: 'jd_image_cache',
                    description: '图片完整显示 Windows 打印机端口设置和勾选的 USB 接口。')
              ])
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    await audit.resolveCaptured(capture);
  }

  Future<String> formal(MediaParent parent, {Set<String>? inputs}) async {
    final pending = (await db.conversation(_customer))!;
    final token = (await db.beginGeneration(
        customer: _customer,
        pendingId: pending.id,
        batchEndMessageId: parent.messageId))!;
    expect(
        await db.generationInputsAnalysisReady(_customer,
            generationToken: token),
        true);
    final input = (await db.generationMessages(_customer,
            batchEndMessageId: parent.messageId))
        .where((m) => m['direction'] == 'incoming');
    expect(input.map((m) => m['id']).toSet(), inputs ?? {parent.messageId});
    final draft = await db.prepareAutomaticDraft(
        _customer,
        AiDraft.fromJson({
          'reply': '请打开打印机属性的端口设置，核对当前勾选的 USB 端口。',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v46-native-confirmation'
        }, mediaBaseUrl: Uri()));
    expect(
        await db.saveDraft(pending.id, draft,
            expectedMessageId: parent.messageId,
            expectedUserId: _customer,
            generationToken: token),
        1);
    await db.abandonGeneration(_customer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
    final adapter = MacOSCaptureAdapter(channel: channel);
    await adapter.openConversation(_customer, allowActivation: true);
    expect(
        (await adapter.sendDraftOnce(
            expectedCustomer: _customer,
            reply: draft.reply,
            attemptId: attempt['attemptId'],
            receiptPath: attempt['receiptPath']))['sent'],
        true);
    await db.recoverDeliveryReceipts();
    return attempt['attemptId']!;
  }

  Future<
      ({
        MediaParent whiteParent,
        MediaParent loadedParent,
        _Frame white,
        _Frame loaded
      })> legacySplit(String prefix) async {
    final white = await frame('$prefix-white');
    final loaded = await frame('$prefix-loaded');
    final first = (await register(white)).parents.values.single;
    // Recreate the shipped unmatched-loaded admission; the production recovery
    // subsequently receives only these actual immutable frames, no chosen owner.
    final observation = await audit.discover(loaded.evidence, loaded.region,
        inspection: loaded.inspection, physicalCards: [loaded.region]);
    final senderAt = const OcrCaptureExtractor()
        .mediaClockForRegion(loaded.inspection, loaded.region)
        .sentAt;
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: loaded.evidence.id,
        observedAt: loaded.evidence.capturedAt,
        senderAt: senderAt,
        slot: 0,
        region: [
          loaded.region.x,
          loaded.region.y,
          loaded.region.width,
          loaded.region.height
        ],
        current: true,
        occurrenceKey: 'bubble:$observation');
    final admitted = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: loaded.evidence.id,
        occurrenceKey: 'bubble:$observation',
        receivedAt: loaded.evidence.capturedAt,
        senderAt: senderAt);
    final preview =
        (await audit.frozenCardPreview(loaded.evidence, loaded.region))!;
    final path = await (await db.history).saveMedia(
        userId: _customer, filename: 'legacy-loaded-crop.png', bytes: preview);
    await audit.finish(observation, 'discovered',
        {'previewPath': path, 'cardOccurrenceProven': true});
    await audit.bindParent(observation,
        receiptId: receipt, messageId: admitted.messageId);
    final second = (await inventory.resolveParent(_customer,
        receiptId: receipt, requireCurrentSession: true))!;
    expect(first.messageId, isNot(second.messageId));
    expect(await owners(), hasLength(2));
    return (
      whiteParent: first,
      loadedParent: second,
      white: white,
      loaded: loaded
    );
  }

  Future<void> expectCoherentOwners() async {
    final rows = await (await db.database).query('media_capture_audit');
    for (final row in rows) {
      final details = jsonDecode(row['details']! as String) as Map;
      if (details['parentMessageId'] is! String) continue;
      final parent = await inventory.resolveParent(_customer,
          receiptId: details['mediaReceiptId']! as String,
          requireCurrentSession: true);
      expect(parent, isNotNull);
      expect(details['parentMessageId'], parent!.messageId);
      if (parent.admissionKey!.startsWith('bubble:')) {
        expect(
            details['observationGroupId'], parent.admissionKey!.substring(7));
        if (details['liveArrivalProof'] case final Map proof) {
          expect(proof['observationGroupId'], details['observationGroupId']);
          expect(proof['occurrenceKey'], parent.admissionKey);
        }
      }
    }
  }

  test(
      'physical image repair proof cannot cross customer or automation session',
      () async {
    final old = await legacySplit('second');
    final observed = await audit.discover(old.white.evidence, old.white.region,
        inspection: old.white.inspection, physicalCards: [old.white.region]);
    final proof = await audit.groupUnbound(
        old.white.evidence, old.white.region, observed,
        inspection: old.white.inspection, physicalCards: [old.white.region]);
    expect(proof['sameBubbleOwnerProof'], isA<Map>());
    final session = db.currentAutomationSessionId!;
    expect(
        await inventory.bindProvenBubbleOwners('jd_other_customer',
            proofObservationId: observed, expectedSessionId: session),
        isNull);
    expect(await owners(), hasLength(2));
    await db.beginAutomationSession(startedAt: DateTime.utc(2026, 11, 10, 3));
    expect(
        await inventory.bindProvenBubbleOwners(_customer,
            proofObservationId: observed, expectedSessionId: session),
        isNull);
    expect(
        await inventory.bindProvenBubbleOwners(_customer,
            proofObservationId: observed,
            expectedSessionId: db.currentAutomationSessionId!),
        isNull);
  });
  test('loading repair cannot consume a stale proof once that owner is ready',
      () async {
    final old = await legacySplit('second');
    final observed = await audit.discover(old.white.evidence, old.white.region,
        inspection: old.white.inspection, physicalCards: [old.white.region]);
    final proof = await audit.groupUnbound(
        old.white.evidence, old.white.region, observed,
        inspection: old.white.inspection, physicalCards: [old.white.region]);
    expect(proof['sameBubbleOwnerProof'], isA<Map>());
    await complete(old.whiteParent, old.loaded);
    expect(
        await inventory.bindProvenBubbleOwners(_customer,
            proofObservationId: observed,
            expectedSessionId: db.currentAutomationSessionId!),
        isNull);
    expect(await owners(), hasLength(2));
    expect(await db.hasPendingUnanswered(_customer), true);
    expect(sends, isEmpty);
  });

  for (final prefix in ['first', 'second']) {
    test(
        'recorded $prefix existing split repairs from strong image proof and only an actual native formal receipt covers it',
        () async {
      final old = await legacySplit(prefix);
      await complete(old.loadedParent, old.loaded);
      // A different owner's ready original must not mutate this preview tuple.
      await expectCoherentOwners();
      final attempt = await formal(old.loadedParent);
      expect(
          await db.isMessageFormallyAnswered(
              _customer, old.whiteParent.messageId),
          false);
      final repair = (await register(old.white)).parents.values.single;
      expect(repair.messageId, old.whiteParent.messageId);
      expect(await owners(), hasLength(1));
      await expectCoherentOwners();
      expect(await db.hasPendingUnanswered(_customer), false);
      expect((await work()).map((r) => r['answered_attempt_id']),
          everyElement(attempt));
      expect(await db.customerMessageRecords(_customer), hasLength(1));
      expect(sends, hasLength(1));
      expect((await register(old.loaded)).parents.values.single.messageId,
          repair.messageId);
    });
  }
  test(
      'strong image alias without formal native receipt stays genuinely unanswered',
      () async {
    final old = await legacySplit('second');
    await complete(old.loadedParent, old.loaded);
    await register(old.white);
    expect(await owners(), hasLength(1));
    await expectCoherentOwners();
    expect(await db.hasPendingUnanswered(_customer), true);
    expect((await work()).map((r) => r['response_state']),
        everyElement('pending'));
    expect(sends, isEmpty);
  });
  test(
      'crash after atomic owner transaction is recovered before next admission without a second send',
      () async {
    final old = await legacySplit('first');
    await complete(old.loadedParent, old.loaded);
    final attempt = await formal(old.loadedParent);
    final crashing = _CrashAfterOwnerCommit(db);
    registrar = MediaMessageRegistrar(db, inventory: crashing, audit: audit);
    await expectLater(register(old.white), throwsStateError);
    expect(await owners(), hasLength(1));
    await expectCoherentOwners();
    expect(
        await db.isMessageFormallyAnswered(
            _customer, old.whiteParent.messageId),
        false);
    final rows = await (await db.database).query('media_capture_audit');
    expect(
        rows.any((r) =>
            (jsonDecode(r['details']! as String)
                as Map)['sameBubbleOwnerRepair']?['phase'] ==
            'inventory_committed'),
        true);
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
    expect(await audit.pendingAdmissionRecoveries(customer: _customer), isEmpty,
        reason: 'Owner reconciliation has no new admission gap to wake it.');
    // No further frame or register() call: quiet maintenance must discover the
    // durable transaction journal independently of capture/admission work.
    final repairCustomers = await registrar.pendingOwnerRepairCustomers();
    expect(repairCustomers, {_customer});
    for (final customer in repairCustomers) {
      await registrar.recoverPendingAdmissions(customer: customer);
    }
    expect(await db.hasPendingUnanswered(_customer), false);
    expect((await work()).map((r) => r['answered_attempt_id']),
        everyElement(attempt));
    expect(await registrar.pendingOwnerRepairCustomers(), isEmpty);
    expect(sends, hasLength(1));
    expect(await owners(), hasLength(1));
  });
  test(
      'legacy mixed audit tuple is restored from exact unfinished parent before physical repair',
      () async {
    final old = await legacySplit('second');
    await complete(old.loadedParent, old.loaded);
    final attempt = await formal(old.loadedParent);
    final sql = await db.database;
    final row = (await sql.query('media_capture_audit',
            where: 'evidence_id=?', whereArgs: [old.white.evidence.id]))
        .single;
    final details = jsonDecode(row['details']! as String) as Map;
    final loadedRow = (await sql.query('media_capture_audit',
            where: 'evidence_id=?', whereArgs: [old.loaded.evidence.id]))
        .single;
    final loadedDetails = jsonDecode(loadedRow['details']! as String) as Map;
    // Exact incoherence observed in v45 snapshot, never a production-data write.
    await sql.update(
        'media_capture_audit',
        {
          'state': 'image_saved',
          'details': jsonEncode({
            ...details,
            'mediaReceiptId': old.loadedParent.receiptId,
            'observationGroupId': loadedDetails['observationGroupId'],
            'resolvedMessageId': old.loadedParent.messageId
          })
        },
        where: 'observation_id=?',
        whereArgs: [row['observation_id']]);
    final repaired = (await register(old.white)).parents.values.single;
    expect(repaired.messageId, old.whiteParent.messageId);
    await expectCoherentOwners();
    expect(await owners(), hasLength(1));
    expect((await work()).map((r) => r['answered_attempt_id']),
        everyElement(attempt));
    expect(await db.hasPendingUnanswered(_customer), false);
  });

  for (final prefix in ['first', 'second']) {
    test(
        'recorded $prefix already admitted white to loaded keeps one owner through formal and late callbacks',
        () async {
      final white = await frame('$prefix-white');
      final loaded = await frame('$prefix-loaded');
      final first = (await register(white)).parents.values.single;
      expect(await work(), hasLength(1));
      expect(await inventory.analysisReadyMessageIds(_customer), isEmpty);
      final ready = (await register(loaded)).parents.values.single;
      expect(ready.messageId, first.messageId);
      expect(ready.receiptId, first.receiptId);
      expect(await owners(), hasLength(1));
      expect(await work(), hasLength(1));
      await complete(ready, loaded);
      final attempt = await formal(ready);
      for (final read in [white, loaded, white, loaded]) {
        expect((await register(read)).parents.values.single.messageId,
            first.messageId);
      }
      expect(await owners(), hasLength(1));
      expect(await work(), hasLength(1));
      expect((await work()).single['answered_attempt_id'], attempt);
      expect(await db.hasPendingUnanswered(_customer), false);
      expect(sends, hasLength(1));
    });
  }

  test(
      'interleaved real white sends remain two owners, and a separate same-file resend stays distinct',
      () async {
    final firstWhite = await frame('first-white');
    final secondWhite = await frame('second-white');
    final first = (await register(firstWhite)).parents.values.single;
    final second = (await register(secondWhite)).parents.values.single;
    expect(first.messageId, isNot(second.messageId));
    final later = await Future.wait([
      register(await frame('second-loaded')),
      register(firstWhite),
      register(await frame('first-loaded')),
      register(secondWhite)
    ]);
    expect(later[0].parents.values.single.messageId, second.messageId);
    expect(later[1].parents.values.single.messageId, first.messageId);
    expect(later[2].parents.values.single.messageId, first.messageId);
    expect(later[3].parents.values.single.messageId, second.messageId);
    expect(await owners(), hasLength(2));
    final resend =
        (await register(await frame('independent-resend', newArrival: true)))
            .parents
            .values
            .single;
    expect(resend.messageId, isNot(second.messageId));
    expect(await owners(), hasLength(3));
    expect(await work(), hasLength(3));
  });
}
