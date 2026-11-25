import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_card_occurrence.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

const _customer = 'jd_mbnrscuhukvy';
const _fixtures = 'test/fixtures/v43_image_bubble_identity';
const _channel = MethodChannel('v43-recorded-image-bubbles');

typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection inspection,
  OcrVisualRegion region
});

class _ImageFlow {
  _ImageFlow(this.root, this.db) {
    inventory = CustomerMediaInventory(db);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, audit: audit, inventory: inventory);
  }
  final Directory root;
  final CaptureDatabase db;
  late final CustomerMediaInventory inventory;
  late final MediaCaptureAudit audit;
  late final MediaMessageRegistrar registrar;
  final adapter = MacOSCaptureAdapter(channel: _channel);
  final fixtures = <String, Map<String, dynamic>>{};
  final sends = <String>[];
  final generated = <Set<String>>[];
  var sequence = 0;
  late String original;

  Future<void> initialize() async {
    final provenance =
        jsonDecode(await File('$_fixtures/provenance.json').readAsString())
            as Map;
    fixtures.addAll((provenance['frames'] as Map).map(
        (key, value) => MapEntry('$key', Map<String, dynamic>.from(value))));
    final bytes = await File('$_fixtures/shared-original.jpeg').readAsBytes();
    expect(
        sha256.convert(bytes).toString(), provenance['sharedOriginalSha256']);
    original = (await (await db.history).saveMedia(
        userId: _customer, filename: 'shared-original.jpeg', bytes: bytes));
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 9, 3, 39));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
      if (call.method == 'openConversation') {
        expect(args['expectedCustomer'], _customer);
        return {'opened': true, 'customer': _customer};
      }
      if (call.method == 'sendDraftOnce') {
        expect(args['expectedCustomer'], _customer);
        sends.add(args['reply']! as String);
        final at = DateTime.now().millisecondsSinceEpoch;
        await File(args['receiptPath']! as String).writeAsString(jsonEncode({
          'attemptId': args['attemptId'],
          'customer': _customer,
          'state': 'submitted',
          'sendClickedAtMs': at,
          'timeMs': at,
        }));
        return {
          'sent': true,
          'customer': _customer,
          'activeCustomerId': _customer,
          'sendClickedAtMs': at
        };
      }
      throw StateError('Unexpected native operation: ${call.method}');
    });
  }

  Future<_Frame> frame(String name,
      {String? suffix, Map<String, Object?> metadata = const {}}) async {
    final info = fixtures[name]!;
    final image = File('$_fixtures/$name.png');
    final ocr = File('$_fixtures/$name.ocr.json');
    final bytes = await image.readAsBytes();
    expect(sha256.convert(bytes).toString(), info['pngSHA256']);
    expect(
        sha256.convert(await ocr.readAsBytes()).toString(), info['ocrSHA256']);
    final id = '${info['recordedEvidenceId']}${suffix ?? ''}';
    final evidence = ViewportEvidence({
      ...Map<String, Object?>.from(info['metadata'] as Map),
      'automationSessionId': db.currentAutomationSessionId,
      'imagePath': image.absolute.path,
      'manifestPath': '${root.path}/$id.json',
      'evidenceId': id,
      ...metadata,
    });
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    final raw =
        Map<String, Object?>.from(jsonDecode(await ocr.readAsString()) as Map);
    final inspection = OcrInspection.fromMap({
      ...raw,
      'pngBase64': base64Encode(bytes),
      'capturedAtMs': evidence.metadata['capturedAtMs'],
    });
    final box = (info['region'] as List).cast<num>();
    return (
      evidence: evidence,
      inspection: inspection,
      region: OcrVisualRegion(
          x: box[0].toDouble(),
          y: box[1].toDouble(),
          width: box[2].toDouble(),
          height: box[3].toDouble(),
          confidence: 1)
    );
  }

  Future<MediaParent?> register(_Frame frame) async {
    final visible = const OcrCaptureExtractor().extract(frame.inspection);
    final result = await registrar.register(
        evidence: frame.evidence,
        inspection: frame.inspection,
        cards: [frame.region],
        visibleText: visible?.messages ?? const [],
        frontier: frame.evidence.metadata['admissionFrontier'] as Map?,
        registerOnly: true,
        nextMessageId: () =>
            'incoming-image:${db.currentAutomationSessionId}:${++sequence}');
    return result.parents[frame.region];
  }

  Future<MediaParent> receive(String name) async {
    final parent = await register(await frame(name));
    expect(parent, isNotNull,
        reason: 'Recorded re-read $name must retain its owner.');
    return parent!;
  }

  Future<void> acquire(MediaParent parent, _Frame observed) async {
    final receipt = await inventory.classify(parent.receiptId, 'image',
        fingerprint: '00f40040ffff7f00',
        previewBytes:
            await audit.frozenCardPreview(observed.evidence, observed.region),
        evidenceId: observed.evidence.id,
        region: [
          observed.region.x,
          observed.region.y,
          observed.region.width,
          observed.region.height
        ]);
    expect(receipt, parent.receiptId,
        reason:
            'Reusing one physical asset must preserve its distinct business owner.');
    final capture = CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: observed.evidence.capturedAt,
        messages: [
          CapturedMessage(
            stableId: parent.messageId,
            direction: 'incoming',
            sender: _customer,
            body: '[Customer sent an image]',
            axPath: 'actual-recorded-image',
            sentAt: const OcrCaptureExtractor()
                .mediaClockForRegion(observed.inspection, observed.region)
                .sentAt,
            mediaReceiptId: receipt,
            captureEvidenceId: observed.evidence.id,
            media: [
              CapturedMedia(
                  type: 'image',
                  path: original,
                  captureSource: 'jd_image_cache',
                  mimeType: 'image/jpeg')
            ],
          )
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    await audit.resolveCaptured(capture);
    expect(await inventory.analysisReadyMessageIds(_customer),
        contains(parent.messageId));
  }

  Future<({String token, int pending, AiDraft draft})> generate(String end,
      {required Set<String> expectedInputs}) async {
    final pending = (await db.conversation(_customer))!;
    final token = (await db.beginGeneration(
        customer: _customer, pendingId: pending.id, batchEndMessageId: end))!;
    expect(
        await db.generationInputsAnalysisReady(_customer,
            generationToken: token),
        isTrue);
    final input =
        (await db.generationMessages(_customer, batchEndMessageId: end))
            .where((m) => m['direction'] == 'incoming')
            .toList();
    final ids = input.map((m) => m['id']! as String).toSet();
    expect(ids, expectedInputs);
    generated.add(ids);
    final descriptions = <String, String>{
      original:
          'The supplied computer photo shows the printer page-orientation settings.'
    };
    await (await db.history).updateMediaDescriptions(_customer, descriptions);
    final draft = AiDraft.fromJson({
      'reply':
          'Select the correct paper orientation and size in the printer preferences.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-v43-image-coverage',
      'image_descriptions': [
        for (final entry in descriptions.entries)
          {'path': entry.key, 'description': entry.value}
      ],
    }, mediaBaseUrl: Uri());
    return (token: token, pending: pending.id, draft: draft);
  }

  Future<String> deliver(({String token, int pending, AiDraft draft}) generated,
      String end) async {
    final prepared = await db.prepareAutomaticDraft(_customer, generated.draft);
    expect(
        await db.saveDraft(generated.pending, prepared,
            expectedMessageId: end,
            expectedUserId: _customer,
            generationToken: generated.token),
        1);
    await db.abandonGeneration(_customer, generated.token);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: prepared.reply);
    await adapter.openConversation(_customer, allowActivation: true);
    expect(
        (await adapter.sendDraftOnce(
            expectedCustomer: _customer,
            reply: prepared.reply,
            attemptId: attempt['attemptId'],
            receiptPath: attempt['receiptPath']))['sent'],
        isTrue);
    await db.recoverDeliveryReceipts();
    return attempt['attemptId']!;
  }

  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer],
          orderBy: 'activated_at_ms');
  Future<List<Map<String, Object?>>> roots() async => (await db.database).query(
      'customer_media_items',
      where:
          'customer=? AND admission_session_id=? AND canonical_id IS NULL AND message_id IS NOT NULL',
      whereArgs: [_customer, db.currentAutomationSessionId]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late _ImageFlow flow;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v43_image_');
    db = CaptureDatabase(storageRoot: root);
    flow = _ImageFlow(root, db);
    await flow.initialize();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await db.close();
    await root.delete(recursive: true);
  });

  test(
      'recorded summary-separated image sends retain two owners and one reply covers both',
      () async {
    final before = await flow.frame('before-summary');
    final after = await flow.frame('after-summary');
    expect(before.evidence.metadata['unreadArrivalKey'],
        after.evidence.metadata['unreadArrivalKey']);
    expect(before.evidence.metadata['admissionFrontier'], isNull);
    expect(after.evidence.metadata['admissionFrontier'], isNull);
    final first = (await flow.register(before))!;
    await flow.acquire(first, before);
    final second = (await flow.register(after))!;
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    await flow.acquire(second, after);
    // Later readings interleave the original and newer bubble. They may
    // reuse assets, but neither may rebind to the other business owner.
    expect((await flow.receive('before-summary-reread')).messageId,
        first.messageId);
    expect((await flow.receive('after-summary-reread')).messageId,
        second.messageId);
    expect((await flow.receive('before-summary')).messageId, first.messageId);
    expect(await flow.roots(), hasLength(2));
    expect(await flow.work(), hasLength(2));
    final history = (await (await db.history).read(_customer))!;
    final received = (history['messages'] as List)
        .whereType<Map>()
        .where((m) => m['direction'] == 'incoming')
        .toList();
    expect(received.map((m) => m['id']).toSet(),
        {first.messageId, second.messageId});
    expect(received.map((m) => (m['media'] as List).single['path']).toSet(),
        {flow.original});
    final generation = await flow.generate(second.messageId,
        expectedInputs: {first.messageId, second.messageId});
    final attempt = await flow.deliver(generation, second.messageId);
    final work = await flow.work();
    expect(work.map((row) => row['response_state']), everyElement('answered'));
    expect(
        work.map((row) => row['answered_attempt_id']), everyElement(attempt));
    final timeline = await db.customerMessageRecords(_customer);
    expect(timeline, hasLength(2));
    expect(timeline.map((m) => m.replyAttemptId), everyElement(attempt));
    expect(timeline.map((m) => m.coveredMessageCount), everyElement(2));
    expect(timeline.map((m) => m.repliedAt).toSet(), hasLength(1));
    expect(await db.hasPendingUnanswered(_customer), isFalse);
    expect(flow.sends, hasLength(1));
    expect((await flow.receive('after-summary-reread')).messageId,
        second.messageId);
    expect((await flow.receive('before-summary-reread')).messageId,
        first.messageId);
    expect(await db.hasPendingUnanswered(_customer), isFalse);
  });

  test(
      'new recorded image arriving during prior generation remains pending until its own covered reply',
      () async {
    final before = await flow.frame('before-summary');
    final first = (await flow.register(before))!;
    await flow.acquire(first, before);
    final generation =
        await flow.generate(first.messageId, expectedInputs: {first.messageId});
    final after = await flow.frame('after-summary');
    final second = (await flow.register(after))!;
    await flow.acquire(second, after);
    expect(second.messageId, isNot(first.messageId));
    expect(
        await db.generationInputVersionsCurrent(_customer,
            generationToken: generation.token),
        isTrue,
        reason:
            'Another real incoming bubble does not invalidate this frozen input.');
    await flow.deliver(generation, first.messageId);
    expect(
        await db.isMessageFormallyAnswered(_customer, first.messageId), isTrue);
    expect(await db.isMessageFormallyAnswered(_customer, second.messageId),
        isFalse);
    final remaining = (await flow.work())
        .singleWhere((row) => row['message_id'] == second.messageId);
    expect(remaining['response_state'], 'pending');
    expect(remaining['answered_attempt_id'], isNull);
    final secondGeneration = await flow
        .generate(second.messageId, expectedInputs: {second.messageId});
    await flow.deliver(secondGeneration, second.messageId);
    expect(await db.hasPendingUnanswered(_customer), isFalse);
    expect(flow.generated, [
      {first.messageId},
      {second.messageId}
    ]);
    expect(flow.sends, hasLength(2));
  });

  test(
      'recorded image observations racing with old rereads keep two stable owners',
      () async {
    final frames = await Future.wait([
      flow.frame('before-summary'),
      flow.frame('after-summary'),
      flow.frame('before-summary-reread'),
      flow.frame('after-summary-reread'),
    ]);
    final parents = await Future.wait(frames.map(flow.register));
    expect(parents, everyElement(isNotNull));
    expect(parents[0]!.messageId, parents[2]!.messageId);
    expect(parents[1]!.messageId, parents[3]!.messageId);
    expect(parents[0]!.messageId, isNot(parents[1]!.messageId));
    expect(await flow.roots(), hasLength(2));
    expect(await flow.work(), hasLength(2));
  });

  test('same-second different sender blocks across summary are still separate',
      () async {
    final before = await flow.frame('before-summary');
    final originalAfter = await flow.frame('after-summary');
    // Constructed same-second OCR variation: photo and divider are unchanged,
    // while the second independently visible sender header uses the same second.
    final changed = originalAfter.inspection.withObservations([
      for (final line in originalAfter.inspection.observations)
        if (line.text.startsWith(_customer))
          OcrObservation(
              text: line.text.replaceAll('11:49:10', '11:49:01'),
              confidence: line.confidence,
              x: line.x,
              y: line.y,
              width: line.width,
              height: line.height)
        else
          line,
    ]);
    final after = (
      evidence: originalAfter.evidence,
      inspection: changed,
      region: originalAfter.region
    );
    expect(
        MediaCardOccurrenceContext.inspect(changed, _customer, after.region)
            .conflictsWith(MediaCardOccurrenceContext.inspect(
                before.inspection, _customer, before.region)),
        isTrue);
    final first = (await flow.register(before))!;
    final second = (await flow.register(after))!;
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    expect(await flow.work(), hasLength(2));
  });

  test(
      'same image resent again in another explicit sender block stays independent',
      () async {
    final original = await flow.frame('after-summary');
    final first = (await flow.register(original))!;
    await flow.acquire(first, original);
    final next =
        await flow.frame('after-summary', suffix: '-actual-resend', metadata: {
      'capturedAtMs': original.evidence.capturedAt
          .add(const Duration(seconds: 1))
          .millisecondsSinceEpoch,
    });
    final resent = (
      evidence: next.evidence,
      inspection: next.inspection.withObservations([
        // The old header remains separately visible above the new header.
        // This is a new block witness, rather than a changed clock alone.
        const OcrObservation(
            text: 'jd_mbnrscuhukvy 11:49:10',
            confidence: 1,
            x: .272,
            y: .48,
            width: .25,
            height: .015),
        for (final line in next.inspection.observations)
          if (line.text.startsWith(_customer))
            OcrObservation(
                text: line.text.replaceAll('11:49:10', '11:49:11'),
                confidence: line.confidence,
                x: line.x,
                y: line.y,
                width: line.width,
                height: line.height)
          else
            line,
      ]),
      region: next.region
    );
    final second = (await flow.register(resent))!;
    await flow.acquire(second, resent);
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    expect(await flow.roots(), hasLength(2));
    expect(await flow.work(), hasLength(2));
    expect((await flow.register(resent))!.messageId, second.messageId);
    expect(await flow.work(), hasLength(2));
  });

  test('one physical image with a one-digit OCR clock drift retains its owner',
      () async {
    final firstFrame = await flow.frame('after-summary');
    final first = (await flow.register(firstFrame))!;
    final read =
        await flow.frame('after-summary', suffix: '-clock-reading-drift');
    final drift = (
      evidence: read.evidence,
      inspection: read.inspection.withObservations([
        for (final line in read.inspection.observations)
          if (line.text.startsWith(_customer))
            OcrObservation(
                text: line.text.replaceAll('11:49:10', '11:49:11'),
                confidence: line.confidence,
                x: line.x,
                y: line.y,
                width: line.width,
                height: line.height)
          else
            line,
      ]),
      region: read.region
    );
    final originalContext = MediaCardOccurrenceContext.inspect(
        firstFrame.inspection, _customer, firstFrame.region);
    final changedContext = MediaCardOccurrenceContext.inspect(
        drift.inspection, _customer, drift.region);
    expect(changedContext.conflictsWith(originalContext), isFalse);
    final repeated = (await flow.register(drift))!;
    expect(repeated.receiptId, first.receiptId);
    expect(repeated.messageId, first.messageId);
    expect(await flow.work(), hasLength(1));
  });

  test('one recorded physical video with OCR clock drift retains its owner',
      () async {
    const folder = 'test/fixtures/v42_recorded_video_identity';
    final provenance =
        jsonDecode(await File('$folder/provenance.json').readAsString()) as Map;
    final info = provenance['frames']['loaded'] as Map;
    final raw = Map<String, Object?>.from(
        jsonDecode(await File('$folder/loaded.ocr.json').readAsString())
            as Map);
    final bytes = await File('$folder/loaded.png').readAsBytes();
    final box = (info['region'] as List).cast<num>();
    final region = OcrVisualRegion(
        x: box[0].toDouble(),
        y: box[1].toDouble(),
        width: box[2].toDouble(),
        height: box[3].toDouble(),
        confidence: 1);
    _Frame observation(String suffix, bool drift) {
      final inspection =
          OcrInspection.fromMap({...raw, 'pngBase64': base64Encode(bytes)});
      final id = 'same-physical-recorded-video$suffix';
      return (
        evidence: ViewportEvidence({
          ...Map<String, Object?>.from(info['metadata'] as Map),
          'evidenceId': id,
          'automationSessionId': db.currentAutomationSessionId,
          'imagePath': File('$folder/loaded.png').absolute.path,
          'manifestPath': '${root.path}/$id.json',
        }),
        inspection: drift
            ? inspection.withObservations([
                for (final line in inspection.observations)
                  if (line.text.startsWith('jd_41aeec7741d05'))
                    OcrObservation(
                        text: line.text.replaceAll('11:44:00', '11:44:01'),
                        confidence: line.confidence,
                        x: line.x,
                        y: line.y,
                        width: line.width,
                        height: line.height)
                  else
                    line,
              ])
            : inspection,
        region: region
      );
    }

    final first = (await flow.register(observation('-first', false)))!;
    final repeated = (await flow.register(observation('-ocr-drift', true)))!;
    expect(repeated.receiptId, first.receiptId);
    expect(repeated.messageId, first.messageId);
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, 'jd_41aeec7741d05']);
    expect(work, hasLength(1));
  });

  test('same image file in a new session remains a new received message',
      () async {
    final firstFrame = await flow.frame('before-summary');
    final first = (await flow.register(firstFrame))!;
    await flow.acquire(first, firstFrame);
    final firstSession = db.currentAutomationSessionId;
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 9, 3, 50));
    final secondFrame =
        await flow.frame('before-summary', suffix: '-new-session', metadata: {
      'capturedAtMs':
          DateTime.utc(2026, 11, 9, 3, 50, 1).millisecondsSinceEpoch,
      'unreadArrivalKey': 'arrival:current-run-resend',
    });
    final second = (await flow.register(secondFrame))!;
    await flow.acquire(second, secondFrame);
    expect(db.currentAutomationSessionId, isNot(firstSession));
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    expect(await flow.work(), hasLength(1));
    expect((await flow.roots()).single['message_id'], second.messageId);
    expect(await db.isMessageFormallyAnswered(_customer, second.messageId),
        isFalse);
  });
}
