import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_card_occurrence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const _customer = 'buyer';
const _video =
    OcrVisualRegion(x: .28, y: .44, width: .12, height: .25, confidence: 1);

OcrObservation _line(String text, double y) => OcrObservation(
    text: text, confidence: 1, x: .27, y: y, width: .4, height: .015);

OcrInspection _view({
  double shift = 0,
  OcrVisualRegion card = _video,
  bool play = true,
  String clock = '11:44:00',
  List<OcrObservation> extra = const [],
  List<OcrVisualRegion> extraCards = const [],
  String previous = '11:43:25 格志打印机小耿',
}) =>
    OcrInspection(
      image: Uint8List(0),
      imageWidth: 1000,
      imageHeight: 1000,
      windowTitle: '',
      recognizedText: '',
      capturedAt: DateTime.utc(2026, 11, 9),
      activeCustomerId: _customer,
      chatLeft: .24,
      chatRight: .75,
      chatTop: .2,
      chatBottom: .8,
      visualRegions: [card, ...extraCards],
      unboundMediaRegions: play ? [card] : [],
      observations: [
        _line(previous, .3 + shift),
        _line('What do you need help with on your M880?', .34 + shift),
        _line('$_customer $clock', .4 + shift),
        ...extra,
      ],
    );

MediaCardOccurrenceContext _context(OcrInspection view, OcrVisualRegion card) =>
    MediaCardOccurrenceContext.inspect(view, _customer, card);

void main() {
  test('one video retains its sender block across loaded and clipped covers',
      () {
    final first = _context(_view(), _video);
    const loaded = OcrVisualRegion(
        x: .281, y: .43, width: .119, height: .27, confidence: 1);
    final second = _context(_view(card: loaded), loaded);
    expect(second.continuesVideo(first), isTrue);

    const clipped = OcrVisualRegion(
        x: .282, y: .59, width: .112, height: .10, confidence: 1);
    final last =
        _context(_view(shift: .15, card: clipped, play: false), clipped);
    expect(last.continuesVideo(second), isTrue,
        reason: 'Immutable sender and preceding prose move with the card; '
            'a late crop is not another message');
  });

  test('ordinary image receives no new structural merge rule', () {
    final first = _context(_view(play: false), _video);
    final next = _context(_view(play: false), _video);
    expect(next.continuesVideo(first), isFalse);
    expect(next.continuesVideo(first, verifiedVideoParent: true), isTrue,
        reason: 'Only a separately proved video owner can enable this proof');
  });

  test('clock equality cannot join two independently visible sender bubbles',
      () {
    const lower =
        OcrVisualRegion(x: .28, y: .65, width: .12, height: .11, confidence: 1);
    final frame =
        _view(extra: [_line('buyer 11:44:00', .61)], extraCards: [lower]);
    expect(_context(frame, lower).continuesVideo(_context(frame, _video)),
        isFalse);
    expect(_context(frame, lower).continuesVideo(_context(_view(), _video)),
        isFalse,
        reason: 'A same-second second header is still a distinct occurrence');
  });

  test('same-second resend with a different preceding boundary stays separate',
      () {
    final original = _context(_view(), _video);
    final resend = _context(_view(previous: 'buyer 11:44:00'), _video);
    expect(resend.continuesVideo(original), isFalse,
        reason: 'A clock and same pixels cannot replace sender-block ancestry');
  });

  test('another sender clock is a new message even for identical video pixels',
      () {
    final original = _context(_view(), _video);
    final resend = _context(_view(clock: '11:44:01'), _video);
    expect(resend.continuesVideo(original), isFalse);
  });

  test('two cards under one header remain independent same-second slots', () {
    const lower =
        OcrVisualRegion(x: .28, y: .69, width: .12, height: .07, confidence: 1);
    final frame = _view(extraCards: [lower]);
    final first = _context(frame, _video), second = _context(frame, lower);
    expect(first.toMap()['cardCount'], 2);
    expect(second.toMap()['cardCount'], 2);
    expect(second.continuesVideo(first), isFalse);
  });

  test('summary chrome cannot prove a continuation across its divider', () {
    final before = _context(_view(extra: [_line('上次会话小结', .72)]), _video);
    const after =
        OcrVisualRegion(x: .28, y: .69, width: .12, height: .07, confidence: 1);
    final inSummary =
        _context(_view(card: after, extra: [_line('上次会话小结', .61)]), after);
    expect(inSummary.continuesVideo(before), isFalse);
  });

  test('unrelated preceding prose cannot establish the same video owner', () {
    final original = _context(_view(), _video);
    final different = _view().withObservations([
      _line('11:43:25 格志打印机小耿', .3),
      _line('A different earlier conversation about an order', .34),
      _line('buyer 11:44:00', .4),
    ]);
    expect(_context(different, _video).continuesVideo(original), isFalse);
  });

  test('nested play/thumbnail detector crops are one visible card slot', () {
    const play =
        OcrVisualRegion(x: .31, y: .51, width: .04, height: .05, confidence: 1);
    final full = _view(extraCards: [play]);
    expect(_context(full, _video).toMap()['cardCount'], 1);
    expect(_context(full, _video).continuesVideo(_context(_view(), _video)),
        isTrue);
  });
}
