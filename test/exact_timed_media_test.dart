import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/exact_timed_media.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  final started = DateTime.utc(2026, 11, 17, 9, 30);
  final captured = DateTime.utc(2026, 11, 17, 9, 47);
  const first =
      OcrVisualRegion(x: .27, y: .35, width: .09, height: .20, confidence: 1);
  const second =
      OcrVisualRegion(x: .27, y: .60, width: .10, height: .13, confidence: 1);
  const legacy =
      OcrVisualRegion(x: .28, y: .36, width: .25, height: .17, confidence: 1);
  OcrObservation label(String time, double y) => OcrObservation(
      text: 'buyer $time',
      confidence: .99,
      x: .27,
      y: y,
      width: .14,
      height: .014);
  final frame = OcrInspection(
      image: Uint8List(0),
      imageWidth: 2880,
      imageHeight: 1626,
      windowTitle: 'JD',
      recognizedText: '',
      observations: [label('17:45:36', .32), label('17:45:42', .57)],
      visualRegions: const [legacy],
      physicalMediaRegions: const [first, second],
      capturedAt: captured,
      activeCustomerId: 'buyer',
      chatTop: .2,
      chatLeft: .23,
      chatRight: .75,
      chatBottom: .79);
  ViewportEvidence evidence({bool authorized = true}) => ViewportEvidence({
        'customer': 'buyer',
        'evidenceId': 'saved-history-page',
        'capturedAtMs': captured.millisecondsSinceEpoch,
        'automationSessionId': 'run',
        'historyCutoffMs': captured.millisecondsSinceEpoch,
        'capturePurpose': 'history_backfill',
        'replyActivationAllowed': authorized,
      });

  test('exact complete cards keep distinct sender seconds on a backfill page',
      () {
    final cards =
        ExactTimedMedia.select(evidence(), frame, sessionStartedAt: started);
    expect(cards.map((c) => c.region), [first, second]);
    expect(cards.map((c) => c.sentAt.toUtc()), [
      DateTime.utc(2026, 11, 17, 9, 45, 36),
      DateTime.utc(2026, 11, 17, 9, 45, 42)
    ]);
    expect(
        ExactTimedMedia.select(evidence(authorized: false), frame,
            sessionStartedAt: started),
        isEmpty);
  });

  test('registered cards start independently without live admission', () async {
    final at1 = DateTime.utc(2026, 11, 17, 9, 45, 36);
    final at2 = DateTime.utc(2026, 11, 17, 9, 45, 42);
    final cards = ExactTimedMedia.registered(evidence(authorized: false), frame,
        {first: at1, second: at2, legacy: at1});
    final hold = Completer<void>();
    final startedSecond = Completer<void>();
    final work = ExactTimedMedia.run(cards, (card) async {
      if (card.sentAt.isAtSameMomentAs(at1)) await hold.future;
      if (card.sentAt.isAtSameMomentAs(at2)) startedSecond.complete();
    });
    try {
      expect(cards.map((card) => card.region), [first, second]);
      await startedSecond.future.timeout(const Duration(seconds: 1));
      expect(hold.isCompleted, isFalse);
    } finally {
      hold.complete();
      await work;
    }
  });

  test('one saved frame serves all pending times, not just the requesting time',
      () async {
    final a = DateTime.utc(2026, 11, 17, 9, 45, 36);
    final b = DateTime.utc(2026, 11, 17, 9, 45, 42);
    final cards =
        ExactTimedMedia.forPending(evidence(authorized: false), frame, [a, b]);
    expect(cards.map((c) => c.region), [first, second]);
    expect(
        ExactTimedMedia.forPending(evidence(), frame, [b]).map((c) => c.region),
        [second]);
    final hold = Completer<void>();
    final finished = <DateTime>[];
    final work = ExactTimedMedia.run(cards, (card) async {
      if (card.sentAt == a) await hold.future;
      finished.add(card.sentAt);
    });
    await Future<void>.delayed(Duration.zero);
    try {
      expect(finished, [b]);
    } finally {
      hold.complete();
      await work;
    }
  });

  test('a slow first match does not block a later timestamp', () async {
    final cards =
        ExactTimedMedia.select(evidence(), frame, sessionStartedAt: started);
    final held = Completer<void>();
    final later = Completer<void>();
    final work = ExactTimedMedia.run(cards, (card) async {
      if (card.region == first) {
        await held.future;
      } else {
        later.complete();
      }
    });
    await later.future.timeout(const Duration(seconds: 1));
    expect(held.isCompleted, false);
    held.complete();
    await work;
  });
}
