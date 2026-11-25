import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

const _customer = 'session-buyer';
const _currentQuestion =
    'My printer will not power on and I want to return it. What order information do you need?';
const _businessAnswer =
    'Please provide your order number and confirm whether the power indicator turns on. An authorized colleague must verify return eligibility before a return can be approved.';

Map<String, Object?> _response(String reply, {bool review = false}) => {
      'reply': reply,
      'decision': review ? 'human_review_required' : 'draft',
      'confidence': 0.9,
      'used_record_ids': <String>[],
      'required_slots': ['order number'],
      'actions': <Object?>[],
      'risk_level': review ? 'medium' : 'low',
      'risk_triggers': <String>[if (review) 'order_service_handoff'],
      'auto_send_allowed': false,
      'attachments': <Object?>[],
      'image_descriptions': <Object?>[],
      'human_review_required': review,
      'reason':
          review ? 'Return eligibility needs authorized verification.' : null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late File cli;
  late File input;
  late File response;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_reply_session_');
    db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/test_support_kb.md').writeAsString(
        'Controlled test knowledge. Check the power connection and ask for the '
        'order number. Return eligibility requires authorized verification.');
    cli = File('${root.path}/fake-cli.sh');
    input = File('${root.path}/captured-stdin.txt');
    response = File('${root.path}/controlled-reply.json');
    await response.writeAsString(jsonEncode(_response(_businessAnswer)));
    // This executable only records stdin and copies the controlled fixture.
    // It cannot invoke Codex or any other model process.
    await cli.writeAsString('''#!/usr/bin/python3
import sys,json,pathlib
args=sys.argv[1:]
output=args[args.index('--output-last-message')+1]
pathlib.Path(${jsonEncode(input.path)}).write_text(sys.stdin.read())
reply=json.loads(pathlib.Path(${jsonEncode(response.path)}).read_text())
paths=[args[i+1] for i,arg in enumerate(args[:-1]) if arg=='--image']
reply['image_descriptions']=[{'path':path,'description':'Controlled private analysis of the supplied customer image.'} for path in paths]
pathlib.Path(output).write_text(json.dumps(reply))
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  CodexReplyService service() => CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'),
        timeout: const Duration(seconds: 5),
        capacityRetryDelays: const [],
      );

  Future<List<Map<String, dynamic>>> history() async =>
      ((await (await db.history).read(_customer))!['messages'] as List)
          .cast<Map<String, dynamic>>();

  Future<String> incoming(String id, String body,
      {DateTime? at, List<CapturedMedia> media = const []}) async {
    final timestamp = at ?? DateTime.now().toUtc();
    String? receipt;
    final inventory = CustomerMediaInventory(db);
    if (media.isNotEmpty && db.currentAutomationSessionId != null) {
      receipt = await inventory.observe(
          customer: _customer,
          evidenceId: 'fixture-$id',
          occurrenceKey: 'fixture-$id',
          observedAt: timestamp,
          senderAt: timestamp,
          slot: 0,
          region: [.3, .3, .2, .2],
          current: true);
      await inventory.classify(receipt, media.first.type);
      await admitFixtureMedia(db,
          customer: _customer,
          receiptId: receipt,
          messageId: id,
          receivedAt: timestamp,
          senderAt: timestamp);
    }
    final capture = CapturedConversation(
      stableKey: _customer,
      customerName: _customer,
      customerExternalId: _customer,
      automationSessionId: db.currentAutomationSessionId,
      capturedAt: timestamp,
      messages: [
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: body,
            sentAt: timestamp,
            axPath: 'controlled AX fixture',
            mediaReceiptId: receipt,
            media: media)
      ],
    );
    await db.saveCapture(capture);
    if (receipt != null) {
      await inventory.persist(capture, verifiedAnchor: true);
    }
    return (await history()).lastWhere(
            (m) => m['direction'] == 'incoming' && m['body'] == body)['id']
        as String;
  }

  Future<Map<String, dynamic>> request() async {
    final captured = await input.readAsString();
    final data = RegExp(r'<request_json>\s*([\s\S]*?)\s*</request_json>')
        .firstMatch(captured);
    expect(data, isNotNull);
    return jsonDecode(data!.group(1)!) as Map<String, dynamic>;
  }

  Future<AiDraft> generate(String end) async => service().generate(
      conversation: (await db.conversations()).single,
      database: db,
      batchEndMessageId: end);

  Future<int> failedCurrentHandoff() async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final question = await incoming('current-return', _currentQuestion);
    final ticket = await db.createHumanReviewTicket(
        userId: _customer,
        customerRequest: _currentQuestion,
        reason: 'order_service_handoff',
        requestMessageId: question);
    expect(
        await db.releaseHandoffForAi(ticket.id,
            reason: 'handoff_no_eligible_online_agent'),
        isTrue);
    await db.appendAutomatedNoticeSent(
        userId: _customer,
        reply: 'I will check which colleague is available.',
        model: 'jd-transfer-acknowledgement-v1');
    await (await db.history).appendSlaFallbackSent(
        userId: _customer,
        messageId: question,
        reply: englishHoldingReplies.first);
    return ticket.id;
  }

  test(
      'a new-session hi ignores archived refund/handoff and uses local EN reply',
      () async {
    final old = await incoming(
        'old-refund', 'I want a refund for order OLD-123.',
        at: DateTime.now().subtract(const Duration(hours: 1)));
    final ticket = await db.createHumanReviewTicket(
        userId: _customer,
        customerRequest: 'I want a refund for order OLD-123.',
        reason: 'order_service_handoff',
        requestMessageId: old);
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final fresh = await incoming('fresh-hi', 'hi');

    final draft = await generate(fresh);

    expect(draft.model, 'local-intent-router-v1');
    expect(draft.usedRecordIds, contains('intent:greeting'));
    expect(draft.reply, contains('help'));
    expect(draft.reply, isNot(contains('OLD-123')));
    expect(RegExp(r'[\u3400-\u9fff]').hasMatch(draft.reply), isFalse);
    expect(isExplicitHumanTransfer(draft), isFalse);
    expect(await input.exists(), isFalse,
        reason: 'A fresh greeting must not inherit the old business CLI task.');
    expect(
        (await db.processingMessages(_customer)).map((m) => m['id']), [fresh]);
    final archived = (await (await db.database).query('human_review_tickets',
            where: 'id=?', whereArgs: [ticket.id]))
        .single;
    expect(archived['status'], 'session_archived');
    expect((await history()).any((m) => m['id'] == old), isTrue);
  });

  test('failed handoff plus ACK and holding preserve the frozen real question',
      () async {
    final old = await incoming('old-label', 'My old label printer jams paper.',
        at: DateTime.now().subtract(const Duration(hours: 1)));
    final ticket = await failedCurrentHandoff();
    final current = (await db.processingMessages(_customer))
        .singleWhere((m) => m['direction'] == 'incoming')['id'] as String;

    final draft = await generate(current);
    final prompt = await request();

    expect(draft.reply, contains('order number'));
    expect(draft.reply, contains('power indicator'));
    expect(isHoldingReply(draft.reply), isFalse);
    expect(isExplicitHumanTransfer(draft), isFalse);
    expect(prompt['target_batch_end_message_id'], current);
    expect(prompt['latest_message']['body'], _currentQuestion);
    expect(prompt['target_customer_batch'], hasLength(1));
    expect(prompt['target_customer_batch'][0]['id'], current);
    expect(prompt['target_customer_batch'][0]['body'], _currentQuestion);
    expect(prompt['handoff_unavailable'], isNotNull);
    expect(prompt['archived_requests_are_not_pending'], isTrue);
    expect(prompt['automation_session_id'], db.currentAutomationSessionId);
    expect(
        (prompt['conversation'] as List).any((m) => m['id'] == old), isFalse);
    expect((prompt['past_context_only'] as List).any((m) => m['id'] == old),
        isTrue);
    expect(jsonEncode(prompt['requirements']),
        contains('Automatic transfer is unavailable'));
    expect(jsonEncode(prompt['requirements']), contains('past_context_only'));
    expect((await db.humanReviewTickets()).single.id, ticket);
    expect((await db.humanReviewTickets()).single.status, 'open');
    expect(await db.hasPendingUnanswered(_customer), isTrue,
        reason:
            'Holding and transfer ACK do not settle the real customer task.');
  });

  for (final unsupportedClaim in [
    'I have processed your refund and cancelled your order.',
    '已为您退款，订单已取消。',
  ]) {
    test(
        'failed transfer cannot claim account action completed: $unsupportedClaim',
        () async {
      final ticket = await failedCurrentHandoff();
      final current = (await db.processingMessages(_customer))
          .singleWhere((m) => m['direction'] == 'incoming')['id'] as String;
      await response
          .writeAsString(jsonEncode(_response(unsupportedClaim, review: true)));
      final draft = await generate(current);
      expect(draft.reply, isNot(contains(unsupportedClaim)));
      expect(draft.reply, contains('authorized colleague'));
      expect(draft.reply, contains('order details'));
      expect(isExplicitHumanTransfer(draft), isFalse);
      expect((await db.humanReviewTickets()).single.id, ticket);
      expect((await db.humanReviewTickets()).single.status, 'open');
      expect(await db.hasPendingUnanswered(_customer), isTrue);
    });
  }

  test('fallback model transfer promise is rewritten while the case stays open',
      () async {
    final ticket = await failedCurrentHandoff();
    final current = (await db.processingMessages(_customer))
        .singleWhere((m) => m['direction'] == 'incoming')['id'] as String;
    await response.writeAsString(jsonEncode(_response(
        'I will transfer you to a colleague. Please wait a moment.',
        review: true)));

    final draft = await generate(current);

    expect(draft.reply, contains('transfer has not completed'));
    expect(draft.reply, contains('order details'));
    expect(draft.reply, isNot(contains('I will transfer')));
    expect(isHoldingReply(draft.reply), isFalse);
    expect(isExplicitHumanTransfer(draft), isFalse);
    expect(jsonDecode(draft.rawJson)['auto_handoff_suppressed'], isTrue);
    expect((await db.humanReviewTickets()).single.id, ticket);
    expect((await db.humanReviewTickets()).single.status, 'open');
    expect(await db.hasPendingUnanswered(_customer), isTrue);
  });

  test('fixed holding cannot replace business content after transfer failure',
      () async {
    await failedCurrentHandoff();
    final draft = service().enforceHumanReviewPolicy(
        AiDraft.fromJson(_response(englishHoldingReplies.first, review: true),
            mediaBaseUrl: Uri()),
        _currentQuestion,
        language: CustomerLanguage.english,
        handoffUnavailable: true);

    expect(isHoldingReply(draft.reply), isFalse);
    expect(draft.reply, contains('order details'));
    expect(isExplicitHumanTransfer(draft), isFalse);
    expect((await db.humanReviewTickets()).single.status, 'open');
  });

  for (final invalid in [
    'I am transferring you to a customer service colleague.',
    'Please wait while I check.',
  ]) {
    test('unavailable handoff guards model wording: $invalid', () async {
      final draft = service().enforceHumanReviewPolicy(
          AiDraft.fromJson(_response(invalid, review: true),
              mediaBaseUrl: Uri()),
          _currentQuestion,
          language: CustomerLanguage.english,
          handoffUnavailable: true);
      expect(draft.reply, isNot(invalid));
      expect(draft.reply, contains('order details'));
      expect(isExplicitHumanTransfer(draft), isFalse);
    });
  }

  test(
      'a media-only new session retains customer EN language from preserved history',
      () async {
    final english = await incoming(
        'old-english', 'Hello, I would like help in English with my printer.',
        at: DateTime.now().subtract(const Duration(hours: 1)));
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final png = File('${root.path}/received-image.png');
    await png.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='));
    final image =
        await incoming('new-picture', '[Customer sent image]', media: [
      CapturedMedia(
          type: 'image',
          path: png.path,
          mimeType: 'image/png',
          description: '图片里的文字是中文，这不是客户文字语言。')
    ]);
    await response.writeAsString(jsonEncode(
        _response('What problem would you like help with in this picture?')));

    final draft = await generate(image);
    final prompt = await request();

    expect(prompt['reply_language'], 'en');
    expect(prompt['reply_language_source_message_id'], english);
    expect(prompt['image_analysis_required'], isTrue);
    expect(prompt['target_customer_batch'], hasLength(1));
    expect(prompt['target_customer_batch'][0]['id'], image);
    expect((prompt['conversation'] as List).any((m) => m['id'] == english),
        isFalse);
    expect((prompt['past_context_only'] as List).any((m) => m['id'] == english),
        isTrue);
    expect(RegExp(r'[\u3400-\u9fff]').hasMatch(draft.reply), isFalse);
    expect(draft.reply, contains('picture'));
    expect(CustomerLanguageResolver.resolve(await history()).language,
        CustomerLanguage.english);
  });
}
