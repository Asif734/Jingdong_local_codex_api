import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

AiDraft _answer(String customer) => AiDraft.fromJson({
      'reply':
          'Actual answer for $customer: check the paper and run a self-test.',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-reply',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
    }, mediaBaseUrl: Uri());

AiDraft _handoff() => AiDraft.fromJson({
      'reply': 'Internal handoff decision.',
      'decision': 'human_review_required',
      'human_review_required': true,
      'risk_triggers': ['explicit_human_request'],
      'reason': 'Customer requested a colleague.',
      'confidence': 1,
      'risk_level': 'medium',
      'model': 'controlled-handoff',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
    }, mediaBaseUrl: Uri());

class _Database extends CaptureDatabase {
  _Database(Directory root) : super(storageRoot: root);
  Future<void> Function()? beforeChoice;
  int choices = 0;

  @override
  Future<String> chooseAutomaticTransferAccount(
      Iterable<String> activeAccounts) async {
    choices++;
    await beforeChoice?.call();
    return super.chooseAutomaticTransferAccount(activeAccounts);
  }
}

class _Flow {
  _Flow(this.root, this.db, this.channel);
  final Directory root;
  final _Database db;
  final MethodChannel channel;
  final answerA = Completer<AiDraft>();
  final answerB = Completer<AiDraft>();
  final sendB = Completer<void>();
  final replies = <(String, String)>[];
  final targets = <String>[];
  final generated = <String, int>{};
  Completer<void>? inspection;
  bool running = false;
  bool gateB = false;
  bool interruptSecondRead = false;
  bool blockFirstRead = false;
  bool interruptFirstTransfer = false;
  bool proveNotClicked = true;
  bool bRed = false;
  String finalState = 'confirmed';
  int staffReads = 0, pulses = 0, ack = 0;
  final attempts = <String>[];
  bool bSendEntered = false;

  Future<void> incoming(String customer, String id) async {
    final now = DateTime.now().toUtc();
    await db.saveCapture(
        CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: now,
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: 'Customer question $id',
                  sentAt: now,
                  axPath: 'controlled AX conversation')
            ]),
        activeIncomingIds: {id});
  }

  Future<void> ready(String customer, String id) async {
    await incoming(customer, id);
    await db.saveDraft((await db.conversation(customer))!.id, _answer(customer),
        expectedMessageId: id);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1250, 950);
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
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
            for (final customer in ['A', 'B', 'C'])
              {
                'customer': customer,
                'identitySource': 'ax',
                'unread': false,
                'redClockPresent': customer == 'B' && bRed,
                'unreadAgeSeconds': customer == 'B' && bRed ? 21 : null,
                'evidenceAvailable': true,
              }
          ];
        case 'captureViewportEvidence':
          return {'error': 'snapshot_chat_missing'};
        case 'openConversation':
          return {'opened': true, 'customer': args['expectedCustomer']};
        case 'cancelTransferSelection':
          return {'closed': true};
        case 'requestTransferInspectionYield':
          pulses++;
          final active = inspection;
          if (active != null && !active.isCompleted) {
            active.completeError(
                PlatformException(code: 'handoff_yielded_for_reply'));
          }
          return {};
        case 'listActiveTransferAccounts':
          staffReads++;
          if ((blockFirstRead && staffReads == 1) ||
              (interruptSecondRead && staffReads == 2)) {
            final active = Completer<void>();
            inspection = active;
            try {
              await active.future;
            } finally {
              if (identical(inspection, active)) inspection = null;
            }
          }
          return {
            'sourceAccount': staffReads > 1 && finalState == 'source_changed'
                ? 'different_source'
                : 'source_agent',
            'accounts': staffReads > 1 && finalState == 'offline'
                ? ['agent_other']
                : staffReads > 1
                    ? ['agent_other', 'agent_first']
                    : ['agent_first', 'agent_other'],
          };
        case 'sendDraftOnce':
          final customer = args['expectedCustomer'] as String;
          final reply = args['reply'] as String;
          if (customer == 'B' && reply == _answer('B').reply) {
            bSendEntered = true;
            if (gateB) await sendB.future;
          }
          if (reply.contains('transferring this conversation') ||
              reply.contains('正在为您转接') ||
              reply.contains('现在正为您转接')) {
            ack++;
          }
          replies.add((customer, reply));
          if (customer == 'B') bRed = false;
          return {
            'sent': true,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch,
          };
        case 'transferConversation':
          attempts.add(args['attemptId'] as String);
          if (interruptFirstTransfer && attempts.length == 1) {
            final active = Completer<void>();
            inspection = active;
            try {
              await active.future;
            } on PlatformException {
              final receipt = File(args['receiptPath'] as String);
              await receipt.writeAsString(
                  jsonEncode({
                    'attemptId': args['attemptId'],
                    'customer': args['expectedCustomer'],
                    'targetAccount': args['targetAccount'],
                    'state': proveNotClicked ? 'not_clicked' : 'unknown',
                    'transferClicked': !proveNotClicked,
                    'timeMs': DateTime.now().millisecondsSinceEpoch,
                  }),
                  flush: true);
              return {
                'error': 'handoff_yielded_for_reply',
                'attemptId': args['attemptId'],
                'transferClicked': false,
                'receiptState': 'not_clicked',
                'receiptPersisted': true,
              };
            } finally {
              if (identical(inspection, active)) inspection = null;
            }
          }
          targets.add(args['targetAccount'] as String);
          return {
            'transferred': true,
            'customer': args['expectedCustomer'],
            'targetAccount': args['targetAccount'],
            'attemptId': args['attemptId'],
            'receiptState': 'confirmed',
            'transferClicked': true,
          };
      }
      return {};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            generateDraftOverride: (c, d, b, x) {
              final count = (generated[c.userId] ?? 0) + 1;
              generated[c.userId] = count;
              if (c.userId == 'A') {
                return count == 1 ? Future.value(_handoff()) : answerA.future;
              }
              return c.userId == 'B'
                  ? answerB.future
                  : Future.value(_answer(c.userId));
            })));
    await grantRunPermissions(tester);
    await start(tester);
  }

  Future<void> start(WidgetTester tester) async {
    final before = db.currentAutomationSessionId;
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    running = true;
    await wait(tester, () => db.currentAutomationSessionId != before);
  }

  Future<void> stop(WidgetTester tester) async {
    if (!running) return;
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    running = false;
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> wait(WidgetTester tester, bool Function() done,
      {int steps = 400}) async {
    for (var i = 0; i < steps && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue,
        reason:
            'reads=$staffReads targets=$targets replies=$replies generated=$generated pulses=$pulses');
  }

  Future<Map<String, Object?>?> log() async =>
      (await (await db.database).query('chat_transfer_logs')).firstOrNull;

  Future<Map<String, Object?>> deferred(WidgetTester tester) async {
    Map<String, Object?>? current;
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() async => current = await log());
      if (current?['status'] == 'deferred') return current!;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    fail('A safe response yield was not deferred: $current');
  }

  Future<void> close(WidgetTester tester) async {
    if (!sendB.isCompleted) sendB.complete();
    if (!answerA.isCompleted) answerA.complete(_answer('A'));
    if (!answerB.isCompleted) answerB.complete(_answer('B'));
    final active = inspection;
    if (active != null && !active.isCompleted) active.complete();
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
      final root = await Directory.systemTemp.createTemp('v32_$name');
      flow = _Flow(root, _Database(root), MethodChannel('v32.$name'));
      await flow.db.database;
    });
    return flow;
  }

  for (final result in ['confirmed', 'offline', 'source_changed']) {
    testWidgets('yielded selection continues with fresh validation: $result',
        (tester) async {
      final f = await fixture(tester, result);
      f.gateB = true;
      f.finalState = result;
      f.interruptSecondRead = result == 'confirmed';
      f.db.beforeChoice = () => f.ready('B', 'b-ready');
      await f.mount(tester);
      await tester.runAsync(() => f.incoming('A', 'ask-human'));
      await f.wait(tester, () => f.bSendEntered);
      final deferred = await f.deferred(tester);
      expect(deferred['target_account'], 'agent_first');
      expect(deferred['preclick_retry_count'], 0);
      f.sendB.complete();
      await f.wait(tester, () => f.staffReads >= 2);
      f.answerA.complete(_answer('A'));
      await f.wait(tester, () => f.replies.contains(('A', _answer('A').reply)));
      if (result == 'confirmed') {
        await f.wait(tester, () => f.targets.isNotEmpty);
        expect(f.targets, ['agent_first']);
        expect(f.staffReads, 3,
            reason: 'Two resumptions only perform the final fresh validation');
      } else {
        expect(f.targets, isEmpty,
            reason:
                'Offline targets and a changed source cannot use checkpoint permission');
        expect(f.staffReads, 2);
      }
      expect(f.db.choices, 1);
      expect(
          f.replies.where((r) => r == ('B', _answer('B').reply)), hasLength(1));
      expect(f.replies.where((r) => isHoldingReply(r.$2)), isEmpty);
      expect(f.ack, 1);
      await f.close(tester);
    }, skip: !Platform.isMacOS);
  }

  testWidgets('inspection can exceed 2.5s but yields for a red deadline',
      (tester) async {
    final f = await fixture(tester, 'sla');
    f.blockFirstRead = true;
    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'ask-human'));
    await f.wait(tester, () => f.inspection != null);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3100)));
    await tester.pump();
    expect(f.staffReads, 1);
    expect(f.targets, isEmpty);
    expect(f.pulses, 0);
    await tester.runAsync(() => f.incoming('B', 'b-slow'));
    f.bRed = true;
    await f.wait(tester,
        () => f.replies.any((r) => r.$1 == 'B' && isHoldingReply(r.$2)));
    expect(f.pulses, greaterThan(0));
    await f.wait(tester, () => f.targets.isNotEmpty);
    f.answerB.complete(_answer('B'));
    await f.wait(tester, () => f.replies.contains(('B', _answer('B').reply)));
    expect(f.replies.where((r) => r.$1 == 'B' && isHoldingReply(r.$2)),
        hasLength(1));
    expect(f.targets, ['agent_first']);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets('Stop Start does not resume a previous deferred selection',
      (tester) async {
    final f = await fixture(tester, 'restart');
    f.gateB = true;
    f.db.beforeChoice = () => f.ready('B', 'b-ready');
    await f.mount(tester);
    await tester.runAsync(() => f.incoming('A', 'ask-human'));
    await f.wait(tester, () => f.bSendEntered);
    await f.deferred(tester);
    f.sendB.complete();
    await f.wait(tester, () => f.replies.contains(('B', _answer('B').reply)));
    await f.stop(tester);
    await f.start(tester);
    f.answerA.complete(_answer('A'));
    await tester.runAsync(() => f.incoming('C', 'new-session-question'));
    await f.wait(tester, () => f.replies.contains(('C', _answer('C').reply)));
    expect(f.targets, isEmpty);
    expect(f.staffReads, 1);
    expect(f.replies.where((r) => r.$1 == 'A'), isEmpty);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  for (final proven in [true, false]) {
    testWidgets(
        'native pre-click yield requires durable no-click proof: $proven',
        (tester) async {
      final f = await fixture(tester, 'native-yield-$proven');
      f.interruptFirstTransfer = true;
      f.proveNotClicked = proven;
      f.gateB = true;
      await f.mount(tester);
      await tester.runAsync(() => f.incoming('A', 'ask-human'));
      await f.wait(
          tester, () => f.attempts.length == 1 && f.inspection != null);
      await tester.runAsync(() => f.ready('B', 'formal-before-transfer'));
      await f.wait(tester, () => f.bSendEntered);
      if (proven) {
        final deferred = await f.deferred(tester);
        expect(deferred['attempt_id'], isNull);
        expect(deferred['preclick_retry_count'], 0);
        expect(deferred['acknowledged'], 1);
      }
      f.sendB.complete();
      await f.wait(tester, () => f.replies.contains(('B', _answer('B').reply)));
      if (proven) {
        await f.wait(tester, () => f.targets.isNotEmpty);
        expect(f.targets, ['agent_first']);
        expect(f.attempts, hasLength(2));
        expect(f.attempts.toSet(), hasLength(2));
        expect(f.staffReads, 3);
        expect(f.db.choices, 1);
        await tester.runAsync(() async {
          final old =
              File('${f.root.path}/transfer_receipts/${f.attempts.first}.json');
          expect((jsonDecode(await old.readAsString()) as Map)['state'],
              'not_clicked');
        });
      } else {
        f.answerA.complete(_answer('A'));
        await f.wait(
            tester, () => f.replies.contains(('A', _answer('A').reply)));
        expect(f.targets, isEmpty);
        expect(f.attempts, hasLength(1));
        await tester.runAsync(() async {
          final log = (await f.log())!;
          expect(log['status'], 'unconfirmed');
          expect(log['attempt_id'], f.attempts.single);
          expect(await f.db.handoffReplyContinuation(log['ticket_id'] as int),
              isNull);
        });
      }
      expect(f.ack, 1);
      await f.close(tester);
    }, skip: !Platform.isMacOS);
  }
}
