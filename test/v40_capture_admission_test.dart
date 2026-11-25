import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

const _buyer = 'jd_41aeec7741d05';
const _fixtures = 'test/fixtures/v40_live_registration';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<OcrInspection> view(String name) async =>
      OcrInspection.fromMap(Map<String, Object?>.from(
          jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
              as Map));

  test(
      'real new text bubbles are admitted individually inside a history-marked frame',
      () async {
    final inspection = await view('second-arrival');
    const selector = OcrImageCandidateSelector();
    final regions = selector.select(inspection, _buyer, includeTextDense: true);
    final masked = [
      ...regions,
      ...selector.unboundCandidates(inspection, regions)
    ];
    final capture = const OcrCaptureExtractor()
        .analyze(inspection, excludedMediaRegions: masked)
        .capture!;
    final metadata = {
      'evidenceId': 'recorded-second',
      'customer': _buyer,
      'historyCutoffMs':
          DateTime.utc(2026, 11, 8, 9, 37, 48).millisecondsSinceEpoch,
      'replyActivationAllowed': true,
      'unreadArrivalKey': 'recorded-current-AX-arrival',
    };
    final result = LiveMediaArrival.textInputs(
        evidence: ViewportEvidence(metadata),
        inspection: inspection,
        messages: capture.messages,
        existingIds: {},
        frontier: {
          'id': 'already-received-video',
          'sent_at': DateTime.utc(2026, 11, 8, 9, 37, 45).toIso8601String(),
          'visibleTextAnchors': [
            {
              'id': 'confirmed-seller-question',
              'direction': 'outgoing',
              'body': 'What issue are you experiencing with your TD630?',
              'sent_at': DateTime.utc(2026, 11, 8, 9, 37, 59).toIso8601String(),
            }
          ],
        });
    final actual = capture.messages.where((m) => result.contains(m.stableId));
    expect(actual.map((m) => m.body),
        containsAll(["Don't you get my video?", 'ijust shared']));
    expect(actual, hasLength(2));
    expect(
        LiveMediaArrival.textInputs(
            evidence: ViewportEvidence(metadata),
            inspection: inspection,
            messages: capture.messages,
            existingIds: {},
            frontier: {
              'id': 'offscreen-frontier-with-only-a-clock',
              'sent_at': DateTime.utc(2026, 11, 8, 9, 37, 45).toIso8601String(),
            }),
        isEmpty,
        reason:
            'A later clock plus AX arrival cannot identify a historical bubble without a visible trusted anchor.');
    expect(
        LiveMediaArrival.textInputs(
            evidence:
                ViewportEvidence({...metadata}..remove('unreadArrivalKey')),
            inspection: inspection,
            messages: capture.messages,
            existingIds: {},
            frontier: {
              'id': 'old',
              'sent_at': DateTime.utc(2026, 11, 8, 9).toIso8601String()
            }),
        isEmpty,
        reason: 'A historical sender clock alone cannot start new business.');
  });

  for (final identical in [false, true]) {
    test(
        'two real bubbles in one second survive history navigation; identical=$identical',
        () {
      final at = DateTime.utc(2026, 11, 8, 9, 38, 39);
      final inspection = OcrInspection.fromMap({
        'activeCustomerId': _buyer,
        'windowId': 1,
        'capturedAtMs':
            at.add(const Duration(seconds: 2)).millisecondsSinceEpoch,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .8},
        'observations': [
          {
            'text': '$_buyer 17:38:39',
            'confidence': 1,
            'x': .27,
            'y': .3,
            'width': .25,
            'height': .015
          },
          {
            'text': 'first real bubble',
            'confidence': 1,
            'x': .28,
            'y': .34,
            'width': .2,
            'height': .02
          },
          {
            'text': '$_buyer 17:38:39',
            'confidence': 1,
            'x': .27,
            'y': .42,
            'width': .25,
            'height': .015
          },
          {
            'text': identical ? 'first real bubble' : 'second real bubble',
            'confidence': 1,
            'x': .28,
            'y': .46,
            'width': .2,
            'height': .02
          },
        ],
      });
      final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
      final incoming =
          capture.messages.where((m) => m.direction == 'incoming').toList();
      expect(incoming, hasLength(2));
      expect(incoming.first.sentAt, incoming.last.sentAt);
      final result = LiveMediaArrival.textInputs(
          evidence: ViewportEvidence({
            'customer': _buyer,
            'historyCutoffMs': at.millisecondsSinceEpoch,
            'replyActivationAllowed': true,
            'unreadArrivalKey': 'AX-current'
          }),
          inspection: inspection,
          messages: capture.messages,
          existingIds: {
            incoming.first.stableId
          },
          frontier: {
            'id': incoming.first.stableId,
            'direction': 'incoming',
            'body': incoming.first.body,
            'sent_at': incoming.first.sentAt!.toIso8601String()
          });
      expect(result, incoming.map((m) => m.stableId).toSet(),
          reason:
              'Geometry after the known first bubble proves the second; the shared second is not its ID.');
    });
  }

  test(
      'AX-owned frozen frontier overtakes recovery without dropping older raw frames',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v40_capture_queue_');
    final db = CaptureDatabase(storageRoot: root);
    final now = DateTime.now();
    final session = await db.beginAutomationSession(startedAt: now);
    final store = CaptureEvidenceStore(db);
    await store.beginSession(sessionId: session, startedAt: now);
    Future<ViewportEvidence> frame(String id, int offset,
        {bool live = false}) async {
      final image = await File('${root.path}/$id.png').writeAsBytes([1]);
      final manifest = File('${root.path}/$id.json');
      final value = ViewportEvidence({
        'evidenceId': id,
        'customer': _buyer,
        'automationSessionId': session,
        'capturedAtMs':
            now.add(Duration(milliseconds: offset)).millisecondsSinceEpoch,
        'imagePath': image.path,
        'manifestPath': manifest.path,
        'replyActivationAllowed': true,
        'captureRequestedBackfill': !live,
        if (live) 'unreadArrivalKey': 'AX-new',
        if (live) 'admissionFrontier': {'id': 'known-before-these-pixels'},
      });
      await manifest.writeAsString(value.toJson());
      await store.record(value);
      return value;
    }

    try {
      final old = await frame('old-recovery', 1);
      final fresh = await frame('new-live', 2, live: true);
      expect((await store.claim(mediaOnly: false))!.id, fresh.id);
      await store.rememberTextInputs(fresh, {'one-real-bubble'});
      await store.rememberTextInputs(fresh, {'one-real-bubble'});
      expect((await store.lookup(fresh.id))!.metadata['admittedTextInputIds'],
          ['one-real-bubble']);
      await store.complete(fresh);
      expect((await store.claim(mediaOnly: false))!.id, old.id);
      expect(await old.filesExist(), isTrue);
      expect(await fresh.filesExist(), isTrue);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
