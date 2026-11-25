import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/capture_coordinator.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

class _SessionAdapter implements CaptureAdapter {
  final events = StreamController<CapturedConversation>.broadcast(sync: true);
  @override
  Stream<CapturedConversation> get captures => events.stream;
  @override
  Stream<Map<String, Object?>> get diagnostics => const Stream.empty();
  @override
  Future<Map<String, Object?>> status() async => {'trusted': true};
  @override
  Future<bool> requestAccessibility() async => true;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<Map<String, Object?>> inspectTree({int maxDepth = 12}) async => {};
}

void main() {
  late Directory root;
  late Directory frames;
  late CaptureDatabase db;
  late CaptureEvidenceStore inbox;
  late DateTime at;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_capture_session_');
    frames = await Directory('${root.path}/capture_evidence').create();
    db = CaptureDatabase(storageRoot: root);
    at = DateTime.utc(2026, 11, 4, 10, 10);
    inbox = CaptureEvidenceStore(db, now: () => at);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<ViewportEvidence> frame(String id,
      {String customer = 'buyer', int seconds = 0, String? session}) async {
    final png = File('${frames.path}/$id.png');
    final manifest = File('${frames.path}/$id.json');
    await png.writeAsBytes([1, 2, 3]);
    final value = <String, Object?>{
      'evidenceId': id,
      'customer': customer,
      'imagePath': png.path,
      'manifestPath': manifest.path,
      'capturedAtMs': at.add(Duration(seconds: seconds)).millisecondsSinceEpoch,
      if (session != null) 'automationSessionId': session
    };
    await manifest.writeAsString(jsonEncode(value));
    return ViewportEvidence(value);
  }

  Future<Map<String, Object?>> row(String id) async =>
      (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;

  CapturedConversation streamCapture(String customer, String? session,
          {int seconds = 1}) =>
      CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          capturedAt: at.add(Duration(seconds: seconds)),
          automationSessionId: session,
          messages: [
            CapturedMessage(
                stableId: '$customer-question',
                direction: 'incoming',
                body: 'Question for $customer',
                sentAt: at.add(Duration(seconds: seconds)),
                axPath: 'AX fixture')
          ]);

  test(
      'new session archives old partial work, observations, backfill and unresolved media audit',
      () async {
    final partial = await frame('old-partial', seconds: -20);
    final retry = await frame('old-retry', customer: 'another', seconds: -15);
    await inbox.observe('buyer', at.subtract(const Duration(seconds: 22)));
    await inbox.record(partial);
    await inbox.complete(partial, partial: true);
    await inbox.observe('another', at.subtract(const Duration(seconds: 16)));
    await inbox.record(retry);
    await inbox.fail(retry, StateError('old OCR failure'));
    await inbox.requestBackfill(
        'buyer', at.subtract(const Duration(minutes: 1)));
    await inbox.setRestore('buyer', true);
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'old-audit',
      'evidence_id': partial.id,
      'customer': 'buyer',
      'state': 'video_preview_only',
      'details': '{"originalRetrieved":false}',
      'updated_at_ms': at.millisecondsSinceEpoch
    });
    await inbox.beginSession(sessionId: 'new', startedAt: at);
    expect((await row(partial.id))['state'], 'session_archived');
    expect((await row(retry.id))['state'], 'session_archived');
    expect(await inbox.claim(), isNull);
    expect(await inbox.retryMedia(partial.id), isFalse);
    expect(await inbox.awaitingFrameCustomers(), isEmpty);
    expect(await inbox.pendingBackfills(), isEmpty);
    expect(await inbox.dueRestorations(), isEmpty);
    expect(await inbox.firstObserved('buyer'), isNull);
    final archived = await (await db.database).query('capture_session_archive',
        where: 'session_id=?', whereArgs: ['new']);
    expect(
        archived.map((r) => r['table_name']).toSet(),
        containsAll([
          'capture_evidence',
          'capture_observations',
          'capture_backfill',
          'media_capture_audit'
        ]));
    expect(
        archived.any((r) =>
            r['row_key'] == partial.id &&
            (jsonDecode(r['payload']! as String) as Map)['state'] == 'partial'),
        isTrue);
    expect(await partial.filesExist(), isTrue);
  });
  test(
      'current timestamp is insufficient when a late native callback carries an old or missing session tag',
      () async {
    await inbox.beginSession(sessionId: 'current', startedAt: at);
    final wrongTag =
        await frame('late-native', seconds: 4, session: 'previous');
    final missingTag = await frame('untagged-native', seconds: 5);
    final stalePixels =
        await frame('old-pixels', seconds: -1, session: 'current');
    for (final old in [wrongTag, missingTag, stalePixels]) {
      expect(inbox.isCurrent(old), isFalse);
      expect(await inbox.record(old), isFalse);
    }
    expect(await (await db.database).query('capture_evidence'), isEmpty);
    expect(await inbox.claim(), isNull);
    final fresh = await frame('fresh', seconds: 6, session: 'current');
    expect(inbox.isCurrent(fresh), isTrue);
    expect(await inbox.record(fresh), isTrue);
    final freshClaim = (await inbox.claim())!;
    expect(freshClaim.id, fresh.id);
    await inbox.complete((await inbox.refreshClaim(freshClaim))!);
    expect((await row(fresh.id))['state'], 'processed');
  });
  test(
      'old complete pin and fail cannot overwrite a new run observation or processing row',
      () async {
    await inbox.beginSession(sessionId: 'old', startedAt: at);
    final old = await frame('old-worker', session: 'old', seconds: 1);
    await inbox.observe('buyer', old.capturedAt);
    await inbox.record(old);
    final oldClaim = (await inbox.claim())!;
    expect(oldClaim.id, old.id);
    at = at.add(const Duration(seconds: 10));
    await inbox.beginSession(sessionId: 'new', startedAt: at);
    final fresh = await frame('new-worker', session: 'new', seconds: 1);
    await inbox.observe('buyer', fresh.capturedAt);
    await inbox.record(fresh);
    final freshClaim = (await inbox.claim())!;
    expect(freshClaim.id, fresh.id);
    final oldPinned = oldClaim.withPinnedMedia({
      'kind': 'image',
      'evidenceFile': old.imagePath,
      'cacheKey': 'old-cache'
    });
    await inbox.complete(oldClaim);
    await inbox.pin(oldPinned);
    await inbox.fail(oldClaim, StateError('late worker'));
    expect((await row(old.id))['state'], 'session_archived');
    expect((await row(old.id))['attempts'], 0);
    expect((await row(fresh.id))['state'], 'processing');
    expect((await inbox.lookup(fresh.id))!.pinnedMedia, isNull);
    expect(await inbox.firstObserved('buyer'), fresh.capturedAt);
    await inbox.complete((await inbox.refreshClaim(freshClaim))!);
    expect((await row(fresh.id))['state'], 'processed');
    final observation = (await (await db.database).query('capture_observations',
            where: 'customer=?', whereArgs: ['buyer']))
        .single;
    expect(observation['state'], 'processed',
        reason:
            'Archived frames cannot keep a current observation artificially unfinished');
  });
  test('a late old media hint cannot requeue a previously processed frame',
      () async {
    final old = await frame('old-processed', seconds: -3);
    await inbox.record(old);
    await inbox.complete(old);
    await inbox.beginSession(sessionId: 'new', startedAt: at);
    expect(await inbox.retryMedia(old.id, background: true), isFalse);
    expect((await row(old.id))['state'], 'processed');
    expect(await inbox.claim(), isNull);
  });
  test(
      'old manifests and interrupted workers cannot be resurrected by disk recovery in a new run',
      () async {
    final old = await frame('on-disk-old', seconds: -5);
    await inbox.record(old);
    await inbox.claim();
    await frame('orphan-old', seconds: -4);
    await inbox.beginSession(sessionId: 'new', startedAt: at);
    await inbox.recover(frames);
    expect(await inbox.claim(), isNull);
    expect(await inbox.lookup('orphan-old'), isNull);
    expect((await row(old.id))['state'], 'session_archived');
    expect(await File(old.manifestPath).exists(), isTrue);
  });
  test(
      'a stale queued raw callback is quarantined and cannot starve the next current frame',
      () async {
    await inbox.beginSession(sessionId: 'new', startedAt: at);
    final old = await frame('old-injected', session: 'old', seconds: 1);
    await (await db.database).insert('capture_evidence', {
      'id': old.id,
      'customer': old.customer,
      'captured_at_ms': old.capturedAt.millisecondsSinceEpoch,
      'payload': old.toJson(),
      'state': 'captured',
      'attempts': 0,
      'retry_at_ms': 0
    });
    final fresh = await frame('fresh-behind-old', session: 'new', seconds: 2);
    await inbox.record(fresh);
    final first = await inbox.claim();
    final current = first ?? await inbox.claim();
    expect(current?.id, fresh.id);
    expect((await row(old.id))['state'], 'session_archived');
  });

  test(
      'coordinator rejects unscoped and late old stream callbacks even if their timestamps are fresh',
      () async {
    final adapter = _SessionAdapter();
    final coordinator = CaptureCoordinator(adapter, db);
    await coordinator.beginSession(sessionId: 'current', startedAt: at);
    await coordinator.start();
    final saved = coordinator.updates
        .firstWhere((rows) => rows.any((r) => r.userId == 'current-user'));
    adapter.events.add(streamCapture('late-old-user', 'previous'));
    adapter.events.add(streamCapture('unscoped-user', null));
    adapter.events.add(streamCapture('old-pixels', 'current', seconds: -1));
    adapter.events.add(streamCapture('current-user', 'current'));
    await saved.timeout(const Duration(seconds: 5));
    expect((await db.conversations()).map((r) => r.userId), ['current-user']);
    expect(await (await db.history).read('late-old-user'), isNull);
    expect(await (await db.history).read('unscoped-user'), isNull);
    await coordinator.stop();
    await adapter.events.close();
  });
  test(
      'queued writes from an old coordinator epoch are discarded before a new run',
      () async {
    final adapter = _SessionAdapter();
    final coordinator = CaptureCoordinator(adapter, db);
    await coordinator.beginSession(sessionId: 'old', startedAt: at);
    await coordinator.start();
    adapter.events.add(streamCapture('queued-old-a', 'old'));
    adapter.events.add(streamCapture('queued-old-b', 'old'));
    // Begin synchronously changes the owner before the queued persistence
    // futures execute. The fresh lane must not wait behind their old work.
    await coordinator.beginSession(sessionId: 'new', startedAt: at);
    final saved = coordinator.updates
        .firstWhere((rows) => rows.any((r) => r.userId == 'fresh-lane'));
    adapter.events.add(streamCapture('fresh-lane', 'new'));
    await saved.timeout(const Duration(seconds: 5));
    expect((await db.conversations()).map((r) => r.userId), ['fresh-lane']);
    expect(await (await db.history).read('queued-old-a'), isNull);
    expect(await (await db.history).read('queued-old-b'), isNull);
    await coordinator.stop();
    await adapter.events.close();
  });
  test(
      'captured conversation preserves the request session tag instead of inferring the receiver run',
      () {
    final capture = CapturedConversation.fromMap({
      'stableKey': 'tagged',
      'customerName': 'tagged',
      'customerExternalId': 'tagged',
      'automationSessionId': 'request-owner',
      'capturedAtMs': at.millisecondsSinceEpoch,
      'messages': []
    });
    expect(capture.automationSessionId, 'request-owner');
  });
}
