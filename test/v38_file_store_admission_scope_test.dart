import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  late Directory temp;
  late ConversationFileStore store;
  final first = DateTime.utc(2026, 11, 8, 4, 2, 56);
  final later = DateTime.utc(2026, 11, 8, 4, 46, 35);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jd_v38_file_scope_');
    store = ConversationFileStore(temp);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  CapturedMessage message(String id, String body, {DateTime? at}) =>
      CapturedMessage(
          stableId: id,
          direction: 'incoming',
          body: body,
          sentAt: at ?? first,
          axPath: 'explicit fixture bubble');
  CapturedConversation capture(List<CapturedMessage> messages,
          {required String session, required DateTime at}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: session,
          capturedAt: at,
          messages: messages);
  Future<List<Map>> records() async =>
      ((await store.read('buyer'))!['messages'] as List).cast<Map>();
  test(
      'mixed frame stamps only selected actual new incoming, not old context OCR',
      () async {
    final old = message('old-question', 'Old already observed question.');
    await store.appendCapture(capture([old], session: 'prior', at: first));
    final oldRecord = (await records()).single;
    final capturedAt = oldRecord['captured_at'];
    final oldLive = List.of(oldRecord['live_observed_session_ids']);
    await store.appendCapture(
        capture([
          old,
          message('new-question', 'A genuinely new question.', at: later)
        ], session: 'current', at: later),
        activeIncomingIds: {'new-question'});
    final all = await records();
    final previous = all.singleWhere((r) => r['id'] == 'old-question');
    expect(previous['captured_at'], capturedAt);
    expect(previous['live_observed_session_ids'], oldLive);
    expect(previous['live_observed_session_ids'], isNot(contains('current')));
    expect(
        all.singleWhere(
            (r) => r['id'] == 'new-question')['live_observed_session_ids'],
        ['current']);
  });
  test(
      'unselected newly saved historical context cannot be repaired into current business',
      () async {
    await store.appendCapture(
        capture([
          message('old-unseen', 'Old scrolled context.'),
          message('new', 'Live current question.', at: later)
        ], session: 'current', at: later),
        activeIncomingIds: {'new'});
    final old = (await records()).singleWhere((r) => r['id'] == 'old-unseen');
    expect(old['capture_purpose'], 'history_only');
    expect(old['live_observed_session_ids'], isNull);
    await store.appendCapture(
        capture([message('old-unseen', 'Old scrolled context.')],
            session: 'current', at: later.add(const Duration(minutes: 1))),
        activeIncomingIds: {});
    final again = (await records()).singleWhere((r) => r['id'] == 'old-unseen');
    expect(again['capture_purpose'], 'history_only');
    expect(again['live_observed_session_ids'], isNull);
    expect(again['activated_at'], isNull);
  });
  test(
      'selected proven alias promotes exactly its canonical input once without refreshing receive time',
      () async {
    await store.appendCapture(
        capture([message('canonical', 'Same real incoming bubble.')],
            session: 'current', at: first),
        historyOnly: true);
    final original = (await records()).single['captured_at'];
    await store.appendCapture(
        capture([message('selected-ocr-alias', 'Same real incoming bubble.')],
            session: 'current', at: later),
        activeIncomingIds: {'selected-ocr-alias'});
    var record = (await records()).single;
    expect(record['id'], 'canonical');
    expect(record['observed_ids'], contains('selected-ocr-alias'));
    expect(record['live_observed_session_ids'], ['current']);
    expect(record['capture_purpose'], 'live_signal');
    expect(record['captured_at'], original);
    final activated = record['activated_at'];
    await store.appendCapture(
        capture([message('selected-ocr-alias', 'Same real incoming bubble.')],
            session: 'current', at: later.add(const Duration(minutes: 1))),
        activeIncomingIds: {});
    record = (await records()).single;
    expect(record['captured_at'], original);
    expect(record['activated_at'], activated);
    expect(record['live_observed_session_ids'], ['current']);
  });
}
