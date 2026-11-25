import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_capture_pump.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';

// Pure scheduling/storage tests. No recorded screenshot, native app, OCR,
// CaptureHome, customer UI, or conversation replay is involved.
void main() {
  late Directory root;
  late ViewportCapturePump pump;
  final releaseOnCleanup = <void Function()>[];
  var epoch = 1;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v48_pump_unit_');
    pump = ViewportCapturePump();
    epoch = 1;
    releaseOnCleanup.clear();
  });
  tearDown(() async {
    epoch++;
    for (final release in releaseOnCleanup) {
      release();
    }
    await pump.whenIdle;
    await root.delete(recursive: true);
  });
  ViewportEvidence frame(String id, {int at = 100, String customer = 'a'}) =>
      ViewportEvidence({
        'evidenceId': id,
        'customer': customer,
        'capturedAtMs': at,
        'pngSHA256': id,
        'chatContentSHA256': id,
        'automationSessionId': 'run-$epoch'
      });
  void begin(int run,
      Future<void> Function(ViewportEvidence, Map<String, Object?>) consume) {
    pump.begin(
        epoch: run,
        sessionId: 'run-$run',
        directory: root,
        current: () => epoch == run,
        consume: consume,
        onError: (error) => fail('$error'));
  }

  test('slow native stays singleflight and passive ticks never queue requests',
      () async {
    begin(1, (_, __) async {});
    final native = Completer<ViewportEvidence>();
    releaseOnCleanup.add(() {
      if (!native.isCompleted) native.complete(frame('cleanup'));
    });
    var started = 0;
    final first = pump.capture(
        wait: false,
        current: () => true,
        native: () {
          started++;
          return native.future;
        });
    for (var i = 0; i < 20; i++) {
      expect(
          await pump.capture(
              wait: false,
              current: () => true,
              native: () async {
                started++;
                return frame('forbidden');
              }),
          isNull);
    }
    expect(started, 1);
    native.complete(frame('first'));
    expect((await first)!.id, 'first');
    expect(
        (await pump.capture(
                wait: false,
                current: () => true,
                native: () async {
                  started++;
                  return frame('second');
                }))!
            .id,
        'second');
    expect(started, 2);
  });

  test('blocked metadata consumer does not stop raw frames landing on disk',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    releaseOnCleanup.add(() {
      if (!release.isCompleted) release.complete();
    });
    final consumed = Completer<void>();
    final seen = <String>[];
    begin(1, (evidence, _) async {
      seen.add(evidence.id);
      if (evidence.id == 'first') {
        entered.complete();
        await release.future;
      }
      if (evidence.id == 'later') consumed.complete();
    });
    await pump.save(1, frame('first'), {'frontier': 'old', 'epoch': 1});
    await entered.future;
    await pump
        .save(1, frame('later', at: 102), {'frontier': 'old', 'epoch': 1});
    await pump
        .save(1, frame('second', at: 101), {'frontier': 'old', 'epoch': 1});
    final pending = await Directory('${root.path}/raw_inbox/run-1')
        .list()
        .where((e) => e.path.endsWith('.pending.json'))
        .toList();
    expect(pending, hasLength(3));
    expect(seen, ['first']);
    release.complete();
    await consumed.future;
    expect(seen, ['first', 'second', 'later']);
  });

  test('a new run cannot overlap an unfinished old native screenshot',
      () async {
    begin(1, (_, __) async {});
    final oldNative = Completer<ViewportEvidence>();
    releaseOnCleanup.add(() {
      if (!oldNative.isCompleted) oldNative.complete(frame('cleanup'));
    });
    var calls = 0;
    final old = pump.capture(
        wait: false,
        current: () => epoch == 1,
        native: () {
          calls++;
          return oldNative.future;
        });
    epoch = 2;
    begin(2, (_, __) async {});
    expect(
        await pump.capture(
            wait: false,
            current: () => epoch == 2,
            native: () async {
              calls++;
              return frame('too-early');
            }),
        isNull);
    expect(calls, 1);
    oldNative.complete(frame('old-native'));
    await pump.save(1, (await old)!, {'frontier': 'old'});
    expect(await Directory('${root.path}/raw_inbox/run-1').exists(), isFalse);
    expect(
        (await pump.capture(
                wait: false,
                current: () => epoch == 2,
                native: () async {
                  calls++;
                  return frame('current');
                }))!
            .id,
        'current');
    expect(calls, 2);
  });

  test('failed durable registration retries without another screenshot',
      () async {
    pump = ViewportCapturePump(
        failureRetryDelay: const Duration(milliseconds: 20));
    var attempts = 0;
    final errors = <Object>[];
    final recovered = Completer<void>();
    pump.begin(
        epoch: 1,
        sessionId: 'run-1',
        directory: root,
        current: () => epoch == 1,
        consume: (evidence, _) async {
          expect(evidence.id, 'only-frame');
          attempts++;
          if (attempts == 1) throw StateError('temporary DB failure');
          recovered.complete();
        },
        onError: errors.add);
    await pump.save(1, frame('only-frame'), {'frontier': 'current'});
    await recovered.future.timeout(const Duration(seconds: 5));
    await pump.whenIdle;
    expect(attempts, 2);
    expect(errors, hasLength(1));
    final files =
        await Directory('${root.path}/raw_inbox/run-1').list().toList();
    expect(files.where((f) => f.path.endsWith('.pending.json')), isEmpty);
    expect(files.where((f) => f.path.endsWith('.done.json')), hasLength(1));
  });

  test('a failed old registration cannot retry into a restarted run', () async {
    pump = ViewportCapturePump(
        failureRetryDelay: const Duration(milliseconds: 20));
    final failed = Completer<void>();
    var oldAttempts = 0;
    pump.begin(
        epoch: 1,
        sessionId: 'run-1',
        directory: root,
        current: () => epoch == 1,
        consume: (_, __) async {
          oldAttempts++;
          throw StateError('temporary DB failure');
        },
        onError: (_) {
          if (!failed.isCompleted) failed.complete();
        });
    await pump.save(1, frame('old-failed'), {'frontier': 'old'});
    await failed.future;
    await pump.whenIdle;
    epoch = 2;
    final newIds = <String>[];
    begin(2, (evidence, _) async => newIds.add(evidence.id));
    await pump.save(2, frame('new'), {'frontier': 'new'});
    await pump.whenIdle;
    expect(oldAttempts, 1);
    expect(newIds, ['new']);
    expect(
        await Directory('${root.path}/raw_inbox/run-1')
            .list()
            .where((f) => f.path.endsWith('.pending.json'))
            .length,
        1);
  });

  test(
      'capture contexts are frozen and late old epoch cannot overwrite a new run',
      () async {
    final oldEntered = Completer<void>();
    final oldRelease = Completer<void>();
    releaseOnCleanup.add(() {
      if (!oldRelease.isCompleted) oldRelease.complete();
    });
    final newConsumed = Completer<void>();
    final seen = <String>[];
    begin(1, (evidence, snapshot) async {
      oldEntered.complete();
      await oldRelease.future;
      expect(snapshot['frontier'], 'old');
      seen.add(evidence.id);
    });
    pump.cacheContext(1, 'a', 1, {'frontier': 'old'});
    final frozen = pump.freezeContexts();
    pump.cacheContext(1, 'a', 2, {'frontier': 'later'});
    expect(frozen['a']!['frontier'], 'old');
    await pump.save(1, frame('old'), frozen['a']!);
    await oldEntered.future;
    epoch = 2;
    begin(2, (evidence, snapshot) async {
      expect(snapshot['frontier'], 'new');
      seen.add(evidence.id);
      newConsumed.complete();
    });
    pump.cacheContext(2, 'a', 3, {'frontier': 'new'});
    pump.cacheContext(1, 'a', 99, {'frontier': 'stale-owner'});
    await pump.save(1, frame('not-current'), {'frontier': 'stale-owner'});
    await pump.save(2, frame('new'), pump.freezeContexts()['a']!);
    oldRelease.complete();
    await newConsumed.future;
    expect(seen, ['old', 'new']);
    expect(pump.freezeContexts()['a']!['frontier'], 'new');
    expect(
        await Directory('${root.path}/raw_inbox/run-1')
            .list()
            .where((e) => e.path.endsWith('.pending.json'))
            .length,
        1,
        reason:
            'Old raw data stays isolated and is not consumed in the new run');
  });
}
