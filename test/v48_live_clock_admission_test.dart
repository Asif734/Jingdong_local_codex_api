import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/ui/customer_message_timeline.dart';

void main() {
  const customer = 'jd_clock_buyer';
  final at = DateTime.utc(2026, 11, 10, 5, 40, 13);
  final view = OcrInspection.fromMap({
    'activeCustomerId': customer,
    'windowId': 1,
    'capturedAtMs': at.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
    'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .8},
    'observations': [
      {
        'text': '$customer 13:40:13',
        'confidence': 1,
        'x': .27,
        'y': .3,
        'width': .25,
        'height': .015,
      },
      {
        'text': 'regarding td630',
        'confidence': 1,
        'x': .28,
        'y': .34,
        'width': .2,
        'height': .02,
      },
    ],
  });
  Map<String, Object?> frame(Map<String, Object?> metadata) => {
        'customer': customer,
        'capturedAtMs':
            at.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
        'automationSessionId': 'controlled-v48-current-run',
        'automationSessionStartedAtMs':
            at.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch,
        'capturePurpose': 'active_discovery',
        ...metadata,
      };

  test('later complete clock admits live text after its anchor scrolls away',
      () {
    final capture = const OcrCaptureExtractor().analyze(view).capture!;
    final incoming = capture.messages.where((m) => m.direction == 'incoming');
    final frontier = {
      'id': 'offscreen-previous-message',
      'sent_at': at.subtract(const Duration(seconds: 6)).toIso8601String(),
    };
    Set<String> admit(Map<String, Object?> metadata) =>
        LiveMediaArrival.textInputs(
            evidence: ViewportEvidence(frame(metadata)),
            inspection: view,
            messages: capture.messages,
            existingIds: {},
            frontier: frontier);

    expect(admit({'replyActivationAllowed': true}),
        incoming.map((m) => m.stableId).toSet());
    expect(
        LiveMediaArrival.textInputs(
            evidence: ViewportEvidence(frame({
              'replyActivationAllowed': true,
            })),
            inspection: view,
            messages: capture.messages,
            existingIds: {},
            frontier: {
              'id': 'unclocked-media-placeholder',
              'visibleTextAnchors': [
                {
                  'direction': 'incoming',
                  'sent_at':
                      at.subtract(const Duration(seconds: 6)).toIso8601String(),
                },
                {
                  'direction': 'outgoing',
                  'sent_at':
                      at.add(const Duration(seconds: 3)).toIso8601String(),
                },
              ],
            }),
        incoming.map((m) => m.stableId).toSet(),
        reason: 'A holding reply must not hide an earlier customer question.');
    expect(admit({'replyActivationAllowed': false}), isEmpty);
    expect(
        admit({
          'replyActivationAllowed': false,
          'historyCutoffMs': at.millisecondsSinceEpoch,
          'capturePurpose': 'history_backfill',
        }),
        isEmpty,
        reason:
            'A history page still needs frozen current-run reply authorization.');
    expect(admit({'replyActivationAllowed': true, 'automationSessionId': null}),
        isEmpty);
    expect(
        LiveMediaArrival.textInputs(
            evidence: ViewportEvidence(frame({
              'customer': 'another-customer',
              'replyActivationAllowed': true,
            })),
            inspection: view,
            messages: capture.messages,
            existingIds: {},
            frontier: frontier),
        isEmpty);
  });

  test('timeline clock matches JD HH:mm:ss independently of Mac timezone', () {
    expect(CustomerMessageTimeline.formatTime(at), '11-10 13:40:13');
  });
}
