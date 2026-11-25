import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

typedef _Observed = ({ViewportEvidence evidence, OcrInspection inspection});

/// Original pixels and sender OCR are unchanged. Only the detector's list of
/// acquisition rectangles is varied, just as native Vision/component outputs
/// can vary while one physical card remains on screen.
Future<_Observed> _load(CaptureDatabase db, Directory root, String folder,
    String name, String suffix,
    {List<Map<String, Object?>>? regions}) async {
  final manifest =
      jsonDecode(await File('$folder/provenance.json').readAsString()) as Map;
  final info = manifest['frames'][name] as Map;
  final bytes = await File('$folder/$name.png').readAsBytes();
  final ocr = await File('$folder/$name.ocr.json').readAsBytes();
  expect(sha256.convert(bytes).toString(), info['pngSHA256']);
  expect(sha256.convert(ocr).toString(), info['ocrSHA256']);
  final raw = Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map);
  final capture = File('$folder/$name.capture.json');
  final metadata = capture.existsSync()
      ? Map<String, Object?>.from(
          jsonDecode(await capture.readAsString()) as Map)
      : Map<String, Object?>.from(info['metadata'] as Map);
  metadata.remove('pinnedMedia');
  final id = '${info['recordedEvidenceId']}$suffix';
  final evidence = ViewportEvidence({
    ...metadata,
    'evidenceId': id,
    'automationSessionId': db.currentAutomationSessionId,
    'imagePath': File('$folder/$name.png').absolute.path,
    'manifestPath': '${root.path}/$id.json',
  });
  await File(evidence.manifestPath).writeAsString(evidence.toJson());
  return (
    evidence: evidence,
    inspection: OcrInspection.fromMap({
      ...raw,
      'pngBase64': base64Encode(bytes),
      if (regions != null) 'visualRegions': regions,
      if (regions != null) 'unboundMediaRegions': const [],
    })
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late MediaMessageRegistrar registrar;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_fragment_');
    db = CaptureDatabase(storageRoot: root);
    await db.beginAutomationSession(startedAt: DateTime.utc(2026, 11, 9, 3));
    registrar = MediaMessageRegistrar(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<MediaMessageRegistration> register(_Observed frame) async {
    final customer = frame.evidence.customer;
    final extracted = const OcrCaptureExtractor().extract(frame.inspection);
    final cards = const OcrImageCandidateSelector().select(
        frame.inspection, customer,
        includeTextDense: true,
        customerText: extracted?.messages
                .where((m) => m.direction == 'incoming')
                .map((m) => m.body) ??
            const []);
    expect(cards, hasLength(1),
        reason: 'The real selector chooses one physical incoming candidate.');
    return registrar.register(
        evidence: frame.evidence,
        inspection: frame.inspection,
        cards: cards,
        visibleText: extracted?.messages ?? const [],
        frontier: frame.evidence.metadata['admissionFrontier'] as Map?,
        registerOnly: true);
  }

  test(
      'recorded physical video survives two disjoint detector fragments then full card and old gray',
      () async {
    const folder = 'test/fixtures/v44_loading_media_owner';
    final fragmented =
        await _load(db, root, folder, 'loaded', '-split-detector', regions: [
      {
        'x': .27326388888888886,
        'y': .48,
        'width': .11180555555555556,
        'height': .09,
        'confidence': 1.0
      },
      {
        'x': .27326388888888886,
        'y': .59,
        'width': .11180555555555556,
        'height': .12,
        'confidence': 1.0
      },
    ]);
    final first = (await register(fragmented)).parents.values.single;
    final full =
        (await register(await _load(db, root, folder, 'loaded', '-whole-card')))
            .parents
            .values
            .single;
    expect(full.messageId, first.messageId);
    expect(full.receiptId, first.receiptId);
    for (final frame in [
      await _load(db, root, folder, 'gray-inner', '-late-gray'),
      fragmented,
      await _load(db, root, folder, 'later-loaded', '-later-full'),
    ]) {
      expect((await register(frame)).parents.values.single.messageId,
          first.messageId);
    }
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [
          db.currentAutomationSessionId,
          fragmented.evidence.customer
        ]);
    expect(work, hasLength(1));
  });
  test(
      'recorded independently sent same-file image bubbles keep their separate sender blocks',
      () async {
    const folder = 'test/fixtures/v43_image_bubble_identity';
    final first = (await register(
            await _load(db, root, folder, 'before-summary', '-selector')))
        .parents
        .values
        .single;
    final second = (await register(
            await _load(db, root, folder, 'after-summary', '-selector')))
        .parents
        .values
        .single;
    expect(second.messageId, isNot(first.messageId));
    expect(second.receiptId, isNot(first.receiptId));
    final work = await (await db.database).query('automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [db.currentAutomationSessionId, 'jd_mbnrscuhukvy']);
    expect(work, hasLength(2));
  });
}
