import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  late Directory root;
  late CaptureDatabase database;
  late CaptureEvidenceStore store;
  late MediaCaptureAudit audit;
  late ViewportEvidence frame;
  late String owner;
  late String receipt;
  late String unknownObservation;
  const customer = 'jd_progress_buyer';
  final at = DateTime.utc(2026, 11, 10, 4, 27, 11);
  const unknown =
      OcrVisualRegion(x: .24, y: .54, width: .42, height: .24, confidence: 0);
  const physical =
      OcrVisualRegion(x: .27, y: .55, width: .18, height: .20, confidence: 1);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v47_material_resume_');
    database = CaptureDatabase(storageRoot: root);
    final session = await database.beginAutomationSession(startedAt: at);
    store = CaptureEvidenceStore(database);
    await store.beginSession(sessionId: session, startedAt: at);
    audit = MediaCaptureAudit(database, record: (_, __) {});
    final image = await File('${root.path}/frozen.png').writeAsBytes([1, 2, 3]);
    frame = ViewportEvidence({
      'evidenceId': 'frozen-unknown-video',
      'customer': customer,
      'automationSessionId': session,
      'capturedAtMs': at.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
      'imagePath': image.path,
      'manifestPath': '${root.path}/frozen.json',
      'replyActivationAllowed': true,
      'capturePurpose': 'live_signal',
    });
    await File(frame.manifestPath).writeAsString(frame.toJson());
    await store.record(frame);
    receipt = await CustomerMediaInventory(database).observe(
        customer: customer,
        evidenceId: frame.id,
        observedAt: frame.capturedAt,
        senderAt: at,
        slot: 0,
        region: [unknown.x, unknown.y, unknown.width, unknown.height],
        current: true,
        occurrenceKey: 'actual-incoming-bubble');
    final admission = await database.admitMediaMessage(customer,
        receiptId: receipt,
        evidenceId: frame.id,
        occurrenceKey: 'actual-incoming-bubble',
        receivedAt: frame.capturedAt,
        senderAt: at);
    owner = admission.messageId;
    unknownObservation = await audit.discover(frame, unknown);
    await audit.bindParent(unknownObservation,
        receiptId: receipt, messageId: owner);
    await (await database.database).update(
        'capture_evidence', {'state': 'media_waiting'},
        where: 'id=?', whereArgs: [frame.id]);
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<void> consume() async {
    final claim = await store.claim(mediaOnly: true);
    expect(claim?.id, frame.id);
    await store.complete(claim!, partial: true);
    await store.waitForMediaProgress(claim);
  }

  test('same owner resumes once when its real video material is finally bound',
      () async {
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 1);
    await consume();
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 0);
    final observed = await audit.discover(frame, physical);
    await audit.bindParent(observed, receiptId: receipt, messageId: owner);
    await audit.finish(observed, 'video_preview_only', {
      'kind': 'video',
      'verifiedOriginalPath': '${root.path}/verified.mp4',
      'representationOwnershipProof': 'same_physical_incoming_block',
    });
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 1,
        reason:
            'New media evidence must wake even though the owner ID stayed.');
    await consume();
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 0);
    final work = await (await database.database).query(
        'automation_session_messages',
        where: 'session_id=? AND user_id=?',
        whereArgs: [database.currentAutomationSessionId, customer]);
    expect(work, hasLength(1));
    expect(work.single['message_id'], owner);
    expect(work.single['response_state'], 'pending');
  });

  test('state churn and an unowned adjacent original do not replay recognition',
      () async {
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 1);
    await consume();
    for (var i = 0; i < 3; i++) {
      await audit.finish(unknownObservation, i.isEven ? 'discovered' : 'failed',
          {'reason': 'unchanged_material_$i', 'elapsedMs': i});
      expect(await store.resumeAdmittedMediaEvidence({frame.id}), 0);
    }
    final unowned = await audit.discover(frame, physical);
    await audit.finish(unowned, 'video_preview_only', {
      'kind': 'video',
      'verifiedOriginalPath': '${root.path}/some-other-bubble.mp4',
    });
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 0,
        reason: 'A file without exact parent proof must not wake this duty.');
    expect(await store.claim(mediaOnly: true), isNull);
    final row = (await (await database.database)
            .query('capture_evidence', where: 'id=?', whereArgs: [frame.id]))
        .single;
    final payload = jsonDecode(row['payload']! as String) as Map;
    expect(payload['admissionResumeKey'], contains('material:'));
  });

  test('an old-session material arrival cannot resume a new run', () async {
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 1);
    await consume();
    await database.beginAutomationSession(
        startedAt: at.add(const Duration(minutes: 1)));
    expect(await store.resumeAdmittedMediaEvidence({frame.id}), 0);
    expect(await store.claim(mediaOnly: true), isNull);
  });
}
