import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/capture/evidence_coverage.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  late Directory root;
  late Directory frames;
  late CaptureDatabase db;
  late CaptureEvidenceStore inbox;
  late DateTime now;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_evidence_test_');
    frames = await Directory('${root.path}/capture_evidence').create();
    db = CaptureDatabase(storageRoot: root);
    now = DateTime.utc(2026, 10, 31, 10);
    inbox = CaptureEvidenceStore(db, now: () => now);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<ViewportEvidence> frame(String id, String customer, int second) async {
    final png = File('${frames.path}/$id.png');
    await png.writeAsBytes([1, 2, 3, second]);
    final manifest = File('${frames.path}/$id.json');
    final values = <String, Object?>{
      'evidenceId': id,
      'customer': customer,
      'imagePath': png.path,
      'manifestPath': manifest.path,
      'capturedAtMs': now.add(Duration(seconds: second)).millisecondsSinceEpoch
    };
    await manifest.writeAsString(jsonEncode(values));
    return ViewportEvidence(values);
  }

  test('observation is durable before a window is opened or any OCR runs',
      () async {
    await inbox.observe('customer', now);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    inbox = CaptureEvidenceStore(db);
    expect(await inbox.awaitingFrameCustomers(), {'customer'});
    expect(await inbox.claim(), isNull);
  });
  test('AX-verified rebinding moves only the observation, not customer history',
      () async {
    await inbox.observe('ja_customer', now);
    await inbox.rebindObservation('ja_customer', 'jd_customer');
    expect(await inbox.awaitingFrameCustomers(), {'jd_customer'});
    expect(await inbox.firstObserved('jd_customer'), now);
  });
  test('manifests recover after the cache folder moves to another machine',
      () async {
    final a = await frame('a', 'customer', 0);
    final moved = await Directory('${root.path}/moved').create();
    await File(a.imagePath).copy('${moved.path}/a.png');
    await File(a.manifestPath).copy('${moved.path}/a.json');
    await File(a.imagePath).delete();
    await File(a.manifestPath).delete();
    await inbox.recover(moved);
    final claimed = (await inbox.claim())!;
    expect(claimed.manifestPath, '${moved.path}/a.json');
    expect(await claimed.filesExist(), isTrue);
  });
  test('different customers can register while one timeline remains ordered',
      () async {
    final a = await frame('reg-a', 'buyer-a', 0);
    final nextA = await frame('reg-next-a', 'buyer-a', 1);
    final b = await frame('reg-b', 'buyer-b', 2);
    final c = await frame('reg-c', 'buyer-c', 3);
    for (final evidence in [a, nextA, b, c]) {
      await inbox.record(evidence);
    }
    final ready = await inbox.dueRegistrationCustomers();
    expect(ready, {a.customer, b.customer, c.customer});
    final claims = await Future.wait([
      for (final customer in ready)
        inbox.claim(mediaOnly: false, registrationCustomer: customer),
    ]);
    expect(claims.map((e) => e?.id).toSet(), {a.id, b.id, c.id});
    expect(
        await inbox.claim(mediaOnly: false, registrationCustomer: a.customer),
        isNull);
    await inbox.complete(claims.firstWhere((e) => e?.id == a.id)!);
    expect(
        (await inbox.claim(mediaOnly: false, registrationCustomer: a.customer))
            ?.id,
        nextA.id);
  });
  test('same turn retains its first detection timestamp', () async {
    await inbox.observe('customer', now);
    await inbox.observe('customer', now.add(const Duration(seconds: 8)));
    expect(await inbox.firstObserved('customer'), now);
  });
  test('new messages and sidebar reorder cannot overwrite older saved pixels',
      () async {
    final a = await frame('a', 'customer-a', 0);
    final b = await frame('b', 'customer-b', 1);
    final nextA = await frame('next-a', 'customer-a', 2);
    for (final f in [a, b, nextA]) {
      await inbox.record(f);
    }
    expect((await inbox.claim())?.id, 'a');
    expect((await inbox.claim())?.id, 'b');
    await inbox.complete(a);
    expect((await inbox.claim())?.id, 'next-a');
    expect(await File(a.imagePath).readAsBytes(), [1, 2, 3, 0]);
    expect(await inbox.claim(), isNull);
  });
  test(
      'every due media customer can claim independently without sharing a lease',
      () async {
    final a = await frame('media-a', 'customer-a', 0);
    final duplicate = await frame('media-a-again', 'customer-a', 1);
    final b = await frame('media-b', 'customer-b', 2);
    final c = await frame('media-c', 'customer-c', 3);
    final d = await frame('media-d', 'customer-d', 4);
    final e = await frame('media-e', 'customer-e', 5);
    for (final evidence in [a, duplicate, b, c, d, e]) {
      await inbox.record(evidence);
      await inbox.complete(evidence);
      expect(
          await inbox.retryMedia(evidence.id,
              delay: Duration.zero, background: true),
          isTrue);
    }
    final customers = await inbox.dueMediaCustomers();
    expect(customers,
        {a.customer, b.customer, c.customer, d.customer, e.customer});
    final claims = await Future.wait([
      for (final customer in customers)
        inbox.claim(mediaOnly: true, mediaCustomer: customer),
    ]);
    expect(claims.map((e) => e?.id).toSet(), {a.id, b.id, c.id, d.id, e.id});
    expect(
        await inbox.claim(mediaOnly: true, mediaCustomer: a.customer), isNull);
    await inbox.complete(claims.firstWhere((e) => e?.id == a.id)!);
    expect((await inbox.claim(mediaOnly: true))?.id, duplicate.id);
  });
  test(
      'a customer can process two admitted media messages but not the same owner twice',
      () async {
    const customer = 'buyer';
    now = DateTime.now().toUtc();
    final started = now.subtract(const Duration(minutes: 1));
    final session = await db.beginAutomationSession(startedAt: started);
    await inbox.beginSession(sessionId: session, startedAt: started);
    final inventory = CustomerMediaInventory(db);
    Future<String> enqueue(String id, int second, {String? owner}) async {
      final evidence = ViewportEvidence({
        ...(await frame(id, customer, second)).metadata,
        'automationSessionId': session,
      });
      await inbox.record(evidence);
      final epoch = now.millisecondsSinceEpoch ~/ 1000 * 1000;
      final sentAt = DateTime.fromMillisecondsSinceEpoch(epoch + second * 1000,
          isUtc: true);
      final receipt = owner ??
          await inventory.observe(
              customer: customer,
              evidenceId: id,
              observedAt: now,
              senderAt: sentAt,
              slot: 0,
              region: [.25, .4, .15, .3],
              current: true);
      if (owner == null) {
        await db.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: id,
            occurrenceKey: 'arrival-$id',
            receivedAt: sentAt,
            senderAt: sentAt);
      }
      await (await db.database).insert('media_capture_audit', {
        'observation_id': 'obs-$id',
        'evidence_id': id,
        'customer': customer,
        'state': 'discovered',
        'details': jsonEncode({
          'automationSessionId': session,
          'mediaReceiptId': receipt,
        }),
        'updated_at_ms': now.millisecondsSinceEpoch,
      });
      await inbox.complete(evidence);
      expect(await inbox.retryMedia(id, delay: Duration.zero, background: true),
          isTrue);
      return receipt;
    }

    final first = await enqueue('first', -4);
    await enqueue('duplicate', -3, owner: first);
    await enqueue('other', -2);
    final claims = await Future.wait([
      for (var i = 0; i < 3; i++)
        inbox.claim(mediaOnly: true, mediaCustomer: customer)
    ]);
    expect(claims.map((e) => e?.id).toSet(), {'first', 'other', null});
    await inbox.complete(claims.firstWhere((e) => e?.id == 'first')!);
    expect((await inbox.claim(mediaOnly: true, mediaCustomer: customer))?.id,
        'duplicate');
  });
  test('retrying an older frame blocks only later frames of the same customer',
      () async {
    final a = await frame('a', 'customer-a', 0);
    final nextA = await frame('next-a', 'customer-a', 1);
    final b = await frame('b', 'customer-b', 2);
    for (final f in [a, nextA, b]) {
      await inbox.record(f);
    }
    expect((await inbox.claim())?.id, 'a');
    await inbox.fail(a, StateError('temporary OCR failure'));
    expect((await inbox.claim())?.id, 'b');
    expect(await inbox.claim(), isNull);
    now = now.add(const Duration(seconds: 6));
    expect((await inbox.claim())?.id, 'a');
    await inbox.complete(a);
    expect((await inbox.claim())?.id, 'next-a');
  });
  test('repeated unchanged frame is queued once, concurrent claims are unique',
      () async {
    final a = await frame('a', 'customer', 0);
    expect(await inbox.record(a), isTrue);
    expect(await inbox.record(a), isFalse);
    final claims = await Future.wait([inbox.claim(), inbox.claim()]);
    expect(claims.whereType<ViewportEvidence>(), hasLength(1));
  });
  test('incomplete file acquisition is never marked captured', () async {
    await inbox.observe('customer', now);
    final a = await frame('a', 'customer', 0);
    await File(a.imagePath).delete();
    await expectLater(inbox.record(a), throwsStateError);
    expect(await inbox.awaitingFrameCustomers(), {'customer'});
  });
  test('restart recovers an interrupted worker and an orphaned manifest',
      () async {
    final a = await frame('a', 'customer-a', 0);
    await inbox.record(a);
    await inbox.claim();
    await frame('b', 'customer-b',
        1); // process died after disk commit, before SQLite commit
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    inbox = CaptureEvidenceStore(db);
    await inbox.recover(frames);
    expect((await inbox.claim())?.id, 'a');
    expect((await inbox.claim())?.id, 'b');
  });
  test(
      'original-media enrichment is durable while an OCR worker owns the frame',
      () async {
    final a = await frame('a', 'customer', 0);
    await inbox.record(a);
    await inbox.claim();
    await inbox
        .pin(a.withPinnedMedia({'kind': 'image', 'evidenceFile': 'pinned'}));
    expect((await inbox.lookup(a.id))?.pinnedMedia?['evidenceFile'], 'pinned');
  });
  test('recognition failures retain raw evidence and stop after three attempts',
      () async {
    final a = await frame('a', 'customer', 0);
    await inbox.record(a);
    for (var attempt = 0; attempt < 3; attempt++) {
      expect((await inbox.claim())?.id, 'a');
      await inbox.fail(a, StateError('OCR unavailable'));
      expect(await File(a.imagePath).exists(), isTrue);
      if (attempt < 2) {
        expect(await inbox.claim(), isNull);
        now = now.add(const Duration(seconds: 6));
      }
    }
    now = now.add(const Duration(minutes: 1));
    expect(await inbox.claim(), isNull);
    expect(await File(a.imagePath).exists(), isTrue);
  });
  test('retention removes only completed cache files, never pending frames',
      () async {
    final pending = await frame('pending', 'a', 0);
    await inbox.record(pending);
    final old = await frame('old', 'b', 1);
    await inbox.record(old);
    await inbox.complete(old);
    final recent = await frame('recent', 'b', 2);
    await inbox.record(recent);
    await inbox.complete(recent);
    await inbox.pruneProcessed(keep: 1);
    expect(await File(old.imagePath).exists(), isFalse);
    expect(await File(recent.imagePath).exists(), isTrue);
    expect(await File(pending.imagePath).exists(), isTrue);
  });
  test(
      'history backfill is bounded and a covered result wins over final-page bookkeeping',
      () async {
    await inbox.requestBackfill('customer', now, stepPixels: 200);
    for (var i = 0; i < 3; i++) {
      expect(await inbox.pendingBackfills(), hasLength(1));
      await inbox.backfillAttempt('customer');
    }
    expect(await inbox.pendingBackfills(), isEmpty);
    expect(await inbox.coverageState('customer'), 'exhausted');
    await inbox.requestBackfill(
        'customer', now); // same turn cannot restart a loop
    expect(await inbox.pendingBackfills(), isEmpty);
    await inbox.covered('customer');
    await inbox.backfillAttempt('customer');
    expect(await inbox.coverageState('customer'), 'covered');
  });
  test(
      'unfinished scroll restoration preserves a history cutoff through restart',
      () async {
    await inbox.requestBackfill('customer', now);
    await inbox.setRestore('customer', true);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    inbox = CaptureEvidenceStore(db);
    expect(
        await inbox.restoreCutoffs(), {'customer': now.millisecondsSinceEpoch});
    await inbox.setRestore('customer', false);
    expect(await inbox.restoreCutoffs(), isEmpty);
  });
  test('no capture retry loop remains after three acquisition failures',
      () async {
    await inbox.observe('customer', now);
    for (var i = 0; i < 3; i++) {
      await inbox.captureFailed('customer');
    }
    expect(await inbox.failedCaptures(), {'customer'});
  });
  test(
      'coverage asks for backfill only for a timestamp gap inside the observed turn',
      () {
    expect(
        EvidenceCoverage.needsBackfill(
            firstObserved: now,
            capturedAt: now.add(const Duration(seconds: 15)),
            visibleIncoming: [
              now.add(const Duration(seconds: 8)),
              now.add(const Duration(seconds: 14))
            ]),
        isTrue);
    expect(
        EvidenceCoverage.needsBackfill(
            firstObserved: now,
            capturedAt: now.add(const Duration(seconds: 15)),
            visibleIncoming: [
              now.add(const Duration(seconds: 1)),
              now.add(const Duration(seconds: 14))
            ]),
        isFalse);
    expect(
        EvidenceCoverage.needsBackfill(
            firstObserved: now,
            capturedAt: now.subtract(const Duration(seconds: 1)),
            visibleIncoming: [now.add(const Duration(seconds: 8))]),
        isFalse);
    expect(EvidenceCoverage.scrollPixels(2, stepPixels: 200), 600);
  });
}
