import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late DateTime start;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_evidence_promotion_');
    db = CaptureDatabase(storageRoot: root);
    start = DateTime.utc(2026, 11, 4, 10);
    store = CaptureEvidenceStore(db,
        now: () => start.add(const Duration(seconds: 10)));
    await store.beginSession(sessionId: 'run-one', startedAt: start);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id,
      {String session = 'run-one',
      String purpose = 'history_only',
      bool active = false,
      int seconds = 1}) async {
    final png = File('${root.path}/$id.png');
    final manifest = File('${root.path}/$id.json');
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': 'buyer',
      'imagePath': png.path,
      'manifestPath': manifest.path,
      'capturedAtMs':
          start.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
      'automationSessionId': session,
      'capturePurpose': purpose,
      'replyActivationAllowed': active,
    });
    await png.writeAsBytes([1, 2, 3]);
    await manifest.writeAsString(evidence.toJson());
    return evidence;
  }

  ViewportEvidence activate(ViewportEvidence evidence,
          {String purpose = 'live_signal'}) =>
      ViewportEvidence({
        ...evidence.metadata,
        'replyActivationAllowed': true,
        'capturePurpose': purpose,
      });

  Future<Map<String, Object?>> row(String id) async =>
      (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;

  for (final purpose in ['live_signal', 'durable_unanswered']) {
    test('same frame skipped before $purpose is promoted once without cache',
        () async {
      final history = await frame('unchanged');
      final manifestBefore = await File(history.manifestPath).readAsString();
      await store.observe('buyer', start);
      expect(await store.record(history), isTrue);
      final oldJob = (await store.claim())!;
      await store.complete(oldJob);
      expect((await row(history.id))['state'], 'processed');

      final live = activate(history, purpose: purpose);
      expect(await store.record(live), isTrue);
      expect((await row(history.id))['state'], 'captured');
      expect(
          (await (await db.database).query('capture_observations'))
              .single['state'],
          'captured');
      final job = (await store.claim())!;
      expect(job.metadata['replyActivationAllowed'], isTrue);
      expect(job.metadata['capturePurpose'], purpose);
      expect(job.capturedAt, history.capturedAt);
      expect(job.pinnedMedia, isNull);
      expect(await store.claim(), isNull);
      await store.complete(job);

      expect(await store.record(live), isFalse);
      expect(await store.record(history), isFalse);
      expect((await row(history.id))['state'], 'processed');
      expect(
          (await store.lookup(history.id))!.metadata['replyActivationAllowed'],
          isTrue);
      expect(await store.claim(), isNull);
      expect(await File(history.imagePath).readAsBytes(), [1, 2, 3]);
      expect(await File(history.manifestPath).readAsString(), manifestBefore,
          reason:
              'Promotion changes queue metadata, never the immutable frame capture time or files.');
    });
  }

  test('stale history completion cannot finish a newly promoted or claimed job',
      () async {
    final history = await frame('claimed-before-signal');
    await store.observe('buyer', start);
    await store.record(history);
    final stale = (await store.claim())!;
    expect(await store.record(activate(history)), isTrue);
    await store.complete(stale);
    expect((await row(history.id))['state'], 'captured');
    final current = (await store.claim())!;
    await store.complete(stale, partial: true);
    await store.fail(stale, StateError('late history callback'));
    await store
        .pin(stale.withPinnedMedia({'kind': 'image', 'cacheKey': 'stale'}));
    final activeRow = await row(history.id);
    expect(activeRow['state'], 'processing');
    expect(activeRow['attempts'], 0);
    expect(
        jsonDecode(activeRow['payload']! as String)['replyActivationAllowed'],
        isTrue);
    expect((await store.lookup(history.id))!.pinnedMedia, isNull);
    await store.complete(current);
    expect((await row(history.id))['state'], 'processed');
  });

  test('old session frames cannot be promoted by an old callback or a new tag',
      () async {
    final history = await frame('old-frame');
    await store.record(history);
    await store.complete((await store.claim())!);
    await store.beginSession(
        sessionId: 'run-two', startedAt: start.add(const Duration(minutes: 1)));

    expect(await store.record(activate(history)), isFalse);
    final retagged = ViewportEvidence({
      ...activate(history).metadata,
      'automationSessionId': 'run-two',
    });
    expect(await store.record(retagged), isFalse,
        reason: 'A new tag cannot make an old native manifest fresh.');
    final fabricatedClock = ViewportEvidence({
      ...retagged.metadata,
      'capturedAtMs':
          start.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
    });
    expect(await store.record(fabricatedClock), isFalse,
        reason:
            'A persisted old-session row is not a same-run promotion target.');
    expect((await row(history.id))['state'], 'processed');
    expect((await store.lookup(history.id))!.metadata['automationSessionId'],
        'run-one');
    expect(await store.claim(), isNull);
  });

  test('completed live OCR is not requeued by another live observation',
      () async {
    final live =
        await frame('already-live', active: true, purpose: 'live_signal');
    await store.record(live);
    await store.complete((await store.claim())!);
    expect(await store.record(activate(live, purpose: 'durable_unanswered')),
        isFalse);
    expect(await store.claim(), isNull);
    expect((await row(live.id))['state'], 'processed');
  });

  test(
      'backfill, unverified activation and altered frame identity cannot promote',
      () async {
    final history = await frame('restricted');
    await store.record(history);
    await store.complete((await store.claim())!);
    expect(await store.record(activate(history, purpose: 'history_backfill')),
        isFalse);
    expect(
        await store.record(ViewportEvidence({
          ...activate(history).metadata,
          'historyCutoffMs': start.millisecondsSinceEpoch,
        })),
        isFalse);
    expect(
        await store.record(ViewportEvidence({
          ...activate(history).metadata,
          'capturedAtMs': history.capturedAt
              .add(const Duration(seconds: 1))
              .millisecondsSinceEpoch,
        })),
        isFalse);
    expect(
        await store.record(ViewportEvidence({
          ...activate(history).metadata,
          'customer': 'another-buyer',
        })),
        isFalse);
    expect((await row(history.id))['state'], 'processed');
    expect(await store.claim(), isNull);
  });
}
