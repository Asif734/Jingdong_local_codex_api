import 'dart:async';

import '../domain/capture_models.dart';
import '../platform/capture_adapter.dart';
import '../storage/capture_database.dart';

class CaptureCoordinator {
  CaptureCoordinator(this.adapter, this.database);

  final CaptureAdapter adapter;
  final CaptureDatabase database;
  final _updates = StreamController<List<ConversationSummary>>.broadcast();
  StreamSubscription<CapturedConversation>? _subscription;
  Future<void> _writeTail = Future.value();
  int _epoch = 0;
  DateTime? _sessionStartedAt;
  String? _sessionId;

  Future<void> beginSession(
      {required String sessionId, required DateTime startedAt}) async {
    _epoch++;
    _sessionStartedAt = startedAt;
    _sessionId = sessionId;
    // A queued write from an old run must not hold up a fresh capture lane.
    _writeTail = Future.value();
  }

  Stream<List<ConversationSummary>> get updates => _updates.stream;

  Future<void> start() async {
    _subscription ??= adapter.captures.listen((capture) {
      final epoch = _epoch;
      if (_sessionStartedAt != null &&
          (capture.automationSessionId != _sessionId ||
              capture.capturedAt.isBefore(_sessionStartedAt!))) {
        return;
      }
      // A serialized persistence queue decouples AX capture from database and future AI work.
      _writeTail = _writeTail.then((_) async {
        if (epoch != _epoch) return;
        await database.saveCapture(capture);
        if (epoch != _epoch) return;
        _updates.add(await database.conversations());
      }).catchError((Object error, StackTrace stack) {
        if (epoch != _epoch) return;
        _updates.addError(error, stack);
      });
    });
    _updates.add(await database.conversations());
    await adapter.start();
  }

  Future<void> stop() {
    _epoch++;
    return adapter.stop();
  }

  Future<void> refresh() async => _updates.add(await database.conversations());
}
