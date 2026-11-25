import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_original_locator.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

const _customer = 'jd_image_owner';
final _sent = DateTime.utc(2026, 11, 11, 4, 0, 5);
Map<String, Object?> header(String text, double y) => {
      'text': text,
      'confidence': 1.0,
      'x': .26,
      'y': y,
      'width': .3,
      'height': .02,
    };
Map<String, Object?> rectangle(double x, double y, double w, double h) => {
      'x': x,
      'y': y,
      'width': w,
      'height': h,
      'confidence': 1.0,
    };
OcrInspection view(
        {String? customer = _customer,
        List<Map<String, Object?>> regions = const [],
        List<Map<String, Object?>>? headers,
        List<Map<String, Object?>>? physicalCards,
        Map<String, double>? bounds = const {
          'left': .24,
          'right': .75,
          'top': .2,
          'bottom': .81
        }}) =>
    OcrInspection.fromMap({
      'activeCustomerId': customer,
      'capturedAtMs':
          _sent.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      'imageWidth': 1440,
      'imageHeight': 810,
      'windowId': 1,
      if (bounds != null) 'chatRegion': bounds,
      'observations': headers ?? [header('$_customer 12:00:05', .3)],
      'visualRegions': regions,
      if (physicalCards != null) 'physicalMediaRegions': physicalCards,
    });

void main() {
  test('loading without a rectangle cannot become a synthetic crop', () {
    final loading = ImageOriginalLocator.locate(view(), _customer, _sent);
    expect(loading, isEmpty);
    final loaded = ImageOriginalLocator.locate(
        view(regions: [rectangle(.28, .35, .2, .2)]), _customer, _sent);
    expect(loaded, hasLength(1));
    expect(loaded.single.x, .28);
    expect(loaded.single.y, .35);
    expect(loaded.single.height, closeTo(.2, .000001));
    expect(loaded.single.width, .2);
  });

  test('timestamp-owned physical crop wins over the wide message body', () {
    final card = {
      ...rectangle(.26632, .34563, .06076, .18635),
      'proof': 'full_card_pixels',
    };
    final wideBody = rectangle(.26744, .337, .42, .24);
    final inspection = view(headers: [
      header('$_customer 12:00:05', .32),
      header('$_customer 12:00:08', .56),
    ], regions: [
      wideBody
    ], physicalCards: [
      card
    ]);
    final exact = ImageOriginalLocator.locate(inspection, _customer, _sent);
    expect(exact.single.width, closeTo(.06076, .00001));
    expect(
        ImageOriginalLocator.locate(
            view(regions: [wideBody], physicalCards: []), _customer, _sent),
        isEmpty);
    final clipped = {
      ...rectangle(.26632, .238, .0594, .06027),
      'proof': 'full_card_pixels',
    };
    expect(
        ImageOriginalLocator.locate(
            view(
                headers: [header('$_customer 12:00:08', .36)],
                regions: [wideBody],
                physicalCards: [clipped]),
            _customer,
            _sent),
        isEmpty);
  });

  test('a different second image cannot become this target', () {
    final inspection = view(
        headers: [header('$_customer 12:00:15', .3)],
        regions: [rectangle(.28, .35, .2, .2)]);
    expect(ImageOriginalLocator.locate(inspection, _customer, _sent), isEmpty);
  });

  test('a newer rectangle cannot provide a crop for an older target', () {
    final inspection = view(headers: [
      header('$_customer 12:00:05', .3),
      header('格志打印机小耿 12:00:10', .55),
      header('$_customer 12:00:15', .65),
    ], regions: [
      rectangle(.28, .69, .2, .10)
    ]);
    final target = ImageOriginalLocator.locate(inspection, _customer, _sent);
    expect(target, isEmpty);
    final copy =
        ImageOriginalLocator.contextCopyTarget(inspection, _customer, _sent);
    expect(copy, isNotNull);
    expect(copy!.y, lessThan(.55));
  });

  test('customer identity must match exactly and every chat side must exist',
      () {
    expect(
        ImageOriginalLocator.locate(
            view(customer: 'JD_IMAGE_OWNER'), _customer, _sent),
        isEmpty);
    expect(ImageOriginalLocator.locate(view(customer: null), _customer, _sent),
        isEmpty);
    expect(ImageOriginalLocator.locate(view(bounds: null), _customer, _sent),
        isEmpty);
    expect(
        ImageOriginalLocator.locate(
            view(bounds: const {
              'left': .75,
              'right': .24,
              'top': .2,
              'bottom': .81,
            }),
            _customer,
            _sent),
        isEmpty);
  });

  test('a context hit stays inside actual narrow chat bounds', () {
    final inspection = view(bounds: const {
      'left': .24,
      'right': .34,
      'top': .2,
      'bottom': .6,
    }, headers: [
      {...header('$_customer 12:00:05', .3), 'width': .05},
    ], regions: [
      rectangle(.25, .58, .08, .2)
    ]);
    final target = ImageOriginalLocator.locate(inspection, _customer, _sent);
    expect(target, isEmpty);
    final copy =
        ImageOriginalLocator.contextCopyTarget(inspection, _customer, _sent);
    expect(copy, isNotNull);
    expect(copy!.x, greaterThanOrEqualTo(.24));
    expect(copy.x, lessThan(.34));
    expect(copy.y, lessThan(.6));
  });
}
