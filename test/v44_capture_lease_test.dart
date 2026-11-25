import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late CaptureEvidenceStore other;
  late String session;
  final start = DateTime.utc(2026, 11, 9, 5, 39);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_capture_lease_');
    db = CaptureDatabase(storageRoot: root);
    session = await db.beginAutomationSession(startedAt: start);
    store = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(minutes: 1)));
    other = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(minutes: 1)));
    await store.beginSession(sessionId: session, startedAt: start);
    await other.beginSession(sessionId: session, startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id,
      {int second = 1,
      String customer = 'buyer',
      String purpose = 'arrival_observation',
      bool active = false}) async {
    final image = await File('${root.path}/$id.png').writeAsBytes([1, 2, 3]);
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': customer,
      'automationSessionId': session,
      'capturedAtMs':
          start.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'imagePath': image.path,
      'manifestPath': '${root.path}/$id.json',
      'capturePurpose': purpose,
      'replyActivationAllowed': active,
      'captureRequestedBackfill': false,
    });
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    return evidence;
  }

  ViewportEvidence activate(ViewportEvidence value,
          {String purpose = 'live_signal', bool active = true}) =>
      ViewportEvidence({
        ...value.metadata,
        'capturePurpose': purpose,
        'replyActivationAllowed': active,
        'unreadArrivalKey': 'actual-AX-arrival',
        'admissionFrontier': {'id': 'proved-frontier'},
      });

  Future<Map<String, Object?>> row(String id) async =>
      (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;

  Future<void> saveOcr(ViewportEvidence evidence) async {
    await File('${evidence.manifestPath}.ocr.json').writeAsString(jsonEncode({
      'evidenceId': evidence.id,
      'customer': evidence.customer,
      'activeCustomerId': evidence.customer,
      'capturedAtMs': evidence.capturedAt.millisecondsSinceEpoch,
      'observations': [],
      'visualRegions': [],
    }));
  }

  Future<String> media(ViewportEvidence evidence, String? parent) async {
    await store.record(evidence);
    final receipt = await CustomerMediaInventory(db).observe(
        customer: evidence.customer,
        evidenceId: evidence.id,
        observedAt: evidence.capturedAt,
        senderAt: evidence.capturedAt,
        slot: 0,
        region: [.27, .4, .12, .24],
        current: true,
        occurrenceKey: parent == null ? null : 'arrival:$parent');
    if (parent != null) {
      await db.admitMediaMessage(evidence.customer,
          receiptId: receipt,
          evidenceId: evidence.id,
          occurrenceKey: 'arrival:$parent',
          receivedAt: evidence.capturedAt,
          messageId: parent);
    }
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'observation:${evidence.id}',
      'evidence_id': evidence.id,
      'customer': evidence.customer,
      'state': 'video_preview_only',
      'updated_at_ms': evidence.capturedAt.millisecondsSinceEpoch,
      'details': jsonEncode({
        'automationSessionId': session,
        if (parent != null) 'parentMessageId': parent,
        'mediaReceiptId': receipt
      }),
    });
    await saveOcr(evidence);
    await store.complete(evidence, partial: true);
    await store.retryMedia(evidence.id, delay: Duration.zero, background: true);
    return receipt;
  }

  test(
      'held general OCR adopts live activation without a second extraction lease',
      () async {
    final raw = await frame('same-frozen-pixels');
    await store.record(raw);
    final first = (await store.claim(mediaOnly: false))!;
    final releaseOcr = Completer<void>();
    var ocrCount = 0;
    final extraction = () async {
      ocrCount++;
      await releaseOcr.future;
      await saveOcr(first);
      final current = (await store.refreshClaim(first))!;
      expect(current.metadata['replyActivationAllowed'], isTrue);
      expect(current.metadata['captureClaimToken'],
          first.metadata['captureClaimToken']);
      await db.saveCapture(CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: session,
          capturedAt: current.capturedAt,
          messages: [
            CapturedMessage(
                stableId: 'one-real-question',
                direction: 'incoming',
                body: 'How do I turn the printer on?',
                axPath: 'shared immutable OCR')
          ]));
      await store.complete(current);
    }();
    expect(await other.record(activate(raw)), isTrue);
    expect((await row(raw.id))['state'], 'processing');
    expect(await other.claim(mediaOnly: false, liveRegistrationOnly: true),
        isNull);
    expect(await other.claim(mediaOnly: false), isNull);
    releaseOcr.complete();
    await extraction;
    expect(ocrCount, 1);
    expect((await row(raw.id))['state'], 'processed');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    expect(await other.claim(mediaOnly: false), isNull);
  });

  test(
      'unacknowledged promotion releases once into an OCR-reuse registration replay',
      () async {
    final raw = await frame('late-promotion');
    await store.record(raw);
    final original = (await store.claim(mediaOnly: false))!;
    await saveOcr(original);
    await other.record(activate(raw));
    expect(await other.claim(mediaOnly: false), isNull);
    await store.complete(original);
    expect((await row(raw.id))['state'], 'captured');
    final replay =
        (await other.claim(mediaOnly: false, liveRegistrationOnly: true))!;
    expect(replay.metadata['captureReplayOcr'], isTrue);
    expect(replay.metadata['captureClaimToken'],
        isNot(original.metadata['captureClaimToken']));
    await store.complete(original, partial: true);
    await store.fail(original, StateError('late original callback'));
    await store
        .pin(original.withPinnedMedia({'kind': 'video', 'cacheKey': 'old'}));
    expect((await row(raw.id))['state'], 'processing');
    expect((await store.lookup(raw.id))!.pinnedMedia, isNull);
    expect(await store.refreshClaim(original), isNull);
    await other.complete(replay);
    expect((await row(raw.id))['state'], 'processed');
  });

  test(
      'an old activation acknowledgement cannot release an updated same-token owner',
      () async {
    final raw = await frame('activation-cas');
    await store.record(raw);
    final original = (await store.claim(mediaOnly: false))!;
    await store
        .record(activate(raw, purpose: 'discovery_baseline', active: false));
    final acknowledged = (await store.refreshClaim(original))!;
    await store.record(activate(raw));
    await store.complete(original);
    expect((await row(raw.id))['state'], 'processing',
        reason:
            'Same token is insufficient after a newer activation acknowledgement');
    await store.complete(acknowledged);
    expect((await row(raw.id))['state'], 'captured');
    final replay = (await store.claim(mediaOnly: false))!;
    await store.fail(acknowledged, StateError('late old acknowledgement'));
    expect((await row(raw.id))['state'], 'processing');
    await store.complete(replay);
  });

  test('promotion and producer pin preserve the active media processing lease',
      () async {
    final raw =
        await frame('active-media', purpose: 'active_discovery', active: true);
    await media(raw, 'video-owner');
    final first = (await store.claim(mediaOnly: true))!;
    await other.record(activate(raw));
    expect((await row(raw.id))['state'], 'media_processing');
    await store.pin(activate(raw)
        .withPinnedMedia({'kind': 'video', 'cacheKey': 'correct'}));
    final stored = (await store.lookup(raw.id))!;
    expect(stored.metadata['captureClaimToken'],
        first.metadata['captureClaimToken']);
    expect(stored.metadata['captureClaimActivationRevision'],
        first.metadata['captureClaimActivationRevision']);
    expect(await other.claim(mediaOnly: true), isNull);
    expect(await other.claim(mediaOnly: false, liveRegistrationOnly: true),
        isNull);
    final latest = (await store.refreshClaim(first))!;
    expect(latest.pinnedMedia!['cacheKey'], 'correct');
    await store.complete(latest);
    expect((await row(raw.id))['state'], 'processed');
  });

  test(
      'current admitted media goes before much older unbound retries without deleting them',
      () async {
    final old =
        await frame('old-unbound', purpose: 'active_discovery', active: true);
    await media(old, null);
    final current = await frame('real-current-video',
        second: 10, purpose: 'live_signal', active: true);
    await media(current, 'current-owner');
    expect((await store.claim(mediaOnly: true))?.id, current.id);
    expect((await row(old.id))['state'], 'media_retry');
    expect(await File(old.imagePath).exists(), isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test(
      'admitted media scheduling rotates customers within the same ready class',
      () async {
    final a1 = await frame('a1', purpose: 'live_signal', active: true);
    final a2 =
        await frame('a2', second: 2, purpose: 'live_signal', active: true);
    final b = await frame('b1',
        second: 3, customer: 'buyer-b', purpose: 'live_signal', active: true);
    await media(a1, 'owner-a1');
    await media(a2, 'owner-a2');
    await media(b, 'owner-b1');
    final first = (await store.claim(mediaOnly: true))!;
    expect(first.id, a1.id);
    final second = (await other.claim(mediaOnly: true))!;
    expect(second.id, b.id,
        reason:
            'An older second video from A cannot monopolize the media queue');
    final third = (await store.claim(mediaOnly: true))!;
    expect(third.id, a2.id);
  });

  test('exact admission progress cannot wake historical unbound observations',
      () async {
    final old =
        await frame('old-waiting', purpose: 'active_discovery', active: true);
    await media(old, null);
    final current = await frame('owned-waiting',
        second: 2, purpose: 'live_signal', active: true);
    final receipt = await media(current, 'current-owner');
    for (final value in [old, current]) {
      await (await db.database).update(
          'capture_evidence', {'state': 'media_waiting'},
          where: 'id=?', whereArgs: [value.id]);
    }
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'admission:current-owner',
            ownerKeys: {'current-owner', receipt}),
        1);
    expect((await row(old.id))['state'], 'media_waiting');
    expect((await row(current.id))['state'], 'media_retry');
  });

  test('Stop and new Start cannot let an old extraction release the new owner',
      () async {
    final old = await frame('old-run');
    await store.record(old);
    final held = (await store.claim(mediaOnly: false))!;
    final release = Completer<void>();
    final callback = release.future.then((_) async {
      expect(await store.refreshClaim(held), isNull);
      await store.complete(held);
      await store.fail(held, StateError('late stopped OCR'));
      await store
          .pin(held.withPinnedMedia({'kind': 'video', 'cacheKey': 'late'}));
    });
    final nextStart = start.add(const Duration(minutes: 2));
    session = await db.beginAutomationSession(startedAt: nextStart);
    await store.beginSession(sessionId: session, startedAt: nextStart);
    final fresh = await frame('new-run',
        second: 121, purpose: 'live_signal', active: true);
    await store.record(fresh);
    final current = (await store.claim(mediaOnly: false))!;
    release.complete();
    await callback;
    expect((await row(old.id))['state'], 'session_archived');
    expect((await row(fresh.id))['state'], 'processing');
    expect((await store.lookup(fresh.id))!.metadata['captureClaimToken'],
        current.metadata['captureClaimToken']);
    await store.complete(current);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });
}
