import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_acquisition_route.dart';

void main() {
  for (final kind in ['image', 'unknown']) {
    test('$kind valid rectangle cache miss never starts a context copy',
        () async {
      final calls = <String>[];
      final result = await ImageAcquisitionRoute.run<String, String>(
          kind: kind,
          hasValidatedRectangle: true,
          hasContextTarget: true,
          isCurrent: () => true,
          viaVision: () async {
            calls.add('vision-cache-miss');
            return null;
          },
          copyUnderUiLease: () async {
            calls.add('context-copy');
            return 'wrong-path';
          },
          compareInBackground: (bytes) async {
            calls.add('background');
            return bytes;
          });
      expect(result, isNull);
      expect(calls, ['vision-cache-miss']);
    });
  }

  test('copy is the only no-rectangle path and releases UI before comparison',
      () async {
    final copied = Completer<String?>();
    final copyStarted = Completer<void>();
    final comparisonStarted = Completer<void>();
    final comparisonFinished = Completer<String?>();
    final calls = <String>[];
    var uiHeld = false;
    final work = ImageAcquisitionRoute.run<String, String>(
        kind: 'unknown',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => true,
        viaVision: () async => fail('No image rectangle exists'),
        copyUnderUiLease: () async {
          uiHeld = true;
          calls.add('copy-start');
          copyStarted.complete();
          try {
            return await copied.future;
          } finally {
            calls.add('menu-clipboard-ui-released');
            uiHeld = false;
          }
        },
        compareInBackground: (bytes) async {
          expect(bytes, 'fresh-image-bytes');
          expect(uiHeld, isFalse);
          calls.add('compare-start');
          comparisonStarted.complete();
          return comparisonFinished.future;
        });
    await copyStarted.future;
    expect(calls, ['copy-start']);
    copied.complete('fresh-image-bytes');
    await comparisonStarted.future;
    expect(uiHeld, isFalse);
    // A response can own the UI while slow image matching is still running.
    calls.add('reply-uses-ui');
    comparisonFinished.complete('verified-original');
    expect(await work, 'verified-original');
    expect(calls, [
      'copy-start',
      'menu-clipboard-ui-released',
      'compare-start',
      'reply-uses-ui'
    ]);
  });

  for (final kind in ['video', 'text', 'unsupported']) {
    test('$kind never enters image acquisition even with an available target',
        () async {
      final result = await ImageAcquisitionRoute.run<String, String>(
          kind: kind,
          hasValidatedRectangle: true,
          hasContextTarget: true,
          isCurrent: () => fail('Non-image work belongs to its existing flow'),
          viaVision: () async => fail('Non-image vision'),
          copyUnderUiLease: () async => fail('Non-image context copy'),
          compareInBackground: (_) async => fail('Non-image comparison'));
      expect(result, isNull);
    });
  }

  test('missing rectangle and missing safe target do not invent a crop',
      () async {
    final result = await ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: false,
        hasContextTarget: false,
        isCurrent: () => true,
        viaVision: () async => fail('No rectangle'),
        copyUnderUiLease: () async => fail('No safe copy point'),
        compareInBackground: (_) async => fail('No copied image'));
    expect(result, isNull);
  });

  test('a stale or expired message never starts acquisition', () async {
    final result = await ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => false,
        viaVision: () async => fail('Stale vision'),
        copyUnderUiLease: () async => fail('Stale context copy'),
        compareInBackground: (_) async => fail('Stale comparison'));
    expect(result, isNull);
  });

  test('no fresh image from the menu does not run image matching', () async {
    var comparisons = 0;
    final result = await ImageAcquisitionRoute.run<String, String>(
        kind: 'unknown',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => true,
        viaVision: () async => fail('No rectangle'),
        copyUnderUiLease: () async => null,
        compareInBackground: (_) async {
          comparisons++;
          return 'unproven';
        });
    expect(result, isNull);
    expect(comparisons, 0);
  });

  test('expiry while copying discards the copied image before matching',
      () async {
    final copying = Completer<void>();
    final copied = Completer<String?>();
    var current = true;
    var comparisons = 0;
    final result = ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => current,
        viaVision: () async => fail('No rectangle'),
        copyUnderUiLease: () {
          copying.complete();
          return copied.future;
        },
        compareInBackground: (_) async {
          comparisons++;
          return 'late';
        });
    await copying.future;
    current = false;
    copied.complete('late-copy');
    expect(await result, isNull);
    expect(comparisons, 0);
  });

  test('a changed owner during background matching cannot return old results',
      () async {
    final matching = Completer<void>();
    final matched = Completer<String?>();
    var current = true;
    final result = ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: false,
        hasContextTarget: true,
        isCurrent: () => current,
        viaVision: () async => fail('No rectangle'),
        copyUnderUiLease: () async => 'fresh-copy',
        compareInBackground: (_) {
          matching.complete();
          return matched.future;
        });
    await matching.future;
    current = false;
    matched.complete('old-customer-original');
    expect(await result, isNull);
  });

  test('late vision result is discarded without using the context-copy path',
      () async {
    final visionStarted = Completer<void>();
    final vision = Completer<String?>();
    var current = true;
    final result = ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: true,
        hasContextTarget: true,
        isCurrent: () => current,
        viaVision: () {
          visionStarted.complete();
          return vision.future;
        },
        copyUnderUiLease: () async => fail('A valid rectangle owns this path'),
        compareInBackground: (_) async => fail('No context-copy image'));
    await visionStarted.future;
    current = false;
    vision.complete('late-image');
    expect(await result, isNull);
  });

  test('a vision error propagates without silently switching to context copy',
      () async {
    final result = ImageAcquisitionRoute.run<String, String>(
        kind: 'image',
        hasValidatedRectangle: true,
        hasContextTarget: true,
        isCurrent: () => true,
        viaVision: () async => throw StateError('source changed'),
        copyUnderUiLease: () async => fail('Valid rectangle did not disappear'),
        compareInBackground: (_) async => fail('No copied image'));
    await expectLater(result, throwsStateError);
  });
}
