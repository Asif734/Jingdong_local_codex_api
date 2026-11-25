import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_original_locator.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const buyer = 'jd_copy_owner';
final sender = DateTime.utc(2026, 11, 12, 2, 46, 51);

Map<String, Object?> line(String text, double y,
        {double x = .273,
        double width = .15,
        double height = .018,
        double confidence = 1,
        bool watermark = false}) =>
    {
      'text': text,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'confidence': confidence,
      'isWatermark': watermark,
    };

Map<String, Object?> box(double x, double y, double width, double height) => {
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'confidence': 1,
    };

OcrInspection frame({
  String? active = buyer,
  List<Map<String, Object?>>? observations,
  List<Map<String, Object?>> rectangles = const [],
  List<Map<String, Object?>> video = const [],
  double? bottom = .792,
  int width = 2880,
  int height = 1626,
}) =>
    OcrInspection.fromMap({
      'activeCustomerId': active,
      'capturedAtMs':
          sender.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
      'imageWidth': width,
      'imageHeight': height,
      'chatRegion': {'left': .24, 'right': .748, 'top': .2, 'bottom': bottom},
      'observations': observations ?? [line('$buyer 10:46:51', .465)],
      'visualRegions': rectangles,
      'unboundMediaRegions': [
        for (final region in video)
          {...region, 'proof': 'explicit_play_overlay'}
      ],
    });

void main() {
  test('a missing detector rectangle supplies a header hit, never a crop', () {
    final view = frame();
    expect(ImageOriginalLocator.locate(view, buyer, sender), isEmpty);
    final target = ImageOriginalLocator.contextCopyTarget(view, buyer, sender)!;
    expect(target.x, closeTo(.273 + 8 / 2880, 1e-12));
    expect(target.y, closeTo(.465 + .018 + .004 + 8 / 1626, 1e-12));
    expect(target.x, lessThan(.29),
        reason: 'The message-block centre must never become a right-click.');
    expect(target.y, lessThan(target.bodyTop + .01));
    expect(target.toMap().keys,
        containsAll(['pointX', 'pointY', 'header', 'chat']));
    expect(target.toMap().keys, isNot(contains('width')));
  });

  test('a valid first-path rectangle vetoes any context-copy fallback', () {
    final view = frame(rectangles: [box(.274, .491, .10, .20)]);
    expect(ImageOriginalLocator.locate(view, buyer, sender), hasLength(1));
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  test(
      'after image classification, a cache miss permits a hit inside its rectangle',
      () {
    final view = frame(rectangles: [box(.274, .491, .10, .20)]);
    final region = ImageOriginalLocator.locate(view, buyer, sender).single;
    final target = ImageOriginalLocator.contextCopyTarget(view, buyer, sender,
        confirmedRegion: region)!;
    expect(target.x, inExclusiveRange(region.x, region.x + region.width));
    expect(target.y, inExclusiveRange(region.y, region.y + region.height));
    expect(
        ImageOriginalLocator.contextCopyTarget(
            view, buyer, sender.add(const Duration(seconds: 1)),
            confirmedRegion: region),
        isNull);
  });

  test('a zero-confidence synthetic region cannot become a real crop', () {
    final view = frame(rectangles: [
      {...box(.274, .491, .10, .20), 'confidence': 0}
    ]);
    expect(ImageOriginalLocator.locate(view, buyer, sender), isEmpty);
    expect(
        ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNotNull);
  });

  test('a rectangle for another sender second cannot prevent this copy hit',
      () {
    final view = frame(observations: [
      line('$buyer 10:46:51', .3),
      line('格志打印机小耿 10:47:00', .5),
      line('$buyer 10:47:10', .6),
    ], rectangles: [
      box(.274, .63, .15, .12)
    ]);
    expect(ImageOriginalLocator.locate(view, buyer, sender), isEmpty);
    final target = ImageOriginalLocator.contextCopyTarget(view, buyer, sender)!;
    expect(target.y, lessThan(.5));
    expect(target.bodyBottom, lessThan(.5));
  });

  test('new messages shifting the target move the hit with its own header', () {
    final before = ImageOriginalLocator.contextCopyTarget(
        frame(observations: [line('$buyer 10:46:51', .5)]), buyer, sender)!;
    final after = ImageOriginalLocator.contextCopyTarget(
        frame(observations: [
          line('$buyer 10:46:51', .3),
          line('$buyer 10:47:01', .6),
        ]),
        buyer,
        sender)!;
    expect(before.y - after.y, closeTo(.2, 1e-12));
    expect(after.header.text, '$buyer 10:46:51');
    expect(after.y, lessThan(.6));
  });

  test('duplicate matching sender clocks are ambiguous and never clicked', () {
    final view = frame(observations: [
      line('$buyer 10:46:51', .3),
      line('$buyer 10:46:51', .6),
    ]);
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  test('an unmatched clock cannot use the newest available header', () {
    final view = frame(observations: [line('$buyer 10:46:52', .465)]);
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  for (final active in [null, 'JD_COPY_OWNER', 'different_customer']) {
    test('AX identity $active cannot borrow the target header', () {
      expect(
          ImageOriginalLocator.contextCopyTarget(
              frame(active: active), buyer, sender),
          isNull);
    });
  }

  test('a visible ordinary first text line does not authorize a context copy',
      () {
    for (final body in ['OK', '请问保修多久？', 'How long is the warranty?']) {
      final view = frame(observations: [
        line('$buyer 10:46:51', .465),
        line(body, .49, x: .28, height: .017),
      ]);
      expect(
          ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
    }
  });

  test('tiny text printed in a screenshot does not become ordinary prose', () {
    final view = frame(observations: [
      line('$buyer 10:46:51', .465),
      line('10:46', .493, x: .28, height: .002),
      line('添加发票抬头', .502, x: .29, height: .003),
    ]);
    expect(
        ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNotNull);
  });

  test('a known video play region cannot take the image-copy fallback', () {
    final view = frame(video: [box(.275, .491, .025, .04)]);
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  test('a newly appeared next sender removes an obsolete tiny hit area', () {
    final view = frame(observations: [
      line('$buyer 10:46:51', .465),
      line('格志打印机小耿 10:46:52', .491),
    ]);
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  test('the bottom font toolbar excludes its own target point', () {
    final view = frame(bottom: .81, observations: [
      line('$buyer 10:46:51', .755),
      line('Aa', .783, x: .37, width: .02, height: .014),
      line('发送', .783, x: .58, width: .02, height: .014),
    ]);
    expect(ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNull);
  });

  test('invalid image dimensions cannot define a physical inset', () {
    expect(
        ImageOriginalLocator.contextCopyTarget(frame(width: 0), buyer, sender),
        isNull);
    expect(
        ImageOriginalLocator.contextCopyTarget(frame(height: 0), buyer, sender),
        isNull);
  });

  test('the copied target remains within a narrow but valid chat pane', () {
    final view = OcrInspection.fromMap({
      'activeCustomerId': buyer,
      'capturedAtMs': sender.millisecondsSinceEpoch,
      'imageWidth': 1440,
      'imageHeight': 810,
      'chatRegion': {'left': .24, 'right': .34, 'top': .2, 'bottom': .6},
      'observations': [line('$buyer 10:46:51', .3, x: .26, width: .05)],
    });
    final target = ImageOriginalLocator.contextCopyTarget(view, buyer, sender)!;
    expect(target.x, inExclusiveRange(.24, .34));
    expect(target.y, lessThan(.6));
  });

  test('watermarks do not define a second target or an ordinary body', () {
    final view = frame(observations: [
      line('$buyer 10:46:51', .465),
      line('$buyer 10:46:51', .65, watermark: true),
      line('格志打印机小耿', .492, watermark: true),
    ]);
    expect(
        ImageOriginalLocator.contextCopyTarget(view, buyer, sender), isNotNull);
  });

  test('a narrow invoice layout anchors inside its physical thumbnail', () {
    final view = frame(observations: [
      line('$buyer 10:46:51', 756.5706942490523 / 1626,
          x: 786.9767479027826 / 2880,
          width: 351.62789916992193 / 2880,
          height: 29.42930603027356 / 1626),
    ]);
    final target = ImageOriginalLocator.contextCopyTarget(view, buyer, sender)!;
    expect(ImageOriginalLocator.locate(view, buyer, sender), isEmpty);
    expect(target.x * view.imageWidth, inInclusiveRange(788, 928));
    expect(target.y * view.imageHeight, inInclusiveRange(798, 1098));
  });
}
