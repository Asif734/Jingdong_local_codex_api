import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

AiDraft answer(String customer) => AiDraft.fromJson({
      'reply':
          'Real answer for $customer: check the paper and run the self-test.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'session-test',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false
    }, mediaBaseUrl: Uri());
AiDraft handoff() => AiDraft.fromJson({
      'reply': 'Internal transfer decision, never send as a business answer.',
      'decision': 'human_review_required',
      'human_review_required': true,
      'risk_triggers': ['explicit_human_request'],
      'reason': 'Customer requested a colleague',
      'confidence': 1,
      'risk_level': 'medium',
      'model': 'session-test',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false
    }, mediaBaseUrl: Uri());

class _Flow {
  _Flow(this.root, this.db, this.channel);
  final Directory root;
  final CaptureDatabase db;
  final MethodChannel channel;
  int mono = 0;
  bool realClock = false;
  final watch = Stopwatch()..start();
  bool running = false;
  bool failHandoff = false;
  bool noAgents = false;
  bool captureFixture = false;
  bool rowUnread = true;
  bool returnCachedImage = false;
  int cacheCaptures = 0;
  final cacheClocks = <int>[];
  Completer<void>? ocrGate;
  int captureSerial = 0, oldInspects = 0, newInspects = 0;
  DateTime? fixtureMessageAt;
  final red = <String>{};
  final sent = <String>[];
  final replies = <String>[];
  final nativeCalls = <String>[];
  late RedClockTracker clock;
  int transferCalls = 0, staffChecks = 0;
  Future<AiDraft> Function(ConversationSummary, CaptureDatabase, String,
      CodexGenerationCancellation)? generate;

  Future<void> incoming(String customer, String id, {String? body}) async {
    final at = DateTime.now().toUtc();
    await db.saveCapture(
        CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            capturedAt: at,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: body ?? 'I have an issue with M880 $id',
                  sentAt: at,
                  axPath: 'fixture')
            ]),
        activeIncomingIds: {id});
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1250, 950);
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      final args = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'setAutomationEpoch':
          return {};
        case 'listConversationRows':
          return [
            for (final c in red)
              {
                'customer': c,
                'identitySource': 'ax',
                'unread': rowUnread,
                'unreadEvidence': 1,
                'redClockPresent': true,
                'evidenceAvailable': true
              }
          ];
        case 'captureViewportEvidence':
          if (!captureFixture) {
            throw PlatformException(code: 'snapshot_chat_missing');
          }
          final fresh = red.contains('jd_fixture');
          if (fresh) {
            fixtureMessageAt ??=
                DateTime.now().subtract(const Duration(seconds: 1));
          }
          final id = fresh ? 'new-${++captureSerial}' : 'old-selected';
          final image = File('${root.path}/$id.png');
          final manifest = File('${root.path}/$id.json');
          await image.writeAsBytes([1]);
          await manifest.writeAsString('{}');
          return {
            'evidenceId': id,
            'customer': 'jd_fixture',
            'imagePath': image.path,
            'manifestPath': manifest.path,
            'capturedAtMs': DateTime.now().millisecondsSinceEpoch
          };
        case 'inspectViewportEvidence':
          final fresh = (args['manifestPath'] as String)
              .split('/')
              .last
              .startsWith('new-');
          if (fresh) {
            newInspects++;
          } else {
            oldInspects++;
          }
          if (ocrGate case final gate?) await gate.future;
          final at = fixtureMessageAt ??
              DateTime.now().subtract(const Duration(days: 1));
          final stamp = at
              .toUtc()
              .add(const Duration(hours: 8))
              .toIso8601String()
              .substring(0, 19)
              .replaceFirst('T', ' ');
          return {
            'windowId': 7,
            'imageWidth': 1600,
            'imageHeight': 1200,
            'pngBase64':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
            'activeCustomerId': 'jd_fixture',
            'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
            'chatRegion': {'left': .2, 'right': .8, 'top': .25, 'bottom': .85},
            'observations': [
              {
                'text': 'jd_fixture $stamp',
                'confidence': 1.0,
                'x': .24,
                'y': .30,
                'width': .3,
                'height': .02
              },
              {
                'text': 'My printer does not print',
                'confidence': 1.0,
                'x': .24,
                'y': .35,
                'width': .3,
                'height': .02
              }
            ],
            'visualRegions': []
          };
        case 'captureRecentCachedMedia':
          cacheCaptures++;
          cacheClocks.add(args['expectedMediaAtMs'] as int);
          if (!returnCachedImage) return {'kind': 'none'};
          return {
            'kind': 'image',
            'cacheKey': 'red-only-original',
            'cacheModifiedAtMs': args['expectedMediaAtMs'],
            'dataBase64':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
            'mimeType': 'image/png',
            'extension': 'png',
            'originalName': 'original.png'
          };
        case 'openConversation':
          return {'opened': true, 'customer': args['expectedCustomer']};
        case 'listActiveTransferAccounts':
          staffChecks++;
          return {
            'accounts': noAgents ? <String>[] : ['other_agent'],
            'sourceAccount': 'source_agent'
          };
        case 'cancelTransferSelection':
          return {'closed': true};
        case 'sendDraftOnce':
          final c = args['expectedCustomer'] as String;
          final text = args['reply'] as String;
          sent.add(c);
          replies.add(text);
          red.remove(c);
          return {
            'sent': true,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch
          };
        case 'transferConversation':
          transferCalls++;
          if (failHandoff) {
            return {
              'error': 'transfer_action_missing',
              'attemptId': args['attemptId'],
              'transferClicked': false,
              'receiptState': 'not_clicked'
            };
          }
          return {
            'transferred': true,
            'customer': args['expectedCustomer'],
            'targetAccount': args['targetAccount'],
            'attemptId': args['attemptId'],
            'receiptState': 'confirmed',
            'transferClicked': true
          };
      }
      return {};
    });
    clock = RedClockTracker(
        monotonicMs: () => realClock ? watch.elapsedMilliseconds : mono);
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            redClockTracker: clock,
            generateDraftOverride: (c, d, b, x) =>
                generate?.call(c, d, b, x) ?? Future.value(answer(c.userId)))));
    await grantRunPermissions(tester);
    await start(tester);
  }

  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    running = true;
    await drive(tester, steps: 5);
  }

  Future<void> stop(WidgetTester tester) async {
    if (!running) return;
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    running = false;
    await drive(tester, steps: 5);
  }

  Future<void> drive(WidgetTester tester,
      {int steps = 50, bool Function()? until}) async {
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      mono += 200;
      await tester.pump(const Duration(milliseconds: 200));
      if (until?.call() == true) break;
    }
  }

  Future<void> close(WidgetTester tester) async {
    await stop(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void main() {
  Future<_Flow> fixture(WidgetTester tester, String name) async {
    late _Flow flow;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('v31_main_$name');
      flow = _Flow(dir, CaptureDatabase(storageRoot: dir),
          MethodChannel('v31.session.$name'));
      await flow.db.database;
    });
    return flow;
  }

  testWidgets(
      'new Start archives old blocked work and fast current answer does not need holding',
      (tester) async {
    final f = await fixture(tester, 'fresh');
    await tester.runAsync(() async {
      await f.incoming('A', 'old-refund', body: 'refund my old order');
      final q = (await f.db.conversation('A'))!;
      await f.db.saveDraft(q.id, handoff(),
          expectedMessageId: 'old-refund', deliverable: false);
      final ticket = await f.db.createHumanReviewTicket(
          userId: 'A',
          customerRequest: 'refund old order',
          reason: 'old business',
          requestMessageId: 'old-refund');
      await f.db
          .markTicketHandoffBlocked(ticket.id, 'previous_transfer_unknown');
    });
    final activeBodies = <String>[];
    f.generate = (c, d, b, x) async {
      activeBodies.addAll((await d.processingMessages(c.userId))
          .where((m) => m['direction'] == 'incoming')
          .map((m) => m['body'].toString()));
      return answer(c.userId);
    };
    await f.mount(tester);
    expect(f.sent, isEmpty);
    expect(f.staffChecks, 0);
    await tester.runAsync(() => f.incoming('A', 'new-hi', body: 'hi'));
    await f.drive(tester, until: () => f.replies.contains(answer('A').reply));
    await f.drive(tester, steps: 5);
    expect(f.replies, [answer('A').reply]);
    expect(activeBodies, ['hi']);
    expect(f.transferCalls, 0);
    await tester.runAsync(() async {
      expect(await f.db.answeredMessageId('A'), 'new-hi');
      expect((await (await f.db.history).read('A'))!['messages'].toString(),
          contains('refund my old order'));
    });
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'slow current generation gets one holding then still sends its real answer',
      (tester) async {
    final f = await fixture(tester, 'slow');
    f.realClock = true;
    final gate = Completer<AiDraft>();
    var generated = 0;
    f.generate = (c, d, b, x) {
      generated++;
      return gate.future;
    };
    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'issue'));
    f.red.add('A');
    // Start runs real file/SQLite work, so its real Timer must also be allowed
    // to reach the genuine twenty-second deadline rather than pumping only.
    await f.drive(tester,
        steps: 1200, until: () => f.replies.any(isHoldingReply));
    final state = await tester.runAsync(() async => {
          'cycle': await f.db.platformResponseCycle('A'),
          'sla': await (await f.db.database).query('sla_fallbacks'),
          'unavailable':
              await (await f.db.database).query('unavailable_conversations')
        });
    expect(generated, 1);
    expect(f.replies.where(isHoldingReply), hasLength(1),
        reason:
            'mono=${f.mono} remaining=${f.clock.remaining('A')} state=$state calls=${f.nativeCalls}');
    gate.complete(answer('A'));
    await f.drive(tester, until: () => f.replies.contains(answer('A').reply));
    await f.drive(tester, steps: 5);
    expect(f.replies.where(isHoldingReply), hasLength(1));
    expect(f.replies, contains(answer('A').reply));
    await tester.runAsync(() async {
      expect(await f.db.pendingMessageId('A'), isNull);
      expect(await f.db.answeredMessageId('A'), 'issue');
    });
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'ACK then failed transfer continues A real answer while B is served',
      (tester) async {
    final f = await fixture(tester, 'fair');
    f.failHandoff = true;
    final calls = <String, int>{};
    f.generate = (c, d, b, x) async {
      final n = (calls[c.userId] ?? 0) + 1;
      calls[c.userId] = n;
      return c.userId == 'A' && n == 1 ? handoff() : answer(c.userId);
    };
    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'ask-human'));
    await f.drive(tester, steps: 50, until: () => f.transferCalls > 0);
    await tester.runAsync(() => f.incoming('B', 'normal'));
    await f.drive(tester,
        steps: 120,
        until: () =>
            f.replies.contains(answer('A').reply) &&
            f.replies.contains(answer('B').reply));
    await f.drive(tester, steps: 5);
    final logs = await tester.runAsync(
        () async => (await f.db.database).query('chat_transfer_logs'));
    expect(f.transferCalls, 1,
        reason:
            'calls=${f.nativeCalls} generated=$calls replies=${f.replies} logs=$logs');
    expect(f.replies, contains(answer('A').reply));
    expect(f.replies, contains(answer('B').reply));
    expect(f.replies.any((r) => r.contains('transferring')), isTrue);
    expect(f.replies.where((r) => r == handoff().reply), isEmpty);
    await tester.runAsync(() async {
      expect(await f.db.isHumanContacting('A'), isFalse);
      expect(await f.db.answeredMessageId('A'), 'ask-human');
      expect(await f.db.answeredMessageId('B'), 'normal');
    });
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'Stop Start drops old generation but current message can get a new worker',
      (tester) async {
    final f = await fixture(tester, 'restart');
    final old = Completer<AiDraft>();
    var calls = 0;
    f.generate = (c, d, b, x) {
      calls++;
      return b == 'old-run' ? old.future : Future.value(answer(c.userId));
    };
    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'old-run'));
    await f.drive(tester, until: () => calls == 1);
    expect(calls, 1);
    await f.stop(tester);
    await f.start(tester);
    await tester.runAsync(() => f.incoming('A', 'new-run'));
    await f.drive(tester, until: () => f.replies.contains(answer('A').reply));
    old.complete(handoff());
    await f.drive(tester, steps: 10);
    expect(f.replies, [answer('A').reply]);
    expect(f.transferCalls, 0);
    await tester.runAsync(() async {
      expect(await f.db.answeredMessageId('A'), 'new-run');
    });
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'A no-agent todo keeps AI serving while B gets its holding and final answer',
      (tester) async {
    final f = await fixture(tester, 'no-agent');
    f.noAgents = true;
    f.realClock = true;
    final b = Completer<AiDraft>();
    final calls = <String, int>{};
    f.generate = (c, d, batch, x) {
      final n = (calls[c.userId] ?? 0) + 1;
      calls[c.userId] = n;
      if (c.userId == 'B') return b.future;
      return Future.value(n == 1 ? handoff() : answer(c.userId));
    };
    Future<void> reachWorkflowStage(
        bool Function() reached, String stage) async {
      final elapsed = Stopwatch()..start();
      while (!reached() && elapsed.elapsed < const Duration(seconds: 10)) {
        await f.drive(tester, steps: 1);
      }
      expect(reached(), isTrue, reason: stage);
    }

    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'help-A'));
    // This is a real-clock flow with two generation leases and an intervening
    // transfer attempt. Wait for its stages instead of assuming all of that
    // storage work finishes in drive's default one-second wall-clock window.
    await reachWorkflowStage(
        () => f.staffChecks == 1, 'The no-agent inspection must run.');
    await reachWorkflowStage(() => calls['A'] == 2,
        'A must resume business generation after the no-agent fallback.');
    await reachWorkflowStage(() => f.replies.contains(answer('A').reply),
        'A must send its real business answer after the failed handoff.');
    expect(f.staffChecks, 1);
    expect(f.replies, contains(answer('A').reply));
    expect(f.transferCalls, 0);
    await tester.runAsync(() => f.incoming('B', 'help-B'));
    f.red.add('B');
    await f.drive(tester,
        steps: 1200, until: () => f.replies.any(isHoldingReply));
    expect(f.replies.where(isHoldingReply), hasLength(1));
    expect(f.sent.last, 'B');
    b.complete(answer('B'));
    await reachWorkflowStage(() => f.replies.contains(answer('B').reply),
        'B must send its real answer after its red-clock holding reply.');
    await f.drive(tester, steps: 5);
    expect(f.replies, contains(answer('B').reply));
    expect(f.staffChecks, 1,
        reason:
            'Background retry must retain its real backoff instead of polling/clicking repeatedly');
    await tester.runAsync(() async {
      expect(await f.db.answeredMessageId('A'), 'help-A');
      expect(await f.db.answeredMessageId('B'), 'help-B');
      expect(
          (await (await f.db.database).query('human_review_tickets'))
              .single['status'],
          'open');
    });
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'first passive frame establishes history baseline once; current red frame can generate',
      (tester) async {
    final f = await fixture(tester, 'history-only');
    f.captureFixture = true;
    f.realClock = true;
    final bodies = <String>[];
    f.generate = (c, d, b, x) async {
      bodies.addAll((await d.processingMessages(c.userId))
          .map((m) => m['body'].toString()));
      return answer(c.userId);
    };
    await f.mount(tester);
    expect(find.text('v0.1.74+75'), findsOneWidget);
    await f.drive(tester, steps: 100, until: () => f.oldInspects > 0);
    await f.drive(tester, steps: 12);
    expect(f.oldInspects, 1);
    expect(f.newInspects, 0);
    expect(bodies, isEmpty);
    expect(f.sent, isEmpty);
    await tester.runAsync(() async {
      final rows = await (await f.db.database).query('capture_evidence',
          where: 'id=?', whereArgs: ['old-selected']);
      expect(rows.single['state'], 'processed');
      expect(await File('${f.root.path}/old-selected.png').exists(), isTrue);
      expect(await File('${f.root.path}/old-selected.json').exists(), isTrue);
      expect(await (await f.db.database).query('pending_customers'), isEmpty);
    });
    f.red.add('jd_fixture');
    await f.drive(tester,
        steps: 200,
        until: () => f.replies.contains(answer('jd_fixture').reply));
    await f.drive(tester, steps: 5);
    expect(f.oldInspects, 1,
        reason: 'Unchanged transcript content must not repeat baseline OCR');
    expect(f.newInspects, greaterThan(0));
    expect(bodies, contains('My printer does not print'));
    expect(f.replies, contains(answer('jd_fixture').reply));
    expect(f.replies.where(isHoldingReply), isEmpty);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'selected AX red without unread pins original before slow OCR finishes',
      (tester) async {
    final f = await fixture(tester, 'red-only-pin');
    f.captureFixture = true;
    f.rowUnread = false;
    f.returnCachedImage = true;
    f.ocrGate = Completer<void>();
    f.red.add('jd_fixture');
    await f.mount(tester);
    await f.drive(tester,
        until: () => f.newInspects > 0 && f.cacheCaptures > 0);
    expect(f.newInspects, greaterThan(0));
    expect(f.cacheCaptures, greaterThan(0));
    expect(f.ocrGate!.isCompleted, isFalse);
    expect(f.sent, isEmpty);
    await tester.runAsync(() async {
      final db = await f.db.database;
      final cycle = await f.db.platformResponseCycle('jd_fixture');
      expect(cycle?['state'], 'waiting');
      expect(cycle?['identity_verified'], 1);
      expect(f.cacheClocks, everyElement(cycle!['started_at_ms']));
      expect(await db.query('pending_customers'), isEmpty,
          reason: 'Pin-only recovery does not create an AI business task');
      final rows = await db.query('capture_evidence', where: "id LIKE 'new-%'");
      final pinned = rows
          .map((r) => jsonDecode(r['payload']! as String) as Map)
          .where((r) => r['pinnedMedia'] is Map)
          .toList();
      expect(pinned, isNotEmpty);
      expect(pinned.first['pinnedMedia']['cacheKey'], 'red-only-original');
      expect(
          await File(pinned.first['pinnedMedia']['evidenceFile'] as String)
              .exists(),
          isTrue);
      expect((await f.db.platformResponseCycle('jd_fixture'))?['started_at_ms'],
          cycle['started_at_ms']);
    });
    f.ocrGate!.complete();
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'two red-only customers with competing cache clocks do not claim one original',
      (tester) async {
    final f = await fixture(tester, 'red-only-ambiguity');
    f.rowUnread = false;
    f.returnCachedImage = true;
    f.ocrGate = Completer<void>();
    f.red.addAll(['jd_fixture', 'jd_other']);
    await f.mount(tester);
    await f.drive(tester, steps: 12);
    await tester.runAsync(() async {
      expect((await f.db.platformResponseCycle('jd_fixture'))?['state'],
          'waiting');
      expect(
          (await f.db.platformResponseCycle('jd_other'))?['state'], 'waiting');
    });
    f.captureFixture = true;
    await f.drive(tester,
        until: () => f.newInspects > 0 && f.cacheCaptures > 0);
    expect(f.newInspects, greaterThan(0));
    expect(f.cacheCaptures, greaterThan(0));
    await tester.runAsync(() async {
      final db = await f.db.database;
      final rows = await db.query('capture_evidence', where: "id LIKE 'new-%'");
      expect(rows, isNotEmpty);
      expect(
          rows.map((r) =>
              (jsonDecode(r['payload']! as String) as Map)['pinnedMedia']),
          everyElement(isNull));
      expect(await db.query('pending_customers'), isEmpty);
    });
    expect(f.sent, isEmpty);
    f.ocrGate!.complete();
    await f.close(tester);
  }, skip: !Platform.isMacOS);
}
