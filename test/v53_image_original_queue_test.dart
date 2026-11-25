import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_original_task_queue.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';

void main() {
  final received = DateTime.utc(2026, 11, 11, 4);
  late DateTime now;
  late ImageOriginalTaskQueue queue;

  setUp(() {
    now = received;
    queue = ImageOriginalTaskQueue(clock: () => now);
  });

  ImageOriginalTask enqueue(
      {String customer = 'buyer-a',
      int second = 0,
      int milliseconds = 0,
      String? receipt,
      bool confirmedImage = false,
      String session = 'run-a',
      int epoch = 7}) {
    final at =
        received.add(Duration(seconds: second, milliseconds: milliseconds));
    return queue.enqueue(
        customer: customer,
        messageId: CustomerMessageTime.incomingId(customer, at),
        receiptId: receipt ?? 'receipt-$customer-$second',
        senderAt: at,
        sessionId: session,
        epoch: epoch,
        confirmedImage: confirmedImage);
  }

  test('reserved UI still dispatches different frozen tasks in parallel', () {
    final needsUi = enqueue();
    final first = enqueue(second: 1)..freshFrame = const ViewportEvidence({});
    final second = enqueue(customer: 'buyer-b')
      ..freshFrame = const ViewportEvidence({});
    final third = enqueue(customer: 'buyer-c')..token = 'token-c';
    expect(queue.takeBatch(allowUi: false, maxInFlight: 2), [first, second]);
    expect(queue.takeBatch(allowUi: false, maxInFlight: 2), isEmpty);
    queue.complete(first);
    expect(queue.takeBatch(allowUi: false, maxInFlight: 2), [third]);
    expect(queue.owns(needsUi), isTrue);
  });

  test('a shared page/OCR result is reused without serializing another page',
      () async {
    final work = SharedImageAcquisitionWork<String, int>(completedLimit: 2);
    final first = Completer<int>();
    final a = work.run('page-a', () => first.future);
    final b =
        work.run('page-a', () async => fail('same page was started twice'));
    final c = work.run('page-b', () async => 7);
    expect(identical(a, b), isTrue);
    expect(await c, 7);
    first.complete(6);
    expect(await Future.wait([a, b]), [6, 6]);
    expect(
        await work.run('page-a', () async => fail('OCR should be reused')), 6);
    work.reset();
    expect(await work.run('page-a', () async => 8), 8);
  });

  test('a cache miss parks the exact receipt until cache progress', () {
    final item = enqueue();
    final frame = const ViewportEvidence({});
    expect(queue.takeReady(allowUi: true), same(item));
    queue.waitForCache(item, frame: frame);
    queue.release(item, retryAfter: Duration.zero);
    expect(queue.takeReady(allowUi: true), isNull);
    queue.wakeCacheWaiters();
    expect(queue.takeReady(allowUi: false), same(item));
    expect(item.freshFrame, same(frame));
  });

  test('same customer and complete sender second preserve the pending token',
      () {
    final original = enqueue();
    original.token = 'native-download-token';
    original.searchPage = 2;
    original.previousPageHash = 'verified-page';
    original.reason = 'download_pending';
    original.retryAt = now.add(const Duration(seconds: 2));
    now = now.add(const Duration(milliseconds: 500));
    final reread = enqueue(milliseconds: 999);
    expect(identical(original, reread), isTrue);
    expect(queue.length, 1);
    expect(reread.token, 'native-download-token');
    expect(reread.searchPage, 2);
    expect(reread.previousPageHash, 'verified-page');
    expect(reread.retryAt, received.add(const Duration(seconds: 2)));
    expect(reread.reason, 'download_pending');
    expect(reread.senderAt, received);
  });

  test('different customer or second remains independent original work', () {
    final first = enqueue();
    final anotherSecond = enqueue(second: 1);
    final anotherCustomer = enqueue(customer: 'buyer-b');
    expect(queue.length, 3);
    expect({first.key, anotherSecond.key, anotherCustomer.key}, hasLength(3));
    expect(queue.tasks.map((task) => task.messageId),
        [first.messageId, anotherSecond.messageId, anotherCustomer.messageId]);
  });

  test('a newly confirmed image goes ahead of waiting classification work', () {
    final unknown = enqueue(second: 1);
    final image = enqueue(second: 2);
    expect(enqueue(second: 2, confirmedImage: true), same(image));
    expect(queue.takeReady(allowUi: true), same(image));
    queue.release(image);
    expect(queue.takeReady(allowUi: true), same(unknown));
  });

  test('releasing a pending image yields to another customer without losing it',
      () {
    final first = enqueue();
    final other = enqueue(customer: 'buyer-b');
    expect(queue.takeReady(allowUi: true), same(first));
    first.token = 'pending-token';
    queue.release(first, retryAfter: Duration.zero, reason: 'download_pending');
    expect(queue.takeReady(allowUi: true), same(other));
    queue.complete(other);
    expect(queue.takeReady(allowUi: false), same(first));
    expect(first.token, 'pending-token');
    expect(first.reason, 'download_pending');
    queue.complete(first);
    expect(queue.isEmpty, isTrue);
  });

  test('reserved UI permits token polling while fresh UI work stays queued',
      () {
    final needsUi = enqueue();
    final pending = enqueue(customer: 'buyer-b');
    pending.token = 'native-original-in-progress';
    expect(queue.takeReady(allowUi: false), same(pending));
    expect(queue.takeReady(allowUi: false), isNull,
        reason: 'The same token cannot be polled by concurrent queue leases');
    queue.complete(pending);
    expect(queue.takeReady(allowUi: false), isNull);
    expect(queue.takeReady(allowUi: true), same(needsUi));
    queue.complete(needsUi);
    expect(queue.isEmpty, isTrue);
  });

  test('a busy message is never leased twice even when it is reread', () {
    final task = enqueue();
    expect(queue.takeReady(allowUi: true), same(task));
    expect(enqueue(), same(task));
    expect(queue.takeReady(allowUi: true), isNull);
    task.token = 'pending';
    expect(queue.takeReady(allowUi: false), isNull);
    queue.release(task, retryAfter: const Duration(seconds: 2));
    now = now.add(const Duration(milliseconds: 1999));
    expect(queue.takeReady(allowUi: false), isNull);
    now = now.add(const Duration(milliseconds: 1));
    expect(queue.takeReady(allowUi: false), same(task));
    queue.complete(task);
    expect(queue.length, 0);
  });

  test('reset invalidates an old lease and its token cannot affect a new run',
      () {
    final old = enqueue();
    old.token = 'old-run-token';
    expect(queue.takeReady(allowUi: true), same(old));
    queue.reset();
    final current = enqueue(session: 'run-b', epoch: 8);
    expect(queue.owns(old), isFalse);
    expect(queue.owns(current), isTrue);
    queue.complete(old);
    queue.release(old, retryAfter: const Duration(days: 1), reason: 'stale');
    expect(queue.length, 1);
    expect(current.token, isNull);
    expect(current.reason, isNull);
    expect(current.retryAt, isNull);
    expect(queue.takeReady(allowUi: false), isNull);
    expect(queue.takeReady(allowUi: true), same(current));
  });

  test(
      'changed epoch replaces ownership and stale completion preserves new work',
      () {
    final old = enqueue();
    old.token = 'old-epoch-token';
    queue.takeReady(allowUi: true);
    final current = enqueue(epoch: 8);
    expect(identical(old, current), isFalse);
    expect(queue.owns(old), isFalse);
    expect(current.token, isNull);
    queue.complete(old);
    expect(queue.tasks.single, same(current));
    expect(queue.takeReady(allowUi: true), same(current));
  });

  test('changed session replaces ownership even if its epoch number is reused',
      () {
    final old = enqueue();
    old.token = 'old-session-token';
    queue.takeReady(allowUi: true);
    final current = enqueue(session: 'run-b');
    queue.release(old, reason: 'late-old-result');
    expect(queue.tasks.single, same(current));
    expect(current.token, isNull);
    expect(current.reason, isNull);
    expect(queue.takeReady(allowUi: true), same(current));
  });

  test('changed receipt replaces the task without transferring an old token',
      () {
    final old = enqueue(receipt: 'old-receipt');
    old.token = 'old-owner-token';
    queue.takeReady(allowUi: true);
    final current = enqueue(receipt: 'verified-current-receipt');
    expect(queue.length, 1);
    expect(queue.owns(old), isFalse);
    expect(current.receiptId, 'verified-current-receipt');
    expect(current.token, isNull);
    queue.release(old, retryAfter: const Duration(days: 1), reason: 'stale');
    queue.complete(old);
    expect(queue.tasks.single, same(current));
    expect(current.retryAt, isNull);
    expect(queue.takeReady(allowUi: true), same(current));
    expect(queue.takeReady(allowUi: true), isNull);
  });

  test('a completion removes only its exact lease and leaves other work intact',
      () {
    final first = enqueue();
    final second = enqueue(customer: 'buyer-b');
    expect(queue.takeReady(allowUi: true), same(first));
    queue.complete(first);
    queue.complete(first);
    expect(queue.tasks.single, same(second));
    expect(queue.takeReady(allowUi: true), same(second));
    queue.complete(second);
    expect(queue.isEmpty, isTrue);
  });

  test('pending acquisition retains its token and polls the same message', () {
    final task = enqueue();
    final id = task.messageId;
    expect(queue.takeReady(allowUi: true), same(task));
    task.searchPage = 2;
    task.previousPageHash = 'exact-page';
    task.recordAcquisition(
        state: 'pending',
        returnedToken: 'download-handle',
        reason: 'native_download_pending');
    queue.release(task, retryAfter: Duration.zero, reason: task.reason);
    expect(queue.tasks.single, same(task));
    expect(task.messageId, id);
    expect(task.token, 'download-handle');
    expect(task.searchPage, 2);
    expect(task.previousPageHash, 'exact-page');
    expect(task.reason, 'native_download_pending');
    expect(queue.takeReady(allowUi: false), same(task),
        reason: 'A download poll must not need a new customer-window visit.');
    expect(queue.takeReady(allowUi: false), isNull);
  });

  test('source change clears even an echoed invalid token without losing work',
      () {
    final task = enqueue();
    final id = task.messageId;
    expect(queue.takeReady(allowUi: true), same(task));
    task.token = 'expired-token';
    task.searchPage = 4;
    task.previousPageHash = 'obsolete-source';
    task.recordAcquisition(
        state: 'source_changed',
        returnedToken: 'expired-token',
        reason: 'native_token_expired');
    expect(task.token, isNull);
    expect(task.searchPage, 0);
    expect(task.previousPageHash, isNull);
    expect(task.reason, 'native_token_expired');
    expect(queue.owns(task), isTrue);
    expect(task.messageId, id);
    queue.release(task, retryAfter: Duration.zero, reason: task.reason);
    expect(queue.length, 1);
    expect(queue.takeReady(allowUi: false), isNull,
        reason: 'The invalid handle must never be polled indefinitely.');
    expect(queue.takeReady(allowUi: true), same(task));
    expect(task.receiptId, 'receipt-buyer-a-0');
  });

  test(
      'ready consumes the token before persistence and a failed commit can relocate',
      () {
    final task = enqueue();
    final id = task.messageId;
    expect(queue.takeReady(allowUi: true), same(task));
    task.token = 'one-shot-ready-token';
    task.recordAcquisition(
        state: 'ready', returnedToken: 'one-shot-ready-token');
    expect(task.token, isNull);
    // The caller completes only after saving the original and its ledger.
    // Model a commit error between the native result and that completion.
    try {
      throw StateError('controlled_original_commit_failed');
    } catch (_) {
      queue.release(task,
          retryAfter: Duration.zero,
          reason: 'controlled_original_commit_failed');
    }
    expect(queue.owns(task), isTrue);
    expect(queue.tasks.single.messageId, id);
    expect(queue.takeReady(allowUi: false), isNull);
    expect(queue.takeReady(allowUi: true), same(task),
        reason: 'Retry acquisition by location, not by a consumed token.');
    task.recordAcquisition(
        state: 'pending', returnedToken: 'replacement-token');
    expect(task.token, 'replacement-token');
    task.recordAcquisition(state: 'ready', returnedToken: 'replacement-token');
    expect(task.token, isNull);
    queue.complete(task);
    expect(queue.isEmpty, isTrue);
  });

  test(
      'a blocked modal retains its exact token for close and continued polling',
      () {
    final task = enqueue();
    expect(queue.takeReady(allowUi: true), same(task));
    task.recordAcquisition(
        state: 'modal_blocked',
        returnedToken: 'modal-owner',
        reason: 'viewer_close_pending');
    queue.release(task, retryAfter: Duration.zero, reason: task.reason);
    expect(task.token, 'modal-owner');
    expect(task.reason, 'viewer_close_pending');
    expect(queue.takeReady(allowUi: false), same(task));
    task.recordAcquisition(state: 'pending', returnedToken: 'modal-owner');
    expect(task.token, 'modal-owner');
    queue.release(task, retryAfter: Duration.zero, reason: task.reason);
    expect(queue.takeReady(allowUi: false), same(task));
    task.recordAcquisition(state: 'ready', returnedToken: 'modal-owner');
    expect(task.token, isNull);
    queue.complete(task);
    expect(queue.isEmpty, isTrue);
  });
}
