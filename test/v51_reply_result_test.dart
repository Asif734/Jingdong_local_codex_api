import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/reply_progress.dart';
import 'package:jd_automation/storage/capture_database.dart';

AiDraft _draft(String reply,
        {String purpose = 'substantive',
        List<String> requests = const [],
        bool review = false}) =>
    AiDraft.fromJson({
      'reply': reply,
      'reply_purpose': purpose,
      'decision': review ? 'human_review_required' : 'draft',
      'confidence': .91,
      'risk_level': review ? 'high' : 'low',
      'human_review_required': review,
      'review_acknowledgement_only': purpose == 'review_status',
      'risk_triggers': review ? ['explicit_human_request'] : <String>[],
      'human_transfer_request_message_ids': requests,
      'used_record_ids': ['controlled-kb'],
      'actions': [
        {'type': 'review', 'description': 'Keep original review metadata.'}
      ],
      'image_descriptions': [
        {'path': '/controlled/frame.jpg', 'description': 'Original evidence.'}
      ],
      'model': 'controlled-reply-result',
      'reply_evidence_key_snapshot': {'media-one': 'ready-original'},
      'reply_media_dependency_keys': {'media-one': 'ready-original'},
    }, mediaBaseUrl: Uri());

Map<String, dynamic> _input(String id, String body,
        {List<String> aliases = const [], int second = 1}) =>
    {
      'id': id,
      'observed_ids': aliases,
      'direction': 'incoming',
      'body': body,
      'text_origin': 'customer_text',
      'captured_at': DateTime.utc(2026, 11, 10, 4, 0, second).toIso8601String(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mislabelled actual answers keep their text, evidence and transfer risk',
      () {
    for (final purpose in ['review_status', 'media_status']) {
      final original = _draft('请关闭电源，清理纸道后重新装纸，再测试打印。',
          purpose: purpose, requests: ['request-one'], review: true);
      final corrected = normalizeReplyProgress(original);
      final raw = jsonDecode(corrected.rawJson) as Map;
      final before = jsonDecode(original.rawJson) as Map;
      expect(replyPurpose(corrected), ReplyPurpose.substantive);
      expect(corrected.reply, original.reply);
      expect(corrected.decision, original.decision);
      expect(corrected.riskLevel, original.riskLevel);
      expect(corrected.confidence, original.confidence);
      expect(corrected.usedRecordIds, original.usedRecordIds);
      expect(corrected.imageDescriptions, original.imageDescriptions);
      for (final field in [
        'human_review_required',
        'human_transfer_request_message_ids',
        'risk_triggers',
        'actions',
        'reply_evidence_key_snapshot',
        'reply_media_dependency_keys'
      ]) {
        expect(raw[field], before[field], reason: field);
      }
      expect(raw.containsKey('review_acknowledgement_only'), isFalse);
      expect(isReviewAcknowledgement(raw), isFalse);
    }
  });

  test('useful clarifications and concrete answers are not waiting notices',
      () {
    for (final text in [
      '请提供打印机型号和当前报错，我可以据此确认下一步。',
      'Does the power light turn on when you connect the original adapter?',
      'The video is still loading. Turn the printer off and clear the paper path.',
      '请稍等。TP730支持USB连接，请按说明安装对应驱动。',
      'You can use USB. I will check the remaining details.',
    ]) {
      expect(isOnlyReplyProgressNotice(text), isFalse, reason: text);
      expect(
          replyPurpose(
              normalizeReplyProgress(_draft(text, purpose: 'review_status'))),
          ReplyPurpose.substantive,
          reason: text);
      expect(isOnlyMediaProgressNotice(text), isFalse, reason: text);
    }
  });

  test('a social reply alone never starts the status-only correction path', () {
    for (final text in ['您好', '好的', '收到', '谢谢', 'Hello.', 'Thanks.']) {
      expect(isOnlyReplyProgressNotice(text), isFalse, reason: text);
      final corrected =
          normalizeReplyProgress(_draft(text, purpose: 'review_status'));
      expect(replyPurpose(corrected), ReplyPurpose.substantive, reason: text);
      expect(isReviewAcknowledgement(jsonDecode(corrected.rawJson) as Map),
          isFalse,
          reason: text);
    }
  });

  test('whole-text waiting and assistance promises cannot close actual work',
      () {
    for (final text in [
      '请稍等，我正在核对您的问题。',
      '您好，我会继续协助您。',
      'Please wait while I check.',
      'I can continue helping here.',
      'Let me check that for you, please wait.',
      '这个问题还需要进一步准确核对。我已保留您提供的详细信息，完成下一步核对后会从这里继续。',
      'This issue needs further checking. I have kept the information you provided and will continue here after the next check.',
      'Hello. Please wait a moment while I request assistance from my colleague Xiao Geng.',
      'Hello. Your request for assistance from Xiao Geng is still being handled. Please wait a moment.',
    ]) {
      expect(isOnlyReplyProgressNotice(text), isTrue, reason: text);
      final corrected = normalizeReplyProgress(_draft(text));
      expect(replyPurpose(corrected), ReplyPurpose.reviewStatus, reason: text);
      expect(
          isReviewAcknowledgement(jsonDecode(corrected.rawJson) as Map), isTrue,
          reason: text);
    }
  });

  test('media-only progress remains progress without swallowing real answers',
      () {
    for (final text in [
      'The video content is still loading.',
      'Your media message has arrived, but its content is still loading.',
      '视频内容尚未完整提取。',
    ]) {
      expect(isOnlyReplyProgressNotice(text), isTrue, reason: text);
      final corrected =
          normalizeReplyProgress(_draft(text, purpose: 'media_status'));
      expect(replyPurpose(corrected), ReplyPurpose.mediaStatus, reason: text);
    }
  });

  test('receipt facts are distinct from generic waiting', () {
    for (final text in [
      '已收到您的图片。',
      '我看到了两个视频，但其内容仍在加载。',
      "I've received the image; the original is still loading.",
      'Your video has arrived.',
      'I can see two videos.',
      '没有收到您的视频。',
    ]) {
      expect(isReceiptFactReply(text), isTrue, reason: text);
    }
    for (final text in [
      '已收到您的图片。',
      '收到两张图片。',
      'I have received your image.',
      "I've received your image.",
      'I can see two videos.',
    ]) {
      expect(isOnlyReplyProgressNotice(text), isTrue,
          reason: 'A receipt fact alone does not answer a technical issue.');
      final labelled = normalizeReplyProgress(_draft(text, purpose: 'receipt'));
      expect(replyPurpose(labelled), ReplyPurpose.receipt,
          reason: 'Storage still verifies that the input asks only receipt.');
      expect(replyPurpose(normalizeReplyProgress(_draft(text))),
          ReplyPurpose.reviewStatus,
          reason: 'A fact alone must not complete a non-receipt problem.');
      final answer = '$text 请关闭电源，重新装纸后再试。';
      expect(isOnlyReplyProgressNotice(answer), isFalse);
      expect(
          replyPurpose(
              normalizeReplyProgress(_draft(answer, purpose: 'review_status'))),
          ReplyPurpose.substantive);
    }
    for (final text in [
      'Please wait while I check.',
      '请稍等，我正在核对。',
      '收到后会为您检查视频。',
      'I will receive your video soon.',
    ]) {
      expect(isReceiptFactReply(text), isFalse, reason: text);
    }
    final falselyLabelled =
        normalizeReplyProgress(_draft('请稍等，我正在核对。', purpose: 'receipt'));
    expect(replyPurpose(falselyLabelled), ReplyPurpose.reviewStatus);
    expect(
        isReviewAcknowledgement({
          ...jsonDecode(_draft('Your video has arrived.',
                  purpose: 'review_status', review: true)
              .rawJson) as Map,
          'reply_purpose': 'receipt',
          'automatic_progress_classified': true,
        }),
        isFalse,
        reason: 'Storage-verified receipt scope survives legacy review flags.');
  });

  test('intent IDs resolve only to real frozen inputs and deduplicate aliases',
      () {
    final first = _input('first', '转小华', aliases: ['old-first']);
    final second = _input('second', '不，麻烦帮我转接', second: 2);
    final inputs = [
      first,
      second,
      _input('hello', 'hello', second: 3),
      {..._input('outgoing', '转客服'), 'direction': 'outgoing'},
      {..._input('subtitle', '转客服'), 'text_origin': 'video_subtitle'},
      {..._input('image', '转客服'), 'source': 'image_ocr'},
    ];
    final requests = frozenHumanTransferRequests(
        _draft('回答', requests: [
          'old-first',
          'first',
          'second',
          'old-history',
          'outgoing',
          'subtitle',
          'image'
        ]),
        inputs);
    expect(requests.map((message) => message['id']), ['first', 'second']);
    expect(
        frozenHumanTransferRequests(_draft('回答', requests: ['shared']), [
          _input('one', '转客服', aliases: ['shared']),
          _input('two', '转客服', aliases: ['shared'])
        ]),
        isEmpty,
        reason: 'One ambiguous old observation cannot invent two requests.');
  });

  group('frozen request accounting', () {
    late Directory root;
    late CaptureDatabase database;
    const customer = 'controlled-v51-buyer';
    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_v51_reply_result_');
      database = CaptureDatabase(storageRoot: root);
      await database.beginAutomationSession(
          startedAt: DateTime.utc(2026, 11, 10, 3, 59));
    });
    tearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    test('two real requests before latest hello count once each across retries',
        () async {
      final inputs = [
        _input('first', '请转同事', aliases: ['old-first']),
        _input('second', '不，请帮我转接', second: 2),
        _input('hello', 'hello', second: 3),
      ];
      final draft =
          _draft('我可以先帮您核对。', requests: ['old-first', 'first', 'second']);
      for (var retry = 0; retry < 3; retry++) {
        final result = await recordFrozenHumanTransferRequests(
            draft: draft,
            frozenInputs: inputs,
            database: database,
            customer: customer);
        expect(result.hasRequest, isTrue);
        expect(result.repeatedRequest, isTrue);
        expect(codexHumanTransferRequestIds(result.draft), {'first', 'second'});
        final service = CodexReplyService(
            executable: '/unused-pure-policy',
            workspace: root,
            knowledgeDirectory: root,
            outputSchema: File('${root.path}/unused-schema'));
        final guarded = service.enforceHumanReviewPolicy(
            result.draft, result.requests.map((m) => m['body']).join('\n'),
            language: CustomerLanguage.chinese,
            humanTransferRequested: result.hasRequest,
            repeatedHumanTransferRequest: result.repeatedRequest);
        expect(isExplicitHumanTransfer(guarded), isTrue);
      }
      final sql = await database.database;
      expect(await sql.query('human_transfer_request_events'), hasLength(2));
      expect(
          (await sql.query('human_transfer_requests')).single['request_count'],
          0);
    });

    test('previous observed-alias event does not increment the canonical event',
        () async {
      await database.recordHumanTransferRequest(
          userId: customer,
          messageId: 'old-observation',
          requestedAt: DateTime.utc(2026, 11, 10, 4));
      final result = await recordFrozenHumanTransferRequests(
          draft: _draft('我可以先帮您处理。', requests: ['canonical']),
          frozenInputs: [
            _input('canonical', '请转客服', aliases: ['old-observation'])
          ],
          database: database,
          customer: customer);
      expect(result.repeatedRequest, isFalse);
      final sql = await database.database;
      expect(await sql.query('human_transfer_request_events'), hasLength(1));
      expect(
          (await sql.query('human_transfer_requests')).single['request_count'],
          1);
    });

    test(
        'satisfied self and suppressed old request cannot consume a new target',
        () async {
      Future<Map<String, dynamic>> receive(
          String stableId, String body, int second) async {
        final at = DateTime.utc(2026, 11, 10, 4, 0, second);
        await database.saveCapture(CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            automationSessionId: database.currentAutomationSessionId,
            capturedAt: at.add(const Duration(milliseconds: 100)),
            messages: [
              CapturedMessage(
                  stableId: stableId,
                  direction: 'incoming',
                  sender: customer,
                  body: body,
                  sentAt: at,
                  axPath: 'controlled current-run message')
            ]));
        final id = (await database.incomingMessageIdAtTime(customer, at))!;
        return (await database.processingMessages(customer))
            .singleWhere((message) => message['id'] == id);
      }

      final self = await receive('self-observation', '转小耿', 1);
      final old = await receive('old-observation', '转小华', 2);
      final target = await receive('target-observation', '请转小关', 3);
      final hello = await receive('hello-observation', 'hello', 4);
      final selfId = self['id']! as String;
      final oldId = old['id']! as String;
      final targetId = target['id']! as String;
      final ticket = await database.createHumanReviewTicket(
          userId: customer,
          customerRequest: '转小华',
          reason: 'Customer explicitly requested human assistance.',
          requestMessageId: oldId);
      await (await database.database).insert('handoff_ai_fallbacks', {
        'session_id': database.currentAutomationSessionId,
        'user_id': customer,
        'request_message_id': oldId,
        'ticket_id': ticket.id,
        'reason': 'no_online_agent',
        'unknown_click': 0,
        'created_at_ms': 1,
        'yield_count': 0,
      });
      final sanitized = withoutSatisfiedNamedTransferIntents(
          _draft('请先确认电源灯是否亮。',
              requests: [selfId, oldId, targetId], review: true),
          {selfId},
          '格志打印机小耿',
          otherNamedTargetPresent: true);
      final result = await recordFrozenHumanTransferRequests(
          draft: sanitized,
          frozenInputs: [self, old, target, hello],
          database: database,
          customer: customer);
      expect(codexHumanTransferRequestIds(result.draft), {targetId});
      expect(result.requests.map((message) => message['id']), [targetId]);
      expect(result.repeatedRequest, isFalse);
      expect(
          (jsonDecode(result.draft.rawJson)
              as Map)['named_agent_already_current_message_ids'],
          [selfId]);
      final events = await (await database.database)
          .query('human_transfer_request_events');
      expect(events.map((row) => row['message_id']), [targetId]);
    });
  });
}
