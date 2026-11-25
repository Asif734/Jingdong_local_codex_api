import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/run_permissions.dart';

const _buyer = 'jd_41aeec7741d05';
const _questions = ['hi', 'how are you doing?', 'i need help'];
const _answers = {
  'hi': 'Hello. How can I help you today?',
  'how are you doing?': 'I am here and ready to help you.',
  'i need help': 'Please describe the issue you need help with.',
};
const _fixtures = 'test/fixtures/v41_existing_database';
const _oldMessage = 'old-business-before-upgrade';

/// Recorded v40 input runs through CaptureHome's actual existing-database open,
/// Start, acquisition, generation queue and native-confirmation paths.
/// Only the native adapter and AI answer are controlled; no real customer UI
/// or CLI is contacted by this regression.
class _ExistingDatabaseFlow {
  _ExistingDatabaseFlow(this.root, this.db, this.channel);
  final Directory root;
  final CaptureDatabase db;
  final MethodChannel channel;
  final frames = <String, Map<String, dynamic>>{};
  final frameAt = <String, int>{};
  final nativeFrames = <String, String>{};
  final inspections = <String, int>{};
  final sends = <String>[];
  final generated = <List<Map<String, dynamic>>>[];
  final trace = <String>[];
  String phase = 'baseline';
  final confirmedPhases = <String>{};
  final sendPhases = <String>[];
  bool thirdGenerationStarted = false;
  final releaseThirdGeneration = Completer<void>();
  String? active;
  int monotonic = 0;
  bool holdingSent = false;
  bool formalSent = false;
  bool running = false;
  Map<String, dynamic> document = {};

  Future<void> mount(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final name in ['baseline', 'hi', 'how-are-you', 'need-help']) {
        frames[name] =
            jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
                as Map<String, dynamic>;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      trace.add(call.method);
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [
            {
              'customer': _buyer,
              'identitySource': 'ax',
              'unread': false,
              'redClockPresent':
                  phase != 'baseline' && !confirmedPhases.contains(phase),
              'evidenceAvailable': true,
              'unreadEvidence': 0,
            }
          ];
        case 'openConversation':
          expect(args['expectedCustomer'], _buyer);
          active = _buyer;
          return {'opened': true, 'customer': _buyer};
        case 'scrollConversation':
          return {'scrolled': true};
        case 'captureViewportEvidence':
          final restore = args['historyCutoffs'] as Map? ?? const {};
          final cutoff = args['historyCutoffMs'] ?? restore[_buyer];
          final history = cutoff != null;
          final name = '${history ? 'history-' : ''}recorded-$phase';
          final source = frames[phase]!;
          final directory = await Directory('${root.path}/capture_evidence')
              .create(recursive: true);
          final image = File('${directory.path}/$name.png');
          final manifest = File('${directory.path}/$name.json');
          final bytes = await File('$_fixtures/$phase.png').readAsBytes();
          await image.writeAsBytes(bytes);
          nativeFrames[manifest.path] = phase;
          final receivedAt = frameAt.putIfAbsent(
              name, () => DateTime.now().millisecondsSinceEpoch);
          final metadata = {
            'evidenceId': name,
            'customer': _buyer,
            'automationSessionId': db.currentAutomationSessionId,
            'capturedAtMs': receivedAt,
            'imageWidth': source['imageWidth'],
            'imageHeight': source['imageHeight'],
            'windowId': source['windowId'],
            'chatRegion': source['chatRegion'],
            'imagePath': image.path,
            'manifestPath': manifest.path,
            'pngSHA256': sha256.convert(bytes).toString(),
            'chatContentSHA256': 'recorded-transcript-$phase',
            'recordedCapturedAtMs': source['capturedAtMs'],
            'recordedEvidenceId': source['evidenceId'],
            if (history) 'historyCutoffMs': cutoff,
          };
          await manifest.writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          final name = nativeFrames[args['manifestPath']]!;
          inspections.update(name, (n) => n + 1, ifAbsent: () => 1);
          final metadata = jsonDecode(
              await File(args['manifestPath'] as String).readAsString()) as Map;
          return {
            ...frames[name]!,
            'evidenceId': metadata['evidenceId'],
            'capturedAtMs': metadata['capturedAtMs'],
            'pngBase64':
                base64Encode(await File('$_fixtures/$name.png').readAsBytes()),
          };
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'recentMediaCacheRevision':
          return {'revision': 'no-new-customer-file'};
        case 'cropViewportEvidence':
          // This real customer sent text. An unknown crop cannot produce
          // an image/video original or satisfy media-analysis readiness.
          return {
            'kind': 'unknown',
            'captureSource': 'frozen-window-crop',
            'reason': 'no_media_object_in_clipped_text_bubble',
          };
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active,
          };
        case 'sendDraftOnce':
          expect(args['expectedCustomer'], _buyer);
          expect(active, _buyer);
          final reply = args['reply'] as String;
          sends.add(reply);
          sendPhases.add(phase);
          confirmedPhases.add(phase);
          if (isHoldingReply(reply)) {
            holdingSent = true;
          } else {
            formalSent = true;
          }
          return {
            'sent': true,
            'customer': _buyer,
            'activeCustomerId': _buyer,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch,
          };
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      redClockTracker: RedClockTracker(monotonicMs: () => monotonic),
      scanIntervalOverride: const Duration(milliseconds: 150),
      generateDraftOverride: (customer, database, end, cancellation) async {
        final inputs = await database.generationMessages(customer.userId,
            batchEndMessageId: end);
        generated.add(inputs
            .where((message) => message['direction'] == 'incoming')
            .toList());
        final current = inputs
            .where((message) => message['direction'] == 'incoming')
            .toList();
        expect(current, hasLength(1));
        final question = current.single['body'] as String;
        expect(_questions, contains(question));
        if (question == 'i need help') {
          thirdGenerationStarted = true;
          await releaseThirdGeneration.future;
        }
        return AiDraft.fromJson({
          'reply': _answers[question],
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-recorded-existing-database',
          'auto_send_allowed': true,
          'actions': [],
          'attachments': [],
        }, mediaBaseUrl: Uri());
      },
    )));
    await grantRunPermissions(tester);
    await until(
        tester,
        () =>
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Start automation'))
                .onPressed !=
            null);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    running = true;
  }

  Future<void> tick(WidgetTester tester, {int steps = 1}) async {
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final history = File('${root.path}/$_buyer.json');
        if (await history.exists()) {
          document =
              jsonDecode(await history.readAsString()) as Map<String, dynamic>;
        }
      });
      monotonic += 100;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() ready,
      {int steps = 400}) async {
    for (var i = 0; i < steps && !ready(); i++) {
      await tick(tester);
    }
    expect(ready(), isTrue,
        reason: 'phase=$phase inspected=$inspections generated=$generated '
            'sends=$sends trace=${trace.take(50).toList()}');
  }

  Future<T> query<T>(WidgetTester tester, Future<T> Function() read) async {
    var ready = false;
    T? value;
    Object? error;
    await tester.runAsync(() async {
      unawaited(read().then((result) {
        value = result;
        ready = true;
      }, onError: (Object failure) {
        error = failure;
        ready = true;
      }));
    });
    await until(tester, () => ready);
    if (error != null) throw error!;
    return value as T;
  }

  Future<List<Map<String, Object?>>> work(WidgetTester tester) => query(
      tester,
      () async => (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _buyer],
          orderBy: 'activated_at_ms,rowid'));

  Future<void> close(WidgetTester tester) async {
    if (running) {
      await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    }
    if (!releaseThirdGeneration.isCompleted) releaseThirdGeneration.complete();
    await tick(tester, steps: 15);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

/// Reproduce the shipped v34 table exactly, including a previous business row.
/// Constructing it through native SQLite SQL avoids assuming DROP COLUMN is
/// supported on every developer Mac. Only a disposable test database is edited.
Future<(CaptureDatabase, String)> _legacyDatabase(Directory root) async {
  final seed = CaptureDatabase(storageRoot: root);
  final oldSession = await seed.beginAutomationSession(
      startedAt: DateTime.now().subtract(const Duration(minutes: 10)));
  await seed.saveCapture(CapturedConversation(
    stableKey: _buyer,
    customerName: _buyer,
    customerExternalId: _buyer,
    automationSessionId: oldSession,
    capturedAt: DateTime.now().subtract(const Duration(minutes: 9)),
    messages: [
      CapturedMessage(
        stableId: _oldMessage,
        direction: 'incoming',
        body: 'Previous session question must not resume after Start.',
        sender: _buyer,
        sentAt: DateTime.utc(2026, 11, 7, 1),
        axPath: 'previous business fixture',
      )
    ],
  ));
  expect(await seed.hasPendingUnanswered(_buyer), isTrue);
  await seed.close();
  final legacy = await databaseFactoryFfi.openDatabase(
      '${root.path}/jd_automation.sqlite3',
      options: OpenDatabaseOptions(singleInstance: false));
  try {
    await legacy.transaction((txn) async {
      await txn.execute(
          'ALTER TABLE automation_session_messages RENAME TO prior_automation_session_messages');
      await txn.execute("""CREATE TABLE automation_session_messages(
        session_id TEXT NOT NULL,user_id TEXT NOT NULL,message_id TEXT NOT NULL,
        activated_at_ms INTEGER NOT NULL,response_state TEXT NOT NULL DEFAULT 'pending',
        answered_task_id TEXT,answered_attempt_id TEXT,responded_at_ms INTEGER,
        work_revision INTEGER NOT NULL DEFAULT 0,evidence_key TEXT,
        input_kind TEXT NOT NULL DEFAULT 'unknown',
        PRIMARY KEY(session_id,user_id,message_id))""");
      const columns =
          'session_id,user_id,message_id,activated_at_ms,response_state,'
          'answered_task_id,answered_attempt_id,responded_at_ms,work_revision,evidence_key,input_kind';
      await txn.execute('INSERT INTO automation_session_messages($columns) '
          'SELECT $columns FROM prior_automation_session_messages');
      await txn.execute('DROP TABLE prior_automation_session_messages');
    });
    await legacy.execute('PRAGMA user_version=34');
    expect((await legacy.rawQuery('PRAGMA user_version')).single.values.single,
        34);
    expect(
        (await legacy
                .rawQuery('PRAGMA table_info(automation_session_messages)'))
            .map((row) => row['name']),
        isNot(contains('input_key')));
    expect(
        await legacy.query('automation_session_messages',
            where: 'session_id=? AND message_id=?',
            whereArgs: [oldSession, _oldMessage]),
        hasLength(1));
  } finally {
    await legacy.close();
  }
  // Intentionally unopened: CaptureHome's own initialization opens/upgrades it.
  return (CaptureDatabase(storageRoot: root), oldSession);
}

void main() {
  testWidgets(
      'existing v34 database upgrades before three recorded customer texts enter real reply flow',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late _ExistingDatabaseFlow flow;
    late String oldSession;
    await tester.runAsync(() async {
      final root =
          await Directory.systemTemp.createTemp('jd_v41_existing_recorded_');
      final legacy = await _legacyDatabase(root);
      oldSession = legacy.$2;
      flow = _ExistingDatabaseFlow(root, legacy.$1,
          const MethodChannel('v41.recorded-existing-database'));
    });
    try {
      await flow.mount(tester);
      await flow.until(tester, () => (flow.inspections['baseline'] ?? 0) > 0);
      var baselineReady = false;
      for (var i = 0; i < 120 && !baselineReady; i++) {
        baselineReady = await flow.query(
            tester,
            () async => (await (await flow.db.database).query(
                    'capture_evidence',
                    where: "id='recorded-baseline' AND state='processed'"))
                .isNotEmpty);
        if (!baselineReady) await flow.tick(tester);
      }
      expect(baselineReady, isTrue);
      expect(await flow.work(tester), isEmpty,
          reason:
              'Start archives previous business and visible yesterday bubbles.');
      final readyColumns = await flow.query(
          tester,
          () async => (await (await flow.db.database)
                  .rawQuery('PRAGMA table_info(automation_session_messages)'))
              .map((row) => row['name'])
              .toSet());
      expect(readyColumns, contains('input_key'));
      expect(
          await flow.query(
              tester,
              () async => (await (await flow.db.database)
                      .rawQuery('PRAGMA user_version'))
                  .single
                  .values
                  .single),
          35);
      expect(
          await flow.query(
              tester,
              () async => (await (await flow.db.database).query(
                      'automation_session_messages',
                      where: 'session_id=? AND message_id=?',
                      whereArgs: [oldSession, _oldMessage]))
                  .single['response_state']),
          'pending',
          reason:
              'Migration and Start preserve old business as history, without marking it answered.');
      for (final phase in ['hi', 'how-are-you']) {
        flow.phase = phase;
        await flow.until(
            tester,
            () => flow.sendPhases.asMap().entries.any((entry) =>
                entry.value == phase &&
                !isHoldingReply(flow.sends[entry.key])));
        List<Map<String, Object?>> work = [];
        for (var i = 0; i < 100; i++) {
          work = await flow.work(tester);
          if (work.isNotEmpty &&
              work.every((row) => row['response_state'] == 'answered')) {
            break;
          }
          await flow.tick(tester);
        }
        expect(
            work.every((row) => row['response_state'] == 'answered'), isTrue);
      }
      flow.phase = 'need-help';
      await flow.until(tester, () => flow.thirdGenerationStarted);
      var work = await flow.work(tester);
      expect(work, hasLength(3));
      expect(work.where((row) => row['response_state'] == 'pending'),
          hasLength(1));
      await flow.until(tester,
          () => flow.holdingSent && flow.sendPhases.last == 'need-help');
      work = await flow.work(tester);
      expect(
          work.where((row) => row['response_state'] == 'pending'), hasLength(1),
          reason:
              'A holding acknowledgement cannot complete the real third question.');
      expect(
          await flow.query(tester, flow.db.unansweredWorkCounts), {_buyer: 1});
      await flow.tick(tester, steps: 25);
      final thirdHoldingCount = List.generate(flow.sends.length, (i) => i)
          .where((i) =>
              flow.sendPhases[i] == 'need-help' &&
              isHoldingReply(flow.sends[i]))
          .length;
      expect(thirdHoldingCount, 1,
          reason: 'The same AX red cycle gets one holding message.');
      flow.releaseThirdGeneration.complete();
      for (var i = 0;
          i < 250 && work.any((row) => row['response_state'] != 'answered');
          i++) {
        await flow.tick(tester);
        work = await flow.work(tester);
      }
      expect(work, hasLength(3));
      expect(work.every((row) => row['input_kind'] == 'text'), isTrue);
      expect(
          work.every(
              (row) => (row['input_key'] as String?)?.isNotEmpty == true),
          isTrue);
      expect(
          work.every((row) =>
              row['response_state'] == 'answered' &&
              row['answered_attempt_id'] != null &&
              row['responded_at_ms'] != null),
          isTrue);
      expect(flow.generated.expand((batch) => batch).map((m) => m['body']),
          _questions);
      expect(
          flow.generated
              .expand((batch) => batch)
              .any((m) => m['id'] == _oldMessage),
          isFalse);
      expect(
          flow.sends.where((reply) => !isHoldingReply(reply)), _answers.values);
      expect(await flow.query(tester, flow.db.unansweredWorkCounts), isEmpty);
      final errors = await flow.query(
          tester,
          () async => (await (await flow.db.database).query('capture_evidence'))
              .where((row) => row['last_error'] != null)
              .toList());
      expect(errors, isEmpty,
          reason:
              'Actual recorded acquisition must not hide registration SQL errors.');
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close(tester);
    }
  });
}
