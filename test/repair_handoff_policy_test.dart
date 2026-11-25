import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  final service = CodexReplyService(
      executable: '/unused',
      workspace: Directory('/unused'),
      knowledgeDirectory: Directory('/unused'),
      outputSchema: File('/unused'));
  AiDraft draft({bool repair = true, String reply = '检测后确认需要维修，请先停止使用。'}) =>
      AiDraft.fromJson({
        'reply': reply,
        'decision': 'human_review_required',
        'risk_level': 'medium',
        'confidence': 1.0,
        'model': 'test',
        'risk_triggers': [if (repair) 'repair_required'],
        'required_slots': ['order_number'],
        'actions': [],
        'attachments': [],
        'used_record_ids': [],
      }, mediaBaseUrl: Uri());
  test(
      'confirmed repair enters existing service handoff without order prerequisite',
      () {
    final result = service.enforceHumanReviewPolicy(draft(), '卡住后已经无法使用');
    expect(isExplicitHumanTransfer(result), isTrue);
    final raw = jsonDecode(result.rawJson) as Map;
    expect(raw['risk_triggers'], contains('order_service_handoff'));
    expect(raw['required_slots'], isEmpty);
    expect(result.reply, contains('停止使用'));
  });
  test('a confirmed colleague responsibility also starts service handoff', () {
    final raw = jsonDecode(draft().rawJson) as Map<String, dynamic>;
    raw['risk_triggers'] = ['service_colleague_required'];
    raw['reply'] = '这个规格问题需要客服同事实际核查处理。';
    final result = service.enforceHumanReviewPolicy(
        AiDraft.fromJson(raw, mediaBaseUrl: Uri()), '这个配件还是不对');
    expect(isExplicitHumanTransfer(result), isTrue);
    expect((jsonDecode(result.rawJson) as Map)['risk_triggers'],
        contains('order_service_handoff'));
  });

  test('repair keyword alone does not authorize a transfer', () {
    final result = service.enforceHumanReviewPolicy(
        draft(repair: false, reply: '是否需要维修还不能确认，先检查纸张。'), '这个要维修吗');
    expect(isExplicitHumanTransfer(result), isFalse);
  });
  test('failed repair handoff respects existing suppression', () {
    final result = service.enforceHumanReviewPolicy(draft(), '卡住后已经无法使用',
        handoffUnavailable: true);
    expect(isExplicitHumanTransfer(result), isFalse);
  });
}
