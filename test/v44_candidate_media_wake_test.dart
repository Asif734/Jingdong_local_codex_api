import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late String session;
  const owner = 'verified-current-video';
  final at = DateTime.utc(2026, 11, 9, 5, 52);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_candidate_wake_');
    db = CaptureDatabase(storageRoot: root);
    session = await db.beginAutomationSession(startedAt: at);
    store =
        CaptureEvidenceStore(db, now: () => at.add(const Duration(minutes: 1)));
    await store.beginSession(sessionId: session, startedAt: at);
    final receipt = await CustomerMediaInventory(db).observe(
        customer: 'buyer',
        evidenceId: 'true-owner-evidence',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.27, .4, .12, .24],
        current: true,
        occurrenceKey: 'actual-current-arrival');
    await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'true-owner-evidence',
        occurrenceKey: 'actual-current-arrival',
        receivedAt: at,
        messageId: owner);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id, int second) async {
    final image = await File('${root.path}/$id.png').writeAsBytes([1, 2, 3]);
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': 'buyer',
      'automationSessionId': session,
      'capturedAtMs': at.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'imagePath': image.path,
      'manifestPath': '${root.path}/$id.json',
      'capturePurpose': 'active_discovery',
      'replyActivationAllowed': true,
    });
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    return evidence;
  }

  Future<String> state(String id) async =>
      (await (await db.database).query('capture_evidence',
              columns: ['state'], where: 'id=?', whereArgs: [id]))
          .single['state']! as String;

  Future<ViewportEvidence> waitingCandidate({String? candidateSession}) async {
    final evidence = await frame('ambiguous-unbound', 3);
    final receipt = await CustomerMediaInventory(db).observe(
        customer: 'buyer',
        evidenceId: evidence.id,
        observedAt: evidence.capturedAt,
        senderAt: null,
        slot: 0,
        region: [.27, .4, .12, .24],
        current: false);
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'ambiguous-observation',
      'evidence_id': evidence.id,
      'customer': 'buyer',
      'state': 'unbound',
      'updated_at_ms': evidence.capturedAt.millisecondsSinceEpoch,
      'details': jsonEncode({
        'automationSessionId': candidateSession ?? session,
        'ownershipAmbiguous': true,
        'candidateParentIds': [owner],
        'mediaReceiptId': receipt,
      }),
    });
    await store.record(evidence);
    final claim = (await store.claim(mediaOnly: false))!;
    await store.complete((await store.refreshClaim(claim))!, partial: true);
    await store.waitForMediaProgress(claim);
    await File('${evidence.manifestPath}.ocr.json').writeAsString(jsonEncode({
      'evidenceId': evidence.id,
      'customer': 'buyer',
      'activeCustomerId': 'buyer',
      'capturedAtMs': evidence.capturedAt.millisecondsSinceEpoch,
      'observations': [],
      'visualRegions': [],
    }));
    return evidence;
  }

  test('candidate progress wakes verification without assigning ownership',
      () async {
    final evidence = await waitingCandidate();
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'owner:original-ready', ownerKeys: {owner}),
        1);
    expect(await state(evidence.id), 'media_retry');
    final details = jsonDecode((await (await db.database).query(
            'media_capture_audit',
            where: 'observation_id=?',
            whereArgs: ['ambiguous-observation']))
        .single['details']! as String) as Map;
    expect(details['parentMessageId'], isNull);
    expect(details['resolvedMessageId'], isNull);
    expect(details['ownershipAmbiguous'], isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(await db.isMessageFormallyAnswered('buyer', owner), isFalse);
  });

  test(
      'unrelated progress does not wake candidate and exact progress coalesces',
      () async {
    final evidence = await waitingCandidate();
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'unrelated', ownerKeys: {'another-owner'}),
        0);
    expect(await state(evidence.id), 'media_waiting');
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'candidate:1', ownerKeys: {owner}),
        1);
    final claim = (await store.claim(mediaOnly: true))!;
    await store.complete((await store.refreshClaim(claim))!, partial: true);
    await store.waitForMediaProgress(claim);
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'candidate:1', ownerKeys: {owner}),
        0);
    expect(await state(evidence.id), 'media_waiting');
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'candidate:2', ownerKeys: {owner}),
        1);
  });

  test(
      'candidate cannot bypass an older raw OCR via the admitted media fast lane',
      () async {
    final candidate = await waitingCandidate();
    final old = await frame('older-held-OCR', 1);
    await store.record(old);
    expect((await store.claim(mediaOnly: false))?.id, old.id);
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'candidate:ready', ownerKeys: {owner}),
        1);
    expect(await store.claim(mediaOnly: true), isNull,
        reason: 'Saved OCR plus a candidate is not a proved admitted parent');
    expect(await state(candidate.id), 'media_retry');
    expect(await File(candidate.imagePath).exists(), isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('a candidate relation from an earlier run cannot wake current evidence',
      () async {
    final evidence = await waitingCandidate(candidateSession: 'previous-run');
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'current:ready', ownerKeys: {owner}),
        0);
    expect(await state(evidence.id), 'media_waiting');
  });
}
