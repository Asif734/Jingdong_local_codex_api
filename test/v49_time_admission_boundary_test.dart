import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/incoming_message_blocks.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const customer = 'jd_late_clock';
  final startSecond = DateTime.utc(2026, 11, 10);
  final startedAt = startSecond.add(const Duration(milliseconds: 500));
  final capturedAt = startSecond.add(const Duration(seconds: 5));
  String display(DateTime at) {
    final jd = at.add(const Duration(hours: 8));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(jd.hour)}:${two(jd.minute)}:${two(jd.second)}';
  }

  OcrInspection view(List<(DateTime, String)> inputs) => OcrInspection.fromMap({
        'activeCustomerId': customer,
        'windowId': 1,
        'capturedAtMs': capturedAt.millisecondsSinceEpoch,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .85},
        'observations': [
          for (var i = 0; i < inputs.length; i++) ...[
            {
              'text': '$customer ${display(inputs[i].$1)}',
              'confidence': 1,
              'x': .27,
              'y': .28 + i * .12,
              'width': .25,
              'height': .015,
            },
            {
              'text': inputs[i].$2,
              'confidence': 1,
              'x': .28,
              'y': .32 + i * .12,
              'width': .25,
              'height': .02,
            },
          ],
        ],
      });
  ViewportEvidence evidence([Map<String, Object?> changes = const {}]) =>
      ViewportEvidence({
        'evidenceId': 'controlled-late-time',
        'customer': customer,
        'capturedAtMs': capturedAt.millisecondsSinceEpoch,
        'automationSessionId': 'controlled-current-run',
        'automationSessionStartedAtMs': startedAt.millisecondsSinceEpoch,
        'replyActivationAllowed': true,
        'capturePurpose': 'active_discovery',
        ...changes,
      });

  test('late OCR of T1 is admitted after T2 has already become the frontier',
      () {
    final t1 = startSecond.add(const Duration(seconds: 1));
    final t2 = startSecond.add(const Duration(seconds: 2));
    final inspection = view([(t1, 'first question'), (t2, 'second question')]);
    final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
    final t1Id = CustomerMessageTime.incomingId(customer, t1);
    final t2Id = CustomerMessageTime.incomingId(customer, t2);
    Set<String> admit(ViewportEvidence frame) => LiveMediaArrival.textInputs(
            evidence: frame,
            inspection: inspection,
            messages: capture.messages,
            existingIds: {
              t2Id
            },
            frontier: {
              'id': t2Id,
              'direction': 'incoming',
              'body': 'second question',
              'sent_at': t2.toIso8601String(),
            });
    expect(admit(evidence()), {t1Id, t2Id});
    expect(
        admit(evidence({
          'capturePurpose': 'history_backfill',
          'historyCutoffMs': startedAt.millisecondsSinceEpoch,
          'captureRequestedBackfill': true,
        })),
        {t1Id, t2Id},
        reason:
            'An authorized current-run recovery does not need T2 below T1.');
    expect(admit(evidence({'acquisitionOnly': true})), {t2Id});
    expect(admit(evidence({'capturePurpose': 'discovery_baseline'})), {t2Id});
  });

  test(
      'time admission uses the fixed Start second and rejects old/future clocks',
      () {
    final inspection = view([
      (startSecond.subtract(const Duration(seconds: 1)), 'before Start'),
      (startSecond, 'same second as Start'),
      (startSecond.add(const Duration(seconds: 1)), 'current question'),
      (startSecond.add(const Duration(seconds: 8)), 'invalid future clock'),
    ]);
    final capture = const OcrCaptureExtractor().analyze(inspection).capture!;
    final admitted = LiveMediaArrival.textInputs(
        evidence: evidence(),
        inspection: inspection,
        messages: capture.messages,
        existingIds: {},
        frontier: {'id': 'empty-start', 'empty': true});
    expect(admitted, {
      CustomerMessageTime.incomingId(customer, startSecond),
      CustomerMessageTime.incomingId(
          customer, startSecond.add(const Duration(seconds: 1))),
    });
    expect(
        LiveMediaArrival.textInputs(
            evidence: evidence({'customer': 'different-customer'}),
            inspection: inspection,
            messages: capture.messages,
            existingIds: {}),
        isEmpty);
  });

  test('complete media clocks cannot be vetoed or rescued by old geometry', () {
    final t1 = startSecond.add(const Duration(seconds: 1));
    final t2 = startSecond.add(const Duration(seconds: 2));
    final inspection = view([(t1, 'media body')]);
    const card =
        OcrVisualRegion(x: .27, y: .32, width: .2, height: .1, confidence: 1);
    Map<OcrVisualRegion, String> infer(DateTime clock,
            [Map<String, Object?> changes = const {}]) =>
        LiveMediaArrival.infer(
            evidence: evidence(changes),
            inspection: inspection,
            cards: [card],
            headers: {
              card: OcrMediaClockEvidence(
                  source: 'ocr_media_sender_header',
                  sentAt: clock,
                  headerTop: .28,
                  headerBottom: .295,
                  confidence: 1)
            },
            knownParents: {},
            visibleText: [],
            frontier: {
              'id': 'later-T2-offscreen',
              'sent_at': t2.toIso8601String(),
            },
            sessionStartedAt: startedAt);
    expect(infer(t1), {card: CustomerMessageTime.incomingId(customer, t1)});
    expect(infer(startSecond.subtract(const Duration(seconds: 1))), isEmpty);
    expect(infer(t1, {'acquisitionOnly': true}), isEmpty);

    final future = view([
      (startSecond.add(const Duration(seconds: 8)), 'unreadable current body'),
    ]);
    expect(
        UnknownIncomingBlocks.locate(
            evidence: evidence(),
            inspection: future,
            messages: [],
            sessionId: 'controlled-current-run',
            sessionStartedAt: startedAt,
            knownMediaParents: {
              const OcrVisualRegion(
                  x: .27,
                  y: .75,
                  width: .2,
                  height: .05,
                  confidence: 1): 'later-known-media'
            },
            frontier: {'id': 'later-known-media'}),
        isEmpty,
        reason:
            'The retired before-frontier rescue cannot admit a future clock.');
  });
}
