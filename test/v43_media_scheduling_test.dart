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
  late String session;
  final start = DateTime.utc(2026, 11, 9, 3, 44);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v43_media_schedule_');
    db = CaptureDatabase(storageRoot: root);
    session = await db.beginAutomationSession(startedAt: start);
    store = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(minutes: 2)));
    await store.beginSession(sessionId: session, startedAt: start);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id,
      {int second = 1,
      String customer = 'buyer',
      Map<String, Object?> metadata = const {}}) async {
    final image = await File('${root.path}/$id.png').writeAsBytes([1, 2, 3]);
    final value = ViewportEvidence({
      'evidenceId': id,
      'customer': customer,
      'imagePath': image.path,
      'manifestPath': '${root.path}/$id.json',
      'capturedAtMs':
          start.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'automationSessionId': session,
      'replyActivationAllowed': true,
      'capturePurpose': 'live_signal',
      ...metadata,
    });
    await File(value.manifestPath).writeAsString(value.toJson());
    return value;
  }

  Future<void> saveOcr(ViewportEvidence value,
          {String? activeCustomer, String? sourceHash}) =>
      File('${value.manifestPath}.ocr.json').writeAsString(jsonEncode({
        'evidenceId': value.id,
        'customer': value.customer,
        'activeCustomerId': activeCustomer ?? value.customer,
        'capturedAtMs': value.capturedAt.millisecondsSinceEpoch,
        'sourcePngSHA256': sourceHash,
        'observations': [],
        'visualRegions': [],
      }));

  Future<void> link(
      ViewportEvidence value, String owner, String receipt) async {
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'observation:${value.id}',
      'evidence_id': value.id,
      'customer': value.customer,
      'state': 'video_preview_only',
      'updated_at_ms': value.capturedAt.millisecondsSinceEpoch,
      'details': jsonEncode({
        'automationSessionId': session,
        'parentMessageId': owner,
        'mediaReceiptId': receipt,
      }),
    });
  }

  Future<String> own(ViewportEvidence value, String owner) async {
    final receipt = await CustomerMediaInventory(db).observe(
        customer: value.customer,
        evidenceId: value.id,
        observedAt: value.capturedAt,
        senderAt: value.capturedAt,
        slot: 0,
        region: [.27, .44, .12, .24],
        current: true,
        occurrenceKey: 'real-arrival:$owner');
    await db.admitMediaMessage(value.customer,
        receiptId: receipt,
        evidenceId: value.id,
        occurrenceKey: 'real-arrival:$owner',
        receivedAt: value.capturedAt,
        messageId: owner);
    await link(value, owner, receipt);
    return receipt;
  }

  Future<void> queueMedia(ViewportEvidence value, {bool ocr = true}) async {
    await store.record(value);
    if (ocr) await saveOcr(value);
    await store.complete(value, partial: true);
    expect(
        await store.retryMedia(value.id,
            background: true, delay: Duration.zero),
        isTrue);
  }

  Future<String> state(String id) async =>
      (await (await db.database).query('capture_evidence',
              columns: ['state'], where: 'id=?', whereArgs: [id]))
          .single['state']! as String;

  for (final olderState in ['captured', 'processing', 'retry']) {
    test('admitted saved-OCR media bypasses older $olderState screenshot',
        () async {
      final old = await frame('old-f4');
      await store.record(old);
      await (await db.database).update(
          'capture_evidence', {'state': olderState},
          where: 'id=?', whereArgs: [old.id]);
      final media = await frame('registered-184', second: 3);
      await store.record(media);
      await own(media, 'video-owner');
      await queueMedia(media);
      expect((await store.claim(mediaOnly: true))?.id, media.id);
      expect(await state(old.id), olderState,
          reason:
              'Processing one proved owner does not skip or finish old OCR');
    });
  }

  test('held old OCR does not block media or new textual business', () async {
    final old = await frame('held-f4');
    await store.record(old);
    final oldClaim = (await store.claim(mediaOnly: false))!;
    final releaseOld = Completer<void>();
    final oldOcr = releaseOld.future.then((_) => store.complete(oldClaim));
    final media = await frame('ready-184', second: 3);
    await store.record(media);
    await own(media, 'video-owner');
    await queueMedia(media);
    final mediaJob = await store.claim(mediaOnly: true);
    expect(mediaJob?.id, media.id);
    expect(releaseOld.isCompleted, isFalse);
    expect(await state(old.id), 'processing');

    for (final customer in ['buyer', 'another-buyer']) {
      await db.observePlatformResponse(customer,
          red: true,
          observedAt: start.add(const Duration(seconds: 5)),
          identityVerified: true);
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: session,
          capturedAt: start.add(const Duration(seconds: 6)),
          messages: [
            CapturedMessage(
                stableId: '$customer-new-question',
                direction: 'incoming',
                body: 'The print is faint, how do I fix it?',
                sender: customer,
                sentAt: start.add(const Duration(seconds: 6)),
                axPath: 'new question during held OCR')
          ]));
      expect(await db.hasPendingUnanswered(customer), isTrue);
      expect(await db.platformResponseCycle(customer), isNotNull);
    }
    expect((await db.unansweredWorkCounts())['buyer'], 2);
    expect((await db.unansweredWorkCounts())['another-buyer'], 1);
    expect(releaseOld.isCompleted, isFalse,
        reason:
            'Neither new customer duty waits for old screenshot completion');
    await store.complete(mediaJob!);
    releaseOld.complete();
    await oldOcr;
  });

  for (final reason in [
    'no-admission',
    'no-ocr',
    'wrong-ax',
    'wrong-pixels',
    'out-of-acquisition-scope'
  ]) {
    test('$reason cannot use the owner media fast lane', () async {
      final old = await frame('blocking-old');
      await store.record(old);
      await store.claim(mediaOnly: false);
      final media = await frame('untrusted-media', second: 3, metadata: {
        if (reason == 'wrong-pixels') 'pngSHA256': 'actual-pixels',
        if (reason == 'out-of-acquisition-scope') ...{
          'acquisitionOnly': true,
          'acquisitionInputKeys': ['another-owner'],
        },
      });
      await store.record(media);
      if (reason != 'no-admission') {
        await own(media, 'video-owner');
      } else {
        await link(media, 'invented-owner', 'unbound-receipt');
      }
      await queueMedia(media, ocr: reason != 'no-ocr');
      if (reason == 'wrong-ax') {
        await saveOcr(media, activeCustomer: 'someone-else');
      }
      if (reason == 'wrong-pixels') {
        await saveOcr(media, sourceHash: 'another-image');
      }
      expect(await store.claim(mediaOnly: true), isNull);
      expect(await state(media.id), 'media_retry');
    });
  }

  test('admitted media cannot bypass an unfinished Start baseline', () async {
    final baseline = await frame('start-baseline', metadata: {
      'capturePurpose': 'history_only',
      'replyActivationAllowed': false
    });
    await store.discoveryCapture(baseline,
        hasLiveWork: false, hasPendingWork: false, acquisition: false);
    final media = await frame('blocked-by-baseline',
        second: 3, metadata: {'capturePurpose': 'active_discovery'});
    await store.record(media);
    await own(media, 'video-owner');
    await queueMedia(media);
    await (await db.database).update(
        'capture_evidence', {'discovery_requires_baseline': 1},
        where: 'id=?', whereArgs: [media.id]);
    final reservation = (await (await db.database).query(
            'capture_discovery_state',
            where: 'session_id=? AND customer=?',
            whereArgs: [session, 'buyer']))
        .single;
    expect(reservation['kind'], 'baseline');
    expect(reservation['ready'], 0,
        reason: 'The negative must actually retain its unfinished baseline');
    expect(await store.claim(mediaOnly: true), isNull);
    expect(await state(media.id), 'media_retry');
  });

  test('two stores cannot process two representations of one owner together',
      () async {
    final other = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(minutes: 2)));
    await other.beginSession(sessionId: session, startedAt: start);
    final first = await frame('first-representation');
    final second = await frame('later-representation', second: 2);
    await store.record(first);
    final receipt = await own(first, 'video-owner');
    await queueMedia(first);
    await link(second, 'video-owner', receipt);
    await queueMedia(second);
    final claims = await Future.wait([
      store.claim(mediaOnly: true),
      other.claim(mediaOnly: true),
    ]);
    expect(claims.whereType<ViewportEvidence>(), hasLength(1));
    expect((await db.unansweredWorkCounts())['buyer'], 1);
    expect(await store.claim(mediaOnly: true), isNull);
    await store.complete(claims.whereType<ViewportEvidence>().single);
    expect(await other.claim(mediaOnly: true), isNotNull);
  });

  test('an active media owner does not lock a different owner of that customer',
      () async {
    final other = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(minutes: 2)));
    await other.beginSession(sessionId: session, startedAt: start);
    final first = await frame('first-video');
    await store.record(first);
    await own(first, 'video-one');
    await queueMedia(first);
    expect((await store.claim(mediaOnly: true))?.id, first.id);
    final second = await frame('independent-video', second: 2);
    await store.record(second);
    await own(second, 'video-two');
    await queueMedia(second);
    expect((await other.claim(mediaOnly: true))?.id, second.id);
    expect((await db.unansweredWorkCounts())['buyer'], 2);
  });

  test('reserved live lane admits first AX customer while older OCR is held',
      () async {
    final old = await frame('old-customer-a');
    await store.record(old);
    expect((await store.claim(mediaOnly: false))?.id, old.id);
    final b = await frame('first-customer-b',
        customer: 'new-buyer',
        second: 2,
        metadata: {
          'unreadArrivalKey': 'arrival:verified-current:$session:new-buyer',
          'captureRequestedBackfill': false,
          'admissionFrontier': null,
        });
    final saved = await store.discoveryCapture(b,
        hasLiveWork: true, hasPendingWork: false, acquisition: false);
    expect(saved.evidence.metadata['capturePurpose'], 'live_signal');
    expect(
        (await store.claim(mediaOnly: false, liveRegistrationOnly: true))?.id,
        b.id);
    expect(await state(old.id), 'processing');
  });

  test('live lane retains frozen-frontier same-customer overtaking proof',
      () async {
    final old = await frame('old-a');
    await store.record(old);
    await store.claim(mediaOnly: false);
    final fresh = await frame('fresh-a', second: 2, metadata: {
      'unreadArrivalKey': 'new-current-ax-arrival',
      'captureRequestedBackfill': false,
      'admissionFrontier': {'id': 'already-known-parent'},
    });
    await store.record(fresh);
    expect(
        (await store.claim(mediaOnly: false, liveRegistrationOnly: true))?.id,
        fresh.id);
    expect(await state(old.id), 'processing');
  });

  test('current unanswered frame uses live lane without a second AX arrival',
      () async {
    final old = await frame('old-recovery', customer: 'other-buyer');
    await store.record(old);
    expect((await store.claim(mediaOnly: false))?.id, old.id);
    final current = await frame('new-unanswered', second: 2, metadata: {
      'captureRequestedBackfill': false,
      'admissionFrontier': {'id': 'already-known-parent'},
    });
    await store.discoveryCapture(current,
        hasLiveWork: false, hasPendingWork: true, acquisition: false);
    final historical = await frame('historical', second: 1, metadata: {
      'capturePurpose': 'durable_unanswered',
      'captureRequestedBackfill': false,
      'historyCutoffMs': start.millisecondsSinceEpoch,
      'admissionFrontier': {'id': 'already-known-parent'},
    });
    await store.record(historical);
    expect(
        (await store.claim(mediaOnly: false, liveRegistrationOnly: true))?.id,
        current.id);
    expect(await state(old.id), 'processing');
    expect(await state(historical.id), 'captured');
  });

  test('raw history and Start baseline cannot consume the reserved live lane',
      () async {
    final old = await frame('raw-old-a');
    await store.record(old);
    final baseline = await frame('first-passive-b',
        customer: 'new-buyer',
        second: 2,
        metadata: {'replyActivationAllowed': false});
    await store.discoveryCapture(baseline,
        hasLiveWork: false, hasPendingWork: false, acquisition: false);
    final history = await frame('history-c',
        customer: 'history-buyer',
        second: 3,
        metadata: {
          'unreadArrivalKey': 'current-signal-is-not-ownership',
          'captureRequestedBackfill': false,
          'historyCutoffMs': start.millisecondsSinceEpoch,
          'admissionFrontier': null,
        });
    await store.discoveryCapture(history,
        hasLiveWork: true, hasPendingWork: false, acquisition: false);
    expect(await store.claim(mediaOnly: false, liveRegistrationOnly: true),
        isNull);
    expect(await state(old.id), 'captured');
    expect(await state(baseline.id), 'captured');
    expect(await state(history.id), 'captured');
  });

  test('pin wakes only exact owner and preserves previously stored metadata',
      () async {
    final a = await frame('pin-a', metadata: {
      'admittedTextInputIds': ['typed-a']
    });
    final b = await frame('wait-b', second: 2);
    for (final value in [a, b]) {
      await store.record(value);
      await own(value, 'owner-${value.id}');
      await store.complete(value, partial: true);
      await store.waitForMediaProgress(value);
    }
    final stale =
        ViewportEvidence({...a.metadata}..remove('admittedTextInputIds'));
    await store
        .pin(stale.withPinnedMedia({'kind': 'video', 'cacheKey': 'pin-a'}));
    expect(await store.wakePinnedMedia(stale), 1);
    expect(await state(a.id), 'media_retry');
    expect(await state(b.id), 'media_waiting');
    expect((await store.lookup(a.id))!.metadata['admittedTextInputIds'],
        ['typed-a']);
  });

  test('a pin without an admitted frame owner cannot wake unrelated media',
      () async {
    final owned = await frame('owned-waiting');
    await store.record(owned);
    await own(owned, 'video-owner');
    await store.complete(owned, partial: true);
    await store.waitForMediaProgress(owned);
    final unowned = await frame('unbound-pin', second: 2);
    await store.record(unowned);
    await store
        .pin(unowned.withPinnedMedia({'kind': 'video', 'cacheKey': 'unbound'}));
    expect(await store.wakePinnedMedia(unowned), 0);
    expect(await state(owned.id), 'media_waiting');
  });

  test('Restart cannot claim or complete an old-session media job', () async {
    final media = await frame('old-run-media');
    await store.record(media);
    await own(media, 'old-video-owner');
    await queueMedia(media);
    final held = (await store.claim(mediaOnly: true))!;
    final nextStart = start.add(const Duration(minutes: 3));
    final next = await db.beginAutomationSession(startedAt: nextStart);
    // Between DB reset and store reset, old-session claims already stop.
    expect(await store.claim(mediaOnly: true), isNull);
    await store.beginSession(sessionId: next, startedAt: nextStart);
    await store.complete(held);
    expect(await state(media.id), 'session_archived');
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await store.wakePinnedMedia(held), 0);
  });
}
