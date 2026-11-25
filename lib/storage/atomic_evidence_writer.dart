import 'dart:async';
import 'dart:io';

/// Commit one immutable evidence sidecar once, even when callers share the
/// extraction Future. A failed write stays a failure for every waiter and a
/// later call may retry; no caller can rename another writer's temporary file.
class AtomicEvidenceWriter {
  static final _inFlight = <String, Future<void>>{};
  static int _sequence = 0;

  static Future<void> write(String path, String contents,
      {required String session}) {
    final key = '$session\u001f${File(path).absolute.path}';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    late final Future<void> future;
    future = () async {
      final temporary = File('$path.$pid.'
          '${DateTime.now().microsecondsSinceEpoch}.${++_sequence}.tmp');
      try {
        await temporary.writeAsString(contents, flush: true);
        await temporary.rename(path);
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // The commit's failure must reach every waiter. Cleanup may fail
          // too (e.g. a removed parent); it cannot replace that original error.
        }
      }
    }()
        .whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }
}
