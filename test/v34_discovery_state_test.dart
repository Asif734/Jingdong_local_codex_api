import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase database;
  late CaptureEvidenceStore store;
  late String session;
  late DateTime now;
  final started = DateTime.utc(2026, 11, 5, 10);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v34_discovery_');
    database = CaptureDatabase(storageRoot: root);
    now = started.add(const Duration(seconds: 1));
    session = await database.beginAutomationSession(startedAt: started);
    store = CaptureEvidenceStore(database, now: () => now);
    await store.beginSession(sessionId: session, startedAt: started);
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id,
      {String customer = 'buyer', int second = 1, String? owner}) async {
    final png = await File('${root.path}/$id.png').writeAsBytes([1, 2, 3]);
    final manifest = File('${root.path}/$id.json');
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': customer,
      'imagePath': png.path,
      'manifestPath': manifest.path,
      'capturedAtMs':
          started.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'automationSessionId': owner ?? session,
    });
    await manifest.writeAsString(evidence.toJson());
    return evidence;
  }

  Future<DiscoveryCaptureResult> admit(ViewportEvidence evidence,
          {bool live = false,
          bool pending = false,
          bool acquisition = false}) =>
      store.discoveryCapture(evidence,
          hasLiveWork: live, hasPendingWork: pending, acquisition: acquisition);

  Future<Map<String, Object?>> state(String id) async =>
      (await (await database.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;

  Future<ViewportEvidence> claim(String id) async {
    final leased = (await store.claim())!;
    expect(leased.id, id);
    final current = await store.refreshClaim(leased);
    expect(current, isNotNull);
    return current!;
  }

  Future<void> baseline(ViewportEvidence evidence,
      {List<CapturedMessage> messages = const []}) async {
    expect(evidence.metadata['captureClaimToken'], isNotNull,
        reason: 'Baseline completion must carry its real extraction lease');
    await database.saveCapture(
        CapturedConversation(
            stableKey: evidence.customer,
            customerName: evidence.customer,
            customerExternalId: evidence.customer,
            automationSessionId: session,
            capturedAt: evidence.capturedAt,
            messages: messages),
        activateReplies: false);
    expect(
        await database.registerDiscoveryBaseline(
            evidence.customer, messages.map((m) => m.stableId),
            evidenceId: evidence.id, expectedSessionId: session),
        isTrue);
    await store.complete(evidence);
  }

  CapturedMessage question(String id, {String? observationKey}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          body: 'Question $id',
          sentAt: started.subtract(const Duration(hours: 2)),
          axPath: 'controlled immutable frame',
          observationTurnKey: observationKey);

  test('first passive frame is one durable baseline; later frame waits',
      () async {
    final first = await admit(await frame('first'));
    final later = await admit(await frame('later', second: 2));
    expect(first.evidence.metadata['capturePurpose'], 'discovery_baseline');
    expect(first.evidence.metadata['replyActivationAllowed'], isFalse);
    expect(later.evidence.metadata['capturePurpose'], 'active_discovery');
    expect(later.evidence.metadata['replyActivationAllowed'], isTrue);
    expect(later.evidence.metadata['discoveryAnchorId'], first.evidence.id);
    final firstClaim = await claim(first.evidence.id);
    expect(await store.claim(), isNull);
    await store.complete(firstClaim);
    expect((await state(first.evidence.id))['state'], 'processing',
        reason:
            'Merely calling complete cannot claim baseline registration succeeded');
    await baseline(firstClaim);
    expect((await store.claim())?.id, later.evidence.id);
  });

  test('concurrent passive captures reserve one first immutable baseline',
      () async {
    final frames = await Future.wait(
        [frame('a'), frame('b', second: 2), frame('c', second: 3)]);
    final admitted = await Future.wait(frames.map(admit));
    final baselineFrame = admitted
        .singleWhere((r) =>
            r.evidence.metadata['capturePurpose'] == 'discovery_baseline')
        .evidence;
    expect((await (await database.database).query('capture_discovery_state')),
        hasLength(1));
    final baselineClaim = await claim(baselineFrame.id);
    expect(await store.claim(), isNull);
    await baseline(baselineClaim);
    expect(await store.claim(), isNotNull);
  });

  test(
      'unknown old IDs and canonical aliases stay excluded after live reread and repair',
      () async {
    final first = (await admit(await frame('first'))).evidence;
    final firstClaim = await claim(first.id);
    final old = question('old-question', observationKey: 'ocr-bubble:same');
    await baseline(firstClaim, messages: [old]);
    final next = (await admit(await frame('later', second: 2))).evidence;
    final oldAlias =
        question('old-observation-alias', observationKey: 'ocr-bubble:same');
    await database.saveCapture(CapturedConversation(
      stableKey: 'buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      automationSessionId: session,
      capturedAt: next.capturedAt,
      messages: [oldAlias, question('new-question')],
    ));
    await database.repairSessionPendingWork('buyer');
    expect((await database.processingMessages('buyer')).map((m) => m['id']),
        ['new-question']);
    expect(await database.isCurrentSessionMessage('buyer', 'old-question'),
        isFalse);
    expect(
        await database.isCurrentSessionMessage(
            'buyer', 'old-observation-alias'),
        isFalse);
    expect(await database.isMessageFormallyAnswered('buyer', 'old-question'),
        isFalse);
  });

  test(
      'baseline cannot absorb an input already positively captured as current live work',
      () async {
    final first = (await admit(await frame('baseline'))).evidence;
    final firstClaim = await claim(first.id);
    await database.saveCapture(CapturedConversation(
      stableKey: 'buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      automationSessionId: session,
      capturedAt: first.capturedAt,
      messages: [question('live-race')],
    ));
    await baseline(firstClaim, messages: [question('live-race')]);
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
    expect(await database.pendingMessageId('buyer'), 'live-race');
  });

  test('successful current live frame is already a discovery anchor', () async {
    final old = await frame('live');
    final live = ViewportEvidence({
      ...old.metadata,
      'capturePurpose': 'live_signal',
      'replyActivationAllowed': true
    });
    await store.record(live);
    await store.complete((await store.claim())!);
    final next = await admit(await frame('new-video', second: 2));
    expect(next.evidence.metadata['capturePurpose'], 'active_discovery');
    expect((await store.claim())?.id, next.evidence.id);
    final anchor =
        (await (await database.database).query('capture_discovery_state'))
            .single;
    expect(anchor['ready'], 1);
    expect(anchor['evidence_id'], live.id);
  });

  test('first live frame does not baseline a legitimate current message',
      () async {
    final live = await admit(await frame('live'), live: true);
    expect(live.evidence.metadata['capturePurpose'], 'live_signal');
    expect(live.evidence.metadata['replyActivationAllowed'], isTrue);
    final next = await admit(await frame('passive-after-live', second: 2));
    final liveClaim = await claim(live.evidence.id);
    expect(await store.claim(), isNull);
    await store.complete(liveClaim);
    expect((await store.claim())?.id, next.evidence.id);
  });

  test(
      'baseline OCR failures remain retryable without blocking another customer',
      () async {
    final first = (await admit(await frame('failed-baseline'))).evidence;
    await admit(await frame('newer-buyer', second: 2));
    final other = await admit(
        await frame('another', customer: 'another', second: 3),
        live: true);
    for (var attempt = 0; attempt < 5; attempt++) {
      final failedClaim = await claim(first.id);
      await store.fail(failedClaim, StateError('temporary OCR failure'));
      expect((await state(first.id))['state'], 'retry');
      if (attempt == 0) {
        await store.complete(await claim(other.evidence.id));
      }
      expect(await store.claim(), isNull);
      now = now.add(const Duration(seconds: 6));
    }
    await baseline(await claim(first.id));
    expect((await store.claim())?.id, 'newer-buyer');
  });

  test(
      'new AX-red work bypasses a failed baseline and becomes the successful anchor',
      () async {
    final first = (await admit(await frame('bad-baseline'))).evidence;
    final firstClaim = await claim(first.id);
    await store.fail(firstClaim, StateError('bad initial frame'));
    final passive = (await admit(await frame('passive', second: 2))).evidence;
    final positive =
        await admit(await frame('real-red', second: 3), live: true);
    final positiveClaim = (await store.claim())!;
    expect(positiveClaim.id, positive.evidence.id,
        reason:
            'An initial passive failure cannot block real current business');
    await store.complete((await store.refreshClaim(positiveClaim))!);
    expect((await state(first.id))['state'], 'processed');
    expect((await store.claim())?.id, passive.id);
    expect(
        await database.registerDiscoveryBaseline('buyer', const [],
            evidenceId: first.id, expectedSessionId: session),
        isFalse);
  });

  test(
      'a red signal upgrades the same pending passive frame without stale callbacks',
      () async {
    final first = (await admit(await frame('same-frame'))).evidence;
    final firstClaim = await claim(first.id);
    final positive = await admit(first, live: true);
    expect(positive.inserted, isTrue);
    expect(positive.evidence.metadata['capturePurpose'], 'live_signal');
    final current = (await store.refreshClaim(firstClaim))!;
    expect(current.metadata['captureClaimToken'],
        firstClaim.metadata['captureClaimToken']);
    await store.complete(firstClaim);
    await store.fail(firstClaim, StateError('stale baseline callback'));
    await store.pin(
        firstClaim.withPinnedMedia({'kind': 'image', 'cacheKey': 'stale'}));
    expect(
        await database.registerDiscoveryBaseline('buyer', const [],
            evidenceId: first.id, expectedSessionId: session),
        isFalse);
    expect((await state(first.id))['state'], 'processing',
        reason:
            'Promotion updates activation without reopening an owned extraction');
    expect((await store.lookup(first.id))!.pinnedMedia, isNull);
    expect(await store.claim(), isNull,
        reason:
            'General/live lanes cannot claim the same promoted pixels twice');
    expect(current.metadata['capturePurpose'], 'live_signal');
    await store.complete(current);
    final later = await admit(await frame('later', second: 2));
    expect((await store.claim())?.id, later.evidence.id);
  });

  test(
      'late callbacks cannot resurrect a baseline superseded by another live frame',
      () async {
    final old = (await admit(await frame('superseded-baseline'))).evidence;
    final oldClaim = await claim(old.id);
    await store.fail(oldClaim, StateError('initial OCR failed'));
    final live =
        (await admit(await frame('verified-live', second: 2), live: true))
            .evidence;
    await store.complete(await claim(live.id));
    await store.fail(oldClaim, StateError('late failure'));
    await store
        .pin(oldClaim.withPinnedMedia({'kind': 'image', 'cacheKey': 'late'}));
    await store.complete(oldClaim);
    expect((await state(old.id))['state'], 'processed');
    expect((await store.lookup(old.id))!.pinnedMedia, isNull);
    // Recovery can expose an obsolete row again, but only its newly claimed
    // owner may retire it; an old callback cannot manufacture that authority.
    await (await database.database).update(
        'capture_evidence', {'state': 'captured'},
        where: 'id=?', whereArgs: [old.id]);
    await store.complete(await claim(old.id));
    expect((await state(old.id))['state'], 'processed');
    final next =
        (await admit(await frame('next-discovery', second: 3))).evidence;
    expect((await store.claim())?.id, next.id);
  });

  test('history backfill without current work never activates historical input',
      () async {
    final original = await frame('history');
    final history = ViewportEvidence({
      ...original.metadata,
      'historyCutoffMs': started.millisecondsSinceEpoch
    });
    final result = await admit(history);
    expect(result.evidence.metadata['capturePurpose'], 'history_backfill');
    expect(result.evidence.metadata['replyActivationAllowed'], isFalse);
    expect(await (await database.database).query('capture_discovery_state'),
        isEmpty);
    final rescue = await admit(
        ViewportEvidence({...history.metadata, 'evidenceId': 'history-rescue'}),
        pending: true);
    expect(rescue.evidence.metadata['replyActivationAllowed'], isTrue);
  });

  test('repeated completed active content is not extracted or queued again',
      () async {
    final live = await admit(await frame('stable'), live: true);
    await store.complete((await store.claim())!);
    final repeat = await admit(live.evidence);
    expect(repeat.inserted, isFalse);
    expect(await store.claim(), isNull);
  });

  test(
      'a failing passive discovery remains durable without blocking newer valid frames',
      () async {
    final anchor =
        (await admit(await frame('observed-live'), live: true)).evidence;
    await store.complete((await store.claim())!);
    final failing =
        (await admit(await frame('bad-discovery', second: 2))).evidence;
    await store.fail(
        await claim(failing.id), StateError('unreadable saved frame'));
    expect((await state(failing.id))['state'], 'media_retry');
    final valid =
        (await admit(await frame('good-discovery', second: 3))).evidence;
    final other = (await admit(
            await frame('other-customer', customer: 'another', second: 4),
            live: true))
        .evidence;
    final validClaim = await claim(valid.id);
    final otherClaim = await claim(other.id);
    await store.complete(validClaim);
    await store.complete(otherClaim);
    for (var attempt = 0; attempt < 4; attempt++) {
      now = now.add(const Duration(seconds: 6));
      final failedClaim = await claim(failing.id);
      expect(await store.claim(), isNull,
          reason: 'One failed frame has only one processing owner');
      await store.fail(failedClaim, StateError('still unreadable'));
    }
    final row = await state(failing.id);
    expect(row['attempts'], 5);
    expect(row['state'], 'media_retry');
    expect(await File(failing.imagePath).exists(), isTrue);
    final newest =
        (await admit(await frame('latest-valid', second: 20))).evidence;
    expect((await store.claim())?.id, newest.id);
    expect(anchor.id, 'observed-live');
  });

  test(
      'unfinished acquisition of the same pixels retries with one owner and backoff',
      () async {
    final live = await admit(await frame('unchanged-card'), live: true);
    await store.complete((await store.claim())!);
    final acquired = await admit(live.evidence, acquisition: true);
    expect(acquired.inserted, isTrue);
    expect(acquired.evidence.metadata['capturePurpose'], 'media_acquisition');
    final work = (await store.claim())!;
    expect((await admit(live.evidence, acquisition: true)).inserted, isFalse,
        reason:
            'A running acquisition cannot be restarted by a periodic capture');
    await store.complete(work, partial: true);
    expect((await admit(live.evidence, acquisition: true)).inserted, isFalse);
    now = now.add(const Duration(seconds: 6));
    expect((await admit(live.evidence, acquisition: true)).inserted, isTrue);
    expect((await store.claim())?.id, live.evidence.id);
  });

  test(
      'optional media acquisition failure cannot block a newer customer question',
      () async {
    final live = (await admit(await frame('known-media'), live: true)).evidence;
    await store.complete((await store.claim())!);
    final acquisition = (await admit(live, acquisition: true)).evidence;
    await store.fail(await claim(acquisition.id),
        StateError('optional original unavailable'));
    expect((await state(acquisition.id))['state'], 'media_retry');
    final newer =
        (await admit(await frame('new-question', second: 2), live: true))
            .evidence;
    await store.complete(await claim(newer.id));
    final passive =
        (await admit(await frame('another-question', second: 3))).evidence;
    await store.complete(await claim(passive.id));
    now = now.add(const Duration(seconds: 6));
    expect((await store.claim())?.id, acquisition.id);
    expect(await File(acquisition.imagePath).exists(), isTrue);
  });

  test(
      'skipped history frame promotes into discovery once, stale callback cannot finish it',
      () async {
    final first = (await admit(await frame('anchor'), live: true)).evidence;
    await store.complete((await store.claim())!);
    final raw = await frame('missed-video', second: 2);
    final skipped = ViewportEvidence({
      ...raw.metadata,
      'replyActivationAllowed': false,
      'capturePurpose': 'history_only'
    });
    await store.record(skipped);
    final skippedClaim = await claim(skipped.id);
    await store.complete(skippedClaim);
    final admission = await admit(raw);
    expect(admission.inserted, isTrue);
    expect(admission.evidence.metadata['capturePurpose'], 'active_discovery');
    await store.complete(skippedClaim);
    await store.fail(skippedClaim, StateError('late old callback'));
    expect((await state(raw.id))['state'], 'captured');
    await store.complete(await claim(raw.id));
    expect((await admit(raw)).inserted, isFalse);
    expect(first.id, 'anchor');
  });

  test('a pending reservation cannot be registered with another frame or run',
      () async {
    final first = (await admit(await frame('baseline'))).evidence;
    expect(
        await database.registerDiscoveryBaseline('buyer', const [],
            evidenceId: 'other-frame', expectedSessionId: session),
        isFalse);
    expect(
        await database.registerDiscoveryBaseline('buyer', const [],
            evidenceId: first.id, expectedSessionId: 'old-run'),
        isFalse);
    final before = session;
    session = await database.beginAutomationSession(
        startedAt: started.add(const Duration(minutes: 1)));
    await store.beginSession(
        sessionId: session, startedAt: started.add(const Duration(minutes: 1)));
    expect((await admit(first)).inserted, isFalse);
    expect(
        await database.registerDiscoveryBaseline('buyer', const [],
            evidenceId: first.id, expectedSessionId: before),
        isFalse);
    expect(await store.claim(), isNull);
  });

  test(
      'schema migration preserves receipt data and creates discovery reservations',
      () async {
    final sql = await database.database;
    await sql.execute('DROP TABLE capture_discovery_state');
    await sql.execute('PRAGMA user_version=31');
    await database.close();
    database = CaptureDatabase(storageRoot: root);
    final reopened = await database.database;
    expect(
        (await reopened.rawQuery('PRAGMA user_version')).single['user_version'],
        CaptureDatabase.databaseSchemaVersion);
    expect(await reopened.query('capture_discovery_state'), isEmpty);
    expect(await reopened.query('automation_sessions'), hasLength(1));
  });
}
