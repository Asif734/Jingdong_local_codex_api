import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'timed-out exact cache request stays singleflight until native completes',
      () async {
    const channel = MethodChannel('v48-cache-singleflight-unit');
    final native = Completer<Map<String, Object?>>();
    final arguments = <Map>[];
    final at = DateTime.utc(2026, 1, 1);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureRecentCachedMedia');
      final args = Map.from(call.arguments as Map);
      arguments.add(args);
      if (args['expectedCustomer'] == 'verified-customer' &&
          args['expectedMediaAtMs'] == at.millisecondsSinceEpoch &&
          args['destinationDirectory'] == '/unit/cache-a') {
        return native.future;
      }
      return {'kind': 'none'};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(() {
      if (!native.isCompleted) native.complete({'kind': 'none'});
    });
    addTearDown(adapter.close);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    Future<CachedMediaPayload?> exact() => adapter.captureRecentCachedMedia(
        expectedCustomer: 'verified-customer',
        expectedMediaAt: at,
        destinationDirectory: '/unit/cache-a');
    final first = exact();
    await expectLater(
        first.timeout(Duration.zero), throwsA(isA<TimeoutException>()));
    final retry = exact();
    expect(identical(first, retry), isTrue);
    expect(arguments, hasLength(1));
    await adapter.captureRecentCachedMedia(
        expectedCustomer: 'other-customer',
        expectedMediaAt: at,
        destinationDirectory: '/unit/cache-a');
    await adapter.captureRecentCachedMedia(
        expectedCustomer: 'verified-customer',
        expectedMediaAt: at.add(const Duration(milliseconds: 1)),
        destinationDirectory: '/unit/cache-a');
    await adapter.captureRecentCachedMedia(
        expectedCustomer: 'verified-customer',
        expectedMediaAt: at,
        destinationDirectory: '/unit/cache-b');
    expect(arguments, hasLength(4),
        reason:
            'Customer, original-media boundary and destination all scope native ownership');
    native.complete({'kind': 'none'});
    expect(await retry, isNull);
    expect(await exact(), isNull);
    expect(arguments, hasLength(5),
        reason:
            'Completed scans are not cached; a later actual cache update is re-read');
  });
}
