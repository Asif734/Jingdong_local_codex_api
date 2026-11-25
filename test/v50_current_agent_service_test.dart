import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  const account = '格志打印机小耿';
  Map<String, dynamic> input(String id, String body) => {
        'id': id,
        'direction': 'incoming',
        'body': body,
        'text_origin': 'customer_text',
      };
  AiDraft reply(String body,
          {List<String>? ids,
          List<String> triggers = const ['explicit_human_request']}) =>
      AiDraft.fromJson({
        'reply': body,
        'reply_purpose': 'substantive',
        'decision': 'human_review_required',
        'human_review_required': true,
        'risk_level': 'high',
        'risk_triggers': triggers,
        if (ids != null) 'human_transfer_request_message_ids': ids,
        'actions': [
          {'type': 'transfer', 'description': 'Transfer the conversation.'}
        ],
        'confidence': 1,
        'model': 'controlled-current-agent',
      }, mediaBaseUrl: Uri());

  test('only all-standalone self requests receive an identity acknowledgement',
      () {
    final own = [input('one', '请转小耿'), input('two', '麻烦转格志打印机小耿')];
    final draft = alreadyCurrentAgentReply(own, account,
        language: CustomerLanguage.chinese)!;
    expect(draft.reply, contains(account));
    expect(draft.reply, isNot(contains('正在转接')));
    expect(isExplicitHumanTransfer(draft), isFalse);
    expect(draftRequiresHumanReview(draft), isFalse);
    expect(codexHumanTransferRequestIds(draft), isEmpty);
    expect(
        (jsonDecode(draft.rawJson)
            as Map)['named_agent_already_current_message_ids'],
        ['one', 'two']);
    expect(
        alreadyCurrentAgentReply([input('one', '转小耿，打印不出来')], account,
            language: CustomerLanguage.chinese),
        isNull);
    expect(
        alreadyCurrentAgentReply(
            [...own, input('problem', '纸张为什么不出来？')], account,
            language: CustomerLanguage.chinese),
        isNull);
  });

  test(
      'unknown self identity or another requested account is not presumed self',
      () {
    expect(currentAgentRequestMessageIds([input('one', '转小耿')], null), isEmpty);
    final unverified = reply('请先检查电源灯。', ids: ['one']);
    expect(withoutSatisfiedNamedTransferIntents(unverified, {'one'}, null),
        same(unverified));
    expect(
        currentAgentRequestMessageIds([input('one', '转小关')], account), isEmpty);
    expect(currentAgentRequestMessageIds([input('one', '换其他客服')], account),
        isEmpty);
    expect(
        currentAgentRequestMessageIds([
          {...input('media-ocr', '转小耿'), 'text_origin': 'media'},
          {...input('subtitle', '转小耿'), 'source': 'video_subtitle'},
        ], account),
        isEmpty);
    expect(
        alreadyCurrentAgentReply([input('one', '转小关')], account,
            language: CustomerLanguage.english),
        isNull);
    final english = alreadyCurrentAgentReply(
        [input('one', 'Please transfer me to 小耿')], account,
        language: CustomerLanguage.english)!;
    expect(english.reply, startsWith('You are already connected with'));
  });

  test('only satisfied IDs leave the transfer intent sequence', () {
    final original = reply('请先检查电源灯是否亮。', ids: ['self', 'other']);
    final filtered = withoutSatisfiedNamedTransferIntents(
        original, {'self'}, account,
        otherNamedTargetPresent: true);
    expect(codexHumanTransferRequestIds(filtered), {'other'});
    expect(isExplicitHumanTransfer(filtered), isTrue);
    final answered = withoutSatisfiedNamedTransferIntents(
        reply('请先检查电源灯是否亮。', ids: ['self']), {'self'}, account);
    expect(answered.reply, '请先检查电源灯是否亮。');
    expect(codexHumanTransferRequestIds(answered), isEmpty);
    expect(draftRequiresHumanReview(answered), isFalse);
    expect(isExplicitHumanTransfer(answered), isFalse);
  });

  test('missing model IDs cannot turn a satisfied self request into handoff',
      () {
    final filtered = withoutSatisfiedNamedTransferIntents(
        reply('请先确认USB连接是否正常。'), {'self'}, account);
    expect(isExplicitHumanTransfer(filtered), isFalse);
    expect(filtered.actions, isEmpty);
    expect(codexHumanTransferRequestIds(filtered), isEmpty);
  });

  test('independent order authority remains review work', () {
    final filtered = withoutSatisfiedNamedTransferIntents(
        reply('订单退款需要有权限的同事核查。',
            ids: ['self'],
            triggers: ['explicit_human_request', 'order_service_handoff']),
        {'self'},
        account);
    expect(isExplicitHumanTransfer(filtered), isTrue);
    expect(draftRequiresHumanReview(filtered), isTrue);
    expect((jsonDecode(filtered.rawJson) as Map)['risk_triggers'],
        ['order_service_handoff']);
    expect(
        alreadyCurrentAgentReply([input('one', '转小耿，订单退款怎么处理')], account,
            language: CustomerLanguage.chinese),
        isNull);
  });

  test(
      'a mixed batch cannot complete with a transfer promise or identity alone',
      () {
    for (final text in [
      '我正在帮您转接，请稍等。',
      'I will transfer you to my colleague now.',
      '您好，当前由格志打印机小耿为您接待，请问有什么可以帮您？',
    ]) {
      expect(
          () => withoutSatisfiedNamedTransferIntents(
              reply(text, ids: ['self']), {'self'}, account),
          throwsA(isA<CodexReplyException>()));
    }
  });

  test('current agent authority review does not claim the transfer failed', () {
    final service = CodexReplyService(
        executable: '/unused-pure-policy-check',
        workspace: Directory.systemTemp,
        knowledgeDirectory: Directory.systemTemp,
        outputSchema: File('${Directory.systemTemp.path}/unused-schema.json'));
    for (final language in [
      CustomerLanguage.chinese,
      CustomerLanguage.english
    ]) {
      final guarded = service.enforceHumanReviewPolicy(
          reply('正在为您转接，请稍等。',
              ids: ['self'], triggers: ['order_service_handoff']),
          '转小耿，订单退款怎么处理',
          language: language,
          handoffUnavailable: true,
          currentAgentReviewAccount: account);
      expect(guarded.reply, contains(account));
      expect(guarded.reply, isNot(contains('转接尚未完成')));
      expect(guarded.reply, isNot(contains('transfer has not completed')));
      expect(draftRequiresHumanReview(guarded), isTrue);
      expect(
          (jsonDecode(guarded.rawJson) as Map)['reply_purpose'], 'substantive',
          reason: 'Wording does not alter the existing reply scope.');
    }
  });
}
