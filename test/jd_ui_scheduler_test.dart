import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/jd_ui_scheduler.dart';
import 'package:jd_automation/capture/response_timing_policy.dart';

void main() {
  test('transfer owns the foreground across phases while background completes',
      () async {
    final queue = JdUiScheduler();
    final inspected = Completer<void>(), continueTransfer = Completer<void>();
    final order = <String>[];
    final transfer = queue.run(() async {
      order.add('inspect');
      inspected.complete();
      await continueTransfer.future;
      order.add('acknowledge');
      await Future<void>.delayed(Duration.zero);
      order.add('transfer');
    }, priority: JdUiPriority.transfer);
    await inspected.future;
    final reply = queue.run(() async {
      order.add('reply');
    }, priority: JdUiPriority.responseDeadline);
    final capture = queue.run(() async {
      order.add('capture');
    }, priority: JdUiPriority.capture);
    await Future<void>(() {
      order.add('background-crop');
    });
    expect(order, ['inspect', 'background-crop']);
    continueTransfer.complete();
    await Future.wait([transfer, reply, capture]);
    expect(order, [
      'inspect',
      'background-crop',
      'acknowledge',
      'transfer',
      'reply',
      'capture'
    ]);
  });

  test('failed transfer releases foreground for the waiting reply', () async {
    final queue = JdUiScheduler();
    await expectLater(
        queue.run(() async {
          throw StateError('transfer failed');
        }, priority: JdUiPriority.transfer),
        throwsStateError);
    expect(await queue.run(() async => 'reply-ready'), 'reply-ready');
  });

  test('two simultaneous customers both receive holding responses inside 20s',
      () {
    fakeAsync((clock) {
      final queue = JdUiScheduler();
      final start = DateTime(2026);
      final sent = <int>[];
      clock.elapse(const Duration(seconds: 9));
      unawaited(
          queue.run(() => Future<void>.delayed(const Duration(seconds: 4))));
      clock.flushMicrotasks();
      for (var i = 0; i < 3; i++) {
        unawaited(queue.run(
            () => Future<void>.delayed(const Duration(seconds: 4)),
            priority: JdUiPriority.capture));
      }
      clock.elapse(const Duration(seconds: 1));
      for (var i = 0; i < 2; i++) {
        unawaited(queue.run(() async {
          await Future<void>.delayed(const Duration(seconds: 3));
          sent.add(clock.elapsed.inSeconds);
        },
            priority: JdUiPriority.responseDeadline,
            deadline: start.add(ResponseTimingPolicy.responseTarget)));
      }
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      expect(sent, [16, 19]);
    });
  });

  test(
      'holding overtakes queued scans and delivery without interrupting current UI',
      () async {
    final queue = JdUiScheduler();
    final active = await queue.acquire();
    final order = <String>[];
    final scan = queue.run(() async {
      order.add('scan');
    }, priority: JdUiPriority.capture);
    final reply = queue.run(() async {
      order.add('reply');
    });
    final holding = queue.run(() async {
      order.add('holding');
    }, priority: JdUiPriority.responseDeadline, deadline: DateTime(2026));
    expect(order, isEmpty);
    active.release();
    await Future.wait([scan, reply, holding]);
    expect(order, ['holding', 'reply', 'scan']);
  });

  test('confirmed image work overtakes queued scans, while replies go first',
      () async {
    final queue = JdUiScheduler();
    final active = await queue.acquire();
    final order = <String>[];
    final scan = queue.run(() async => order.add('scan'),
        priority: JdUiPriority.capture);
    final image = queue.run(() async => order.add('image'),
        priority: JdUiPriority.imageAcquisition);
    final reply = queue.run(() async => order.add('reply'));
    active.release();
    await Future.wait([scan, image, reply]);
    expect(order, ['reply', 'image', 'scan']);
  });

  test('concurrent customers are ordered by their actual response deadlines',
      () async {
    final queue = JdUiScheduler();
    final active = await queue.acquire();
    final order = <String>[];
    final later = queue.run(() async {
      order.add('later');
    },
        priority: JdUiPriority.responseDeadline,
        deadline: DateTime(2026, 1, 1, 0, 0, 20));
    final earlier = queue.run(() async {
      order.add('earlier');
    },
        priority: JdUiPriority.responseDeadline,
        deadline: DateTime(2026, 1, 1, 0, 0, 15));
    active.release();
    await Future.wait([later, earlier]);
    expect(order, ['earlier', 'later']);
  });

  test('a failed urgent send releases ownership for another customer',
      () async {
    final queue = JdUiScheduler();
    await expectLater(
        queue.run(() async {
          throw StateError('identity changed');
        }, priority: JdUiPriority.responseDeadline),
        throwsStateError);
    expect(await queue.run(() async => 'next'), 'next');
  });

  test('several live deadlines overtake one customer retry and queued capture',
      () async {
    final queue = JdUiScheduler();
    final active = await queue.acquire();
    final now = DateTime(2026, 1, 1, 0, 0, 18);
    final seen = <String>[];
    Future<void> enqueue(String tag, DateTime deadline, {bool retry = false}) =>
        queue.run(() async {
          seen.add(tag);
        },
            priority: JdUiPriority.responseDeadline,
            deadline: ResponseTimingPolicy.holdingQueueDeadline(deadline, now,
                retry: retry));
    final scan =
        queue.run(() async => seen.add('scan'), priority: JdUiPriority.capture);
    final retry = enqueue(
        'old retry', now.subtract(const Duration(seconds: 30)),
        retry: true);
    final c = enqueue('C', now.add(const Duration(seconds: 5)));
    final b = enqueue('B', now.add(const Duration(seconds: 2)));
    final a = enqueue('A', now.add(const Duration(seconds: 1)));
    active.release();
    await Future.wait([scan, retry, c, b, a]);
    expect(seen, ['A', 'B', 'C', 'old retry', 'scan']);
  });

  test(
      'holding triggered at red clock 20 seconds overtakes scans before platform 30-second warning',
      () {
    fakeAsync((clock) {
      final queue = JdUiScheduler();
      final start = DateTime(2026);
      var sentAt = -1;
      // One bounded capture is already running at second 11. Other scans have
      // queued first, but must not take the UI before a deadline response.
      clock.elapse(const Duration(seconds: 11));
      unawaited(
          queue.run(() => Future<void>.delayed(const Duration(seconds: 4))));
      clock.flushMicrotasks();
      for (var i = 0; i < 5; i++) {
        unawaited(queue.run(
            () => Future<void>.delayed(const Duration(seconds: 3)),
            priority: JdUiPriority.capture));
      }
      clock.elapse(ResponseTimingPolicy.delayUntilDispatch(
          start.add(ResponseTimingPolicy.responseTarget),
          start.add(clock.elapsed)));
      unawaited(queue.run(() async {
        await Future<void>.delayed(const Duration(seconds: 3));
        sentAt = clock.elapsed.inSeconds;
      },
          priority: JdUiPriority.responseDeadline,
          deadline: start.add(ResponseTimingPolicy.responseTarget)));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 8));
      expect(sentAt, greaterThanOrEqualTo(20));
      expect(sentAt, lessThan(30));
    });
  });

  test('releasing a lease twice never runs two UI transactions together',
      () async {
    final queue = JdUiScheduler();
    final lease = await queue.acquire();
    final blocker = Completer<void>();
    var secondStarted = false;
    final first = queue.run(() => blocker.future);
    final second = queue.run(() async {
      secondStarted = true;
    });
    lease.release();
    lease.release();
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);
    blocker.complete();
    await Future.wait([first, second]);
    expect(secondStarted, isTrue);
  });
  test('ready formal reply and holding share actual deadline ordering',
      () async {
    final queue = JdUiScheduler();
    final active = await queue.acquire();
    final order = <String>[];
    final scan = queue.run(() async {
      order.add('scan');
    }, priority: JdUiPriority.capture);
    final holding = queue.run(() async {
      order.add('holding');
    },
        priority: JdUiPriority.responseDeadline,
        deadline: DateTime(2026, 1, 1, 0, 0, 20));
    final formal = queue.run(() async {
      order.add('formal');
    },
        priority: JdUiPriority.responseDeadline,
        deadline: DateTime(2026, 1, 1, 0, 0, 15));
    active.release();
    await Future.wait([scan, holding, formal]);
    expect(order, ['formal', 'holding', 'scan']);
  });
}
