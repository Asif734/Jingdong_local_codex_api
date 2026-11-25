import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  test('Chinese-only deployment keeps fallback Chinese for English input',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_fixed_zh_');
    addTearDown(() => root.delete(recursive: true));
    final service = CodexReplyService(
        executable: '/unused',
        workspace: root,
        knowledgeDirectory: root,
        outputSchema: File('${root.path}/schema.json'),
        chineseOnly: true);
    final result = service.contextAwareFallback([
      {'direction': 'incoming', 'body': 'Please answer in English.'},
    ], hasImage: false, failure: CodexFallbackFailure.timeout);
    expect(ChineseOnlyReplyPolicy.accepts(result.reply), isTrue);
    expect(
        ChineseOnlyReplyPolicy.accepts('Please restart the printer.'), isFalse);
    expect(ChineseOnlyReplyPolicy.accepts('请重启 M880D。'), isTrue);
  });

  for (final language in [CustomerLanguage.chinese, CustomerLanguage.english]) {
    test(
        'every fixed policy response follows $language without changing safety',
        () async {
      final root =
          await Directory.systemTemp.createTemp('jd_language_policies_');
      addTearDown(() => root.delete(recursive: true));
      final service = CodexReplyService(
          executable: '/unused',
          workspace: root,
          knowledgeDirectory: root,
          outputSchema: File('${root.path}/schema.json'));
      AiDraft draft(String reply, {bool review = false, String? reason}) =>
          service.parseResponse(jsonEncode({
            'reply': reply,
            'decision': review ? 'human_review_required' : 'draft',
            'confidence': 0.8,
            'used_record_ids': <String>[],
            'required_slots': <String>[],
            'actions': <Object?>[],
            'risk_level': review ? 'high' : 'low',
            'risk_triggers': <String>[],
            'auto_send_allowed': false,
            'model': 'test',
            'attachments': <Object?>[],
            'image_descriptions': <Object?>[],
            'human_review_required': review,
            'reason': reason,
          }));
      final ordinary = draft(language == CustomerLanguage.english
          ? 'Please describe the issue.'
          : '请描述具体问题。');
      final cases = <String, AiDraft>{
        'identity': service.enforceCustomerFacingPolicy(
            ordinary, 'Are you a robot?',
            language: language),
        'scope': service.enforceCustomerFacingPolicy(
            ordinary, 'Can you help with WeChat?',
            language: language),
        'media clarification': service.enforceCustomerFacingPolicy(
            draft('The video shows a printer.'), 'M880D',
            language: language),
        'private wording': service.enforceCustomerFacingPolicy(
            draft('My OCR analysis is complete.'), 'M880D',
            language: language),
        'purchase pressure': service.enforceCustomerFacingPolicy(
            draft('Buy it on JD before placing your order.'), 'M880D',
            language: language),
        'unverified fact': service.enforceCustomerFacingPolicy(
            draft('I have asked a technical colleague to verify this.'),
            'M880D',
            language: language),
        'unconfirmed handoff': service.enforceCustomerFacingPolicy(
            draft('I have arranged for a human agent to assist you.'), 'M880D',
            language: language),
        'first transfer': service.enforceHumanReviewPolicy(ordinary, 'M880D',
            language: language, humanTransferRequested: true),
        'repeated transfer': service.enforceHumanReviewPolicy(ordinary, 'M880D',
            language: language,
            humanTransferRequested: true,
            repeatedHumanTransferRequest: true),
        'refund': service.enforceHumanReviewPolicy(ordinary, 'I want a refund',
            language: language),
        'dissatisfaction': service.enforceHumanReviewPolicy(
            ordinary, 'This reply did not help',
            language: language),
        'no solution': service.enforceHumanReviewPolicy(
            draft('I cannot resolve this issue.',
                review: true, reason: 'No reliable solution found.'),
            'M880D',
            language: language),
        'second investigation': service.enforceHumanReviewPolicy(
            draft('Transferred to a human agent.', review: true), 'M880D',
            language: language, technicalSecondInvestigationCompleted: true),
        'product photo': service.enforceProductPhotoReview(ordinary, 'M880D',
            language: language),
        for (final failure in CodexFallbackFailure.values)
          'failure $failure': service.contextAwareFallback([
            {
              'direction': 'incoming',
              'body': language == CustomerLanguage.english
                  ? 'How do I connect it?'
                  : '怎么连接？'
            },
            {'direction': 'incoming', 'body': '[Customer sent a video.]'},
          ], hasImage: true, failure: failure),
      };
      for (final entry in cases.entries) {
        expect(entry.value.reply, isNotEmpty, reason: entry.key);
        expect(RegExp(r'[\u3400-\u9fff]').hasMatch(entry.value.reply),
            language == CustomerLanguage.chinese,
            reason: entry.key);
        expect(jsonDecode(entry.value.rawJson)['auto_send_allowed'], isFalse,
            reason: entry.key);
      }
      expect(draftRequiresHumanReview(cases['first transfer']!), isFalse);
      for (final name in [
        'repeated transfer',
        'refund',
        'dissatisfaction',
        'product photo',
        'second investigation'
      ]) {
        expect(draftRequiresHumanReview(cases[name]!), isTrue, reason: name);
      }
    });
  }
}
