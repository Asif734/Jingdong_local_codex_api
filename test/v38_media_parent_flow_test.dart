import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixtures = 'test/fixtures/v38_media_parent';
  late Directory temp;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late Map<String, dynamic> frames;
  late DateTime now;
  setUp(() async {
    frames = (jsonDecode(await File('$fixtures/provenance.json').readAsString())
        as Map<String, dynamic>)['frames'];
    temp = await Directory.systemTemp.createTemp('jd_v38_parent_');
    db = CaptureDatabase(storageRoot: temp);
    inventory = CustomerMediaInventory(db);
    now = DateTime.now().toUtc();
    await db.beginAutomationSession(
        startedAt: now.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  List<double> region(String frame) => (frames[frame]['region'] as List)
      .cast<num>()
      .map((v) => v.toDouble())
      .toList();
  DateTime? clock(String frame) => frame.startsWith('first-')
      ? DateTime.utc(2026, 11, 8, 3, 52, 49)
      : frame == 'tray-original'
          ? DateTime.utc(2026, 11, 8, 4, 2, 56)
          : null;
  Future<String> observe(String frame,
          {String? occurrence, String? parent, int index = 0, int slot = 0}) =>
      inventory.observe(
          customer: 'buyer',
          evidenceId: frames[frame]['evidenceId'],
          observedAt: now.add(Duration(seconds: index)),
          senderAt: clock(frame),
          slot: slot,
          region: region(frame),
          current: occurrence != null || parent != null,
          occurrenceKey: occurrence,
          parentReceiptId: parent);
  CapturedConversation capture(String receipt, String id,
          {List<CapturedMedia> media = const [],
          int index = 0,
          DateTime? senderAt}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: now.add(Duration(seconds: index)),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: media.isEmpty
                    ? '[Customer sent media; acquisition pending.]'
                    : '[Customer media original]',
                axPath: 'fixture',
                sentAt: senderAt,
                mediaReceiptId: receipt,
                media: media)
          ]);
  List<CapturedMedia> video(
          {bool audio = true, bool cover = true, String episode = 'ribbon'}) =>
      [
        CapturedMedia(
            type: 'video',
            path: '${temp.path}/owned-$episode.mp4',
            captureSource: 'jd_video_cache',
            description: audio
                ? '[Video audio: audible content exists, but no speech was recognized]'
                : 'Audio analysis pending.'),
        CapturedMedia(
            type: 'image',
            path: '$fixtures/$episode-first.jpg',
            originalName: 'video_frame_00s.jpg',
            captureSource: 'jd_video_frame_1fps'),
        CapturedMedia(
            type: 'image',
            path: '$fixtures/$episode-tail.jpg',
            originalName: 'video_frame_tail.jpg',
            captureSource: 'jd_video_frame_1fps'),
        if (cover)
          CapturedMedia(
              type: 'image',
              path: '$fixtures/$episode-first.jpg',
              captureSource: 'jd_video_cover',
              isPartial: true,
              description:
                  'Video preview reconstructed from its first decoded frame; no separate card cover was retained.'),
      ];
  Future<void> save(CapturedConversation c) async {
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true, currentTaskOnly: true);
  }

  Future<List<Map<String, Object?>>> business() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, 'buyer']);
  test('three cache/headerless observations are not three incoming businesses',
      () async {
    for (final name in ['first-gray', 'first-loaded']) {
      final receipt = await observe(name);
      await inventory.classify(receipt, 'video');
      await save(
          capture(receipt, 'visible-video:derived:$name', media: video()));
      expect(
          await inventory.resolveParent('buyer', receiptId: receipt), isNull);
    }
    await save(capture('unowned-cache-operation', 'visible-video:cache-only',
        media: video()));
    expect(await business(), isEmpty);
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    final rows = await (await db.database).query('customer_media_items');
    expect(rows.where((r) => r['message_id'] != null), isEmpty);
    expect(rows.where((r) => jsonDecode(r['media_json']! as String).isNotEmpty),
        hasLength(2));
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
  });
  test(
      'all observations and decoded assets retain one admitted parent and received time',
      () async {
    final receipt = await observe('first-gray', occurrence: 'arrival-alpha');
    final admitted = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: frames['first-gray']['evidenceId'],
        occurrenceKey: 'arrival-alpha',
        receivedAt: now,
        senderAt: clock('first-gray'),
        messageId: 'incoming-alpha');
    for (var i = 0; i < 4; i++) {
      final name =
          ['first-loaded', 'first-gray', 'first-loaded', 'first-loaded'][i];
      final observation =
          await observe(name, parent: admitted.receiptId, index: i + 1);
      final result = await inventory.classify(observation, 'video',
          fingerprint: i.isEven ? '0000000000000000' : 'ffffffffffffffff');
      expect(result, admitted.receiptId);
      await save(capture(result, admitted.messageId,
          media: video(audio: i > 0, episode: 'first'), index: i + 1));
      final parent = await inventory.resolveParent('buyer',
          receiptId: observation, requireCurrentSession: true);
      expect(parent!.messageId, admitted.messageId);
      expect(parent.receivedAt!.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch);
    }
    expect(await business(), hasLength(1));
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(admitted.messageId));
    final records =
        ((await (await db.history).read('buyer'))!['messages'] as List)
            .where((m) => m['direction'] == 'incoming');
    expect(records, hasLength(1));
    expect(records.single['id'], 'incoming-alpha');
  });
  test('real04:02:56 video is not re-admitted by the04:46 headerless a7 frame',
      () async {
    final receipt = await observe('tray-original', occurrence: 'arrival-tray');
    final parent = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: frames['tray-original']['evidenceId'],
        occurrenceKey: 'arrival-tray',
        receivedAt: now,
        senderAt: clock('tray-original'),
        messageId: 'incoming-tray');
    await inventory.classify(receipt, 'video');
    await save(capture(parent.receiptId, parent.messageId,
        media: video(episode: 'tray')));
    final answer = AiDraft.fromJson({
      'reply': 'Use the documented printer checks.',
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'fixture'
    }, mediaBaseUrl: Uri());
    final conversation = (await db.conversation('buyer'))!;
    expect(
        await db.saveDraft(conversation.id, answer,
            expectedMessageId: parent.messageId),
        1);
    final attempt =
        await db.beginDeliveryAttempt(userId: 'buyer', reply: answer.reply);
    final click = DateTime.now().millisecondsSinceEpoch;
    await File(attempt['receiptPath']!).writeAsString(jsonEncode({
      'attemptId': attempt['attemptId'],
      'customer': 'buyer',
      'state': 'submitted',
      'sendClickedAtMs': click,
      'timeMs': click + 500
    }));
    await db.recoverDeliveryReceipts();
    expect(
        await db.isMessageFormallyAnswered('buyer', parent.messageId), isTrue);
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    final before = await business();
    final old = await observe('tray-old-backfill', index: 42 * 60);
    await save(capture(old, 'media-pending:$old', index: 42 * 60));
    expect(await inventory.resolveParent('buyer', receiptId: old), isNull);
    expect(await business(), before);
    final raw = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [old]))
        .single;
    expect(raw['message_id'], isNull);
    expect(raw['admission_key'], isNull);
    expect(await db.hasPendingUnanswered('buyer'), isFalse);
    // A later exact occurrence association attaches the saved frame to its
    // established parent; it does not create another customer arrival.
    final bound = await observe('tray-old-backfill',
        parent: parent.receiptId, index: 42 * 60);
    expect(bound, parent.receiptId);
    expect(await business(), before);
  });
  test(
      'same second genuine bubbles and later same-file resend remain independent admissions',
      () async {
    final parents = <String>[];
    for (var i = 0; i < 3; i++) {
      final key = 'actual-arrival-$i';
      final receipt =
          await observe('first-loaded', occurrence: key, index: i, slot: i % 2);
      final parent = await db.admitMediaMessage('buyer',
          receiptId: receipt,
          evidenceId: frames['first-loaded']['evidenceId'],
          occurrenceKey: key,
          receivedAt: now.add(Duration(seconds: i)),
          senderAt: clock('first-loaded'),
          messageId: 'incoming-$i');
      await inventory.classify(receipt, 'video',
          fingerprint: '0000000000000000');
      await save(capture(parent.receiptId, parent.messageId,
          media: video(), index: i));
      parents.add(parent.receiptId);
    }
    expect(parents.toSet(), hasLength(3));
    expect(await business(), hasLength(3));
    final roots = await (await db.database)
        .query('customer_media_items', where: 'admission_key IS NOT NULL');
    expect(roots, hasLength(3));
    expect(roots.every((r) => r['canonical_id'] == null), isTrue);
  });
  test(
      'same live admission key redirects an extra observation without another business',
      () async {
    final first = await observe('first-gray', occurrence: 'same-arrival');
    final a = await db.admitMediaMessage('buyer',
        receiptId: first,
        evidenceId: frames['first-gray']['evidenceId'],
        occurrenceKey: 'same-arrival',
        receivedAt: now,
        messageId: 'incoming-only');
    final extra = await observe('first-loaded', index: 4);
    final b = await db.admitMediaMessage('buyer',
        receiptId: extra,
        evidenceId: frames['first-loaded']['evidenceId'],
        occurrenceKey: 'same-arrival',
        receivedAt: now.add(const Duration(seconds: 4)),
        messageId: 'must-not-become-input');
    expect(b.messageId, a.messageId);
    expect(b.receiptId, a.receiptId);
    expect(b.created, isFalse);
    final linked = await inventory.resolveParent('buyer', receiptId: extra);
    expect(linked!.messageId, a.messageId);
    expect(
        linked.receivedAt!.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
    expect(await business(), hasLength(1));
  });
  test(
      'real59 orphan first frame and reconstructed cover retain both roles in one file',
      () async {
    final receipt = await observe('ribbon-live', occurrence: 'arrival-ribbon');
    final parent = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: frames['ribbon-live']['evidenceId'],
        occurrenceKey: 'arrival-ribbon',
        receivedAt: now,
        messageId: 'incoming-ribbon');
    await inventory.classify(receipt, 'video');
    await save(capture(receipt, parent.messageId, media: video(audio: false)));
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await save(capture(receipt, parent.messageId, media: video()));
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(parent.messageId));
    final row = (await (await db.database).query('customer_media_items',
            where: 'item_id=?', whereArgs: [parent.receiptId]))
        .single;
    final media =
        (jsonDecode(row['media_json']! as String) as List).cast<Map>();
    expect(media.map((m) => m['path']).toSet(), hasLength(3));
    expect(media, hasLength(3));
    final first =
        media.singleWhere((m) => m['path'] == '$fixtures/ribbon-first.jpg');
    expect(ConversationFileStore.mediaRoles(first),
        containsAll(['video_frame', 'first_frame', 'video_cover']));
    final history =
        ((await (await db.history).read('buyer'))!['messages'] as List).single;
    expect(
        (history['media'] as List)
            .where((m) => m['path'] == '$fixtures/ribbon-first.jpg'),
        hasLength(1));
    expect(await business(), hasLength(1));
  });
  test(
      'v37 snapshot alternate cover role repairs only its original admitted business',
      () async {
    final receipt =
        await observe('ribbon-live', occurrence: 'legacy-ribbon-replay');
    final parent = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: frames['ribbon-live']['evidenceId'],
        occurrenceKey: 'legacy-ribbon-replay',
        receivedAt: now,
        messageId: 'ribbon-original-parent');
    final raw = frames['ribbon-v37-root'];
    Map<String, Object?> portable(Map file) {
      final copy = Map<String, Object?>.from(file);
      final path = file['path'].toString();
      copy['path'] = path.endsWith('frame_00.jpg')
          ? '$fixtures/ribbon-first.jpg'
          : file['original_name'] == 'video_frame_tail.jpg'
              ? '$fixtures/ribbon-tail.jpg'
              : '${temp.path}/${path.split('/').last}';
      return copy;
    }

    final oldMedia = (raw['media'] as List).cast<Map>().map(portable).toList();
    final alternates =
        (raw['historyAlternates'] as List).cast<Map>().map(portable).toList();
    final sql = await db.database;
    await sql.update('customer_media_items',
        {'kind': 'video', 'state': 'ready', 'media_json': jsonEncode(oldMedia)},
        where: 'item_id=?', whereArgs: [receipt]);
    final store = await db.history;
    final document = (await store.read('buyer'))!;
    final message = (document['messages'] as List).cast<Map>().single;
    message['media'] = oldMedia;
    message['media_alternates'] = alternates;
    await File(
            '${store.conversationsDirectory.path}/${store.safeUserId('buyer')}.json')
        .writeAsString(jsonEncode(document));
    expect(await inventory.analysisReadyMessageIds('buyer'), isEmpty);
    await inventory.reconcileProvenMediaAliases(customer: 'buyer');
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(parent.messageId));
    final after = (await sql.query('customer_media_items',
            where: 'item_id=?', whereArgs: [receipt]))
        .single;
    final media =
        (jsonDecode(after['media_json']! as String) as List).cast<Map>();
    expect(media.length, oldMedia.length);
    final first =
        media.singleWhere((m) => m['path'] == '$fixtures/ribbon-first.jpg');
    expect(ConversationFileStore.mediaRoles(first),
        containsAll(['first_frame', 'video_cover']));
    expect(after['message_id'], parent.messageId);
    expect(after['admitted_at_ms'], now.millisecondsSinceEpoch);
    expect(await business(), hasLength(1));
    await inventory.reconcileProvenMediaAliases(customer: 'buyer');
    final again = (await sql.query('customer_media_items',
            where: 'item_id=?', whereArgs: [receipt]))
        .single;
    expect(again['media_json'], after['media_json']);
  });
  test(
      'ready A cannot absorb same-clock same-slot B preview from another live admission',
      () async {
    final sameSecond = clock('first-gray')!;
    final a = await observe('first-gray', occurrence: 'actual-A', slot: 0);
    final parentA = await db.admitMediaMessage('buyer',
        receiptId: a,
        evidenceId: frames['first-gray']['evidenceId'],
        occurrenceKey: 'actual-A',
        receivedAt: now,
        senderAt: sameSecond,
        messageId: 'actual-A-message');
    await inventory.classify(a, 'video', fingerprint: '0000000000000000');
    await save(capture(a, parentA.messageId,
        media: video(episode: 'first'), senderAt: sameSecond));
    final b = await observe('first-loaded',
        occurrence: 'actual-B', index: 1, slot: 0);
    final parentB = await db.admitMediaMessage('buyer',
        receiptId: b,
        evidenceId: frames['first-loaded']['evidenceId'],
        occurrenceKey: 'actual-B',
        receivedAt: now.add(const Duration(seconds: 1)),
        senderAt: sameSecond,
        messageId: 'actual-B-message');
    await inventory.classify(b, 'video', fingerprint: '0000000000000000');
    await save(
        capture(b, parentB.messageId, senderAt: sameSecond, index: 1, media: [
      const CapturedMedia(
          type: 'image',
          path: '$fixtures/first-first.jpg',
          captureSource: 'verified_media_preview',
          isPartial: true)
    ]));
    final second = await inventory.resolveParent('buyer',
        receiptId: b, requireCurrentSession: true);
    expect(second, isNotNull);
    expect(second!.messageId, parentB.messageId);
    expect(second.receiptId, isNot(a));
    final sql = await db.database;
    final rowB = (await sql
            .query('customer_media_items', where: 'item_id=?', whereArgs: [b]))
        .single;
    expect(rowB['canonical_id'], isNull);
    expect(rowB['admission_key'], 'actual-B');
    expect(rowB['state'], 'preview');
    expect(await inventory.analysisReadyMessageIds('buyer'),
        contains(parentA.messageId));
    expect(await inventory.analysisReadyMessageIds('buyer'),
        isNot(contains(parentB.messageId)));
    expect(await business(), hasLength(2));
    await save(capture(b, parentB.messageId,
        senderAt: sameSecond, index: 2, media: video(episode: 'first')));
    expect(await inventory.analysisReadyMessageIds('buyer'),
        containsAll([parentA.messageId, parentB.messageId]));
    expect(
        (await sql.query('customer_media_items',
                where: 'admission_key IS NOT NULL'))
            .every((r) => r['canonical_id'] == null),
        isTrue);
    expect(
        (await db.processingMessages('buyer')).map((message) => message['id']),
        unorderedEquals([parentA.messageId, parentB.messageId]),
        reason: 'Both real bubbles must remain available as formal inputs');
    final incoming =
        ((await (await db.history).read('buyer'))!['messages'] as List)
            .whereType<Map>()
            .where((message) => message['direction'] == 'incoming');
    expect(incoming.map((message) => message['id']),
        unorderedEquals([parentA.messageId, parentB.messageId]),
        reason:
            'A shared physical file must not collapse distinct history IDs');
  });
}
