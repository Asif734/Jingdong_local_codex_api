import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local operation metadata only: no message bodies, prompts, or credentials.
class RuntimeTrace {
  static Future<void> _tail = Future<void>.value();
  static int _sequence = 0;
  static String get path =>
      '${Platform.environment['HOME'] ?? Directory.systemTemp.path}/Library/Logs/JD Automation/runtime.jsonl';

  static void record(String event, [Map<String, Object?> fields = const {}]) {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    final line = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'pid': pid,
      'event': event,
      ...fields,
    });
    _tail = _tail.then((_) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString('$line\n', mode: FileMode.append);
    }).catchError((Object _) {});
  }

  /// Wait until all Dart diagnostic records accepted so far are durable.
  static Future<void> flush() => _tail;

  static Future<T> measure<T>(String stage, Future<T> Function() work,
      {Map<String, Object?> fields = const {},
      Map<String, Object?> Function(T)? describe}) async {
    final id = ++_sequence;
    final clock = Stopwatch()..start();
    record('$stage.start', {'operation': id, ...fields});
    try {
      final result = await work();
      record('$stage.end', {
        'operation': id,
        'elapsedMs': clock.elapsedMilliseconds,
        ...fields,
        if (describe != null) ...describe(result),
      });
      return result;
    } catch (error) {
      record('$stage.error', {
        'operation': id,
        'elapsedMs': clock.elapsedMilliseconds,
        ...fields,
        'error': '$error',
      });
      rethrow;
    }
  }
}
