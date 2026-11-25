import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/customer_codex_session.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/local_reply_router.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  const model = 'controlled-daily-model';
  const yesterday = '2026-11-09';
  const today = '2026-11-10';
  final history = <Map<String, dynamic>>[
    {'id': 'one', 'direction': 'incoming', 'body': 'A controlled question.'},
    {'id': 'answer', 'direction': 'outgoing', 'body': 'A controlled answer.'},
  ];
  CustomerCodexSession session({String? day, String? policy}) =>
      CustomerCodexSession(
        threadId: 'controlled-thread-$day',
        model: model,
        historyCount: 1,
        historyFingerprint: CustomerCodexSession.fingerprint(history.take(1)),
        lastReply: 'A controlled answer.',
        updatedAt: DateTime.now().toUtc(),
        replyLanguagePolicy: policy,
        businessDay: day,
      );

  test('thread identity rejects a different business day even within 24 hours',
      () {
    final old = session(day: yesterday, policy: 'same-language-and-run');
    expect(
        old.canResume(history, model,
            replyLanguagePolicy: 'same-language-and-run',
            businessDay: yesterday),
        isTrue);
    expect(
        old.canResume(history, model,
            replyLanguagePolicy: 'same-language-and-run', businessDay: today),
        isFalse,
        reason: 'A recent yesterday thread must never carry hidden context.');
    final restored = CustomerCodexSession.fromJson(old.toJson())!;
    expect(restored.businessDay, yesterday);
    expect(restored.canResume(history, model, businessDay: today), isFalse);
  });

  test('a legacy thread cannot resume in daily mode but keeps legacy behavior',
      () {
    final old = session(policy: 'legacy');
    expect(old.toJson().containsKey('business_day'), isFalse);
    expect(
        old.canResume(history, model, replyLanguagePolicy: 'legacy'), isTrue);
    expect(
        old.canResume(history, model,
            replyLanguagePolicy: 'legacy', businessDay: today),
        isFalse);
  });

  test('session files stay separate by day without falling back to legacy',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v52_daily_threads_');
    addTearDown(() => root.delete(recursive: true));
    final base = Directory('${root.path}/codex_sessions');
    final legacy = CustomerCodexSessionStore(base);
    final prior = CustomerCodexSessionStore(base, businessDay: yesterday);
    final current = CustomerCodexSessionStore(base, businessDay: today);
    await legacy.write('buyer', session(policy: 'legacy'));
    await prior.write('buyer', session(day: yesterday));
    expect(current.directory.path, '${base.path}/$today');
    expect(await current.read('buyer'), isNull);
    await current.write('buyer', session(day: today));
    expect((await prior.read('buyer'))!.businessDay, yesterday);
    expect((await current.read('buyer'))!.businessDay, today);
    await current.invalidate('buyer');
    expect(await current.read('buyer'), isNull);
    expect(await legacy.read('buyer'), isNotNull);
    expect(await prior.read('buyer'), isNotNull,
        reason: 'Invalidating today must preserve archived daily threads.');
  });

  test('session day must be a date key, not a directory traversal', () {
    expect(
        () => CustomerCodexSessionStore(Directory.systemTemp,
            businessDay: '../old'),
        throwsArgumentError);
  });

  test('today media or model does not inherit yesterday customer English',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v52_daily_context_');
    addTearDown(() => root.delete(recursive: true));
    final originalFiles = <String, String>{};
    for (final kind in ['image', 'video', 'model']) {
      final customer = 'controlled-$kind-buyer';
      final oldFile = File('${root.path}/$customer.json');
      final old = jsonEncode({
        'schema_version': 1,
        'user_id': customer,
        'display_name': customer,
        'stable_key': customer,
        'messages': [
          {
            'id': 'yesterday-english',
            'direction': 'incoming',
            'body': 'Please reply in English.',
            'text_origin': 'customer_text',
            'sent_at': '2026-11-09T15:59:00Z',
            'captured_at': '2026-11-09T15:59:01Z',
          },
          {
            'id': 'today-$kind',
            'direction': 'incoming',
            'body': kind == 'model' ? 'TP730' : '[Customer sent $kind]',
            'text_origin': kind == 'model' ? 'customer_text' : 'media',
            'sent_at': '2026-11-09T16:00:01Z',
            'captured_at': '2026-11-09T16:00:02Z',
            if (kind != 'model')
              'media': [
                {
                  'type': kind,
                  'path': '/controlled/$kind',
                  'description':
                      'English words in attachment must not set language.'
                }
              ],
          },
        ],
      });
      await oldFile.writeAsString(old);
      originalFiles[customer] = old;
    }
    final store = ConversationFileStore.forDay(root,
        businessDay: today, clock: () => DateTime.utc(2026, 11, 10, 4));
    await store.prepareDay();
    for (final kind in ['image', 'video', 'model']) {
      final customer = 'controlled-$kind-buyer';
      final document = (await store.read(customer))!;
      final inputs =
          (document['messages'] as List).cast<Map<String, dynamic>>();
      expect(inputs.map((message) => message['id']), ['today-$kind']);
      final language = CustomerLanguageResolver.resolve(inputs);
      expect(language.language, CustomerLanguage.unknown);
      expect(language.language.replyCode, 'zh');
      expect(language.sourceMessageId, isNull);
      expect(await File('${root.path}/$customer.json').readAsString(),
          originalFiles[customer],
          reason: 'Context isolation must not rewrite or erase old history.');
    }
  });

  test('UTC+8 midnight starts fresh local greeting and customer language',
      () async {
    expect(
        ConversationFileStore.businessDayFor(
            DateTime.parse('2026-11-09T15:59:59Z')),
        yesterday);
    expect(
        ConversationFileStore.businessDayFor(
            DateTime.parse('2026-11-09T16:00:00Z')),
        today);
    final todayMessages = <Map<String, dynamic>>[
      {
        'id': 'today-hello',
        'direction': 'incoming',
        'body': '您好',
        'text_origin': 'customer_text',
        'captured_at': '2026-11-09T16:00:01Z',
        'sent_at': '2026-11-09T16:00:00Z',
      }
    ];
    final choice = CustomerLanguageResolver.resolve(todayMessages);
    final reply = const LocalReplyRouter()
        .route(todayMessages, language: choice.language)!;
    expect(reply.model, 'local-intent-router-v1');
    expect(reply.reply, LocalReplyRouter.transferWelcome);
    expect(reply.reply, isNot(contains('Please reply in English')));
  });
}
