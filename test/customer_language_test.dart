import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/customer_codex_session.dart';
import 'package:jd_automation/codex/fixed_replies.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/codex/local_reply_router.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

Map<String, dynamic> incoming(String body, [String? id]) =>
    {'direction': 'incoming', 'body': body, if (id != null) 'id': id};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (body, expected) in [
    ('你好，这个打印机怎么连接？', CustomerLanguage.chinese),
    ('How can I connect this printer?', CustomerLanguage.english),
    ('TD630G支持Wi-Fi吗？', CustomerLanguage.chinese),
    ('Can TD630G print 中文?', CustomerLanguage.english),
    ('请用英文回复', CustomerLanguage.english),
    ('Please reply in Chinese', CustomerLanguage.chinese),
    ('English please', CustomerLanguage.english),
    ('Please use Chinese', CustomerLanguage.chinese),
    ('英文回复', CustomerLanguage.english),
    ('请用英文', CustomerLanguage.english),
    ('麻烦用英语，谢谢', CustomerLanguage.english),
    ('打印机可以用英文打印吗？', CustomerLanguage.chinese),
    ('M880D', null),
    ('TD630G (Bluetooth)', null),
    ('80mm', null),
    ('OK', null),
    ('👍', null),
    ('https://example.com/M880D', null),
    ('[Customer sent an image.]', null),
    ('[Customer sent a video.]', null),
    ('口、Aa国Q◎', null),
    ('◎ 回', null),
    ('你好◎', CustomerLanguage.chinese),
  ]) {
    test('language evidence: $body', () {
      expect(CustomerLanguageResolver.fromText(body), expected);
    });
  }

  for (final (question, expected) in [
    ('How can I connect this printer?', CustomerLanguage.english),
    ('这个打印机怎么连接？', CustomerLanguage.chinese),
  ]) {
    test('neutral and media messages inherit $expected across stored history',
        () {
      final messages = [
        incoming(question, 'question'),
        {'direction': 'outgoing', 'body': '您好，请稍等。'},
        incoming('TD630G'),
        incoming('OK'),
        incoming('口、Aa国Q◎'),
        incoming('[Customer sent an image.]'),
        incoming('[Customer sent a video.]'),
        incoming('您的同事小甘将客户买家转接给您'),
      ];
      final persisted = (jsonDecode(jsonEncode(messages)) as List)
          .cast<Map<String, dynamic>>();
      final choice = CustomerLanguageResolver.resolve(persisted);
      expect(choice.language, expected);
      expect(choice.sourceMessageId, 'question');
      final holding =
          chooseHoldingReply('', language: choice.language, random: Random(1));
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(holding),
          expected == CustomerLanguage.chinese);
    });
  }

  test('latest meaningful customer language wins in either direction', () {
    expect(
        CustomerLanguageResolver.resolve([
          incoming('你好'),
          incoming('How do I install it?'),
          incoming('M880D')
        ]).language,
        CustomerLanguage.english);
    expect(
        CustomerLanguageResolver.resolve(
            [incoming('Hello'), incoming('怎么安装？'), incoming('OK')]).language,
        CustomerLanguage.chinese);
  });

  test('late OCR backfill cannot reverse a newer language switch', () {
    final choice = CustomerLanguageResolver.resolve([
      {
        ...incoming('How do I install it?', 'new'),
        'sent_at': '2026-11-01T10:01:00Z'
      },
      {
        ...incoming('怎么连接？', 'old'),
        'sent_at': '2026-11-01T10:00:00Z',
        'captured_at': '2026-11-01T10:02:00Z'
      },
    ]);
    expect(choice.language, CustomerLanguage.english);
    expect(choice.sourceMessageId, 'new');
  });

  test('first media or model without language history defaults to Chinese', () {
    for (final body in [
      'M880D',
      '[Customer sent an image.]',
      '[Customer sent a video.]'
    ]) {
      final choice = CustomerLanguageResolver.resolve([incoming(body)]);
      expect(choice.language, CustomerLanguage.unknown);
      expect(FixedReplies.text(FixedReplies.uncapturedHolding, choice.language),
          '请稍等，我正在核对您刚发来的消息。');
      expect(
          chooseHoldingReply(body,
              language: choice.language, random: Random(2)),
          isIn(chineseHoldingReplies));
    }
  });

  test('all 20 holding variants and recovery messages support both languages',
      () {
    expect(englishHoldingReplies.toSet(), hasLength(20));
    for (final chinese in [
      ...chineseHoldingReplies,
      FixedReplies.uncapturedHolding,
      FixedReplies.resend
    ]) {
      final english = FixedReplies.text(chinese, CustomerLanguage.english);
      expect(english, isNotEmpty);
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(english), isFalse);
      expect(isRecoveryReply(chinese), isTrue);
      expect(isRecoveryReply(english), isTrue);
      expect(FixedReplies.text(chinese, CustomerLanguage.unknown), chinese);
    }
    expect(
        isHoldingReply(
            FixedReplies.text(FixedReplies.resend, CustomerLanguage.english)),
        isFalse);
  });

  test(
      'sentence spacing cannot leave a fixed Chinese scope reply for an English customer',
      () {
    expect(
        FixedReplies.localizeIfFixed(
            '本客服账号仅处理京东店铺及京东订单。 请问您的京东订单或产品需要什么帮助？', CustomerLanguage.english),
        'This customer service account handles only our JD store and JD orders. How can I help with your JD order or product?');
    expect(
        isHoldingReply('Please wait a moment while we\ncheck your question.'),
        isTrue);
  });

  test('wrapped English seller holding text is removed from customer OCR', () {
    expect(
        stripAppendedHoldingReply(
            "It doesn't print.Please wait a moment while we\ncheck your question."),
        "It doesn't print.");
  });

  test('English contractions do not conceal appended holding text', () {
    final holding = englishHoldingReplies.first;
    expect(stripAppendedHoldingReply("It doesn't print.$holding"),
        "It doesn't print.");
    expect(stripAppendedHoldingReply("Why did you say '$holding'?"),
        "Why did you say '$holding'?");
    expect(
        stripAppendedHoldingReply('你说“$holding”是什么意思？'), '你说“$holding”是什么意思？');
  });

  test(
      'English welcome is recognized after transfer to avoid duplicate greeting',
      () {
    final at = DateTime.utc(2026, 11, 1, 10);
    final messages = [
      incoming('How do I install the printer?'),
      {
        'direction': 'outgoing',
        'body':
            'Hello, welcome to Grozziie customer service. How can I help you?',
        'captured_at': at.toIso8601String()
      },
      {
        ...incoming('Hello'),
        'captured_at': at.add(const Duration(minutes: 1)).toIso8601String()
      },
    ];
    expect(
        const LocalReplyRouter().route(messages, transferNoticeAt: at), isNull);
  });

  test('old sessions and language changes cannot resume stale language policy',
      () {
    final history = [incoming('How do I install it?', 'question')];
    CustomerCodexSession session(String? policy) => CustomerCodexSession(
          threadId: 'thread',
          model: 'test',
          historyCount: 1,
          historyFingerprint: CustomerCodexSession.fingerprint(history),
          lastReply: 'Which model?',
          updatedAt: DateTime.now(),
          replyLanguagePolicy: policy,
        );
    final delivered = [
      ...history,
      {'direction': 'outgoing', 'body': 'Which model?'}
    ];
    expect(
        session(null).canResume(delivered, 'test',
            replyLanguagePolicy: 'customer-language-v1:en'),
        isFalse);
    expect(
        session('customer-language-v1:zh').canResume(delivered, 'test',
            replyLanguagePolicy: 'customer-language-v1:en'),
        isFalse);
    final compatible = CustomerCodexSession.fromJson(
        jsonDecode(jsonEncode(session('customer-language-v1:en').toJson())))!;
    expect(
        compatible.canResume(delivered, 'test',
            replyLanguagePolicy: 'customer-language-v1:en'),
        isTrue);
  });

  test(
      'generation uses frozen customer language, not later messages or seller language',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_reply_language_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    await File('${knowledge.path}/printer_kb.md')
        .writeAsString('TP732 is a printer.');
    final requestFile = File('${root.path}/request.txt');
    final fake = File('${root.path}/fake-codex.sh');
    await fake.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > "${requestFile.path}"
printf '%s\\n' '{"reply":"请告诉我您目前需要解决的具体问题，我会继续为您核对。","decision":"ask_clarification","confidence":0.9,"used_record_ids":[],"required_slots":["connection"],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
''');
    expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.now(),
      messages: [
        CapturedMessage(
            stableId: 'en',
            direction: 'incoming',
            body: 'How do I connect this printer?',
            axPath: 'test'),
        CapturedMessage(
            stableId: 'model',
            direction: 'incoming',
            body: 'TP732',
            axPath: 'test'),
        CapturedMessage(
            stableId: 'later',
            direction: 'incoming',
            body: '现在用中文回复',
            axPath: 'test'),
      ],
    ));
    final document = await (await database.history).read('buyer');
    final messages =
        (document!['messages'] as List).cast<Map<String, dynamic>>();
    final endId = messages
        .firstWhere((message) => message['body'] == 'TP732')['id'] as String;
    final service = CodexReplyService(
        executable: fake.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'));
    final draft = await service.generate(
        conversation: (await database.conversations()).single,
        database: database,
        batchEndMessageId: endId);
    final request = jsonDecode((await requestFile.readAsString())
        .split('<request_json>')[1]
        .split('</request_json>')[0]) as Map<String, dynamic>;
    final instructions =
        (await requestFile.readAsString()).split('<request_json>').first;
    expect(instructions, contains('Reply entirely in English'));
    expect(instructions, contains('overrides any older default'));
    expect(request['reply_language'], 'en');
    expect(request['reply_language_instruction'],
        contains('Reply entirely in English'));
    expect(request['reply_language_source_message_id'], messages.first['id']);
    expect(jsonEncode(request['conversation']), isNot(contains('现在用中文回复')));
    expect(draft.reply,
        'Please tell me the specific problem you need to solve, and I will continue checking it for you.');
  });
}
