import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'viewport_evidence.dart';

/// One actual native screenshot at a time. Raw frames wait on disk rather than
/// retaining an unbounded chain of OCR/SQLite futures in the capture loop.
class ViewportCapturePump {
  ViewportCapturePump({this.failureRetryDelay = const Duration(seconds: 5)});

  final Duration failureRetryDelay;
  Timer? _retryTimer;
  DateTime? _retryAt;
  Future<ViewportEvidence>? _native;
  bool _draining = false;
  bool _requested = false;
  Completer<void>? _drainFinished;
  int? _epoch;
  Directory? _inbox;
  Future<void> Function(ViewportEvidence, Map<String, Object?>)? _consume;
  bool Function()? _current;
  void Function(Object)? _onError;
  final _contexts = <String, (int, Map<String, Object?>)>{};
  Map<String, int> navigationCutoffs = const {};
  Directory? captureDirectory;
  int _captureSequence = 0;
  int _leaseGeneration = 0;
  Completer<void> _stopSignal = Completer<void>();

  void begin(
      {required int epoch,
      required String sessionId,
      required Directory directory,
      required bool Function() current,
      required Future<void> Function(ViewportEvidence, Map<String, Object?>)
          consume,
      required void Function(Object) onError}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAt = null;
    if (_stopSignal.isCompleted) _stopSignal = Completer<void>();
    _epoch = epoch;
    captureDirectory = directory;
    _inbox = Directory('${directory.path}/raw_inbox/$sessionId');
    _current = current;
    _consume = consume;
    _onError = onError;
    _contexts.clear();
    _captureSequence = 0;
    navigationCutoffs = const {};
    _requested = false;
    // An older native call/consumer keeps its lease until its actual Future
    // completes. Starting a new run never makes a second native call overlap.
  }

  bool current(int epoch) => epoch == _epoch && _current?.call() == true;

  /// Includes the durable acknowledgement rename, not just the consumer's
  /// callback. Tests and shutdown can wait without artificial sleep intervals.
  /// Retire only the stopped run's scheduling leases. Its immutable pending
  /// frames stay on disk; late callbacks cannot release a new run's lease.
  Map<String, Object?> stop() {
    final snapshot = <String, Object?>{
      'nativeInFlight': _native != null,
      'registrationInFlight': _draining,
    };
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAt = null;
    _epoch = null;
    _current = () => false;
    _requested = false;
    _leaseGeneration++;
    _native = null;
    _draining = false;
    _drainFinished = null;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    return snapshot;
  }

  Future<void> get whenIdle async {
    final stopped = _stopSignal;
    while (!stopped.isCompleted && (_native != null || _draining)) {
      final native = _native;
      if (native != null) {
        try {
          await Future.any([native, stopped.future]);
        } catch (_) {}
      }
      final drain = _drainFinished;
      if (_draining && drain != null) {
        await Future.any([drain.future, stopped.future]);
      }
    }
  }

  Map<String, Map<String, Object?>> freezeContexts() => {
        for (final entry in _contexts.entries)
          entry.key: Map<String, Object?>.from(
              jsonDecode(jsonEncode(entry.value.$2)) as Map),
      };

  void cacheContext(
      int epoch, String customer, int revision, Map<String, Object?> context) {
    if (!current(epoch) || (_contexts[customer]?.$1 ?? -1) > revision) return;
    _contexts[customer] = (
      revision,
      Map<String, Object?>.from(jsonDecode(jsonEncode(context)) as Map)
    );
  }

  Future<ViewportEvidence?> capture(
      {required bool wait,
      required bool Function() current,
      required Future<ViewportEvidence> Function() native}) async {
    while (_native != null) {
      final running = _native!;
      if (!wait) return null;
      try {
        await running;
      } catch (_) {/* The original caller owns errors. */}
      if (!current()) return null;
    }
    if (!current()) return null;
    final operation = Future<ViewportEvidence>.sync(native);
    _native = operation;
    try {
      return await operation;
    } finally {
      if (identical(_native, operation)) _native = null;
    }
  }

  Future<void> save(int epoch, ViewportEvidence evidence,
      Map<String, Object?> snapshot) async {
    if (!current(epoch)) return;
    final directory = _inbox!;
    await directory.create(recursive: true);
    final payload =
        jsonEncode({'evidence': evidence.metadata, 'snapshot': snapshot});
    // Repeated unchanged native pixels with unchanged frozen authorization
    // need one registration. Different pixels or authorization stay separate.
    final key = sha256
        .convert(utf8.encode(jsonEncode({
          'id': evidence.id,
          'customer': evidence.customer,
          'png': evidence.metadata['pngSHA256'],
          'chat': evidence.metadata['chatContentSHA256'],
          'cutoff': evidence.metadata['historyCutoffMs'],
          'verifiedLiveBottom': evidence.metadata['verifiedLiveBottom'],
          'authorization': snapshot,
        })))
        .toString();
    final ticket = File('${directory.path}/seen/$key');
    if (await ticket.exists()) {
      if (current(epoch)) requestDrain();
      return;
    }
    final sequence = ++_captureSequence;
    final name =
        '${evidence.capturedAt.millisecondsSinceEpoch.toString().padLeft(16, '0')}'
        '-${sequence.toString().padLeft(12, '0')}-$key';
    final pending = File('${directory.path}/$name.pending.json');
    final temporary = File('${pending.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    await temporary.rename(pending.path);
    await ticket.parent.create(recursive: true);
    await ticket.writeAsString(name, flush: true);
    if (current(epoch)) requestDrain();
  }

  void requestDrain() {
    _requested = true;
    if (_draining || _current?.call() != true || _inbox == null) return;
    _draining = true;
    final finished = Completer<void>();
    _drainFinished = finished;
    unawaited(_drain(_epoch!, _inbox!, _consume!, finished, _leaseGeneration));
  }

  void _scheduleRetry(int epoch, DateTime at) {
    if (!current(epoch) || (_retryAt != null && !_retryAt!.isAfter(at))) {
      return;
    }
    _retryTimer?.cancel();
    _retryAt = at;
    final delay = at.difference(DateTime.now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _retryTimer = null;
      _retryAt = null;
      if (current(epoch)) requestDrain();
    });
  }

  Future<void> _drain(
      int epoch,
      Directory directory,
      Future<void> Function(ViewportEvidence, Map<String, Object?>) consume,
      Completer<void> finished,
      int leaseGeneration) async {
    try {
      while (current(epoch)) {
        _requested = false;
        if (!await directory.exists()) break;
        final paths = <String>[];
        await for (final entry in directory.list(followLinks: false)) {
          if (entry is File && entry.path.endsWith('.pending.json')) {
            final retryAt = await entry.lastModified();
            if (retryAt.isAfter(DateTime.now())) {
              _scheduleRetry(epoch, retryAt);
            } else {
              paths.add(entry.path);
            }
          }
        }
        paths.sort();
        if (paths.isEmpty) break;
        // Only paths are sorted; payload memory is bounded to one frame.
        for (final path in paths.take(32)) {
          final file = File(path);
          if (!current(epoch)) return;
          try {
            final payload = jsonDecode(await file.readAsString()) as Map;
            if (!current(epoch)) return;
            await consume(ViewportEvidence.fromMap(payload['evidence'] as Map),
                Map<String, Object?>.from(payload['snapshot'] as Map));
            if (!current(epoch)) return;
            await file
                .rename(file.path.replaceFirst('.pending.json', '.done.json'));
          } catch (error) {
            if (!current(epoch)) return;
            _onError?.call(error);
            // Keep the immutable frame, but do not spin on a failed disk/DB
            // commit or prevent other customers' files from being registered.
            if (await file.exists()) {
              final retryAt = DateTime.now().add(failureRetryDelay);
              await file.setLastModified(retryAt);
              _scheduleRetry(epoch, retryAt);
            }
          }
        }
      }
    } catch (error) {
      if (current(epoch)) _onError?.call(error);
    } finally {
      if (leaseGeneration == _leaseGeneration) {
        _draining = false;
        if (_requested && _current?.call() == true) requestDrain();
      }
      finished.complete();
    }
  }
}
