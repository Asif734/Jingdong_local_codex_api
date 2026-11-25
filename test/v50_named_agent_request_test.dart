import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/named_agent_request.dart';

void main() {
  const current = '格志打印机小耿';

  test('explicit named requests match literal account text', () {
    for (final message in [
      '转小耿',
      '转小耿阿',
      '麻烦转小耿谢谢',
      '请转给格志打印机小耿',
      '帮我找小耿客服',
      '让小耿接待',
      '请小耿来接手',
      '你好，麻烦转小耿，谢谢',
      'Please transfer me to 小耿',
      'Please transfer me to 小耿.',
      'connect me with 小耿 please',
      "I'd like to speak with agent 小耿.",
    ]) {
      final request = NamedAgentRequest.parse(message);
      expect(request, isNotNull, reason: message);
      expect(request!.matchesAccount(current), isTrue, reason: message);
      expect(request.isStandalone, isTrue, reason: message);
    }
  });

  test('romanized transfer action extracts one named target', () {
    for (final message in [
      'zhuan wen wen',
      'ZHUAN WEN WEN',
      'zhuan wen wen，zhuan wen wen',
      'transfer to wen wen',
    ]) {
      final request = NamedAgentRequest.parse(message);
      expect(request, isNotNull, reason: message);
      expect(request!.target.toLowerCase(), 'wen wen', reason: message);
      expect(request.isStandalone, isTrue, reason: message);
    }
  });

  test('romanized action keeps existing request constraints', () {
    for (final message in [
      "don't zhuan wen wen",
      'do not zhuan wen wen',
      'never zhuan wen wen',
      '昨天 zhuan wen wen',
      'wen wen said zhuan wen wen',
      'zhuan human',
      'zhuan ren gong',
      'zhuan rengong',
      'zhuan ke fu',
      'zhuan kefu',
      'zhuan ren gong ke fu',
      'zhuan rengongkefu',
      'zhuan wen wen or xiao hua',
      'zhuan wen wen and xiao hua',
      'zhuan wen wen，zhuan xiao hua',
    ]) {
      expect(NamedAgentRequest.parse(message), isNull, reason: message);
    }
    final question = NamedAgentRequest.parse('zhuan wen wen，打印机怎么连接？');
    expect(question!.target, 'wen wen');
    expect(question.isStandalone, isFalse);
  });

  test('romanized action selects the first online full-account pinyin match',
      () {
    const account = '格志打印机文文（雯雯）';
    for (final message in ['zhuan wen wen', 'transfer to wen wen']) {
      final request = NamedAgentRequest.parse(message)!;
      expect(request.matchesAccount(account), isTrue);
      expect(request.matchesAccount('格志打印机小华'), isFalse);
      expect(
          request.firstMatchingAccount([
            '格志打印机小华',
            account,
            '另一店铺文文',
          ]),
          account);
      expect(request.firstMatchingAccount(['另一店铺文文', account]), '另一店铺文文');
    }
  }, skip: !Platform.isMacOS);

  test('literal account text supports different store prefixes', () {
    expect(NamedAgentRequest.parse('转小华')!.matchesAccount('其他店铺:小华'), isTrue);
    expect(NamedAgentRequest.parse('转小华')!.matchesAccount(current), isFalse);
    expect(NamedAgentRequest.parse('转小雨')!.matchesAccount('打印耗材专卖店小雨'), isTrue);
    expect(NamedAgentRequest.parse('转小耿')!.matchesAccount('小米店小耿'), isTrue);
    expect(NamedAgentRequest.parse('转特别店小耿')!.matchesAccount('特别店小耿'), isTrue);
    expect(NamedAgentRequest.parse('转或然店小耿')!.matchesAccount('或然店小耿'), isTrue);
    expect(
        NamedAgentRequest.parse('transfer me to Agent007')!
            .matchesAccount('shop:Agent007'),
        isTrue);
    expect(NamedAgentRequest.parse('转给格志打印机小耿')!.matchesAccount('另一家店小耿'),
        isFalse);
  });

  test('negative, historical and generic requests cannot suppress a transfer',
      () {
    for (final message in [
      '不要转小耿',
      '别找小耿',
      '不用让小耿接待',
      '小耿上次说会处理',
      '小耿说请转人工',
      '小耿是谁',
      '转人工',
      '请转其他客服',
      '帮我找另一个客服',
      '我要退款，请转售后',
      "Please don't transfer me to 小耿",
      'Transfer me to another agent',
      'Please connect me with a human',
    ]) {
      expect(NamedAgentRequest.parse(message), isNull, reason: message);
    }
  });

  test('ambiguous multiple names never become a self-transfer match', () {
    for (final message in [
      '转小耿或小华',
      '转小耿和小华',
      '转小耿，或者小华',
      '转小耿，转小华',
      'transfer me to Alice or Bob',
      'transfer me to Alice and Bob',
      '转小耿，不然找小华',
      '转小耿和小华，还是转小耿',
    ]) {
      expect(NamedAgentRequest.parse(message), isNull, reason: message);
    }
  });

  test('a clear replacement target is not the previously rejected own name',
      () {
    final request = NamedAgentRequest.parse('不要转小耿，请转小华');
    expect(request, isNotNull);
    expect(request!.target, '小华');
    expect(request.matchesAccount(current), isFalse);
    expect(request.isStandalone, isFalse);
  });

  test('questions remain on the normal reply path even when the name is self',
      () {
    for (final message in [
      '转小耿，打印机怎么连接？',
      '请转小耿帮我处理打印机的问题',
      'transfer me to 小耿 regarding my printer',
      '让小耿接待，我的订单什么时候发货',
    ]) {
      final request = NamedAgentRequest.parse(message);
      expect(request, isNotNull, reason: message);
      expect(request!.matchesAccount(current), isTrue, reason: message);
      expect(request.isStandalone, isFalse, reason: message);
    }
  });

  test(
      'matching accepts literal substrings but never guesses confusable characters',
      () {
    final request = NamedAgentRequest.parse('转小耿')!;
    expect(request.matchesAccount('格志打印机小耿耿'), isTrue);
    expect(request.matchesAccount('格志打印机小耿2'), isTrue);
    expect(request.matchesAccount('当前客服账号'), isFalse);
    expect(
        NamedAgentRequest.parse('transfer me to AgentI')!
            .matchesAccount('Agent1'),
        isFalse);
    expect(
        NamedAgentRequest.parse('transfer me to AgentI')!
            .matchesAccount('Agentl'),
        isFalse);
    expect(
        NamedAgentRequest.parse('transfer me to xiaogeng')!
            .matchesAccount(current),
        Platform.isMacOS);
  });

  test('matches requested text inside full names with parentheses', () {
    const account = '格志打印机文文（雯雯）';
    expect(NamedAgentRequest.parse('转文文')!.matchesAccount(account), isTrue);
    expect(NamedAgentRequest.parse('转雯雯')!.matchesAccount(account), isTrue);
    expect(
        NamedAgentRequest.parse('转格志打印机文文')!.matchesAccount(account), isTrue);
    expect(NamedAgentRequest.parse('转小华')!.matchesAccount(account), isFalse);
    expect(NamedAgentRequest.parse('转格志打印机文文（雯雯）')!.matchesAccount(account),
        isTrue);
  });

  test('pinyin matches full account text without generated aliases', () {
    const account = '格志打印机文文（雯雯）';
    expect(NamedAgentRequest.parse('转wenwen')!.matchesAccount(account), isTrue);
    expect(NamedAgentRequest.parse('转WENWEN')!.matchesAccount(account), isTrue);
    expect(
        NamedAgentRequest.parse('转wen wen')!.matchesAccount(account), isTrue);
    expect(
        NamedAgentRequest.parse('转xiaohua')!.matchesAccount(account), isFalse);
    expect(
        NamedAgentRequest.parse('转xiaohua')!.matchesAccount('格志打印机小华'), isTrue);
    expect(
        NamedAgentRequest.parse('转wenwen')!.firstMatchingAccount([
          '格志打印机小华',
          '格志打印机文文（雯雯）',
          '另一店铺文文',
        ]),
        account);
  }, skip: !Platform.isMacOS);

  test('first online substring match preserves roster order', () {
    final request = NamedAgentRequest.parse('转文文')!;
    final matches = request.matchingAccounts([
      '格志打印机小华',
      '格志打印机文文（雯雯）',
      '格志打印机文文2',
    ]);
    expect(matches, ['格志打印机文文（雯雯）', '格志打印机文文2']);
    expect(request.firstMatchingAccount(matches), '格志打印机文文（雯雯）');
    expect(request.firstMatchingAccount(['格志打印机小华']), isNull);
  });

  test(
      'online roster matching preserves display order and removes duplicate rows',
      () {
    final request = NamedAgentRequest.parse('转小耿')!;
    expect(request.matchingAccounts(['格志打印机小华', current, current]), [current]);
    expect(request.matchingAccounts([current, '另一店铺:小耿']), hasLength(2));
    expect(request.matchingAccounts(['格志打印机小华']), isEmpty);
  });
}
