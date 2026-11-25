import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

const _customer = 'session-buyer';
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
  test('same workflow retains an attached question without an age deadline',
      () {
    final now = DateTime.utc(2026, 11, 5, 10);
    final question = <String, dynamic>{
      'id': 'visual-question',
      'direction': 'incoming',
      'body': 'What do you see in this video?',
      'sent_at': now.subtract(const Duration(hours: 2)).toIso8601String(),
    };
    final receipt = <String, dynamic>{
      'id': 'media-pending:r',
      'direction': 'incoming',
      'body': '[Customer sent media; acquisition pending.]',
      'media_receipt_id': 'r',
      'media': <Object?>[],
    };
    expect(
        resolveAttachedMediaQuestion(
            history: [question, receipt],
            currentTurn: [receipt],
            now: now,
            processBased: true),
        question['body']);
  });
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
    await cli.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > "${input.path}"
cat "${response.path}" > "\$output"
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
      {DateTime? at,
      List<CapturedMedia> media = const [],
      String? evidenceId}) async {
    final timestamp = at ?? DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
      stableKey: _customer,
      customerName: _customer,
      customerExternalId: _customer,
      automationSessionId: db.currentAutomationSessionId,
      capturedAt: DateTime.now().toUtc(),
      messages: [
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: body,
            sentAt: timestamp,
            axPath: 'controlled AX fixture',
            captureEvidenceId: evidenceId,
            media: media)
      ],
    ));
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

  test(
      'late question before an outgoing answer remains in the exact formal batch',
      () async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final first = await incoming(
        'first', 'Please explain how to connect my printer by USB.');
    await (await db.history).appendSlaFallbackSent(
        userId: _customer,
        messageId: first,
        reply: englishHoldingReplies.first);
    final late = await incoming(
        'late', 'How long is the warranty for this printer?',
        at: DateTime.now().subtract(const Duration(minutes: 4)));
    final draft = await generate(late);
    final prompt = await request();
    expect(draft.reply, isNotEmpty);
    expect((prompt['target_customer_batch'] as List).map((m) => m['id']),
        containsAll([first, late]));
    expect(await db.isMessageFormallyAnswered(_customer, late), isFalse);
  });

  test('a generation lease excludes a later-arriving input from its prompt',
      () async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final frozen =
        await incoming('frozen', 'Please explain USB setup for this printer.');
    final c = (await db.conversation(_customer))!;
    expect(
        await db.beginGeneration(
            customer: _customer, pendingId: c.id, batchEndMessageId: frozen),
        isNotNull);
    final later = await incoming('later', 'What is the warranty duration?');
    await generate(frozen);
    final prompt = await request();
    expect((prompt['target_customer_batch'] as List).map((m) => m['id']),
        [frozen]);
    expect(jsonEncode(prompt['conversation']), isNot(contains(later)));
    expect(jsonEncode(prompt['past_context_only']), isNot(contains(later)));
  });

  test(
      'a frozen earlier input with customer ellipsis is never silently excluded',
      () async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final earlier = await incoming(
        'earlier', 'The USB cable is connected... but the printer is offline.');
    final end =
        await incoming('end', 'Which connection setting should I check?');
    await generate(end);
    final prompt = await request();
    expect((prompt['target_customer_batch'] as List).map((m) => m['id']),
        [earlier, end]);
    expect(jsonEncode(prompt['target_customer_batch']),
        contains('printer is offline'));
  });

  test('early independent text does not depend on unowned same-frame visuals',
      () async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final now = DateTime.now().toUtc();
    final sql = await db.database;
    for (final evidence in [
      'own-frame',
      for (var i = 0; i < 8; i++) 'future-unrelated-frame-$i'
    ]) {
      await sql.insert('media_capture_audit', {
        'observation_id': evidence,
        'evidence_id': evidence,
        'customer': _customer,
        'state': 'discovered',
        'updated_at_ms': now.millisecondsSinceEpoch,
        'details': jsonEncode({
          'capturedAt': now.toIso8601String(),
          'automationSessionId': db.currentAutomationSessionId
        }),
      });
    }
    final end = await incoming(
        'text-first', 'Which USB connection setting should I check?',
        evidenceId: 'own-frame');
    final draft = await generate(end);
    final prompt = await request();
    expect(prompt['unresolved_customer_media'], isEmpty);
    expect(jsonDecode(draft.rawJson)['reply_media_dependency_keys'], isEmpty);
    expect((prompt['target_customer_batch'] as List).single['id'], end);
    expect(
        (await sql.query('media_capture_audit',
                where: 'observation_id=?', whereArgs: ['own-frame']))
            .single['state'],
        'discovered',
        reason: 'Unknown capture work is preserved separately');
    expect(prompt['attached_image_paths'], isEmpty);
    expect(prompt['image_analysis_required'], isFalse);
  });

  test(
      'pending media is a real input, never a greeting or invented analyzed file',
      () async {
    await db.beginAutomationSession(
        startedAt: DateTime.now().subtract(const Duration(seconds: 1)));
    final at = DateTime.now().toUtc();
    final receipt = await CustomerMediaInventory(db).observe(
        customer: _customer,
        evidenceId: 'live-pending-media',
        occurrenceKey: 'live-pending-media',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: [.3, .3, .2, .2],
        current: true);
    await admitFixtureMedia(db,
        customer: _customer,
        receiptId: receipt,
        messageId: 'media-pending:receipt',
        receivedAt: at,
        senderAt: at);
    for (final own in [true, false]) {
      final evidence = own ? 'live-pending-media' : 'unrelated-frame';
      await (await db.database).insert('media_capture_audit', {
        'observation_id': evidence,
        'evidence_id': evidence,
        'customer': _customer,
        'state': 'discovered',
        'updated_at_ms': at.millisecondsSinceEpoch,
        'details': jsonEncode({
          'capturedAt': at.toIso8601String(),
          'automationSessionId': db.currentAutomationSessionId,
          if (own) 'parentMessageId': 'media-pending:receipt',
          if (own) 'mediaReceiptId': receipt,
        }),
      });
    }
    final draft = await generate('media-pending:receipt');
    final prompt = await request();
    expect(draft.model, isNot('local-intent-router-v1'));
    expect(prompt['target_customer_batch'], hasLength(1));
    expect(prompt['target_customer_batch'][0]['id'], 'media-pending:receipt');
    expect(prompt['attached_image_paths'], isEmpty);
    expect(prompt['attached_video_frame_paths'], isEmpty);
    expect(prompt['image_analysis_required'], isFalse);
    expect(prompt['unresolved_customer_media'], hasLength(1));
    expect(prompt['unresolved_customer_media'][0]['evidenceId'],
        'live-pending-media');
    expect(jsonDecode(draft.rawJson)['reply_media_dependency_keys'],
        {'media-pending:receipt': ''});
    expect(
        jsonEncode(prompt['requirements']), contains('not proof of its type'));
    expect(
        await db.isMessageFormallyAnswered(_customer, 'media-pending:receipt'),
        isFalse);
  });
}
