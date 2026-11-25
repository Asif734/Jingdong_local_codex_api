import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache progress has no identity, media payload or UI operation',
      () async {
    const channel = MethodChannel('jd-v38-cache-progress');
    final calls = <MethodCall>[];
    final values = <Map<String, Object?>>[
      {'revision': 'unchanged'},
      {'revision': 'unchanged'},
      {'revision': 'new-cache-metadata'},
      {},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return values.removeAt(0);
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final adapter = MacOSCaptureAdapter(channel: channel);
    expect(await adapter.recentMediaCacheRevision(), 'unchanged');
    expect(await adapter.recentMediaCacheRevision(), 'unchanged');
    expect(await adapter.recentMediaCacheRevision(), 'new-cache-metadata');
    expect(await adapter.recentMediaCacheRevision(), isNull);
    expect(calls.every((call) => call.method == 'recentMediaCacheRevision'),
        isTrue);
    expect(calls.every((call) => call.arguments == null), isTrue);
  });

  test('a caller timeout does not stack metadata probes', () async {
    const channel = MethodChannel('jd-v38-cache-single-flight');
    var calls = 0;
    final native = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return native.future;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final adapter = MacOSCaptureAdapter(channel: channel);
    final first = adapter.recentMediaCacheRevision();
    await expectLater(first.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()));
    final second = adapter.recentMediaCacheRevision();
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    native.complete({'revision': 'download-progress'});
    expect(await second, 'download-progress');
    expect(await adapter.recentMediaCacheRevision(), 'download-progress');
    expect(calls, 2);
  });
}
