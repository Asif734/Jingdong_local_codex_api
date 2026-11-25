import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/transcript_text.dart';
import 'package:jd_automation/codex/customer_language.dart';

void main() {
  test(
      'JD recommendation reminder and glyph-colon controls are not customer messages',
      () {
    expect(TranscriptText.clean('请尽快回复客户咨询，即将为客户推荐相似商品哦~'), isEmpty);
    expect(TranscriptText.clean('口 ：'), isEmpty);
    expect(TranscriptText.clean('为什么显示请尽快回复客户咨询？'), '为什么显示请尽快回复客户咨询？');
  });
  test(
      'recorded play/font controls cannot become a question or language switch',
      () {
    expect(TranscriptText.clean('口、Aa国Q◎'), isEmpty);
    final language = CustomerLanguageResolver.resolve([
      {'id': 'english', 'direction': 'incoming', 'body': 'do you have video?'},
      {'id': 'controls', 'direction': 'incoming', 'body': '口、Aa国Q◎'},
    ]);
    expect(language.language, CustomerLanguage.english);
    expect(language.sourceMessageId, 'english');
    expect(TranscriptText.clean('你好◎'), '你好◎');
    expect(TranscriptText.clean('打印一行就停？'), '打印一行就停？');
  });
  test(
      'JD warning appended to holding is excluded, customer quotation retained',
      () {
    const warning = '当前会话您存在消极服务行为，请积极与消费者协商解决问题，平台已记录信息，进一步了解规则请查看相关规则。';
    expect(TranscriptText.clean(warning), isEmpty);
    expect(
        TranscriptText.clean(
            'Please wait a moment while I check your latest message. $warning'),
        'Please wait a moment while I check your latest message.');
    expect(TranscriptText.clean('为什么会提示“$warning”？'), '为什么会提示“$warning”？');
  });
}
