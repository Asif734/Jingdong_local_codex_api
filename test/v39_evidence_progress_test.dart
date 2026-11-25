import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore store;
  late String session;
  final now = DateTime.utc(2026, 11, 8, 7, 40);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v39_evidence_');
    db = CaptureDatabase(storageRoot: root);
    session = await db.beginAutomationSession(
        startedAt: now.subtract(const Duration(minutes: 4)));
    store = CaptureEvidenceStore(db, now: () => now);
    await store.beginSession(
        sessionId: session,
        startedAt: now.subtract(const Duration(minutes: 4)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id,
      {int second = 0, Map<String, Object?> metadata = const {}}) async {
    final image = await File('${root.path}/$id.png').writeAsBytes([1, 2, 3]);
    final manifest = File('${root.path}/$id.json');
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': 'buyer',
      'capturedAtMs': now.add(Duration(seconds: second)).millisecondsSinceEpoch,
      'automationSessionId': session,
      'imagePath': image.path,
      'manifestPath': manifest.path,
      'replyActivationAllowed': true,
      'capturePurpose': 'live_signal',
      ...metadata,
    });
    await manifest.writeAsString(evidence.toJson());
    return evidence;
  }

  Future<void> input(String id,
      {DateTime? at,
      String? evidence,
      bool activate = true,
      DateTime? senderAt}) async {
    await db.saveCapture(
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            capturedAt: at ?? now,
            automationSessionId: session,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: 'Question $id',
                  sender: 'buyer',
                  sentAt: senderAt ?? at ?? now,
                  captureEvidenceId: evidence,
                  axPath: 'controlled actual incoming')
            ]),
        activateReplies: activate);
  }

  Future<void> audit(ViewportEvidence value, String owner,
      {String state = 'video_preview_only'}) async {
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'observation:${value.id}',
      'evidence_id': value.id,
      'customer': 'buyer',
      'state': state,
      'updated_at_ms': value.capturedAt.millisecondsSinceEpoch,
      'details': jsonEncode({
        'automationSessionId': session,
        'parentMessageId': owner,
      }),
    });
  }

  Future<void> pendingMedia(String id) async {
    final receipt = await CustomerMediaInventory(db).observe(
        customer: 'buyer',
        evidenceId: 'admission-$id',
        observedAt: now,
        senderAt: now,
        slot: 0,
        region: [.25, .35, .2, .2],
        current: true,
        occurrenceKey: 'arrival-$id');
    await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: 'admission-$id',
        occurrenceKey: 'arrival-$id',
        receivedAt: now,
        senderAt: now,
        messageId: id);
  }

  Future<String> state(ViewportEvidence value) async =>
      (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [value.id]))
          .single['state']! as String;

  test('old04:38 headers and new frame IDs do not start another recovery',
      () async {
    final oldAt = DateTime.utc(2026, 11, 8, 4, 38, 56);
    await input('old-history', activate: false, senderAt: oldAt);
    await db.observePlatformResponse('buyer',
        red: true, observedAt: now, identityVerified: true);
    for (var i = 0; i < 5; i++) {
      final value = await frame('old-reread-$i',
          second: i, metadata: {'unreadArrivalKey': 'current-ax-cycle'});
      expect(await store.claimHeaderRecoveryAnchor(value, oldAt), isNull);
    }
    expect(await store.firstObserved('buyer'), isNull);
    expect(await db.unansweredWorkCounts(), isEmpty);
  });

  test('a current AX signal grants one recovery at its signal clock', () async {
    await db.observePlatformResponse('buyer',
        red: true, observedAt: now, identityVerified: true);
    final first = await frame('current-first',
        second: 3, metadata: {'unreadArrivalKey': 'current-ax-cycle'});
    final next = await frame('current-next',
        second: 8, metadata: {'unreadArrivalKey': 'current-ax-cycle'});
    final anchor = await store.claimHeaderRecoveryAnchor(
        first, now.subtract(const Duration(seconds: 2)));
    expect(anchor, now);
    await store.observe('buyer', anchor!);
    expect(await store.claimHeaderRecoveryAnchor(next, now), isNull);
    expect(await store.firstObserved('buyer'), now);
    expect((await db.platformResponseCycle('buyer'))!['started_at_ms'],
        now.millisecondsSinceEpoch);
  });

  test('an explicitly owned gap retains its original receipt clock', () async {
    await pendingMedia('owned-gap');
    final first = await frame('owned-current', second: 30, metadata: {
      'acquisitionInputKeys': ['owned-gap']
    });
    expect(await store.claimHeaderRecoveryAnchor(first, now), now);
    final repeated = await frame('owned-next', second: 60, metadata: {
      'acquisitionInputKeys': ['owned-gap']
    });
    expect(await store.claimHeaderRecoveryAnchor(repeated, now), isNull);
    expect(await db.isMessageFormallyAnswered('buyer', 'owned-gap'), isFalse);
  });

  test('coverage progress wakes only its pending owner, not old siblings',
      () async {
    await pendingMedia('A');
    await pendingMedia('B');
    final a = await frame('waiting-a');
    final b = await frame('waiting-b', second: 1);
    final orphan = await frame('waiting-unowned', second: 2);
    for (final value in [a, b, orphan]) {
      await store.record(value);
      await store.complete(value, partial: true);
      await store.waitForMediaProgress(value);
    }
    await audit(a, 'A');
    await audit(b, 'B');
    final page = await frame('page-a', second: 3, metadata: {
      'historyCutoffMs': now.millisecondsSinceEpoch,
      'acquisitionInputKeys': ['A'],
    });
    await store.requestBackfill('buyer', now);
    final boundary = now.add(const Duration(minutes: 1));
    expect(await store.reportBackfillProgress('buyer', now, boundary), isTrue);
    final owners = await store.currentAcquisitionOwnerKeys(page);
    expect(owners, contains('A'));
    expect(owners, isNot(contains('B')));
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'coverage:${boundary.millisecondsSinceEpoch}',
            ownerKeys: owners),
        1);
    expect(await state(a), 'media_retry');
    expect(await state(b), 'media_waiting');
    expect(await state(orphan), 'media_waiting');
    final resumed = (await store.claim(mediaOnly: true))!;
    await store.complete(resumed, partial: true);
    await store.waitForMediaProgress(resumed);
    expect(await store.reportBackfillProgress('buyer', now, boundary), isFalse,
        reason: 'Another screenshot ID does not advance this boundary.');
    expect(
        await store.wakeMediaForProgress('buyer',
            progressKey: 'coverage:${boundary.millisecondsSinceEpoch}',
            ownerKeys: owners),
        0);
    expect(await store.claim(mediaOnly: true), isNull);
    expect(await store.covered('buyer', cutoff: now), isTrue);
    expect(await store.covered('buyer', cutoff: now), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
  });

  test('concurrent cleanup coalesces and a missing OCR sidecar is success',
      () async {
    final old = await frame('completed-old');
    final pending = await frame('pending-new', second: 1);
    final processing = await frame('processing-new', second: 2);
    for (final value in [old, pending, processing]) {
      await store.record(value);
    }
    await store.complete(old);
    await (await db.database).update(
        'capture_evidence', {'state': 'processing'},
        where: 'id=?', whereArgs: [processing.id]);
    final first = store.pruneProcessed(keep: 0);
    final second = store.pruneProcessed(keep: 0);
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(await store.lookup(old.id), isNull);
    expect(await File(old.imagePath).exists(), isFalse);
    expect(await pending.filesExist(), isTrue);
    expect(await processing.filesExist(), isTrue);
  });

  test('processed evidence stays while a pending input or observation owns it',
      () async {
    final owned = await frame('completed-but-owned');
    final unresolved = await frame('completed-but-unresolved', second: 1);
    for (final value in [owned, unresolved]) {
      await store.record(value);
      await store.complete(value);
    }
    await input('question', evidence: owned.id);
    await audit(unresolved, 'unbound-observation', state: 'unbound');
    await store.pruneProcessed(keep: 0);
    expect(await owned.filesExist(), isTrue);
    expect(await unresolved.filesExist(), isTrue);
    expect(await store.lookup(owned.id), isNotNull);
    expect(await db.isMessageFormallyAnswered('buyer', 'question'), isFalse);
  });

  test('other cleanup I/O errors retain retry metadata without failing work',
      () async {
    final old = await frame('io-error');
    await store.record(old);
    await store.complete(old);
    await File(old.imagePath).delete();
    await Directory(old.imagePath).create();
    await store.pruneProcessed(keep: 0);
    expect(await state(old), 'processed');
    await Directory(old.imagePath).delete();
    await File(old.imagePath).writeAsBytes([1]);
    await store.pruneProcessed(keep: 0);
    expect(await store.lookup(old.id), isNull);
  });
}
