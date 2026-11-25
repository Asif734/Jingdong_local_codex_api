import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_acquisition_route.dart';
import 'package:jd_automation/capture/media_timeline_progress.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validated native image type progress', () {
    test('a pending type hint keeps image and unknown acquisition eligible',
        () {
      final pending = [
        {'type': 'image', 'type_verification': 'pending'}
      ];
      expect(MediaTimelineProgress.inventoryType('unknown', pending),
          (kind: 'unknown', knownImage: false));
      expect(MediaTimelineProgress.inventoryType('image', pending),
          (kind: 'image', knownImage: true));
      expect(MediaTimelineProgress.inventoryType('video', pending),
          (kind: 'video', knownImage: false));
      expect(
          MediaTimelineProgress.inventoryType('unknown', [
            {'type': 'video'}
          ]),
          (kind: 'video', knownImage: false));
    });

    Future<String?> advance({
      String timelineKind = 'media',
      String inventoryKind = 'unknown',
      bool rectangle = true,
      String nativeKind = 'image',
      bool bytes = true,
      bool playback = false,
      bool video = false,
      FutureOr<bool> Function()? current,
      Future<bool> Function()? confirm,
      Future<String?> Function()? acquire,
    }) =>
        MediaTimelineProgress.advanceValidatedImage<String>(
            timelineKind: timelineKind,
            inventoryKind: inventoryKind,
            hasValidatedRectangle: rectangle,
            nativeKind: nativeKind,
            hasImageBytes: bytes,
            playbackOverlayDetected: playback,
            hasVideoPayload: video,
            isCurrent: current ?? () => true,
            confirmImageType: confirm ?? () async => true,
            acquireOriginal: acquire ?? () async => 'acquisition-started');

    test(
        'an unknown cache miss establishes type then acquires in the same call',
        () async {
      final calls = <String>[];
      var kind = 'unknown';
      const ready = false;
      const answered = false;
      final result = await advance(confirm: () async {
        calls.add('type-only');
        kind = 'image';
        return true;
      }, acquire: () async {
        expect(kind, 'image');
        expect(ready, isFalse);
        expect(answered, isFalse);
        calls.add('original-download');
        return 'native-download-token';
      });
      expect(result, 'native-download-token');
      expect(calls, ['type-only', 'original-download']);
      expect(ready, isFalse);
      expect(answered, isFalse);
    });

    test('first valid rectangle never falls back to Copy after a cache miss',
        () async {
      final calls = <String>[];
      final result = await ImageAcquisitionRoute.run<String, String>(
          kind: 'unknown',
          hasValidatedRectangle: true,
          hasContextTarget: true,
          isCurrent: () => true,
          viaVision: () => advance(confirm: () async {
                calls.add('classify-image');
                return true;
              }, acquire: () async {
                calls.add('original-acquisition');
                return null;
              }),
          copyUnderUiLease: () async => fail('Copy cannot replace a real ROI'),
          compareInBackground: (_) async => fail('No context copy was made'));
      expect(result, isNull);
      expect(calls, ['classify-image', 'original-acquisition']);
    });

    test('a known image proceeds without being classified again', () async {
      expect(
          await advance(
              inventoryKind: 'image',
              confirm: () async => fail('Type is already established')),
          'acquisition-started');
    });

    for (final kind in ['text', 'video', 'unsupported']) {
      test('$kind inventory can never be promoted to image', () async {
        expect(
            await advance(
                inventoryKind: kind,
                confirm: () async => fail('No type write'),
                acquire: () async => fail('No image acquisition')),
            isNull);
      });
    }

    for (final proof in [
      'text-timeline',
      'no-roi',
      'no-bytes',
      'play',
      'video'
    ]) {
      test('$proof is not image type proof', () async {
        expect(
            await advance(
                timelineKind: proof == 'text-timeline' ? 'text' : 'media',
                rectangle: proof != 'no-roi',
                bytes: proof != 'no-bytes',
                playback: proof == 'play',
                nativeKind: proof == 'video' ? 'video' : 'image',
                video: proof == 'video',
                confirm: () async => fail('Unproven type must remain pending'),
                acquire: () async => fail('No unproven viewer action')),
            isNull);
      });
    }

    test('a video object cannot be disguised by a native image label',
        () async {
      expect(
          await advance(
              video: true,
              confirm: () async => fail('Video must keep its original path'),
              acquire: () async => fail('Not an image')),
          isNull);
    });

    test('text correction winning the type write prevents the viewer',
        () async {
      expect(
          await advance(
              confirm: () async => false,
              acquire: () async => fail('A proven text message cannot reopen')),
          isNull);
    });

    test('new owner or expiry during type commit prevents late UI acquisition',
        () async {
      final started = Completer<void>();
      final committed = Completer<bool>();
      var current = true;
      final work = advance(
          current: () => current,
          confirm: () {
            started.complete();
            return committed.future;
          },
          acquire: () async => fail('Old ownership cannot acquire a viewer'));
      await started.future;
      current = false;
      committed.complete(true);
      expect(await work, isNull);
    });

    for (final native in ['image', 'unverified', 'video']) {
      test('$native without positive native video proof is not delegated',
          () async {
        expect(
            await MediaTimelineProgress.delegateValidatedVideo(
                timelineKind: 'media',
                nativeKind: native,
                hasVideoPayload: false,
                playbackOverlayDetected: false,
                isCurrent: () => true,
                confirmVideoType: () async => fail('No native video proof'),
                handOff: () async =>
                    fail('Existing video flow must not start')),
            isFalse);
      });
    }
  });

  group('real admitted timeline records', () {
    const customer = 'media-progress-buyer';
    late Directory root;
    late CaptureDatabase db;
    late CustomerMediaInventory inventory;
    late DateTime at;
    late String session;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_v62_media_progress_');
      db = CaptureDatabase(storageRoot: root);
      inventory = CustomerMediaInventory(db);
      at = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000 - 10000,
          isUtc: true);
      session = await db.beginAutomationSession(
          startedAt: at.subtract(const Duration(seconds: 1)));
    });

    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Future<({String receipt, String message})> admit(DateTime sender) async {
      final receipt = await inventory.observe(
          customer: customer,
          evidenceId: 'frame-${sender.millisecondsSinceEpoch}',
          observedAt: DateTime.now().toUtc(),
          senderAt: sender,
          slot: 0,
          region: [.25, .4, .15, .3],
          current: true);
      final admission = await db.admitMediaMessage(customer,
          receiptId: receipt,
          evidenceId: 'frame-${sender.millisecondsSinceEpoch}',
          occurrenceKey: 'arrival-${sender.millisecondsSinceEpoch}',
          receivedAt: sender,
          senderAt: sender);
      return (receipt: receipt, message: admission.messageId);
    }

    Future<Map<String, Object?>> row(String receipt) async =>
        (await (await db.database).query('customer_media_items',
                where: 'item_id=?', whereArgs: [receipt]))
            .single;

    Future<String?> progress(({String receipt, String message}) owner) async {
      return MediaTimelineProgress.advanceValidatedImage<String>(
          timelineKind: 'media',
          inventoryKind: (await row(owner.receipt))['kind']! as String,
          hasValidatedRectangle: true,
          nativeKind: 'image',
          hasImageBytes: true,
          playbackOverlayDetected: false,
          hasVideoPayload: false,
          isCurrent: () async {
            final parent = await inventory.resolveParent(customer,
                receiptId: owner.receipt, requireCurrentSession: true);
            return parent?.messageId == owner.message;
          },
          confirmImageType: () async {
            await inventory.classify(owner.receipt, 'image');
            return (await row(owner.receipt))['kind'] == 'image';
          },
          acquireOriginal: () async {
            expect((await row(owner.receipt))['kind'], 'image');
            expect(await inventory.analysisReadyMessageIds(customer), isEmpty);
            expect(await db.isMessageFormallyAnswered(customer, owner.message),
                isFalse);
            return 'acquiring:${owner.message}';
          });
    }

    test('cache miss promotes type only, then follows durable image expiry',
        () async {
      final owner = await admit(at);
      expect((await row(owner.receipt))['kind'], 'unknown');
      expect(await progress(owner), 'acquiring:${owner.message}');
      final image = await row(owner.receipt);
      expect(image['kind'], 'image');
      expect(image['state'], isNot('ready'));
      expect(image['media_json'], '[]');
      final work = (await (await db.database).query(
              'automation_session_messages',
              where: 'session_id=? AND user_id=? AND message_id=?',
              whereArgs: [session, customer, owner.message]))
          .single;
      expect(work['response_state'], 'pending');
      expect(work['input_kind'], 'media');
      expect(await inventory.analysisReadyMessageIds(customer), isEmpty);
      final expiry = await db.processIncompleteImagePolicy(customer,
          now: at.add(const Duration(minutes: 3)));
      expect(expiry.queuedResponse, isTrue);
      expect(expiry.retiredMessageIds, {owner.message});
      expect(
          await db.isMessageFormallyAnswered(customer, owner.message), isFalse);
    });

    test('later sender second retains another message even for the same image',
        () async {
      final first = await admit(at);
      final nextAt = at.add(const Duration(seconds: 1));
      final second = await admit(nextAt);
      expect(first.message, isNot(second.message));
      expect(first.receipt, isNot(second.receipt));
      expect(await progress(first), 'acquiring:${first.message}');
      expect(await progress(second), 'acquiring:${second.message}');
      expect(await (await db.database).query('customer_media_items'),
          hasLength(2));
      expect(await db.unansweredWorkCounts(), {customer: 2});
      expect(await inventory.analysisReadyMessageIds(customer), isEmpty);
    });

    for (final source in [
      'jd-image-cache',
      'jd-image-viewer-download',
      'jd-image-viewer-copy',
      'jd-message-context-copy',
      'jd-message-context-copy-cache',
    ]) {
      test(
          '$source full-original verdict clears the pending type after persist',
          () async {
        final owner = await admit(at);
        await inventory.classify(owner.receipt, 'image');
        final path = '${root.path}/original.png';
        await File(path).writeAsBytes([1, 2, 3]);
        final capture = CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: session,
            capturedAt: DateTime.now().toUtc(),
            messages: [
              CapturedMessage(
                  stableId: owner.message,
                  direction: 'incoming',
                  sender: customer,
                  sentAt: at,
                  body: '[Customer sent an image]',
                  axPath: 'native-original',
                  mediaReceiptId: owner.receipt,
                  media: [
                    CapturedMedia(
                        type: 'image',
                        path: path,
                        captureSource: 'jd_image_cache')
                  ])
            ]);
        await db.saveCapture(capture);
        await inventory.persist(capture,
            verifiedAnchor: true, currentTaskOnly: true);
        expect(
            await inventory.markMediaTypeVerificationPending(customer,
                messageId: owner.message,
                receiptId: owner.receipt,
                imagePath: path),
            isTrue);
        // Saving the same original alone retains the older type-pending hint.
        await db.saveCapture(capture);
        await inventory.persist(capture,
            verifiedAnchor: true, currentTaskOnly: true);
        expect(await inventory.analysisReadyMessageIds(customer), isEmpty);
        expect(
            await inventory.resolveMediaTypeVerification(customer,
                receiptId: owner.receipt,
                nativeKind: 'image',
                captureSource: source,
                hasImageBytes: true,
                playbackOverlayDetected: false,
                verifiedOriginal: true),
            isTrue);
        expect(await inventory.analysisReadyMessageIds(customer),
            contains(owner.message));
        expect(await db.isMessageFormallyAnswered(customer, owner.message),
            isFalse);
        expect(await db.unansweredWorkCounts(), {customer: 1});
        expect(await (await db.database).query('customer_media_items'),
            hasLength(1));
      });
    }

    test('a preview or context label without full-original proof stays pending',
        () async {
      expect(
          MediaTimelineProgress.isVerifiedImageOriginal(
              nativeKind: 'image',
              captureSource: 'frozen-window-crop',
              hasImageBytes: true,
              playbackOverlayDetected: false,
              hasVideoPayload: false,
              verifiedOriginal: true),
          isFalse);
      expect(
          MediaTimelineProgress.isVerifiedImageOriginal(
              nativeKind: 'image',
              captureSource: 'jd-message-context-copy',
              hasImageBytes: true,
              playbackOverlayDetected: false,
              hasVideoPayload: false),
          isFalse);
    });

    test(
        'positive native video requeues its saved frame without losing new input',
        () async {
      final owner = await admit(at);
      final inbox = CaptureEvidenceStore(db);
      await inbox.beginSession(
          sessionId: session,
          startedAt: at.subtract(const Duration(seconds: 1)));
      final id = 'frame-${at.millisecondsSinceEpoch}';
      final pixels = File('${root.path}/$id.png');
      final manifest = File('${root.path}/$id.json');
      await pixels.writeAsBytes([1, 2, 3]);
      await manifest.writeAsString('{}');
      final evidence = ViewportEvidence({
        'evidenceId': id,
        'customer': customer,
        'imagePath': pixels.path,
        'manifestPath': manifest.path,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'automationSessionId': session,
        'mediaAcquisitionPending': true,
      });
      await inbox.record(evidence);
      await inbox.complete(evidence);
      ({String receipt, String message})? next;
      expect(
          await MediaTimelineProgress.delegateValidatedVideo(
              timelineKind: 'media',
              nativeKind: 'video',
              hasVideoPayload: true,
              playbackOverlayDetected: true,
              isCurrent: () async =>
                  (await inventory.resolveParent(customer,
                          receiptId: owner.receipt,
                          requireCurrentSession: true))
                      ?.messageId ==
                  owner.message,
              confirmVideoType: () async {
                await inventory.classify(owner.receipt, 'video');
                next = await admit(at.add(const Duration(seconds: 1)));
                return (await row(owner.receipt))['kind'] == 'video';
              },
              handOff: () async {
                expect(await inbox.requestMediaTypeRecheck(id), isTrue);
              }),
          isTrue);
      final frame = (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;
      expect(frame['state'], 'media_retry');
      expect((await row(owner.receipt))['kind'], 'video');
      expect((await row(next!.receipt))['kind'], 'unknown');
      expect(await db.unansweredWorkCounts(), {customer: 2});
      expect(await inventory.analysisReadyMessageIds(customer), isEmpty);
    });

    test('one recovery frame keeps both timed media owners', () async {
      final first = await admit(at);
      final second = await admit(at.add(const Duration(seconds: 1)));
      final inbox = CaptureEvidenceStore(db);
      await inbox.beginSession(
          sessionId: session,
          startedAt: at.subtract(const Duration(seconds: 1)));
      const id = 'shared-recovery-frame';
      final pixels = File('${root.path}/$id.png');
      final manifest = File('${root.path}/$id.json');
      await pixels.writeAsBytes([1, 2, 3]);
      await manifest.writeAsString('{}');
      await inbox.record(ViewportEvidence({
        'evidenceId': id,
        'customer': customer,
        'imagePath': pixels.path,
        'manifestPath': manifest.path,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'automationSessionId': session,
        'acquisitionOnly': true,
        'acquisitionInputKeys': [first.message, first.receipt],
      }));
      final accepted = await Future.wait([
        inbox.requestMediaTypeRecheck(id,
            acquisitionOwnerKeys: {first.message, first.receipt}),
        inbox.requestMediaTypeRecheck(id,
            acquisitionOwnerKeys: {second.message, second.receipt}),
      ]);
      expect(accepted, [true, true]);
      expect(
          (await inbox.lookup(id))!.metadata['acquisitionInputKeys'],
          unorderedEquals(
              [first.message, first.receipt, second.message, second.receipt]));
    });

    test('a missing or mismatched saved video frame is never queued', () async {
      final inbox = CaptureEvidenceStore(db);
      await inbox.beginSession(
          sessionId: session,
          startedAt: at.subtract(const Duration(seconds: 1)));
      const id = 'saved-video-source';
      final pixels = File('${root.path}/$id.png');
      final manifest = File('${root.path}/$id.json');
      await pixels.writeAsBytes([1, 2, 3]);
      await manifest.writeAsString('{}');
      final evidence = ViewportEvidence({
        'evidenceId': id,
        'customer': customer,
        'imagePath': pixels.path,
        'manifestPath': manifest.path,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'automationSessionId': session,
      });
      await inbox.record(evidence);
      await inbox.complete(evidence);
      Future<bool> tryQueue({String? forCustomer, String? forSession}) async {
        final stored = await inbox.lookup(id);
        if (!await MediaTimelineProgress.savedFrameIsUsable(stored,
            customer: forCustomer ?? customer,
            sessionId: forSession ?? session)) {
          return false;
        }
        return inbox.requestMediaTypeRecheck(id);
      }

      expect(await tryQueue(forCustomer: 'another-buyer'), isFalse);
      expect(await tryQueue(forSession: 'old-run'), isFalse);
      await pixels.delete();
      expect(await tryQueue(), isFalse);
      final stored = (await (await db.database)
              .query('capture_evidence', where: 'id=?', whereArgs: [id]))
          .single;
      expect(stored['state'], isNot('media_retry'));
      await pixels.writeAsBytes([1, 2, 3]);
      expect(await tryQueue(), isTrue);
    });
  });
}
