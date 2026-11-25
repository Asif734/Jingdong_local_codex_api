import 'dart:async';

/// Serializes foreground transactions. A transfer owns one lease across all
/// its phases; background computation never takes a UI lease.
enum JdUiPriority {
  transfer,
  responseDeadline,
  delivery,
  imageAcquisition,
  capture
}

class JdUiLease {
  JdUiLease(this._release);
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class JdUiScheduler {
  bool _busy = false;
  int _sequence = 0;
  final List<_Request> _pending = [];

  Future<JdUiLease> acquire({
    JdUiPriority priority = JdUiPriority.capture,
    DateTime? deadline,
  }) {
    final request = _Request(priority, deadline, _sequence++);
    _pending.add(request);
    _dispatch();
    return request.ready.future;
  }

  Future<T> run<T>(Future<T> Function() work,
      {JdUiPriority priority = JdUiPriority.delivery,
      DateTime? deadline}) async {
    final lease = await acquire(priority: priority, deadline: deadline);
    try {
      return await work();
    } finally {
      lease.release();
    }
  }

  void _dispatch() {
    if (_busy || _pending.isEmpty) return;
    _pending.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      if (priority != 0) return priority;
      if (a.deadline != null && b.deadline != null) {
        final deadline = a.deadline!.compareTo(b.deadline!);
        if (deadline != 0) return deadline;
      }
      return a.sequence.compareTo(b.sequence);
    });
    _busy = true;
    final request = _pending.removeAt(0);
    request.ready.complete(JdUiLease(() {
      _busy = false;
      _dispatch();
    }));
  }
}

class _Request {
  _Request(this.priority, this.deadline, this.sequence);
  final JdUiPriority priority;
  final DateTime? deadline;
  final int sequence;
  final ready = Completer<JdUiLease>();
}
