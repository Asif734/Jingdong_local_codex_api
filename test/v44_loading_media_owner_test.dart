import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'helpers/completed_video_fixture.dart';

const _fixtures = 'test/fixtures/v44_loading_media_owner';
const _customer = 'jd_41aeec7741d05';
typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection inspection,
  OcrVisualRegion region
});

Future<_Frame> _frame(CaptureDatabase db, Directory root, String name,
    {String suffix = '', OcrVisualRegion? region}) async {
  final provenance =
      jsonDecode(await File('$_fixtures/provenance.json').readAsString())
          as Map;
  final info = provenance['frames'][name] as Map;
  final bytes = await File('$_fixtures/$name.png').readAsBytes();
  final ocr = await File('$_fixtures/$name.ocr.json').readAsBytes();
  expect(sha256.convert(bytes).toString(), info['pngSHA256']);
  expect(sha256.convert(ocr).toString(), info['ocrSHA256']);
  final metadata = Map<String, Object?>.from(
      jsonDecode(await File('$_fixtures/$name.capture.json').readAsString())
          as Map);
  metadata.remove('pinnedMedia');
  final id = '${info['recordedEvidenceId']}$suffix';
  final evidence = ViewportEvidence({
    ...metadata,
    'evidenceId': id,
    'automationSessionId': db.currentAutomationSessionId,
    'imagePath': File('$_fixtures/$name.png').absolute.path,
    'manifestPath': '${root.path}/$id.json'
  });
  await File(evidence.manifestPath).writeAsString(evidence.toJson());
  final box = (info['region'] as List).cast<num>();
  return (
    evidence: evidence,
    inspection: OcrInspection.fromMap({
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map),
      'pngBase64': base64Encode(bytes)
    }),
    region: region ??
        OcrVisualRegion(
            x: box[0].toDouble(),
            y: box[1].toDouble(),
            width: box[2].toDouble(),
            height: box[3].toDouble(),
            confidence: 1)
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late MediaCaptureAudit audit;
  late MediaMessageRegistrar registrar;
  const channel = MethodChannel('v44-physical-video-native');
  final sends = <String>[];
  List<CapturedMedia>? sharedMedia;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_owner_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 9, 5, 39));
    inventory = CustomerMediaInventory(db);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
    sharedMedia = null;
    sends.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'openConversation') {
        return {'opened': true, 'customer': _customer};
      }
      if (call.method == 'sendDraftOnce') {
        expect(args['expectedCustomer'], _customer);
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
      }
      throw StateError('Unexpected native operation: ${call.method}');
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
    await root.delete(recursive: true);
  });
  Future<MediaMessageRegistration> register(_Frame frame) => registrar.register(
      evidence: frame.evidence,
      inspection: frame.inspection,
      cards: [frame.region],
      visibleText:
          const OcrCaptureExtractor().extract(frame.inspection)?.messages ??
              const [],
      frontier: frame.evidence.metadata['admissionFrontier'] as Map?,
      registerOnly: true);
  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer]);
  Future<
      List<
          Map<String, Object?>>> owners() async => (await db.database).query(
      'customer_media_items',
      where:
          'admission_session_id=? AND customer=? AND message_id IS NOT NULL AND canonical_id IS NULL',
      whereArgs: [db.currentAutomationSessionId, _customer]);
  Future<void> complete(MediaParent parent) async {
    sharedMedia ??= await completedVideoFixture(root, name: 'shared-original');
    await inventory.classify(parent.receiptId, 'video');
    final capture = CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: parent.messageId,
              direction: 'incoming',
              sender: _customer,
              sentAt: DateTime.utc(2026, 11, 9, 5, 51, 56),
              body: '[Customer sent a video]',
              axPath: 'completed native fixture',
              mediaReceiptId: parent.receiptId,
              media: sharedMedia!)
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
          'reply': 'Switch off the printer and reload the paper correctly.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v44-native-confirmation'
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

  test('recorded v43 gray inner crop and loaded cover are one incoming video',
      () async {
    final first = (await register(await _frame(db, root, 'gray-inner')))
        .parents
        .values
        .single;
    final second = (await register(await _frame(db, root, 'loaded')))
        .parents
        .values
        .single;
    expect(second.messageId, first.messageId);
    expect(second.receiptId, first.receiptId);
    expect(await work(), hasLength(1));
    expect(await owners(), hasLength(1));
  });
  test(
      'loaded first and formal completion survive old gray callbacks and repeated reads',
      () async {
    final first = (await register(await _frame(db, root, 'loaded')))
        .parents
        .values
        .single;
    expect(
        (await register(await _frame(db, root, 'later-loaded')))
            .parents
            .values
            .single
            .messageId,
        first.messageId);
    await complete(first);
    final attempt = await formal(first);
    for (final name in ['gray-inner', 'later-loaded', 'loaded', 'gray-inner']) {
      final read =
          (await register(await _frame(db, root, name))).parents.values.single;
      expect(read.messageId, first.messageId);
      expect(read.receiptId, first.receiptId);
    }
    expect(await owners(), hasLength(1));
    expect(await work(), hasLength(1));
    expect((await work()).single['answered_attempt_id'], attempt);
    expect(await db.hasPendingUnanswered(_customer), false);
    expect(sends, hasLength(1));
  });
  test('overlapping gray loaded and late callbacks register one owner',
      () async {
    final frames = await Future.wait([
      _frame(db, root, 'gray-inner'),
      _frame(db, root, 'loaded'),
      _frame(db, root, 'later-loaded'),
      _frame(db, root, 'gray-inner')
    ]);
    final results = await Future.wait(frames.map(register));
    expect(results.map((r) => r.parents.values.single.messageId).toSet(),
        hasLength(1));
    expect(await owners(), hasLength(1));
    expect(await work(), hasLength(1));
  });
  test(
      'inner and clipped ROI proposals retain the same physical sender-block owner',
      () async {
    final first = (await register(await _frame(db, root, 'loaded')))
        .parents
        .values
        .single;
    for (final top in [.49, .52, .55]) {
      final read = await _frame(db, root, 'gray-inner',
          suffix: '-inner-$top',
          region: OcrVisualRegion(
              x: .27326388888888886,
              y: top,
              width: .11180555555555556,
              height: .7287822878228782 - top,
              confidence: 1));
      expect((await register(read)).parents.values.single.messageId,
          first.messageId);
    }
    expect(await work(), hasLength(1));
  });
  Future<({MediaParent first, MediaParent second, _Frame gray, _Frame loaded})>
      legacySplit() async {
    final gray = await _frame(db, root, 'gray-inner'),
        loaded = await _frame(db, root, 'loaded');
    final first = (await register(gray)).parents.values.single;
    // Seed exactly the shipped unmatched-second-frame admission. Recovery is
    // subsequently invoked only with the actual immutable frame, not a parent.
    final observation = await audit.discover(loaded.evidence, loaded.region,
        inspection: loaded.inspection);
    final receipt = await inventory.observe(
        customer: _customer,
        evidenceId: loaded.evidence.id,
        observedAt: loaded.evidence.capturedAt,
        senderAt: DateTime.utc(2026, 11, 9, 5, 51, 56),
        slot: 0,
        region: [
          loaded.region.x,
          loaded.region.y,
          loaded.region.width,
          loaded.region.height
        ],
        current: true,
        occurrenceKey: 'shipped-v43-unmatched-loaded');
    final admitted = await db.admitMediaMessage(_customer,
        receiptId: receipt,
        evidenceId: loaded.evidence.id,
        occurrenceKey: 'shipped-v43-unmatched-loaded',
        receivedAt: loaded.evidence.capturedAt,
        senderAt: DateTime.utc(2026, 11, 9, 5, 51, 56));
    final preview =
        (await audit.frozenCardPreview(loaded.evidence, loaded.region))!;
    final previewPath = await (await db.history).saveMedia(
        userId: _customer,
        filename: 'legacy-loaded-preview.png',
        bytes: preview);
    await audit.finish(observation, 'discovered', {
      'previewPath': previewPath,
      'videoOccurrenceProven': true,
    });
    await audit.bindParent(observation,
        receiptId: receipt, messageId: admitted.messageId);
    final second = (await inventory.resolveParent(_customer,
        receiptId: receipt, requireCurrentSession: true))!;
    return (first: first, second: second, gray: gray, loaded: loaded);
  }

  test(
      'existing split rejoins by physical proof and the actual native receipt covers aliases',
      () async {
    final old = await legacySplit();
    await complete(old.second);
    final attempt = await formal(old.second);
    expect(await db.isMessageFormallyAnswered(_customer, old.first.messageId),
        false);
    expect(await owners(), hasLength(2));
    final repaired = (await register(old.gray)).parents.values.single;
    expect(repaired.receiptId, old.first.receiptId);
    expect(repaired.messageId, old.first.messageId);
    expect(await owners(), hasLength(1));
    expect(await db.hasPendingUnanswered(_customer), false);
    expect((await work()).map((r) => r['answered_attempt_id']),
        everyElement(attempt));
    final timeline = await db.customerMessageRecords(_customer);
    expect(timeline, hasLength(1));
    expect(timeline.single.replyAttemptId, attempt);
    expect(timeline.single.receivedAt, old.gray.evidence.capturedAt);
    expect(await inventory.analysisReadyMessageIds(_customer),
        contains(old.first.messageId));
    expect(sends, hasLength(1));
    expect((await register(old.loaded)).parents.values.single.messageId,
        old.first.messageId);
  });
  test(
      'physical alias repair without a receipt cannot fabricate an answered state',
      () async {
    final old = await legacySplit();
    await complete(old.second);
    final repaired = (await register(old.gray)).parents.values.single;
    expect(repaired.messageId, old.first.messageId);
    expect(await owners(), hasLength(1));
    expect(await db.hasPendingUnanswered(_customer), true);
    expect(await db.isMessageFormallyAnswered(_customer, old.first.messageId),
        false);
    expect(await db.isMessageFormallyAnswered(_customer, old.second.messageId),
        false);
    expect(sends, isEmpty);
  });
  test(
      'same-second same-file separately visible incoming blocks remain independent',
      () async {
    final first = (await register(await _frame(db, root, 'loaded')))
        .parents
        .values
        .single;
    final next =
        await _frame(db, root, 'loaded', suffix: '-second-real-bubble');
    final second = (await register((
      evidence: next.evidence,
      region: next.region,
      inspection: next.inspection.withObservations([
        ...next.inspection.observations,
        const OcrObservation(
            text: 'jd_41aeec7741d05 13:51:56',
            confidence: 1,
            x: .273,
            y: .40,
            width: .25,
            height: .018)
      ])
    )))
        .parents
        .values
        .single;
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    await complete(first);
    await complete(second);
    expect(await owners(), hasLength(2));
    expect(await work(), hasLength(2));
    expect(await db.customerMessageRecords(_customer), hasLength(2));
  });
  test(
      'real timestamp glyph change with same file and preceding seller stays a separate send',
      () async {
    final first = (await register(await _frame(db, root, 'loaded')))
        .parents
        .values
        .single;
    final later =
        await _frame(db, root, 'loaded', suffix: '-different-physical-time');
    final codec = await ui.instantiateImageCodec(later.inspection.image);
    final image = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawImage(image, ui.Offset.zero, ui.Paint());
    canvas.drawRect(ui.Rect.fromLTWH(780, 723, 480, 39),
        ui.Paint()..color = const ui.Color(0xfff7f7f7));
    final paragraph = (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 26))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xff555555)))
          ..addText('jd_41aeec7741d05 13:52:56'))
        .build()
      ..layout(const ui.ParagraphConstraints(width: 500));
    canvas.drawParagraph(paragraph, const ui.Offset(785, 727));
    final picture = recorder.endRecording(),
        painted = await picture.toImage(image.width, image.height);
    final bytes = (await painted.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    paragraph.dispose();
    picture.dispose();
    painted.dispose();
    image.dispose();
    codec.dispose();
    final file = await File('${root.path}/new-time.png').writeAsBytes(bytes);
    final changed = (
      evidence: ViewportEvidence(
          {...later.evidence.metadata, 'imagePath': file.path}),
      region: later.region,
      inspection: later.inspection.withObservations([
        for (final line in later.inspection.observations)
          if (line.text.startsWith(_customer))
            OcrObservation(
                text: line.text.replaceAll('13:51:56', '13:52:56'),
                confidence: line.confidence,
                x: line.x,
                y: line.y,
                width: line.width,
                height: line.height)
          else
            line
      ])
    );
    final second = (await register(changed)).parents.values.single;
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    expect(await work(), hasLength(2));
  });
}
