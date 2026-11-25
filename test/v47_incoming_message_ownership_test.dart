import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/incoming_message_blocks.dart';
import 'package:jd_automation/capture/incoming_message_ownership.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const _folder = 'test/fixtures/v47_video_owner_boundary';
const _customer = 'jd_41aeec7741d05';
const _session = 'v47-current-session';
final _start = DateTime.utc(2026, 11, 10, 4, 21, 31);
typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection view,
  Map<String, Object?> raw
});

Future<_Frame> _frame(String name) async {
  final provenance =
      jsonDecode(await File('$_folder/provenance.json').readAsString()) as Map;
  final source = provenance['frames'][name] as Map;
  final bytes = await File('$_folder/$name.png').readAsBytes();
  final ocr = await File('$_folder/$name.ocr.json').readAsBytes();
  final capture = await File('$_folder/$name.capture.json').readAsBytes();
  expect(sha256.convert(bytes).toString(), source['pngSHA256']);
  expect(sha256.convert(ocr).toString(), source['ocr.jsonSHA256']);
  expect(sha256.convert(capture).toString(), source['capture.jsonSHA256']);
  final raw = <String, Object?>{
    ...Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map),
    'pngBase64': base64Encode(bytes),
  };
  return (
    evidence: ViewportEvidence({
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map),
      'automationSessionId': _session,
    }),
    view: OcrInspection.fromMap(raw),
    raw: raw
  );
}

OcrVisualRegion _card(_Frame frame) =>
    frame.view.visualRegions.firstWhere((r) =>
        r.x > .25 && r.x < .3 && r.y > .3 && r.width > .15 && r.height > .17);

Map<OcrVisualRegion, String> _arrivals(_Frame f, OcrVisualRegion card,
    {ViewportEvidence? evidence,
    OcrInspection? view,
    Map? frontier,
    bool originalFrontier = true}) {
  final actual = view ?? f.view;
  return LiveMediaArrival.infer(
      evidence: evidence ?? f.evidence,
      inspection: actual,
      cards: [card],
      headers: {
        card: const OcrCaptureExtractor().mediaClockForRegion(actual, card)
      },
      knownParents: const {},
      visibleText:
          const OcrCaptureExtractor().extract(actual)?.messages ?? const [],
      frontier: originalFrontier
          ? (frontier ?? f.evidence.metadata['admissionFrontier'] as Map?)
          : frontier,
      sessionStartedAt: _start);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'recorded weak sender locates the first video without guessing its ID or clock',
      () async {
    final f = await _frame('cc8e');
    final card = _card(f);
    final proof = IncomingMessageOwnership.inspect(f.view, _customer, card,
        physicalCards: [card])!;
    expect(proof.header.text.startsWith('io_'), isTrue);
    expect(proof.exactCustomerHeader, isFalse);
    expect(proof.sentAt, isNull);
    expect(proof.uniquePhysicalCard, isTrue);
    expect(proof.explicitVideo, isTrue);
    final clock = const OcrCaptureExtractor().mediaClockForRegion(f.view, card);
    expect(clock.source, 'visual_incoming_sender_block');
    expect(clock.sentAt, isNull);
    expect(_arrivals(f, card).keys, [card],
        reason: 'The real new block is below the frozen visible A4 question.');
  });

  test(
      'recorded outer ROI and wide holder agree with the actual video contents',
      () async {
    final f = await _frame('d3e2');
    final card = _card(f);
    final wide = const OcrCaptureExtractor()
        .incomingMessageBlocks(f.view)
        .singleWhere((b) => b.sentAt == DateTime.utc(2026, 11, 10, 4, 27, 11));
    final a = IncomingMessageOwnership.inspect(f.view, _customer, card,
        physicalCards: [card, wide.region])!;
    final b = IncomingMessageOwnership.inspect(f.view, _customer, wide.region,
        physicalCards: [card, wide.region])!;
    expect(card.y, lessThan(a.header.y));
    expect(a.sameBlockAs(b), isTrue);
    expect(a.exactCustomerHeader, isTrue);
    expect(a.sentAt, DateTime.utc(2026, 11, 10, 4, 27, 11));
    expect(a.mediaContentRegion.y, greaterThan(a.header.y + a.header.height));
    expect(const OcrCaptureExtractor().mediaClockForRegion(f.view, card).source,
        'ocr_media_sender_header');
    expect(_arrivals(f, card).keys, [card]);
    expect(
        UnknownIncomingBlocks.locate(
                evidence: f.evidence,
                inspection: f.view,
                messages:
                    const OcrCaptureExtractor().extract(f.view)?.messages ??
                        const [],
                sessionId: _session,
                sessionStartedAt: _start,
                mediaRegions: [card],
                frontier: f.evidence.metadata['admissionFrontier'] as Map?)
            .any((b) => b.sentAt == wide.sentAt),
        isFalse);
    final restored = IncomingMessageOwnershipEvidence.fromMap(a.toMap());
    expect(restored.toMap(), a.toMap());
    expect(restored.sameBlockAs(a), isFalse,
        reason: 'Stored JSON alone is not a same-frame pixel proof.');
    expect(
        UnknownMessageClarifier.match(
            customer: _customer,
            original: f.view,
            originalRegion: wide.region,
            current: f.view,
            messages: const [],
            excludedRegions: [card]),
        isNull);
  });

  test(
      'weak sender admission still needs current AX, a real frontier or exact first-live proof',
      () async {
    final f = await _frame('cc8e');
    final card = _card(f);
    expect(_arrivals(f, card, originalFrontier: false), isEmpty);
    final noVisibleFrontier = OcrInspection.fromMap({
      ...f.raw,
      'observations': (f.raw['observations'] as List)
          .where(
              (line) => (line as Map)['text'] != 'is it support a4 size paper?')
          .toList()
    });
    expect(_arrivals(f, card, view: noVisibleFrontier), isEmpty);
    for (final changes in [
      {'replyActivationAllowed': false},
      {'historyCutoffMs': f.evidence.capturedAt.millisecondsSinceEpoch},
    ]) {
      expect(
          _arrivals(f, card,
              evidence: ViewportEvidence({...f.evidence.metadata, ...changes})),
          isEmpty);
    }
    final wrongCustomer = OcrInspection.fromMap(
        {...f.raw, 'activeCustomerId': 'another_customer'});
    expect(IncomingMessageOwnership.inspect(wrongCustomer, _customer, card),
        isNull);
  });

  test(
      'strict first-live bottom proof admits only the latest unique weak play block',
      () async {
    final f = await _frame('cc8e');
    final card = _card(f);
    final first = ViewportEvidence({
      ...f.evidence.metadata,
      'admissionFrontier': null,
      'discoveryAnchorId': f.evidence.id,
      'verifiedLiveBottom': true,
      'capturePurpose': 'live_signal',
      'navigationCutoffSource': 'current_viewport'
    });
    expect(_arrivals(f, card, evidence: first, originalFrontier: false),
        isNotEmpty);
    for (final changes in [
      {'verifiedLiveBottom': false},
      {'discoveryAnchorId': 'another-frame'},
      {'capturePurpose': 'discovery_baseline'},
      {'captureRequestedBackfill': true},
      {'unreadArrivalKey': null},
    ]) {
      expect(
          _arrivals(f, card,
              evidence: ViewportEvidence({...first.metadata, ...changes}),
              originalFrontier: false),
          isEmpty,
          reason: '$changes');
    }
    final laterText = OcrInspection.fromMap({
      ...f.raw,
      'observations': [
        ...(f.raw['observations'] as List),
        {
          'text': '$_customer 12:26:17',
          'confidence': 1.0,
          'x': .273,
          'y': .74,
          'width': .14,
          'height': .018
        },
        {
          'text': 'new question',
          'confidence': 1.0,
          'x': .28,
          'y': .77,
          'width': .12,
          'height': .017
        },
      ]
    });
    expect(
        _arrivals(f, card,
            evidence: first, view: laterText, originalFrontier: false),
        isEmpty);
  });

  test('untyped nonplay material only preserves original deferred provenance',
      () async {
    final f = await _frame('cc8e');
    final card = _card(f);
    final noPlay =
        OcrInspection.fromMap({...f.raw, 'unboundMediaRegions': <Object>[]});
    expect(IncomingMessageOwnership.inspect(noPlay, _customer, card), isNull);
    expect(_arrivals(f, card, view: noPlay), isEmpty);
    Map<OcrVisualRegion, Map<String, Object?>> deferred(
            ViewportEvidence evidence,
            {Map? frontier,
            String session = _session}) =>
        LiveMediaArrival.deferredCandidates(
            evidence: evidence,
            inspection: noPlay,
            cards: [card],
            knownParents: const {},
            sessionId: session,
            sessionStartedAt: _start,
            frontier:
                frontier ?? f.evidence.metadata['admissionFrontier'] as Map?);
    final source = deferred(f.evidence)[card]!;
    expect(source['admissionGranted'], isFalse);
    expect(source['evidenceId'], f.evidence.id);
    expect(source['region'], [card.x, card.y, card.width, card.height]);
    expect(
        source['capturedAt'], f.evidence.capturedAt.toUtc().toIso8601String());
    expect(deferred(f.evidence, session: 'old-session'), isEmpty);
    for (final changes in [
      {'unreadArrivalKey': null},
      {'replyActivationAllowed': false},
      {'historyCutoffMs': f.evidence.capturedAt.millisecondsSinceEpoch},
      {'captureRequestedBackfill': true},
    ]) {
      expect(deferred(ViewportEvidence({...f.evidence.metadata, ...changes})),
          isEmpty);
    }
  });

  test('dividers and printed photo headers cannot manufacture a new block',
      () async {
    final f = await _frame('cc8e');
    final card = _card(f);
    final withDivider = OcrInspection.fromMap({
      ...f.raw,
      'observations': [
        ...(f.raw['observations'] as List),
        {
          'text': '以下为新消息',
          'confidence': .5,
          'x': .45,
          'y': .402,
          'width': .12,
          'height': .01
        },
      ]
    });
    expect(_arrivals(f, card, view: withDivider), isEmpty);
    final printedHeader = OcrInspection.fromMap({
      ...f.raw,
      'observations': [
        ...(f.raw['observations'] as List),
        {
          'text': '$_customer 12:26:19',
          'confidence': 1.0,
          'x': .28,
          'y': .50,
          'width': .12,
          'height': .018
        },
      ]
    });
    final proof =
        IncomingMessageOwnership.inspect(printedHeader, _customer, card)!;
    expect(proof.header.text.startsWith('io_'), isTrue);
    expect(proof.exactCustomerHeader, isFalse);
    expect(proof.sentAt, isNull);
  });
}
