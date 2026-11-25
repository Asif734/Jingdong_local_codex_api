import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/media_caption_dependency.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final at = DateTime.utc(2026, 11, 8, 4, 30);
  const card =
      OcrVisualRegion(x: .28, y: .42, width: .16, height: .18, confidence: 1);
  ViewportEvidence evidence({bool arrival = false, bool history = false}) =>
      ViewportEvidence({
        'evidenceId': 'immutable-raw-evidence',
        'customer': 'buyer',
        'capturedAtMs': at.millisecondsSinceEpoch,
        'replyActivationAllowed': true,
        if (arrival) 'unreadArrivalKey': 'one-real-ax-transition',
        if (history) 'historyCutoffMs': at.millisecondsSinceEpoch,
      });
  OcrInspection inspection(
          {List<OcrObservation>? observations, String customer = 'buyer'}) =>
      OcrInspection.fromMap({
        'activeCustomerId': customer,
        'windowId': 1,
        'imageWidth': 1000,
        'imageHeight': 1000,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'chatRegion': {'left': .24, 'top': .2, 'right': .75, 'bottom': .81},
        'observations': [
          for (final line in observations ?? const <OcrObservation>[])
            {
              'text': line.text,
              'confidence': line.confidence,
              'x': line.x,
              'y': line.y,
              'width': line.width,
              'height': line.height,
            },
        ],
      });
  OcrMediaClockEvidence header(DateTime time) => OcrMediaClockEvidence(
      sentAt: time,
      source: 'ocr_media_sender_header',
      headerTop: .385,
      headerBottom: .405,
      confidence: 1);

  test('empty verified baseline discovers a new card without red or unread',
      () {
    final result = LiveMediaArrival.infer(
        evidence: evidence(),
        inspection: inspection(),
        cards: [card],
        headers: {card: header(at)},
        knownParents: {},
        visibleText: [],
        frontier: {'id': 'empty-baseline', 'empty': true});
    expect(result.keys, [card]);
    expect(result.values.single, 'frontier:empty-baseline:incoming-media:0');
    expect(
        LiveMediaArrival.infer(
            evidence: evidence(history: true),
            inspection: inspection(),
            cards: [card],
            headers: {card: header(at)},
            knownParents: {},
            visibleText: [],
            frontier: {'id': 'empty-baseline', 'empty': true}),
        isEmpty);
  });

  test('a real AX transition cannot revive an older offscreen bubble', () {
    final frontier = {
      'id': 'actual-newer-answer',
      'sent_at': at.subtract(const Duration(minutes: 2)).toIso8601String()
    };
    Map<OcrVisualRegion, String> infer(DateTime sender) =>
        LiveMediaArrival.infer(
            evidence: evidence(arrival: true),
            inspection: inspection(),
            cards: [card],
            headers: {card: header(sender)},
            knownParents: {},
            visibleText: [],
            frontier: frontier);
    expect(infer(at.subtract(const Duration(minutes: 20))), isEmpty,
        reason:
            'The 04:02 card revisited at 04:46 is an observation, not a new arrival');
    expect(infer(at), hasLength(1));
    expect(
        LiveMediaArrival.infer(
            evidence: evidence(arrival: true),
            inspection: inspection(),
            cards: [card],
            headers: {
              card: const OcrMediaClockEvidence(
                  source: 'no_incoming_header_above_card')
            },
            knownParents: {},
            visibleText: [],
            frontier: frontier),
        isEmpty);
  });

  test('same-second identical visible cards have distinct occurrence ordinals',
      () {
    const second =
        OcrVisualRegion(x: .28, y: .66, width: .16, height: .12, confidence: 1);
    final result = LiveMediaArrival.infer(
        evidence: evidence(),
        inspection: inspection(),
        cards: [
          card,
          second
        ],
        headers: {
          card: header(at),
          second: OcrMediaClockEvidence(
              sentAt: at,
              source: 'ocr_media_sender_header',
              headerTop: .62,
              headerBottom: .64,
              confidence: 1)
        },
        knownParents: {},
        visibleText: [],
        frontier: {
          'id': 'empty',
          'empty': true
        });
    expect(result, hasLength(2));
    expect(result.values.toSet(), hasLength(2));
  });

  test(
      'new text needs frontier proof; an OCR alias attaches to the existing input',
      () {
    final message = CapturedMessage(
        stableId: 'new-ocr',
        direction: 'incoming',
        body: 'My device has stopped',
        sentAt: at,
        axPath: 'incoming');
    final scan = inspection(observations: const [
      OcrObservation(
          text: 'My device has stopped',
          confidence: 1,
          x: .28,
          y: .5,
          width: .3,
          height: .02)
    ]);
    final frontier = {
      'id': 'last-answer',
      'sent_at': at.add(const Duration(seconds: 5)).toIso8601String()
    };
    expect(
        LiveMediaArrival.textInputs(
            evidence: evidence(arrival: true),
            inspection: scan,
            messages: [message],
            existingIds: {},
            frontier: frontier),
        isEmpty);
    expect(
        LiveMediaArrival.textInputs(
            evidence: evidence(),
            inspection: scan,
            messages: [message],
            existingIds: {'new-ocr'},
            frontier: frontier),
        {'new-ocr'});
    expect(
        LiveMediaArrival.textInputs(
            evidence: evidence(),
            inspection: inspection(customer: 'another-buyer'),
            messages: [message],
            existingIds: {'new-ocr'},
            frontier: {'id': 'empty', 'empty': true}),
        isEmpty,
        reason: 'Even an existing alias cannot cross an AX customer mismatch');
    expect(
        LiveMediaArrival.textInputs(
            evidence: evidence(),
            inspection: scan,
            messages: [message],
            existingIds: {},
            frontier: {'id': 'empty', 'empty': true}),
        {'new-ocr'});
  });

  test(
      'actual checkout caption is linked before generation without an intent word list',
      () async {
    final map = Map<String, Object?>.from(jsonDecode(
        await File('test/fixtures/v38_media_parent/first-gray.ocr.json')
            .readAsString()) as Map);
    final scan = OcrInspection.fromMap(map);
    const customer = 'jd_41aeec7741d05';
    final cards = const OcrImageCandidateSelector()
        .select(scan, customer, includeTextDense: true);
    final texts = const OcrCaptureExtractor()
        .analyze(scan, excludedMediaRegions: cards)
        .capture!
        .messages;
    final caption =
        texts.singleWhere((m) => m.body.toLowerCase().contains('checkout'));
    final result = MediaCaptionDependency.inferScope(scan, customer, texts,
        {for (final region in cards) region: 'actual-parent'});
    expect(result[caption.stableId], {'actual-parent'});
    expect(
        MediaCaptionDependency.inferScope(scan, customer, texts,
            {for (final region in cards) region: 'actual-parent'},
            independentMessageIds: {caption.stableId}),
        isEmpty,
        reason:
            'Only an explicit independent scope may opt out, never a USB/check keyword');
  });

  test(
      'actual hour old retries park durably, fresh evidence passes, and only new progress wakes',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v38_waiting_');
    final db = CaptureDatabase(storageRoot: root);
    try {
      final session = await db.beginAutomationSession(startedAt: at);
      final store = CaptureEvidenceStore(db,
          now: () => at.add(const Duration(seconds: 1)));
      await store.beginSession(sessionId: session, startedAt: at);
      Future<ViewportEvidence> frame(String id, int offset) async {
        final png = await File('${root.path}/$id.png').writeAsBytes([1]);
        final manifest = File('${root.path}/$id.json');
        final value = ViewportEvidence({
          'evidenceId': id,
          'customer': 'buyer',
          'capturedAtMs':
              at.add(Duration(milliseconds: offset)).millisecondsSinceEpoch,
          'automationSessionId': session,
          'capturePurpose': 'live_signal',
          'replyActivationAllowed': true,
          'imagePath': png.path,
          'manifestPath': manifest.path
        });
        await manifest.writeAsString(value.toJson());
        await store.record(value);
        return value;
      }

      final old = await frame('old-unbound-owner', 1);
      await store.complete((await store.claim(mediaOnly: false))!,
          partial: true);
      await store.retryMedia(old.id, delay: Duration.zero, background: true);
      final first = (await store.claim(mediaOnly: true))!;
      await store.complete(first, partial: true);
      await store.waitForMediaProgress(first);
      final replay = jsonDecode(
          await File('test/fixtures/v38_media_parent/hour-order.json')
              .readAsString()) as Map;
      var retries = 0;
      for (final event in replay['events'] as List) {
        if (event['event'] != 'media.pending_retry') continue;
        retries++;
        expect(await store.claim(mediaOnly: true), isNull);
      }
      expect(retries, 548);
      await frame('fresh-current-question', 2);
      expect(
          (await store.claim(mediaOnly: false))!.id, 'fresh-current-question');
      expect(await File(old.imagePath).exists(), isTrue);
      expect(
          await store.wakeMediaForProgress('buyer',
              progressKey: 'unrelated-cache-change', ownerKeys: {}),
          0,
          reason:
              'A shared-cache change cannot reactivate an unadmitted orphan');
      expect(
          await store.wakeMediaForProgress('buyer',
              progressKey: 'cache:changed'),
          1);
      final resumed = (await store.claim(mediaOnly: true))!;
      expect(resumed.id, old.id);
      await store.complete(resumed, partial: true);
      await store.waitForMediaProgress(resumed);
      expect(
          await store.wakeMediaForProgress('buyer',
              progressKey: 'cache:changed'),
          0);
      expect(await store.claim(mediaOnly: true), isNull);
      expect(
          await store.wakeMediaForProgress('buyer',
              progressKey: 'coverage:next-page'),
          1);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
