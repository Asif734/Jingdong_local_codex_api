import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

void main() {
  testWidgets(
      'formal commit wakes a captured later question before its collection timer',
      (tester) async {
    const customer = 'jd_v46_commit_buyer';
    const channel = MethodChannel('v46-main-submit-and-commit');
    late Directory root;
    late CaptureDatabase db;
    late CodexReplyService service;
    late File requestLog;
    late File hold;
    final snapshots = <String, Map<String, Object?>>{};
    final formal = <String>[];
    var phase = 'baseline';
    var active = customer;
    var fakeAdvanced = Duration.zero;
    late DateTime firstReceivedAt;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v46_main_commit_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
      final workspace = await Directory('${root.path}/workspace').create();
      final knowledge = await Directory('${root.path}/knowledge').create();
      await File('${knowledge.path}/printer_kb.md').writeAsString(
          'Use the supplied USB cable and the printer setup menu.');
      requestLog = File('${root.path}/requests.jsonl');
      hold = await File('${root.path}/hold')
          .writeAsString('hold first submitted CLI');
      final cli =
          await File('${root.path}/cli.py').writeAsString('''#!/usr/bin/python3
import sys,re,json,pathlib,time
args=sys.argv[1:]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
path=pathlib.Path(${jsonEncode(requestLog.path)})
with path.open('a') as f: f.write(json.dumps(request)+'\\n')
hold=pathlib.Path(${jsonEncode(hold.path)})
while hold.exists(): time.sleep(.005)
ids=[m['id'] for m in request['target_customer_batch']]
reply={'reply':'Use the supplied USB cable and the setup menu. '+', '.join(ids),'reply_purpose':'substantive','decision':'draft','confidence':.99,'risk_level':'low','auto_send_allowed':False,'human_review_required':False,'risk_triggers':[],'used_record_ids':[],'required_slots':[],'actions':[],'attachments':[],'image_descriptions':[]}
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(reply))
''');
      expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
      service = CodexReplyService(
          executable: cli.path,
          workspace: workspace,
          knowledgeDirectory: knowledge,
          outputSchema: File('${root.path}/reply.schema.json'),
          timeout: const Duration(seconds: 20),
          capacityRetryDelays: const []);
    });
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.runAsync(() async {
        if (await hold.exists()) await hold.delete();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    Future<Map<String, Object?>> snapshot(String name) async {
      if (snapshots[name] case final previous?) return previous;
      final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=');
      final image = await File('${root.path}/$name.png').writeAsBytes(bytes);
      final at = DateTime.now().toUtc();
      final values = <String, Object?>{
        'evidenceId': 'v46-home-$name',
        'customer': customer,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'automationSessionId': db.currentAutomationSessionId,
        'windowId': 1,
        'windowTitle': '客服-咚咚融合工作台',
        'windowBounds': {'x': 0, 'y': 0, 'width': 1440, 'height': 813},
        'imageWidth': 2880,
        'imageHeight': 1626,
        'imagePath': image.path,
        'manifestPath': '${root.path}/$name.capture.json',
        'pngSHA256': sha256.convert(bytes).toString(),
        'chatContentSHA256': 'actual-current-$name',
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
      };
      await File(values['manifestPath'] as String)
          .writeAsString(jsonEncode(values));
      snapshots[name] = values;
      return values;
    }

    String jdClock(DateTime at) {
      final jd = at.toUtc().add(const Duration(hours: 8));
      return '${jd.hour.toString().padLeft(2, '0')}:${jd.minute.toString().padLeft(2, '0')}:${jd.second.toString().padLeft(2, '0')}';
    }

    List<Map<String, Object?>> visibleQuestions({bool later = false}) => [
          {
            'text': '$customer ${jdClock(firstReceivedAt)}',
            'confidence': 1.0,
            'x': .27,
            'y': .27,
            'width': .3,
            'height': .02
          },
          {
            'text': 'Where is the printer setup menu?',
            'confidence': 1.0,
            'x': .28,
            'y': .31,
            'width': .32,
            'height': .022
          },
          if (later) ...[
            {
              // Two separate physical bubbles deliberately share a clock.
              // The visible first question proves the later one's order.
              'text': '$customer ${jdClock(firstReceivedAt)}',
              'confidence': 1.0,
              'x': .27,
              'y': .43,
              'width': .3,
              'height': .02
            },
            {
              'text': 'Which USB port should I connect the printer to?',
              'confidence': 1.0,
              'x': .28,
              'y': .48,
              'width': .32,
              'height': .022
            },
          ]
        ];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
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
              'customer': customer,
              'identitySource': 'ax',
              'unread': phase == 'later' && formal.isEmpty,
              'redClockPresent': phase == 'later' && formal.isEmpty,
              'evidenceAvailable': true,
              'unreadEvidence': phase == 'later' ? 1 : 0
            }
          ];
        case 'openConversation':
          active = args['expectedCustomer'] as String;
          return {'opened': true, 'customer': active};
        case 'recentMediaCacheRevision':
          return {'revision': 'none'};
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'captureViewportEvidence':
          return snapshot(phase);
        case 'inspectViewportEvidence':
          final values = jsonDecode(
              await File(args['manifestPath'] as String).readAsString()) as Map;
          final later = values['evidenceId'] == 'v46-home-later';
          return {
            'windowId': 1,
            'imageWidth': 2880,
            'imageHeight': 1626,
            'capturedAtMs': values['capturedAtMs'],
            'activeCustomerId': customer,
            'chatRegion': values['chatRegion'],
            'observations': later ? visibleQuestions(later: true) : [],
            'visualRegions': []
          };
        case 'scrollConversation':
          return {'scrolled': true};
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active
          };
        case 'sendDraftOnce':
          expect(active, args['expectedCustomer']);
          formal.add(args['reply'] as String);
          final stamp = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath'] as String).writeAsString(jsonEncode({
            'attemptId': args['attemptId'],
            'customer': active,
            'state': 'submitted',
            'timeMs': stamp,
            'sendClickedAtMs': stamp
          }));
          return {
            'sent': true,
            'customer': active,
            'activeCustomerId': active,
            'sendClickedAtMs': stamp,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': stamp
          };
      }
      return <String, Object?>{};
    });
    Future<void> tick([Duration advance = Duration.zero]) async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      fakeAdvanced += advance;
      await tester.pump(advance);
    }

    Future<T> query<T>(Future<T> Function() read) async {
      late T value;
      await tester.runAsync(() async {
        value = await read();
      });
      return value;
    }

    Future<void> until(Future<bool> Function() ready) async {
      for (var i = 0; i < 600; i++) {
        if (await ready()) return;
        await tick();
      }
      final ledger = await query(() async => (await db.database).query(
          'automation_session_messages',
          columns: ['message_id', 'input_kind', 'response_state'],
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, customer]));
      final evidence = await query(() async => (await db.database).query(
          'capture_evidence',
          columns: ['id', 'state'],
          where: 'customer=?',
          whereArgs: [customer]));
      expect(await ready(), isTrue,
          reason: 'phase=$phase sends=$formal snapshots=${snapshots.keys} '
              'ledger=$ledger evidence=$evidence');
    }

    Future<List<Map>> requests() => query(() async => await requestLog.exists()
        ? (await requestLog.readAsLines())
            .map((s) => jsonDecode(s) as Map)
            .toList()
        : []);
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            replyServiceOverride: service,
            batchCollectionWindowOverride: const Duration(days: 1),
            redClockTracker:
                RedClockTracker(monotonicMs: () => fakeAdvanced.inMilliseconds),
            scanIntervalOverride: const Duration(milliseconds: 100))));
    await grantRunPermissions(tester);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    await until(() async => find.text('Stop automation').evaluate().isNotEmpty);
    // The initial passive frame becomes Start baseline before test work arrives.
    await tick(const Duration(seconds: 1));
    await until(() async => (await query(() async => (await db.database).query(
            'capture_evidence',
            where: 'id=?',
            whereArgs: ['v46-home-baseline'])))
        .any((r) => r['state'] == 'processed'));
    await query(() async {
      firstReceivedAt = DateTime.now().toUtc();
      final parsed = const OcrCaptureExtractor().extract(OcrInspection.fromMap({
        'windowId': 1,
        'imageWidth': 2880,
        'imageHeight': 1626,
        'capturedAtMs': firstReceivedAt.millisecondsSinceEpoch,
        'activeCustomerId': customer,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
        'observations': visibleQuestions(),
        'visualRegions': <Map<String, Object?>>[]
      }));
      expect(parsed, isNotNull);
      expect(parsed!.messages, hasLength(1));
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: parsed.capturedAt,
          messages: parsed.messages));
    });
    await tick(const Duration(seconds: 1));
    await until(() async => (await requests()).length == 1);
    phase = 'later';
    await tick(const Duration(milliseconds: 200));
    await until(() async =>
        (await query(() async => (await db.database).query(
                'automation_session_messages',
                where: 'session_id=? AND user_id=?',
                whereArgs: [db.currentAutomationSessionId, customer])))
            .length ==
        2);
    await until(() async => (await query(() async => (await db.database).query(
            'capture_evidence',
            where: 'id=?',
            whereArgs: ['v46-home-later'])))
        .any((r) => r['state'] == 'processed'));
    expect(formal, isEmpty,
        reason: 'The first actual CLI is deliberately held');
    final frozenClock = fakeAdvanced;
    await query(() => hold.delete());
    // The later question's collection timer is held for one day. Neither
    // periodic maintenance nor elapsed wall time can naturally expire it;
    // native/formal commit must actively cancel it and wake the ready input.
    await until(() async => (await requests()).length == 2);
    expect(fakeAdvanced, frozenClock);
    expect(formal, hasLength(1));
    final second = (await requests()).last;
    expect((second['target_customer_batch'] as List), hasLength(1));
    expect((second['target_customer_batch'] as List).single['body'],
        contains('Which USB port'));
    await until(
        () async => (await query(() => db.unansweredWorkCounts())).isEmpty);
    expect(formal, hasLength(2));
    expect(await requests(), hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Stop automation'));
    await tick();
  }, skip: !Platform.isMacOS);
}
