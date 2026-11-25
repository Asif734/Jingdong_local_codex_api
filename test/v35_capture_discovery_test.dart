import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

const _customer = 'jd_41aeec7741d05';

Future<OcrInspection> _recorded(String name) async =>
    OcrInspection.fromMap(Map<String, Object?>.from(jsonDecode(
            await File('test/fixtures/v35_media/$name.json').readAsString())
        as Map));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same-second duplicate bubbles retain distinct stable occurrence IDs',
      () {
    OcrObservation line(String text, double y) => OcrObservation(
        text: text, confidence: 1, x: .27, y: y, width: .2, height: .018);
    OcrInspection frame(int second) => OcrInspection(
            image: Uint8List(0),
            imageWidth: 2880,
            imageHeight: 1626,
            windowTitle: '咚咚融合工作台',
            recognizedText: '',
            activeCustomerId: _customer,
            capturedAt: DateTime.utc(2026, 11, 5, 8, 0, second),
            chatLeft: .24,
            chatRight: .75,
            chatTop: .20,
            chatBottom: .79,
            observations: [
              line('$_customer 15:59:59', .25),
              line('Yes', .28),
              line('$_customer 15:59:59', .35),
              line('Yes', .38),
              line('$_customer 15:59:59', .45),
              line('No', .48),
            ]);
    final first =
        const OcrCaptureExtractor().analyze(frame(1)).capture!.messages;
    final reread =
        const OcrCaptureExtractor().analyze(frame(2)).capture!.messages;
    expect(first.map((m) => m.body), ['Yes', 'Yes', 'No']);
    expect(first.map((m) => m.stableId).toSet(), hasLength(3));
    expect(first.map((m) => m.stableId), reread.map((m) => m.stableId));
  });

  test('recorded clipped video remains unbound beside a later text question',
      () async {
    final inspection = await _recorded('unbound-video-frame');
    const selector = OcrImageCandidateSelector();
    final owned = selector.select(inspection, _customer,
        includeTextDense: true, allowUnlabeledLatestImage: true);
    expect(owned, isEmpty);
    final unbound = selector.unboundCandidates(inspection, owned);
    expect(unbound, hasLength(1));
    expect(unbound.single.width, greaterThan(.1),
        reason: 'The original failure retained only a small LCD rectangle');
    final extraction = const OcrCaptureExtractor()
        .analyze(inspection, excludedMediaRegions: unbound);
    expect(extraction.latestIncomingHasText, isTrue);
    expect(
        extraction.capture!.messages
            .where((m) => m.direction == 'incoming')
            .map((m) => m.body),
        ['did you get my video?']);
    expect(
        const OcrCaptureExtractor()
            .mediaClockForRegion(inspection, unbound.single)
            .sentAt,
        isNull,
        reason: 'The later question cannot supply this video\'s missing clock');
  });

  test(
      'whole recorded paper card masks text even when its frame overlaps header',
      () async {
    final inspection = await _recorded('paper-card-header-overlap');
    final regions = const OcrImageCandidateSelector()
        .select(inspection, '格志打印机小熊', includeTextDense: true);
    expect(regions, hasLength(1));
    expect(regions.single.width, greaterThan(.11));
    final messages = const OcrCaptureExtractor()
        .analyze(inspection, excludedMediaRegions: regions)
        .capture!
        .messages
        .where((m) => m.direction == 'incoming')
        .map((m) => m.body)
        .toList();
    expect(messages, containsAll(['可以打印这种纸吗', '三联']));
    expect(messages.any((m) => m.contains('可撕边')), isFalse);
  });

  test('recorded JD recommendation overlay is interface, not customer prose',
      () async {
    final inspection = await _recorded('jd-recommendation-overlay');
    final messages = const OcrCaptureExtractor()
        .analyze(inspection)
        .capture!
        .messages
        .where((m) => m.direction == 'incoming');
    expect(messages.single.body, '连打跟这个什么区别');
  });

  group('durable phases and unbound duties', () {
    late Directory root;
    late CaptureDatabase db;
    late CaptureEvidenceStore store;
    late MediaCaptureAudit audit;
    late String session;
    late DateTime now;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_v35_capture_');
      db = CaptureDatabase(storageRoot: root);
      now = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true);
      session = await db.beginAutomationSession(startedAt: now);
      store = CaptureEvidenceStore(db, now: () => now);
      await store.beginSession(sessionId: session, startedAt: now);
      audit = MediaCaptureAudit(db, record: (_, __) {});
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    Future<ViewportEvidence> frame(String id, int offset) async {
      final image =
          await File('test/fixtures/v35_media/unbound-video-frame.png')
              .copy('${root.path}/$id.png');
      final manifest = File('${root.path}/$id.json');
      final metadata = <String, Object?>{
        'evidenceId': id,
        'customer': _customer,
        'automationSessionId': session,
        'capturedAtMs':
            now.add(Duration(seconds: offset)).millisecondsSinceEpoch,
        'imagePath': image.path,
        'manifestPath': manifest.path,
        'replyActivationAllowed': true,
        'capturePurpose': 'live_signal',
        'chatRegion': {
          'left': .24027777777777778,
          'top': .20418204182041821,
          'right': .7479166666666667,
          'bottom': .7921279212792128
        },
      };
      await manifest.writeAsString(jsonEncode(metadata));
      return ViewportEvidence(metadata);
    }

    test('fresh same-customer frame bypasses an in-flight media acquisition',
        () async {
      final old = await frame('old-media', 0);
      expect(await store.record(old), isTrue);
      await store.complete(old, partial: true);
      expect(
          await store.retryMedia(old.id,
              delay: Duration.zero, background: true),
          isTrue);
      var mediaClaim = (await store.claim(mediaOnly: true))!;
      expect(mediaClaim.id, old.id);
      final next = await frame('new-text', 1);
      await store.record(next);
      expect((await store.claim(mediaOnly: false))!.id, next.id);
      expect(
          (await (await db.database).query('capture_evidence',
                  where: 'id=?', whereArgs: [old.id]))
              .single['state'],
          'media_processing');
      for (var i = 0; i < 6; i++) {
        await store.complete((await store.refreshClaim(mediaClaim))!,
            partial: true);
        expect(
            await store.retryMedia(old.id,
                delay: Duration.zero, background: true),
            isTrue);
        mediaClaim = (await store.claim(mediaOnly: true))!;
        expect(mediaClaim.id, old.id);
      }
    });

    test(
        'unbound observations group exact card continuation and ignore old video',
        () async {
      final inspection = await _recorded('unbound-video-frame');
      final region = inspection.unboundMediaRegions.single;
      final first = await frame('visible-card', 0);
      final second = await frame('later-text-same-card', 1);
      final a = await audit.discoverUnbound(first, region);
      await audit.groupUnbound(first, region, a);
      final b = await audit.discoverUnbound(second, region);
      await audit.groupUnbound(second, region, b);
      final pending = await audit.pendingUnboundForCustomer(_customer);
      expect(pending, hasLength(2));
      expect(pending.map((m) => m['observationGroupId']).toSet(), hasLength(1));
      CapturedConversation original(String receipt) => CapturedConversation(
              stableKey: _customer,
              customerName: _customer,
              customerExternalId: _customer,
              capturedAt: now,
              messages: [
                CapturedMessage(
                    stableId: 'verified-$receipt',
                    direction: 'incoming',
                    body: '[Video]',
                    axPath: 'cache',
                    mediaReceiptId: receipt,
                    media: const [
                      CapturedMedia(
                          type: 'video',
                          path: 'original.mp4',
                          captureSource: 'jd_video_cache'),
                      CapturedMedia(
                          type: 'image',
                          path: 'frame.jpg',
                          captureSource: 'jd_video_frame_1fps'),
                    ])
              ]);
      await audit.resolveCaptured(original('old-printer-video'));
      expect(await audit.pendingUnboundForCustomer(_customer), hasLength(2));
      await audit.finish(b, 'video_frames_saved', {
        'mediaReceiptId': 'current-card',
        'resolvedMessageId': 'verified-current-card',
      });
      await audit.resolveCaptured(original('current-card'));
      expect(await audit.pendingUnboundForCustomer(_customer), hasLength(2),
          reason:
              'A receipt/parent string without current business ownership cannot close observations.');

      final inventory = CustomerMediaInventory(db);
      final receipt = await inventory.observe(
          customer: _customer,
          evidenceId: second.id,
          observedAt: second.capturedAt,
          senderAt: null,
          slot: 0,
          region: [region.x, region.y, region.width, region.height],
          current: true,
          occurrenceKey: 'proved-current-card');
      const parent = 'verified-current-card-parent';
      await admitFixtureMedia(db,
          customer: _customer,
          receiptId: receipt,
          messageId: parent,
          receivedAt: second.capturedAt);
      final media = await completedVideoFixture(root, name: 'current-card');
      final completed = CapturedConversation(
          stableKey: _customer,
          customerName: _customer,
          customerExternalId: _customer,
          automationSessionId: session,
          capturedAt: second.capturedAt,
          messages: [
            CapturedMessage(
                stableId: parent,
                direction: 'incoming',
                body: '[Video]',
                axPath: 'exact-current-card',
                mediaReceiptId: receipt,
                media: media)
          ]);
      await db.saveCapture(completed);
      await inventory.persist(completed, verifiedAnchor: true);
      await audit.bindParent(b, receiptId: receipt, messageId: parent);
      await audit.finish(b, 'video_frames_saved', {
        'mediaReceiptId': receipt,
        'parentMessageId': parent,
        'resolvedMessageId': parent,
      });
      await audit.resolveCaptured(completed);
      expect(await audit.pendingUnboundForCustomer(_customer), isEmpty);
      expect(await db.unansweredWorkCounts(), {_customer: 1},
          reason:
              'Resolving a proven capture does not formally answer its message.');
    });

    test('passive Start card remains baseline after a later lower text changes',
        () async {
      final region =
          (await _recorded('unbound-video-frame')).unboundMediaRegions.single;
      final first = await frame('baseline-card', 0);
      final id = await audit.discoverUnbound(first, region,
          current: false, receiptId: 'historical-receipt');
      await audit.groupUnbound(first, region, id);
      final later = await frame('same-card-live', 1);
      final next = await audit.discoverUnbound(later, region);
      final group = await audit.groupUnbound(later, region, next);
      expect(group['state'], 'baseline');
      expect(group['mediaReceiptId'], 'historical-receipt');
      expect(await audit.pendingUnboundForCustomer(_customer), isEmpty);
    });
  });
}
