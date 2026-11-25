import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

const _folder = 'test/fixtures/v45_recorded_image_admission';
const _customer = 'jd_41aeec7741d05';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late MediaCaptureAudit audit;
  late MediaMessageRegistrar registrar;
  late ViewportEvidence loaded;
  late ViewportEvidence loading;
  late MediaParent firstParent;
  late MediaParent secondParent;

  Future<({ViewportEvidence frame, MediaMessageRegistration registration})>
      observe(String name) async {
    final data = Map<String, Object?>.from(
        jsonDecode(await File('$_folder/$name.capture.json').readAsString())
            as Map);
    data.addAll({
      'automationSessionId': db.currentAutomationSessionId,
      'imagePath': File('$_folder/$name.png').absolute.path,
      'manifestPath': '${root.path}/$name.json',
    });
    if (data['pinnedMedia'] case final Map pin) {
      final copy = await File('$_folder/$name.original')
          .copy('${root.path}/$name.original');
      data['pinnedMedia'] = {...pin, 'evidenceFile': copy.path};
    }
    final evidence = ViewportEvidence(data);
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    await store.record(evidence);
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(
          jsonDecode(await File('$_folder/$name.ocr.json').readAsString())
              as Map),
      'pngBase64': base64Encode(await File(evidence.imagePath).readAsBytes()),
    });
    final text =
        const OcrCaptureExtractor().extract(view)?.messages ?? const [];
    const selector = OcrImageCandidateSelector();
    final initial = selector.select(view, _customer,
        includeTextDense: true,
        allowUnlabeledLatestImage: true,
        customerText:
            text.where((m) => m.direction == 'incoming').map((m) => m.body));
    final cards = selector.recoverCustomerBlocks(view, _customer,
        owned: initial,
        hasPinnedImage: evidence.pinnedMedia?['kind'] == 'image');
    final registration = await registrar.register(
        evidence: evidence,
        inspection: view,
        cards: cards,
        visibleText: text,
        registerOnly: true,
        frontier: evidence.metadata['admissionFrontier'] as Map?);
    return (frame: evidence, registration: registration);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v45_image_pin_');
    db = CaptureDatabase(storageRoot: root);
    final at = DateTime.utc(2026, 11, 9, 8, 47);
    final session = await db.beginAutomationSession(startedAt: at);
    store = CaptureEvidenceStore(db);
    await store.beginSession(sessionId: session, startedAt: at);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, audit: audit);
    firstParent = (await observe('first')).registration.parents.values.single;
    final white = await observe('second-loading');
    expect(white.registration.parents, isEmpty);
    loading = white.frame;
    final full = await observe('second-loaded');
    loaded = full.frame;
    secondParent = full.registration.parents.values.single;
    expect(firstParent.messageId, isNot(secondParent.messageId));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('loaded real card inherits only its own proven loading-frame original',
      () async {
    expect(loaded.pinnedMedia, isNull);
    final pin = await audit.inheritedImagePin(loaded,
        receiptId: secondParent.receiptId);
    expect(pin, isNotNull);
    expect(pin!['kind'], 'image');
    expect(pin['originEvidenceId'], loading.id);
    expect(pin['evidenceFile'], loading.pinnedMedia!['evidenceFile']);
    expect(await File(pin['evidenceFile']! as String).readAsBytes(),
        await File('$_folder/second-loading.original').readAsBytes());
    expect(
        await audit.inheritedImagePin(loaded, receiptId: firstParent.receiptId),
        isNull,
        reason:
            'The same file sent in an earlier bubble is a different owner.');
  });

  test(
      'same group label without a physical correspondence link cannot lend a pin',
      () async {
    final sql = await db.database;
    final rows = await sql.query('media_capture_audit',
        where: 'evidence_id=?', whereArgs: [loaded.id]);
    for (final row in rows) {
      final details = jsonDecode(row['details']! as String) as Map;
      details.remove('physicalGroupLink');
      await sql.update('media_capture_audit', {'details': jsonEncode(details)},
          where: 'observation_id=?', whereArgs: [row['observation_id']]);
    }
    expect(
        await audit.inheritedImagePin(loaded,
            receiptId: secondParent.receiptId),
        isNull);
  });

  test('missing original and a non-image pin cannot satisfy image inheritance',
      () async {
    final sql = await db.database;
    final original = loading.pinnedMedia!;
    final wrongKind = ViewportEvidence({
      ...loading.metadata,
      'pinnedMedia': {...original, 'kind': 'video'}
    });
    await sql.update('capture_evidence', {'payload': wrongKind.toJson()},
        where: 'id=?', whereArgs: [loading.id]);
    expect(
        await audit.inheritedImagePin(loaded,
            receiptId: secondParent.receiptId),
        isNull);
    await sql.update('capture_evidence', {'payload': loading.toJson()},
        where: 'id=?', whereArgs: [loading.id]);
    await File(original['evidenceFile']! as String).delete();
    expect(
        await audit.inheritedImagePin(loaded,
            receiptId: secondParent.receiptId),
        isNull);
  });

  test('another customer or session cannot borrow a proved original', () async {
    final wrongCustomer =
        ViewportEvidence({...loaded.metadata, 'customer': 'another-customer'});
    expect(
        await audit.inheritedImagePin(wrongCustomer,
            receiptId: secondParent.receiptId),
        isNull);
    await db.beginAutomationSession(startedAt: DateTime.utc(2026, 11, 9, 10));
    expect(
        await audit.inheritedImagePin(loaded,
            receiptId: secondParent.receiptId),
        isNull);
  });
}
