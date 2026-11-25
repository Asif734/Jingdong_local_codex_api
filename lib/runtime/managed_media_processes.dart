import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cancelling media work is distinct from a missing stream or decoding failure.
class MediaProcessCancelled implements Exception {
  const MediaProcessCancelled();

  @override
  String toString() => 'Local media work was cancelled.';
}

/// Owns only subprocesses launched for local media analysis.
class ManagedMediaProcesses {
  ManagedMediaProcesses();

  static final shared = ManagedMediaProcesses();
  static final Object _zoneKey = Object();
  MediaProcessRun? _current;

  /// A new epoch cannot revive a pipeline admitted by an earlier epoch.
  MediaProcessRun beginRun() {
    final previous = _current;
    if (previous != null) unawaited(previous.cancel());
    return _current = MediaProcessRun._();
  }

  T runCurrent<T>(T Function() body) => captureRun().run(body);

  Future<void> cancelRun() => (_current ??= MediaProcessRun._()).cancel();

  /// Standalone extraction remains usable before the app starts its first run.
  MediaProcessRun captureRun() =>
      Zone.current[_zoneKey] as MediaProcessRun? ??
      (_current ??= MediaProcessRun._());
}

class MediaProcessRun {
  MediaProcessRun._();

  bool _cancelled = false;
  final Set<_MediaChild> _children = {};
  final Set<Future<void>> _starting = {};
  Future<void>? _cancellation;

  bool get isCancelled => _cancelled;

  void throwIfCancelled() {
    if (_cancelled) throw const MediaProcessCancelled();
  }

  /// Bind the entire pipeline, including subsequent extractor invocations.
  T run<T>(T Function() body) => runZoned(() {
        throwIfCancelled();
        return body();
      }, zoneValues: {ManagedMediaProcesses._zoneKey: this});

  Future<ProcessResult> execute(
      String executable, List<String> arguments) async {
    throwIfCancelled();
    final started = Completer<void>();
    _starting.add(started.future);
    late final _MediaChild child;
    try {
      final process = await Process.start(executable, arguments);
      child = _MediaChild(process);
      _children.add(child);
    } catch (_) {
      throwIfCancelled();
      rethrow;
    } finally {
      _starting.remove(started.future);
      started.complete();
    }
    try {
      if (_cancelled) {
        await child.terminate();
        throw const MediaProcessCancelled();
      }
      final result = await child.result;
      throwIfCancelled();
      return result;
    } catch (_) {
      throwIfCancelled();
      rethrow;
    } finally {
      _children.remove(child);
    }
  }

  Future<void> cancel() {
    _cancelled = true;
    return _cancellation ??= _cancelChildren();
  }

  Future<void> _cancelChildren() async {
    // A launch already in Process.start must register its handle before Stop
    // finishes. No new launch may enter once _cancelled is set.
    await Future.wait(_starting.toList());
    await Future.wait(_children.toList().map((child) => child.terminate()));
  }
}

class _MediaChild {
  _MediaChild(this.process) {
    result = Future.wait<Object>([
      process.exitCode,
      utf8.decoder.bind(process.stdout).join(),
      utf8.decoder.bind(process.stderr).join(),
    ]).then((values) =>
        ProcessResult(process.pid, values[0] as int, values[1], values[2]));
  }

  final Process process;
  late final Future<ProcessResult> result;
  Future<void>? _termination;

  Future<void> terminate() => _termination ??= _terminate();

  Future<void> _terminate() async {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(milliseconds: 350));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      // Bound Stop even if an OS process refuses to reap promptly.
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The handle remains owned; no unrelated processes are signalled.
      }
    }
  }
}
