import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

const _customer = 'jd_41aeec7741d05';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late String session;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v36_recovery_');
    db = CaptureDatabase(storageRoot: root);
    now = DateTime.utc(2026, 11, 5, 9, 54, 21);
    session = await db.beginAutomationSession(startedAt: now);
    store = CaptureEvidenceStore(db, now: () => now);
    await store.beginSession(sessionId: session, startedAt: now);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<OcrInspection> inspection(String name,
          {String folder = 'v36_capture'}) async =>
      OcrInspection.fromMap(Map<String, Object?>.from(jsonDecode(
              await File('test/fixtures/$folder/$name.json').readAsString())
          as Map));

  Future<ViewportEvidence> frame(String id,
      {int? cutoff,
      String hash = 'same-chat-pixels',
      bool acquisition = false,
      List<String> keys = const [],
      bool activation = true}) async {
    final image =
        await File('test/fixtures/v36_capture/answered-hi-bottom-clipped.png')
            .copy('${root.path}/$id.png');
    final manifest = File('${root.path}/$id.json');
    final values = <String, Object?>{
      'evidenceId': id,
      'customer': _customer,
      'automationSessionId': session,
      'capturedAtMs':
          now.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
      'imagePath': image.path,
      'manifestPath': manifest.path,
      'chatContentSHA256': hash,
      'replyActivationAllowed': activation,
      'capturePurpose':
          cutoff == null ? 'active_discovery' : 'history_backfill',
      if (cutoff != null) 'historyCutoffMs': cutoff,
      if (acquisition) ...{
        'mediaAcquisitionPending': true,
        'acquisitionOnly': true,
        'acquisitionInputKeys': keys,
      },
      'chatRegion': {
        'left': .24027777777777778,
        'top': .20418204182041821,
        'right': .7479166666666667,
        'bottom': .7921279212792128
      },
    };
    await manifest.writeAsString(jsonEncode(values));
    return ViewportEvidence(values);
  }

  test('recorded historical bottom headers cannot create new recovery inputs',
      () async {
    for (final name in [
      'old-video-question-bottom-clipped',
      'answered-hi-bottom-clipped'
    ]) {
      final original = await inspection(name);
      final extraction = const OcrCaptureExtractor().analyze(original);
      expect(extraction.latestVisibleSenderIsIncoming, isTrue);
      expect(extraction.latestIncomingHasText, isFalse);
      final evidence = await frame(name,
          hash: name,
          cutoff: now.add(const Duration(minutes: 2)).millisecondsSinceEpoch);
      expect(
          await store.needsHeaderRecovery(
              evidence, extraction.latestIncomingSentAt),
          isFalse);
      await store.record(evidence);
      final claimed = (await store.claim())!;
      expect(claimed.id, evidence.id);
      await store.complete((await store.refreshClaim(claimed))!);
      now = now.add(const Duration(minutes: 1));
      expect(await store.claim(mediaOnly: true), isNull,
          reason: 'Successful OCR of clipped historical pixels is terminal; '
              'navigation, not re-OCR, recovers a body outside those pixels');
    }
  });

  test('durable known body does not become missing when its bubble is clipped',
      () async {
    final incomingAt = DateTime.utc(2026, 11, 5, 9, 56, 9);
    final evidence = await frame('active-clipped-known-hi');
    await db.saveCapture(CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        capturedAt: incomingAt,
        messages: [
          CapturedMessage(
              stableId: 'known-hi',
              direction: 'incoming',
              body: 'hi',
              sender: _customer,
              sentAt: incomingAt,
              captureEvidenceId: evidence.id,
              axPath: 'recorded')
        ]));
    expect(await store.needsHeaderRecovery(evidence, incomingAt), isFalse);
    expect(await db.hasPendingUnanswered(_customer), isTrue,
        reason: 'Knowing the body never marks an unanswered input completed');
    // An OCR clock alone does not prove an unseen input. The raw frame and
    // existing pending question remain durable while identity is unresolved.
    expect(
        await store.needsHeaderRecovery(evidence, DateTime.utc(2026, 11, 5, 7)),
        isFalse);
    final fresh = await frame('same-second-another-partial-bubble');
    expect(await store.needsHeaderRecovery(fresh, incomingAt), isFalse,
        reason: 'A fresh frame ID is not another AX arrival or owner proof.');
    final signaled = ViewportEvidence({
      ...evidence.metadata,
      'capturePurpose': 'live_signal',
    });
    expect(await store.needsHeaderRecovery(signaled, incomingAt), isFalse,
        reason: 'The live_signal label cannot promote a known OCR header '
            'into another incoming event.');
    expect(await db.hasPendingUnanswered(_customer), isTrue);
  });

  test('backfill anchor is immutable and identical ownership has one OCR owner',
      () async {
    final anchor = now.add(const Duration(seconds: 10));
    final first = await frame('first-page',
        cutoff: anchor.millisecondsSinceEpoch, acquisition: true, keys: ['a']);
    await store.requestBackfill(_customer, anchor);
    expect(await store.record(first), isTrue);
    expect(
        await store.backfillCutoffFor(first,
            currentSignalAt: now.add(const Duration(hours: 1))),
        anchor);
    for (var i = 1; i <= 10; i++) {
      final repeated = await frame('duplicate-page-$i',
          cutoff: anchor.add(Duration(seconds: i * 10)).millisecondsSinceEpoch,
          acquisition: true,
          keys: ['a']);
      expect(await store.record(repeated), isFalse);
      expect(await repeated.filesExist(), isTrue);
      await store.requestBackfill(
          _customer, await store.backfillCutoffFor(first),
          reopenCovered: true);
    }
    expect((await store.pendingBackfills()).single['cutoff_ms'],
        anchor.millisecondsSinceEpoch);
    expect((await store.claim(mediaOnly: false))?.id, first.id);
    expect(await store.claim(mediaOnly: false), isNull);
    final newOwner = await frame('different-media-duty',
        cutoff: anchor.millisecondsSinceEpoch,
        acquisition: true,
        keys: ['a', 'b']);
    expect(await store.record(newOwner), isTrue,
        reason: 'Another actual media owner is not a duplicate obligation');
  });

  test('real unbound video survives known text and more than three retries',
      () async {
    final original =
        await inspection('unbound-video-frame', folder: 'v35_media');
    const selector = OcrImageCandidateSelector();
    final regions = selector.unboundCandidates(
        original, selector.select(original, _customer, includeTextDense: true));
    expect(regions, hasLength(1));
    final extraction = const OcrCaptureExtractor()
        .analyze(original, excludedMediaRegions: regions);
    expect(extraction.latestIncomingHasText, isTrue);
    final evidence = await frame('current-unbound',
        acquisition: true, keys: ['unbound-video']);
    await File('test/fixtures/v35_media/unbound-video-frame.png')
        .copy(evidence.imagePath);
    final audit = MediaCaptureAudit(db, record: (_, __) {});
    await audit.discoverUnbound(evidence, regions.single);
    await store.record(evidence);
    var currentClaim = (await store.claim(mediaOnly: false))!;
    expect(currentClaim.id, evidence.id);
    for (var i = 0; i < 8; i++) {
      await store.complete((await store.refreshClaim(currentClaim))!,
          partial: true);
      expect(
          await store.retryMedia(evidence.id,
              delay: Duration.zero, background: true),
          isTrue);
      currentClaim = (await store.claim(mediaOnly: true))!;
      expect(currentClaim.id, evidence.id);
      expect(await audit.unresolvedCount(evidence.id), 1);
      now = now.add(const Duration(seconds: 6));
    }
    expect(await evidence.filesExist(), isTrue);
    expect(await audit.pendingUnboundForCustomer(_customer), hasLength(1));
  });
}
