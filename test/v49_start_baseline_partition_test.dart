import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'jd_start_partition';
  final second = DateTime.utc(2026, 11, 10);
  final startedAt = second.add(const Duration(milliseconds: 500));

  test('only complete clocks before the Start second are old baseline inputs',
      () {
    final evidence = ViewportEvidence({
      'automationSessionStartedAtMs': startedAt.millisecondsSinceEpoch,
    });
    expect(LiveMediaArrival.isBeforeSessionStart(evidence, null), isFalse);
    expect(
        LiveMediaArrival.isBeforeSessionStart(
            evidence, second.subtract(const Duration(seconds: 1))),
        isTrue);
    expect(LiveMediaArrival.isBeforeSessionStart(evidence, second), isFalse);
    expect(
        LiveMediaArrival.isBeforeSessionStart(
            evidence, second.add(const Duration(seconds: 1))),
        isFalse);
  });

  test(
      'a mixed first frame promotes its existing lease after old-only baseline',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v49_start_unit_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final session = await db.beginAutomationSession(startedAt: startedAt);
    final store = CaptureEvidenceStore(db);
    await store.beginSession(sessionId: session, startedAt: startedAt);
    final png =
        await File('${root.path}/controlled-raw.bin').writeAsString('raw');
    final manifest =
        await File('${root.path}/controlled-manifest.json').writeAsString('{}');
    final raw = ViewportEvidence({
      'evidenceId': 'one-first-frame',
      'customer': customer,
      'capturedAtMs':
          second.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
      'automationSessionId': session,
      'automationSessionStartedAtMs': startedAt.millisecondsSinceEpoch,
      'imagePath': png.path,
      'manifestPath': manifest.path,
      'replyActivationAllowed': false,
    });
    final first = await store.discoveryCapture(raw,
        hasLiveWork: false, hasPendingWork: false, acquisition: false);
    expect(first.evidence.metadata['capturePurpose'], 'discovery_baseline');
    final claim = (await store.claim(mediaOnly: false))!;
    final oldAt = second.subtract(const Duration(seconds: 1));
    final oldId = CustomerMessageTime.incomingId(customer, oldAt);
    final currentId = CustomerMessageTime.incomingId(customer, second);
    CapturedConversation capture(List<CapturedMessage> messages) =>
        CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: session,
            capturedAt: raw.capturedAt,
            messages: messages);
    await db.saveCapture(
        capture([
          CapturedMessage(
              stableId: oldId,
              direction: 'incoming',
              body: 'Old question',
              sentAt: oldAt,
              captureEvidenceId: raw.id,
              axPath: 'controlled-previous-clock')
        ]),
        activateReplies: false);
    expect(
        await db.registerDiscoveryBaseline(customer, [oldId],
            evidenceId: raw.id, expectedSessionId: session),
        isTrue);
    expect(await db.isSessionBaselineMessage(customer, oldId), isTrue);
    expect(await db.isSessionBaselineMessage(customer, currentId), isFalse);
    expect(
        await store.record(ViewportEvidence({
          ...claim.metadata,
          'replyActivationAllowed': true,
          'capturePurpose': 'live_signal',
        })),
        isTrue);
    final promoted = (await store.refreshClaim(claim))!;
    expect(promoted.id, claim.id);
    expect(promoted.metadata['captureClaimToken'],
        claim.metadata['captureClaimToken']);
    expect(promoted.metadata['capturePurpose'], 'live_signal');
    expect(await store.baselineEvidenceId(customer), isNull);
    await db.saveCapture(
        capture([
          CapturedMessage(
              stableId: currentId,
              direction: 'incoming',
              body: 'New question in the first saved frame',
              sentAt: second,
              captureEvidenceId: raw.id,
              axPath: 'controlled-current-clock')
        ]),
        activeIncomingIds: {currentId});
    expect(await db.hasPendingUnanswered(customer), isTrue);
    expect(await db.isCurrentSessionMessage(customer, currentId), isTrue);
    await store.complete(promoted);
    final stored = await (await db.database)
        .query('capture_evidence', where: 'id=?', whereArgs: [raw.id]);
    expect(stored, hasLength(1));
    expect(stored.single['state'], 'processed');
  });
}
