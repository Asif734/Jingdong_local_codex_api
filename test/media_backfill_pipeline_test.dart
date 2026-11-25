import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/backfill_dispatcher.dart';
import 'package:jd_automation/capture/evidence_coverage.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore inbox;
  late MediaCaptureAudit audit;
  var now = DateTime.utc(2026, 11, 1);
  final events = <String>[];
  setUp(() async {
    now = DateTime.utc(2026, 11, 1);
    root = await Directory.systemTemp.createTemp('jd_media_pipeline_');
    db = CaptureDatabase(storageRoot: root);
    inbox = CaptureEvidenceStore(db, now: () => now);
    audit =
        MediaCaptureAudit(db, record: (e, f) => events.add('$e:${f['state']}'));
    events.clear();
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<ViewportEvidence> save(String id, [DateTime? cutoff]) async {
    final image = File('${root.path}/$id.png');
    final manifest = File('${root.path}/$id.json');
    await image.writeAsBytes([1, 2, 3]);
    final frame = ViewportEvidence({
      'evidenceId': id,
      'customer': 'a',
      'imagePath': image.path,
      'manifestPath': manifest.path,
      'capturedAtMs': now.millisecondsSinceEpoch,
      if (cutoff != null) 'historyCutoffMs': cutoff.millisecondsSinceEpoch
    });
    await manifest.writeAsString(frame.toJson());
    await inbox.record(frame);
    return frame;
  }

  BackfillDispatcher dispatcher(
          {Future<void> Function(String, int)? scroll,
          Future<ViewportEvidence?> Function(String, DateTime)? capture,
          bool Function()? canRun,
          int burstPages = 1,
          Future<void> Function(Future<void> Function())? withUi}) =>
      BackfillDispatcher(
          store: inbox,
          burstPages: burstPages,
          canRun: canRun ?? () => true,
          canVisit: (_) async => true,
          withUi: withUi ??
              (work) async {
                events.add('lease');
                await work();
                events.add('release');
              },
          open: (c) async => events.add('open:$c'),
          scroll: scroll ?? (c, d) async => events.add('scroll:$d'),
          capture: capture ??
              (c, cutoff) async {
                events.add('capture');
                return save('page${events.length}', cutoff);
              },
          record: (e, f) => events.add('$e:${f['stage']}'));

  test(
      'persisted gap is actually scrolled, saved with cutoff and restored without any OCR',
      () async {
    await inbox.requestBackfill('a', now, stepPixels: 312);
    await dispatcher().runOnePage();
    expect(events.where((e) => e.startsWith('scroll:')),
        ['scroll:312', 'scroll:-10000']);
    expect(
        events.indexOf('capture'), greaterThan(events.indexOf('scroll:312')));
    expect(events.indexOf('scroll:-10000'),
        greaterThan(events.indexOf('capture')));
    expect(await inbox.restoreCutoffs(), isEmpty);
    final frame = await inbox.claim();
    expect(frame!.metadata['historyCutoffMs'], now.millisecondsSinceEpoch);
    expect(await frame.filesExist(), isTrue);
  });
  test(
      'real page attempts stop at three, coverage stays explicitly unconfirmed',
      () async {
    await inbox.requestBackfill('a', now, stepPixels: 100);
    for (var i = 0; i < 5; i++) {
      await dispatcher().runOnePage();
    }
    expect(events.where((e) => e == 'capture').length, 3);
    expect(events.where((e) => e.startsWith('scroll:') && !e.contains('-')),
        ['scroll:100', 'scroll:200', 'scroll:300']);
    expect(await inbox.coverageState('a'), 'exhausted');
  });
  test('capture failure still restores bottom and retains bounded retry job',
      () async {
    await inbox.requestBackfill('a', now);
    await dispatcher(capture: (_, __) async => throw StateError('disk_failed'))
        .runOnePage();
    expect(events, contains('scroll:-10000'));
    expect(await inbox.restoreCutoffs(), isEmpty);
    expect(events, contains('evidence.backfill_failed:capture'));
    expect(
        (await (await db.database).query('capture_backfill')).single['pages'],
        1);
    expect(await inbox.pendingBackfills(), isEmpty);
  });
  test(
      'failed restore persists across restart for recovery before another scroll',
      () async {
    await inbox.requestBackfill('a', now);
    await dispatcher(scroll: (_, d) async {
      if (d < 0) throw PlatformException(code: 'customer_changed');
    }).runOnePage();
    expect(await inbox.restoreCutoffs(), {'a': now.millisecondsSinceEpoch});
    events.clear();
    now = now.add(const Duration(seconds: 11));
    await dispatcher().runOnePage();
    expect(events.where((e) => e.startsWith('scroll:')).first, 'scroll:-10000');
  });
  test('priority arriving while queued prevents opening and scrolling',
      () async {
    await inbox.requestBackfill('a', now);
    var allowed = true;
    await dispatcher(
        canRun: () => allowed,
        withUi: (work) async {
          allowed = false;
          await work();
        }).runOnePage();
    expect(events.where((e) => e.startsWith('open:')), isEmpty);
    expect((await inbox.pendingBackfills()).single['pages'], 0);
  });
  test('a burst scrolls incrementally, restores once and yields between pages',
      () async {
    await inbox.requestBackfill('a', now, stepPixels: 100);
    var allowed = true;
    var captured = 0;
    final run = dispatcher(
      burstPages: 3,
      canRun: () => allowed,
      capture: (_, cutoff) async {
        events.add('capture');
        if (++captured == 2) allowed = false;
        return save('burst-$captured', cutoff);
      },
    );
    await run.runOnePage();
    expect(events.where((e) => e.startsWith('scroll:') || e == 'capture'),
        ['scroll:100', 'capture', 'scroll:100', 'capture', 'scroll:-10000']);
    expect((await inbox.pendingBackfills()).single['pages'], 2);

    allowed = true;
    events.clear();
    await run.runOnePage();
    expect(events.where((e) => e.startsWith('scroll:') || e == 'capture'),
        ['scroll:300', 'capture', 'scroll:-10000']);
  });

  test('a confirmed boundary stops the burst before it scrolls again',
      () async {
    await inbox.requestBackfill('a', now, stepPixels: 100);
    await dispatcher(
      burstPages: 3,
      capture: (_, cutoff) async {
        events.add('capture');
        final frame = await save('covered-on-first', cutoff);
        await inbox.covered('a', cutoff: cutoff);
        return frame;
      },
    ).runOnePage();
    expect(events.where((e) => e.startsWith('scroll:') || e == 'capture'),
        ['scroll:100', 'capture', 'scroll:-10000']);
    expect(await inbox.coverageState('a'), 'covered');
  });

  test('old OCR cannot mark a newer turn covered or consume its page budget',
      () async {
    await inbox.requestBackfill('a', now);
    await inbox.requestBackfill('a', now.add(const Duration(seconds: 10)));
    await inbox.covered('a', cutoff: now);
    await inbox.backfillAttempt('a', cutoff: now);
    expect((await inbox.pendingBackfills()).single['pages'], 0);
    expect(await inbox.coverageState('a'), 'pending');
  });
  const region =
      OcrVisualRegion(x: .2, y: .3, width: .1, height: .2, confidence: 1);
  test(
      'blank/preview observations are partial, durable and exempt from processed-frame pruning',
      () async {
    final frame = await save('partial');
    final id = await audit.discover(frame, region);
    await audit
        .finish(id, 'video_preview_only', {'reason': 'original_not_verified'});
    expect(await audit.unresolvedCount(frame.id), 1);
    await inbox.complete(frame, partial: true);
    await inbox.pruneProcessed(keep: 0);
    expect(await frame.filesExist(), isTrue);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    audit = MediaCaptureAudit(db);
    expect(await audit.unresolvedCount(frame.id), 1);
    final row = (await (await db.database).query('media_capture_audit')).single;
    final details = jsonDecode(row['details']! as String) as Map;
    expect(details['platformMessageId'], isNull);
    expect(details['analysisComplete'], isFalse);
    expect(details['captureResolved'], isFalse);
  });
  test(
      'media candidates in a burst retain separate outcomes and immutable evidence IDs',
      () async {
    final frame = await save('burst');
    final first = await audit.discover(frame, region);
    final second = await audit.discover(
        frame,
        const OcrVisualRegion(
            x: .2, y: .6, width: .1, height: .2, confidence: 1));
    expect(first, isNot(second));
    await audit.finish(first, 'image_saved', {'contentSha256': 'image-a'});
    await audit.finish(second, 'failed', {'errorCode': 'crop_failed'});
    expect(await audit.unresolvedCount(frame.id), 1);
    expect(events, contains('media.observation_finished:failed'));
  });
  test('same saved frame media retry has a durable three-attempt cap',
      () async {
    final frame = await save('retry');
    for (var i = 0; i < 3; i++) {
      await inbox.complete(frame, partial: true);
      expect(await inbox.retryMedia(frame.id), isTrue);
    }
    await inbox.complete(frame, partial: true);
    expect(await inbox.retryMedia(frame.id), isFalse);
  });
  test('a media-only gap can reopen covered pages without resetting the cap',
      () async {
    await inbox.requestBackfill('a', now);
    await inbox.backfillAttempt('a');
    await inbox.covered('a');
    await inbox.requestBackfill('a', now, reopenCovered: true);
    expect((await inbox.pendingBackfills()).single['pages'], 1);
    await inbox.backfillAttempt('a');
    await inbox.backfillAttempt('a');
    await inbox.covered('a');
    await inbox.requestBackfill('a', now, reopenCovered: true);
    expect(await inbox.pendingBackfills(), isEmpty);
  });
  test('a covered last page still restores bottom after a failed restore',
      () async {
    await inbox.requestBackfill('a', now);
    await inbox.covered('a');
    await inbox.setRestore('a', true);
    await dispatcher().runOnePage();
    expect(events.where((e) => e.startsWith('scroll:')), ['scroll:-10000']);
    expect(events, isNot(contains('capture')));
    expect(await inbox.restoreCutoffs(), isEmpty);
  });
  test(
      'model play hint stays unresolved during offline image reuse and protects raw frames',
      () async {
    final frame = await save('model-hint');
    final id = await audit.discover(frame, region);
    final bytes = await File(frame.imagePath).readAsBytes();
    // Derive a real file digest without logging its image content.
    await audit.finish(id, 'image_saved', {'contentSha256': 'unused'});
    final database = await db.database;
    final row = (await database.query('media_capture_audit')).single;
    final details =
        jsonDecode(row['details']! as String) as Map<String, dynamic>;
    // noteVideoHint hashes the saved media; use the same SHA-256 in the ledger.
    details['contentSha256'] = sha256.convert(bytes).toString();
    await database
        .update('media_capture_audit', {'details': jsonEncode(details)});
    await inbox.complete(frame);
    expect(await audit.noteVideoHint('a', frame.imagePath), {frame.id});
    await inbox.pruneProcessed(keep: 0);
    expect(await frame.filesExist(), isTrue);
    await audit.discover(frame, region);
    await audit.finish(id, 'reused', {'reason': 'existing_screenshot'});
    expect(await audit.unresolvedCount(frame.id), 1);
    await audit.finish(id, 'video_frames_saved', {'frameCount': 3});
    expect(await audit.unresolvedCount(frame.id), 0);
  });
  test(
      'v16 backfill migration preserves pending work and adds retry protection',
      () async {
    await inbox.requestBackfill('a', now, stepPixels: 312);
    final old = await db.database;
    await old.execute('ALTER TABLE capture_backfill DROP COLUMN retry_at_ms');
    await old.execute('ALTER TABLE capture_backfill DROP COLUMN failures');
    await old.execute('PRAGMA user_version=16');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    inbox = CaptureEvidenceStore(db, now: () => now);
    final job = (await inbox.pendingBackfills()).single;
    expect(job['cutoff_ms'], now.millisecondsSinceEpoch);
    expect(job['step_pixels'], 312);
    expect(job['retry_at_ms'], 0);
    await inbox.deferBackfill('a');
    expect(await inbox.pendingBackfills(), isEmpty);
    now = now.add(const Duration(seconds: 11));
    expect((await inbox.pendingBackfills()).length, 1);
  });
  test(
      'partly offscreen images stay unresolved and request the bounded backfill path',
      () async {
    expect(
        EvidenceCoverage.mediaTouchesViewport(
            top: .2, bottom: .8, viewportTop: .2, viewportBottom: .8),
        isTrue);
    expect(
        EvidenceCoverage.mediaTouchesViewport(
            top: .3, bottom: .81, viewportTop: .2, viewportBottom: .8),
        isTrue);
    expect(
        EvidenceCoverage.mediaTouchesViewport(
            top: .3, bottom: .7, viewportTop: .2, viewportBottom: .8),
        isFalse);
    final frame = await save('partial-image');
    final id = await audit.discover(frame, region);
    await audit.finish(id, 'image_partial', {'touchesViewportEdge': true});
    expect(await audit.unresolvedCount(frame.id), 1);
  });
  test('late original wins over completion of an older processing snapshot',
      () async {
    final frame = await save('late-pin-race');
    final claimed = await inbox.claim();
    await inbox.pin(
        frame.withPinnedMedia({'kind': 'image', 'evidenceFile': 'original'}));
    await inbox.complete(claimed!);
    final next = await inbox.claim();
    expect(next!.id, frame.id);
    expect(next.pinnedMedia!['kind'], 'image');
    await inbox.complete(next);
    expect(await inbox.claim(), isNull);
  });
  test(
      'original arriving after a processed screenshot queues itself immediately',
      () async {
    final frame = await save('late-pin-processed');
    await inbox.complete(frame);
    await inbox.pin(
        frame.withPinnedMedia({'kind': 'image', 'evidenceFile': 'original'}));
    expect((await inbox.claim())!.pinnedMedia!['kind'], 'image');
  });
}
