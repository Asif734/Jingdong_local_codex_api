import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_codex_session.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CodexReplyService service;
  late DateTime clock;
  late File requests;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v46_submit_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    clock = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
    await db.beginAutomationSession(startedAt: clock);
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    await File('${knowledge.path}/printer_kb.md').writeAsString(
        'Use the supplied USB cable. The printer setup menu contains connection settings.');
    requests = File('${root.path}/requests.jsonl');
    final cli = await File('${root.path}/controlled-cli.py')
        .writeAsString('''#!/usr/bin/python3
import sys,json,re,pathlib,time
args=sys.argv[1:]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
with pathlib.Path(${jsonEncode(requests.path)}).open('a') as log: log.write(json.dumps({'args':args,'request':request})+'\\n')
hold=pathlib.Path(${jsonEncode(root.path)})/('hold-'+request['user_id'])
while hold.exists(): time.sleep(.005)
ids=[m['id'] for m in request['target_customer_batch']]
reply={'reply':'Use the supplied USB cable and the printer setup menu. Covered: '+', '.join(ids),'reply_purpose':'substantive','decision':'draft','confidence':0.99,'risk_level':'low','auto_send_allowed':False,'human_review_required':False,'risk_triggers':[],'used_record_ids':[],'required_slots':[],'actions':[],'attachments':[],'image_descriptions':[{'path':p,'description':'The complete supplied image shows the printer setup interface.'} for p in request['attached_image_paths']]}
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(reply))
print(json.dumps({'type':'thread.started','thread_id':'controlled-thread-'+request['user_id']}))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    service = CodexReplyService(
        executable: cli.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'),
        sessionStore:
            CustomerCodexSessionStore(Directory('${root.path}/sessions')),
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
  });
  tearDown(() async {
    for (final name in ['buyer', 'other']) {
      final hold = File('${root.path}/hold-$name');
      if (await hold.exists()) await hold.delete();
    }
    await db.close();
    await root.delete(recursive: true);
  });

  Future<void> text(String id,
      {String customer = 'buyer', String? body}) async {
    clock = clock.add(const Duration(seconds: 1));
    await db.saveCapture(CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: clock,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body ??
                  'Which USB cable and setup menu should I use for $id?',
              sender: customer,
              sentAt: clock,
              observationTurnKey: 'real-bubble:$id',
              captureEvidenceId: 'frozen:$id',
              axPath: 'exact customer $customer / received input $id')
        ]));
  }

  Future<String> pendingImage(String id) async {
    clock = clock.add(const Duration(seconds: 1));
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frozen:$id',
        occurrenceKey: 'actual-image:$id',
        observedAt: clock,
        senderAt: clock,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: id, receivedAt: clock, senderAt: clock);
    await inventory.classify(receipt, 'image');
    return receipt;
  }

  Future<GenerationSnapshot> begin(String id,
      {String customer = 'buyer'}) async {
    final row = (await db.conversation(customer))!;
    final token = await db.beginGeneration(
        customer: customer,
        pendingId: row.id,
        batchEndMessageId: id,
        expectedSessionId: db.currentAutomationSessionId);
    expect(token, isNotNull);
    return GenerationSnapshot(token!, id);
  }

  Future<GenerationSnapshot?> refresh(GenerationSnapshot claim,
          {String customer = 'buyer',
          String? session,
          bool Function()? canCommit}) async =>
      db.refreezeGenerationBeforeSubmit(
          customer: customer,
          pendingId: (await db.conversation(customer))!.id,
          generationToken: claim.token,
          batchEndMessageId: claim.batchEndMessageId,
          expectedSessionId: session ?? db.currentAutomationSessionId!,
          canCommit: canCommit);

  Future<({AiDraft draft, GenerationSnapshot claim, int checks})> generate(
      GenerationSnapshot claim,
      {String customer = 'buyer',
      Future<void> Function()? atGate}) async {
    var current = claim;
    var checks = 0;
    final draft = await service.generate(
        conversation: (await db.conversation(customer))!,
        database: db,
        batchEndMessageId: claim.batchEndMessageId,
        beforeSubmit: () async {
          checks++;
          await atGate?.call();
          final next = await refresh(current, customer: customer);
          expect(next, isNotNull);
          current = next!;
          return next.expanded ? next.batchEndMessageId : null;
        });
    final prepared = await db.prepareAutomaticDraft(customer, draft);
    return (draft: prepared, claim: current, checks: checks);
  }

  Future<void> saveAndConfirm(AiDraft draft, GenerationSnapshot claim,
      {String customer = 'buyer'}) async {
    final row = (await db.conversation(customer))!;
    expect(
        await db.saveDraft(row.id, draft,
            expectedUserId: customer,
            expectedMessageId: claim.batchEndMessageId,
            generationToken: claim.token),
        1);
    await db.abandonGeneration(customer, claim.token);
    final attempt =
        await db.beginDeliveryAttempt(userId: customer, reply: draft.reply);
    expect(attempt, isNotEmpty);
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': customer,
      'state': 'submitted',
      'timeMs': DateTime.now().millisecondsSinceEpoch,
      'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
    }));
    await db.recoverDeliveryReceipts();
  }

  Future<List<Map>> requestLog() async => await requests.exists()
      ? (await requests.readAsLines()).map((l) => jsonDecode(l) as Map).toList()
      : [];
  Future<void> waitRequests(int count) async {
    for (var i = 0; i < 300 && (await requestLog()).length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await requestLog(), hasLength(count));
  }

  test(
      '35:17 freeze plus 35:21 input before actual CLI submit has one complete request and exact coverage',
      () async {
    await text('where-app', body: 'Where can I find the printer setup menu?');
    final initial = await begin('where-app');
    final result = await generate(initial, atGate: () async {
      await text('how-connect',
          body: 'How do I connect it with the USB cable?');
      await pendingImage('still-loading');
    });
    expect(result.checks, 1);
    expect(result.claim.expanded, isTrue);
    expect(result.claim.token, isNot(initial.token));
    expect(result.claim.batchEndMessageId, 'how-connect');
    final log = await requestLog();
    expect(log, hasLength(1),
        reason: 'No old CLI process was submitted or restarted');
    expect(
        (log.single['request']['target_customer_batch'] as List)
            .map((m) => m['id']),
        ['where-app', 'how-connect']);
    expect(
        await db.generationInputVersionsCurrent('buyer',
            generationToken: result.claim.token),
        isTrue);
    expect(
        await db.generationInputVersionsCurrent('buyer',
            generationToken: initial.token),
        isFalse);
    expect(jsonDecode(result.draft.rawJson)['formal_response_message_ids'],
        ['where-app', 'how-connect']);
    expect(
        await db.saveDraft((await db.conversation('buyer'))!.id, result.draft,
            expectedMessageId: initial.batchEndMessageId,
            generationToken: initial.token),
        0);
    await saveAndConfirm(result.draft, result.claim);
    expect(await db.isMessageFormallyAnswered('buyer', 'where-app'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'how-connect'), isTrue);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'still-loading'), isFalse);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test('no new ready input preserves the token and all old frozen inputs',
      () async {
    await text('question');
    final claim = await begin('question');
    await pendingImage('unready-image');
    final same = (await refresh(claim))!;
    expect(same.expanded, isFalse);
    expect(same.token, claim.token);
    expect(
        (await db.generationMessages('buyer'))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        ['question']);
  });

  test('pending receipt cannot poison an otherwise ready substantive expansion',
      () async {
    await text('independent');
    final initial = await begin('independent');
    await pendingImage('unready-image');
    await text('receipt', body: 'Did you get my picture?');
    final same = (await refresh(initial))!;
    expect(same.expanded, isFalse);
    expect(same.token, initial.token);
    expect(
        (await db.generationMessages('buyer'))
            .where((m) => m['direction'] == 'incoming')
            .map((m) => m['id']),
        ['independent']);
  });

  test(
      'input after CLI submission remains next work; another customer proceeds while first CLI is held',
      () async {
    await text('first');
    final a = await begin('first');
    final hold = await File('${root.path}/hold-buyer').writeAsString('hold');
    final inFlight = generate(a);
    await waitRequests(1);
    await text('after-submit');
    await text('other-question', customer: 'other');
    final b = await generate(await begin('other-question', customer: 'other'),
        customer: 'other');
    await saveAndConfirm(b.draft, b.claim, customer: 'other');
    expect(
        await db.isMessageFormallyAnswered('other', 'other-question'), isTrue);
    expect(
        await db.isMessageFormallyAnswered('buyer', 'after-submit'), isFalse);
    await hold.delete();
    final first = await inFlight;
    expect(first.checks, 1);
    expect(first.claim.token, a.token);
    expect(jsonDecode(first.draft.rawJson)['formal_response_message_ids'],
        ['first']);
    await saveAndConfirm(first.draft, first.claim);
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
    final next = await generate(await begin('after-submit'));
    expect(
        (await requestLog())
            .last['request']['target_customer_batch']
            .map((m) => m['id']),
        ['after-submit']);
    await saveAndConfirm(next.draft, next.claim);
    expect(await db.unansweredWorkCounts(), isEmpty);
    expect(await requestLog(), hasLength(3));
    expect((await requestLog()).last['args'], contains('resume'),
        reason: 'Thread resume goes through the same per-turn submission gate');
  });

  test(
      'CAS rejects a replaced lease and a stopped session without taking new work',
      () async {
    await text('first');
    final first = await begin('first');
    await db.abandonGeneration('buyer', first.token);
    final replacement = await begin('first');
    await text('second');
    expect(await refresh(first), isNull);
    expect(
        await db.generationInputVersionsCurrent('buyer',
            generationToken: replacement.token),
        isTrue);
    final oldSession = db.currentAutomationSessionId!;
    await db.beginAutomationSession(
        startedAt: clock.add(const Duration(seconds: 1)));
    // A stale request never creates a fresh generation for the next session.
    expect(
        await db.refreezeGenerationBeforeSubmit(
            customer: 'buyer',
            pendingId: 1,
            generationToken: replacement.token,
            batchEndMessageId: 'first',
            expectedSessionId: oldSession),
        isNull);
  });

  test(
      'canCommit false prevents a late pre-submit callback from leaving a replacement lease',
      () async {
    await text('first');
    final claim = await begin('first');
    await text('second');
    expect(await refresh(claim, canCommit: () => false), isNull);
    expect(
        await db.generationInputVersionsCurrent('buyer',
            generationToken: claim.token),
        isTrue);
    await db.abandonGeneration('buyer', claim.token);
    expect(
        (await (await db.database).query('pending_customers'))
            .single['generation_token'],
        isNull);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
  });

  test('cancellation after binding rolls back the entire replacement claim',
      () async {
    await text('first');
    final claim = await begin('first');
    await text('second');
    final sql = await db.database;
    final before = await sql.query('automation_reply_inputs',
        orderBy: 'owner_id,message_id');
    var checks = 0;
    final refreshed = await refresh(claim, canCommit: () => ++checks < 3);
    expect(checks, 3,
        reason: 'The final cancellation occurs after new inputs were bound');
    expect(refreshed, isNull);
    expect(
        await sql.query('automation_reply_inputs',
            orderBy: 'owner_id,message_id'),
        before,
        reason: 'An aborted CAS must not commit an orphan replacement scope');
    expect((await sql.query('pending_customers')).single['generation_token'],
        claim.token);
    expect(
        await db.generationInputVersionsCurrent('buyer',
            generationToken: claim.token),
        isTrue);
    expect(await db.unansweredWorkCounts(), {'buyer': 2});
  });
}
