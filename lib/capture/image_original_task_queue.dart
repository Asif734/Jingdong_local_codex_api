import 'viewport_evidence.dart';
import '../domain/customer_message_time.dart';

/// Acquisition belongs to one original incoming message, never to a screenshot
/// or a particular decode attempt. Pending downloads do not need a UI lease.
class ImageOriginalTask {
  ImageOriginalTask({
    required this.customer,
    required this.messageId,
    required this.receiptId,
    required this.senderAt,
    required this.sessionId,
    required this.epoch,
    required this.nextAttemptAt,
    this.confirmedImage = false,
  });

  final String customer;
  final String messageId;
  final String receiptId;
  final DateTime senderAt;
  final String sessionId;
  final int epoch;
  final DateTime nextAttemptAt;
  bool confirmedImage;
  ViewportEvidence? freshFrame;
  bool triedSavedOriginal = false;
  bool waitingForCache = false;
  String? token;
  int searchPage = 0;
  String? previousPageHash;
  String? reason;
  DateTime? retryAt;

  String get key => CustomerMessageTime.incomingId(customer, senderAt);

  void recordAcquisition(
      {required String state, String? returnedToken, String? reason}) {
    // A native token is only a download handle. Losing/consuming it never
    // completes the original customer message or abandons its acquisition.
    token =
        state == 'source_changed' || state == 'ready' ? null : returnedToken;
    this.reason = reason ?? state;
    if (state == 'source_changed') {
      searchPage = 0;
      previousPageHash = null;
    }
  }
}

class ImageOriginalTaskQueue {
  ImageOriginalTaskQueue({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, ImageOriginalTask> _tasks = {};
  final Set<ImageOriginalTask> _leased = {};

  int get length => _tasks.length;
  bool get isEmpty => _tasks.isEmpty;
  bool get hasRunnableTasks => _tasks.values.any((t) => !t.waitingForCache);
  Iterable<ImageOriginalTask> get tasks => List.unmodifiable(_tasks.values);

  ImageOriginalTask enqueue({
    required String customer,
    required String messageId,
    required String receiptId,
    required DateTime senderAt,
    required String sessionId,
    required int epoch,
    bool confirmedImage = false,
    ViewportEvidence? initialFrame,
  }) {
    final key = CustomerMessageTime.incomingId(customer, senderAt);
    final existing = _tasks[key];
    if (existing != null &&
        existing.epoch == epoch &&
        existing.sessionId == sessionId &&
        existing.messageId == messageId &&
        existing.receiptId == receiptId) {
      existing.confirmedImage |= confirmedImage;
      return existing;
    }
    final task = ImageOriginalTask(
        customer: customer,
        messageId: messageId,
        receiptId: receiptId,
        senderAt: CustomerMessageTime.second(senderAt),
        sessionId: sessionId,
        epoch: epoch,
        nextAttemptAt: _clock(),
        confirmedImage: confirmedImage)
      ..freshFrame = initialFrame;
    _tasks[key] = task;
    return task;
  }

  bool owns(ImageOriginalTask task) => identical(_tasks[task.key], task);

  ImageOriginalTask? takeReady({required bool allowUi}) {
    final now = _clock();
    final candidates = _tasks.values;
    bool isNewImage(ImageOriginalTask task) =>
        task.confirmedImage && task.retryAt == null && task.token == null;
    for (final task in [
      ...candidates.where(isNewImage),
      ...candidates.where((task) => !isNewImage(task)),
    ]) {
      if (_leased.contains(task) ||
          task.waitingForCache ||
          (task.retryAt ?? task.nextAttemptAt).isAfter(now) ||
          (!allowUi && task.token == null && task.freshFrame == null)) {
        continue;
      }
      _leased.add(task);
      return task;
    }
    return null;
  }

  List<ImageOriginalTask> takeBatch(
      {required bool allowUi, required int maxInFlight}) {
    final batch = <ImageOriginalTask>[];
    while (_leased.length < maxInFlight) {
      final task = takeReady(allowUi: false) ??
          (allowUi ? takeReady(allowUi: true) : null);
      if (task == null) break;
      batch.add(task);
    }
    return batch;
  }

  void waitForCache(ImageOriginalTask task, {ViewportEvidence? frame}) {
    if (!owns(task)) return;
    task.waitingForCache = true;
    task.freshFrame = frame;
  }

  bool wakeCacheWaiters() {
    var changed = false;
    for (final task in _tasks.values) {
      if (!task.waitingForCache) continue;
      task.waitingForCache = false;
      task.retryAt = _clock();
      changed = true;
    }
    return changed;
  }

  void release(ImageOriginalTask task,
      {Duration retryAfter = const Duration(seconds: 2), String? reason}) {
    _leased.remove(task);
    if (!owns(task)) return;
    task.retryAt = _clock().add(retryAfter);
    task.reason = reason;
    // A waiting or slow image goes behind other customers' acquisition work.
    _tasks.remove(task.key);
    _tasks[task.key] = task;
  }

  void complete(ImageOriginalTask task) {
    _leased.remove(task);
    if (owns(task)) _tasks.remove(task.key);
  }

  void reset() {
    _tasks.clear();
    _leased.clear();
  }
}

/// Coalesce identical navigation or OCR work, without chaining different
/// keys. Only completed immutable OCR results are kept between claims.
class SharedImageAcquisitionWork<K, V> {
  SharedImageAcquisitionWork({this.completedLimit = 0});

  final int completedLimit;
  final _inFlight = <K, Future<V>>{};
  final _completed = <K, Future<V>>{};

  Future<V> run(K key, Future<V> Function() start) {
    final existing = _inFlight[key] ?? _completed[key];
    if (existing != null) return existing;
    late Future<V> future;
    future = Future<V>.microtask(start).then((value) {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
        if (completedLimit > 0) {
          _completed[key] = future;
          while (_completed.length > completedLimit) {
            _completed.remove(_completed.keys.first);
          }
        }
      }
      return value;
    }, onError: (Object error, StackTrace stack) {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
      Error.throwWithStackTrace(error, stack);
    });
    _inFlight[key] = future;
    return future;
  }

  void reset() {
    _inFlight.clear();
    _completed.clear();
  }
}
