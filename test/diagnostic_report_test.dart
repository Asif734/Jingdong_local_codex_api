import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/runtime/diagnostic_report.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  late Directory root;
  late CaptureDatabase database;
  final started = DateTime.utc(2026, 11, 23, 1);
  final stopped = DateTime.utc(2026, 11, 23, 1, 1);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('diagnostic_export_');
    database = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    await database.beginAutomationSession(startedAt: started);
    final db = await database.database;
    await db.insert('automation_session_messages', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'alice',
      'message_id': 'm1',
      'input_kind': 'text',
      'activated_at_ms': started.millisecondsSinceEpoch + 1000,
    });
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('exports portable timeline and exact scoped conditions without secrets',
      () async {
    final db = await database.database;
    await db.insert('automation_message_evidence', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'alice',
      'message_id': 'm1',
      'evidence_key': jsonEncode({'evidenceId': 'ev1'}),
    });
    final image = File('${root.path}/crop.png');
    await image.writeAsBytes([1, 2, 3]);
    final manifest = File('${root.path}/manifest.json');
    await manifest.writeAsString(jsonEncode({
      'customer': 'alice',
      'evidenceId': 'ev1',
      'imagePath': image.path,
      'authorization': 'DO_NOT_EXPORT',
    }));
    await db.insert('capture_evidence', {
      'id': 'ev1',
      'customer': 'alice',
      'captured_at_ms': started.millisecondsSinceEpoch + 1500,
      'payload': jsonEncode({
        'customer': 'alice',
        'evidenceId': 'ev1',
        'manifestPath': manifest.path,
        'imagePath': image.path
      }),
      'state': 'failed',
      'last_error': 'crop_failed',
    });
    final trace = File('${root.path}/trace.jsonl');
    final event = {
      'pid': pid,
      'time': started.add(const Duration(seconds: 2)).toIso8601String(),
      'event': 'media.condition',
      'customer': 'alice',
      'evidenceId': 'ev1',
      'stage': 'crop',
      'conditionId': 'image.minimum_width',
      'expression': 'width >= minimum',
      'actual': {'width': 31},
      'threshold': {'minimum': 64},
      'passed': false,
      'outcome': 'blocked',
      'authorization': 'DO_NOT_EXPORT',
      'error': 'cache failed authorization=DO_NOT_EXPORT',
    };
    await trace.writeAsString([
      jsonEncode(event),
      jsonEncode({
        ...event,
        'pid': null,
        'actual': {'width': 55}
      }),
      jsonEncode({
        ...event,
        'pid': -123,
        'actual': {'width': 77}
      }),
      jsonEncode({
        ...event,
        'expectedMediaAtMs': started.millisecondsSinceEpoch,
        'actual': {'width': 66}
      }),
      jsonEncode({
        ...event,
        'customer': 'bob',
        'actual': {'width': 99}
      }),
      jsonEncode({
        ...event,
        'evidenceId': 'other',
        'actual': {'width': 88}
      }),
      jsonEncode({
        ...event,
        'time': started.subtract(const Duration(seconds: 1)).toIso8601String()
      }),
      jsonEncode({
        'pid': pid,
        'time': started.add(const Duration(seconds: 3)).toIso8601String(),
        'event': 'handoff.accounts_inspected',
        'customer': 'alice',
        'stageElapsedMs': {'initial_recognition': 1350, 'prepare_group': 25},
        'ocrRecognitionCount': 2,
        'groupLabelReuseCount': 1,
        'axProbeCount': 3,
        'statusSampleCount': 2,
        'axDiagnostics': {
          'staffRows': [
            {'name': '格志打印机文文（雯雯）', 'active': true}
          ]
        },
      }),
      '{malformed',
    ].join('\n'));
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {
        'model': 'example',
        'apiKey': 'DO_NOT_EXPORT',
        'hostedToken': 'DO_NOT_EXPORT'
      },
    );
    final raw = await result.jsonFile.readAsString();
    final report = jsonDecode(raw) as Map;
    expect(report['reportId'], result.reportId);
    final staff = (report['customerContextEvents'] as List)
        .whereType<Map>()
        .singleWhere((e) => e['event'] == 'handoff.accounts_inspected');
    expect(staff['ocrRecognitionCount'], 2);
    expect(staff['groupLabelReuseCount'], 1);
    expect(staff['stageElapsedMs']['initial_recognition'], 1350);
    expect(staff['axDiagnostics']['staffRows'][0]['name'], '格志打印机文文（雯雯）');

    final message = (report['messages'] as List).single as Map;
    expect(message['customerId'], 'alice');
    expect(message['stableId'], 'm1');
    final conditions = message['conditions'] as List;
    expect(conditions, hasLength(1));
    expect((conditions.single as Map)['actual'], {'width': 31});
    expect((conditions.single as Map)['attributionScope'], 'evidence_frame');
    expect((message['assessment'] as Map)['certainty'], 'observed_state');
    expect(
        report['traceWarnings'], contains('1 malformed trace line(s) ignored'));
    expect(raw, isNot(contains('DO_NOT_EXPORT')));
    final html = await result.htmlFile.readAsString();
    expect(html, contains('image.minimum_width'));
    expect(html, contains('31'));
    expect(html, contains('64'));
    final files = report['evidenceFiles'] as List;
    expect(files.where((f) => (f as Map)['status'] == 'copied'), hasLength(2));
    for (final file in files.where((f) => (f as Map)['status'] == 'copied')) {
      final packaged =
          File('${result.directory.path}/${(file as Map)['relativePath']}');
      expect(await packaged.exists(), isTrue);
      if (packaged.path.endsWith('.json')) {
        expect(await packaged.readAsString(), isNot(contains('DO_NOT_EXPORT')));
      }
    }
  });

  test('preserves a failed condition followed by success as separate attempts',
      () async {
    final db = await database.database;
    final trace = File('${root.path}/attempts.jsonl');
    await trace.writeAsString([
      for (final pass in [false, true])
        jsonEncode({
          'time':
              started.add(Duration(seconds: pass ? 4 : 2)).toIso8601String(),
          'pid': pid,
          'event': 'media.condition',
          'customer': 'alice',
          'messageId': 'm1',
          'conditionId': 'crop.width',
          'actual': {'width': pass ? 100 : 20},
          'threshold': {'minimum': 64},
          'passed': pass,
          'outcome': pass ? 'pass' : 'blocked',
        }),
    ].join('\n'));
    await db.update('automation_session_messages', {
      'response_state': 'answered',
      'responded_at_ms': started.millisecondsSinceEpoch + 5000
    });
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final message = (report['messages'] as List).single as Map;
    expect(message['status'], 'answered');
    expect((message['conditions'] as List).map((r) => r['outcome']),
        ['blocked', 'pass']);
    expect((report['summary'] as Map)['answered'], 1);
  });

  test('exports confirmed reply content by the exact bound delivery attempt',
      () async {
    final db = await database.database;
    await db.insert('delivery_attempts', {
      'attempt_id': 'attempt-1',
      'task_id': 'task-1',
      'user_id': 'alice',
      'pending_id': 1,
      'reply': 'The confirmed answer',
      'state': 'submitted',
      'created_at_ms': started.millisecondsSinceEpoch + 2000,
      'updated_at_ms': started.millisecondsSinceEpoch + 3000,
      'raw_json': jsonEncode({
        'service_session_id': database.currentAutomationSessionId,
        'service_message_ids': ['m1'],
        'native_confirmed_at_ms': started.millisecondsSinceEpoch + 3000,
        'native_reply_at_ms': started.millisecondsSinceEpoch + 2900,
        'authorization': 'DO_NOT_EXPORT'
      }),
    });
    await db.update('automation_session_messages', {
      'response_state': 'answered',
      'answered_attempt_id': 'attempt-1',
      'responded_at_ms': started.millisecondsSinceEpoch + 3000
    });
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final raw = await result.jsonFile.readAsString();
    final report = jsonDecode(raw) as Map;
    final message = (report['messages'] as List).single as Map;
    expect(message['replyAttemptId'], 'attempt-1');
    expect((message['deliveryAttempts'] as List).single['reply'],
        'The confirmed answer');
    expect(raw, isNot(contains('DO_NOT_EXPORT')));
  });

  test('keeps associated text separate from a media receipt', () async {
    final db = await database.database;
    await db.insert('customer_media_items', {
      'item_id': 'card-1',
      'customer': 'alice',
      'message_id': 'm1',
      'slot': 0,
      'kind': 'image',
      'state': 'discovered',
      'first_seen_ms': started.millisecondsSinceEpoch + 500,
      'last_seen_ms': started.millisecondsSinceEpoch + 500,
      'evidence_id': 'ev-other',
      'media_json': '[]',
      'aliases_json': '["m1"]',
    });
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final message = (report['messages'] as List).single as Map;
    expect(message['kind'], 'text');
    expect(message['canonicalIds'], ['m1']);
    expect(message['media'], isEmpty);
    expect(
        (report['unattributedEvidence'] as List).single['item_id'], 'card-1');
  });

  test(
      'binds delivery conditions to exact task inputs and rejects another task',
      () async {
    final db = await database.database;
    await db.insert('automation_reply_inputs', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'alice',
      'owner_id': 'task-1',
      'message_id': 'm1',
      'message_json': '{}',
    });
    final trace = File('${root.path}/delivery.jsonl');
    await trace.writeAsString([
      for (final task in ['task-1', 'other-task'])
        jsonEncode({
          'time': started.add(const Duration(seconds: 2)).toIso8601String(),
          'pid': pid,
          'event': 'delivery.condition',
          'customer': 'alice',
          'taskId': task,
          'stage': 'delivery.readiness',
          'conditionId': 'reply_inputs_ready',
          'actual': {'ready': false},
          'threshold': {'ready': true},
          'passed': false,
        }),
    ].join('\n'));
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final condition =
        ((report['messages'] as List).single['conditions'] as List).single;
    expect(condition['taskId'], 'task-1');
    expect(condition['attributionScope'], 'task_scope');
  });

  test('does not attach associated text identity to a canonical media message',
      () async {
    final db = await database.database;
    await db.insert('automation_session_messages', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'alice',
      'message_id': 'media-pending:card-1',
      'input_kind': 'media',
      'activated_at_ms': started.millisecondsSinceEpoch + 2000,
    });
    await db.insert('customer_media_items', {
      'item_id': 'card-1',
      'customer': 'alice',
      'message_id': 'm1',
      'slot': 0,
      'kind': 'image',
      'state': 'discovered',
      'first_seen_ms': started.millisecondsSinceEpoch + 500,
      'last_seen_ms': started.millisecondsSinceEpoch + 500,
      'media_json': '[]',
      'aliases_json': '["m1"]',
    });
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final media =
        (report['messages'] as List).singleWhere((r) => r['kind'] == 'image');
    expect(media['canonicalIds'], isNot(contains('m1')));
    expect((report['messages'] as List), hasLength(2));
  });

  test('includes drained diagnostic events while retaining user stop time',
      () async {
    final trace = File('${root.path}/drain.jsonl');
    await trace.writeAsString(jsonEncode({
      'time': stopped.add(const Duration(seconds: 1)).toIso8601String(),
      'pid': pid,
      'customer': 'alice',
      'messageId': 'm1',
      'event': 'media.condition',
      'conditionId': 'drained.crop',
      'sourceFile': 'Capture.swift',
      'sourceLine': 12,
      'sourceSymbol': 'crop',
      'actual': {'width': 1},
      'threshold': {'minimum': 2},
      'passed': false,
    }));
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      processingSettledAt: stopped.add(const Duration(seconds: 2)),
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect(report['runStoppedAt'], '2026-11-23T01:01:00.000Z');
    expect(report['processingSettledAt'], '2026-11-23T01:01:02.000Z');
    final condition =
        ((report['messages'] as List).single['conditions'] as List).single;
    expect(condition['sourceLine'], 12);
  });

  test('includes unadmitted media and evidence without inventing a message',
      () async {
    final db = await database.database;
    await db.insert('capture_evidence', {
      'id': 'orphan',
      'customer': 'lost-customer',
      'captured_at_ms': started.millisecondsSinceEpoch + 500,
      'payload': '{}',
      'state': 'failed',
      'last_error': 'crop_missing',
    });
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect((report['unattributedEvidence'] as List).single['customer'],
        'lost-customer');
    expect((report['messages'] as List), hasLength(1));
    expect(report['buildVersion'], isNotEmpty);
  });

  test('starts trace reads at the supplied byte boundary and skips old garbage',
      () async {
    final trace = File('${root.path}/offset.jsonl');
    const oldPrefix = '旧的运行日志，不是JSON\n';
    final offset = utf8.encode(oldPrefix).length;
    final eventLine = jsonEncode({
      'time': started.add(const Duration(seconds: 2)).toIso8601String(),
      'pid': pid,
      'event': 'media.condition',
      'customer': 'alice',
      'messageId': 'm1',
      'conditionId': 'current.run',
      'actual': {'width': 1},
      'threshold': {'minimum': 2},
    });
    await trace.writeAsString('$oldPrefix$eventLine\n');
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      traceStartOffset: offset,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect(report['traceByteRangeStart'], offset);
    expect(report['traceWarnings'], isEmpty);
    final message = (report['messages'] as List).single as Map;
    expect(
        (message['conditions'] as List).single['conditionId'], 'current.run');
  });

  test('falls back to byte zero with a warning after a trace is truncated',
      () async {
    final trace = File('${root.path}/rotated.jsonl');
    final eventLine = jsonEncode({
      'time': started.add(const Duration(seconds: 2)).toIso8601String(),
      'pid': pid,
      'event': 'media.condition',
      'customer': 'alice',
      'messageId': 'm1',
      'conditionId': 'after.rotation',
    });
    await trace.writeAsString('$eventLine\n');
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      traceStartOffset: 1000000,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect(report['traceByteRangeStart'], 0);
    expect((report['traceWarnings'] as List).single, contains('byte 0'));
    final message = (report['messages'] as List).single as Map;
    expect((message['conditions'] as List).single['conditionId'],
        'after.rotation');
  });

  test(
      'exports other customers when one history is corrupt and preserves source files',
      () async {
    final db = await database.database;
    await db.insert('automation_session_messages', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'bob',
      'message_id': 'bob-m1',
      'input_kind': 'text',
      'activated_at_ms': started.millisecondsSinceEpoch + 2000,
    });
    final history = await database.history;
    await history.conversationsDirectory.create(recursive: true);
    final corrupted = File(
        '${history.conversationsDirectory.path}/${history.safeUserId('alice')}.json');
    const damagedBytes = '{corrupt-history';
    await corrupted.writeAsString(damagedBytes);
    final before = jsonEncode(
        await db.query('automation_session_messages', orderBy: 'user_id'));
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect((report['messages'] as List).single['customerId'], 'bob');
    final failure = (report['timelineReadFailures'] as List).single as Map;
    expect(failure['customer'], 'alice');
    expect(failure['stage'], 'customerMessageRecords/readOnly');
    expect(failure['error'], contains('FormatException'));
    expect((failure['rawWork'] as List).single['message_id'], 'm1');
    expect(failure['bodyAvailability'], contains('不可用'));
    expect(await result.htmlFile.readAsString(), contains('消息时间线读取失败'));
    expect(await corrupted.readAsString(), damagedBytes);
    expect(
        jsonEncode(
            await db.query('automation_session_messages', orderBy: 'user_id')),
        before);
  });

  test('marks missing evidence and does not invent a causal threshold',
      () async {
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing')
            .export(
      database: database,
      outputDirectory: Directory('${root.path}/reports'),
      runStartedAt: started,
      runStoppedAt: stopped,
      settings: {},
    );
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final message = (report['messages'] as List).single as Map;
    expect(message['conditions'], isEmpty);
    expect((message['assessment'] as Map)['explanation'],
        contains('not recorded'));
    expect(report['traceWarnings'], contains('Runtime trace is missing.'));
    final db = await database.database;
    expect(
        (await db.query('automation_session_messages'))
            .single['response_state'],
        'pending');
  });
  test('uncertain receipt report identifies a message-only hold', () async {
    final db = await database.database;
    await db.insert('automation_message_waits', {
      'session_id': database.currentAutomationSessionId,
      'user_id': 'alice',
      'message_id': 'm1',
      'is_media': 0,
      'content_key': 'delivery-unknown-hold:old-attempt',
      'message_revision': 0,
      'task_id': 'old-task',
      'updated_at_ms': started.millisecondsSinceEpoch + 2000,
    });
    final trace = File('${root.path}/empty-trace.jsonl');
    await trace.writeAsString('');
    final result = await DiagnosticReportExporter(tracePath: trace.path).export(
        database: database,
        outputDirectory: Directory('${root.path}/reports'),
        runStartedAt: started,
        runStoppedAt: stopped,
        settings: {});
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    final message = (report['messages'] as List).single as Map;
    expect((message['assessment'] as Map)['step'],
        'uncertain_message_receipt_only_other_messages_continue');
    expect((message['assessment'] as Map)['explanation'], contains('仅限该条消息'));
    expect(((message['waits'] as List).single as Map)['content_key'],
        'delivery-unknown-hold:old-attempt');
  });
  test(
      'report preserves cancellation snapshot without claiming workers completed',
      () async {
    const summary = {
      'mode': 'cancelled_run',
      'localLeasesCancelled': 3,
      'viewport': {'registrationInFlight': true},
      'nativeCancellation': 'requested'
    };
    final result =
        await DiagnosticReportExporter(tracePath: '${root.path}/missing.jsonl')
            .export(
                database: database,
                outputDirectory: Directory('${root.path}/reports'),
                runStartedAt: started,
                runStoppedAt: stopped,
                stopSummary: summary,
                settings: {});
    final report = jsonDecode(await result.jsonFile.readAsString()) as Map;
    expect(report['stopSummary'], summary);
    expect(report['snapshot'], contains('已取消任务不再阻塞导出'));
    expect(await result.htmlFile.readAsString(), contains('停止时取消的任务'));
    expect(
        (await (await database.database).query('automation_session_messages'))
            .single['response_state'],
        'pending');
  });
}
