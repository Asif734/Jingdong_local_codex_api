import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';
import '../storage/capture_database.dart';
import 'jd_v2_client.dart';
import 'jd_v2_config.dart';

typedef JdV2Acknowledge = Future<Map<String, dynamic>> Function(
    String jobId, Map<String, dynamic> body);

/// Durable ACK outbox. It only reads native send receipts and records delivery;
/// it has no capability to send customer messages.
class JdV2DeliveryOutbox {
  JdV2DeliveryOutbox(this.root,
      {required this.acknowledge, DateTime Function()? now})
      : now = now ?? DateTime.now;
  final Directory root;
  final JdV2Acknowledge acknowledge;
  final DateTime Function() now;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _key(String value) => sha256.convert(utf8.encode(value)).toString();
  Directory get _directory => Directory(p.join(root.path, 'jd_v2_delivery'));
  File _file(String attemptId) =>
      File(p.join(_directory.path, '${_key(attemptId)}.json'));
  Future<void> _write(File file, Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }

  Future<void> register(
          {required String attemptId,
          required String customer,
          required String reply,
          required String receiptPath,
          required Map<String, dynamic> binding}) =>
      _serial(() async {
        for (final key in [
          'jobId',
          'customerUid',
          'historyVersion',
          'resultDigest'
        ]) {
          if (binding[key] is! String || (binding[key] as String).isEmpty) {
            throw const JdV2ApiException('invalid_delivery_binding');
          }
        }
        if (binding['customerUid'] != customer ||
            !RegExp(r'^[A-Za-z0-9_-]{1,256}$')
                .hasMatch(binding['jobId'] as String) ||
            !RegExp(r'^[a-fA-F0-9]{64}$')
                .hasMatch(binding['resultDigest'] as String) ||
            attemptId.isEmpty) {
          throw const JdV2ApiException('invalid_delivery_binding');
        }
        final file = _file(attemptId);
        final value = <String, dynamic>{
          'attemptId': attemptId,
          'customer': customer,
          'reply': reply,
          'receiptPath': receiptPath,
          'binding': {
            for (final key in [
              'jobId',
              'customerUid',
              'historyVersion',
              'resultDigest'
            ])
              key: binding[key]
          },
        };
        if (await file.exists()) {
          final existing = jsonDecode(await file.readAsString()) as Map;
          for (final key in value.keys) {
            if (jsonEncode(existing[key]) != jsonEncode(value[key])) {
              throw const JdV2ApiException('delivery_binding_conflict');
            }
          }
          return;
        }
        await _write(file, {...value, 'events': <dynamic>[]});
      });

  Future<void> reconcile() => _serial(() async {
        if (!await _directory.exists()) return;
        await for (final entity in _directory.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final record =
                jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
            final receiptFile = File(record['receiptPath'] as String);
            if (!await receiptFile.exists()) continue;
            final receipt = jsonDecode(await receiptFile.readAsString()) as Map;
            if (receipt['attemptId'] != record['attemptId'] ||
                receipt['customer'] != record['customer']) {
              continue;
            }
            final timestamp = receipt['timeMs'];
            if (timestamp is! num || !timestamp.isFinite || timestamp <= 0) {
              continue;
            }
            final phase = receipt['state'];
            final status = phase == 'submitted'
                ? 'sent'
                : (phase == 'rejected' || phase == 'not_sent')
                    ? 'failed'
                    : phase == 'unknown'
                        ? 'unknown'
                        : ({'clicked', 'click_intent'}.contains(phase) &&
                                now().millisecondsSinceEpoch - timestamp >
                                    60000)
                            ? 'unknown'
                            : null;
            if (status == null) continue;
            final events = record['events'] as List;
            // A receipt can be rewritten with a newer clock. Keep one event per
            // outcome; an unknown -> sent transition gets a distinct stable ID.
            if (events
                .any((event) => (event as Map)['body']['status'] == status)) {
              continue;
            }
            final binding = record['binding'] as Map;
            final clicked = receipt['sendClickedAtMs'];
            final occurred = status == 'sent' &&
                    clicked is num &&
                    clicked.isFinite &&
                    clicked > 0 &&
                    clicked <= timestamp
                ? clicked.toInt()
                : timestamp.toInt();
            final body = <String, dynamic>{
              'storeId': JdV2Client.storeId,
              'eventId': 'jd-${_key('${record['attemptId']}:$status')}',
              'status': status,
              'occurredAt':
                  DateTime.fromMillisecondsSinceEpoch(occurred, isUtc: true)
                      .toIso8601String(),
              'resultDigest': binding['resultDigest'],
              if (status == 'sent') 'actualSentText': record['reply'],
            };
            events.add({
              'jobId': binding['jobId'],
              'body': body,
              'recorded': false,
              'attempts': 0,
              'retryAtMs': 0
            });
            await _write(entity, record);
          } on Object {
            // Partial/corrupt/mismatched native receipts are never send proof.
          }
        }
      });

  bool _pumping = false;
  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final pending = await _serial(() async {
        final items = <Map<String, dynamic>>[];
        if (!await _directory.exists()) return items;
        await for (final entity in _directory.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final record = jsonDecode(await entity.readAsString()) as Map;
            for (final event in (record['events'] as List).cast<Map>()) {
              if (event['recorded'] == true ||
                  (event['retryAtMs'] as num) > now().millisecondsSinceEpoch) {
                continue;
              }
              items.add({
                'path': entity.path,
                'event': Map<String, dynamic>.from(event)
              });
            }
          } on Object {/* Continue other customers' ACKs. */}
        }
        return items;
      });
      for (final item in pending) {
        final event = item['event'] as Map<String, dynamic>;
        // Network I/O never holds the persistence lock used before Send.
        try {
          final result = await acknowledge(event['jobId'] as String,
              Map<String, dynamic>.from(event['body'] as Map));
          if (result['recorded'] != true || result['jobId'] != event['jobId']) {
            throw const JdV2ApiException('delivery_ack_unconfirmed');
          }
          event['recorded'] = true;
          event.remove('errorCode');
        } catch (_) {
          final attempts = (event['attempts'] as int) + 1;
          event['attempts'] = attempts;
          event['retryAtMs'] = now().millisecondsSinceEpoch +
              min(300, 2 << min(attempts, 7)) * 1000;
          event['errorCode'] = 'ack_failed';
        }
        await _serial(() async {
          final file = File(item['path'] as String);
          final record =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          final events = record['events'] as List;
          final index = events.indexWhere((value) =>
              (value as Map)['body']['eventId'] ==
              (event['body'] as Map)['eventId']);
          if (index >= 0) {
            events[index] = event;
            await _write(file, record);
          }
        });
      }
    } finally {
      _pumping = false;
    }
  }
}

/// Fire-and-forget integration hooks. Persistence before the physical send is
/// awaited; receipt recovery and remote ACKs run outside the customer send path.
class JdV2Delivery {
  static final Map<String, JdV2DeliveryOutbox> _outboxes = {};
  static final Map<String, Timer> _timers = {};
  static final Set<String> _recovering = {};

  static Future<JdV2DeliveryOutbox> _outbox(CaptureDatabase database) async {
    final root = await database.storageRoot;
    return _outboxes.putIfAbsent(
        root.path,
        () => JdV2DeliveryOutbox(root, acknowledge: (jobId, body) async {
              final config = await JdV2Config.load();
              final client =
                  JdV2Client(baseUri: config.baseUri, apiKey: config.apiKey);
              try {
                return await client.acknowledge(jobId, body);
              } finally {
                client.close();
              }
            }));
  }

  static Future<void> onAttempt(CaptureDatabase database, String customer,
      AiDraft draft, Map<String, String> attempt) async {
    final raw = jsonDecode(draft.rawJson);
    final binding = raw is Map ? raw['jd_v2'] : null;
    if (binding is! Map) return;
    await (await _outbox(database)).register(
        attemptId: attempt['attemptId']!,
        customer: customer,
        reply: draft.reply,
        receiptPath: attempt['receiptPath']!,
        binding: Map<String, dynamic>.from(binding));
    afterReceipts(database);
  }

  static void onConfirmed(CaptureDatabase database) => afterReceipts(database);

  static void afterReceipts(CaptureDatabase database) {
    unawaited(_recover(database));
  }

  static Future<void> _recover(CaptureDatabase database) async {
    String? rootPath;
    var acquired = false;
    try {
      rootPath = (await database.storageRoot).path;
      if (!_recovering.add(rootPath)) return;
      acquired = true;
      final outbox = await _outbox(database);
      // The app's attempt journal is the fallback if it exited between creating
      // the attempt and persisting our outbox entry.
      final db = await database.database;
      final rows = await db.query('delivery_attempts',
          where: "raw_json LIKE ?", whereArgs: ['%"jd_v2"%']);
      for (final row in rows) {
        try {
          final raw = jsonDecode(row['raw_json'] as String) as Map;
          if (raw['jd_v2'] is! Map) continue;
          await outbox.register(
              attemptId: row['attempt_id'] as String,
              customer: row['user_id'] as String,
              reply: row['reply'] as String,
              receiptPath: p.join(
                  rootPath, 'delivery_receipts', '${row['attempt_id']}.json'),
              binding: Map<String, dynamic>.from(raw['jd_v2'] as Map));
        } on Object {/* Invalid binding must never create an ACK. */}
      }
      await outbox.reconcile();
      await outbox.pump();
      _timers.remove(rootPath)?.cancel();
      _timers[rootPath] =
          Timer(const Duration(seconds: 15), () => afterReceipts(database));
    } on Object {
      // ACK/config/network failure cannot alter actual customer send outcomes.
    } finally {
      if (rootPath != null && acquired) _recovering.remove(rootPath);
    }
  }
}
